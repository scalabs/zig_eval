const std = @import("std");
const builtin = @import("builtin");
const registry = @import("../registry/root.zig");

const max_file_bytes = 1024 * 1024;
const max_response_bytes = 8 * 1024 * 1024;
const max_retry_attempts = 10;
const max_retry_backoff_ms = 60_000;

pub const RetryConfig = struct {
    max_attempts: u32 = 1,
    backoff_ms: u32 = 0,
    retry_on_status: []const u16 = &.{ 429, 500, 502, 503, 504 },
};

pub const ServiceConfig = struct {
    name: []const u8,
    base_url: []const u8,
    api_key_env: ?[]const u8 = null,
    default_model: []const u8,
    provider: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    timeout_ms: u32,
    retry: RetryConfig = .{},
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

pub const ChatCallInput = struct {
    prompt: []const u8,
    system_prompt_override: ?[]const u8 = null,
    model_override: ?[]const u8 = null,
    tools: ?[]const registry.ToolDefinition = null,
    attachments: ?[]const registry.Attachment = null,
    attachment_dir: ?std.fs.Dir = null,
};

pub const ToolCall = struct {
    name: []const u8,
    arguments_json: []const u8,
};

pub const ChatCallFailureKind = enum {
    fetch_error,
    upstream_http_error,
    invalid_upstream_json,
    malformed_success_payload,
    response_too_large,
    invalid_request,
    retry_exhausted,
};

pub const ChatCallFailure = struct {
    kind: ChatCallFailureKind,
    reason: []u8,
    model: []u8,
    status_code: ?u16 = null,
    attempt_count: u32 = 1,
    retried: bool = false,

    pub fn deinit(self: *ChatCallFailure, allocator: std.mem.Allocator) void {
        allocator.free(self.reason);
        allocator.free(self.model);
        self.* = undefined;
    }
};

/// `callChatCompletion` returns owned buffers; `deinit` releases them.
pub const ChatCallOutput = struct {
    content: []u8,
    model: []u8,
    status_code: u16,
    attempt_count: u32 = 1,
    retried: bool = false,
    tool_calls: ?[]const ToolCall = null,

    pub fn deinit(self: *ChatCallOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        allocator.free(self.model);
        if (self.tool_calls) |calls| {
            freeToolCalls(allocator, calls);
        }
        self.* = undefined;
    }
};

pub const ChatCallResult = union(enum) {
    success: ChatCallOutput,
    failure: ChatCallFailure,

    pub fn deinit(self: *ChatCallResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .success => |*output| output.deinit(allocator),
            .failure => |*failure| failure.deinit(allocator),
        }
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

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch |err| {
        if (err == error.OutOfMemory) return err;
        return error.InvalidServicesJson;
    };
    defer parsed.deinit();

    const values = switch (parsed.value) {
        .array => |array| array.items,
        else => return error.InvalidServicesJson,
    };

    var items = std.ArrayList(ServiceConfig){};
    defer items.deinit(allocator);

    var seen_names = std.StringHashMap(void).init(allocator);
    defer seen_names.deinit();

    for (values) |value| {
        const service = try parseServiceConfig(arena.allocator(), value);
        const gop = try seen_names.getOrPut(service.name);
        if (gop.found_existing) return error.DuplicateServiceName;
        try items.append(allocator, service);
    }

    return .{
        .parent_allocator = allocator,
        .arena = arena,
        .items = try arena.allocator().dupe(ServiceConfig, items.items),
    };
}

fn shouldRetryStatus(status: std.http.Status, retry_on_status: []const u16) bool {
    const code: u16 = @intFromEnum(status);

    for (retry_on_status) |retry_code| {
        if (code == retry_code) {
            return true;
        }
    }

    return false;
}

fn retryDelay(backoff_ms: u32, attempt: u32) void {
    if (backoff_ms == 0) return;

    const delay_ms: u64 = @as(u64, backoff_ms) * @as(u64, attempt);
    std.Thread.sleep(delay_ms * std.time.ns_per_ms);
}

pub fn callChatCompletion(
    allocator: std.mem.Allocator,
    service: ServiceConfig,
    input: ChatCallInput,
) !ChatCallOutput {
    var result = try callChatCompletionResult(allocator, service, input);
    switch (result) {
        .success => |output| return output,
        .failure => |*failure| {
            defer failure.deinit(allocator);
            return failureKindToError(failure.kind);
        },
    }
}

pub fn callChatCompletionResult(
    allocator: std.mem.Allocator,
    service: ServiceConfig,
    input: ChatCallInput,
) !ChatCallResult {
    const model_name = selectModelName(service, input);
    const system_prompt = selectSystemPrompt(service, input);

    const endpoint = normalizeChatCompletionsUrl(allocator, service.base_url) catch |err| {
        if (err == error.OutOfMemory) return err;
        return try failureResultFromError(allocator, err, .invalid_request, null, 1, false, model_name);
    };
    defer allocator.free(endpoint);
    const uri = std.Uri.parse(endpoint) catch |err| {
        return try failureResultFromError(allocator, err, .invalid_request, null, 1, false, model_name);
    };

    const payload = renderChatPayloadJsonAlloc(
        allocator,
        model_name,
        input.prompt,
        system_prompt,
        service.provider,
        input.tools,
        input.attachment_dir,
        input.attachments,
    ) catch |err| {
        if (err == error.OutOfMemory) return err;
        return try failureResultFromError(allocator, err, .invalid_request, null, 1, false, model_name);
    };
    defer allocator.free(payload);

    var headers = std.ArrayList(std.http.Header){};
    defer headers.deinit(allocator);
    try headers.append(allocator, .{ .name = "content-type", .value = "application/json" });

    const api_key = readApiKeyFromEnv(allocator, service.api_key_env) catch |err| {
        if (err == error.OutOfMemory) return err;
        return try failureResultFromError(allocator, err, .invalid_request, null, 1, false, model_name);
    };
    defer if (api_key) |key| allocator.free(key);

    var auth_header_value: ?[]u8 = null;
    defer if (auth_header_value) |value| allocator.free(value);

    if (api_key) |key| {
        auth_header_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{key});
        try headers.append(allocator, .{ .name = "authorization", .value = auth_header_value.? });
    }

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var attempt: u32 = 1;
    const max_attempts: u32 = if (service.retry.max_attempts == 0) 1 else service.retry.max_attempts;

    while (attempt <= max_attempts) : (attempt += 1) {
        var response_writer = std.Io.Writer.Allocating.init(allocator);
        defer response_writer.deinit();

        const fetch_result = fetchChatCompletionWithTimeout(
            &client,
            uri,
            payload,
            headers.items,
            &response_writer.writer,
            service.timeout_ms,
        ) catch |err| {
            if (err == error.OutOfMemory) return err;
            if (attempt >= max_attempts) {
                return try failureResultFromError(
                    allocator,
                    err,
                    failureKindFromError(err),
                    null,
                    attempt,
                    attempt > 1,
                    model_name,
                );
            }

            retryDelay(service.retry.backoff_ms, attempt);
            continue;
        };

        if (shouldRetryStatus(fetch_result.status, service.retry.retry_on_status) and attempt < max_attempts) {
            retryDelay(service.retry.backoff_ms, attempt);
            continue;
        }

        var parsed = parseChatCompletionResponse(
            allocator,
            fetch_result.status,
            response_writer.written(),
            model_name,
        ) catch |err| {
            if (err == error.OutOfMemory) return err;
            const reason = if (err == error.UpstreamHttpError)
                try upstreamFailureReason(allocator, response_writer.written(), err)
            else
                try allocator.dupe(u8, @errorName(err));
            defer allocator.free(reason);

            return try failureResult(
                allocator,
                failureKindFromError(err),
                reason,
                @intFromEnum(fetch_result.status),
                attempt,
                attempt > 1,
                model_name,
            );
        };

        parsed.attempt_count = attempt;
        parsed.retried = attempt > 1;

        return .{ .success = parsed };
    }

    return try failureResultFromError(
        allocator,
        error.RetryExhausted,
        .retry_exhausted,
        null,
        max_attempts,
        max_attempts > 1,
        model_name,
    );
}

