const std = @import("std");
const registry = @import("../registry/root.zig");
const services = @import("../services/root.zig");

pub const MatcherKind = enum {
    exact_match,
    includes,
    json_fields,
    model_grade,
    tool_call,
};

pub const TextMatchOptions = struct {
    case_sensitive: bool = true,
    trim_whitespace: bool = true,
};

pub const JsonFieldsMatcherConfig = struct {
    required_fields: []const []const u8,
};

pub const ModelGradeMatcherConfig = struct {
    judge_service: []const u8,
    judge_model: ?[]const u8 = null,
    rubric: []const u8,
    pass_score: f64 = 1.0,
};

pub const ToolCallMatcherConfig = struct {};

pub const ModelGradePromptInput = struct {
    input: []const u8,
    output: []const u8,
    ideal: ?[]const u8 = null,
};

pub const MatcherConfig = union(MatcherKind) {
    exact_match: TextMatchOptions,
    includes: TextMatchOptions,
    json_fields: JsonFieldsMatcherConfig,
    model_grade: ModelGradeMatcherConfig,
    tool_call: ToolCallMatcherConfig,
};

pub const MatchOutcome = struct {
    passed: bool,
    score: f64,
    failure_reason: ?[]const u8 = null,
};

pub fn renderModelGradePrompt(
    allocator: std.mem.Allocator,
    config: ModelGradeMatcherConfig,
    input: ModelGradePromptInput,
) ![]u8 {
    const ideal = input.ideal orelse "No ideal answer was provided.";
    return std.fmt.allocPrint(allocator,
        \\You are grading an LLM or product response for an eval.
        \\
        \\Rubric:
        \\{s}
        \\
        \\Passing score:
        \\{d:.3}
        \\
        \\Eval input:
        \\{s}
        \\
        \\Candidate output:
        \\{s}
        \\
        \\Ideal answer:
        \\{s}
        \\
        \\Return JSON only with this exact shape:
        \\{{"score":0.0,"passed":false,"reason":"short explanation"}}
        \\
        \\Score must be between 0 and 1. Set passed to true only when score is greater than or equal to the passing score.
        \\
    , .{ config.rubric, config.pass_score, input.input, input.output, ideal });
}

pub fn parseMatcherConfig(
    allocator: std.mem.Allocator,
    value: std.json.Value,
) !MatcherConfig {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidMatcherConfig,
    };

    const kind_text = switch (object.get("kind") orelse return error.InvalidMatcherConfig) {
        .string => |text| text,
        else => return error.InvalidMatcherConfig,
    };

    if (std.mem.eql(u8, kind_text, "exact_match")) {
        try validateFields(object, &.{ "kind", "case_sensitive", "trim_whitespace" });
        return .{
            .exact_match = .{
                .case_sensitive = try parseOptionalBool(object, "case_sensitive", true),
                .trim_whitespace = try parseOptionalBool(object, "trim_whitespace", true),
            },
        };
    }

    if (std.mem.eql(u8, kind_text, "includes")) {
        try validateFields(object, &.{ "kind", "case_sensitive", "trim_whitespace" });
        return .{
            .includes = .{
                .case_sensitive = try parseOptionalBool(object, "case_sensitive", true),
                .trim_whitespace = try parseOptionalBool(object, "trim_whitespace", true),
            },
        };
    }

    if (std.mem.eql(u8, kind_text, "json_fields")) {
        try validateFields(object, &.{ "kind", "required_fields" });
        return .{
            .json_fields = .{
                .required_fields = try parseRequiredFields(allocator, object),
            },
        };
    }

    if (std.mem.eql(u8, kind_text, "model_grade")) {
        try validateFields(object, &.{ "kind", "judge_service", "judge_model", "rubric", "pass_score" });
        return .{
            .model_grade = .{
                .judge_service = try parseRequiredString(allocator, object, "judge_service"),
                .judge_model = try parseOptionalString(allocator, object, "judge_model"),
                .rubric = try parseRequiredString(allocator, object, "rubric"),
                .pass_score = try parseOptionalF64(object, "pass_score", 1.0),
            },
        };
    }

    if (std.mem.eql(u8, kind_text, "tool_call")) {
        try validateFields(object, &.{"kind"});

        return .{
            .tool_call = .{},
        };
    }

    return error.InvalidMatcherConfig;
}

