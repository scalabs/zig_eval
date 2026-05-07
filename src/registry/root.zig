const std = @import("std");
const matchers = @import("../matchers/root.zig");

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

test "EvalDefinition and EvalCase store registry metadata" {
    const services = [_][]const u8{ "local-router", "bedrock" };
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
