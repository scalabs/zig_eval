const std = @import("std");
const matchers = @import("../matchers/root.zig");

const max_eval_file_bytes = 1024 * 1024;
const max_dataset_file_bytes = 8 * 1024 * 1024;
pub const max_attachment_bytes = 5 * 1024 * 1024;

pub const EvalDefinition = struct {
    id: []const u8,
    group: []const u8,
    description: []const u8,
    dataset_path: []const u8,
    split: []const u8,
    matcher: matchers.MatcherConfig,
    default_run_count: u32,
    service_allowlist: ?[]const []const u8 = null,
    tools: ?[]const ToolDefinition = null,
};

pub const EvalCase = struct {
    id: []const u8,
    input: []const u8,
    ideal: ?[]const u8 = null,
    expected_tool_calls: ?[]const ExpectedToolCall = null,
    attachments: ?[]const Attachment = null,
};

pub const AttachmentKind = enum {
    image,
    file,
};

pub const Attachment = struct {
    kind: AttachmentKind,
    path: []const u8,
    mime_type: ?[]const u8 = null,
    label: ?[]const u8 = null,
};

pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    parameters_json: []const u8,
};

pub const ExpectedToolCall = struct {
    name: []const u8,
    arguments_json: ?[]const u8 = null,
};

pub const LoadedEvalDefinition = struct {
    parent_allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    value: EvalDefinition,

    pub fn deinit(self: *LoadedEvalDefinition) void {
        self.arena.deinit();
        self.parent_allocator.destroy(self.arena);
        self.* = undefined;
    }
};

pub const LoadedEvalDefinitions = struct {
    parent_allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    items: []const EvalDefinition,

    pub fn deinit(self: *LoadedEvalDefinitions) void {
        self.arena.deinit();
        self.parent_allocator.destroy(self.arena);
        self.* = undefined;
    }
};

pub const LoadedEvalCases = struct {
    parent_allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    items: []const EvalCase,

    pub fn deinit(self: *LoadedEvalCases) void {
        self.arena.deinit();
        self.parent_allocator.destroy(self.arena);
        self.* = undefined;
    }
};

pub fn loadEvalDefinition(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    path: []const u8,
) !LoadedEvalDefinition {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer allocator.destroy(arena);
    errdefer arena.deinit();

    const definition = try loadEvalDefinitionWithAllocator(allocator, arena.allocator(), dir, path);
    return .{
        .parent_allocator = allocator,
        .arena = arena,
        .value = definition,
    };
}

pub fn loadAllEvalDefinitions(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    base_path: []const u8,
) !LoadedEvalDefinitions {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer allocator.destroy(arena);
    errdefer arena.deinit();

    var evals_dir = try dir.openDir(base_path, .{ .iterate = true });
    defer evals_dir.close();

    var walker = try evals_dir.walk(allocator);
    defer walker.deinit();

    var seen_ids = std.StringHashMap(void).init(allocator);
    defer seen_ids.deinit();

    var items = std.ArrayList(EvalDefinition){};
    defer items.deinit(allocator);

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".json")) continue;

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_path, entry.path });
        defer allocator.free(full_path);

        const definition = try loadEvalDefinitionWithAllocator(allocator, arena.allocator(), dir, full_path);
        const gop = try seen_ids.getOrPut(definition.id);
        if (gop.found_existing) return error.DuplicateEvalId;
        try items.append(allocator, definition);
    }

    return .{
        .parent_allocator = allocator,
        .arena = arena,
        .items = try arena.allocator().dupe(EvalDefinition, items.items),
    };
}

pub fn loadRegistryEvalDefinitions(
    allocator: std.mem.Allocator,
    registry_dir: std.fs.Dir,
) !LoadedEvalDefinitions {
    return loadAllEvalDefinitions(allocator, registry_dir, "evals");
}

pub fn loadRegistryEvalCases(
    allocator: std.mem.Allocator,
    registry_dir: std.fs.Dir,
    definition: EvalDefinition,
) !LoadedEvalCases {
    return loadEvalCases(allocator, registry_dir, definition.dataset_path);
}

pub fn loadEvalCases(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    path: []const u8,
) !LoadedEvalCases {
    try validateDatasetRelativePath(path);

    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer allocator.destroy(arena);
    errdefer arena.deinit();

    const raw = try dir.readFileAlloc(allocator, path, max_dataset_file_bytes);
    defer allocator.free(raw);

    var items = std.ArrayList(EvalCase){};
    defer items.deinit(allocator);

    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
            return error.InvalidJsonLines;
        };
        defer parsed.deinit();

        const eval_case = try parseEvalCase(arena.allocator(), parsed.value);
        try validateEvalCaseAttachments(dir, eval_case);
        try items.append(allocator, eval_case);
    }

    return .{
        .parent_allocator = allocator,
        .arena = arena,
        .items = try arena.allocator().dupe(EvalCase, items.items),
    };
}

