# `zig_eval` Registry And Report Reference

This page documents the file formats and report shapes supported by the current
library implementation.

## Registry Layout

```text
examples/registry
|-- services.json
|-- evals
|   `-- <group>
|       `-- <eval>.json
`-- data
    `-- <group>
        `-- <eval>
            `-- <split>.jsonl
```

`loadAllEvalDefinitions` recursively discovers `.json` files under the evals
directory. Each eval definition must point to an existing dataset path.

## Service Config

`services.json` is an array of service objects.

| Field | Required | Meaning |
| --- | --- | --- |
| `name` | yes | Stable service name used in filters, allowlists, and reports. |
| `base_url` | yes | OpenAI-compatible chat-completions endpoint or base URL. |
| `default_model` | yes | Model sent when a run does not override the model. |
| `timeout_ms` | yes | Timeout value stored with the service config. |
| `api_key_env` | no | Environment variable read for Bearer-token auth. |
| `provider` | no | Provider value included in the OpenAI-style payload. |
| `system_prompt` | no | Default system prompt added before user prompts. |

Example:

```json
{
  "name": "product-staging",
  "base_url": "https://product.example.com/v1/chat/completions",
  "api_key_env": "PRODUCT_STAGING_API_KEY",
  "default_model": "product-model",
  "provider": "product",
  "system_prompt": "Follow the eval instructions exactly.",
  "timeout_ms": 30000
}
```

## Eval Definition

Each eval definition describes one eval and points to one JSONL dataset.

| Field | Required | Meaning |
| --- | --- | --- |
| `id` | yes | Unique eval id, usually `<group>.<name>`. |
| `group` | yes | Capability group used for filtering and reporting. |
| `description` | yes | Human-readable eval purpose. |
| `dataset_path` | yes | Path to the dataset JSONL file, relative to the registry root when using registry-root loading. |
| `split` | yes | Dataset split name, such as `test`. |
| `matcher` | yes | Matcher configuration parsed by `matchers.parseMatcherConfig`. |
| `default_run_count` | yes | Number of times each case should run by default. |
| `service_allowlist` | no | Service names allowed for this eval. |

Supported matcher config kinds are currently `exact_match`, `includes`, and
`json_fields`.

## Dataset Case

Datasets are newline-delimited JSON. Each non-empty line is one case.

| Field | Required | Meaning |
| --- | --- | --- |
| `id` | yes | Stable case id used in run results. |
| `input` | yes | Prompt sent to the service as the user message. |
| `ideal` | no | Expected value used by matcher implementations. |

Example:

```jsonl
{"id":"case-1","input":"Reply with exactly OK.","ideal":"OK"}
```

## Runner Output

The runner returns `runner.RunResult` values. Each result represents one service
response for one eval case and one run index.

Important fields:

- `group`, `eval_id`, `service_name`, `model`, `case_id`
- `run_index`
- `output`
- `passed`, `score`, `failure_reason`
- `latency_ms`

Service call failures are converted into failed run results with
`failure_reason` set to the error name.

## JSON Report Artifacts

`reporting.formatRunResultsJson` writes raw run artifacts:

```json
{
  "schema_version": 1,
  "runs": [
    {
      "group": "smoke",
      "eval_id": "smoke.reply_ok",
      "service_name": "local-product",
      "model": "local-eval-model",
      "run_index": 1,
      "case_id": "case-1",
      "output": "OK",
      "passed": true,
      "score": 1,
      "failure_reason": null,
      "latency_ms": 42
    }
  ]
}
```

`reporting.formatEvalReportsJson` writes grouped aggregate artifacts:

```json
{
  "schema_version": 1,
  "evals": [
    {
      "group": "smoke",
      "eval_id": "smoke.reply_ok",
      "stats": {
        "counts": {
          "total_runs": 2,
          "passed": 2,
          "failed": 0
        },
        "pass_rate": 1,
        "latency": {
          "mean_ms": 42,
          "p50_ms": 40,
          "p95_ms": 44
        }
      },
      "services": []
    }
  ]
}
```

The current schema version is `1`.
