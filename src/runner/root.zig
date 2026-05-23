const std = @import("std");
const matchers = @import("../matchers/root.zig");
const registry = @import("../registry/root.zig");
const services = @import("../services/root.zig");
const Thread = std.Thread;
const Mutex = Thread.Mutex;

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
    attempt_count: u32 = 1,
    retried: bool = false,
    latency_ms: u64,
};

pub const MatcherOutcome = struct {
    passed: bool,
    score: f64,
    failure_reason: ?[]const u8 = null,
    owned_failure_reason: ?[]u8 = null,
};

pub const ServiceCaller = *const fn (
    allocator: std.mem.Allocator,
    service: services.ServiceConfig,
    input: services.ChatCallInput,
) anyerror!services.ChatCallOutput;

pub const MatcherEvaluator = *const fn (
    allocator: std.mem.Allocator,
    matcher: matchers.MatcherConfig,
    output: []const u8,
    ideal: ?[]const u8,
) anyerror!MatcherOutcome;

pub const RunnerOptions = struct {
    root_dir: std.fs.Dir,
    services: []const services.ServiceConfig,
    evals: []const registry.EvalDefinition,
    service_filter: ?[]const u8 = null,
    group_filter: ?[]const u8 = null,
    eval_filter: ?[]const u8 = null,
    run_count_override: ?u32 = null,
    parallelism: u32 = 1,
    max_inflight_per_service: u32 = 1,
    show_progress: bool = false,
    progress_writer: ?*std.Io.Writer = null,
    service_caller: ServiceCaller = defaultServiceCaller,
    matcher_evaluator: MatcherEvaluator,
};

pub const RunnerResult = struct {
    parent_allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    runs: []const RunResult,

    pub fn deinit(self: *RunnerResult) void {
        self.arena.deinit();
        self.parent_allocator.destroy(self.arena);
        self.* = undefined;
    }
};

pub const EvalTask = struct {
    eval_definition: registry.EvalDefinition,
    service: services.ServiceConfig,
    case: registry.EvalCase,
    run_index: u32,
};

pub const WorkerContext = struct {
    allocator: std.mem.Allocator,
    arena_allocator: std.mem.Allocator,
    runs: *std.ArrayList(RunResult),
    runs_mutex: *Mutex,
    tasks: []const EvalTask,
    next_index: *usize,
    index_mutex: *Mutex,
    service_limiter: *ServiceLimiter,
    completed_count: *usize,
    progress_mutex: *Mutex,
    options: RunnerOptions,
};

pub const ServiceLimiter = struct {
    mutex: Mutex = .{},
    service_names: []const []const u8,
    inflight_counts: []u32,
    max_inflight: u32,

    fn acquire(self: *ServiceLimiter, service_name: []const u8) void {
        while (true) {
            self.mutex.lock();

            const index = self.indexOf(service_name) orelse {
                self.mutex.unlock();
                return;
            };

            if (self.inflight_counts[index] < self.max_inflight) {
                self.inflight_counts[index] += 1;
                self.mutex.unlock();
                return;
            }

            self.mutex.unlock();
            Thread.sleep(1 * std.time.ns_per_ms);
        }
    }

    fn release(self: *ServiceLimiter, service_name: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const index = self.indexOf(service_name) orelse return;

        if (self.inflight_counts[index] > 0) {
            self.inflight_counts[index] -= 1;
        }
    }

    fn indexOf(self: *ServiceLimiter, service_name: []const u8) ?usize {
        for (self.service_names, 0..) |name, index| {
            if (std.mem.eql(u8, name, service_name)) {
                return index;
            }
        }

        return null;
    }
};