fn loadEvalDefinitionWithAllocator(
    temp_allocator: std.mem.Allocator,
    arena_allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    path: []const u8,
) !EvalDefinition {
    const raw = try dir.readFileAlloc(temp_allocator, path, max_eval_file_bytes);
    defer temp_allocator.free(raw);

    var parsed = std.json.parseFromSlice(std.json.Value, temp_allocator, raw, .{}) catch {
        return error.InvalidEvalDefinitionJson;
    };
    defer parsed.deinit();

    const definition = try parseEvalDefinition(arena_allocator, parsed.value);
    validateDatasetPath(dir, definition.dataset_path) catch |err| switch (err) {
        error.FileNotFound => return error.MissingDatasetFile,
        else => return err,
    };

    return definition;
}

fn validateDatasetPath(
    dir: std.fs.Dir,
    dataset_path: []const u8,
) !void {
    try validateDatasetRelativePath(dataset_path);
    try dir.access(dataset_path, .{});
}

fn parseEvalDefinition(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !EvalDefinition {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidEvalDefinition,
    };

    const default_run_count = try parseRequiredU32(object, "default_run_count");
    if (default_run_count == 0) return error.InvalidEvalDefinition;

    return .{
        .id = try dupRequiredString(allocator, object, "id"),
        .group = try dupRequiredString(allocator, object, "group"),
        .description = try dupRequiredString(allocator, object, "description"),
        .dataset_path = try dupRequiredString(allocator, object, "dataset_path"),
        .split = try dupRequiredString(allocator, object, "split"),
        .matcher = try parseRequiredMatcher(allocator, object),
        .default_run_count = default_run_count,
        .service_allowlist = try parseOptionalStringList(allocator, object, "service_allowlist"),
        .tools = try parseOptionalTools(allocator, object, "tools"),
    };
}

fn parseEvalCase(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !EvalCase {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidEvalCase,
    };

    return .{
        .id = try dupRequiredString(allocator, object, "id"),
        .input = try dupRequiredString(allocator, object, "input"),
        .ideal = try dupOptionalString(allocator, object, "ideal"),
        .expected_tool_calls = try parseOptionalExpectedToolCalls(
            allocator,
            object,
            "expected_tool_calls",
        ),
        .attachments = try parseOptionalAttachments(allocator, object, "attachments"),
    };
}

fn parseRequiredMatcher(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) !matchers.MatcherConfig {
    const value = object.get("matcher") orelse return error.InvalidEvalDefinition;
    return matchers.parseMatcherConfig(allocator, value) catch {
        return error.InvalidEvalDefinition;
    };
}

fn parseOptionalTools(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    field_name: []const u8,
) !?[]const ToolDefinition {
    const value = object.get(field_name) orelse return null;

    const array = switch (value) {
        .array => |array| array,
        else => return error.InvalidEvalDefinition,
    };

    var items = std.ArrayList(ToolDefinition){};
    defer items.deinit(allocator);

    for (array.items) |item| {
        const tool_object = switch (item) {
            .object => |obj| obj,
            else => return error.InvalidEvalDefinition,
        };

        const parameters_json = try dupRequiredString(allocator, tool_object, "parameters_json");
        try validateToolParametersJson(allocator, parameters_json);

        try items.append(allocator, .{
            .name = try dupRequiredString(allocator, tool_object, "name"),
            .description = try dupRequiredString(allocator, tool_object, "description"),
            .parameters_json = parameters_json,
        });
    }

    return try allocator.dupe(ToolDefinition, items.items);
}

fn validateToolParametersJson(
    allocator: std.mem.Allocator,
    parameters_json: []const u8,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, parameters_json, .{}) catch {
        return error.InvalidEvalDefinition;
    };
    defer parsed.deinit();

    switch (parsed.value) {
        .object => {},
        else => return error.InvalidEvalDefinition,
    }
}

fn parseOptionalExpectedToolCalls(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    field_name: []const u8,
) !?[]const ExpectedToolCall {
    const value = object.get(field_name) orelse return null;

    const array = switch (value) {
        .array => |array| array,
        else => return error.InvalidEvalCase,
    };
    if (array.items.len == 0) return error.InvalidEvalCase;

    var items = std.ArrayList(ExpectedToolCall){};
    defer items.deinit(allocator);

    for (array.items) |item| {
        const call_object = switch (item) {
            .object => |obj| obj,
            else => return error.InvalidEvalCase,
        };

        try items.append(allocator, .{
            .name = try dupRequiredString(allocator, call_object, "name"),
            .arguments_json = try dupOptionalString(allocator, call_object, "arguments_json"),
        });
    }

    return try allocator.dupe(ExpectedToolCall, items.items);
}

