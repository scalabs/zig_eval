const std = @import("std");
const zig_eval = @import("zig_eval");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const out = &stdout_writer.interface;

    zig_eval.cli.run(allocator, args[1..], out) catch |err| switch (err) {
        error.InvalidArguments => try zig_eval.cli.writeUsage(out),
        else => return err,
    };

    try out.flush();
}
