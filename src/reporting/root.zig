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

pub const RetryStats = struct {
    retried_runs: usize,
    total_attempts: usize,
};

pub const ConfidenceInterval = struct {
    confidence_level: f64,
    low: f64,
    high: f64,
};

pub const AggregateStats = struct {
    counts: AggregateCounts,
    pass_rate: f64,
    confidence: ConfidenceInterval,
    latency: LatencyStats,
    retries: RetryStats,
};

pub const BaselineComparison = struct {
    group: []const u8,
    eval_id: []const u8,
    target_kind: []const u8,
    service_name: ?[]const u8 = null,
    baseline_name: []const u8,
    candidate_name: []const u8,
    baseline_pass_rate: f64,
    candidate_pass_rate: f64,
    delta_pass_rate: f64,
    delta_ci_low: f64,
    delta_ci_high: f64,
    confidence_level: f64,
};

pub const OwnedBaselineComparisons = struct {
    parent_allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    items: []const BaselineComparison,

    pub fn deinit(self: *OwnedBaselineComparisons) void {
        self.arena.deinit();
        self.parent_allocator.destroy(self.arena);
        self.* = undefined;
    }
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

pub const json_schema_version: u32 = 2;
pub const default_confidence_level: f64 = 0.95;

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

pub fn formatRunResultsJson(writer: anytype, results: []const runner.RunResult) !void {
    var json_writer = std.json.Stringify{
        .writer = writer,
        .options = .{},
    };

    try json_writer.beginObject();
    try json_writer.objectField("schema_version");
    try json_writer.write(json_schema_version);
    try json_writer.objectField("runs");
    try json_writer.beginArray();
    for (results) |result| {
        try writeRunResultJson(&json_writer, result);
    }
    try json_writer.endArray();
    try json_writer.endObject();
}

pub fn formatEvalReportsJson(writer: anytype, reports: []const EvalReport) !void {
    var json_writer = std.json.Stringify{
        .writer = writer,
        .options = .{},
    };

    try json_writer.beginObject();
    try json_writer.objectField("schema_version");
    try json_writer.write(json_schema_version);
    try json_writer.objectField("evals");
    try json_writer.beginArray();
    for (reports) |report| {
        try writeEvalReportJson(&json_writer, report);
    }
    try json_writer.endArray();
    try json_writer.endObject();
}

pub fn compareServicesToBaseline(
    allocator: std.mem.Allocator,
    reports: []const EvalReport,
    baseline_service: []const u8,
) !OwnedBaselineComparisons {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    errdefer allocator.destroy(arena);

    var items = std.ArrayList(BaselineComparison){};
    defer items.deinit(allocator);

    for (reports) |report| {
        const baseline = findServiceReport(report.services, baseline_service) orelse continue;
        for (report.services) |service| {
            if (std.mem.eql(u8, service.service_name, baseline_service)) continue;
            try items.append(allocator, try buildBaselineComparison(
                arena.allocator(),
                report.group,
                report.eval_id,
                "service",
                null,
                baseline_service,
                service.service_name,
                baseline.stats.counts,
                service.stats.counts,
            ));
        }
    }

    return .{
        .parent_allocator = allocator,
        .arena = arena,
        .items = try arena.allocator().dupe(BaselineComparison, items.items),
    };
}

pub fn compareModelsToBaseline(
    allocator: std.mem.Allocator,
    reports: []const EvalReport,
    baseline_model: []const u8,
) !OwnedBaselineComparisons {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    errdefer allocator.destroy(arena);

    var items = std.ArrayList(BaselineComparison){};
    defer items.deinit(allocator);

    for (reports) |report| {
        for (report.services) |service| {
            const baseline = findModelReport(service.models, baseline_model) orelse continue;
            for (service.models) |model| {
                if (std.mem.eql(u8, model.model, baseline_model)) continue;
                try items.append(allocator, try buildBaselineComparison(
                    arena.allocator(),
                    report.group,
                    report.eval_id,
                    "model",
                    service.service_name,
                    baseline_model,
                    model.model,
                    baseline.stats.counts,
                    model.stats.counts,
                ));
            }
        }
    }

    return .{
        .parent_allocator = allocator,
        .arena = arena,
        .items = try arena.allocator().dupe(BaselineComparison, items.items),
    };
}

pub fn formatBaselineComparisonsJson(
    writer: anytype,
    comparisons: []const BaselineComparison,
) !void {
    var json_writer = std.json.Stringify{
        .writer = writer,
        .options = .{},
    };

    try json_writer.beginObject();
    try json_writer.objectField("schema_version");
    try json_writer.write(json_schema_version);
    try json_writer.objectField("baseline_comparisons");
    try json_writer.beginArray();
    for (comparisons) |comparison| {
        try writeBaselineComparisonJson(&json_writer, comparison);
    }
    try json_writer.endArray();
    try json_writer.endObject();
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
        "{s}: total={d} passed={d} failed={d} pass_rate={d:.2}% ci95=[{d:.2}%, {d:.2}%] mean_ms={d:.2} p50_ms={d} p95_ms={d}\n",
        .{
            label,
            stats.counts.total_runs,
            stats.counts.passed,
            stats.counts.failed,
            stats.pass_rate * 100.0,
            stats.confidence.low * 100.0,
            stats.confidence.high * 100.0,
            stats.latency.mean_ms,
            stats.latency.p50_ms,
            stats.latency.p95_ms,
        },
    );
}