fn parseOptionalAttachments(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    field_name: []const u8,
) !?[]const Attachment {
    const value = object.get(field_name) orelse return null;

    const array = switch (value) {
        .array => |array| array,
        else => return error.InvalidEvalCase,
    };

    var items = std.ArrayList(Attachment){};
    defer items.deinit(allocator);

    for (array.items) |item| {
        const attachment_object = switch (item) {
            .object => |obj| obj,
            else => return error.InvalidEvalCase,
        };

        const path = try dupRequiredString(allocator, attachment_object, "path");
        try validateAttachmentPath(path);
        const kind = try parseAttachmentKind(attachment_object);

        const mime_type = try dupOptionalString(allocator, attachment_object, "mime_type");
        const resolved_mime_type = mime_type orelse inferAttachmentMimeType(path);
        if (resolved_mime_type == null) {
            return error.UnsupportedAttachmentType;
        }
        try validateAttachmentKindMime(kind, resolved_mime_type.?);

        try items.append(allocator, .{
            .kind = kind,
            .path = path,
            .mime_type = mime_type,
            .label = try dupOptionalString(allocator, attachment_object, "label"),
        });
    }

    return try allocator.dupe(Attachment, items.items);
}

fn parseAttachmentKind(object: std.json.ObjectMap) !AttachmentKind {
    const value = object.get("kind") orelse return error.InvalidEvalCase;
    const text = switch (value) {
        .string => |text| std.mem.trim(u8, text, " \t\r\n"),
        else => return error.InvalidEvalCase,
    };
    if (std.mem.eql(u8, text, "image")) return .image;
    if (std.mem.eql(u8, text, "file")) return .file;
    return error.InvalidEvalCase;
}

fn validateEvalCaseAttachments(dir: std.fs.Dir, eval_case: EvalCase) !void {
    const attachments = eval_case.attachments orelse return;
    for (attachments) |attachment| {
        const stat = dir.statFile(attachment.path) catch |err| switch (err) {
            error.FileNotFound => return error.MissingAttachmentFile,
            else => return err,
        };
        if (stat.size > max_attachment_bytes) return error.AttachmentTooLarge;
    }
}

fn validateAttachmentPath(path: []const u8) !void {
    if (!isSafeRelativePath(path)) return error.InvalidAttachmentPath;
}

fn validateDatasetRelativePath(path: []const u8) !void {
    if (!isSafeRelativePath(path)) return error.InvalidDatasetPath;
}

fn isSafeRelativePath(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) return false;
    var parts = std.mem.splitAny(u8, path, "/\\");
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) {
            return false;
        }
    }
    return true;
}

fn validateAttachmentKindMime(kind: AttachmentKind, mime_type: []const u8) !void {
    const image_mime = isImageAttachmentMimeType(mime_type);
    switch (kind) {
        .image => if (!image_mime) return error.InvalidAttachmentMimeType,
        .file => if (image_mime) return error.InvalidAttachmentMimeType,
    }
}

fn isImageAttachmentMimeType(mime_type: []const u8) bool {
    return std.mem.eql(u8, mime_type, "image/png") or
        std.mem.eql(u8, mime_type, "image/jpeg") or
        std.mem.eql(u8, mime_type, "image/webp");
}