fn fetchChatCompletionWithTimeout(
    client: *std.http.Client,
    uri: std.Uri,
    payload: []const u8,
    headers: []const std.http.Header,
    response_writer: *std.Io.Writer,
    timeout_ms: u32,
) !std.http.Client.FetchResult {
    var req = try client.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .extra_headers = headers,
        .keep_alive = false,
    });
    defer req.deinit();

    if (req.connection) |connection| {
        try applyConnectionTimeout(connection, timeout_ms);
    }

    req.transfer_encoding = .{ .content_length = payload.len };
    var body = try req.sendBodyUnflushed(&.{});
    try body.writer.writeAll(payload);
    try body.end();
    try req.connection.?.flush();

    var response = try req.receiveHead(&.{});

    const decompress_buffer: []u8 = switch (response.head.content_encoding) {
        .identity => &.{},
        .zstd => try client.allocator.alloc(u8, std.compress.zstd.default_window_len),
        .deflate, .gzip => try client.allocator.alloc(u8, std.compress.flate.max_window_len),
        .compress => return error.UnsupportedCompressionMethod,
    };
    defer if (response.head.content_encoding != .identity) client.allocator.free(decompress_buffer);

    var transfer_buffer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
    streamResponseWithLimit(reader, response_writer, max_response_bytes) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        else => |e| return e,
    };

    return .{ .status = response.head.status };
}

fn streamResponseWithLimit(
    reader: *std.Io.Reader,
    response_writer: *std.Io.Writer,
    max_bytes: usize,
) !void {
    var bytes_read: usize = 0;
    while (true) {
        const remaining = max_bytes + 1 - bytes_read;
        const n = reader.stream(response_writer, .limited(remaining)) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        bytes_read += n;
        if (bytes_read > max_bytes) return error.ResponseTooLarge;
    }
}

fn failureKindToError(kind: ChatCallFailureKind) anyerror {
    return switch (kind) {
        .fetch_error => error.FetchFailed,
        .upstream_http_error => error.UpstreamHttpError,
        .invalid_upstream_json => error.InvalidUpstreamJson,
        .malformed_success_payload => error.MalformedSuccessPayload,
        .response_too_large => error.ResponseTooLarge,
        .invalid_request => error.InvalidChatRequest,
        .retry_exhausted => error.RetryExhausted,
    };
}

fn failureKindFromError(err: anyerror) ChatCallFailureKind {
    return switch (err) {
        error.UpstreamHttpError => .upstream_http_error,
        error.InvalidUpstreamJson => .invalid_upstream_json,
        error.MalformedSuccessPayload => .malformed_success_payload,
        error.ResponseTooLarge, error.StreamTooLong => .response_too_large,
        error.RetryExhausted => .retry_exhausted,
        error.InvalidAttachmentPath,
        error.InvalidAttachmentMimeType,
        error.UnsupportedAttachmentType,
        error.MissingAttachmentRoot,
        error.InvalidAttachmentText,
        error.FileNotFound,
        => .invalid_request,
        else => .fetch_error,
    };
}

fn failureResultFromError(
    allocator: std.mem.Allocator,
    err: anyerror,
    kind: ChatCallFailureKind,
    status_code: ?u16,
    attempt_count: u32,
    retried: bool,
    model: []const u8,
) !ChatCallResult {
    return failureResult(
        allocator,
        kind,
        @errorName(err),
        status_code,
        attempt_count,
        retried,
        model,
    );
}

fn failureResult(
    allocator: std.mem.Allocator,
    kind: ChatCallFailureKind,
    reason: []const u8,
    status_code: ?u16,
    attempt_count: u32,
    retried: bool,
    model: []const u8,
) !ChatCallResult {
    const owned_reason = try allocator.dupe(u8, reason);
    errdefer allocator.free(owned_reason);
    const owned_model = try allocator.dupe(u8, model);
    return .{
        .failure = .{
            .kind = kind,
            .reason = owned_reason,
            .model = owned_model,
            .status_code = status_code,
            .attempt_count = attempt_count,
            .retried = retried,
        },
    };
}

