const std = @import("std");
const matchers = @import("../matchers/root.zig");
const registry = @import("../registry/root.zig");
const services = @import("../services/root.zig");
const Thread = std.Thread;
const Mutex = Thread.Mutex;

pub const max_run_count = 10_000;
pub const max_parallelism = 256;
pub const max_inflight_per_service = 256;

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
    status_code: ?u16 = null,
    attempt_count: u32 = 1,
    retried: bool = false,
    judge_attempt_count: u32 = 0,
    judge_retried: bool = false,
    judge_status_code: ?u16 = null,
    latency_ms: u64,
};

pub const MatcherOutcome = struct {
    passed: bool,
    score: f64,
    failure_reason: ?[]const u8 = null,
    owned_failure_reason: ?[]u8 = null,
    judge_attempt_count: u32 = 0,
    judge_retried: bool = false,
    judge_status_code: ?u16 = null,
};

pub const ServiceCaller = *const fn (
    allocator: std.mem.Allocator,
    service: services.ServiceConfig,
    input: services.ChatCallInput,
) anyerror!services.ChatCallResult;

pub const MatcherEvaluator = *const fn (
    allocator: std.mem.Allocator,
    matcher: matchers.MatcherConfig,
    output: []const u8,
    ideal: ?[]const u8,
    tool_calls: ?[]const services.ToolCall,
    expected_tool_calls: ?[]const registry.ExpectedToolCall,
) anyerror!MatcherOutcome;

pub const RunnerOptions = struct {
    root_dir: std.fs.Dir,
    services: []const services.ServiceConfig,
    evals: []const registry.EvalDefinition,
    service_filter: ?[]const u8 = null,
    group_filter: ?[]const u8 = null,
    eval_filter: ?[]const u8 = null,
    judge_service_override: ?[]const u8 = null,
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
    first_error: *?anyerror,
    error_mutex: *Mutex,
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
    if (options.parallelism == 0) return error.InvalidParallelism;
    if (options.parallelism > max_parallelism) return error.InvalidParallelism;
    if (options.max_inflight_per_service == 0) return error.InvalidMaxInflightPerService;
    if (options.max_inflight_per_service > max_inflight_per_service) {
        return error.InvalidMaxInflightPerService;
    }

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
        var first_error: ?anyerror = null;
        var error_mutex = Mutex{};
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
            .first_error = &first_error,
            .error_mutex = &error_mutex,
            .options = options,
        };

        for (threads, 0..) |*thread, index| {
            _ = index;
            thread.* = try Thread.spawn(.{}, workerLoop, .{&context});
        }

        for (threads) |thread| {
            thread.join();
        }

        if (first_error) |err| return err;
    }

    std.mem.sort(RunResult, runs.items, {}, compareRunResults);

    return .{
        .parent_allocator = allocator,
        .arena = arena,
        .runs = try arena.allocator().dupe(RunResult, runs.items),
    };
}

fn workerLoop(context: *WorkerContext) void {
    while (true) {
        if (hasWorkerError(context)) return;

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

        runOneCase(
            context.allocator,
            context.arena_allocator,
            context.runs,
            context.runs_mutex,
            context.options,
            task.eval_definition,
            task.service,
            task.case,
            task.run_index,
        ) catch |err| {
            recordWorkerError(context, err);
            return;
        };

        context.progress_mutex.lock();
        defer context.progress_mutex.unlock();

        context.completed_count.* += 1;

        if (context.options.show_progress) {
            if (context.options.progress_writer) |writer| {
                writer.print(
                    "completed {d}/{d} eval runs\n",
                    .{ context.completed_count.*, context.tasks.len },
                ) catch |err| {
                    recordWorkerError(context, err);
                    return;
                };
                writer.flush() catch |err| {
                    recordWorkerError(context, err);
                    return;
                };
            }
        }
    }
}

fn hasWorkerError(context: *WorkerContext) bool {
    context.error_mutex.lock();
    defer context.error_mutex.unlock();
    return context.first_error.* != null;
}

