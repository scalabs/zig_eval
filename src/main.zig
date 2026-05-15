const std = @import("std");
const registry = @import("zig_eval").registry;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printHelp();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "list")) {
        try listEvals(allocator);
    } else if (std.mem.eql(u8, command, "show")) {
        if (args.len < 3) {
            std.debug.print("Error: missing eval id\n\n", .{});
            std.debug.print("Usage: zig build run -- show <eval_id>\n", .{});
            return;
        }

        try showEval(allocator, args[2]);
    } else {
        std.debug.print("Unknown command: {s}\n\n", .{command});
        printHelp();
    }
}

fn printHelp() void {
    std.debug.print(
        \\zig_eval CLI
        \\
        \\Commands:
        \\  list                 List all eval definitions
        \\  show <eval_id>       Show one eval and its dataset cases
        \\
        \\Examples:
        \\  zig build run -- list
        \\  zig build run -- show smoke.reply_ok
        \\
    , .{});
}

fn listEvals(allocator: std.mem.Allocator) !void {
    const cwd = std.fs.cwd();

    var loaded = try registry.loadAllEvalDefinitions(
        allocator,
        cwd,
        "registry/evals",
    );
    defer loaded.deinit();

    if (loaded.items.len == 0) {
        std.debug.print("No evals found.\n", .{});
        return;
    }

    std.debug.print("Available evals:\n", .{});

    for (loaded.items) |eval_def| {
        std.debug.print(
            "  - {s} [{s}] {s}\n",
            .{
                eval_def.id,
                eval_def.group,
                eval_def.description,
            },
        );
    }
}

fn showEval(allocator: std.mem.Allocator, eval_id: []const u8) !void {
    const cwd = std.fs.cwd();

    var loaded = try registry.loadAllEvalDefinitions(
        allocator,
        cwd,
        "registry/evals",
    );
    defer loaded.deinit();

    const eval_def = findEvalById(loaded.items, eval_id) orelse {
        std.debug.print("Eval not found: {s}\n", .{eval_id});
        return;
    };

    std.debug.print("Eval ID: {s}\n", .{eval_def.id});
    std.debug.print("Group: {s}\n", .{eval_def.group});
    std.debug.print("Description: {s}\n", .{eval_def.description});
    std.debug.print("Dataset: {s}\n", .{eval_def.dataset_path});
    std.debug.print("Split: {s}\n", .{eval_def.split});
    std.debug.print("Default run count: {}\n\n", .{eval_def.default_run_count});

    var cases = try registry.loadEvalCases(
        allocator,
        cwd,
        eval_def.dataset_path,
    );
    defer cases.deinit();

    std.debug.print("Cases: {}\n", .{cases.items.len});

    for (cases.items) |case| {
        std.debug.print("\nCase ID: {s}\n", .{case.id});
        std.debug.print("Input: {s}\n", .{case.input});

        if (case.ideal) |ideal| {
            std.debug.print("Ideal: {s}\n", .{ideal});
        } else {
            std.debug.print("Ideal: null\n", .{});
        }
    }
}

fn findEvalById(
    items: []const registry.EvalDefinition,
    eval_id: []const u8,
) ?registry.EvalDefinition {
    for (items) |item| {
        if (std.mem.eql(u8, item.id, eval_id)) {
            return item;
        }
    }

    return null;
}