fn applyConnectionTimeout(connection: *std.http.Client.Connection, timeout_ms: u32) !void {
    if (timeout_ms == 0) return;

    const stream = connection.stream_reader.getStream();
    try setSocketTimeout(stream.handle, std.posix.SO.RCVTIMEO, timeout_ms);
    try setSocketTimeout(stream.handle, std.posix.SO.SNDTIMEO, timeout_ms);
}

fn setSocketTimeout(
    socket: std.posix.socket_t,
    optname: u32,
    timeout_ms: u32,
) !void {
    if (builtin.os.tag == .windows) {
        const value: u32 = timeout_ms;
        try std.posix.setsockopt(
            socket,
            std.posix.SOL.SOCKET,
            optname,
            std.mem.asBytes(&value),
        );
        return;
    }

    const value = timeoutMillisToTimeval(timeout_ms);
    try std.posix.setsockopt(
        socket,
        std.posix.SOL.SOCKET,
        optname,
        std.mem.asBytes(&value),
    );
}

fn timeoutMillisToTimeval(timeout_ms: u32) std.posix.timeval {
    return .{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
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
        .api_key_env = try dupOptionalString(allocator, object, "api_key_env"),
        .default_model = try dupRequiredString(allocator, object, "default_model"),
        .provider = try dupOptionalString(allocator, object, "provider"),
        .system_prompt = try dupOptionalString(allocator, object, "system_prompt"),
        .timeout_ms = try parseRequiredU32(object, "timeout_ms"),
        .retry = try parseOptionalRetryConfig(allocator, object),
    };
}

fn selectModelName(
    service: ServiceConfig,
    input: ChatCallInput,
) []const u8 {
    if (input.model_override) |override| {
        const trimmed = std.mem.trim(u8, override, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    }
    return service.default_model;
}

fn selectSystemPrompt(
    service: ServiceConfig,
    input: ChatCallInput,
) ?[]const u8 {
    if (input.system_prompt_override) |override| {
        const trimmed = std.mem.trim(u8, override, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    }
    if (service.system_prompt) |configured| {
        const trimmed = std.mem.trim(u8, configured, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    }
    return null;
}

fn readApiKeyFromEnv(
    allocator: std.mem.Allocator,
    env_name: ?[]const u8,
) !?[]u8 {
    const configured_env = env_name orelse return null;
    const trimmed_env = std.mem.trim(u8, configured_env, " \t\r\n");
    if (trimmed_env.len == 0) return null;

    const raw = std.process.getEnvVarOwned(allocator, trimmed_env) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return null,
        else => return err,
    };
    errdefer allocator.free(raw);

    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(raw);
        return null;
    }

    if (trimmed.ptr == raw.ptr and trimmed.len == raw.len) {
        return raw;
    }

    const duped = try allocator.dupe(u8, trimmed);
    allocator.free(raw);
    return duped;
}

fn normalizeChatCompletionsUrl(
    allocator: std.mem.Allocator,
    base_url: []const u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, base_url, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidServiceConfig;

    if (std.mem.endsWith(u8, trimmed, "/v1/chat/completions")) {
        return allocator.dupe(u8, trimmed);
    }
    if (std.mem.endsWith(u8, trimmed, "/chat/completions")) {
        return allocator.dupe(u8, trimmed);
    }
    if (std.mem.endsWith(u8, trimmed, "/v1")) {
        return std.fmt.allocPrint(allocator, "{s}/chat/completions", .{trimmed});
    }
    if (std.mem.endsWith(u8, trimmed, "/v1/")) {
        return std.fmt.allocPrint(allocator, "{s}chat/completions", .{trimmed});
    }
    if (std.mem.endsWith(u8, trimmed, "/")) {
        return std.fmt.allocPrint(allocator, "{s}v1/chat/completions", .{trimmed});
    }
    return std.fmt.allocPrint(allocator, "{s}/v1/chat/completions", .{trimmed});
}

fn renderChatPayloadJsonAlloc(
    allocator: std.mem.Allocator,
    model: []const u8,
    prompt: []const u8,
    system_prompt: ?[]const u8,
    provider: ?[]const u8,
    tools: ?[]const registry.ToolDefinition,
    attachment_dir: ?std.fs.Dir,
    attachments: ?[]const registry.Attachment,
) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    var json_writer = std.json.Stringify{
        .writer = &out.writer,
        .options = .{},
    };

    try json_writer.beginObject();

    try json_writer.objectField("model");
    try json_writer.write(model);

    try json_writer.objectField("messages");
    try json_writer.beginArray();

    if (system_prompt) |value| {
        try writeMessageObject(&json_writer, "system", value);
    }
    try writeUserMessageObject(&json_writer, allocator, attachment_dir, prompt, attachments);
    try json_writer.endArray();

    if (tools) |tool_list| {
        try json_writer.objectField("tools");
        try json_writer.beginArray();

        for (tool_list) |tool| {
            try json_writer.beginObject();

            try json_writer.objectField("type");
            try json_writer.write("function");

            try json_writer.objectField("function");
            try json_writer.beginObject();

            try json_writer.objectField("name");
            try json_writer.write(tool.name);

            try json_writer.objectField("description");
            try json_writer.write(tool.description);

            try json_writer.objectField("parameters");

            var parsed = try std.json.parseFromSlice(
                std.json.Value,
                allocator,
                tool.parameters_json,
                .{},
            );
            defer parsed.deinit();

            try json_writer.write(parsed.value);

            try json_writer.endObject();
            try json_writer.endObject();
        }

        try json_writer.endArray();
    }

    try json_writer.objectField("stream");
    try json_writer.write(false);

    if (provider) |value| {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len > 0) {
            try json_writer.objectField("provider");
            try json_writer.write(trimmed);
        }
    }

    try json_writer.endObject();
    return try out.toOwnedSlice();
}

fn writeMessageObject(
    json_writer: *std.json.Stringify,
    role: []const u8,
    content: []const u8,
) !void {
    try json_writer.beginObject();
    try json_writer.objectField("role");
    try json_writer.write(role);
    try json_writer.objectField("content");
    try json_writer.write(content);
    try json_writer.endObject();
}