pub fn evaluate(
    allocator: std.mem.Allocator,
    matcher: MatcherConfig,
    output: []const u8,
    ideal: ?[]const u8,
    tool_calls: ?[]const services.ToolCall,
    expected_tool_calls: ?[]const registry.ExpectedToolCall,
) !MatchOutcome {
    return switch (matcher) {
        .exact_match => |options| evaluateExactMatch(options, output, ideal),
        .includes => |options| evaluateIncludes(options, output, ideal),
        .json_fields => |config| evaluateJsonFields(allocator, config, output),
        .model_grade => error.ModelGradeRequiresJudge,
        .tool_call => evaluateToolCalls(
            allocator,
            tool_calls,
            expected_tool_calls,
        ),
    };
}

fn evaluateExactMatch(
    options: TextMatchOptions,
    output: []const u8,
    ideal: ?[]const u8,
) MatchOutcome {
    const expected = ideal orelse return failed("missing ideal");
    const normalized_output = normalizeText(output, options);
    const normalized_expected = normalizeText(expected, options);
    if (textEquals(normalized_output, normalized_expected, options.case_sensitive)) {
        return passed();
    }
    return failed("output did not exactly match ideal");
}

fn evaluateIncludes(
    options: TextMatchOptions,
    output: []const u8,
    ideal: ?[]const u8,
) MatchOutcome {
    const expected = ideal orelse return failed("missing ideal");
    const normalized_output = normalizeText(output, options);
    const normalized_expected = normalizeText(expected, options);
    if (textContains(normalized_output, normalized_expected, options.case_sensitive)) {
        return passed();
    }
    return failed("output did not include ideal");
}

fn evaluateJsonFields(
    allocator: std.mem.Allocator,
    config: JsonFieldsMatcherConfig,
    output: []const u8,
) !MatchOutcome {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, output, .{}) catch {
        return failed("invalid json output");
    };
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |object| object,
        else => return failed("json output is not an object"),
    };

    for (config.required_fields) |field| {
        if (object.get(field) == null) return failed("missing required json field");
    }
    return passed();
}

fn evaluateToolCalls(
    allocator: std.mem.Allocator,
    tool_calls: ?[]const services.ToolCall,
    expected_tool_calls: ?[]const registry.ExpectedToolCall,
) !MatchOutcome {
    const expected = expected_tool_calls orelse
        return failed("missing expected tool calls");

    const actual = tool_calls orelse
        return failed("missing tool call");

    for (expected) |expected_call| {
        var matched = false;

        for (actual) |actual_call| {
            if (!std.mem.eql(u8, expected_call.name, actual_call.name)) {
                continue;
            }

            matched = true;

            if (expected_call.arguments_json) |expected_args| {
                var parsed = std.json.parseFromSlice(
                    std.json.Value,
                    allocator,
                    actual_call.arguments_json,
                    .{},
                ) catch {
                    return failed("invalid arguments json");
                };
                defer parsed.deinit();

                const actual_args_object = switch (parsed.value) {
                    .object => |obj| obj,
                    else => return failed("arguments json is not object"),
                };

                var expected_parsed = std.json.parseFromSlice(
                    std.json.Value,
                    allocator,
                    expected_args,
                    .{},
                ) catch {
                    return failed("invalid expected arguments json");
                };
                defer expected_parsed.deinit();

                const expected_object = switch (expected_parsed.value) {
                    .object => |obj| obj,
                    else => return failed("expected arguments json is not object"),
                };

                var iter = expected_object.iterator();

                while (iter.next()) |entry| {
                    const actual_value = actual_args_object.get(entry.key_ptr.*) orelse {
                        return failed("missing expected argument field");
                    };
                    if (!jsonValuesEqual(entry.value_ptr.*, actual_value)) {
                        return failed("tool argument value mismatch");
                    }
                }
            }

            break;
        }

        if (!matched) {
            return failed("wrong tool name");
        }
    }

    return passed();
}