pub fn runEvaluations(
    allocator: std.mem.Allocator,
    options: RunnerOptions,
) !RunnerResult {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer allocator.destroy(arena);
    errdefer arena.deinit();

    var runs = std.ArrayList(RunResult){};
    defer runs.deinit(allocator);

    var runs_mutex = Mutex{};

    var tasks = try collectEvalTasks(allocator, arena.allocator(), options);
    defer tasks.deinit(allocator);

    if (options.parallelism <= 1) {
        for (tasks.items) |task| {
            try runOneCase(
                allocator,
                arena.allocator(),
                &runs,
                &runs_mutex,
                options,
                task.eval_definition,
                task.service,
                task.case,
                task.run_index,
            );
        }
    } else {
        var index_mutex = Mutex{};
        var next_index: usize = 0;
        var completed_count: usize = 0;
        var progress_mutex = Mutex{};
        var service_names = try allocator.alloc([]const u8, options.services.len);
        defer allocator.free(service_names);

        var inflight_counts = try allocator.alloc(u32, options.services.len);
        defer allocator.free(inflight_counts);

        for (options.services, 0..) |service, index| {
            service_names[index] = service.name;
            inflight_counts[index] = 0;
        }

        var service_limiter = ServiceLimiter{
            .service_names = service_names,
            .inflight_counts = inflight_counts,
            .max_inflight = options.max_inflight_per_service,
        };

        const worker_count = @min(options.parallelism, @as(u32, @intCast(tasks.items.len)));

        const threads = try allocator.alloc(Thread, worker_count);
        defer allocator.free(threads);

        var context = WorkerContext{
            .allocator = allocator,
            .arena_allocator = arena.allocator(),
            .runs = &runs,
            .runs_mutex = &runs_mutex,
            .tasks = tasks.items,
            .next_index = &next_index,
            .index_mutex = &index_mutex,
            .service_limiter = &service_limiter,
            .completed_count = &completed_count,
            .progress_mutex = &progress_mutex,
            .options = options,
        };

        for (threads, 0..) |*thread, index| {
            _ = index;
            thread.* = try Thread.spawn(.{}, workerLoop, .{&context});
        }

        for (threads) |thread| {
            thread.join();
        }
    }

    std.mem.sort(RunResult, runs.items, {}, compareRunResults);

    return .{
        .parent_allocator = allocator,
        .arena = arena,
        .runs = try arena.allocator().dupe(RunResult, runs.items),
    };
}

fn workerLoop(context: *WorkerContext) !void {
    while (true) {
        context.index_mutex.lock();
        const index = context.next_index.*;
        if (index >= context.tasks.len) {
            context.index_mutex.unlock();
            return;
        }

        context.next_index.* += 1;
        context.index_mutex.unlock();

        const task = context.tasks[index];

        context.service_limiter.acquire(task.service.name);
        defer context.service_limiter.release(task.service.name);

        try runOneCase(
            context.allocator,
            context.arena_allocator,
            context.runs,
            context.runs_mutex,
            context.options,
            task.eval_definition,
            task.service,
            task.case,
            task.run_index,
        );

        context.progress_mutex.lock();

        context.completed_count.* += 1;

        if (context.options.show_progress) {
            if (context.options.progress_writer) |writer| {
                try writer.print(
                    "completed {d}/{d} eval runs\n",
                    .{ context.completed_count.*, context.tasks.len },
                );
            }
        }

        context.progress_mutex.unlock();
    }
}

fn compareRunResults(_: void, a: RunResult, b: RunResult) bool {
    var order = std.mem.order(u8, a.group, b.group);
    if (order != .eq) return order == .lt;

    order = std.mem.order(u8, a.eval_id, b.eval_id);
    if (order != .eq) return order == .lt;

    order = std.mem.order(u8, a.service_name, b.service_name);
    if (order != .eq) return order == .lt;

    if (a.run_index != b.run_index) {
        return a.run_index < b.run_index;
    }

    order = std.mem.order(u8, a.case_id, b.case_id);
    if (order != .eq) return order == .lt;

    order = std.mem.order(u8, a.model, b.model);
    if (order != .eq) return order == .lt;

    return false;
}

fn collectEvalTasks(
    allocator: std.mem.Allocator,
    arena_allocator: std.mem.Allocator,
    options: RunnerOptions,
) !std.ArrayList(EvalTask) {
    var tasks = std.ArrayList(EvalTask){};

    for (options.evals) |eval_definition| {
        if (!evalMatchesFilters(eval_definition, options)) continue;

        const run_count = options.run_count_override orelse eval_definition.default_run_count;
        if (run_count == 0) return error.InvalidRunCount;

        var cases = try registry.loadEvalCases(
            allocator,
            options.root_dir,
            eval_definition.dataset_path,
        );
        defer cases.deinit();

        for (options.services) |service| {
            if (!serviceMatchesFilters(service, eval_definition, options)) continue;

            var run_index: u32 = 1;
            while (run_index <= run_count) : (run_index += 1) {
                for (cases.items) |case| {
                    try tasks.append(allocator, .{
                        .eval_definition = eval_definition,
                        .service = service,
                        .case = .{
                            .id = try arena_allocator.dupe(u8, case.id),
                            .input = try arena_allocator.dupe(u8, case.input),
                            .ideal = if (case.ideal) |ideal| try arena_allocator.dupe(u8, ideal) else null,
                        },
                        .run_index = run_index,
                    });
                }
            }
        }
    }

    return tasks;
}

