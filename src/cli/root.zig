const std = @import("std");
const matchers = @import("../matchers/root.zig");
const registry = @import("../registry/root.zig");
const reporting = @import("../reporting/root.zig");
const runner = @import("../runner/root.zig");
const services = @import("../services/root.zig");

pub const Command = enum {
    list,
    run,
};

pub const OutputFormat = enum {
    text,
    json,
};

pub const CliOptions = struct {
    command: Command,
    registry_path: []const u8 = "examples/registry",
    service_filter: ?[]const u8 = null,
    group_filter: ?[]const u8 = null,
    eval_filter: ?[]const u8 = null,
    judge_service_override: ?[]const u8 = null,
    run_count_override: ?u32 = null,
    parallelism: u32 = 1,
    max_inflight_per_service: u32 = 1,
    format: OutputFormat = .text,
};

pub const Dependencies = struct {
    service_caller: runner.ServiceCaller = defaultServiceCaller,
};

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    writer: *std.Io.Writer,
) !void {
    try runWithDependencies(allocator, args, writer, .{});
}

pub fn runWithDependencies(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    writer: *std.Io.Writer,
    dependencies: Dependencies,
) !void {
    const options = try parseArgs(args);

    var registry_dir = try std.fs.cwd().openDir(options.registry_path, .{});
    defer registry_dir.close();

    var loaded_services = try services.loadServices(allocator, registry_dir, "services.json");
    defer loaded_services.deinit();

    var loaded_evals = try registry.loadRegistryEvalDefinitions(allocator, registry_dir);
    defer loaded_evals.deinit();

    switch (options.command) {
        .list => try listRegistry(writer, loaded_services.items, loaded_evals.items),
        .run => try runRegistryEvals(
            allocator,
            writer,
            registry_dir,
            loaded_services.items,
            loaded_evals.items,
            options,
            dependencies,
        ),
    }
}

pub fn parseArgs(args: []const []const u8) !CliOptions {
    if (args.len == 0) return error.InvalidArguments;

    var options = CliOptions{
        .command = try parseCommand(args[0]),
    };

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];

        if (std.mem.eql(u8, arg, "--registry")) {
            options.registry_path = try nextValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--service")) {
            options.service_filter = try nextValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--group")) {
            options.group_filter = try nextValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--eval")) {
            options.eval_filter = try nextValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--judge-service")) {
            options.judge_service_override = try nextValue(args, &index);
        } else if (std.mem.eql(u8, arg, "--runs")) {
            options.run_count_override = try parsePositiveU32(try nextValue(args, &index));
        } else if (std.mem.eql(u8, arg, "--parallel")) {
            options.parallelism = try parsePositiveU32(try nextValue(args, &index));
        } else if (std.mem.eql(u8, arg, "--max-inflight-per-service")) {
            options.max_inflight_per_service = try parsePositiveU32(try nextValue(args, &index));
        } else if (std.mem.eql(u8, arg, "--format")) {
            options.format = try parseFormat(try nextValue(args, &index));
        } else {
            return error.InvalidArguments;
        }
    }

    return options;
}

pub fn writeUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage:
        \\  zig_eval list [--registry PATH]
        \\  zig_eval run [--registry PATH] [--service NAME] [--group GROUP] [--eval ID] [--judge-service NAME] [--runs N] [--parallel N] [--max-inflight-per-service N] [--format text|json]
        \\
    );
}

fn listRegistry(
    writer: *std.Io.Writer,
    service_items: []const services.ServiceConfig,
    eval_items: []const registry.EvalDefinition,
) !void {
    try writer.writeAll("services\n");
    for (service_items) |service| {
        try writer.print("  {s} model={s}\n", .{ service.name, service.default_model });
    }

    try writer.writeAll("evals\n");
    for (eval_items) |eval_definition| {
        try writer.print(
            "  {s} group={s} split={s}\n",
            .{ eval_definition.id, eval_definition.group, eval_definition.split },
        );
    }
}

fn runRegistryEvals(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    registry_dir: std.fs.Dir,
    service_items: []const services.ServiceConfig,
    eval_items: []const registry.EvalDefinition,
    options: CliOptions,
    dependencies: Dependencies,
) !void {
    var run_result = try runner.runEvaluations(allocator, .{
        .root_dir = registry_dir,
        .services = service_items,
        .evals = eval_items,
        .service_filter = options.service_filter,
        .group_filter = options.group_filter,
        .eval_filter = options.eval_filter,
        .judge_service_override = options.judge_service_override,
        .run_count_override = options.run_count_override,
        .parallelism = options.parallelism,
        .max_inflight_per_service = options.max_inflight_per_service,
        .show_progress = options.format == .text,
        .progress_writer = writer,
        .service_caller = dependencies.service_caller,
        .matcher_evaluator = evaluateMatcher,
    });
    defer run_result.deinit();

    var reports = try reporting.aggregateRunResults(allocator, run_result.runs);
    defer reports.deinit();

    switch (options.format) {
        .text => try reporting.formatEvalReports(writer, reports.items),
        .json => try reporting.formatEvalReportsJson(writer, reports.items),
    }
}

fn evaluateMatcher(
    allocator: std.mem.Allocator,
    matcher: matchers.MatcherConfig,
    output: []const u8,
    ideal: ?[]const u8,
) anyerror!runner.MatcherOutcome {
    const outcome = try matchers.evaluate(allocator, matcher, output, ideal);
    return .{
        .passed = outcome.passed,
        .score = outcome.score,
        .failure_reason = outcome.failure_reason,
    };
}