fn jsonValuesEqual(expected: std.json.Value, actual: std.json.Value) bool {
    return switch (expected) {
        .null => actual == .null,
        .bool => |value| switch (actual) {
            .bool => |actual_value| actual_value == value,
            else => false,
        },
        .integer => |value| switch (actual) {
            .integer => |actual_value| actual_value == value,
            else => false,
        },
        .float => |value| switch (actual) {
            .float => |actual_value| actual_value == value,
            else => false,
        },
        .number_string => |value| switch (actual) {
            .number_string => |actual_value| std.mem.eql(u8, actual_value, value),
            else => false,
        },
        .string => |value| switch (actual) {
            .string => |actual_value| std.mem.eql(u8, actual_value, value),
            else => false,
        },
        .array => |expected_array| switch (actual) {
            .array => |actual_array| blk: {
                if (expected_array.items.len != actual_array.items.len) break :blk false;
                for (expected_array.items, actual_array.items) |expected_item, actual_item| {
                    if (!jsonValuesEqual(expected_item, actual_item)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
        .object => |expected_object| switch (actual) {
            .object => |actual_object| blk: {
                if (expected_object.count() != actual_object.count()) break :blk false;
                var iter = expected_object.iterator();
                while (iter.next()) |entry| {
                    const actual_value = actual_object.get(entry.key_ptr.*) orelse break :blk false;
                    if (!jsonValuesEqual(entry.value_ptr.*, actual_value)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
    };
}

fn normalizeText(text: []const u8, options: TextMatchOptions) []const u8 {
    if (!options.trim_whitespace) return text;
    return std.mem.trim(u8, text, " \t\r\n");
}

fn textEquals(a: []const u8, b: []const u8, case_sensitive: bool) bool {
    if (case_sensitive) return std.mem.eql(u8, a, b);
    if (a.len != b.len) return false;
    for (a, b) |a_char, b_char| {
        if (std.ascii.toLower(a_char) != std.ascii.toLower(b_char)) return false;
    }
    return true;
}

fn textContains(haystack: []const u8, needle: []const u8, case_sensitive: bool) bool {
    if (case_sensitive) return std.mem.indexOf(u8, haystack, needle) != null;
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var index: usize = 0;
    while (index <= haystack.len - needle.len) : (index += 1) {
        if (textEquals(haystack[index .. index + needle.len], needle, false)) return true;
    }
    return false;
}

fn passed() MatchOutcome {
    return .{
        .passed = true,
        .score = 1.0,
    };
}

fn failed(reason: []const u8) MatchOutcome {
    return .{
        .passed = false,
        .score = 0.0,
        .failure_reason = reason,
    };
}

fn validateFields(
    object: std.json.ObjectMap,
    allowed_fields: []const []const u8,
) !void {
    var iter = object.iterator();
    while (iter.next()) |entry| {
        for (allowed_fields) |allowed| {
            if (std.mem.eql(u8, entry.key_ptr.*, allowed)) break;
        } else {
            return error.InvalidMatcherConfig;
        }
    }
}

fn parseOptionalBool(
    object: std.json.ObjectMap,
    field_name: []const u8,
    default_value: bool,
) !bool {
    const value = object.get(field_name) orelse return default_value;
    return switch (value) {
        .bool => |flag| flag,
        else => error.InvalidMatcherConfig,
    };
}

fn parseRequiredFields(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) ![]const []const u8 {
    const value = object.get("required_fields") orelse return error.InvalidMatcherConfig;
    const fields = switch (value) {
        .array => |array| array.items,
        else => return error.InvalidMatcherConfig,
    };
    if (fields.len == 0) return error.InvalidMatcherConfig;

    var items = std.ArrayList([]const u8){};
    defer items.deinit(allocator);

    for (fields) |field| {
        const text = switch (field) {
            .string => |text| text,
            else => return error.InvalidMatcherConfig,
        };
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return error.InvalidMatcherConfig;
        try items.append(allocator, try allocator.dupe(u8, trimmed));
    }

    return allocator.dupe([]const u8, items.items);
}

fn parseRequiredString(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    field_name: []const u8,
) ![]const u8 {
    const value = object.get(field_name) orelse return error.InvalidMatcherConfig;
    const text = switch (value) {
        .string => |text| text,
        else => return error.InvalidMatcherConfig,
    };
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidMatcherConfig;
    return allocator.dupe(u8, trimmed);
}

fn parseOptionalString(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    field_name: []const u8,
) !?[]const u8 {
    const value = object.get(field_name) orelse return null;
    const text = switch (value) {
        .string => |text| text,
        else => return error.InvalidMatcherConfig,
    };
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return error.InvalidMatcherConfig;
    return try allocator.dupe(u8, trimmed);
}

fn parseOptionalF64(
    object: std.json.ObjectMap,
    field_name: []const u8,
    default_value: f64,
) !f64 {
    const value = object.get(field_name) orelse return default_value;
    const parsed = switch (value) {
        .float => |number| number,
        .integer => |number| @as(f64, @floatFromInt(number)),
        else => return error.InvalidMatcherConfig,
    };
    if (parsed < 0.0 or parsed > 1.0) return error.InvalidMatcherConfig;
    return parsed;
}

test "MatcherConfig supports all matcher kinds" {
    const exact = MatcherConfig{
        .exact_match = .{
            .case_sensitive = true,
            .trim_whitespace = true,
        },
    };
    const includes = MatcherConfig{
        .includes = .{
            .case_sensitive = false,
            .trim_whitespace = true,
        },
    };
    const fields = [_][]const u8{ "answer", "score" };
    const json = MatcherConfig{
        .json_fields = .{
            .required_fields = fields[0..],
        },
    };
    const model_grade = MatcherConfig{
        .model_grade = .{
            .judge_service = "judge",
            .judge_model = "judge-model",
            .rubric = "Score correctness from 0 to 1.",
            .pass_score = 0.8,
        },
    };

    try std.testing.expect(exact == .exact_match);
    try std.testing.expect(includes == .includes);
    try std.testing.expect(json == .json_fields);
    try std.testing.expect(model_grade == .model_grade);
    try std.testing.expectEqual(@as(usize, 2), json.json_fields.required_fields.len);
    try std.testing.expectEqual(@as(f64, 0.8), model_grade.model_grade.pass_score);
}

test "parseMatcherConfig parses all matcher kinds" {
    const samples = [_][]const u8{
        "{\"kind\":\"exact_match\",\"case_sensitive\":false}",
        "{\"kind\":\"includes\",\"trim_whitespace\":false}",
        "{\"kind\":\"json_fields\",\"required_fields\":[\"answer\",\"score\"]}",
        "{\"kind\":\"model_grade\",\"judge_service\":\"judge\",\"judge_model\":\"gpt-judge\",\"rubric\":\"Score correctness.\",\"pass_score\":0.75}",
    };

    for (samples) |sample| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();

        var parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), sample, .{});
        defer parsed.deinit();

        const config = try parseMatcherConfig(arena.allocator(), parsed.value);
        switch (config) {
            .exact_match, .includes, .json_fields, .model_grade => {},
            .tool_call => {},
        }
    }
}

test "parseMatcherConfig parses model_grade defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        arena.allocator(),
        "{\"kind\":\"model_grade\",\"judge_service\":\"judge\",\"rubric\":\"Score factual correctness.\"}",
        .{},
    );
    defer parsed.deinit();

    const config = try parseMatcherConfig(arena.allocator(), parsed.value);

    try std.testing.expect(config == .model_grade);
    try std.testing.expectEqualStrings("judge", config.model_grade.judge_service);
    try std.testing.expect(config.model_grade.judge_model == null);
    try std.testing.expectEqualStrings("Score factual correctness.", config.model_grade.rubric);
    try std.testing.expectEqual(@as(f64, 1.0), config.model_grade.pass_score);
}

test "parseMatcherConfig rejects invalid model_grade pass_score" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        arena.allocator(),
        "{\"kind\":\"model_grade\",\"judge_service\":\"judge\",\"rubric\":\"Score correctness.\",\"pass_score\":1.5}",
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectError(
        error.InvalidMatcherConfig,
        parseMatcherConfig(arena.allocator(), parsed.value),
    );
}

test "renderModelGradePrompt includes grading context and json contract" {
    const prompt = try renderModelGradePrompt(
        std.testing.allocator,
        .{
            .judge_service = "judge",
            .judge_model = "judge-model",
            .rubric = "Check factual correctness and completeness.",
            .pass_score = 0.8,
        },
        .{
            .input = "What is the capital of France?",
            .output = "Paris.",
            .ideal = "Paris",
        },
    );
    defer std.testing.allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "Check factual correctness and completeness.") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "0.800") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "What is the capital of France?") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Paris.") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Ideal answer:\nParis") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"score\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"passed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\"reason\"") != null);
}

