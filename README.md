# zig_eval

`zig_eval` is a registry-driven evaluation library for testing LLM products,
agent runtimes, and OpenAI-compatible chat APIs from Zig.

It is not tied to a single application. A team can point `zig_eval` at any
product that exposes a chat-completions-style endpoint, define datasets as
JSONL, group evals by capability, and compare behavior across services or
models.

## Current Capabilities

- Load service definitions from JSON.
- Load grouped eval definitions from a registry directory.
- Load eval cases from JSONL datasets.
- Evaluate exact-match, includes, and required JSON field checks.
- Call an OpenAI-compatible `POST /v1/chat/completions` endpoint.
- Support authenticated and unauthenticated product endpoints.
- Run grouped eval definitions across configured services and datasets.
- Aggregate results into plain-text and JSON report artifacts.
- Run evals from the `zig_eval` CLI with service, group, eval, run-count, and
  output-format filters.
- Run evals with bounded parallelism, per-service throttling, and retry
  metadata in reports.

## How It Works

`zig_eval` loads services, eval definitions, and JSONL datasets from a registry,
then the runner sends each eval case to each selected service. Raw run results
can be aggregated into readable text reports or machine-readable JSON artifacts.

See [docs/usage.md](docs/usage.md) for a complete library usage example.
See [docs/reference.md](docs/reference.md) for registry and report field
definitions.

## Quick Start

List the example registry:

```sh
zig build run -- list --registry examples/registry
```

Run one eval against one configured service:

```sh
zig build run -- run --registry examples/registry --service local-product --eval smoke.reply_ok
```

Use JSON report output:

```sh
zig build run -- run --registry examples/registry --service local-product --format json
```

Run with bounded parallel workers:

```sh
zig build run -- run --registry examples/registry --parallel 4 --max-inflight-per-service 2
```

`run` requires the selected service endpoint to be reachable.

## Registry Layout

The repository includes a starter registry under `examples/registry`.

```text
registry
├── services.json
├── evals
│   └── <group>
│       └── <eval>.json
└── data
    └── <group>
        └── <eval>
            └── <split>.jsonl
```

## Service Configuration

`registry/services.json` is an array of service definitions. Use `api_key_env`
for Bearer-token authentication, or omit it for internal products that do not
need auth.

```json
[
  {
    "name": "product-staging",
    "base_url": "https://product.example.com/v1/chat/completions",
    "api_key_env": "PRODUCT_STAGING_API_KEY",
    "default_model": "product-model",
    "provider": "product",
    "system_prompt": "Answer exactly according to the eval instructions.",
    "timeout_ms": 30000
  },
  {
    "name": "local-product",
    "base_url": "http://127.0.0.1:9000/v1/chat/completions",
    "default_model": "local-model",
    "timeout_ms": 15000
  }
]
```

## Eval Definition

Each eval definition points to a dataset and one matcher.

```json
{
  "id": "smoke.reply_ok",
  "group": "smoke",
  "description": "Checks that the service can return a simple literal answer.",
  "dataset_path": "data/smoke/reply_ok/test.jsonl",
  "split": "test",
  "matcher": {
    "kind": "exact_match",
    "case_sensitive": true,
    "trim_whitespace": true
  },
  "default_run_count": 3,
  "service_allowlist": ["product-staging", "local-product"]
}
```

## Dataset Format

Datasets are JSONL files. Each line is one eval case.

```jsonl
{"id":"case-1","input":"Reply with exactly OK.","ideal":"OK"}
{"id":"case-2","input":"Reply with exactly READY.","ideal":"READY"}
```

## Example Registry

Use `examples/registry` as a copyable starting point for a product eval suite.
It includes:

- one unauthenticated local product service
- one authenticated staging product service
- one smoke eval using `exact_match`
- one structured-output eval using `json_fields`

## Retry policy

Services may define retry behavior:

```json
{
  "retry": {
    "max_attempts": 3,
    "backoff_ms": 500,
    "retry_on_status": [429, 500, 502, 503, 504]
  }
}
```

## Design Direction

The v1 focus is a small, stable core:

- OpenAI-compatible chat execution.
- Product-neutral service configuration.
- Capability-based eval grouping.
- Deterministic matchers plus V2 model-graded judging.
- Clear ownership of allocated data in public APIs.

## Resources

- [Scalabs' Dart Eval library](https://github.com/scalabs/eval)
- [OpenAI's Evals Repo](https://github.com/openai/evals)
