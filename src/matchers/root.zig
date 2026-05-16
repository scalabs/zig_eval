const std = @import("std");

pub const MatcherKind = enum {
    exact_match,
    includes,
    json_fields,
};

pub const TextMatchOptions = struct {
    case_sensitive: bool = true,
    trim_whitespace: bool = true,
};

pub const JsonFieldsMatcherConfig = struct {
    required_fields: []const []const u8,
};

pub const MatcherConfig = union(MatcherKind) {
    exact_match: TextMatchOptions,
    includes: TextMatchOptions,
    json_fields: JsonFieldsMatcherConfig,
};

pub const MatchOutcome = struct {
    passed: bool,
    score: f64,
    failure_reason: ?[]const u8 = null,
};

pub fn parseMatcherConfig(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !MatcherConfig {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidMatcherConfig,
    };

    const kind_text = switch (object.get("kind") orelse return error.InvalidMatcherConfig) {
        .string => |text| text,
        else => return error.InvalidMatcherConfig,
    };

    if (std.mem.eql(u8, kind_text, "exact_match")) {
        try validateFields(object, &.{ "kind", "case_sensitive", "trim_whitespace" });
        return .{
            .exact_match = .{
                .case_sensitive = try parseOptionalBool(object, "case_sensitive", true),
                .trim_whitespace = try parseOptionalBool(object, "trim_whitespace", true),
            },
        };
    }

    if (std.mem.eql(u8, kind_text, "includes")) {
        try validateFields(object, &.{ "kind", "case_sensitive", "trim_whitespace" });
        return .{
            .includes = .{
                .case_sensitive = try parseOptionalBool(object, "case_sensitive", true),
                .trim_whitespace = try parseOptionalBool(object, "trim_whitespace", true),
            },
        };
    }

    if (std.mem.eql(u8, kind_text, "json_fields")) {
        try validateFields(object, &.{ "kind", "required_fields" });
        return .{
            .json_fields = .{
                .required_fields = try parseRequiredFields(allocator, object),
            },
        };
    }

    return error.InvalidMatcherConfig;
}

pub fn evaluate(
    allocator: std.mem.Allocator,
    matcher: MatcherConfig,
    output: []const u8,
    ideal: ?[]const u8,
) !MatchOutcome {
    return switch (matcher) {
        .exact_match => |options| evaluateExactMatch(options, output, ideal),
        .includes => |options| evaluateIncludes(options, output, ideal),
        .json_fields => |config| evaluateJsonFields(allocator, config, output),
    };
}

fn evaluateExactMatch(
    options: TextMatchOptions,
    output: []const u8,
    ideal: ?[]const u8,
) MatchOutcome {
    const expected = ideal orelse return failed("missing ideal");
    const normalized_output = normalizeText(output, options);
    const normalized_expected = normalizeText(expected, options);
    if (textEquals(normalized_output, normalized_expected, options.case_sensitive)) {
        return passed();
    }
    return failed("output did not exactly match ideal");
}

fn evaluateIncludes(
    options: TextMatchOptions,
    output: []const u8,
    ideal: ?[]const u8,
) MatchOutcome {
    const expected = ideal orelse return failed("missing ideal");
    const normalized_output = normalizeText(output, options);
    const normalized_expected = normalizeText(expected, options);
    if (textContains(normalized_output, normalized_expected, options.case_sensitive)) {
        return passed();
    }
    return failed("output did not include ideal");
}

fn evaluateJsonFields(
    allocator: std.mem.Allocator,
    config: JsonFieldsMatcherConfig,
    output: []const u8,
) !MatchOutcome {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, output, .{}) catch {
        return failed("invalid json output");
    };
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |object| object,
        else => return failed("json output is not an object"),
    };

    for (config.required_fields) |field| {
        if (object.get(field) == null) return failed("missing required json field");
    }
    return passed();
}

fn normalizeText(text: []const u8, options: TextMatchOptions) []const u8 {
    if (!options.trim_whitespace) return text;
    return std.mem.trim(u8, text, " \t\r\n");
}

fn textEquals(a: []const u8, b: []const u8, case_sensitive: bool) bool {
    if (case_sensitive) return std.mem.eql(u8, a, b);
    if (a.len != b.len) return false;
    for (a, b) |a_char, b_char| {
        if (std.ascii.toLower(a_char) != std.ascii.toLower(b_char)) return false;
    }
    return true;
}

fn textContains(haystack: []const u8, needle: []const u8, case_sensitive: bool) bool {
    if (case_sensitive) return std.mem.indexOf(u8, haystack, needle) != null;
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var index: usize = 0;
    while (index <= haystack.len - needle.len) : (index += 1) {
        if (textEquals(haystack[index .. index + needle.len], needle, false)) return true;
    }
    return false;
}

fn passed() MatchOutcome {
    return .{
        .passed = true,
        .score = 1.0,
    };
}

fn failed(reason: []const u8) MatchOutcome {
    return .{
        .passed = false,
        .score = 0.0,
        .failure_reason = reason,
    };
}

fn validateFields(
    object: std.json.ObjectMap,
    allowed_fields: []const []const u8,
) !void {
    var iter = object.iterator();
    while (iter.next()) |entry| {
        for (allowed_fields) |allowed| {
            if (std.mem.eql(u8, entry.key_ptr.*, allowed)) break;
        } else {
            return error.InvalidMatcherConfig;
        }
    }
}

