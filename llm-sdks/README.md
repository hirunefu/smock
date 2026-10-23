# The SDK job

The SDK job reads smock's [LLM responses](../docs/definition-files.md#llm-responses)
with the official SDKs of the vendors, openai-python and
anthropic-sdk-python, as applications call them. It catches a change to
smock that breaks an SDK before a release. Each SDK and every package it
needs is pinned by version and hash, so the job changes only when a pin is
raised on purpose.

## Where it runs

`.github/workflows/ci.yml` runs it as the job `llm-sdks`, on every push and
pull request, after its call of `build-test.yml`. It builds nothing: it
takes the amd64 release binary that `build-test.yml` keeps, built with the
pinned toolchain (`smock-linux-amd64`). The weekly run with the latest
toolchain (`latest-toolchain.yml`) does not run it.
`scripts/check-ci-artifacts.sh` checks these rules.

## What is here

| File | What it is |
|---|---|
| `definitions/llm.yaml` | The Definition file made for the job. Its one Mock answers both SDKs, and each Stub answers one model, named as its id. |
| `check.py` | The script. It checks the Definition file with `smock check`, serves it, calls each Stub through an SDK and checks what the SDK reads. |
| `requirements.in` | The SDKs, each pinned to one version. |
| `requirements.txt` | The SDKs and every package they need, each pinned by version and by the hashes of its files. It is generated from `requirements.in`. |
| `.python-version` | The Python the job runs with. |

`scripts/check-llm-sdks.sh` makes a virtual environment, installs
`requirements.txt` into it by hash, and runs `check.py`. pip installs only
files whose hashes are listed, and only wheels, so nothing is built and a
package missing from the list fails the install.

## What it checks

`check.py` uses only the SDKs and the standard library, and builds every
client with `max_retries=0`, so that each call sends one request. Only the
retry checks, below, keep the default retries.

- Chat Completions: `create` with and without `stream`, a stream with
  `stream_options.include_usage`, and the `stream()` helper with function
  tools. It checks the text, the tool calls and their arguments as the SDK
  parses them, usage, stop reasons, ids and the request id that the SDK
  reads from the `x-request-id` header, and what every chunk of a stream
  shares.
- Responses: `create` with and without `stream`, and the `stream()` helper
  with text and with two tool calls, given function tools. It checks the
  text, the function call items and their arguments as the SDK parses
  them, usage, ids and the request id, and what every event of a stream
  shares: sequence numbers from 0, one id, and each item added before its
  content and done with the ids of its added event. For a Stub with a stop
  reason, it checks the incomplete reason, and that the helper's
  `get_final_response()` raises `RuntimeError`, since the stream ends with
  `response.incomplete`, as the vendor's does.
- Anthropic Messages: `create` with and without `stream`, and the
  `stream()` helper with `get_final_message()`. It checks the text, the
  `tool_use` blocks and their `input` as the SDK parses it, usage, stop
  reasons with `stop_sequence` and a refusal's `stop_details`, ids and the
  request id that the SDK reads from the `request-id` header, and the
  frame of a stream: `message_start` first, `message_delta` and
  `message_stop` last, and each block opened, given its deltas and
  stopped in turn, at integer indexes. For a tool call whose arguments
  are not JSON, it checks that `create` gives them as written and that
  the `stream()` helper raises `ValueError` on them mid-stream, as it
  would on such a stream from the vendor.
- The reply that the `stream()` helper builds from a stream equals the one
  the SDK parses from the JSON reply, apart from differences listed by
  name, each with its reason, in `CHAT_HELPER_DIFFERENCES`,
  `RESPONSES_HELPER_DIFFERENCES` and `MESSAGES_HELPER_DIFFERENCES` (and,
  for a Stub whose ids are generated, `GENERATED_ID_DIFFERENCES`,
  `RESPONSES_GENERATED_ID_DIFFERENCES` and
  `MESSAGES_GENERATED_ID_DIFFERENCES`). Any other difference fails the
  check.
- Mid-stream errors, with the docs'
  [cut-short Stub](../docs/definition-files.md#mid-stream-errors) for each
  API. openai-python raises `APIError` itself on Chat's error frame, with
  the message and the error object as its body. It yields the Responses
  `error` event as a `ResponseErrorEvent`, and raises nothing; the
  helper's `get_final_response()` then raises `RuntimeError`.
  anthropic-sdk-python raises `APIStatusError` itself, not
  `OverloadedError`, with status 200 and the type in the body. Each comes
  after the text before the cut, from `create(stream=True)` and from the
  `stream()` helper, and `create` without `stream` gets the whole reply.
- Error replies: the docs'
  [429](../docs/definition-files.md#a-429-with-retry-after), in OpenAI's
  form, and [529](../docs/definition-files.md#a-529-when-overloaded), in
  Anthropic's, each response copied as written. Both SDKs get both, and
  each raises its own status error for the status, which keeps the body:
  `RateLimitError` for the 429, and `InternalServerError` from
  openai-python or `OverloadedError` from anthropic-sdk-python for the
  529.
- Retries: with clients that keep the default retries, each call in a
  [Session](../README.md#sessions-and-ephemeral-stubs) of its own, the
  Journal holds one request of the 429, whose `x-should-retry` is
  `"false"`, and three of the 529, which has none, as each SDK retries it
  twice. So the SDKs do retry, and the header is what stops them.

The job fails when a check fails, or when an SDK raises where no check
expects it to. It prints every check, and smock's log when one fails.

To check more, add a Stub to `definitions/llm.yaml` for a model of its own,
write what the script should read beside the other expectations at the top
of `check.py`, and add a case to `CASES`.

## Run it

It needs a Python 3.10 or later with `venv`, and access to PyPI:

```sh
scripts/build-release.sh
scripts/check-llm-sdks.sh dist/smock
PYTHON=python3.14 scripts/check-llm-sdks.sh dist/smock   # another Python
```

A Python other than the one in `.python-version` gets a note, not a
failure.

## Raising a pin

The pins move only by hand: Dependabot does not cover them
([docs/releasing.md](../docs/releasing.md#what-dependabot-does-not-cover)).
Raising a pin is a change of its own, in a pull request that changes
nothing else, so that a difference in what the job sees comes from the new
version alone.

1. Give the new version in `requirements.in`, or the new Python in
   `.python-version`.
2. Generate `requirements.txt` again. This also moves every package the
   SDKs need to its latest version that fits:

   ```sh
   uvx uv@0.13.5 pip compile --generate-hashes \
     --python-version "$(cat llm-sdks/.python-version)" \
     --python-platform x86_64-unknown-linux-gnu \
     llm-sdks/requirements.in -o llm-sdks/requirements.txt
   ```

3. Run the job with a release build, as above.

When the job passes, the pull request is ready. When it fails, the new
version reads smock's replies differently: read its changelog. Either the
SDK changed on purpose and the check, or a listed difference, follows it,
or smock's output must change, which is the case below.

## When smock's output changes

A change that a raised pin brings to what an existing `llm` Stub sends
ships in a minor release, with a line in `CHANGELOG.md` under `### Changed`
that says what the Stub now sends and why, so that test authors know when
to update recorded expectations. So does a change made to follow a
vendor's documented form, which also updates the date of the vendor
documents in [LLM responses](../docs/definition-files.md#llm-responses).

The SDKs are used only in CI. Neither the binary nor the image holds them,
so NOTICE and the SBOM do not name them.