fn writeRunResultJson(json_writer: *std.json.Stringify, result: runner.RunResult) !void {
    try json_writer.beginObject();
    try json_writer.objectField("group");
    try json_writer.write(result.group);
    try json_writer.objectField("eval_id");
    try json_writer.write(result.eval_id);
    try json_writer.objectField("service_name");
    try json_writer.write(result.service_name);
    try json_writer.objectField("model");
    try json_writer.write(result.model);
    try json_writer.objectField("run_index");
    try json_writer.write(result.run_index);
    try json_writer.objectField("case_id");
    try json_writer.write(result.case_id);
    try json_writer.objectField("output");
    try json_writer.write(result.output);
    try json_writer.objectField("passed");
    try json_writer.write(result.passed);
    try json_writer.objectField("score");
    try json_writer.write(result.score);
    try json_writer.objectField("failure_reason");
    if (result.failure_reason) |reason| {
        try json_writer.write(reason);
    } else {
        try json_writer.write(@as(?[]const u8, null));
    }

    try json_writer.objectField("attempt_count");
    try json_writer.write(result.attempt_count);

    try json_writer.objectField("retried");
    try json_writer.write(result.retried);

    try json_writer.objectField("latency_ms");
    try json_writer.write(result.latency_ms);
    try json_writer.endObject();
}

fn writeEvalReportJson(json_writer: *std.json.Stringify, report: EvalReport) !void {
    try json_writer.beginObject();
    try json_writer.objectField("group");
    try json_writer.write(report.group);
    try json_writer.objectField("eval_id");
    try json_writer.write(report.eval_id);
    try json_writer.objectField("stats");
    try writeAggregateStatsJson(json_writer, report.stats);
    try json_writer.objectField("services");
    try json_writer.beginArray();
    for (report.services) |service| {
        try writeServiceReportJson(json_writer, service);
    }
    try json_writer.endArray();
    try json_writer.endObject();
}

fn writeServiceReportJson(json_writer: *std.json.Stringify, report: ServiceReport) !void {
    try json_writer.beginObject();
    try json_writer.objectField("service_name");
    try json_writer.write(report.service_name);
    try json_writer.objectField("stats");
    try writeAggregateStatsJson(json_writer, report.stats);
    try json_writer.objectField("models");
    try json_writer.beginArray();
    for (report.models) |model| {
        try writeModelReportJson(json_writer, model);
    }
    try json_writer.endArray();
    try json_writer.endObject();
}

fn writeModelReportJson(json_writer: *std.json.Stringify, report: ModelReport) !void {
    try json_writer.beginObject();
    try json_writer.objectField("model");
    try json_writer.write(report.model);
    try json_writer.objectField("stats");
    try writeAggregateStatsJson(json_writer, report.stats);
    try json_writer.endObject();
}