fn writeUserMessageObject(
    json_writer: *std.json.Stringify,
    allocator: std.mem.Allocator,
    attachment_dir: ?std.fs.Dir,
    prompt: []const u8,
    attachments: ?[]const registry.Attachment,
) !void {
    const attachment_list = attachments orelse {
        try writeMessageObject(json_writer, "user", prompt);
        return;
    };
    if (attachment_list.len == 0) {
        try writeMessageObject(json_writer, "user", prompt);
        return;
    }

    const dir = attachment_dir orelse return error.MissingAttachmentRoot;
    const text_content = try buildTextContentWithAttachments(allocator, dir, prompt, attachment_list);
    defer allocator.free(text_content);

    try json_writer.beginObject();
    try json_writer.objectField("role");
    try json_writer.write("user");
    try json_writer.objectField("content");
    try json_writer.beginArray();

    try writeTextContentBlock(json_writer, text_content);

    for (attachment_list) |attachment| {
        var resolved = try resolveAttachment(allocator, dir, attachment);
        defer resolved.deinit(allocator);
        if (attachment.kind == .image) {
            try writeImageContentBlock(json_writer, allocator, resolved.real_path, resolved.mime_type);
        }
    }

    try json_writer.endArray();
    try json_writer.endObject();
}

fn buildTextContentWithAttachments(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    prompt: []const u8,
    attachments: []const registry.Attachment,
) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();

    try out.writer.writeAll(prompt);

    for (attachments) |attachment| {
        var resolved = try resolveAttachment(allocator, dir, attachment);
        defer resolved.deinit(allocator);
        if (attachment.kind == .image) {
            continue;
        }

        const raw = try readResolvedFileAlloc(
            allocator,
            resolved.real_path,
            registry.max_attachment_bytes,
        );
        defer allocator.free(raw);
        if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidAttachmentText;

        const label = attachment.label orelse attachment.path;
        try out.writer.print(
            "\n\n[Attachment: {s} ({s})]\n```text\n{s}\n```",
            .{ label, resolved.mime_type, raw },
        );
    }

    return try out.toOwnedSlice();
}

fn writeTextContentBlock(
    json_writer: *std.json.Stringify,
    text: []const u8,
) !void {
    try json_writer.beginObject();
    try json_writer.objectField("type");
    try json_writer.write("text");
    try json_writer.objectField("text");
    try json_writer.write(text);
    try json_writer.endObject();
}

fn writeImageContentBlock(
    json_writer: *std.json.Stringify,
    allocator: std.mem.Allocator,
    real_path: []const u8,
    mime_type: []const u8,
) !void {
    const data_url = try imageDataUrl(allocator, real_path, mime_type);
    defer allocator.free(data_url);

    try json_writer.beginObject();
    try json_writer.objectField("type");
    try json_writer.write("image_url");
    try json_writer.objectField("image_url");
    try json_writer.beginObject();
    try json_writer.objectField("url");
    try json_writer.write(data_url);
    try json_writer.endObject();
    try json_writer.endObject();
}

fn imageDataUrl(
    allocator: std.mem.Allocator,
    real_path: []const u8,
    mime_type: []const u8,
) ![]u8 {
    const raw = try readResolvedFileAlloc(allocator, real_path, registry.max_attachment_bytes);
    defer allocator.free(raw);

    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(raw.len));
    defer allocator.free(encoded);
    const encoded_slice = std.base64.standard.Encoder.encode(encoded, raw);

    return std.fmt.allocPrint(allocator, "data:{s};base64,{s}", .{ mime_type, encoded_slice });
}

fn attachmentMimeType(attachment: registry.Attachment) ?[]const u8 {
    return attachment.mime_type orelse registry.inferAttachmentMimeType(attachment.path);
}

const ResolvedAttachment = struct {
    mime_type: []const u8,
    real_path: []u8,

    fn deinit(self: *ResolvedAttachment, allocator: std.mem.Allocator) void {
        allocator.free(self.real_path);
        self.* = undefined;
    }
};

fn resolveAttachment(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    attachment: registry.Attachment,
) !ResolvedAttachment {
    const real_path = try registry.attachmentRealPathAlloc(allocator, dir, attachment.path);
    errdefer allocator.free(real_path);

    const mime_type = attachmentMimeType(attachment) orelse return error.UnsupportedAttachmentType;
    const image_mime = isImageMimeType(mime_type);
    switch (attachment.kind) {
        .image => if (!image_mime) return error.InvalidAttachmentMimeType,
        .file => {
            if (image_mime) return error.InvalidAttachmentMimeType;
            if (!isTextMimeType(mime_type)) return error.UnsupportedAttachmentType;
        },
    }
    return .{ .mime_type = mime_type, .real_path = real_path };
}

fn readResolvedFileAlloc(
    allocator: std.mem.Allocator,
    real_path: []const u8,
    max_bytes: usize,
) ![]u8 {
    var file = try std.fs.openFileAbsolute(real_path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, max_bytes);
}

fn isImageMimeType(mime_type: []const u8) bool {
    return std.mem.eql(u8, mime_type, "image/png") or
        std.mem.eql(u8, mime_type, "image/jpeg") or
        std.mem.eql(u8, mime_type, "image/webp");
}

fn isTextMimeType(mime_type: []const u8) bool {
    return std.mem.startsWith(u8, mime_type, "text/") or
        std.mem.eql(u8, mime_type, "application/json") or
        std.mem.eql(u8, mime_type, "application/x-ndjson");
}

fn parseToolCalls(
    allocator: std.mem.Allocator,
    message_object: std.json.ObjectMap,
) !?[]const ToolCall {
    const tool_calls_value = message_object.get("tool_calls") orelse return null;

    const tool_calls_array = switch (tool_calls_value) {
        .array => |array| array.items,
        else => return error.MalformedSuccessPayload,
    };

    var items = std.ArrayList(ToolCall){};
    defer items.deinit(allocator);
    errdefer freeToolCallItems(allocator, items.items);

    for (tool_calls_array) |entry| {
        const entry_object = switch (entry) {
            .object => |object| object,
            else => return error.MalformedSuccessPayload,
        };

        const function_value = entry_object.get("function") orelse
            return error.MalformedSuccessPayload;

        const function_object = switch (function_value) {
            .object => |object| object,
            else => return error.MalformedSuccessPayload,
        };

        const name = switch (function_object.get("name") orelse
            return error.MalformedSuccessPayload) {
            .string => |value| value,
            else => return error.MalformedSuccessPayload,
        };

        const arguments_json = switch (function_object.get("arguments") orelse
            return error.MalformedSuccessPayload) {
            .string => |value| value,
            else => return error.MalformedSuccessPayload,
        };

        try items.append(allocator, .{
            .name = try allocator.dupe(u8, name),
            .arguments_json = try allocator.dupe(u8, arguments_json),
        });
    }

    return try allocator.dupe(ToolCall, items.items);
}