pub fn inferAttachmentMimeType(path: []const u8) ?[]const u8 {
    const extension = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(extension, ".png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(extension, ".jpg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(extension, ".jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(extension, ".webp")) return "image/webp";
    if (std.ascii.eqlIgnoreCase(extension, ".txt")) return "text/plain";
    if (std.ascii.eqlIgnoreCase(extension, ".md")) return "text/markdown";
    if (std.ascii.eqlIgnoreCase(extension, ".json")) return "application/json";
    if (std.ascii.eqlIgnoreCase(extension, ".jsonl")) return "application/x-ndjson";
    if (std.ascii.eqlIgnoreCase(extension, ".csv")) return "text/csv";
    if (std.ascii.eqlIgnoreCase(extension, ".zig")) return "text/plain";
    if (std.ascii.eqlIgnoreCase(extension, ".py")) return "text/x-python";
    if (std.ascii.eqlIgnoreCase(extension, ".js")) return "text/javascript";
    if (std.ascii.eqlIgnoreCase(extension, ".ts")) return "text/typescript";
    return null;
}

fn dupRequiredString(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    field_name: []const u8,
) ![]const u8 {
    const value = object.get(field_name) orelse return error.InvalidEvalDefinition;
    const text = switch (value) {
        .string => |text| text,
        else => return error.InvalidEvalDefinition,
    };
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidEvalDefinition;
    return allocator.dupe(u8, trimmed);
}

fn dupOptionalString(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    field_name: []const u8,
) !?[]const u8 {
    const value = object.get(field_name) orelse return null;
    const text = switch (value) {
        .string => |text| text,
        else => return error.InvalidEvalCase,
    };
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

fn parseRequiredU32(
    object: std.json.ObjectMap,
    field_name: []const u8,
) !u32 {
    const value = object.get(field_name) orelse return error.InvalidEvalDefinition;
    const integer = switch (value) {
        .integer => |integer| integer,
        else => return error.InvalidEvalDefinition,
    };
    if (integer <= 0) return error.InvalidEvalDefinition;
    return std.math.cast(u32, integer) orelse error.InvalidEvalDefinition;
}

fn parseOptionalStringList(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    field_name: []const u8,
) !?[]const []const u8 {
    const value = object.get(field_name) orelse return null;
    const entries = switch (value) {
        .array => |array| array.items,
        else => return error.InvalidEvalDefinition,
    };

    var items = std.ArrayList([]const u8){};
    defer items.deinit(allocator);

    for (entries) |entry| {
        const text = switch (entry) {
            .string => |text| text,
            else => return error.InvalidEvalDefinition,
        };
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return error.InvalidEvalDefinition;
        try items.append(allocator, try allocator.dupe(u8, trimmed));
    }

    return try allocator.dupe([]const u8, items.items);
}

test "EvalDefinition and EvalCase store registry metadata" {
    const services = [_][]const u8{ "product-api", "staging-api" };
    const definition = EvalDefinition{
        .id = "smoke.reply_ok",
        .group = "smoke",
        .description = "Checks a simple OK response.",
        .dataset_path = "registry/data/smoke/reply_ok/test.jsonl",
        .split = "test",
        .matcher = .{
            .exact_match = .{},
        },
        .default_run_count = 3,
        .service_allowlist = services[0..],
    };
    const eval_case = EvalCase{
        .id = "case-1",
        .input = "Reply with OK",
        .ideal = "OK",
    };

    try std.testing.expectEqualStrings("smoke", definition.group);
    try std.testing.expect(definition.matcher == .exact_match);
    try std.testing.expectEqual(@as(u32, 3), definition.default_run_count);
    try std.testing.expectEqual(@as(usize, 2), definition.service_allowlist.?.len);
    try std.testing.expectEqualStrings("OK", eval_case.ideal.?);
}

test "loadEvalDefinition loads one valid eval file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("registry/evals/smoke");
    try tmp.dir.makePath("registry/data/smoke/reply_ok");
    try tmp.dir.writeFile(.{
        .sub_path = "registry/data/smoke/reply_ok/test.jsonl",
        .data = "{\"id\":\"case-1\",\"input\":\"Reply with OK\",\"ideal\":\"OK\"}\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "registry/evals/smoke/reply_ok.json",
        .data =
        \\{
        \\  "id": "smoke.reply_ok",
        \\  "group": "smoke",
        \\  "description": "Checks a simple OK response.",
        \\  "dataset_path": "registry/data/smoke/reply_ok/test.jsonl",
        \\  "split": "test",
        \\  "matcher": { "kind": "exact_match" },
        \\  "default_run_count": 2
        \\}
        ,
    });

    var loaded = try loadEvalDefinition(
        std.testing.allocator,
        tmp.dir,
        "registry/evals/smoke/reply_ok.json",
    );
    defer loaded.deinit();

    try std.testing.expectEqualStrings("smoke.reply_ok", loaded.value.id);
    try std.testing.expect(loaded.value.matcher == .exact_match);
}

test "loadAllEvalDefinitions discovers grouped eval files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("registry/evals/smoke");
    try tmp.dir.makePath("registry/evals/structured_output");
    try tmp.dir.makePath("registry/data/smoke/reply_ok");
    try tmp.dir.makePath("registry/data/structured_output/basic_json");

    try tmp.dir.writeFile(.{
        .sub_path = "registry/data/smoke/reply_ok/test.jsonl",
        .data = "{\"id\":\"case-1\",\"input\":\"Reply with OK\",\"ideal\":\"OK\"}\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "registry/data/structured_output/basic_json/test.jsonl",
        .data = "{\"id\":\"case-1\",\"input\":\"Return JSON\",\"ideal\":\"{}\"}\n",
    });

    try tmp.dir.writeFile(.{
        .sub_path = "registry/evals/smoke/reply_ok.json",
        .data =
        \\{
        \\  "id": "smoke.reply_ok",
        \\  "group": "smoke",
        \\  "description": "Checks a simple OK response.",
        \\  "dataset_path": "registry/data/smoke/reply_ok/test.jsonl",
        \\  "split": "test",
        \\  "matcher": { "kind": "exact_match" },
        \\  "default_run_count": 2
        \\}
        ,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "registry/evals/structured_output/basic_json.json",
        .data =
        \\{
        \\  "id": "structured_output.basic_json",
        \\  "group": "structured_output",
        \\  "description": "Checks JSON responses.",
        \\  "dataset_path": "registry/data/structured_output/basic_json/test.jsonl",
        \\  "split": "test",
        \\  "matcher": { "kind": "json_fields", "required_fields": ["answer"] },
        \\  "default_run_count": 1
        \\}
        ,
    });

    var loaded = try loadAllEvalDefinitions(std.testing.allocator, tmp.dir, "registry/evals");
    defer loaded.deinit();

    try std.testing.expectEqual(@as(usize, 2), loaded.items.len);
}

test "loadAllEvalDefinitions rejects duplicate eval ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("registry/evals/smoke");
    try tmp.dir.makePath("registry/evals/other");
    try tmp.dir.makePath("registry/data/smoke/reply_ok");
    try tmp.dir.makePath("registry/data/other/reply_ok");

    try tmp.dir.writeFile(.{
        .sub_path = "registry/data/smoke/reply_ok/test.jsonl",
        .data = "{\"id\":\"case-1\",\"input\":\"Reply with OK\",\"ideal\":\"OK\"}\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "registry/data/other/reply_ok/test.jsonl",
        .data = "{\"id\":\"case-1\",\"input\":\"Reply with OK\",\"ideal\":\"OK\"}\n",
    });

    const duplicate_json =
        \\{
        \\  "id": "duplicate.eval",
        \\  "group": "smoke",
        \\  "description": "Duplicate id.",
        \\  "dataset_path": "registry/data/smoke/reply_ok/test.jsonl",
        \\  "split": "test",
        \\  "matcher": { "kind": "exact_match" },
        \\  "default_run_count": 1
        \\}
    ;
    try tmp.dir.writeFile(.{
        .sub_path = "registry/evals/smoke/one.json",
        .data = duplicate_json,
    });
    try tmp.dir.writeFile(.{
        .sub_path = "registry/evals/other/two.json",
        .data =
        \\{
        \\  "id": "duplicate.eval",
        \\  "group": "other",
        \\  "description": "Duplicate id.",
        \\  "dataset_path": "registry/data/other/reply_ok/test.jsonl",
        \\  "split": "test",
        \\  "matcher": { "kind": "exact_match" },
        \\  "default_run_count": 1
        \\}
        ,
    });

    try std.testing.expectError(
        error.DuplicateEvalId,
        loadAllEvalDefinitions(std.testing.allocator, tmp.dir, "registry/evals"),
    );
}