fn runOneCase(
    temp_allocator: std.mem.Allocator,
    arena_allocator: std.mem.Allocator,
    runs: *std.ArrayList(RunResult),
    runs_mutex: *Mutex,
    options: RunnerOptions,
    eval_definition: registry.EvalDefinition,
    service: services.ServiceConfig,
    case: registry.EvalCase,
    run_index: u32,
) !void {
    const input = services.ChatCallInput{ .prompt = case.input };
    const started_at = std.time.milliTimestamp();

    var output = options.service_caller(temp_allocator, service, input) catch |err| {
        runs_mutex.lock();
        defer runs_mutex.unlock();

        try appendRunResult(temp_allocator, arena_allocator, runs, .{
            .group = eval_definition.group,
            .eval_id = eval_definition.id,
            .service_name = service.name,
            .model = service.default_model,
            .run_index = run_index,
            .case_id = case.id,
            .output = "",
            .passed = false,
            .score = 0.0,
            .failure_reason = @errorName(err),
            .latency_ms = elapsedMillis(started_at),
        });
        return;
    };
    defer output.deinit(temp_allocator);

    const outcome = evaluateRunMatcher(
        temp_allocator,
        options,
        eval_definition.matcher,
        case.input,
        output.content,
        case.ideal,
    ) catch |err| MatcherOutcome{
        .passed = false,
        .score = 0.0,
        .failure_reason = @errorName(err),
    };
    defer if (outcome.owned_failure_reason) |reason| temp_allocator.free(reason);

    runs_mutex.lock();
    defer runs_mutex.unlock();

    try appendRunResult(temp_allocator, arena_allocator, runs, .{
        .group = eval_definition.group,
        .eval_id = eval_definition.id,
        .service_name = service.name,
        .model = output.model,
        .run_index = run_index,
        .case_id = case.id,
        .output = output.content,
        .passed = outcome.passed,
        .score = outcome.score,
        .failure_reason = outcome.failure_reason,
        .attempt_count = output.attempt_count,
        .retried = output.retried,
        .latency_ms = elapsedMillis(started_at),
    });
}

fn evaluateRunMatcher(
    allocator: std.mem.Allocator,
    options: RunnerOptions,
    matcher: matchers.MatcherConfig,
    input: []const u8,
    output: []const u8,
    ideal: ?[]const u8,
) !MatcherOutcome {
    return switch (matcher) {
        .model_grade => |config| evaluateModelGradeMatcher(allocator, options, config, input, output, ideal),
        else => options.matcher_evaluator(allocator, matcher, output, ideal),
    };
}

fn evaluateModelGradeMatcher(
    allocator: std.mem.Allocator,
    options: RunnerOptions,
    config: matchers.ModelGradeMatcherConfig,
    input: []const u8,
    output: []const u8,
    ideal: ?[]const u8,
) !MatcherOutcome {
    const judge_service = findServiceByName(options.services, config.judge_service) orelse {
        return error.JudgeServiceNotFound;
    };

    const prompt = try matchers.renderModelGradePrompt(allocator, config, .{
        .input = input,
        .output = output,
        .ideal = ideal,
    });
    defer allocator.free(prompt);

    var judge_output = try options.service_caller(allocator, judge_service, .{
        .prompt = prompt,
        .model_override = config.judge_model,
    });
    defer judge_output.deinit(allocator);

    return parseJudgeOutcome(allocator, judge_output.content, config.pass_score);
}