fn recordWorkerError(context: *WorkerContext, err: anyerror) void {
    context.error_mutex.lock();
    defer context.error_mutex.unlock();
    if (context.first_error.* == null) {
        context.first_error.* = err;
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
        if (run_count > max_run_count) return error.InvalidRunCount;

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
                        .case = try copyEvalCaseForTask(arena_allocator, case),
                        .run_index = run_index,
                    });
                }
            }
        }
    }

    return tasks;
}

fn copyEvalCaseForTask(
    allocator: std.mem.Allocator,
    case: registry.EvalCase,
) !registry.EvalCase {
    return .{
        .id = try allocator.dupe(u8, case.id),
        .input = try allocator.dupe(u8, case.input),
        .ideal = if (case.ideal) |ideal| try allocator.dupe(u8, ideal) else null,
        .expected_tool_calls = try copyExpectedToolCalls(allocator, case.expected_tool_calls),
        .attachments = try copyAttachments(allocator, case.attachments),
    };
}

fn copyExpectedToolCalls(
    allocator: std.mem.Allocator,
    expected_tool_calls: ?[]const registry.ExpectedToolCall,
) !?[]const registry.ExpectedToolCall {
    const calls = expected_tool_calls orelse return null;
    const copied = try allocator.alloc(registry.ExpectedToolCall, calls.len);
    for (calls, copied) |call, *target| {
        target.* = .{
            .name = try allocator.dupe(u8, call.name),
            .arguments_json = if (call.arguments_json) |arguments_json|
                try allocator.dupe(u8, arguments_json)
            else
                null,
        };
    }
    return copied;
}

