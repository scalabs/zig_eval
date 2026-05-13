const std = @import("std");
const runner = @import("../runner/root.zig");

pub const AggregateCounts = struct {
    total_runs: usize,
    passed: usize,
    failed: usize,
};

pub const LatencyStats = struct {
    mean_ms: f64,
    p50_ms: u64,
    p95_ms: u64,
};

pub const AggregateStats = struct {
    counts: AggregateCounts,
    pass_rate: f64,
    latency: LatencyStats,
};

pub const ModelReport = struct {
    model: []const u8,
    stats: AggregateStats,
};

pub const ServiceReport = struct {
    service_name: []const u8,
    stats: AggregateStats,
    models: []const ModelReport,
};

pub const EvalReport = struct {
    group: []const u8,
    eval_id: []const u8,
    stats: AggregateStats,
    services: []const ServiceReport,
};

pub const OwnedEvalReports = struct {
    parent_allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    items: []const EvalReport,

    pub fn deinit(self: *OwnedEvalReports) void {
        self.arena.deinit();
        self.parent_allocator.destroy(self.arena);
        self.* = undefined;
    }
};

pub fn aggregateRunResults(
    allocator: std.mem.Allocator,
    results: []const runner.RunResult,
) !OwnedEvalReports {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    errdefer allocator.destroy(arena);

    var builders = std.ArrayList(EvalBuilder){};
    defer deinitEvalBuilders(allocator, &builders);

    for (results) |result| {
        try appendRunResult(allocator, arena.allocator(), &builders, result);
    }

    const reports = try buildEvalReports(arena.allocator(), builders.items);
    return .{
        .parent_allocator = allocator,
        .arena = arena,
        .items = reports,
    };
}

pub fn formatEvalReports(writer: anytype, reports: []const EvalReport) !void {
    if (reports.len == 0) {
        try writer.writeAll("No eval results.\n");
        return;
    }

    for (reports, 0..) |report, index| {
        if (index > 0) try writer.writeByte('\n');
        try formatEvalReport(writer, report);
    }
}

pub fn formatEvalReport(writer: anytype, report: EvalReport) !void {
    try writer.print("eval {s} group={s}\n", .{ report.eval_id, report.group });
    try formatStatsLine(writer, "summary", report.stats, 2);

    for (report.services) |service| {
        try writer.print("  service {s}\n", .{service.service_name});
        try formatStatsLine(writer, "summary", service.stats, 4);

        for (service.models) |model| {
            try writer.print("    model {s}\n", .{model.model});
            try formatStatsLine(writer, "summary", model.stats, 6);
        }
    }
}

fn formatStatsLine(
    writer: anytype,
    label: []const u8,
    stats: AggregateStats,
    indent: usize,
) !void {
    try writer.splatByteAll(' ', indent);
    try writer.print(
        "{s}: total={d} passed={d} failed={d} pass_rate={d:.2}% mean_ms={d:.2} p50_ms={d} p95_ms={d}\n",
        .{
            label,
            stats.counts.total_runs,
            stats.counts.passed,
            stats.counts.failed,
            stats.pass_rate * 100.0,
            stats.latency.mean_ms,
            stats.latency.p50_ms,
            stats.latency.p95_ms,
        },
    );
}

const Accumulator = struct {
    counts: AggregateCounts = .{
        .total_runs = 0,
        .passed = 0,
        .failed = 0,
    },
    latencies: std.ArrayList(u64) = .{},

    fn add(self: *Accumulator, allocator: std.mem.Allocator, result: runner.RunResult) !void {
        self.counts.total_runs += 1;
        if (result.passed) {
            self.counts.passed += 1;
        } else {
            self.counts.failed += 1;
        }
        try self.latencies.append(allocator, result.latency_ms);
    }

    fn deinit(self: *Accumulator, allocator: std.mem.Allocator) void {
        self.latencies.deinit(allocator);
    }

    fn stats(self: Accumulator, allocator: std.mem.Allocator) !AggregateStats {
        return .{
            .counts = self.counts,
            .pass_rate = passRate(self.counts),
            .latency = try computeLatencyStats(allocator, self.latencies.items),
        };
    }
};