fn parseJudgeOutcome(
    allocator: std.mem.Allocator,
    raw: []const u8,
    pass_score: f64,
) !MatcherOutcome {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch {
        return error.InvalidModelGradeJudgeOutput;
    };
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidModelGradeJudgeOutput,
    };

    const score = try parseJudgeScore(object.get("score") orelse return error.InvalidModelGradeJudgeOutput);
    const judge_passed = switch (object.get("passed") orelse return error.InvalidModelGradeJudgeOutput) {
        .bool => |value| value,
        else => return error.InvalidModelGradeJudgeOutput,
    };
    const reason = switch (object.get("reason") orelse return error.InvalidModelGradeJudgeOutput) {
        .string => |value| std.mem.trim(u8, value, " \t\r\n"),
        else => return error.InvalidModelGradeJudgeOutput,
    };
    if (reason.len == 0) return error.InvalidModelGradeJudgeOutput;

    const passed = judge_passed and score >= pass_score;
    const owned_reason = if (passed) null else try allocator.dupe(u8, reason);

    return .{
        .passed = passed,
        .score = score,
        .failure_reason = owned_reason,
        .owned_failure_reason = owned_reason,
    };
}

fn parseJudgeScore(value: std.json.Value) !f64 {
    const score = switch (value) {
        .float => |number| number,
        .integer => |number| @as(f64, @floatFromInt(number)),
        else => return error.InvalidModelGradeJudgeOutput,
    };
    if (score < 0.0 or score > 1.0) return error.InvalidModelGradeJudgeOutput;
    return score;
}

fn appendRunResult(
    temp_allocator: std.mem.Allocator,
    arena_allocator: std.mem.Allocator,
    runs: *std.ArrayList(RunResult),
    result: RunResult,
) !void {
    try runs.append(temp_allocator, .{
        .group = try arena_allocator.dupe(u8, result.group),
        .eval_id = try arena_allocator.dupe(u8, result.eval_id),
        .service_name = try arena_allocator.dupe(u8, result.service_name),
        .model = try arena_allocator.dupe(u8, result.model),
        .run_index = result.run_index,
        .case_id = try arena_allocator.dupe(u8, result.case_id),
        .output = try arena_allocator.dupe(u8, result.output),
        .passed = result.passed,
        .score = result.score,
        .failure_reason = if (result.failure_reason) |reason| try arena_allocator.dupe(u8, reason) else null,
        .attempt_count = result.attempt_count,
        .retried = result.retried,
        .latency_ms = result.latency_ms,
    });
}

fn evalMatchesFilters(eval_definition: registry.EvalDefinition, options: RunnerOptions) bool {
    if (options.group_filter) |group| {
        if (!std.mem.eql(u8, eval_definition.group, group)) return false;
    }
    if (options.eval_filter) |id| {
        if (!std.mem.eql(u8, eval_definition.id, id)) return false;
    }
    return true;
}

fn serviceMatchesFilters(
    service: services.ServiceConfig,
    eval_definition: registry.EvalDefinition,
    options: RunnerOptions,
) bool {
    if (options.service_filter) |name| {
        if (!std.mem.eql(u8, service.name, name)) return false;
    }
    if (eval_definition.service_allowlist) |allowlist| {
        for (allowlist) |allowed| {
            if (std.mem.eql(u8, service.name, allowed)) return true;
        }
        return false;
    }
    return true;
}

fn findServiceByName(configured_services: []const services.ServiceConfig, name: []const u8) ?services.ServiceConfig {
    for (configured_services) |service| {
        if (std.mem.eql(u8, service.name, name)) return service;
    }
    return null;
}

fn elapsedMillis(started_at: i64) u64 {
    const finished_at = std.time.milliTimestamp();
    if (finished_at <= started_at) return 0;
    return @intCast(finished_at - started_at);
}

fn defaultServiceCaller(
    allocator: std.mem.Allocator,
    service: services.ServiceConfig,
    input: services.ChatCallInput,
) anyerror!services.ChatCallOutput {
    return services.callChatCompletion(allocator, service, input);
}

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

test "runEvaluations filters services by eval allowlist" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeDataset(tmp.dir, "cases.jsonl", "case-1", "prompt");

    const allowlist = [_][]const u8{"svc-allowed"};
    const evals = [_]registry.EvalDefinition{evalDefinition("eval.allowlist", "cases.jsonl", allowlist[0..])};
    const configured_services = [_]services.ServiceConfig{
        serviceConfig("svc-allowed"),
        serviceConfig("svc-blocked"),
    };

    var result = try runEvaluations(std.testing.allocator, .{
        .root_dir = tmp.dir,
        .services = configured_services[0..],
        .evals = evals[0..],
        .service_caller = fakeServiceCaller,
        .matcher_evaluator = fakeMatcherPass,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.runs.len);
    try std.testing.expectEqualStrings("svc-allowed", result.runs[0].service_name);
}