fn copyAttachments(
    allocator: std.mem.Allocator,
    attachments: ?[]const registry.Attachment,
) !?[]const registry.Attachment {
    const source = attachments orelse return null;
    const copied = try allocator.alloc(registry.Attachment, source.len);
    for (source, copied) |attachment, *target| {
        target.* = .{
            .kind = attachment.kind,
            .path = try allocator.dupe(u8, attachment.path),
            .mime_type = if (attachment.mime_type) |mime_type|
                try allocator.dupe(u8, mime_type)
            else
                null,
            .label = if (attachment.label) |label|
                try allocator.dupe(u8, label)
            else
                null,
        };
    }
    return copied;
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
    const input = services.ChatCallInput{
        .prompt = case.input,
        .tools = eval_definition.tools,
        .attachments = case.attachments,
        .attachment_dir = options.root_dir,
    };
    const started_at = std.time.milliTimestamp();

    var call_result = options.service_caller(temp_allocator, service, input) catch |err| {
        if (err == error.OutOfMemory) return err;
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
    defer call_result.deinit(temp_allocator);

    const output = switch (call_result) {
        .success => |*success| success,
        .failure => |*failure| {
            runs_mutex.lock();
            defer runs_mutex.unlock();

            try appendRunResult(temp_allocator, arena_allocator, runs, .{
                .group = eval_definition.group,
                .eval_id = eval_definition.id,
                .service_name = service.name,
                .model = failure.model,
                .run_index = run_index,
                .case_id = case.id,
                .output = "",
                .passed = false,
                .score = 0.0,
                .failure_reason = failure.reason,
                .status_code = failure.status_code,
                .attempt_count = failure.attempt_count,
                .retried = failure.retried,
                .latency_ms = elapsedMillis(started_at),
            });
            return;
        },
    };

    const outcome = outcome: {
        break :outcome evaluateRunMatcher(
            temp_allocator,
            options,
            eval_definition.matcher,
            case.input,
            output.content,
            case.ideal,
            output.tool_calls,
            case.expected_tool_calls,
        ) catch |err| {
            if (err == error.OutOfMemory) return err;
            break :outcome MatcherOutcome{
                .passed = false,
                .score = 0.0,
                .failure_reason = @errorName(err),
            };
        };
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
        .status_code = output.status_code,
        .attempt_count = output.attempt_count + outcome.judge_attempt_count,
        .retried = output.retried or outcome.judge_retried,
        .judge_attempt_count = outcome.judge_attempt_count,
        .judge_retried = outcome.judge_retried,
        .judge_status_code = outcome.judge_status_code,
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
    tool_calls: ?[]const services.ToolCall,
    expected_tool_calls: ?[]const registry.ExpectedToolCall,
) !MatcherOutcome {
    return switch (matcher) {
        .model_grade => |config| evaluateModelGradeMatcher(allocator, options, config, input, output, ideal),
        else => options.matcher_evaluator(
            allocator,
            matcher,
            output,
            ideal,
            tool_calls,
            expected_tool_calls,
        ),
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
    const judge_service_name = options.judge_service_override orelse config.judge_service;
    const judge_service = findServiceByName(options.services, judge_service_name) orelse {
        return error.JudgeServiceNotFound;
    };

    const prompt = try matchers.renderModelGradePrompt(allocator, config, .{
        .input = input,
        .output = output,
        .ideal = ideal,
    });
    defer allocator.free(prompt);

    var judge_result = try options.service_caller(allocator, judge_service, .{
        .prompt = prompt,
        .model_override = config.judge_model,
    });
    defer judge_result.deinit(allocator);

    const judge_output = switch (judge_result) {
        .success => |*success| success,
        .failure => |*failure| {
            const owned_reason = try allocator.dupe(u8, failure.reason);
            return .{
                .passed = false,
                .score = 0.0,
                .failure_reason = owned_reason,
                .owned_failure_reason = owned_reason,
                .judge_attempt_count = failure.attempt_count,
                .judge_retried = failure.retried,
                .judge_status_code = failure.status_code,
            };
        },
    };

    var outcome = parseJudgeOutcome(allocator, judge_output.content, config.pass_score) catch |err| {
        if (err == error.OutOfMemory) return err;
        return .{
            .passed = false,
            .score = 0.0,
            .failure_reason = @errorName(err),
            .judge_attempt_count = judge_output.attempt_count,
            .judge_retried = judge_output.retried,
            .judge_status_code = judge_output.status_code,
        };
    };
    outcome.judge_attempt_count = judge_output.attempt_count;
    outcome.judge_retried = judge_output.retried;
    outcome.judge_status_code = judge_output.status_code;
    return outcome;
}

fn parseJudgeOutcome(
    allocator: std.mem.Allocator,
    raw: []const u8,
    pass_score: f64,
) !MatcherOutcome {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch |err| {
        if (err == error.OutOfMemory) return err;
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
        .status_code = result.status_code,
        .attempt_count = result.attempt_count,
        .retried = result.retried,
        .judge_attempt_count = result.judge_attempt_count,
        .judge_retried = result.judge_retried,
        .judge_status_code = result.judge_status_code,
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
) anyerror!services.ChatCallResult {
    return services.callChatCompletionResult(allocator, service, input);
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

test "runEvaluations can override model_grade judge service" {
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
                .judge_service = "default-judge",
                .rubric = "Score correctness.",
                .pass_score = 0.8,
            },
        },
    )};
    const configured_services = [_]services.ServiceConfig{
        serviceConfig("product"),
        serviceConfig("override-judge"),
    };

    var result = try runEvaluations(std.testing.allocator, .{
        .root_dir = tmp.dir,
        .services = configured_services[0..],
        .evals = evals[0..],
        .judge_service_override = "override-judge",
        .service_caller = fakeOverrideJudgeServiceCaller,
        .matcher_evaluator = fakeMatcherPass,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.runs.len);
    try std.testing.expect(result.runs[0].passed);
    try std.testing.expectEqual(@as(f64, 0.95), result.runs[0].score);
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

test "runEvaluations rejects zero parallelism" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const evals = [_]registry.EvalDefinition{evalDefinition("eval.invalid", "cases.jsonl", null)};
    const configured_services = [_]services.ServiceConfig{serviceConfig("svc")};

    try std.testing.expectError(error.InvalidParallelism, runEvaluations(std.testing.allocator, .{
        .root_dir = tmp.dir,
        .services = configured_services[0..],
        .evals = evals[0..],
        .parallelism = 0,
        .service_caller = fakeServiceCaller,
        .matcher_evaluator = fakeMatcherPass,
    }));
}

test "runEvaluations rejects excessive parallelism" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const evals = [_]registry.EvalDefinition{evalDefinition("eval.invalid", "cases.jsonl", null)};
    const configured_services = [_]services.ServiceConfig{serviceConfig("svc")};

    try std.testing.expectError(error.InvalidParallelism, runEvaluations(std.testing.allocator, .{
        .root_dir = tmp.dir,
        .services = configured_services[0..],
        .evals = evals[0..],
        .parallelism = max_parallelism + 1,
        .service_caller = fakeServiceCaller,
        .matcher_evaluator = fakeMatcherPass,
    }));
}

test "runEvaluations rejects zero max inflight per service" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const evals = [_]registry.EvalDefinition{evalDefinition("eval.invalid", "cases.jsonl", null)};
    const configured_services = [_]services.ServiceConfig{serviceConfig("svc")};

    try std.testing.expectError(error.InvalidMaxInflightPerService, runEvaluations(std.testing.allocator, .{
        .root_dir = tmp.dir,
        .services = configured_services[0..],
        .evals = evals[0..],
        .max_inflight_per_service = 0,
        .service_caller = fakeServiceCaller,
        .matcher_evaluator = fakeMatcherPass,
    }));
}