fn defaultServiceCaller(
    allocator: std.mem.Allocator,
    service: services.ServiceConfig,
    input: services.ChatCallInput,
) anyerror!services.ChatCallOutput {
    return services.callChatCompletion(allocator, service, input);
}

fn parseCommand(value: []const u8) !Command {
    if (std.mem.eql(u8, value, "list")) return .list;
    if (std.mem.eql(u8, value, "run")) return .run;
    return error.InvalidArguments;
}

fn parseFormat(value: []const u8) !OutputFormat {
    if (std.mem.eql(u8, value, "text")) return .text;
    if (std.mem.eql(u8, value, "json")) return .json;
    return error.InvalidArguments;
}

fn parsePositiveU32(value: []const u8) !u32 {
    const parsed = std.fmt.parseInt(u32, value, 10) catch return error.InvalidArguments;
    if (parsed == 0) return error.InvalidArguments;
    return parsed;
}

fn nextValue(args: []const []const u8, index: *usize) ![]const u8 {
    index.* += 1;
    if (index.* >= args.len) return error.InvalidArguments;
    const value = args[index.*];
    if (std.mem.startsWith(u8, value, "--")) return error.InvalidArguments;
    return value;
}

test "parseArgs supports list defaults" {
    const options = try parseArgs(&.{"list"});

    try std.testing.expectEqual(Command.list, options.command);
    try std.testing.expectEqualStrings("examples/registry", options.registry_path);
    try std.testing.expectEqual(OutputFormat.text, options.format);
}

test "parseArgs supports run filters and JSON output" {
    const options = try parseArgs(&.{
        "run",
        "--registry",
        "custom-registry",
        "--service",
        "local-product",
        "--group",
        "smoke",
        "--eval",
        "smoke.reply_ok",
        "--judge-service",
        "judge-alt",
        "--runs",
        "2",
        "--parallel",
        "4",
        "--format",
        "json",
    });

    try std.testing.expectEqual(Command.run, options.command);
    try std.testing.expectEqualStrings("custom-registry", options.registry_path);
    try std.testing.expectEqualStrings("local-product", options.service_filter.?);
    try std.testing.expectEqualStrings("smoke", options.group_filter.?);
    try std.testing.expectEqualStrings("smoke.reply_ok", options.eval_filter.?);
    try std.testing.expectEqualStrings("judge-alt", options.judge_service_override.?);
    try std.testing.expectEqual(@as(u32, 2), options.run_count_override.?);
    try std.testing.expectEqual(@as(u32, 4), options.parallelism);
    try std.testing.expectEqual(OutputFormat.json, options.format);
}

test "parseArgs rejects invalid args" {
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{}));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{"unknown"}));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "run", "--runs", "0" }));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "run", "--format", "xml" }));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "run", "--service" }));
    try std.testing.expectError(error.InvalidArguments, parseArgs(&.{ "run", "--judge-service" }));
}

test "runWithDependencies lists example registry" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try runWithDependencies(
        std.testing.allocator,
        &.{ "list", "--registry", "examples/registry" },
        &out.writer,
        .{ .service_caller = fakeServiceCaller },
    );

    const text = out.written();
    try std.testing.expect(std.mem.indexOf(u8, text, "services") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "local-product") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "smoke.reply_ok") != null);
}

test "runWithDependencies runs example eval with fake service" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try runWithDependencies(
        std.testing.allocator,
        &.{
            "run",
            "--registry",
            "examples/registry",
            "--service",
            "local-product",
            "--eval",
            "smoke.reply_ok",
            "--format",
            "json",
        },
        &out.writer,
        .{ .service_caller = fakeServiceCaller },
    );

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();

    const evals = parsed.value.object.get("evals").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), evals.len);
    const stats = evals[0].object.get("stats").?.object;
    try std.testing.expectEqual(@as(i64, 2), stats.get("counts").?.object.get("total_runs").?.integer);
    try std.testing.expectEqual(@as(i64, 2), stats.get("counts").?.object.get("passed").?.integer);
}

test "runWithDependencies forwards judge service override" {
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try runWithDependencies(
        std.testing.allocator,
        &.{
            "run",
            "--registry",
            "examples/registry",
            "--service",
            "local-product",
            "--eval",
            "quality.helpful_summary",
            "--judge-service",
            "missing-judge",
            "--format",
            "json",
        },
        &out.writer,
        .{ .service_caller = fakeServiceCaller },
    );

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.written(), .{});
    defer parsed.deinit();

    const evals = parsed.value.object.get("evals").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), evals.len);
    const stats = evals[0].object.get("stats").?.object;
    try std.testing.expectEqual(@as(i64, 2), stats.get("counts").?.object.get("total_runs").?.integer);
    try std.testing.expectEqual(@as(i64, 2), stats.get("counts").?.object.get("failed").?.integer);
}

fn fakeServiceCaller(
    allocator: std.mem.Allocator,
    service: services.ServiceConfig,
    input: services.ChatCallInput,
) anyerror!services.ChatCallOutput {
    const content = if (std.mem.eql(u8, service.name, "judge"))
        "{\"score\":0.9,\"passed\":true,\"reason\":\"Meets rubric.\"}"
    else if (std.mem.indexOf(u8, input.prompt, "READY") != null)
        "READY"
    else if (std.mem.indexOf(u8, input.prompt, "JSON object") != null)
        "{\"answer\":\"OK\"}"
    else
        "OK";

    return .{
        .content = try allocator.dupe(u8, content),
        .model = try allocator.dupe(u8, service.default_model),
        .status_code = 200,
    };
}