test "runEvaluations applies run count override" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeDataset(tmp.dir, "cases.jsonl", "case-1", "prompt");

    const evals = [_]registry.EvalDefinition{evalDefinition("eval.repeat", "cases.jsonl", null)};
    const configured_services = [_]services.ServiceConfig{serviceConfig("svc")};

    var result = try runEvaluations(std.testing.allocator, .{
        .root_dir = tmp.dir,
        .services = configured_services[0..],
        .evals = evals[0..],
        .run_count_override = 3,
        .service_caller = fakeServiceCaller,
        .matcher_evaluator = fakeMatcherPass,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.runs.len);
    try std.testing.expectEqual(@as(u32, 1), result.runs[0].run_index);
    try std.testing.expectEqual(@as(u32, 2), result.runs[1].run_index);
    try std.testing.expectEqual(@as(u32, 3), result.runs[2].run_index);
}

test "runEvaluations converts service failure into failed result" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeDataset(tmp.dir, "cases.jsonl", "case-1", "prompt");

    const evals = [_]registry.EvalDefinition{evalDefinition("eval.failure", "cases.jsonl", null)};
    const configured_services = [_]services.ServiceConfig{serviceConfig("svc")};

    var result = try runEvaluations(std.testing.allocator, .{
        .root_dir = tmp.dir,
        .services = configured_services[0..],
        .evals = evals[0..],
        .service_caller = fakeServiceFailure,
        .matcher_evaluator = fakeMatcherPass,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.runs.len);
    try std.testing.expect(!result.runs[0].passed);
    try std.testing.expectEqual(@as(f64, 0.0), result.runs[0].score);
    try std.testing.expectEqualStrings("FakeServiceFailure", result.runs[0].failure_reason.?);
}

test "runEvaluations records successful service output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeDataset(tmp.dir, "cases.jsonl", "case-1", "prompt");

    const evals = [_]registry.EvalDefinition{evalDefinition("eval.success", "cases.jsonl", null)};
    const configured_services = [_]services.ServiceConfig{serviceConfig("svc")};

    var result = try runEvaluations(std.testing.allocator, .{
        .root_dir = tmp.dir,
        .services = configured_services[0..],
        .evals = evals[0..],
        .service_caller = fakeServiceCaller,
        .matcher_evaluator = fakeMatcherPass,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.runs.len);
    try std.testing.expect(result.runs[0].passed);
    try std.testing.expectEqualStrings("OK", result.runs[0].output);
    try std.testing.expectEqualStrings("test-model", result.runs[0].model);
}

test "runEvaluations executes model_grade through judge service" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeDataset(tmp.dir, "cases.jsonl", "case-1", "prompt");

    const allowlist = [_][]const u8{"product"};
    const evals = [_]registry.EvalDefinition{evalDefinitionWithMatcher(
        "eval.model_grade",
        "cases.jsonl",
        allowlist[0..],
        .{
            .model_grade = .{
                .judge_service = "judge",
                .judge_model = "judge-model",
                .rubric = "Score correctness.",
                .pass_score = 0.8,
            },
        },
    )};
    const configured_services = [_]services.ServiceConfig{
        serviceConfig("product"),
        serviceConfig("judge"),
    };

    var result = try runEvaluations(std.testing.allocator, .{
        .root_dir = tmp.dir,
        .services = configured_services[0..],
        .evals = evals[0..],
        .service_caller = fakeModelGradeServiceCaller,
        .matcher_evaluator = fakeMatcherPass,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.runs.len);
    try std.testing.expect(result.runs[0].passed);
    try std.testing.expectEqual(@as(f64, 0.9), result.runs[0].score);
    try std.testing.expectEqualStrings("product", result.runs[0].service_name);
    try std.testing.expectEqualStrings("candidate answer", result.runs[0].output);
}