test "runEvaluations rejects excessive max inflight per service" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const evals = [_]registry.EvalDefinition{evalDefinition("eval.invalid", "cases.jsonl", null)};
    const configured_services = [_]services.ServiceConfig{serviceConfig("svc")};

    try std.testing.expectError(error.InvalidMaxInflightPerService, runEvaluations(std.testing.allocator, .{
        .root_dir = tmp.dir,
        .services = configured_services[0..],
        .evals = evals[0..],
        .max_inflight_per_service = max_inflight_per_service + 1,
        .service_caller = fakeServiceCaller,
        .matcher_evaluator = fakeMatcherPass,
    }));
}

test "runEvaluations rejects excessive run count override" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const evals = [_]registry.EvalDefinition{evalDefinition("eval.invalid", "cases.jsonl", null)};
    const configured_services = [_]services.ServiceConfig{serviceConfig("svc")};

    try std.testing.expectError(error.InvalidRunCount, runEvaluations(std.testing.allocator, .{
        .root_dir = tmp.dir,
        .services = configured_services[0..],
        .evals = evals[0..],
        .run_count_override = max_run_count + 1,
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

test "runEvaluations records detailed service failure retry metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeDataset(tmp.dir, "cases.jsonl", "case-1", "prompt");

    const evals = [_]registry.EvalDefinition{evalDefinition("eval.retry_failure", "cases.jsonl", null)};
    const configured_services = [_]services.ServiceConfig{serviceConfig("svc")};

    var result = try runEvaluations(std.testing.allocator, .{
        .root_dir = tmp.dir,
        .services = configured_services[0..],
        .evals = evals[0..],
        .service_caller = fakeDetailedServiceFailure,
        .matcher_evaluator = fakeMatcherPass,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.runs.len);
    try std.testing.expect(!result.runs[0].passed);
    try std.testing.expectEqualStrings("upstream unavailable", result.runs[0].failure_reason.?);
    try std.testing.expectEqual(@as(u16, 503), result.runs[0].status_code.?);
    try std.testing.expectEqual(@as(u32, 3), result.runs[0].attempt_count);
    try std.testing.expect(result.runs[0].retried);
}

test "runEvaluations records model_grade judge retry metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeDataset(tmp.dir, "cases.jsonl", "case-1", "prompt");

    const allowlist = [_][]const u8{"product"};
    const evals = [_]registry.EvalDefinition{evalDefinitionWithMatcher(
        "eval.model_grade_retry",
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
        .service_caller = fakeRetryingJudgeServiceCaller,
        .matcher_evaluator = fakeMatcherPass,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.runs.len);
    try std.testing.expect(result.runs[0].passed);
    try std.testing.expectEqual(@as(u32, 4), result.runs[0].attempt_count);
    try std.testing.expect(result.runs[0].retried);
    try std.testing.expectEqual(@as(u32, 3), result.runs[0].judge_attempt_count);
    try std.testing.expect(result.runs[0].judge_retried);
    try std.testing.expectEqual(@as(u16, 200), result.runs[0].judge_status_code.?);
}

test "runEvaluations propagates parallel worker progress writer errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeDataset(tmp.dir, "cases.jsonl", "case-1", "prompt");

    const evals = [_]registry.EvalDefinition{evalDefinition("eval.worker_error", "cases.jsonl", null)};
    const configured_services = [_]services.ServiceConfig{serviceConfig("svc")};
    var failing_writer = std.Io.Writer{
        .vtable = &failing_writer_vtable,
        .buffer = &.{},
    };

    try std.testing.expectError(error.WriteFailed, runEvaluations(std.testing.allocator, .{
        .root_dir = tmp.dir,
        .services = configured_services[0..],
        .evals = evals[0..],
        .parallelism = 2,
        .show_progress = true,
        .progress_writer = &failing_writer,
        .service_caller = fakeServiceCaller,
        .matcher_evaluator = fakeMatcherPass,
    }));
}

test "runEvaluations runs tool_call evals with loaded expected calls" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{
        .sub_path = "tool_cases.jsonl",
        .data = "{\"id\":\"case-1\",\"input\":\"Search weather\",\"expected_tool_calls\":[{\"name\":\"search_web\",\"arguments_json\":\"{\\\"query\\\":\\\"weather melbourne\\\"}\"}]}\n",
    });

    const allowlist = [_][]const u8{"product"};
    const tools = [_]registry.ToolDefinition{
        .{
            .name = "search_web",
            .description = "Search the web",
            .parameters_json = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"}}}",
        },
    };
    const evals = [_]registry.EvalDefinition{
        .{
            .id = "tools.search_web",
            .group = "tools",
            .description = "tool eval",
            .dataset_path = "tool_cases.jsonl",
            .split = "test",
            .matcher = .{ .tool_call = .{} },
            .default_run_count = 1,
            .service_allowlist = allowlist[0..],
            .tools = tools[0..],
        },
    };
    const configured_services = [_]services.ServiceConfig{serviceConfig("product")};

    var result = try runEvaluations(std.testing.allocator, .{
        .root_dir = tmp.dir,
        .services = configured_services[0..],
        .evals = evals[0..],
        .service_caller = fakeToolServiceCaller,
        .matcher_evaluator = evaluateMatcherForRunner,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.runs.len);
    try std.testing.expect(result.runs[0].passed);
    try std.testing.expectEqualStrings("tools.search_web", result.runs[0].eval_id);
}

test "runEvaluations passes attachments from loaded cases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("assets/changelogs");
    try tmp.dir.writeFile(.{
        .sub_path = "assets/changelogs/release.md",
        .data = "Retry support and parallel execution shipped.\n",
    });
    try tmp.dir.writeFile(.{
        .sub_path = "cases.jsonl",
        .data = "{\"id\":\"case-1\",\"input\":\"Summarize\",\"ideal\":\"OK\",\"attachments\":[{\"kind\":\"file\",\"path\":\"assets/changelogs/release.md\",\"mime_type\":\"text/markdown\",\"label\":\"release notes\"}]}\n",
    });

    const allowlist = [_][]const u8{"product"};
    const evals = [_]registry.EvalDefinition{evalDefinition("multimodal.release_notes", "cases.jsonl", allowlist[0..])};
    const configured_services = [_]services.ServiceConfig{serviceConfig("product")};

    var result = try runEvaluations(std.testing.allocator, .{
        .root_dir = tmp.dir,
        .services = configured_services[0..],
        .evals = evals[0..],
        .service_caller = fakeAttachmentServiceCaller,
        .matcher_evaluator = fakeMatcherPass,
    });
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.runs.len);
    try std.testing.expect(result.runs[0].passed);
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
) anyerror!services.ChatCallResult {
    _ = input;
    return fakeSuccess(allocator, service.default_model, "OK");
}

