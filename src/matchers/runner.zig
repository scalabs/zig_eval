const std = @import("std");
const matchers = @import("root.zig");

pub const MatchResult = struct {
    passed: bool,
    score: f64,
    reason: ?[]const u8 = null,
};

pub fn evaluate(
    allocator: std.mem.Allocator,
    config: matchers.MatcherConfig,
    output: []const u8,
    ideal: ?[]const u8,
) !MatchResult {
    switch (config) {
        .exact_match => |opts| {
            const expected_raw = ideal orelse "";

            const actual = if (opts.trim_whitespace)
                std.mem.trim(u8, output, " \t\r\n")
            else
                output;

            const expected = if (opts.trim_whitespace)
                std.mem.trim(u8, expected_raw, " \t\r\n")
            else
                expected_raw;

            const ok = if (opts.case_sensitive)
                std.mem.eql(u8, actual, expected)
            else
                std.ascii.eqlIgnoreCase(actual, expected);

            return .{
                .passed = ok,
                .score = if (ok) 1.0 else 0.0,
                .reason = if (ok) null else "exact_match_failed",
            };
        },

        .includes => |opts| {
            const expected_raw = ideal orelse "";

            const actual = if (opts.trim_whitespace)
                std.mem.trim(u8, output, " \t\r\n")
            else
                output;

            const expected = if (opts.trim_whitespace)
                std.mem.trim(u8, expected_raw, " \t\r\n")
            else
                expected_raw;

            const ok = if (opts.case_sensitive)
                std.mem.indexOf(u8, actual, expected) != null
            else
                indexOfIgnoreCase(actual, expected) != null;

            return .{
                .passed = ok,
                .score = if (ok) 1.0 else 0.0,
                .reason = if (ok) null else "includes_failed",
            };
        },

        .json_fields => |cfg| {
            var parsed = std.json.parseFromSlice(
                std.json.Value,
                allocator,
                output,
                .{},
            ) catch {
                return .{
                    .passed = false,
                    .score = 0.0,
                    .reason = "invalid_json",
                };
            };
            defer parsed.deinit();

            const obj = switch (parsed.value) {
                .object => |object| object,
                else => {
                    return .{
                        .passed = false,
                        .score = 0.0,
                        .reason = "json_not_object",
                    };
                },
            };

            for (cfg.required_fields) |field| {
                if (!obj.contains(field)) {
                    return .{
                        .passed = false,
                        .score = 0.0,
                        .reason = "missing_required_json_field",
                    };
                }
            }

            return .{
                .passed = true,
                .score = 1.0,
                .reason = null,
            };
        },
    }
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) {
            return i;
        }
    }

    return null;
}

test "exact_match passes when output equals ideal" {
    const config = matchers.MatcherConfig{
        .exact_match = .{
            .case_sensitive = true,
            .trim_whitespace = true,
        },
    };

    const result = try evaluate(
        std.testing.allocator,
        config,
        " OK ",
        "OK",
    );

    try std.testing.expect(result.passed);
    try std.testing.expectEqual(@as(f64, 1.0), result.score);
}

test "includes passes when output contains ideal" {
    const config = matchers.MatcherConfig{
        .includes = .{
            .case_sensitive = false,
            .trim_whitespace = true,
        },
    };

    const result = try evaluate(
        std.testing.allocator,
        config,
        "The answer is Paris.",
        "paris",
    );

    try std.testing.expect(result.passed);
}

test "json_fields passes when all fields exist" {
    const fields = [_][]const u8{ "answer", "score" };

    const config = matchers.MatcherConfig{
        .json_fields = .{
            .required_fields = fields[0..],
        },
    };

    const result = try evaluate(
        std.testing.allocator,
        config,
        "{\"answer\":\"yes\",\"score\":1}",
        null,
    );

    try std.testing.expect(result.passed);
}

test "json_fields fails on invalid json" {
    const fields = [_][]const u8{ "answer" };

    const config = matchers.MatcherConfig{
        .json_fields = .{
            .required_fields = fields[0..],
        },
    };

    const result = try evaluate(
        std.testing.allocator,
        config,
        "not json",
        null,
    );

    try std.testing.expect(!result.passed);
    try std.testing.expectEqualStrings("invalid_json", result.reason.?);
}