test "loadEvalDefinition rejects missing dataset files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("registry/evals/smoke");
    try tmp.dir.writeFile(.{
        .sub_path = "registry/evals/smoke/reply_ok.json",
        .data =
        \\{
        \\  "id": "smoke.reply_ok",
        \\  "group": "smoke",
        \\  "description": "Checks a simple OK response.",
        \\  "dataset_path": "registry/data/smoke/reply_ok/test.jsonl",
        \\  "split": "test",
        \\  "matcher": { "kind": "exact_match" },
        \\  "default_run_count": 2
        \\}
        ,
    });

    try std.testing.expectError(
        error.MissingDatasetFile,
        loadEvalDefinition(std.testing.allocator, tmp.dir, "registry/evals/smoke/reply_ok.json"),
    );
}

test "loadEvalDefinition rejects unsafe dataset paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("registry/evals/smoke");
    try tmp.dir.writeFile(.{
        .sub_path = "registry/evals/smoke/reply_ok.json",
        .data =
        \\{
        \\  "id": "smoke.reply_ok",
        \\  "group": "smoke",
        \\  "description": "Checks a simple OK response.",
        \\  "dataset_path": "../secret.jsonl",
        \\  "split": "test",
        \\  "matcher": { "kind": "exact_match" },
        \\  "default_run_count": 2
        \\}
        ,
    });

    try std.testing.expectError(
        error.InvalidDatasetPath,
        loadEvalDefinition(std.testing.allocator, tmp.dir, "registry/evals/smoke/reply_ok.json"),
    );
}

