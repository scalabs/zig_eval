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