fn fakeServiceFailure(
    allocator: std.mem.Allocator,
    service: services.ServiceConfig,
    input: services.ChatCallInput,
) anyerror!services.ChatCallResult {
    _ = allocator;
    _ = service;
    _ = input;
    return error.FakeServiceFailure;
}

fn fakeDetailedServiceFailure(
    allocator: std.mem.Allocator,
    service: services.ServiceConfig,
    input: services.ChatCallInput,
) anyerror!services.ChatCallResult {
    _ = input;
    return .{
        .failure = .{
            .kind = .upstream_http_error,
            .reason = try allocator.dupe(u8, "upstream unavailable"),
            .model = try allocator.dupe(u8, service.default_model),
            .status_code = 503,
            .attempt_count = 3,
            .retried = true,
        },
    };
}

const failing_writer_vtable = std.Io.Writer.VTable{
    .drain = failingWriterDrain,
};

fn failingWriterDrain(
    writer: *std.Io.Writer,
    data: []const []const u8,
    splat: usize,
) std.Io.Writer.Error!usize {
    _ = writer;
    _ = data;
    _ = splat;
    return error.WriteFailed;
}

fn fakeModelGradeServiceCaller(
    allocator: std.mem.Allocator,
    service: services.ServiceConfig,
    input: services.ChatCallInput,
) anyerror!services.ChatCallResult {
    if (std.mem.eql(u8, service.name, "judge")) {
        if (input.model_override == null or !std.mem.eql(u8, input.model_override.?, "judge-model")) {
            return error.ExpectedJudgeModelOverride;
        }
        if (std.mem.indexOf(u8, input.prompt, "candidate answer") == null) {
            return error.ExpectedCandidateOutputInJudgePrompt;
        }
        return fakeSuccess(allocator, "judge-model", "{\"score\":0.9,\"passed\":true,\"reason\":\"Correct.\"}");
    }

    return fakeSuccess(allocator, service.default_model, "candidate answer");
}