fn parseOptionalBool(
    object: std.json.ObjectMap,
    field_name: []const u8,
    default_value: bool,
) !bool {
    const value = object.get(field_name) orelse return default_value;
    return switch (value) {
        .bool => |flag| flag,
        else => error.InvalidMatcherConfig,
    };
}

fn parseRequiredFields(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) ![]const []const u8 {
    const value = object.get("required_fields") orelse return error.InvalidMatcherConfig;
    const fields = switch (value) {
        .array => |array| array.items,
        else => return error.InvalidMatcherConfig,
    };
    if (fields.len == 0) return error.InvalidMatcherConfig;

    var items = std.ArrayList([]const u8){};
    defer items.deinit(allocator);

    for (fields) |field| {
        const text = switch (field) {
            .string => |text| text,
            else => return error.InvalidMatcherConfig,
        };
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return error.InvalidMatcherConfig;
        try items.append(allocator, try allocator.dupe(u8, trimmed));
    }

    return allocator.dupe([]const u8, items.items);
}

test "MatcherConfig supports all v1 matcher kinds" {
    const exact = MatcherConfig{
        .exact_match = .{
            .case_sensitive = true,
            .trim_whitespace = true,
        },
    };
    const includes = MatcherConfig{
        .includes = .{
            .case_sensitive = false,
            .trim_whitespace = true,
        },
    };
    const fields = [_][]const u8{ "answer", "score" };
    const json = MatcherConfig{
        .json_fields = .{
            .required_fields = fields[0..],
        },
    };

    try std.testing.expect(exact == .exact_match);
    try std.testing.expect(includes == .includes);
    try std.testing.expect(json == .json_fields);
    try std.testing.expectEqual(@as(usize, 2), json.json_fields.required_fields.len);
}

test "parseMatcherConfig parses all matcher kinds" {
    const samples = [_][]const u8{
        "{\"kind\":\"exact_match\",\"case_sensitive\":false}",
        "{\"kind\":\"includes\",\"trim_whitespace\":false}",
        "{\"kind\":\"json_fields\",\"required_fields\":[\"answer\",\"score\"]}",
    };

    for (samples) |sample| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), sample, .{});
        defer parsed.deinit();

        const config = try parseMatcherConfig(arena.allocator(), parsed.value);
        switch (config) {
            .exact_match, .includes, .json_fields => {},
        }
    }
}

test "parseMatcherConfig rejects empty required_fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        arena.allocator(),
        "{\"kind\":\"json_fields\",\"required_fields\":[]}",
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectError(
        error.InvalidMatcherConfig,
        parseMatcherConfig(arena.allocator(), parsed.value),
    );
}

test "parseMatcherConfig rejects unknown kinds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        arena.allocator(),
        "{\"kind\":\"fuzzy_match\"}",
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectError(
        error.InvalidMatcherConfig,
        parseMatcherConfig(arena.allocator(), parsed.value),
    );
}

test "evaluate exact_match passes with trimming" {
    const outcome = try evaluate(
        std.testing.allocator,
        .{ .exact_match = .{ .case_sensitive = true, .trim_whitespace = true } },
        " OK\n",
        "OK",
    );

    try std.testing.expect(outcome.passed);
    try std.testing.expectEqual(@as(f64, 1.0), outcome.score);
}

test "evaluate exact_match honors case sensitivity" {
    const sensitive = try evaluate(
        std.testing.allocator,
        .{ .exact_match = .{ .case_sensitive = true, .trim_whitespace = true } },
        "ok",
        "OK",
    );
    const insensitive = try evaluate(
        std.testing.allocator,
        .{ .exact_match = .{ .case_sensitive = false, .trim_whitespace = true } },
        "ok",
        "OK",
    );

    try std.testing.expect(!sensitive.passed);
    try std.testing.expect(insensitive.passed);
}

test "evaluate includes honors case and trimming options" {
    const outcome = try evaluate(
        std.testing.allocator,
        .{ .includes = .{ .case_sensitive = false, .trim_whitespace = true } },
        "  Product is READY.  ",
        "ready",
    );

    try std.testing.expect(outcome.passed);
}

test "evaluate text matchers fail with missing ideal" {
    const outcome = try evaluate(
        std.testing.allocator,
        .{ .exact_match = .{} },
        "OK",
        null,
    );

    try std.testing.expect(!outcome.passed);
    try std.testing.expectEqualStrings("missing ideal", outcome.failure_reason.?);
}

test "evaluate json_fields passes when required fields exist" {
    const fields = [_][]const u8{ "answer", "score" };
    const outcome = try evaluate(
        std.testing.allocator,
        .{ .json_fields = .{ .required_fields = fields[0..] } },
        "{\"answer\":\"OK\",\"score\":1}",
        null,
    );

    try std.testing.expect(outcome.passed);
}

test "evaluate json_fields fails for invalid JSON" {
    const fields = [_][]const u8{"answer"};
    const outcome = try evaluate(
        std.testing.allocator,
        .{ .json_fields = .{ .required_fields = fields[0..] } },
        "not json",
        null,
    );

    try std.testing.expect(!outcome.passed);
    try std.testing.expectEqualStrings("invalid json output", outcome.failure_reason.?);
}

test "evaluate json_fields fails when required field is missing" {
    const fields = [_][]const u8{ "answer", "score" };
    const outcome = try evaluate(
        std.testing.allocator,
        .{ .json_fields = .{ .required_fields = fields[0..] } },
        "{\"answer\":\"OK\"}",
        null,
    );

    try std.testing.expect(!outcome.passed);
    try std.testing.expectEqualStrings("missing required json field", outcome.failure_reason.?);
}
