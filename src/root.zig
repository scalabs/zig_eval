pub const registry = @import("registry/root.zig");
pub const services = @import("services/root.zig");
pub const matchers = @import("matchers/root.zig");
pub const runner = @import("runner/root.zig");
pub const reporting = @import("reporting/root.zig");
pub const cli = @import("cli/root.zig");

test {
    _ = registry;
    _ = services;
    _ = matchers;
    _ = runner;
    _ = reporting;
    _ = cli;
}
