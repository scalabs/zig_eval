const std = @import("std");
const matchers = @import("../matchers/root.zig");

const max_eval_file_bytes = 1024 * 1024;
const max_dataset_file_bytes = 8 * 1024 * 1024;

pub const EvalDefinition = struct {
    id: []const u8,
    group: []const u8,
    description: []const u8,
    dataset_path: []const u8,
    split: []const u8,
    matcher: matchers.MatcherConfig,
    default_run_count: u32,
    service_allowlist: ?[]const []const u8 = null,
};

pub const EvalCase = struct {
    id: []const u8,
    input: []const u8,
    ideal: ?[]const u8 = null,
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

pub fn loadEvalCases(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    path: []const u8,
) !LoadedEvalCases {
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

        try items.append(allocator, try parseEvalCase(arena.allocator(), parsed.value));
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
