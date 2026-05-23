# Running Product Evals With `zig_eval`

`zig_eval` is a registry-driven eval tool and library. V1 supports deterministic
matchers, OpenAI-compatible chat-completions services, CLI execution, and text
or JSON report output.

## Flow

```text
services.json
    -> eval definition JSON files
    -> JSONL datasets
    -> zig_eval list/run
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

Services can also define retry behavior:

```json
{
  "retry": {
    "max_attempts": 3,
    "backoff_ms": 500,
    "retry_on_status": [429, 500, 502, 503, 504]
  }
}
```

## 2. Define Evals

Eval definitions live under `examples/registry/evals`.

Each eval definition points to one dataset and one matcher config. Dataset
paths are relative to the registry root when using the CLI or registry-root
loaders.

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

`exact_match` and `includes` use `ideal`. `json_fields` checks the service
output for configured root-level JSON fields.

## 4. Run From The CLI

List services and evals:

```sh
zig build run -- list --registry examples/registry
```

Run evals with the default text report:

```sh
zig build run -- run --registry examples/registry --service local-product
```

Run one eval and write aggregate JSON to stdout:

```sh
zig build run -- run --registry examples/registry --service local-product --eval smoke.reply_ok --format json
```

Run with bounded parallelism while limiting concurrent requests per service:

```sh
zig build run -- run --registry examples/registry --parallel 4 --max-inflight-per-service 2
```

Supported flags:

- `--registry PATH`: registry root, default `examples/registry`
- `--service NAME`: run only one service
- `--group GROUP`: run only one eval group
- `--eval ID`: run only one eval id
- `--runs N`: override each eval's `default_run_count`
- `--parallel N`: number of worker threads, default `1`
- `--max-inflight-per-service N`: max concurrent requests per service, default
  `1`
- `--format text|json`: report format, default `text`

`run` requires the selected service endpoint to be reachable and compatible
with OpenAI-style chat completions.

Text output prints progress lines during parallel runs. JSON output suppresses
progress so stdout remains machine-readable.

## 5. Wire The Library From Zig

The CLI is the easiest path, but library users can still call the same modules
directly.

```zig
const std = @import("std");
const zig_eval = @import("zig_eval");

fn evaluateMatcher(
    allocator: std.mem.Allocator,
    matcher: zig_eval.matchers.MatcherConfig,
    output: []const u8,
    ideal: ?[]const u8,
) anyerror!zig_eval.runner.MatcherOutcome {
    const outcome = try zig_eval.matchers.evaluate(allocator, matcher, output, ideal);
    return .{
        .passed = outcome.passed,
        .score = outcome.score,
        .failure_reason = outcome.failure_reason,
    };
}

pub fn runProductEvals(allocator: std.mem.Allocator) !void {
    var registry_dir = try std.fs.cwd().openDir("examples/registry", .{});
    defer registry_dir.close();

    var loaded_services = try zig_eval.services.loadServices(
        allocator,
        registry_dir,
        "services.json",
    );
    defer loaded_services.deinit();

    var loaded_evals = try zig_eval.registry.loadRegistryEvalDefinitions(
        allocator,
        registry_dir,
    );
    defer loaded_evals.deinit();

    var runner_result = try zig_eval.runner.runEvaluations(allocator, .{
        .root_dir = registry_dir,
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
}
```

## Current Limitations

- Service calls must target an OpenAI-compatible chat-completions endpoint.
- JSON field matching checks root-level fields only.
- Streaming, tool-calling, multimodal evals, and advanced significance testing
  are out of scope for v1.