fn freeToolCalls(allocator: std.mem.Allocator, calls: []const ToolCall) void {
    freeToolCallItems(allocator, calls);
    allocator.free(calls);
}

fn freeToolCallItems(allocator: std.mem.Allocator, calls: []const ToolCall) void {
    for (calls) |call| {
        allocator.free(call.name);
        allocator.free(call.arguments_json);
    }
}

fn parseChatCompletionResponse(
    allocator: std.mem.Allocator,
    status: std.http.Status,
    raw: []const u8,
    fallback_model: []const u8,
) !ChatCallOutput {
    if (status != .ok) {
        return error.UpstreamHttpError;
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch |err| {
        if (err == error.OutOfMemory) return err;
        return error.InvalidUpstreamJson;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.InvalidUpstreamJson,
    };

    const model = if (root.get("model")) |value|
        switch (value) {
            .string => |text| text,
            else => fallback_model,
        }
    else
        fallback_model;

    const choices = switch (root.get("choices") orelse return error.MalformedSuccessPayload) {
        .array => |array| array.items,
        else => return error.MalformedSuccessPayload,
    };
    if (choices.len == 0) return error.MalformedSuccessPayload;

    const choice_object = switch (choices[0]) {
        .object => |object| object,
        else => return error.MalformedSuccessPayload,
    };

    const message_object = switch (choice_object.get("message") orelse return error.MalformedSuccessPayload) {
        .object => |object| object,
        else => return error.MalformedSuccessPayload,
    };

    const tool_calls = try parseToolCalls(allocator, message_object);
    errdefer if (tool_calls) |calls| freeToolCalls(allocator, calls);

    const content = if (message_object.get("content")) |content_value|
        switch (content_value) {
            .string => |value| value,
            .null => "",
            else => return error.MalformedSuccessPayload,
        }
    else if (tool_calls != null)
        ""
    else
        return error.MalformedSuccessPayload;

    const owned_content = try allocator.dupe(u8, content);
    errdefer allocator.free(owned_content);

    const owned_model = try allocator.dupe(u8, model);

    return .{
        .content = owned_content,
        .model = owned_model,
        .status_code = @intFromEnum(status),
        .tool_calls = tool_calls,
    };
}

fn upstreamFailureReason(
    allocator: std.mem.Allocator,
    raw: []const u8,
    fallback: anyerror,
) ![]u8 {
    return try extractUpstreamErrorMessage(allocator, raw) orelse
        try allocator.dupe(u8, @errorName(fallback));
}

fn extractUpstreamErrorMessage(
    allocator: std.mem.Allocator,
    raw: []const u8,
) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch |err| {
        if (err == error.OutOfMemory) return err;
        return null;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };

    const error_value = root.get("error") orelse return null;
    const message = switch (error_value) {
        .object => |error_object| switch (error_object.get("message") orelse return null) {
            .string => |value| value,
            else => return null,
        },
        .string => |value| value,
        else => return null,
    };

    return try allocator.dupe(u8, message);
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

fn parseOptionalRetryConfig(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) !RetryConfig {
    const value = object.get("retry") orelse return .{};
    const retry_object = switch (value) {
        .object => |retry_object| retry_object,
        else => return error.InvalidServiceConfig,
    };

    const config = RetryConfig{
        .max_attempts = try parseOptionalU32(retry_object, "max_attempts", 1, false),
        .backoff_ms = try parseOptionalU32(retry_object, "backoff_ms", 0, true),
        .retry_on_status = try parseOptionalStatusList(allocator, retry_object, "retry_on_status"),
    };
    if (config.max_attempts > max_retry_attempts) return error.InvalidServiceConfig;
    if (config.backoff_ms > max_retry_backoff_ms) return error.InvalidServiceConfig;
    return config;
}

fn parseOptionalU32(
    object: std.json.ObjectMap,
    field_name: []const u8,
    default_value: u32,
    allow_zero: bool,
) !u32 {
    const value = object.get(field_name) orelse return default_value;
    const integer = switch (value) {
        .integer => |integer| integer,
        else => return error.InvalidServiceConfig,
    };
    if (integer < 0) return error.InvalidServiceConfig;
    if (!allow_zero and integer == 0) return error.InvalidServiceConfig;
    return std.math.cast(u32, integer) orelse error.InvalidServiceConfig;
}

fn parseOptionalStatusList(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    field_name: []const u8,
) ![]const u16 {
    const default_retry = RetryConfig{};
    const value = object.get(field_name) orelse return default_retry.retry_on_status;
    const entries = switch (value) {
        .array => |array| array.items,
        else => return error.InvalidServiceConfig,
    };

    var items = std.ArrayList(u16){};
    defer items.deinit(allocator);

    for (entries) |entry| {
        const integer = switch (entry) {
            .integer => |integer| integer,
            else => return error.InvalidServiceConfig,
        };
        if (integer < 100 or integer > 599) return error.InvalidServiceConfig;
        try items.append(allocator, std.math.cast(u16, integer) orelse return error.InvalidServiceConfig);
    }

    return try allocator.dupe(u16, items.items);
}

test "ServiceConfig stores v1 fields" {
    const service = ServiceConfig{
        .name = "product-api",
        .base_url = "http://127.0.0.1:8081/v1/chat/completions",
        .api_key_env = "OPENAI_API_KEY",
        .default_model = "gpt-4.1-mini",
        .provider = "openai",
        .system_prompt = "You are a test runner.",
        .timeout_ms = 30_000,
    };

    try std.testing.expectEqualStrings("product-api", service.name);
    try std.testing.expectEqualStrings("openai", service.provider.?);
    try std.testing.expectEqual(@as(u32, 30_000), service.timeout_ms);
}

test "timeoutMillisToTimeval converts milliseconds" {
    const timeout = timeoutMillisToTimeval(1501);

    try std.testing.expectEqual(@as(@TypeOf(timeout.sec), 1), timeout.sec);
    try std.testing.expectEqual(@as(@TypeOf(timeout.usec), 501000), timeout.usec);
}

test "setSocketTimeout applies send and receive timeout options" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const socket = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(socket);

    try setSocketTimeout(socket, std.posix.SO.RCVTIMEO, 25);
    try setSocketTimeout(socket, std.posix.SO.SNDTIMEO, 25);
}

