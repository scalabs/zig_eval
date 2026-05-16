const std = @import("std");
const zig_eval = @import("zig_eval");

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();

    zig_eval.cli.run(allocator, args[1..], &out.writer) catch |err| switch (err) {
        error.InvalidArguments => try zig_eval.cli.writeUsage(&out.writer),
        else => return err,
    };

    try std.fs.File.stdout().writeAll(out.written());
}
