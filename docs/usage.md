# Running Product Evals With `zig_eval`

`zig_eval` is a library-first eval framework. The CLI entrypoint exists, but
full CLI execution is not implemented yet. For now, product evals are wired from
Zig code using the registry, service, runner, and reporting modules.

## Flow

```text
services.json
    -> eval definition JSON files
    -> JSONL datasets
    -> runner
    -> raw run results
    -> text or JSON reports
```

## 1. Configure Services

Services define the products or model endpoints to test. Use
`examples/registry/services.json` as a starting point.

Each service needs:

- `name`: stable name used in reports and allowlists
- `base_url`: OpenAI-compatible chat-completions endpoint
- `default_model`: model name sent in the request
- `timeout_ms`: request timeout value for the service config

`api_key_env`, `provider`, and `system_prompt` are optional. Omit
`api_key_env` for local or internal endpoints that do not require Bearer-token
authentication.

## 2. Define Evals

Eval definitions live under `examples/registry/evals`.

Each eval definition points to one dataset and one matcher config:

```json
{
  "id": "smoke.reply_ok",
  "group": "smoke",
  "description": "Checks that a service can return a simple literal response.",
  "dataset_path": "data/smoke/reply_ok/test.jsonl",
  "split": "test",
  "matcher": {
    "kind": "exact_match",
    "case_sensitive": true,
    "trim_whitespace": true
  },
  "default_run_count": 1,
  "service_allowlist": ["local-product", "product-staging"]
}
```

`service_allowlist` is optional. If present, the runner only runs that eval
against the listed services.

## 3. Add Dataset Cases

Datasets are JSONL files under `examples/registry/data`. Each line is one eval
case with an input prompt and optional expected value.

```jsonl
{"id":"case-1","input":"Reply with exactly OK.","ideal":"OK"}
{"id":"case-2","input":"Reply with exactly READY.","ideal":"READY"}
```

## 4. Wire The Library From Zig

The runner requires a matcher adapter. This is intentional: matcher scoring is
still pending teammate work, so current integrations should provide an adapter
that calls the final matcher API once it exists.

```zig
const std = @import("std");
const zig_eval = @import("zig_eval");

fn evaluateMatcher(
    allocator: std.mem.Allocator,
    matcher: zig_eval.matchers.MatcherConfig,
    output: []const u8,
    ideal: ?[]const u8,
) anyerror!zig_eval.runner.MatcherOutcome {
    _ = allocator;
    _ = matcher;
    _ = output;
    _ = ideal;

    // Replace this with the real matcher implementation.
    return error.MatcherNotImplemented;
}

pub fn runProductEvals(allocator: std.mem.Allocator) !void {
    var cwd = try std.fs.cwd().openDir(".", .{});
    defer cwd.close();

    var loaded_services = try zig_eval.services.loadServices(
        allocator,
        cwd,
        "examples/registry/services.json",
    );
    defer loaded_services.deinit();

    var loaded_evals = try zig_eval.registry.loadAllEvalDefinitions(
        allocator,
        cwd,
        "examples/registry/evals",
    );
    defer loaded_evals.deinit();

    var runner_result = try zig_eval.runner.runEvaluations(allocator, .{
        .root_dir = cwd,
        .services = loaded_services.items,
        .evals = loaded_evals.items,
        .matcher_evaluator = evaluateMatcher,
    });
    defer runner_result.deinit();

    var reports = try zig_eval.reporting.aggregateRunResults(
        allocator,
        runner_result.runs,
    );
    defer reports.deinit();

    var text_out = std.Io.Writer.Allocating.init(allocator);
    defer text_out.deinit();
    try zig_eval.reporting.formatEvalReports(&text_out.writer, reports.items);

    var json_out = std.Io.Writer.Allocating.init(allocator);
    defer json_out.deinit();
    try zig_eval.reporting.formatEvalReportsJson(&json_out.writer, reports.items);
}
```

## Current Limitations

- CLI execution is not implemented yet.
- Matcher scoring is still pending teammate work.
- Service calls must target an OpenAI-compatible chat-completions endpoint.
- Streaming, tool-calling, multimodal evals, and model-graded evals are out of
  scope for the current implementation.