test "streamResponseWithLimit rejects oversized responses" {
    var reader = std.Io.Reader.fixed("abcdef");
    var out = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer out.deinit();

    try std.testing.expectError(
        error.ResponseTooLarge,
        streamResponseWithLimit(&reader, &out.writer, 3),
    );
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
        \\    "name": "product-api",
        \\    "base_url": "http://127.0.0.1:8081/v1/chat/completions",
        \\    "api_key_env": "OPENAI_API_KEY",
        \\    "default_model": "gpt-4.1-mini",
        \\    "provider": "openai",
        \\    "system_prompt": "Be precise.",
        \\    "timeout_ms": 30000,
        \\    "retry": {
        \\      "max_attempts": 4,
        \\      "backoff_ms": 250,
        \\      "retry_on_status": [429, 503]
        \\    }
        \\  }
        \\]
        ,
    });

    var loaded = try loadServices(std.testing.allocator, tmp.dir, "registry/services.json");
    defer loaded.deinit();

    try std.testing.expectEqual(@as(usize, 1), loaded.items.len);
    try std.testing.expectEqualStrings("product-api", loaded.items[0].name);
    try std.testing.expectEqualStrings("openai", loaded.items[0].provider.?);
    try std.testing.expectEqual(@as(u32, 4), loaded.items[0].retry.max_attempts);
    try std.testing.expectEqual(@as(u32, 250), loaded.items[0].retry.backoff_ms);
    try std.testing.expectEqual(@as(usize, 2), loaded.items[0].retry.retry_on_status.len);
    try std.testing.expectEqual(@as(u16, 429), loaded.items[0].retry.retry_on_status[0]);
}

test "loadServices allows unauthenticated product endpoints" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("registry");
    try tmp.dir.writeFile(.{
        .sub_path = "registry/services.json",
        .data =
        \\[
        \\  {
        \\    "name": "internal-product",
        \\    "base_url": "http://127.0.0.1:9000/v1/chat/completions",
        \\    "default_model": "eval-model",
        \\    "timeout_ms": 15000
        \\  }
        \\]
        ,
    });

    var loaded = try loadServices(std.testing.allocator, tmp.dir, "registry/services.json");
    defer loaded.deinit();

    try std.testing.expectEqual(@as(usize, 1), loaded.items.len);
    try std.testing.expectEqualStrings("internal-product", loaded.items[0].name);
    try std.testing.expect(loaded.items[0].api_key_env == null);
}

test "loadServices rejects duplicate service names" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("registry");
    try tmp.dir.writeFile(.{
        .sub_path = "registry/services.json",
        .data =
        \\[
        \\  {
        \\    "name": "product-api",
        \\    "base_url": "http://127.0.0.1:9000/v1",
        \\    "default_model": "model-a",
        \\    "timeout_ms": 1000
        \\  },
        \\  {
        \\    "name": "product-api",
        \\    "base_url": "http://127.0.0.1:9001/v1",
        \\    "default_model": "model-b",
        \\    "timeout_ms": 1000
        \\  }
        \\]
        ,
    });

    try std.testing.expectError(
        error.DuplicateServiceName,
        loadServices(std.testing.allocator, tmp.dir, "registry/services.json"),
    );
}

test "loadServices rejects excessive retry settings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("registry");
    try tmp.dir.writeFile(.{
        .sub_path = "registry/services.json",
        .data =
        \\[
        \\  {
        \\    "name": "product-api",
        \\    "base_url": "http://127.0.0.1:9000/v1",
        \\    "default_model": "model-a",
        \\    "timeout_ms": 1000,
        \\    "retry": { "max_attempts": 11, "backoff_ms": 0 }
        \\  }
        \\]
        ,
    });

    try std.testing.expectError(
        error.InvalidServiceConfig,
        loadServices(std.testing.allocator, tmp.dir, "registry/services.json"),
    );

    try tmp.dir.writeFile(.{
        .sub_path = "registry/services.json",
        .data =
        \\[
        \\  {
        \\    "name": "product-api",
        \\    "base_url": "http://127.0.0.1:9000/v1",
        \\    "default_model": "model-a",
        \\    "timeout_ms": 1000,
        \\    "retry": { "max_attempts": 1, "backoff_ms": 60001 }
        \\  }
        \\]
        ,
    });

    try std.testing.expectError(
        error.InvalidServiceConfig,
        loadServices(std.testing.allocator, tmp.dir, "registry/services.json"),
    );
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

test "normalizeChatCompletionsUrl handles v1 endpoint variants" {
    const cases = [_]struct {
        input: []const u8,
        expected: []const u8,
    }{
        .{ .input = "http://127.0.0.1:8081", .expected = "http://127.0.0.1:8081/v1/chat/completions" },
        .{ .input = "http://127.0.0.1:8081/", .expected = "http://127.0.0.1:8081/v1/chat/completions" },
        .{ .input = "http://127.0.0.1:8081/v1", .expected = "http://127.0.0.1:8081/v1/chat/completions" },
        .{ .input = "http://127.0.0.1:8081/v1/", .expected = "http://127.0.0.1:8081/v1/chat/completions" },
        .{ .input = "http://127.0.0.1:8081/v1/chat/completions", .expected = "http://127.0.0.1:8081/v1/chat/completions" },
    };

    for (cases) |case| {
        const actual = try normalizeChatCompletionsUrl(std.testing.allocator, case.input);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(case.expected, actual);
    }
}