fn writeAggregateStatsJson(json_writer: *std.json.Stringify, stats: AggregateStats) !void {
    try json_writer.beginObject();
    try json_writer.objectField("counts");
    try writeAggregateCountsJson(json_writer, stats.counts);
    try json_writer.objectField("pass_rate");
    try json_writer.write(stats.pass_rate);
    try json_writer.objectField("confidence_level");
    try json_writer.write(stats.confidence.confidence_level);
    try json_writer.objectField("pass_rate_ci_low");
    try json_writer.write(stats.confidence.low);
    try json_writer.objectField("pass_rate_ci_high");
    try json_writer.write(stats.confidence.high);
    try json_writer.objectField("latency");
    try writeLatencyStatsJson(json_writer, stats.latency);
    try json_writer.objectField("retries");
    try writeRetryStatsJson(json_writer, stats.retries);
    try json_writer.endObject();
}

fn writeBaselineComparisonJson(
    json_writer: *std.json.Stringify,
    comparison: BaselineComparison,
) !void {
    try json_writer.beginObject();
    try json_writer.objectField("group");
    try json_writer.write(comparison.group);
    try json_writer.objectField("eval_id");
    try json_writer.write(comparison.eval_id);
    try json_writer.objectField("target_kind");
    try json_writer.write(comparison.target_kind);
    try json_writer.objectField("service_name");
    if (comparison.service_name) |service_name| {
        try json_writer.write(service_name);
    } else {
        try json_writer.write(@as(?[]const u8, null));
    }
    try json_writer.objectField("baseline_name");
    try json_writer.write(comparison.baseline_name);
    try json_writer.objectField("candidate_name");
    try json_writer.write(comparison.candidate_name);
    try json_writer.objectField("baseline_pass_rate");
    try json_writer.write(comparison.baseline_pass_rate);
    try json_writer.objectField("candidate_pass_rate");
    try json_writer.write(comparison.candidate_pass_rate);
    try json_writer.objectField("delta_pass_rate");
    try json_writer.write(comparison.delta_pass_rate);
    try json_writer.objectField("delta_ci_low");
    try json_writer.write(comparison.delta_ci_low);
    try json_writer.objectField("delta_ci_high");
    try json_writer.write(comparison.delta_ci_high);
    try json_writer.objectField("confidence_level");
    try json_writer.write(comparison.confidence_level);
    try json_writer.endObject();
}

fn writeAggregateCountsJson(json_writer: *std.json.Stringify, counts: AggregateCounts) !void {
    try json_writer.beginObject();
    try json_writer.objectField("total_runs");
    try json_writer.write(counts.total_runs);
    try json_writer.objectField("passed");
    try json_writer.write(counts.passed);
    try json_writer.objectField("failed");
    try json_writer.write(counts.failed);
    try json_writer.endObject();
}

fn writeLatencyStatsJson(json_writer: *std.json.Stringify, stats: LatencyStats) !void {
    try json_writer.beginObject();
    try json_writer.objectField("mean_ms");
    try json_writer.write(stats.mean_ms);
    try json_writer.objectField("p50_ms");
    try json_writer.write(stats.p50_ms);
    try json_writer.objectField("p95_ms");
    try json_writer.write(stats.p95_ms);
    try json_writer.endObject();
}

fn writeRetryStatsJson(json_writer: *std.json.Stringify, stats: RetryStats) !void {
    try json_writer.beginObject();
    try json_writer.objectField("retried_runs");
    try json_writer.write(stats.retried_runs);
    try json_writer.objectField("total_attempts");
    try json_writer.write(stats.total_attempts);
    try json_writer.endObject();
}