test "runEvaluations fails model_grade when judge service is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeDataset(tmp.dir, "cases.jsonl", "case-1", "prompt");

    const allowlist = [_][]const u8{"product"};
    const evals = [_]registry.EvalDefinition{evalDefinitionWithMatcher(
        "eval.model_grade",
        "cases.jsonl",
        allowlist[0..],
        .{
            .model_grade = .{
                .judge_service = "missing-judge",
                .rubric = "Score correctness.",
            },
        },
    )};
    const configured_services = [_]services.ServiceConfig{serviceConfig("product")};

    var result = try runEvaluations(std.testing.allocator, .{
        .root_dir = tmp.dir,
        .services = configured_services[0..],
        .evals = evals[0..],
        .service_caller = fakeModelGradeServiceCaller,
        .matcher_evaluator = fakeMatcherPass,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.runs.len);
    try std.testing.expect(!result.runs[0].passed);
    try std.testing.expectEqualStrings("JudgeServiceNotFound", result.runs[0].failure_reason.?);
}

test "runEvaluations fails model_grade for invalid judge json" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeDataset(tmp.dir, "cases.jsonl", "case-1", "prompt");

    const allowlist = [_][]const u8{"product"};
    const evals = [_]registry.EvalDefinition{evalDefinitionWithMatcher(
        "eval.model_grade",
        "cases.jsonl",
        allowlist[0..],
        .{
            .model_grade = .{
                .judge_service = "judge",
                .rubric = "Score correctness.",
            },
        },
    )};
    const configured_services = [_]services.ServiceConfig{
        serviceConfig("product"),
        serviceConfig("judge"),
    };

    var result = try runEvaluations(std.testing.allocator, .{
        .root_dir = tmp.dir,
        .services = configured_services[0..],
        .evals = evals[0..],
        .service_caller = fakeInvalidJudgeServiceCaller,
        .matcher_evaluator = fakeMatcherPass,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.runs.len);
    try std.testing.expect(!result.runs[0].passed);
    try std.testing.expectEqualStrings("InvalidModelGradeJudgeOutput", result.runs[0].failure_reason.?);
}

test "runEvaluations records model_grade failure reason from judge" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeDataset(tmp.dir, "cases.jsonl", "case-1", "prompt");

    const allowlist = [_][]const u8{"product"};
    const evals = [_]registry.EvalDefinition{evalDefinitionWithMatcher(
        "eval.model_grade",
        "cases.jsonl",
        allowlist[0..],
        .{
            .model_grade = .{
                .judge_service = "judge",
                .rubric = "Score correctness.",
                .pass_score = 0.8,
            },
        },
    )};
    const configured_services = [_]services.ServiceConfig{
        serviceConfig("product"),
        serviceConfig("judge"),
    };

    var result = try runEvaluations(std.testing.allocator, .{
        .root_dir = tmp.dir,
        .services = configured_services[0..],
        .evals = evals[0..],
        .service_caller = fakeFailingJudgeServiceCaller,
        .matcher_evaluator = fakeMatcherPass,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.runs.len);
    try std.testing.expect(!result.runs[0].passed);
    try std.testing.expectEqual(@as(f64, 0.4), result.runs[0].score);
    try std.testing.expectEqualStrings("Missing key facts.", result.runs[0].failure_reason.?);
}

test "runEvaluations returns dataset load failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const evals = [_]registry.EvalDefinition{evalDefinition("eval.missing", "missing.jsonl", null)};
    const configured_services = [_]services.ServiceConfig{serviceConfig("svc")};

    try std.testing.expectError(error.FileNotFound, runEvaluations(std.testing.allocator, .{
        .root_dir = tmp.dir,
        .services = configured_services[0..],
        .evals = evals[0..],
        .service_caller = fakeServiceCaller,
        .matcher_evaluator = fakeMatcherPass,
    }));
}

test "RunResult stores retry metadata" {
    const result = RunResult{
        .group = "retry_group",
        .eval_id = "retry.eval",
        .service_name = "retry-service",
        .model = "test-model",
        .run_index = 1,
        .case_id = "case-1",
        .output = "hello",
        .passed = true,
        .score = 1.0,
        .failure_reason = null,
        .attempt_count = 3,
        .retried = true,
        .latency_ms = 250,
    };

    try std.testing.expectEqual(@as(u32, 3), result.attempt_count);
    try std.testing.expect(result.retried);
}

fn evalDefinition(
    id: []const u8,
    dataset_path: []const u8,
    service_allowlist: ?[]const []const u8,
) registry.EvalDefinition {
    return evalDefinitionWithMatcher(id, dataset_path, service_allowlist, .{ .exact_match = .{} });
}