test "loadEvalDefinition rejects absolute dataset paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("registry/evals/smoke");
    try tmp.dir.writeFile(.{
        .sub_path = "registry/evals/smoke/reply_ok.json",
        .data =
        \\{
        \\  "id": "smoke.reply_ok",
        \\  "group": "smoke",
        \\  "description": "Checks a simple OK response.",
        \\  "dataset_path": "/tmp/secret.jsonl",
        \\  "split": "test",
        \\  "matcher": { "kind": "exact_match" },
        \\  "default_run_count": 2
        \\}
        ,
    });

    try std.testing.expectError(
        error.InvalidDatasetPath,
        loadEvalDefinition(std.testing.allocator, tmp.dir, "registry/evals/smoke/reply_ok.json"),
    );
}

test "loadEvalCases loads JSONL datasets and ignores blank lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("registry/data/smoke/reply_ok");
    try tmp.dir.writeFile(.{
        .sub_path = "registry/data/smoke/reply_ok/test.jsonl",
        .data =
        \\{"id":"case-1","input":"Reply with OK","ideal":"OK"}
        \\
        \\{"id":"case-2","input":"Reply with YES","ideal":"YES"}
        ,
    });

    var loaded = try loadEvalCases(
        std.testing.allocator,
        tmp.dir,
        "registry/data/smoke/reply_ok/test.jsonl",
    );
    defer loaded.deinit();

    try std.testing.expectEqual(@as(usize, 2), loaded.items.len);
    try std.testing.expectEqualStrings("case-2", loaded.items[1].id);
}

test "loadEvalCases rejects unsafe dataset paths directly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectError(
        error.InvalidDatasetPath,
        loadEvalCases(std.testing.allocator, tmp.dir, "../secret.jsonl"),
    );
}

test "loadEvalCases rejects absolute dataset paths directly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectError(
        error.InvalidDatasetPath,
        loadEvalCases(std.testing.allocator, tmp.dir, "/tmp/secret.jsonl"),
    );
}

test "loadEvalCases rejects malformed JSONL lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("registry/data/smoke/reply_ok");
    try tmp.dir.writeFile(.{
        .sub_path = "registry/data/smoke/reply_ok/test.jsonl",
        .data =
        \\{"id":"case-1","input":"Reply with OK","ideal":"OK"}
        \\not json
        ,
    });

    try std.testing.expectError(
        error.InvalidJsonLines,
        loadEvalCases(std.testing.allocator, tmp.dir, "registry/data/smoke/reply_ok/test.jsonl"),
    );
}

test "example eval registry loads definitions and datasets" {
    var registry_dir = try std.fs.cwd().openDir("examples/registry", .{});
    defer registry_dir.close();

    var loaded = try loadRegistryEvalDefinitions(
        std.testing.allocator,
        registry_dir,
    );
    defer loaded.deinit();

    try std.testing.expectEqual(@as(usize, 6), loaded.items.len);

    var saw_smoke = false;
    var saw_quality = false;
    var saw_structured_output = false;
    var saw_multimodal_text = false;
    var saw_multimodal_image = false;
    var total_cases: usize = 0;

    for (loaded.items) |definition| {
        if (std.mem.eql(u8, definition.id, "smoke.reply_ok")) {
            saw_smoke = true;
            try std.testing.expect(definition.matcher == .exact_match);
            try std.testing.expectEqualStrings("data/smoke/reply_ok/test.jsonl", definition.dataset_path);
            try std.testing.expectEqual(@as(usize, 2), definition.service_allowlist.?.len);
        }
        if (std.mem.eql(u8, definition.id, "quality.helpful_summary")) {
            saw_quality = true;
            try std.testing.expect(definition.matcher == .model_grade);
            try std.testing.expectEqualStrings("judge", definition.matcher.model_grade.judge_service);
            try std.testing.expectEqual(@as(usize, 2), definition.service_allowlist.?.len);
        }
        if (std.mem.eql(u8, definition.id, "structured_output.required_answer_json")) {
            saw_structured_output = true;
            try std.testing.expect(definition.matcher == .json_fields);
            try std.testing.expectEqualStrings("answer", definition.matcher.json_fields.required_fields[0]);
        }
        if (std.mem.eql(u8, definition.id, "multimodal.release_notes")) {
            saw_multimodal_text = true;
            try std.testing.expect(definition.matcher == .includes);
        }
        if (std.mem.eql(u8, definition.id, "multimodal.image_object")) {
            saw_multimodal_image = true;
            try std.testing.expect(definition.matcher == .includes);
        }

        var cases = try loadRegistryEvalCases(
            std.testing.allocator,
            registry_dir,
            definition,
        );
        defer cases.deinit();
        total_cases += cases.items.len;
        if (std.mem.startsWith(u8, definition.id, "multimodal.")) {
            try std.testing.expect(cases.items[0].attachments != null);
        }
    }

    try std.testing.expect(saw_smoke);
    try std.testing.expect(saw_quality);
    try std.testing.expect(saw_structured_output);
    try std.testing.expect(saw_multimodal_text);
    try std.testing.expect(saw_multimodal_image);
    try std.testing.expectEqual(@as(usize, 9), total_cases);
}

