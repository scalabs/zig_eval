const std = @import("std");

pub const AggregateCounts = struct {
    total_runs: usize,
    passed: usize,
    failed: usize,
};

pub const ModelReport = struct {
    model: []const u8,
    counts: AggregateCounts,
};

pub const ServiceReport = struct {
    service_name: []const u8,
    counts: AggregateCounts,
    models: []const ModelReport,
};

pub const EvalReport = struct {
    group: []const u8,
    eval_id: []const u8,
    counts: AggregateCounts,
    services: []const ServiceReport,
};

test "EvalReport stores grouped report shapes" {
    const model_reports = [_]ModelReport{
        .{
            .model = "gpt-4.1-mini",
            .counts = .{
                .total_runs = 10,
                .passed = 9,
                .failed = 1,
            },
        },
    };
    const service_reports = [_]ServiceReport{
        .{
            .service_name = "product-api",
            .counts = .{
                .total_runs = 10,
                .passed = 9,
                .failed = 1,
            },
            .models = model_reports[0..],
        },
    };
    const report = EvalReport{
        .group = "smoke",
        .eval_id = "reply_ok",
        .counts = .{
            .total_runs = 10,
            .passed = 9,
            .failed = 1,
        },
        .services = service_reports[0..],
    };

    try std.testing.expectEqualStrings("smoke", report.group);
    try std.testing.expectEqual(@as(usize, 1), report.services.len);
    try std.testing.expectEqualStrings("gpt-4.1-mini", report.services[0].models[0].model);
}
