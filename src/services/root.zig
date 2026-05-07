const std = @import("std");

pub const ServiceConfig = struct {
    name: []const u8,
    base_url: []const u8,
    api_key_env: []const u8,
    default_model: []const u8,
    provider: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    timeout_ms: u32,
};

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
