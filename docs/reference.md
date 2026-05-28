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
`-- assets
    `-- <project files used by dataset attachments>
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
| `retry.max_attempts` | no | Maximum attempts for retryable service calls. Defaults to `1`. |
| `retry.backoff_ms` | no | Linear backoff delay in milliseconds between retry attempts. |
| `retry.retry_on_status` | no | HTTP status codes that should retry before failing. |

Example:

```json
{
  "name": "product-staging",
  "base_url": "https://product.example.com/v1/chat/completions",
  "api_key_env": "PRODUCT_STAGING_API_KEY",
  "default_model": "product-model",
  "provider": "product",
  "system_prompt": "Follow the eval instructions exactly.",
  "timeout_ms": 30000,
  "retry": {
    "max_attempts": 3,
    "backoff_ms": 500,
    "retry_on_status": [429, 500, 502, 503, 504]
  }
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
| `tools` | no | OpenAI-compatible function tool schemas used by `tool_call` evals. |

Supported matcher config kinds:

- `exact_match`: compares output with `ideal`, with optional case sensitivity
  and whitespace trimming.
- `includes`: checks whether output contains `ideal`, with optional case
  sensitivity and whitespace trimming.
- `json_fields`: checks that the output is a JSON object containing configured
  root-level fields.
- `model_grade`: configures an LLM judge with `judge_service`, optional
  `judge_model`, `rubric`, and `pass_score`. The judge prompt includes eval
  input, candidate output, optional `ideal`, and the rubric. The runner calls
  the judge service and converts the judge JSON into a score and pass/fail
  result. CLI users can override `judge_service` with `--judge-service`.
- `tool_call`: validates that an OpenAI-style response contains the expected
  tool name and expected root-level argument values.

Example model-graded matcher:

```json
{
  "kind": "model_grade",
  "judge_service": "judge",
  "judge_model": "gpt-4.1-mini",
  "rubric": "Score whether the answer is correct, complete, and concise.",
  "pass_score": 0.8
}
```

The judge is instructed to return JSON only:

```json
{"score":0.0,"passed":false,"reason":"short explanation"}
```

Judge response fields:

| Field | Required | Meaning |
| --- | --- | --- |
| `score` | yes | Numeric grade between `0` and `1`. |
| `passed` | yes | Judge's pass/fail decision. The runner also requires `score >= pass_score`. |
| `reason` | yes | Short explanation stored as the failure reason when the eval fails. |

For model-graded evals, `service_allowlist` should usually list only product
services. The judge service is selected by `matcher.judge_service` or
`--judge-service` and does not need to be in the allowlist.

Example tool-calling eval:

```json
{
  "id": "tools.search_web",
  "group": "tools",
  "description": "Checks that the product chooses the search_web tool.",
  "dataset_path": "data/tools/search_web/test.jsonl",
  "split": "test",
  "tools": [
    {
      "name": "search_web",
      "description": "Search the web for current information.",
      "parameters_json": "{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\"}},\"required\":[\"query\"]}"
    }
  ],
  "matcher": {
    "kind": "tool_call"
  },
  "default_run_count": 1,
  "service_allowlist": ["local-product"]
}
```

`parameters_json` must parse as a JSON object. `tool_call` does not execute the
tool or run a multi-turn loop.

## Dataset Case

Datasets are newline-delimited JSON. Each non-empty line is one case.

| Field | Required | Meaning |
| --- | --- | --- |
| `id` | yes | Stable case id used in run results. |
| `input` | yes | Prompt sent to the service as the user message. |
| `ideal` | no | Expected value used by matcher implementations. |
| `expected_tool_calls` | no | Expected OpenAI-style tool call names and optional root-level argument values. |
| `attachments` | no | Files attached to the case and resolved relative to the registry root. |

Example:

```jsonl
{"id":"case-1","input":"Reply with exactly OK.","ideal":"OK"}
```

Tool-calling case example:

```jsonl
{"id":"case-1","input":"Search the web for the weather in Melbourne.","expected_tool_calls":[{"name":"search_web","arguments_json":"{\"query\":\"weather melbourne\"}"}]}
```

For `expected_tool_calls[*].arguments_json`, every expected root-level field
must exist in the actual tool arguments and have the same JSON value. Extra
actual argument fields are allowed.

Attachment example:

```jsonl
{"id":"case-1","input":"Summarize the attached changelog.","ideal":"Mentions retries.","attachments":[{"kind":"file","path":"assets/changelogs/release.md","mime_type":"text/markdown","label":"release notes"}]}
```

Attachment fields:

| Field | Required | Meaning |
| --- | --- | --- |
| `kind` | yes | `image` or `file`. |
| `path` | yes | Registry-relative file path. Absolute paths and `..` segments are rejected. |
| `mime_type` | no | Explicit MIME type. If omitted, it is inferred for supported extensions. |
| `label` | no | Human-readable label used when rendering text attachments. |

The default renderer supports PNG, JPEG, WebP, and UTF-8 text-like files. Each
attachment is limited to `5 MB`. Unsupported binary file types require a custom
service adapter.

## Runner Output

The runner returns `runner.RunResult` values. Each result represents one service
response for one eval case and one run index.

Important fields:

- `group`, `eval_id`, `service_name`, `model`, `case_id`
- `run_index`
- `output`
- `passed`, `score`, `failure_reason`
- `status_code`, `attempt_count`, `retried`
- `judge_attempt_count`, `judge_retried`, `judge_status_code` for model-graded evals
- `latency_ms`

Service call failures are converted into failed run results with
`failure_reason` set to the error name or upstream failure message. Retry
attempts include candidate calls and model-grade judge calls.

## JSON Report Artifacts

`reporting.formatRunResultsJson` writes raw run artifacts:

```json
{
  "schema_version": 2,
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
      "status_code": 200,
      "attempt_count": 1,
      "retried": false,
      "judge_attempt_count": 0,
      "judge_retried": false,
      "judge_status_code": null,
      "latency_ms": 42
    }
  ]
}
```

`reporting.formatEvalReportsJson` writes grouped aggregate artifacts:

```json
{
  "schema_version": 2,
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
        "confidence_level": 0.95,
        "pass_rate_ci_low": 0.34,
        "pass_rate_ci_high": 1,
        "latency": {
          "mean_ms": 42,
          "p50_ms": 40,
          "p95_ms": 44
        },
        "retries": {
          "retried_runs": 0,
          "total_attempts": 2
        }
      },
      "services": []
    }
  ]
}
```

`reporting.formatBaselineComparisonsJson` writes baseline comparison artifacts:

```json
{
  "schema_version": 2,
  "baseline_comparisons": [
    {
      "group": "smoke",
      "eval_id": "smoke.reply_ok",
      "target_kind": "service",
      "service_name": null,
      "baseline_name": "local-product",
      "candidate_name": "product-staging",
      "baseline_pass_rate": 0.8,
      "candidate_pass_rate": 0.9,
      "delta_pass_rate": 0.1,
      "delta_ci_low": -0.1,
      "delta_ci_high": 0.3,
      "confidence_level": 0.95
    }
  ]
}
```

The current schema version is `2`.