test "renderModelGradePrompt handles missing ideal" {
    const prompt = try renderModelGradePrompt(
        std.testing.allocator,
        .{
            .judge_service = "judge",
            .rubric = "Score usefulness.",
        },
        .{
            .input = "Explain retry backoff.",
            .output = "Retry after a delay.",
        },
    );
    defer std.testing.allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "No ideal answer was provided.") != null);
}

test "parseMatcherConfig rejects empty required_fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        arena.allocator(),
        "{\"kind\":\"json_fields\",\"required_fields\":[]}",
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectError(
        error.InvalidMatcherConfig,
        parseMatcherConfig(arena.allocator(), parsed.value),
    );
}

test "parseMatcherConfig rejects unknown kinds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        arena.allocator(),
        "{\"kind\":\"fuzzy_match\"}",
        .{},
    );
    defer parsed.deinit();

    try std.testing.expectError(
        error.InvalidMatcherConfig,
        parseMatcherConfig(arena.allocator(), parsed.value),
    );
}

test "evaluate exact_match passes with trimming" {
    const outcome = try evaluate(
        std.testing.allocator,
        .{ .exact_match = .{ .case_sensitive = true, .trim_whitespace = true } },
        " OK\n",
        "OK",
        null,
        null,
    );

    try std.testing.expect(outcome.passed);
    try std.testing.expectEqual(@as(f64, 1.0), outcome.score);
}