fn fakeInvalidJudgeServiceCaller(
    allocator: std.mem.Allocator,
    service: services.ServiceConfig,
    input: services.ChatCallInput,
) anyerror!services.ChatCallResult {
    _ = input;
    if (std.mem.eql(u8, service.name, "judge")) {
        return fakeSuccess(allocator, service.default_model, "not json");
    }

    return fakeSuccess(allocator, service.default_model, "candidate answer");
}

fn fakeOverrideJudgeServiceCaller(
    allocator: std.mem.Allocator,
    service: services.ServiceConfig,
    input: services.ChatCallInput,
) anyerror!services.ChatCallResult {
    if (std.mem.eql(u8, service.name, "override-judge")) {
        if (std.mem.indexOf(u8, input.prompt, "candidate answer") == null) {
            return error.ExpectedCandidateOutputInJudgePrompt;
        }
        return fakeSuccess(allocator, service.default_model, "{\"score\":0.95,\"passed\":true,\"reason\":\"Strong answer.\"}");
    }

    if (std.mem.eql(u8, service.name, "default-judge")) {
        return error.DefaultJudgeShouldNotBeCalled;
    }

    return fakeSuccess(allocator, service.default_model, "candidate answer");
}

fn fakeFailingJudgeServiceCaller(
    allocator: std.mem.Allocator,
    service: services.ServiceConfig,
    input: services.ChatCallInput,
) anyerror!services.ChatCallResult {
    _ = input;
    if (std.mem.eql(u8, service.name, "judge")) {
        return fakeSuccess(allocator, service.default_model, "{\"score\":0.4,\"passed\":false,\"reason\":\"Missing key facts.\"}");
    }

    return fakeSuccess(allocator, service.default_model, "candidate answer");
}

