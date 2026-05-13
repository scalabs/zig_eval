const std = @import("std");

pub const RunResult = struct {
    group: []const u8,
    eval_id: []const u8,
    service_name: []const u8,
    model: []const u8,
    run_index: u32,
    case_id: []const u8,
    output: []const u8,
    passed: bool,
    score: f64,
    failure_reason: ?[]const u8 = null,
    latency_ms: u64,
};

test "RunResult represents one evaluated case" {
    const result = RunResult{
        .group = "structured_output",
        .eval_id = "json.basic",
        .service_name = "product-api",
        .model = "gpt-4.1-mini",
        .run_index = 1,
        .case_id = "case-7",
        .output = "{\"answer\":\"OK\"}",
        .passed = true,
        .score = 1.0,
        .failure_reason = null,
        .latency_ms = 124,
    };

    try std.testing.expect(result.passed);
    try std.testing.expectEqual(@as(f64, 1.0), result.score);
    try std.testing.expectEqual(@as(u64, 124), result.latency_ms);
}