test "evaluate exact_match honors case sensitivity" {
    const sensitive = try evaluate(
        std.testing.allocator,
        .{ .exact_match = .{ .case_sensitive = true, .trim_whitespace = true } },
        "ok",
        "OK",
        null,
        null,
    );
    const insensitive = try evaluate(
        std.testing.allocator,
        .{ .exact_match = .{ .case_sensitive = false, .trim_whitespace = true } },
        "ok",
        "OK",
        null,
        null,
    );

    try std.testing.expect(!sensitive.passed);
    try std.testing.expect(insensitive.passed);
}

test "evaluate includes honors case and trimming options" {
    const outcome = try evaluate(
        std.testing.allocator,
        .{ .includes = .{ .case_sensitive = false, .trim_whitespace = true } },
        "  Product is READY.  ",
        "ready",
        null,
        null,
    );

    try std.testing.expect(outcome.passed);
}

test "evaluate text matchers fail with missing ideal" {
    const outcome = try evaluate(
        std.testing.allocator,
        .{ .exact_match = .{} },
        "OK",
        null,
        null,
        null,
    );

    try std.testing.expect(!outcome.passed);
    try std.testing.expectEqualStrings("missing ideal", outcome.failure_reason.?);
}

test "evaluate json_fields passes when required fields exist" {
    const fields = [_][]const u8{ "answer", "score" };
    const outcome = try evaluate(
        std.testing.allocator,
        .{ .json_fields = .{ .required_fields = fields[0..] } },
        "{\"answer\":\"OK\",\"score\":1}",
        null,
        null,
        null,
    );

    try std.testing.expect(outcome.passed);
}

test "evaluate json_fields fails for invalid JSON" {
    const fields = [_][]const u8{"answer"};
    const outcome = try evaluate(
        std.testing.allocator,
        .{ .json_fields = .{ .required_fields = fields[0..] } },
        "not json",
        null,
        null,
        null,
    );

    try std.testing.expect(!outcome.passed);
    try std.testing.expectEqualStrings("invalid json output", outcome.failure_reason.?);
}