fn evalDefinitionWithMatcher(
    id: []const u8,
    dataset_path: []const u8,
    service_allowlist: ?[]const []const u8,
    matcher: matchers.MatcherConfig,
) registry.EvalDefinition {
    return .{
        .id = id,
        .group = "quality",
        .description = "test eval",
        .dataset_path = dataset_path,
        .split = "test",
        .matcher = matcher,
        .default_run_count = 1,
        .service_allowlist = service_allowlist,
    };
}

fn serviceConfig(name: []const u8) services.ServiceConfig {
    return .{
        .name = name,
        .base_url = "http://127.0.0.1:8080/v1",
        .default_model = "test-model",
        .timeout_ms = 1000,
    };
}

fn writeDataset(
    dir: std.fs.Dir,
    path: []const u8,
    id: []const u8,
    input: []const u8,
) !void {
    const content = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"id\":\"{s}\",\"input\":\"{s}\",\"ideal\":\"OK\"}}\n",
        .{ id, input },
    );
    defer std.testing.allocator.free(content);
    try dir.writeFile(.{ .sub_path = path, .data = content });
}

fn fakeServiceCaller(
    allocator: std.mem.Allocator,
    service: services.ServiceConfig,
    input: services.ChatCallInput,
) anyerror!services.ChatCallOutput {
    _ = input;
    return .{
        .content = try allocator.dupe(u8, "OK"),
        .model = try allocator.dupe(u8, service.default_model),
        .status_code = 200,
    };
}

fn fakeServiceFailure(
    allocator: std.mem.Allocator,
    service: services.ServiceConfig,
    input: services.ChatCallInput,
) anyerror!services.ChatCallOutput {
    _ = allocator;
    _ = service;
    _ = input;
    return error.FakeServiceFailure;
}

fn fakeModelGradeServiceCaller(
    allocator: std.mem.Allocator,
    service: services.ServiceConfig,
    input: services.ChatCallInput,
) anyerror!services.ChatCallOutput {
    if (std.mem.eql(u8, service.name, "judge")) {
        if (input.model_override == null or !std.mem.eql(u8, input.model_override.?, "judge-model")) {
            return error.ExpectedJudgeModelOverride;
        }
        if (std.mem.indexOf(u8, input.prompt, "candidate answer") == null) {
            return error.ExpectedCandidateOutputInJudgePrompt;
        }
        return .{
            .content = try allocator.dupe(u8, "{\"score\":0.9,\"passed\":true,\"reason\":\"Correct.\"}"),
            .model = try allocator.dupe(u8, "judge-model"),
            .status_code = 200,
        };
    }

    return .{
        .content = try allocator.dupe(u8, "candidate answer"),
        .model = try allocator.dupe(u8, service.default_model),
        .status_code = 200,
    };
}

fn fakeInvalidJudgeServiceCaller(
    allocator: std.mem.Allocator,
    service: services.ServiceConfig,
    input: services.ChatCallInput,
) anyerror!services.ChatCallOutput {
    _ = input;
    if (std.mem.eql(u8, service.name, "judge")) {
        return .{
            .content = try allocator.dupe(u8, "not json"),
            .model = try allocator.dupe(u8, service.default_model),
            .status_code = 200,
        };
    }

    return .{
        .content = try allocator.dupe(u8, "candidate answer"),
        .model = try allocator.dupe(u8, service.default_model),
        .status_code = 200,
    };
}

fn fakeFailingJudgeServiceCaller(
    allocator: std.mem.Allocator,
    service: services.ServiceConfig,
    input: services.ChatCallInput,
) anyerror!services.ChatCallOutput {
    _ = input;
    if (std.mem.eql(u8, service.name, "judge")) {
        return .{
            .content = try allocator.dupe(u8, "{\"score\":0.4,\"passed\":false,\"reason\":\"Missing key facts.\"}"),
            .model = try allocator.dupe(u8, service.default_model),
            .status_code = 200,
        };
    }

    return .{
        .content = try allocator.dupe(u8, "candidate answer"),
        .model = try allocator.dupe(u8, service.default_model),
        .status_code = 200,
    };
}

fn fakeMatcherPass(
    allocator: std.mem.Allocator,
    matcher: matchers.MatcherConfig,
    output: []const u8,
    ideal: ?[]const u8,
) anyerror!MatcherOutcome {
    _ = allocator;
    _ = matcher;
    _ = output;
    _ = ideal;
    return .{ .passed = true, .score = 1.0 };
}
