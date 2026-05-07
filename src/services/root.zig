const std = @import("std");

const max_file_bytes = 1024 * 1024;

pub const ServiceConfig = struct {
    name: []const u8,
    base_url: []const u8,
    api_key_env: []const u8,
    default_model: []const u8,
    provider: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    timeout_ms: u32,
};

pub const LoadedServices = struct {
    parent_allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    items: []const ServiceConfig,

    pub fn deinit(self: *LoadedServices) void {
        self.arena.deinit();
        self.parent_allocator.destroy(self.arena);
        self.* = undefined;
    }
};

pub fn loadServices(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    path: []const u8,
) !LoadedServices {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer allocator.destroy(arena);
    errdefer arena.deinit();

    const raw = try dir.readFileAlloc(allocator, path, max_file_bytes);
    defer allocator.free(raw);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch {
        return error.InvalidServicesJson;
    };
    defer parsed.deinit();

    const values = switch (parsed.value) {
        .array => |array| array.items,
        else => return error.InvalidServicesJson,
    };

    var items = std.ArrayList(ServiceConfig){};
    defer items.deinit(allocator);

    for (values) |value| {
        try items.append(allocator, try parseServiceConfig(arena.allocator(), value));
    }

    return .{
        .parent_allocator = allocator,
        .arena = arena,
        .items = try arena.allocator().dupe(ServiceConfig, items.items),
    };
}

fn parseServiceConfig(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !ServiceConfig {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidServiceConfig,
    };

    return .{
        .name = try dupRequiredString(allocator, object, "name"),
        .base_url = try dupRequiredString(allocator, object, "base_url"),
        .api_key_env = try dupRequiredString(allocator, object, "api_key_env"),
        .default_model = try dupRequiredString(allocator, object, "default_model"),
        .provider = try dupOptionalString(allocator, object, "provider"),
        .system_prompt = try dupOptionalString(allocator, object, "system_prompt"),
        .timeout_ms = try parseRequiredU32(object, "timeout_ms"),
    };
}

fn dupRequiredString(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    field_name: []const u8,
) ![]const u8 {
    const value = object.get(field_name) orelse return error.InvalidServiceConfig;
    const text = switch (value) {
        .string => |text| text,
        else => return error.InvalidServiceConfig,
    };
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidServiceConfig;
    return allocator.dupe(u8, trimmed);
}

fn dupOptionalString(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    field_name: []const u8,
) !?[]const u8 {
    const value = object.get(field_name) orelse return null;
    const text = switch (value) {
        .string => |text| text,
        else => return error.InvalidServiceConfig,
    };
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

fn parseRequiredU32(
    object: std.json.ObjectMap,
    field_name: []const u8,
) !u32 {
    const value = object.get(field_name) orelse return error.InvalidServiceConfig;
    const integer = switch (value) {
        .integer => |integer| integer,
        else => return error.InvalidServiceConfig,
    };
    if (integer <= 0) return error.InvalidServiceConfig;
    return std.math.cast(u32, integer) orelse error.InvalidServiceConfig;
}

test "ServiceConfig stores v1 fields" {
    const service = ServiceConfig{
        .name = "local-router",
        .base_url = "http://127.0.0.1:8081/v1/chat/completions",
        .api_key_env = "OPENAI_API_KEY",
        .default_model = "gpt-4.1-mini",
        .provider = "openai",
        .system_prompt = "You are a test runner.",
        .timeout_ms = 30_000,
    };

    try std.testing.expectEqualStrings("local-router", service.name);
    try std.testing.expectEqualStrings("openai", service.provider.?);
    try std.testing.expectEqual(@as(u32, 30_000), service.timeout_ms);
}

test "loadServices loads valid services.json" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("registry");
    try tmp.dir.writeFile(.{
        .sub_path = "registry/services.json",
        .data =
        \\[
        \\  {
        \\    "name": "local-router",
        \\    "base_url": "http://127.0.0.1:8081/v1/chat/completions",
        \\    "api_key_env": "OPENAI_API_KEY",
        \\    "default_model": "gpt-4.1-mini",
        \\    "provider": "openai",
        \\    "system_prompt": "Be precise.",
        \\    "timeout_ms": 30000
        \\  }
        \\]
        ,
    });

    var loaded = try loadServices(std.testing.allocator, tmp.dir, "registry/services.json");
    defer loaded.deinit();

    try std.testing.expectEqual(@as(usize, 1), loaded.items.len);
    try std.testing.expectEqualStrings("local-router", loaded.items[0].name);
    try std.testing.expectEqualStrings("openai", loaded.items[0].provider.?);
}

test "loadServices rejects missing required fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("registry");
    try tmp.dir.writeFile(.{
        .sub_path = "registry/services.json",
        .data =
        \\[
        \\  {
        \\    "name": "",
        \\    "base_url": "http://127.0.0.1:8081/v1/chat/completions",
        \\    "api_key_env": "OPENAI_API_KEY",
        \\    "default_model": "gpt-4.1-mini",
        \\    "timeout_ms": 30000
        \\  }
        \\]
        ,
    });

    try std.testing.expectError(
        error.InvalidServiceConfig,
        loadServices(std.testing.allocator, tmp.dir, "registry/services.json"),
    );
}
