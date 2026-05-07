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