test "renderChatPayloadJsonAlloc includes messages stream and provider" {
    const payload = try renderChatPayloadJsonAlloc(
        std.testing.allocator,
        "gpt-4.1-mini",
        "Reply with OK",
        "Follow instructions exactly.",
        "openai",
        null,
        null,
        null,
    );
    defer std.testing.allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("gpt-4.1-mini", root.get("model").?.string);
    try std.testing.expectEqual(false, root.get("stream").?.bool);
    try std.testing.expectEqualStrings("openai", root.get("provider").?.string);

    const messages = root.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqualStrings("system", messages[0].object.get("role").?.string);
    try std.testing.expectEqualStrings("user", messages[1].object.get("role").?.string);
}

test "parseChatCompletionResponse parses valid success body" {
    const raw =
        \\{
        \\  "id": "chatcmpl-test",
        \\  "model": "gpt-4.1-mini",
        \\  "choices": [
        \\    {
        \\      "message": {
        \\        "role": "assistant",
        \\        "content": "OK"
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    var output = try parseChatCompletionResponse(std.testing.allocator, .ok, raw, "fallback-model");
    defer output.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("OK", output.content);
    try std.testing.expectEqualStrings("gpt-4.1-mini", output.model);
    try std.testing.expectEqual(@as(u16, 200), output.status_code);
}

test "parseChatCompletionResponse returns error for non-200 with json error body" {
    const raw =
        \\{
        \\  "error": {
        \\    "message": "invalid_api_key"
        \\  }
        \\}
    ;
    try std.testing.expectError(
        error.UpstreamHttpError,
        parseChatCompletionResponse(std.testing.allocator, .unauthorized, raw, "fallback-model"),
    );
}

test "parseChatCompletionResponse rejects malformed success payload" {
    const raw_missing_choices =
        \\{
        \\  "model": "gpt-4.1-mini"
        \\}
    ;
    try std.testing.expectError(
        error.MalformedSuccessPayload,
        parseChatCompletionResponse(std.testing.allocator, .ok, raw_missing_choices, "fallback-model"),
    );

    const raw_missing_content =
        \\{
        \\  "model": "gpt-4.1-mini",
        \\  "choices": [
        \\    { "message": { "role": "assistant" } }
        \\  ]
        \\}
    ;
    try std.testing.expectError(
        error.MalformedSuccessPayload,
        parseChatCompletionResponse(std.testing.allocator, .ok, raw_missing_content, "fallback-model"),
    );
}

test "example services registry loads" {
    var cwd = try std.fs.cwd().openDir(".", .{});
    defer cwd.close();

    var loaded = try loadServices(
        std.testing.allocator,
        cwd,
        "examples/registry/services.json",
    );
    defer loaded.deinit();

    try std.testing.expectEqual(@as(usize, 3), loaded.items.len);
    try std.testing.expectEqualStrings("local-product", loaded.items[0].name);
    try std.testing.expect(loaded.items[0].api_key_env == null);
    try std.testing.expectEqual(@as(u32, 3), loaded.items[0].retry.max_attempts);
    try std.testing.expectEqual(@as(u32, 500), loaded.items[0].retry.backoff_ms);
    try std.testing.expectEqual(@as(usize, 5), loaded.items[0].retry.retry_on_status.len);
    try std.testing.expectEqualStrings("product-staging", loaded.items[1].name);
    try std.testing.expectEqualStrings("PRODUCT_STAGING_API_KEY", loaded.items[1].api_key_env.?);
    try std.testing.expectEqualStrings("judge", loaded.items[2].name);
    try std.testing.expectEqualStrings("OPENAI_API_KEY", loaded.items[2].api_key_env.?);
    try std.testing.expectEqualStrings("gpt-4.1-mini", loaded.items[2].default_model);
}

test "renderChatPayloadJsonAlloc includes tools" {
    const tools = [_]registry.ToolDefinition{
        .{
            .name = "search_web",
            .description = "Search the web",
            .parameters_json = "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"}}}",
        },
    };

    const payload = try renderChatPayloadJsonAlloc(
        std.testing.allocator,
        "gpt-4.1-mini",
        "Search weather",
        null,
        "openai",
        tools[0..],
        null,
        null,
    );
    defer std.testing.allocator.free(payload);

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        payload,
        .{},
    );
    defer parsed.deinit();

    const root = parsed.value.object;

    const tool_array = root.get("tools").?.array.items;

    try std.testing.expectEqual(@as(usize, 1), tool_array.len);

    const tool = tool_array[0].object;

    try std.testing.expectEqualStrings(
        "function",
        tool.get("type").?.string,
    );

    const function = tool.get("function").?.object;

    try std.testing.expectEqualStrings(
        "search_web",
        function.get("name").?.string,
    );
}

test "renderChatPayloadJsonAlloc includes image attachments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("assets/images");
    try tmp.dir.writeFile(.{
        .sub_path = "assets/images/red_mug.png",
        .data = "png",
    });

    const attachments = [_]registry.Attachment{
        .{
            .kind = .image,
            .path = "assets/images/red_mug.png",
            .mime_type = "image/png",
            .label = "reference image",
        },
    };

    const payload = try renderChatPayloadJsonAlloc(
        std.testing.allocator,
        "gpt-4.1-mini",
        "What object is shown?",
        null,
        null,
        null,
        tmp.dir,
        attachments[0..],
    );
    defer std.testing.allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();

    const message = parsed.value.object.get("messages").?.array.items[0].object;
    const content = message.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), content.len);
    try std.testing.expectEqualStrings("text", content[0].object.get("type").?.string);
    try std.testing.expectEqualStrings("image_url", content[1].object.get("type").?.string);
    const url = content[1].object.get("image_url").?.object.get("url").?.string;
    try std.testing.expect(std.mem.startsWith(u8, url, "data:image/png;base64,"));
}