const Accumulator = struct {
    counts: AggregateCounts = .{
        .total_runs = 0,
        .passed = 0,
        .failed = 0,
    },
    latencies: std.ArrayList(u64) = .{},
    retried_runs: usize = 0,
    total_attempts: usize = 0,

    fn add(self: *Accumulator, allocator: std.mem.Allocator, result: runner.RunResult) !void {
        self.counts.total_runs += 1;
        if (result.passed) {
            self.counts.passed += 1;
        } else {
            self.counts.failed += 1;
        }
        try self.latencies.append(allocator, result.latency_ms);

        self.total_attempts += result.attempt_count;

        if (result.retried) {
            self.retried_runs += 1;
        }
    }

    fn deinit(self: *Accumulator, allocator: std.mem.Allocator) void {
        self.latencies.deinit(allocator);
    }

    fn stats(self: Accumulator, allocator: std.mem.Allocator) !AggregateStats {
        return .{
            .counts = self.counts,
            .pass_rate = passRate(self.counts),
            .confidence = computePassRateConfidenceInterval(self.counts, default_confidence_level),
            .latency = try computeLatencyStats(allocator, self.latencies.items),
            .retries = .{
                .retried_runs = self.retried_runs,
                .total_attempts = self.total_attempts,
            },
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

fn findServiceReport(services: []const ServiceReport, service_name: []const u8) ?ServiceReport {
    for (services) |service| {
        if (std.mem.eql(u8, service.service_name, service_name)) return service;
    }
    return null;
}

fn findModelReport(models: []const ModelReport, model_name: []const u8) ?ModelReport {
    for (models) |model| {
        if (std.mem.eql(u8, model.model, model_name)) return model;
    }
    return null;
}

fn buildBaselineComparison(
    allocator: std.mem.Allocator,
    group: []const u8,
    eval_id: []const u8,
    target_kind: []const u8,
    service_name: ?[]const u8,
    baseline_name: []const u8,
    candidate_name: []const u8,
    baseline_counts: AggregateCounts,
    candidate_counts: AggregateCounts,
) !BaselineComparison {
    const baseline_pass_rate = passRate(baseline_counts);
    const candidate_pass_rate = passRate(candidate_counts);
    const delta = candidate_pass_rate - baseline_pass_rate;
    const delta_ci = computeDeltaConfidenceInterval(
        baseline_counts,
        candidate_counts,
        default_confidence_level,
    );

    return .{
        .group = try allocator.dupe(u8, group),
        .eval_id = try allocator.dupe(u8, eval_id),
        .target_kind = target_kind,
        .service_name = if (service_name) |name| try allocator.dupe(u8, name) else null,
        .baseline_name = try allocator.dupe(u8, baseline_name),
        .candidate_name = try allocator.dupe(u8, candidate_name),
        .baseline_pass_rate = baseline_pass_rate,
        .candidate_pass_rate = candidate_pass_rate,
        .delta_pass_rate = delta,
        .delta_ci_low = delta_ci.low,
        .delta_ci_high = delta_ci.high,
        .confidence_level = default_confidence_level,
    };
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

fn computePassRateConfidenceInterval(
    counts: AggregateCounts,
    confidence_level: f64,
) ConfidenceInterval {
    if (counts.total_runs == 0) {
        return .{
            .confidence_level = confidence_level,
            .low = 0.0,
            .high = 0.0,
        };
    }

    const z = zScore(confidence_level);
    const n = @as(f64, @floatFromInt(counts.total_runs));
    const p = passRate(counts);
    const z2 = z * z;
    const denominator = 1.0 + z2 / n;
    const center = (p + z2 / (2.0 * n)) / denominator;
    const margin = (z * @sqrt((p * (1.0 - p) + z2 / (4.0 * n)) / n)) / denominator;

    return .{
        .confidence_level = confidence_level,
        .low = clampRate(center - margin),
        .high = clampRate(center + margin),
    };
}

fn computeDeltaConfidenceInterval(
    baseline: AggregateCounts,
    candidate: AggregateCounts,
    confidence_level: f64,
) ConfidenceInterval {
    if (baseline.total_runs == 0 or candidate.total_runs == 0) {
        return .{
            .confidence_level = confidence_level,
            .low = 0.0,
            .high = 0.0,
        };
    }

    const z = zScore(confidence_level);
    const baseline_rate = passRate(baseline);
    const candidate_rate = passRate(candidate);
    const delta = candidate_rate - baseline_rate;
    const baseline_n = @as(f64, @floatFromInt(baseline.total_runs));
    const candidate_n = @as(f64, @floatFromInt(candidate.total_runs));
    const se = @sqrt(
        (baseline_rate * (1.0 - baseline_rate) / baseline_n) +
            (candidate_rate * (1.0 - candidate_rate) / candidate_n),
    );
    const margin = z * se;

    return .{
        .confidence_level = confidence_level,
        .low = clampDelta(delta - margin),
        .high = clampDelta(delta + margin),
    };
}

fn zScore(confidence_level: f64) f64 {
    _ = confidence_level;
    return 1.959963984540054;
}

fn clampRate(value: f64) f64 {
    return @max(0.0, @min(1.0, value));
}

fn clampDelta(value: f64) f64 {
    return @max(-1.0, @min(1.0, value));
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
        .attempt_count = if (passed) 1 else 2,
        .retried = !passed,
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
                .confidence = .{
                    .confidence_level = 0.95,
                    .low = 0.6,
                    .high = 0.98,
                },
                .latency = .{
                    .mean_ms = 100.0,
                    .p50_ms = 95,
                    .p95_ms = 140,
                },
                .retries = .{
                    .retried_runs = 1,
                    .total_attempts = 11,
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

test "computePassRateConfidenceInterval handles common result shapes" {
    const empty = computePassRateConfidenceInterval(.{
        .total_runs = 0,
        .passed = 0,
        .failed = 0,
    }, default_confidence_level);
    try std.testing.expectEqual(@as(f64, 0.0), empty.low);
    try std.testing.expectEqual(@as(f64, 0.0), empty.high);

    const all_pass = computePassRateConfidenceInterval(.{
        .total_runs = 4,
        .passed = 4,
        .failed = 0,
    }, default_confidence_level);
    try std.testing.expect(all_pass.low > 0.45);
    try std.testing.expectEqual(@as(f64, 1.0), all_pass.high);

    const all_fail = computePassRateConfidenceInterval(.{
        .total_runs = 4,
        .passed = 0,
        .failed = 4,
    }, default_confidence_level);
    try std.testing.expectEqual(@as(f64, 0.0), all_fail.low);
    try std.testing.expect(all_fail.high < 0.55);

    const mixed = computePassRateConfidenceInterval(.{
        .total_runs = 2,
        .passed = 1,
        .failed = 1,
    }, default_confidence_level);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0945), mixed.low, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.9055), mixed.high, 0.001);
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
    try std.testing.expect(std.mem.indexOf(u8, text, "ci95") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "mean_ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "p50_ms") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "p95_ms") != null);
}

test "formatRunResultsJson writes machine readable run artifacts" {
    const results = [_]runner.RunResult{
        sampleRun("smoke", "reply_ok", "product-api", "model-a", true, 10),
        sampleRun("smoke", "reply_ok", "product-api", "model-a", false, 30),
    };

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try formatRunResultsJson(&out.writer, results[0..]);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, json_schema_version), root.get("schema_version").?.integer);

    const runs = root.get("runs").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), runs.len);
    try std.testing.expectEqualStrings("reply_ok", runs[0].object.get("eval_id").?.string);
    try std.testing.expectEqualStrings("product-api", runs[0].object.get("service_name").?.string);
    try std.testing.expect(runs[0].object.get("passed").?.bool);
    try std.testing.expectEqual(@as(i64, 30), runs[1].object.get("latency_ms").?.integer);
    try std.testing.expectEqualStrings("failed", runs[1].object.get("failure_reason").?.string);
    try std.testing.expectEqual(@as(i64, 2), runs[1].object.get("attempt_count").?.integer);
    try std.testing.expect(runs[1].object.get("retried").?.bool);
}