const ModelBuilder = struct {
    model: []const u8,
    accumulator: Accumulator = .{},

    fn deinit(self: *ModelBuilder, allocator: std.mem.Allocator) void {
        self.accumulator.deinit(allocator);
    }
};

const ServiceBuilder = struct {
    service_name: []const u8,
    accumulator: Accumulator = .{},
    models: std.ArrayList(ModelBuilder) = .{},

    fn deinit(self: *ServiceBuilder, allocator: std.mem.Allocator) void {
        for (self.models.items) |*model| {
            model.deinit(allocator);
        }
        self.models.deinit(allocator);
        self.accumulator.deinit(allocator);
    }
};

const EvalBuilder = struct {
    group: []const u8,
    eval_id: []const u8,
    accumulator: Accumulator = .{},
    services: std.ArrayList(ServiceBuilder) = .{},

    fn deinit(self: *EvalBuilder, allocator: std.mem.Allocator) void {
        for (self.services.items) |*service| {
            service.deinit(allocator);
        }
        self.services.deinit(allocator);
        self.accumulator.deinit(allocator);
    }
};

fn deinitEvalBuilders(
    allocator: std.mem.Allocator,
    builders: *std.ArrayList(EvalBuilder),
) void {
    for (builders.items) |*builder| {
        builder.deinit(allocator);
    }
    builders.deinit(allocator);
}

fn appendRunResult(
    allocator: std.mem.Allocator,
    arena_allocator: std.mem.Allocator,
    builders: *std.ArrayList(EvalBuilder),
    result: runner.RunResult,
) !void {
    const eval_index = try getOrAppendEvalBuilder(allocator, arena_allocator, builders, result);
    var eval_builder = &builders.items[eval_index];
    try eval_builder.accumulator.add(allocator, result);

    const service_index = try getOrAppendServiceBuilder(
        allocator,
        arena_allocator,
        &eval_builder.services,
        result,
    );
    var service_builder = &eval_builder.services.items[service_index];
    try service_builder.accumulator.add(allocator, result);

    const model_index = try getOrAppendModelBuilder(
        allocator,
        arena_allocator,
        &service_builder.models,
        result,
    );
    var model_builder = &service_builder.models.items[model_index];
    try model_builder.accumulator.add(allocator, result);
}

fn getOrAppendEvalBuilder(
    allocator: std.mem.Allocator,
    arena_allocator: std.mem.Allocator,
    builders: *std.ArrayList(EvalBuilder),
    result: runner.RunResult,
) !usize {
    for (builders.items, 0..) |builder, index| {
        if (std.mem.eql(u8, builder.group, result.group) and
            std.mem.eql(u8, builder.eval_id, result.eval_id))
        {
            return index;
        }
    }

    try builders.append(allocator, .{
        .group = try arena_allocator.dupe(u8, result.group),
        .eval_id = try arena_allocator.dupe(u8, result.eval_id),
    });
    return builders.items.len - 1;
}

fn getOrAppendServiceBuilder(
    allocator: std.mem.Allocator,
    arena_allocator: std.mem.Allocator,
    builders: *std.ArrayList(ServiceBuilder),
    result: runner.RunResult,
) !usize {
    for (builders.items, 0..) |builder, index| {
        if (std.mem.eql(u8, builder.service_name, result.service_name)) {
            return index;
        }
    }

    try builders.append(allocator, .{
        .service_name = try arena_allocator.dupe(u8, result.service_name),
    });
    return builders.items.len - 1;
}

fn getOrAppendModelBuilder(
    allocator: std.mem.Allocator,
    arena_allocator: std.mem.Allocator,
    builders: *std.ArrayList(ModelBuilder),
    result: runner.RunResult,
) !usize {
    for (builders.items, 0..) |builder, index| {
        if (std.mem.eql(u8, builder.model, result.model)) {
            return index;
        }
    }

    try builders.append(allocator, .{
        .model = try arena_allocator.dupe(u8, result.model),
    });
    return builders.items.len - 1;
}