fn fakeRetryingJudgeServiceCaller(
    allocator: std.mem.Allocator,
    service: services.ServiceConfig,
    input: services.ChatCallInput,
) anyerror!services.ChatCallResult {
    _ = input;
    if (std.mem.eql(u8, service.name, "judge")) {
        return .{
            .success = .{
                .content = try allocator.dupe(u8, "{\"score\":0.9,\"passed\":true,\"reason\":\"Correct.\"}"),
                .model = try allocator.dupe(u8, service.default_model),
                .status_code = 200,
                .attempt_count = 3,
                .retried = true,
            },
        };
    }

    return fakeSuccess(allocator, service.default_model, "candidate answer");
}

fn fakeToolServiceCaller(
    allocator: std.mem.Allocator,
    service: services.ServiceConfig,
    input: services.ChatCallInput,
) anyerror!services.ChatCallResult {
    if (input.tools == null or input.tools.?.len != 1) {
        return error.ExpectedToolSchemas;
    }

    const calls = try allocator.alloc(services.ToolCall, 1);
    calls[0] = .{
        .name = try allocator.dupe(u8, "search_web"),
        .arguments_json = try allocator.dupe(u8, "{\"query\":\"weather melbourne\"}"),
    };

    return .{
        .success = .{
            .content = try allocator.dupe(u8, ""),
            .model = try allocator.dupe(u8, service.default_model),
            .status_code = 200,
            .tool_calls = calls,
        },
    };
}

fn fakeAttachmentServiceCaller(
    allocator: std.mem.Allocator,
    service: services.ServiceConfig,
    input: services.ChatCallInput,
) anyerror!services.ChatCallResult {
    const attachments = input.attachments orelse return error.ExpectedAttachments;
    if (attachments.len != 1) return error.ExpectedAttachments;
    if (input.attachment_dir == null) return error.ExpectedAttachmentDir;
    if (!std.mem.eql(u8, attachments[0].path, "assets/changelogs/release.md")) {
        return error.ExpectedAttachmentPath;
    }

    return fakeSuccess(allocator, service.default_model, "OK");
}

fn fakeSuccess(
    allocator: std.mem.Allocator,
    model: []const u8,
    content: []const u8,
) !services.ChatCallResult {
    return .{
        .success = .{
            .content = try allocator.dupe(u8, content),
            .model = try allocator.dupe(u8, model),
            .status_code = 200,
        },
    };
}

fn evaluateMatcherForRunner(
    allocator: std.mem.Allocator,
    matcher: matchers.MatcherConfig,
    output: []const u8,
    ideal: ?[]const u8,
    tool_calls: ?[]const services.ToolCall,
    expected_tool_calls: ?[]const registry.ExpectedToolCall,
) anyerror!MatcherOutcome {
    const outcome = try matchers.evaluate(
        allocator,
        matcher,
        output,
        ideal,
        tool_calls,
        expected_tool_calls,
    );
    return .{
        .passed = outcome.passed,
        .score = outcome.score,
        .failure_reason = outcome.failure_reason,
    };
}

fn fakeMatcherPass(
    allocator: std.mem.Allocator,
    matcher: matchers.MatcherConfig,
    output: []const u8,
    ideal: ?[]const u8,
    tool_calls: ?[]const services.ToolCall,
    expected_tool_calls: ?[]const registry.ExpectedToolCall,
) anyerror!MatcherOutcome {
    _ = tool_calls;
    _ = expected_tool_calls;
    _ = allocator;
    _ = matcher;
    _ = output;
    _ = ideal;
    return .{ .passed = true, .score = 1.0 };
}

test "parseJudgeOutcome propagates out of memory" {
    var failing_allocator = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );

    try std.testing.expectError(
        error.OutOfMemory,
        parseJudgeOutcome(
            failing_allocator.allocator(),
            "{\"passed\":true,\"score\":1,\"reason\":\"ok\"}",
            0.5,
        ),
    );
}