test "parseEvalDefinition supports tool definitions" {
    const json =
        \\{
        \\  "id": "tools.search_web",
        \\  "group": "tools",
        \\  "description": "tool eval",
        \\  "dataset_path": "data/tools/search_web/test.jsonl",
        \\  "split": "test",
        \\  "tools": [
        \\    {
        \\      "name": "search_web",
        \\      "description": "Search the web",
        \\      "parameters_json": "{\"type\":\"object\"}"
        \\    }
        \\  ],
        \\  "matcher": {
        \\    "kind": "tool_call"
        \\  },
        \\  "default_run_count": 1
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parsed_json = try std.json.parseFromSlice(
        std.json.Value,
        arena.allocator(),
        json,
        .{},
    );
    defer parsed_json.deinit();

    const parsed = try parseEvalDefinition(
        arena.allocator(),
        parsed_json.value,
    );

    try std.testing.expect(parsed.tools != null);

    const tools = parsed.tools.?;

    try std.testing.expectEqual(@as(usize, 1), tools.len);
    try std.testing.expectEqualStrings("search_web", tools[0].name);
}

test "parseEvalDefinition rejects malformed tool parameters json" {
    const json =
        \\{
        \\  "id": "tools.search_web",
        \\  "group": "tools",
        \\  "description": "tool eval",
        \\  "dataset_path": "data/tools/search_web/test.jsonl",
        \\  "split": "test",
        \\  "tools": [
        \\    {
        \\      "name": "search_web",
        \\      "description": "Search the web",
        \\      "parameters_json": "{invalid json}"
        \\    }
        \\  ],
        \\  "matcher": {
        \\    "kind": "tool_call"
        \\  },
        \\  "default_run_count": 1
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parsed_json = try std.json.parseFromSlice(
        std.json.Value,
        arena.allocator(),
        json,
        .{},
    );
    defer parsed_json.deinit();

    try std.testing.expectError(
        error.InvalidEvalDefinition,
        parseEvalDefinition(arena.allocator(), parsed_json.value),
    );
}

test "parseEvalDefinition rejects non-object tool parameters json" {
    const json =
        \\{
        \\  "id": "tools.search_web",
        \\  "group": "tools",
        \\  "description": "tool eval",
        \\  "dataset_path": "data/tools/search_web/test.jsonl",
        \\  "split": "test",
        \\  "tools": [
        \\    {
        \\      "name": "search_web",
        \\      "description": "Search the web",
        \\      "parameters_json": "[]"
        \\    }
        \\  ],
        \\  "matcher": {
        \\    "kind": "tool_call"
        \\  },
        \\  "default_run_count": 1
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parsed_json = try std.json.parseFromSlice(
        std.json.Value,
        arena.allocator(),
        json,
        .{},
    );
    defer parsed_json.deinit();

    try std.testing.expectError(
        error.InvalidEvalDefinition,
        parseEvalDefinition(arena.allocator(), parsed_json.value),
    );
}

test "parseEvalCase supports expected tool calls" {
    const json =
        \\{
        \\  "id": "case-1",
        \\  "input": "Search weather",
        \\  "expected_tool_calls": [
        \\    {
        \\      "name": "search_web",
        \\      "arguments_json": "{\"query\":\"weather melbourne\"}"
        \\    }
        \\  ]
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parsed_json = try std.json.parseFromSlice(
        std.json.Value,
        arena.allocator(),
        json,
        .{},
    );
    defer parsed_json.deinit();

    const parsed = try parseEvalCase(
        arena.allocator(),
        parsed_json.value,
    );

    try std.testing.expect(parsed.expected_tool_calls != null);

    const calls = parsed.expected_tool_calls.?;

    try std.testing.expectEqual(@as(usize, 1), calls.len);
    try std.testing.expectEqualStrings("search_web", calls[0].name);
}

test "parseEvalCase rejects empty expected tool calls" {
    const json =
        \\{
        \\  "id": "case-1",
        \\  "input": "Search weather",
        \\  "expected_tool_calls": []
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parsed_json = try std.json.parseFromSlice(
        std.json.Value,
        arena.allocator(),
        json,
        .{},
    );
    defer parsed_json.deinit();

    try std.testing.expectError(
        error.InvalidEvalCase,
        parseEvalCase(arena.allocator(), parsed_json.value),
    );
}

test "parseEvalCase supports file attachments" {
    const json =
        \\{
        \\  "id": "case-1",
        \\  "input": "Summarize the attachment",
        \\  "attachments": [
        \\    {
        \\      "kind": "file",
        \\      "path": "assets/changelogs/release.md",
        \\      "mime_type": "text/markdown",
        \\      "label": "release notes"
        \\    }
        \\  ]
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parsed_json = try std.json.parseFromSlice(
        std.json.Value,
        arena.allocator(),
        json,
        .{},
    );
    defer parsed_json.deinit();

    const parsed = try parseEvalCase(arena.allocator(), parsed_json.value);
    try std.testing.expect(parsed.attachments != null);

    const attachments = parsed.attachments.?;
    try std.testing.expectEqual(@as(usize, 1), attachments.len);
    try std.testing.expectEqual(AttachmentKind.file, attachments[0].kind);
    try std.testing.expectEqualStrings("assets/changelogs/release.md", attachments[0].path);
    try std.testing.expectEqualStrings("text/markdown", attachments[0].mime_type.?);
    try std.testing.expectEqualStrings("release notes", attachments[0].label.?);
}

test "loadEvalCases validates attachment files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("assets/changelogs");
    try tmp.dir.writeFile(.{
        .sub_path = "assets/changelogs/release.md",
        .data = "Retry support and parallel execution shipped.\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "cases.jsonl",
        .data = "{\"id\":\"case-1\",\"input\":\"Summarize\",\"attachments\":[{\"kind\":\"file\",\"path\":\"assets/changelogs/release.md\"}]}\n",
    });

    var loaded = try loadEvalCases(std.testing.allocator, tmp.dir, "cases.jsonl");
    defer loaded.deinit();

    try std.testing.expectEqual(@as(usize, 1), loaded.items.len);
    try std.testing.expectEqualStrings("text/markdown", inferAttachmentMimeType(loaded.items[0].attachments.?[0].path).?);
}

test "loadEvalCases rejects missing attachment files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "cases.jsonl",
        .data = "{\"id\":\"case-1\",\"input\":\"Summarize\",\"attachments\":[{\"kind\":\"file\",\"path\":\"assets/missing.md\"}]}\n",
    });

    try std.testing.expectError(
        error.MissingAttachmentFile,
        loadEvalCases(std.testing.allocator, tmp.dir, "cases.jsonl"),
    );
}

test "parseEvalCase rejects unsafe attachment paths" {
    const json =
        \\{
        \\  "id": "case-1",
        \\  "input": "Summarize",
        \\  "attachments": [
        \\    {
        \\      "kind": "file",
        \\      "path": "../secret.txt"
        \\    }
        \\  ]
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parsed_json = try std.json.parseFromSlice(
        std.json.Value,
        arena.allocator(),
        json,
        .{},
    );
    defer parsed_json.deinit();

    try std.testing.expectError(
        error.InvalidAttachmentPath,
        parseEvalCase(arena.allocator(), parsed_json.value),
    );
}

test "parseEvalCase rejects unsupported attachment extension without mime type" {
    const json =
        \\{
        \\  "id": "case-1",
        \\  "input": "Inspect",
        \\  "attachments": [
        \\    {
        \\      "kind": "file",
        \\      "path": "assets/archive.zip"
        \\    }
        \\  ]
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parsed_json = try std.json.parseFromSlice(
        std.json.Value,
        arena.allocator(),
        json,
        .{},
    );
    defer parsed_json.deinit();

    try std.testing.expectError(
        error.UnsupportedAttachmentType,
        parseEvalCase(arena.allocator(), parsed_json.value),
    );
}

test "parseEvalCase rejects image attachment with text mime type" {
    const json =
        \\{
        \\  "id": "case-1",
        \\  "input": "Inspect",
        \\  "attachments": [
        \\    {
        \\      "kind": "image",
        \\      "path": "assets/images/red_mug.png",
        \\      "mime_type": "text/plain"
        \\    }
        \\  ]
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parsed_json = try std.json.parseFromSlice(
        std.json.Value,
        arena.allocator(),
        json,
        .{},
    );
    defer parsed_json.deinit();

    try std.testing.expectError(
        error.InvalidAttachmentMimeType,
        parseEvalCase(arena.allocator(), parsed_json.value),
    );
}

test "parseEvalCase rejects file attachment with image mime type" {
    const json =
        \\{
        \\  "id": "case-1",
        \\  "input": "Inspect",
        \\  "attachments": [
        \\    {
        \\      "kind": "file",
        \\      "path": "assets/images/red_mug.png",
        \\      "mime_type": "image/png"
        \\    }
        \\  ]
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parsed_json = try std.json.parseFromSlice(
        std.json.Value,
        arena.allocator(),
        json,
        .{},
    );
    defer parsed_json.deinit();

    try std.testing.expectError(
        error.InvalidAttachmentMimeType,
        parseEvalCase(arena.allocator(), parsed_json.value),
    );
}