fn buildEvalReports(
    allocator: std.mem.Allocator,
    builders: []const EvalBuilder,
) ![]const EvalReport {
    var reports = try std.ArrayList(EvalReport).initCapacity(allocator, builders.len);
    defer reports.deinit(allocator);

    for (builders) |builder| {
        reports.appendAssumeCapacity(.{
            .group = builder.group,
            .eval_id = builder.eval_id,
            .stats = try builder.accumulator.stats(allocator),
            .services = try buildServiceReports(allocator, builder.services.items),
        });
    }

    return allocator.dupe(EvalReport, reports.items);
}

fn buildServiceReports(
    allocator: std.mem.Allocator,
    builders: []const ServiceBuilder,
) ![]const ServiceReport {
    var reports = try std.ArrayList(ServiceReport).initCapacity(allocator, builders.len);
    defer reports.deinit(allocator);

    for (builders) |builder| {
        reports.appendAssumeCapacity(.{
            .service_name = builder.service_name,
            .stats = try builder.accumulator.stats(allocator),
            .models = try buildModelReports(allocator, builder.models.items),
        });
    }

    return allocator.dupe(ServiceReport, reports.items);
}

fn buildModelReports(
    allocator: std.mem.Allocator,
    builders: []const ModelBuilder,
) ![]const ModelReport {
    var reports = try std.ArrayList(ModelReport).initCapacity(allocator, builders.len);
    defer reports.deinit(allocator);

    for (builders) |builder| {
        reports.appendAssumeCapacity(.{
            .model = builder.model,
            .stats = try builder.accumulator.stats(allocator),
        });
    }

    return allocator.dupe(ModelReport, reports.items);
}

fn passRate(counts: AggregateCounts) f64 {
    if (counts.total_runs == 0) return 0.0;
    return @as(f64, @floatFromInt(counts.passed)) / @as(f64, @floatFromInt(counts.total_runs));
}

fn computeLatencyStats(
    allocator: std.mem.Allocator,
    latencies: []const u64,
) !LatencyStats {
    if (latencies.len == 0) {
        return .{
            .mean_ms = 0.0,
            .p50_ms = 0,
            .p95_ms = 0,
        };
    }

    const sorted = try allocator.dupe(u64, latencies);
    defer allocator.free(sorted);
    std.mem.sort(u64, sorted, {}, std.sort.asc(u64));

    var total: u128 = 0;
    for (sorted) |value| {
        total += value;
    }

    return .{
        .mean_ms = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(sorted.len)),
        .p50_ms = sorted[nearestRankIndex(sorted.len, 50)],
        .p95_ms = sorted[nearestRankIndex(sorted.len, 95)],
    };
}

fn nearestRankIndex(count: usize, percentile: usize) usize {
    std.debug.assert(count > 0);
    std.debug.assert(percentile > 0);
    const rank = (percentile * count + 99) / 100;
    return @min(count - 1, rank - 1);
}

fn sampleRun(
    group: []const u8,
    eval_id: []const u8,
    service_name: []const u8,
    model: []const u8,
    passed: bool,
    latency_ms: u64,
) runner.RunResult {
    return .{
        .group = group,
        .eval_id = eval_id,
        .service_name = service_name,
        .model = model,
        .run_index = 1,
        .case_id = "case-1",
        .output = "OK",
        .passed = passed,
        .score = if (passed) 1.0 else 0.0,
        .failure_reason = if (passed) null else "failed",
        .latency_ms = latency_ms,
    };
}

test "EvalReport stores grouped report shapes" {
    const model_reports = [_]ModelReport{
        .{
            .model = "gpt-4.1-mini",
            .stats = .{
                .counts = .{
                    .total_runs = 10,
                    .passed = 9,
                    .failed = 1,
                },
                .pass_rate = 0.9,
                .latency = .{
                    .mean_ms = 100.0,
                    .p50_ms = 95,
                    .p95_ms = 140,
                },
            },
        },
    };
    const service_reports = [_]ServiceReport{
        .{
            .service_name = "product-api",
            .stats = model_reports[0].stats,
            .models = model_reports[0..],
        },
    };
    const report = EvalReport{
        .group = "smoke",
        .eval_id = "reply_ok",
        .stats = service_reports[0].stats,
        .services = service_reports[0..],
    };

    try std.testing.expectEqualStrings("smoke", report.group);
    try std.testing.expectEqual(@as(usize, 1), report.services.len);
    try std.testing.expectEqualStrings("gpt-4.1-mini", report.services[0].models[0].model);
}