test "formatEvalReportsJson writes grouped aggregate artifacts" {
    const results = [_]runner.RunResult{
        sampleRun("smoke", "reply_ok", "product-api", "model-a", true, 10),
        sampleRun("smoke", "reply_ok", "product-api", "model-a", false, 30),
    };

    var owned = try aggregateRunResults(std.testing.allocator, results[0..]);
    defer owned.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try formatEvalReportsJson(&out.writer, owned.items);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, json_schema_version), root.get("schema_version").?.integer);

    const evals = root.get("evals").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), evals.len);

    const eval_report = evals[0].object;
    try std.testing.expectEqualStrings("smoke", eval_report.get("group").?.string);
    try std.testing.expectEqualStrings("reply_ok", eval_report.get("eval_id").?.string);
    const eval_stats = eval_report.get("stats").?.object;
    try std.testing.expectEqual(@as(i64, 2), eval_stats.get("counts").?.object.get("total_runs").?.integer);
    try std.testing.expectEqual(@as(f64, 0.95), eval_stats.get("confidence_level").?.float);
    try std.testing.expect(eval_stats.get("pass_rate_ci_low") != null);
    try std.testing.expect(eval_stats.get("pass_rate_ci_high") != null);
    try std.testing.expectEqual(@as(i64, 1), eval_stats.get("retries").?.object.get("retried_runs").?.integer);
    try std.testing.expectEqual(@as(i64, 3), eval_stats.get("retries").?.object.get("total_attempts").?.integer);

    const service_reports = eval_report.get("services").?.array.items;
    try std.testing.expectEqualStrings("product-api", service_reports[0].object.get("service_name").?.string);

    const model_reports = service_reports[0].object.get("models").?.array.items;
    try std.testing.expectEqualStrings("model-a", model_reports[0].object.get("model").?.string);
    try std.testing.expectEqual(@as(i64, 30), model_reports[0].object.get("stats").?.object.get("latency").?.object.get("p95_ms").?.integer);
}