test "evaluate json_fields fails when required field is missing" {
    const fields = [_][]const u8{ "answer", "score" };
    const outcome = try evaluate(
        std.testing.allocator,
        .{ .json_fields = .{ .required_fields = fields[0..] } },
        "{\"answer\":\"OK\"}",
        null,
        null,
        null,
    );

    try std.testing.expect(!outcome.passed);
    try std.testing.expectEqualStrings("missing required json field", outcome.failure_reason.?);
}

test "evaluate model_grade requires judge execution" {
    try std.testing.expectError(
        error.ModelGradeRequiresJudge,
        evaluate(
            std.testing.allocator,
            .{
                .model_grade = .{
                    .judge_service = "judge",
                    .rubric = "Score correctness.",
                },
            },
            "candidate",
            null,
            null,
            null,
        ),
    );
}

test "evaluate tool_call passes with matching tool name and args" {
    const actual_calls = [_]services.ToolCall{
        .{
            .name = "search_web",
            .arguments_json = "{\"query\":\"weather melbourne\"}",
        },
    };

    const expected_calls = [_]registry.ExpectedToolCall{
        .{
            .name = "search_web",
            .arguments_json = "{\"query\":\"weather melbourne\"}",
        },
    };

    const outcome = try evaluate(
        std.testing.allocator,
        .{
            .tool_call = .{},
        },
        "",
        null,
        actual_calls[0..],
        expected_calls[0..],
    );

    try std.testing.expect(outcome.passed);
}

test "evaluate tool_call fails for mismatched argument value" {
    const actual_calls = [_]services.ToolCall{
        .{
            .name = "search_web",
            .arguments_json = "{\"query\":\"weather melbourne\"}",
        },
    };

    const expected_calls = [_]registry.ExpectedToolCall{
        .{
            .name = "search_web",
            .arguments_json = "{\"query\":\"weather sydney\"}",
        },
    };

    const outcome = try evaluate(
        std.testing.allocator,
        .{
            .tool_call = .{},
        },
        "",
        null,
        actual_calls[0..],
        expected_calls[0..],
    );

    try std.testing.expect(!outcome.passed);
    try std.testing.expectEqualStrings("tool argument value mismatch", outcome.failure_reason.?);
}

test "evaluate tool_call fails for wrong tool name" {
    const actual_calls = [_]services.ToolCall{
        .{
            .name = "lookup_weather",
            .arguments_json = "{\"query\":\"weather melbourne\"}",
        },
    };

    const expected_calls = [_]registry.ExpectedToolCall{
        .{
            .name = "search_web",
            .arguments_json = "{\"query\":\"x\"}",
        },
    };

    const outcome = try evaluate(
        std.testing.allocator,
        .{
            .tool_call = .{},
        },
        "",
        null,
        actual_calls[0..],
        expected_calls[0..],
    );

    try std.testing.expect(!outcome.passed);
}

test "evaluate tool_call fails for invalid arguments json" {
    const actual_calls = [_]services.ToolCall{
        .{
            .name = "search_web",
            .arguments_json = "{invalid json}",
        },
    };

    const expected_calls = [_]registry.ExpectedToolCall{
        .{
            .name = "search_web",
            .arguments_json = "{\"query\":\"x\"}",
        },
    };

    const outcome = try evaluate(
        std.testing.allocator,
        .{
            .tool_call = .{},
        },
        "",
        null,
        actual_calls[0..],
        expected_calls[0..],
    );

    try std.testing.expect(!outcome.passed);
}

test "evaluate tool_call fails for missing expected argument field" {
    const actual_calls = [_]services.ToolCall{
        .{
            .name = "search_web",
            .arguments_json = "{\"location\":\"melbourne\"}",
        },
    };

    const expected_calls = [_]registry.ExpectedToolCall{
        .{
            .name = "search_web",
            .arguments_json = "{\"query\":\"x\"}",
        },
    };

    const outcome = try evaluate(
        std.testing.allocator,
        .{
            .tool_call = .{},
        },
        "",
        null,
        actual_calls[0..],
        expected_calls[0..],
    );

    try std.testing.expect(!outcome.passed);
}