test "aggregateRunResults returns empty reports for empty input" {
    var owned = try aggregateRunResults(std.testing.allocator, &.{});
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 0), owned.items.len);
}

test "aggregateRunResults handles all-pass aggregation" {
    const results = [_]runner.RunResult{
        sampleRun("smoke", "reply_ok", "product-api", "model-a", true, 10),
        sampleRun("smoke", "reply_ok", "product-api", "model-a", true, 20),
    };

    var owned = try aggregateRunResults(std.testing.allocator, results[0..]);
    defer owned.deinit();

    const report = owned.items[0];
    try std.testing.expectEqual(@as(usize, 2), report.stats.counts.total_runs);
    try std.testing.expectEqual(@as(usize, 2), report.stats.counts.passed);
    try std.testing.expectEqual(@as(usize, 0), report.stats.counts.failed);
    try std.testing.expectEqual(@as(f64, 1.0), report.stats.pass_rate);
    try std.testing.expectEqual(@as(f64, 15.0), report.stats.latency.mean_ms);
}

test "aggregateRunResults handles mixed pass and fail aggregation" {
    const results = [_]runner.RunResult{
        sampleRun("smoke", "reply_ok", "product-api", "model-a", true, 10),
        sampleRun("smoke", "reply_ok", "product-api", "model-a", false, 30),
    };

    var owned = try aggregateRunResults(std.testing.allocator, results[0..]);
    defer owned.deinit();

    const report = owned.items[0];
    try std.testing.expectEqual(@as(usize, 2), report.stats.counts.total_runs);
    try std.testing.expectEqual(@as(usize, 1), report.stats.counts.passed);
    try std.testing.expectEqual(@as(usize, 1), report.stats.counts.failed);
    try std.testing.expectEqual(@as(f64, 0.5), report.stats.pass_rate);
}

test "aggregateRunResults groups by eval service and model" {
    const results = [_]runner.RunResult{
        sampleRun("smoke", "reply_ok", "product-api", "model-a", true, 10),
        sampleRun("smoke", "reply_ok", "product-api", "model-b", true, 20),
        sampleRun("smoke", "reply_ok", "staging-api", "model-a", false, 30),
        sampleRun("json", "required_fields", "product-api", "model-a", true, 40),
    };

    var owned = try aggregateRunResults(std.testing.allocator, results[0..]);
    defer owned.deinit();

    try std.testing.expectEqual(@as(usize, 2), owned.items.len);
    try std.testing.expectEqualStrings("reply_ok", owned.items[0].eval_id);
    try std.testing.expectEqual(@as(usize, 2), owned.items[0].services.len);
    try std.testing.expectEqual(@as(usize, 2), owned.items[0].services[0].models.len);
    try std.testing.expectEqualStrings("required_fields", owned.items[1].eval_id);
}

test "computeLatencyStats calculates mean p50 and p95" {
    const latencies = [_]u64{ 40, 10, 30, 20 };
    const stats = try computeLatencyStats(std.testing.allocator, latencies[0..]);

    try std.testing.expectEqual(@as(f64, 25.0), stats.mean_ms);
    try std.testing.expectEqual(@as(u64, 20), stats.p50_ms);
    try std.testing.expectEqual(@as(u64, 40), stats.p95_ms);
}

test "formatEvalReports includes report fields" {
    const results = [_]runner.RunResult{
        sampleRun("smoke", "reply_ok", "product-api", "model-a", true, 10),
        sampleRun("smoke", "reply_ok", "product-api", "model-a", false, 30),
    };

    var owned = try aggregateRunResults(std.testing.allocator, results[0..]);
    defer owned.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try formatEvalReports(&out.writer, owned.items);
    const text = out.written();

    try std.testing.expect(std.mem.indexOf(u8, text, "reply_ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "product-api") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "model-a") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pass_rate") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "mean_ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "p50_ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "p95_ms") != null);
}