test "compareServicesToBaseline computes pass-rate delta" {
    const results = [_]runner.RunResult{
        sampleRun("smoke", "reply_ok", "baseline", "model-a", true, 10),
        sampleRun("smoke", "reply_ok", "baseline", "model-a", false, 10),
        sampleRun("smoke", "reply_ok", "candidate", "model-a", true, 10),
        sampleRun("smoke", "reply_ok", "candidate", "model-a", true, 10),
    };

    var owned = try aggregateRunResults(std.testing.allocator, results[0..]);
    defer owned.deinit();

    var comparisons = try compareServicesToBaseline(
        std.testing.allocator,
        owned.items,
        "baseline",
    );
    defer comparisons.deinit();

    try std.testing.expectEqual(@as(usize, 1), comparisons.items.len);
    try std.testing.expectEqualStrings("baseline", comparisons.items[0].baseline_name);
    try std.testing.expectEqualStrings("candidate", comparisons.items[0].candidate_name);
    try std.testing.expectEqual(@as(f64, 0.5), comparisons.items[0].delta_pass_rate);
}

test "compareModelsToBaseline computes model delta within service" {
    const results = [_]runner.RunResult{
        sampleRun("smoke", "reply_ok", "product-api", "baseline-model", true, 10),
        sampleRun("smoke", "reply_ok", "product-api", "baseline-model", false, 10),
        sampleRun("smoke", "reply_ok", "product-api", "candidate-model", true, 10),
        sampleRun("smoke", "reply_ok", "product-api", "candidate-model", true, 10),
    };

    var owned = try aggregateRunResults(std.testing.allocator, results[0..]);
    defer owned.deinit();

    var comparisons = try compareModelsToBaseline(
        std.testing.allocator,
        owned.items,
        "baseline-model",
    );
    defer comparisons.deinit();

    try std.testing.expectEqual(@as(usize, 1), comparisons.items.len);
    try std.testing.expectEqualStrings("model", comparisons.items[0].target_kind);
    try std.testing.expectEqualStrings("product-api", comparisons.items[0].service_name.?);
    try std.testing.expectEqual(@as(f64, 0.5), comparisons.items[0].delta_pass_rate);
}

test "formatBaselineComparisonsJson writes comparison artifact" {
    const results = [_]runner.RunResult{
        sampleRun("smoke", "reply_ok", "baseline", "model-a", true, 10),
        sampleRun("smoke", "reply_ok", "candidate", "model-a", false, 10),
    };

    var owned = try aggregateRunResults(std.testing.allocator, results[0..]);
    defer owned.deinit();

    var comparisons = try compareServicesToBaseline(
        std.testing.allocator,
        owned.items,
        "baseline",
    );
    defer comparisons.deinit();

    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();
    try formatBaselineComparisonsJson(&out.writer, comparisons.items);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, json_schema_version), root.get("schema_version").?.integer);
    const comparison = root.get("baseline_comparisons").?.array.items[0].object;
    try std.testing.expectEqualStrings("service", comparison.get("target_kind").?.string);
    try std.testing.expect(comparison.get("delta_ci_low") != null);
    try std.testing.expect(comparison.get("delta_ci_high") != null);
}