test "renderChatPayloadJsonAlloc appends text attachments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("assets/changelogs");
    try tmp.dir.writeFile(.{
        .sub_path = "assets/changelogs/release.md",
        .data = "Retry support and parallel execution shipped.\n",
    });

    const attachments = [_]registry.Attachment{
        .{
            .kind = .file,
            .path = "assets/changelogs/release.md",
            .mime_type = "text/markdown",
            .label = "release notes",
        },
    };

    const payload = try renderChatPayloadJsonAlloc(
        std.testing.allocator,
        "gpt-4.1-mini",
        "Summarize the attached changelog.",
        null,
        null,
        null,
        tmp.dir,
        attachments[0..],
    );
    defer std.testing.allocator.free(payload);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, payload, .{});
    defer parsed.deinit();

    const message = parsed.value.object.get("messages").?.array.items[0].object;
    const content = message.get("content").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), content.len);
    const text = content[0].object.get("text").?.string;
    try std.testing.expect(std.mem.indexOf(u8, text, "release notes") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Retry support") != null);
}

test "renderChatPayloadJsonAlloc rejects unsupported binary attachments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("assets/files");
    try tmp.dir.writeFile(.{
        .sub_path = "assets/files/spec.pdf",
        .data = "%PDF-placeholder",
    });

    const attachments = [_]registry.Attachment{
        .{
            .kind = .file,
            .path = "assets/files/spec.pdf",
            .mime_type = "application/pdf",
        },
    };

    try std.testing.expectError(
        error.UnsupportedAttachmentType,
        renderChatPayloadJsonAlloc(
            std.testing.allocator,
            "gpt-4.1-mini",
            "Summarize the attachment.",
            null,
            null,
            null,
            tmp.dir,
            attachments[0..],
        ),
    );
}

test "renderChatPayloadJsonAlloc rejects unsafe manual attachment paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const attachments = [_]registry.Attachment{
        .{
            .kind = .file,
            .path = "../secret.md",
            .mime_type = "text/markdown",
        },
    };

    try std.testing.expectError(
        error.InvalidAttachmentPath,
        renderChatPayloadJsonAlloc(
            std.testing.allocator,
            "gpt-4.1-mini",
            "Summarize the attachment.",
            null,
            null,
            null,
            tmp.dir,
            attachments[0..],
        ),
    );
}

test "renderChatPayloadJsonAlloc rejects file attachments with image mime types" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("assets/images");
    try tmp.dir.writeFile(.{
        .sub_path = "assets/images/red_mug.png",
        .data = "png",
    });

    const attachments = [_]registry.Attachment{
        .{
            .kind = .file,
            .path = "assets/images/red_mug.png",
            .mime_type = "image/png",
        },
    };

    try std.testing.expectError(
        error.InvalidAttachmentMimeType,
        renderChatPayloadJsonAlloc(
            std.testing.allocator,
            "gpt-4.1-mini",
            "Summarize the attachment.",
            null,
            null,
            null,
            tmp.dir,
            attachments[0..],
        ),
    );
}

test "renderChatPayloadJsonAlloc rejects attachment symlink escaping root" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("registry/assets");
    try tmp.dir.writeFile(.{
        .sub_path = "secret.md",
        .data = "secret",
    });
    var registry_dir = try tmp.dir.openDir("registry", .{});
    defer registry_dir.close();

    try registry_dir.symLink("../../secret.md", "assets/link.md", .{});

    const attachments = [_]registry.Attachment{
        .{
            .kind = .file,
            .path = "assets/link.md",
            .mime_type = "text/markdown",
        },
    };

    try std.testing.expectError(
        error.InvalidAttachmentPath,
        renderChatPayloadJsonAlloc(
            std.testing.allocator,
            "gpt-4.1-mini",
            "Summarize the attachment.",
            null,
            null,
            null,
            registry_dir,
            attachments[0..],
        ),
    );
}

test "renderChatPayloadJsonAlloc allows attachment symlink inside root" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("registry/assets");
    try tmp.dir.writeFile(.{
        .sub_path = "registry/assets/real.md",
        .data = "public notes",
    });
    var registry_dir = try tmp.dir.openDir("registry", .{});
    defer registry_dir.close();

    try registry_dir.symLink("real.md", "assets/link.md", .{});

    const attachments = [_]registry.Attachment{
        .{
            .kind = .file,
            .path = "assets/link.md",
            .mime_type = "text/markdown",
        },
    };

    const payload = try renderChatPayloadJsonAlloc(
        std.testing.allocator,
        "gpt-4.1-mini",
        "Summarize the attachment.",
        null,
        null,
        null,
        registry_dir,
        attachments[0..],
    );
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "public notes") != null);
}

test "parseChatCompletionResponse parses tool calls" {
    const raw =
        \\{
        \\  "choices": [
        \\    {
        \\      "message": {
        \\        "content": null,
        \\        "tool_calls": [
        \\          {
        \\            "function": {
        \\              "name": "search_web",
        \\              "arguments": "{\"query\":\"weather melbourne\"}"
        \\            }
        \\          }
        \\        ]
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    var output = try parseChatCompletionResponse(
        std.testing.allocator,
        .ok,
        raw,
        "gpt-4.1-mini",
    );
    defer output.deinit(std.testing.allocator);

    try std.testing.expect(output.tool_calls != null);

    const calls = output.tool_calls.?;

    try std.testing.expectEqual(@as(usize, 1), calls.len);

    try std.testing.expectEqualStrings(
        "search_web",
        calls[0].name,
    );
}

test "parseChatCompletionResponse propagates out of memory" {
    const raw =
        \\{
        \\  "choices": [
        \\    {
        \\      "message": {
        \\        "content": "ok"
        \\      }
        \\    }
        \\  ]
        \\}
    ;

    var failing_allocator = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );

    try std.testing.expectError(
        error.OutOfMemory,
        parseChatCompletionResponse(
            failing_allocator.allocator(),
            .ok,
            raw,
            "gpt-4.1-mini",
        ),
    );
}

test "extractUpstreamErrorMessage propagates out of memory" {
    const raw =
        \\{
        \\  "error": {
        \\    "message": "rate limited"
        \\  }
        \\}
    ;

    var failing_allocator = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );

    try std.testing.expectError(
        error.OutOfMemory,
        extractUpstreamErrorMessage(failing_allocator.allocator(), raw),
    );
}
