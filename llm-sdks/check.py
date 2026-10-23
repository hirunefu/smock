"""The SDK job: reads smock's LLM responses with the official SDKs.

It checks llm-sdks/definitions/ with `smock check`, serves it with the given
smock binary, and calls each Stub through openai-python as applications call
the API. Then it checks what the SDK reads: the text, the tool calls and
their parsed arguments, usage, stop reasons, ids and the request id, and
that the reply the SDK's stream helper builds from a stream equals the one
it parses from the JSON reply, apart from differences listed by name.

It uses only the SDKs and the standard library. Every client is built with
max_retries=0, so that each call sends one request.

It prints each check, and exits with status 1 when a check fails or an SDK
raises where no check expects it to.

usage: python llm-sdks/check.py <smock binary>

scripts/check-llm-sdks.sh installs the pinned SDKs and runs it, as CI does.
llm-sdks/README.md says more.
"""

import json
import os
import re
import secrets
import subprocess
import sys
import threading
import time
import traceback
import urllib.request
from pathlib import Path

import openai

DEFINITIONS = Path(__file__).resolve().parent / "definitions"

# How long smock may take to become ready, and to exit after SIGTERM, and
# how long one call may take.
START_TIMEOUT_S = 30
STOP_TIMEOUT_S = 10
CALL_TIMEOUT_S = 30

# The conversation every call sends. The Stubs do not read it.
MESSAGES = [{"role": "user", "content": "Hello!"}]

# Generated ids: the vendor's prefix and 24 characters from A-Z, a-z and
# 0-9.
CHAT_ID = re.compile(r"chatcmpl-[A-Za-z0-9]{24}")
CALL_ID = re.compile(r"call_[A-Za-z0-9]{24}")
REQUEST_ID = re.compile(r"req_[A-Za-z0-9]{24}")
RESPONSE_ID = re.compile(r"resp_[A-Za-z0-9]{24}")
MESSAGE_ID = re.compile(r"msg_[A-Za-z0-9]{24}")
FUNCTION_CALL_ID = re.compile(r"fc_[A-Za-z0-9]{24}")

# What the Stubs of definitions/llm.yaml declare, as the checks expect to
# read it. Each Stub answers the model named as its id.
CHAT_TEXT = "Hi! こんにちは。 👋🏽 How can I help?"
CHAT_TOOLS_TEXT = "Let me check both."
CHAT_TOOLS_CALLS = [
    ("call_sdk_weather", "get_weather", {"city": "東京", "days": 3, "units": {"temperature": "celsius"}}),
    ("call_sdk_time", "get_time", {"timezone": "Asia/Tokyo"}),
]
CHAT_CALL_ONLY_CALL = ("get_weather", {"city": "Paris"})
CHAT_LENGTH_TEXT = "The weather in Paris is"
RESPONSES_TEXT = "Hi! こんにちは。 👋🏽 How can I help?"
RESPONSES_INCOMPLETE_TEXT = "The weather in Paris is"
RESPONSES_TOOLS_TEXT = "Let me look both up."
RESPONSES_TOOLS_CALLS = [
    ("call_sdk_forecast", "get_forecast", {"cities": ["Paris", "東京"], "days": 2, "hourly": False}),
    ("call_sdk_alerts", "get_alerts", {"region": "関東", "severity": None}),
]

# The function tools an application gives the Responses API. With "strict",
# the stream helper parses each call's arguments as JSON.
RESPONSES_TOOLS = [
    {
        "type": "function",
        "name": name,
        "strict": True,
        "parameters": {"type": "object", "properties": {}, "additionalProperties": True},
    }
    for name in ("get_forecast", "get_alerts")
]

# The function tools an application gives the stream helper. With
# "strict", the helper parses each call's arguments as JSON.
CHAT_TOOLS = [
    {
        "type": "function",
        "function": {
            "name": name,
            "strict": True,
            "parameters": {"type": "object", "properties": {}, "additionalProperties": True},
        },
    }
    for name in ("get_weather", "get_time")
]

# Where the reply openai-python's Chat stream helper builds from a stream
# differs from the one it parses from the JSON reply, on purpose, by the
# path of the member; "*" stands for any index.
CHAT_HELPER_DIFFERENCES = {
    "created": "the time each of the two requests was received, which may be a second apart",
    "service_tier": 'the JSON reply\'s "default", which no chunk carries',
    "choices.*.message.annotations": "the JSON reply's [], which no chunk carries",
    "choices.*.message.parsed": "the helper's own member",
    "choices.*.message.tool_calls.*.index": "the index of the tool call's deltas, which the helper keeps",
    "choices.*.message.tool_calls.*.function.parsed_arguments": "the helper's own member, checked on its own",
}

# The further differences of a Stub whose ids are generated: each request
# gets its own.
GENERATED_ID_DIFFERENCES = {
    "id": "generated for each request",
    "choices.*.message.tool_calls.*.id": "generated for each request",
}

# Where the Response openai-python's Responses stream helper builds from a
# stream differs from the one it parses from the JSON reply, on purpose.
RESPONSES_HELPER_DIFFERENCES = {
    "created_at": "the time each of the two requests was received, which may be a second apart",
    "completed_at": "the time each of the two requests was received, which may be a second apart",
    "output.*.id": "the msg_ and fc_ ids of the items, which no field fixes, generated for each request",
    "output.*.content.*.parsed": "the helper's own member",
    "output.*.parsed_arguments": "the helper's own member, checked on its own",
}

# The further difference of a Responses Stub whose id is generated.
RESPONSES_GENERATED_ID_DIFFERENCES = {
    "id": "generated for each request",
}

MISSING = object()


class Smock:
    """smock serving DEFINITIONS on ports it picks, until the with block
    ends. Its Admin API needs a token of its own, SMOCK_ADMIN_TOKEN, and
    no other SMOCK_ variable of the environment reaches it."""

    def __init__(self, binary):
        self.binary = binary
        self.ports = {}
        self.log = []
        self.listening = threading.Event()
        self.admin_token = secrets.token_hex(16)

    def __enter__(self):
        env = {name: value for name, value in os.environ.items() if not name.startswith("SMOCK_")}
        env["SMOCK_ADMIN_TOKEN"] = self.admin_token
        command = [
            self.binary, "serve", "--dir", str(DEFINITIONS),
            "--port", "0", "--tls-port", "0", "--admin-port", "0", "--drain-timeout-ms", "1000",
        ]
        self.process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                        stderr=subprocess.PIPE, text=True, env=env)
        self.reader = threading.Thread(target=self.read_log, daemon=True)
        self.reader.start()
        try:
            self.wait_until_ready()
        except BaseException:
            self.stop()
            raise
        return self

    def __exit__(self, *_):
        self.stop()

    def read_log(self):
        for line in self.process.stderr:
            self.log.append(line)
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if isinstance(entry, dict) and entry.get("msg") == "listening":
                self.ports[entry["listener"]] = int(entry["address"].rsplit(":", 1)[1])
                if {"plain", "admin"} <= set(self.ports):
                    self.listening.set()

    def wait_until_ready(self):
        deadline = time.monotonic() + START_TIMEOUT_S
        while not self.listening.wait(0.05):
            self.still_starting(deadline, "did not start listening")
        while not self.ready():
            self.still_starting(deadline, "did not become ready")
            time.sleep(0.05)

    def ready(self):
        try:
            with urllib.request.urlopen(f"{self.admin_url}/readyz", timeout=5) as response:
                return response.status == 200
        except OSError:
            return False

    def still_starting(self, deadline, what):
        """Raises, with smock's log, when smock has exited or the deadline
        has passed."""
        if self.process.poll() is not None or time.monotonic() > deadline:
            self.stop()
            raise RuntimeError(f"smock {what}; its log:\n{''.join(self.log)}")

    def stop(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(STOP_TIMEOUT_S)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.reader.join(5)

    @property
    def url(self):
        return f"http://127.0.0.1:{self.ports['plain']}"

    @property
    def admin_url(self):
        return f"http://127.0.0.1:{self.ports['admin']}"

    def openai(self, **options):
        """An openai-python client of this smock, with max_retries=0 unless
        the options say otherwise."""
        options = {"max_retries": 0, "timeout": CALL_TIMEOUT_S, **options}
        return openai.OpenAI(base_url=f"{self.url}/v1", api_key="test", **options)


class Checks:
    """The checks made so far, each printed as it is made."""

    def __init__(self):
        self.count = 0
        self.failed = []

    def check(self, name, passed, detail=""):
        self.count += 1
        print(f"{'ok  ' if passed else 'FAIL'}  {name}", flush=True)
        if not passed:
            self.failed.append(name)
            for line in detail.splitlines():
                print(f"      {line}", flush=True)

    def equal(self, name, actual, expected):
        self.check(name, actual == expected, f"got:      {actual!r}\nexpected: {expected!r}")

    def id(self, name, actual, expected):
        """Checks a fixed id, given as a string, or a generated one, given
        as the pattern it matches."""
        if isinstance(expected, str):
            self.equal(name, actual, expected)
        else:
            passed = isinstance(actual, str) and expected.fullmatch(actual) is not None
            self.check(name, passed, f"got {actual!r}, which does not match {expected.pattern}")

    def same(self, name, from_json, from_stream, differences):
        """Checks that two replies, dumped from the SDK's objects, are the
        same apart from the differences listed, by the paths of the
        members."""
        unlisted = [
            f"{'.'.join(path)}: {shown(left)} from the JSON reply, {shown(right)} from the stream"
            for path, left, right in differ(from_json, from_stream)
            if not any(listed(path, difference) for difference in differences)
        ]
        self.check(name, not unlisted, "\n".join(unlisted))

    def raised(self, name, error):
        """Fails a case whose SDK raised where no check expects it to."""
        detail = "".join(traceback.format_exception(error))
        self.check(f"{name}: raised {type(error).__name__} unexpectedly", False, detail)

    def raises(self, name, error_class, call, message=None):
        """Checks that a call raises error_class, as the vendor's reply
        makes it, with the given message if one is given."""
        try:
            call()
        except error_class as error:
            if message is None or str(error) == message:
                self.check(name, True)
            else:
                self.raised(name, error)
            return
        except Exception as error:
            self.raised(name, error)
            return
        self.check(name, False, f"it raised no {error_class.__name__}")


def differ(left, right, path=()):
    """The paths, as tuples of member names and indexes, where two values
    of JSON's data model differ, with the value on each side."""
    if isinstance(left, dict) and isinstance(right, dict):
        for key in [*left, *(key for key in right if key not in left)]:
            yield from differ(left.get(key, MISSING), right.get(key, MISSING), (*path, str(key)))
    elif isinstance(left, list) and isinstance(right, list) and len(left) == len(right):
        for index, (left_item, right_item) in enumerate(zip(left, right, strict=True)):
            yield from differ(left_item, right_item, (*path, str(index)))
    elif type(left) is not type(right) or left != right:
        yield path, left, right


def listed(path, difference):
    """Whether a listed difference, such as "choices.*.message.parsed",
    names the path."""
    names = difference.split(".")
    return len(names) == len(path) and all(name in ("*", step) for name, step in zip(names, path, strict=True))


def shown(value):
    return "nothing" if value is MISSING else repr(value)


def check_definitions(checks, binary):
    """Checks that DEFINITIONS passes `smock check`, with no warning."""
    result = subprocess.run([binary, "check", str(DEFINITIONS)], capture_output=True, text=True)
    output = (result.stdout + result.stderr).strip()
    checks.check("definitions: smock check passes with no warning", result.returncode == 0 and not output,
                 f"exit status {result.returncode}\n{output}")


def chat_create(client, model, **options):
    return client.chat.completions.create(model=model, messages=MESSAGES, **options)


def chat_stream(client, model, **options):
    """Reads a Chat stream as an application does with create(stream=True),
    and returns the request id from its header and its chunks."""
    with client.chat.completions.create(model=model, messages=MESSAGES, stream=True, **options) as stream:
        return stream.response.headers.get("x-request-id"), list(stream)


def chat_helper(client, model):
    """Reads a Chat stream with the stream() helper, as an application that
    gives function tools does, and returns its events and the reply it
    builds."""
    with client.chat.completions.stream(
        model=model, messages=MESSAGES, tools=CHAT_TOOLS, stream_options={"include_usage": True}
    ) as stream:
        events = [event for event in stream if event.type != "chunk"]
        return events, stream.get_final_completion()


def check_usage(checks, name, usage, prompt, completion):
    checks.equal(f"{name}: usage", None if usage is None else
                 (usage.prompt_tokens, usage.completion_tokens, usage.total_tokens),
                 (prompt, completion, prompt + completion))


def check_chunks(checks, name, chunks, reply_id, model):
    """Checks what every chunk of a Chat stream shares: the object, one id,
    one created and the model, and the opening chunk's role."""
    checks.equal(f"{name}: every chunk is a chat.completion.chunk",
                 {chunk.object for chunk in chunks}, {"chat.completion.chunk"})
    ids = {chunk.id for chunk in chunks}
    checks.equal(f"{name}: one id across the chunks", len(ids), 1)
    checks.id(f"{name}: the id", chunks[0].id, reply_id)
    checks.equal(f"{name}: one created across the chunks", len({chunk.created for chunk in chunks}), 1)
    checks.equal(f"{name}: the model of every chunk", {chunk.model for chunk in chunks}, {model})
    checks.equal(f"{name}: the opening chunk's role", chunks[0].choices[0].delta.role, "assistant")


def choice_chunks(chunks):
    """The chunks of a Chat stream that carry a choice."""
    return [chunk for chunk in chunks if chunk.choices]


def streamed_content(chunks):
    """The content of a Chat stream, joined as an application joins it."""
    return "".join(chunk.choices[0].delta.content or "" for chunk in choice_chunks(chunks))


def streamed_finish_reasons(chunks):
    return [chunk.choices[0].finish_reason for chunk in choice_chunks(chunks)]


def streamed_tool_calls(checks, name, chunks):
    """Joins the tool calls of a Chat stream by their index, as
    openai-python's accumulator does, and checks that every delta carries
    an integer index and that only the first one of a call carries its id,
    type and name. Returns each call's (id, name, arguments)."""
    calls = {}
    later = []
    deltas = [delta for chunk in choice_chunks(chunks) for delta in chunk.choices[0].delta.tool_calls or []]
    checks.check(f"{name}: every tool-call delta carries an integer index",
                 all(type(delta.index) is int for delta in deltas),
                 repr([delta.index for delta in deltas]))
    for delta in deltas:
        if delta.index not in calls:
            calls[delta.index] = [delta.id, delta.type, delta.function.name, delta.function.arguments or ""]
        else:
            later.append(delta)
            calls[delta.index][3] += delta.function.arguments or ""
    checks.check(f"{name}: the later deltas of a tool call carry no id, type or name",
                 all((delta.id, delta.type, delta.function.name) == (None, None, None) for delta in later),
                 "\n".join(repr(delta) for delta in later))
    checks.equal(f"{name}: the tool calls' indexes", list(calls), list(range(len(calls))))
    checks.equal(f"{name}: the type of every tool call", {call[1] for call in calls.values()},
                 {"function"} if calls else set())
    return [(call_id, call_name, arguments) for call_id, _, call_name, arguments in calls.values()]


def chat_text(checks, smock):
    """Chat Completions, text only, with generated ids: create() with and
    without stream, with and without include_usage."""
    client = smock.openai()
    name = "chat-text: create"
    reply = chat_create(client, "chat-text")
    message = reply.choices[0].message
    checks.equal(f"{name}: the text", message.content, CHAT_TEXT)
    checks.equal(f"{name}: no tool calls", message.tool_calls, None)
    checks.equal(f"{name}: the stop reason", reply.choices[0].finish_reason, "stop")
    check_usage(checks, name, reply.usage, 19, 10)
    checks.id(f"{name}: the id", reply.id, CHAT_ID)
    checks.equal(f"{name}: the model", reply.model, "chat-text")
    checks.id(f"{name}: the request id", reply._request_id, REQUEST_ID)

    name = "chat-text: create(stream=True)"
    request_id, chunks = chat_stream(client, "chat-text")
    check_chunks(checks, name, chunks, CHAT_ID, "chat-text")
    checks.equal(f"{name}: the opening chunk's content", chunks[0].choices[0].delta.content, "")
    checks.equal(f"{name}: the text", streamed_content(chunks), CHAT_TEXT)
    checks.check(f"{name}: a piece ends between the code points of the emoji",
                 any((chunk.choices[0].delta.content or "").endswith("👋") for chunk in chunks),
                 repr([chunk.choices[0].delta.content for chunk in chunks]))
    checks.equal(f"{name}: the stop reason, on the closing chunk only",
                 streamed_finish_reasons(chunks), [None] * (len(chunks) - 1) + ["stop"])
    checks.equal(f"{name}: no usage", [chunk.usage for chunk in chunks], [None] * len(chunks))
    checks.id(f"{name}: the request id", request_id, REQUEST_ID)

    name = "chat-text: create(stream=True) with include_usage"
    request_id, chunks = chat_stream(client, "chat-text", stream_options={"include_usage": True})
    check_chunks(checks, name, chunks, CHAT_ID, "chat-text")
    checks.equal(f"{name}: the text", streamed_content(chunks), CHAT_TEXT)
    checks.equal(f"{name}: the last chunk has no choice", chunks[-1].choices, [])
    check_usage(checks, f"{name}: the last chunk", chunks[-1].usage, 19, 10)
    checks.equal(f"{name}: no usage before the last chunk",
                 [chunk.usage for chunk in chunks[:-1]], [None] * (len(chunks) - 1))
    checks.equal(f"{name}: the stop reason", streamed_finish_reasons(chunks)[-1], "stop")
    checks.id(f"{name}: the request id", request_id, REQUEST_ID)


def chat_tools(checks, smock):
    """Chat Completions, text and two tool calls, with fixed ids: create()
    with and without stream, and the stream() helper."""
    client = smock.openai()
    name = "chat-tools: create"
    reply = chat_create(client, "chat-tools")
    message = reply.choices[0].message
    checks.equal(f"{name}: the text", message.content, CHAT_TOOLS_TEXT)
    checks.equal(f"{name}: the tool calls, their arguments parsed",
                 [(call.id, call.type, call.function.name, json.loads(call.function.arguments))
                  for call in message.tool_calls or []],
                 [(call_id, "function", call_name, arguments) for call_id, call_name, arguments in CHAT_TOOLS_CALLS])
    checks.equal(f"{name}: the stop reason", reply.choices[0].finish_reason, "tool_calls")
    check_usage(checks, name, reply.usage, 52, 31)
    checks.equal(f"{name}: the fixed id", reply.id, "chatcmpl-sdk-chat-tools")
    checks.equal(f"{name}: the fixed model", reply.model, "chat-tools-2026-10-23")
    checks.equal(f"{name}: the Stub's request id", reply._request_id, "req_sdk_chat_tools")

    name = "chat-tools: create(stream=True)"
    request_id, chunks = chat_stream(client, "chat-tools")
    check_chunks(checks, name, chunks, "chatcmpl-sdk-chat-tools", "chat-tools-2026-10-23")
    checks.equal(f"{name}: the text", streamed_content(chunks), CHAT_TOOLS_TEXT)
    calls = streamed_tool_calls(checks, name, chunks)
    checks.equal(f"{name}: the tool calls, their arguments joined and parsed",
                 [(call_id, call_name, json.loads(arguments)) for call_id, call_name, arguments in calls],
                 CHAT_TOOLS_CALLS)
    checks.equal(f"{name}: the arguments, joined as the JSON reply gives them",
                 [arguments for _, _, arguments in calls],
                 [call.function.arguments for call in message.tool_calls or []])
    checks.equal(f"{name}: the stop reason", streamed_finish_reasons(chunks)[-1], "tool_calls")
    checks.equal(f"{name}: the Stub's request id", request_id, "req_sdk_chat_tools")

    name = "chat-tools: stream()"
    events, built = chat_helper(client, "chat-tools")
    checks.equal(f"{name}: the content deltas, joined",
                 "".join(event.delta for event in events if event.type == "content.delta"), CHAT_TOOLS_TEXT)
    checks.equal(f"{name}: content.done",
                 [event.content for event in events if event.type == "content.done"], [CHAT_TOOLS_TEXT])
    checks.equal(f"{name}: the parsed arguments of each tool_calls.function.arguments.done",
                 [(event.index, event.name, event.parsed_arguments)
                  for event in events if event.type == "tool_calls.function.arguments.done"],
                 [(index, call_name, arguments) for index, (_, call_name, arguments) in enumerate(CHAT_TOOLS_CALLS)])
    checks.equal(f"{name}: the parsed arguments of the reply",
                 [call.function.parsed_arguments for call in built.choices[0].message.tool_calls or []],
                 [arguments for _, _, arguments in CHAT_TOOLS_CALLS])
    checks.check(f"{name}: created, within a second of the JSON reply's", abs(built.created - reply.created) <= 1,
                 f"{built.created} from the stream, {reply.created} from the JSON reply")
    checks.same(f"{name}: the reply equals the JSON reply, apart from the listed differences",
                reply.model_dump(), built.model_dump(), CHAT_HELPER_DIFFERENCES)


def chat_call_only(checks, smock):
    """Chat Completions, one tool call and no text, with generated ids:
    create() and the stream() helper."""
    client = smock.openai()
    call_name, arguments = CHAT_CALL_ONLY_CALL
    name = "chat-call-only: create"
    reply = chat_create(client, "chat-call-only")
    message = reply.choices[0].message
    checks.equal(f"{name}: no content", message.content, None)
    checks.equal(f"{name}: the tool call, its arguments parsed",
                 [(call.function.name, json.loads(call.function.arguments)) for call in message.tool_calls or []],
                 [(call_name, arguments)])
    calls = message.tool_calls or []
    checks.id(f"{name}: the call id", calls[0].id if calls else None, CALL_ID)
    checks.equal(f"{name}: the stop reason", reply.choices[0].finish_reason, "tool_calls")
    check_usage(checks, name, reply.usage, 40, 12)
    checks.id(f"{name}: the id", reply.id, CHAT_ID)
    checks.id(f"{name}: the request id", reply._request_id, REQUEST_ID)

    name = "chat-call-only: stream()"
    events, built = chat_helper(client, "chat-call-only")
    checks.equal(f"{name}: no content event",
                 [event.type for event in events if event.type.startswith("content.")], [])
    checks.equal(f"{name}: the parsed arguments of each tool_calls.function.arguments.done",
                 [(event.index, event.name, event.parsed_arguments)
                  for event in events if event.type == "tool_calls.function.arguments.done"],
                 [(0, call_name, arguments)])
    calls = built.choices[0].message.tool_calls or []
    checks.id(f"{name}: the call id", calls[0].id if calls else None, CALL_ID)
    checks.id(f"{name}: the id", built.id, CHAT_ID)
    checks.same(f"{name}: the reply equals the JSON reply, apart from the listed differences",
                reply.model_dump(), built.model_dump(), {**CHAT_HELPER_DIFFERENCES, **GENERATED_ID_DIFFERENCES})


def chat_length(checks, smock):
    """Chat Completions, a reply with the written stop reason length:
    create() with and without stream, and the stream() helper, which raises
    on it as it does on the vendor's."""
    client = smock.openai()
    name = "chat-length: create"
    reply = chat_create(client, "chat-length")
    checks.equal(f"{name}: the text", reply.choices[0].message.content, CHAT_LENGTH_TEXT)
    checks.equal(f"{name}: the stop reason", reply.choices[0].finish_reason, "length")
    check_usage(checks, name, reply.usage, 31, 5)

    name = "chat-length: create(stream=True)"
    _, chunks = chat_stream(client, "chat-length")
    checks.equal(f"{name}: the text", streamed_content(chunks), CHAT_LENGTH_TEXT)
    checks.equal(f"{name}: the stop reason", streamed_finish_reasons(chunks)[-1], "length")

    checks.raises("chat-length: stream(): raises LengthFinishReasonError",
                  openai.LengthFinishReasonError, lambda: chat_helper(client, "chat-length"))


def responses_create(client, model, **options):
    return client.responses.create(model=model, input=MESSAGES, **options)


def responses_stream(client, model, **options):
    """Reads a Responses stream as an application does with
    create(stream=True), and returns the request id from its header and its
    events."""
    with client.responses.create(model=model, input=MESSAGES, stream=True, **options) as stream:
        return stream.response.headers.get("x-request-id"), list(stream)


def responses_helper(client, model, **options):
    """Reads a Responses stream with the stream() helper, as an application
    does, and returns its events and the Response it builds."""
    with client.responses.stream(model=model, input=MESSAGES, **options) as stream:
        events = list(stream)
        return events, stream.get_final_response()


def check_times(checks, name, built, reply):
    """Checks that a Response built from a stream has the JSON reply's
    times, within a second, as two requests may be received a second
    apart."""
    for member in ("created_at", "completed_at"):
        from_stream, from_json = getattr(built, member), getattr(reply, member)
        checks.check(f"{name}: {member}, within a second of the JSON reply's",
                     from_stream is not None and from_json is not None and abs(from_stream - from_json) <= 1,
                     f"{from_stream} from the stream, {from_json} from the JSON reply")


def check_responses_usage(checks, name, usage, input_tokens, output_tokens):
    checks.equal(f"{name}: usage", None if usage is None else
                 (usage.input_tokens, usage.output_tokens, usage.total_tokens),
                 (input_tokens, output_tokens, input_tokens + output_tokens))


# The events of a Responses stream that carry the whole Response object.
LIFECYCLE_EVENTS = {"response.created", "response.in_progress", "response.completed", "response.incomplete"}


def check_events(checks, name, events, reply_id, model, closing):
    """Checks what every event of a Responses stream shares: sequence
    numbers from 0 without a gap, the Response object's id and model, the
    opening events, and the closing event, which is the last one and the
    only one with usage. Returns the closing event's Response."""
    checks.equal(f"{name}: the sequence numbers", [event.sequence_number for event in events],
                 list(range(len(events))))
    checks.equal(f"{name}: the opening events", [event.type for event in events[:2]],
                 ["response.created", "response.in_progress"])
    checks.equal(f"{name}: the closing event, last", [event.type for event in events[-1:]], [closing])
    lifecycle = [event.response for event in events if event.type in LIFECYCLE_EVENTS]
    checks.equal(f"{name}: one id across the events", len({response.id for response in lifecycle}), 1)
    checks.id(f"{name}: the id", lifecycle[0].id if lifecycle else None, reply_id)
    checks.equal(f"{name}: the model of every event", {response.model for response in lifecycle}, {model})
    checks.equal(f"{name}: usage on the closing event only", [response.usage is None for response in lifecycle],
                 [True] * (len(lifecycle) - 1) + [False])
    return events[-1].response if events and events[-1].type == closing else None


def items_of(events):
    """The output items of a Responses stream, by their output index: each
    item's added and done events, and the events between them that carry
    its item id."""
    items = {}
    for event in events:
        if event.type == "response.output_item.added":
            items[event.output_index] = {"added": event.item, "done": None, "events": []}
        elif event.type == "response.output_item.done":
            items.setdefault(event.output_index, {"added": None, "done": None, "events": []})["done"] = event.item
        elif hasattr(event, "item_id"):
            items.setdefault(event.output_index, {"added": None, "done": None, "events": []})["events"].append(event)
    return [items[index] for index in sorted(items)]


def check_items(checks, name, events):
    """Checks that every output item of a Responses stream is opened before
    its content and done with the ids of its added event, and that its
    content events carry its id. Returns the items."""
    items = items_of(events)
    checks.equal(f"{name}: the output indexes", [event.output_index for event in events
                                                 if event.type == "response.output_item.added"],
                 list(range(len(items))))
    checks.check(f"{name}: each item is added, then done with the ids of its added event",
                 all(item["added"] is not None and item["done"] is not None
                     and (item["added"].id, getattr(item["added"], "call_id", None))
                     == (item["done"].id, getattr(item["done"], "call_id", None)) for item in items),
                 "\n".join(repr((item["added"], item["done"])) for item in items))
    checks.check(f"{name}: the events of an item carry its id",
                 all(event.item_id == item["added"].id for item in items for event in item["events"]),
                 "\n".join(f"{event.type}: {event.item_id}" for item in items for event in item["events"]))
    return items


def streamed_text(events):
    """The text of a Responses stream, joined from its deltas as an
    application joins it."""
    return "".join(event.delta for event in events if event.type == "response.output_text.delta")


def function_calls(output):
    """The function call items of a Response's output."""
    return [item for item in output if item.type == "function_call"]


def check_function_calls(checks, name, output, expected):
    """Checks the function call items of a Response: each one's call id,
    name and arguments, parsed, its fc_ id, distinct from the others', and
    its status. Returns the items."""
    calls = function_calls(output)
    checks.equal(f"{name}: the function calls, their arguments parsed",
                 [(call.call_id, call.name, json.loads(call.arguments)) for call in calls], expected)
    checks.check(f"{name}: each function call item has an fc_ id of its own",
                 all(FUNCTION_CALL_ID.fullmatch(call.id or "") for call in calls)
                 and len({call.id for call in calls}) == len(calls),
                 repr([call.id for call in calls]))
    checks.equal(f"{name}: each function call item is completed", [call.status for call in calls],
                 ["completed"] * len(calls))
    return calls


def check_streamed_calls(checks, name, items, expected):
    """Checks the function call items of a Responses stream: the added
    item, with empty arguments, then argument deltas that join to the done
    event's arguments and the done item's, which parse to the expected
    ones. Returns each call's joined arguments."""
    calls = [item for item in items if item["added"].type == "function_call"]
    checks.equal(f"{name}: each function call item is added in progress, with empty arguments",
                 [(item["added"].status, item["added"].arguments) for item in calls],
                 [("in_progress", "")] * len(calls))
    joined = ["".join(event.delta for event in item["events"]
                      if event.type == "response.function_call_arguments.delta") for item in calls]
    checks.equal(f"{name}: the argument deltas join to the done event's arguments", joined,
                 [next((event.arguments for event in item["events"]
                        if event.type == "response.function_call_arguments.done"), None) for item in calls])
    checks.equal(f"{name}: the argument deltas join to the done item's arguments", joined,
                 [item["done"].arguments for item in calls])
    checks.equal(f"{name}: the function calls, their arguments joined and parsed",
                 [(item["done"].call_id, item["done"].name, json.loads(arguments))
                  for item, arguments in zip(calls, joined, strict=True)], expected)
    return joined


def responses_text(checks, smock):
    """Responses, text only, with generated ids: create() with and without
    stream, and the stream() helper."""
    client = smock.openai()
    name = "responses-text: create"
    reply = responses_create(client, "responses-text")
    checks.equal(f"{name}: the object", reply.object, "response")
    checks.equal(f"{name}: the status", (reply.status, reply.incomplete_details), ("completed", None))
    checks.equal(f"{name}: the text, as output_text joins it", reply.output_text, RESPONSES_TEXT)
    checks.equal(f"{name}: one message item, completed",
                 [(item.type, item.role, item.status, [part.type for part in item.content])
                  for item in reply.output],
                 [("message", "assistant", "completed", ["output_text"])])
    check_responses_usage(checks, name, reply.usage, 37, 11)
    checks.id(f"{name}: the id", reply.id, RESPONSE_ID)
    checks.id(f"{name}: the message item's id", reply.output[0].id if reply.output else None, MESSAGE_ID)
    checks.equal(f"{name}: the model", reply.model, "responses-text")
    checks.id(f"{name}: the request id", reply._request_id, REQUEST_ID)

    name = "responses-text: create(stream=True)"
    request_id, events = responses_stream(client, "responses-text")
    closed = check_events(checks, name, events, RESPONSE_ID, "responses-text", "response.completed")
    items = check_items(checks, name, events)
    checks.equal(f"{name}: the items", [(item["added"].type, item["done"].status) for item in items],
                 [("message", "completed")])
    checks.id(f"{name}: the message item's id", items[0]["added"].id if items else None, MESSAGE_ID)
    checks.equal(f"{name}: the text", streamed_text(events), RESPONSES_TEXT)
    checks.check(f"{name}: a piece ends between the code points of the emoji",
                 any(event.delta.endswith("👋") for event in events if event.type == "response.output_text.delta"),
                 repr([event.delta for event in events if event.type == "response.output_text.delta"]))
    checks.equal(f"{name}: response.output_text.done",
                 [event.text for event in events if event.type == "response.output_text.done"], [RESPONSES_TEXT])
    checks.equal(f"{name}: the closing event's text", closed and closed.output_text, RESPONSES_TEXT)
    checks.equal(f"{name}: the closing event's status", closed and closed.status, "completed")
    check_responses_usage(checks, f"{name}: the closing event", closed and closed.usage, 37, 11)
    checks.id(f"{name}: the request id", request_id, REQUEST_ID)

    name = "responses-text: stream()"
    events, built = responses_helper(client, "responses-text")
    checks.equal(f"{name}: the text deltas, joined",
                 "".join(event.delta for event in events if event.type == "response.output_text.delta"),
                 RESPONSES_TEXT)
    checks.equal(f"{name}: the last delta's snapshot",
                 [event.snapshot for event in events if event.type == "response.output_text.delta"][-1:],
                 [RESPONSES_TEXT])
    checks.equal(f"{name}: the text of the Response", built.output_text, RESPONSES_TEXT)
    checks.id(f"{name}: the id", built.id, RESPONSE_ID)
    checks.id(f"{name}: the message item's id", built.output[0].id if built.output else None, MESSAGE_ID)
    check_times(checks, name, built, reply)
    checks.same(f"{name}: the Response equals the JSON reply, apart from the listed differences",
                reply.model_dump(), built.model_dump(),
                {**RESPONSES_HELPER_DIFFERENCES, **RESPONSES_GENERATED_ID_DIFFERENCES})


def responses_tools(checks, smock):
    """Responses, text and two tool calls, with the id, the model, the call
    ids and the request id fixed: create() with and without stream, and
    the stream() helper with function tools."""
    client = smock.openai()
    model = "responses-tools-2026-10-23"
    tool_names = [tool["name"] for tool in RESPONSES_TOOLS]
    name = "responses-tools: create"
    reply = responses_create(client, "responses-tools", tools=RESPONSES_TOOLS)
    checks.equal(f"{name}: the status", (reply.status, reply.incomplete_details), ("completed", None))
    checks.equal(f"{name}: the text, as output_text joins it", reply.output_text, RESPONSES_TOOLS_TEXT)
    checks.equal(f"{name}: the message item, then the function call items",
                 [item.type for item in reply.output], ["message", "function_call", "function_call"])
    calls = check_function_calls(checks, name, reply.output, RESPONSES_TOOLS_CALLS)
    check_responses_usage(checks, name, reply.usage, 64, 29)
    checks.equal(f"{name}: the fixed id", reply.id, "resp_sdk_responses_tools")
    checks.equal(f"{name}: the fixed model", reply.model, model)
    checks.equal(f"{name}: the tools, given back", [tool.name for tool in reply.tools], tool_names)
    checks.equal(f"{name}: the Stub's request id", reply._request_id, "req_sdk_responses_tools")

    name = "responses-tools: create(stream=True)"
    request_id, events = responses_stream(client, "responses-tools", tools=RESPONSES_TOOLS)
    closed = check_events(checks, name, events, "resp_sdk_responses_tools", model, "response.completed")
    items = check_items(checks, name, events)
    checks.equal(f"{name}: the items", [(item["added"].type, item["done"].status) for item in items],
                 [("message", "completed"), ("function_call", "completed"), ("function_call", "completed")])
    checks.equal(f"{name}: the text", streamed_text(events), RESPONSES_TOOLS_TEXT)
    joined = check_streamed_calls(checks, name, items, RESPONSES_TOOLS_CALLS)
    checks.equal(f"{name}: the arguments, joined as the JSON reply gives them", joined,
                 [call.arguments for call in calls])
    checks.equal(f"{name}: the closing event's items", closed and [item.type for item in closed.output],
                 ["message", "function_call", "function_call"])
    checks.equal(f"{name}: the Stub's request id", request_id, "req_sdk_responses_tools")

    name = "responses-tools: stream()"
    events, built = responses_helper(client, "responses-tools", tools=RESPONSES_TOOLS)
    checks.equal(f"{name}: the text deltas, joined",
                 "".join(event.delta for event in events if event.type == "response.output_text.delta"),
                 RESPONSES_TOOLS_TEXT)
    snapshots = {}
    for event in events:
        if event.type == "response.function_call_arguments.delta":
            snapshots[event.output_index] = event.snapshot
    checks.equal(f"{name}: the last argument delta's snapshot of each call", list(snapshots.values()),
                 [call.arguments for call in calls])
    checks.equal(f"{name}: the parsed arguments of the Response",
                 [call.parsed_arguments for call in function_calls(built.output)],
                 [arguments for _, _, arguments in RESPONSES_TOOLS_CALLS])
    check_times(checks, name, built, reply)
    checks.same(f"{name}: the Response equals the JSON reply, apart from the listed differences",
                reply.model_dump(), built.model_dump(), RESPONSES_HELPER_DIFFERENCES)


def responses_incomplete(checks, smock):
    """Responses, a reply cut at the token limit, with the written stop
    reason max_output_tokens: create() with and without stream, and the
    stream() helper, whose get_final_response() raises on it as it does on
    the vendor's."""
    client = smock.openai()
    name = "responses-incomplete: create"
    reply = responses_create(client, "responses-incomplete")
    checks.equal(f"{name}: the status", reply.status, "incomplete")
    checks.equal(f"{name}: the incomplete reason", reply.incomplete_details and reply.incomplete_details.reason,
                 "max_output_tokens")
    checks.equal(f"{name}: no completed_at", reply.completed_at, None)
    checks.equal(f"{name}: the text, as output_text joins it", reply.output_text, RESPONSES_INCOMPLETE_TEXT)
    checks.equal(f"{name}: the message item, incomplete", [(item.type, item.status) for item in reply.output],
                 [("message", "incomplete")])
    check_responses_usage(checks, name, reply.usage, 31, 5)

    name = "responses-incomplete: create(stream=True)"
    _, events = responses_stream(client, "responses-incomplete")
    closed = check_events(checks, name, events, RESPONSE_ID, "responses-incomplete", "response.incomplete")
    checks.equal(f"{name}: the text", streamed_text(events), RESPONSES_INCOMPLETE_TEXT)
    checks.equal(f"{name}: the closing event's status and incomplete reason",
                 closed and (closed.status, closed.incomplete_details and closed.incomplete_details.reason),
                 ("incomplete", "max_output_tokens"))
    checks.equal(f"{name}: the closing event's message item, incomplete",
                 closed and [(item.type, item.status) for item in closed.output], [("message", "incomplete")])

    name = "responses-incomplete: stream()"
    with client.responses.stream(model="responses-incomplete", input=MESSAGES) as stream:
        events = list(stream)
        checks.equal(f"{name}: the last event", [event.type for event in events[-1:]], ["response.incomplete"])
        closed = events[-1].response if events else None
        checks.equal(f"{name}: the incomplete reason the last event carries",
                     closed and closed.incomplete_details and closed.incomplete_details.reason,
                     "max_output_tokens")
        checks.equal(f"{name}: the text of the Response the last event carries", closed and closed.output_text,
                     RESPONSES_INCOMPLETE_TEXT)
        checks.raises(f"{name}: get_final_response() raises RuntimeError", RuntimeError, stream.get_final_response,
                      message="Didn't receive a `response.completed` event.")


# The cases, in the order they run. Each calls the Stubs it names, and a
# case whose SDK raises unexpectedly fails without stopping the others.
CASES = [chat_text, chat_tools, chat_call_only, chat_length, responses_text, responses_tools, responses_incomplete]


def main():
    if len(sys.argv) != 2:
        print("usage: python llm-sdks/check.py <smock binary>", file=sys.stderr)
        return 2
    binary = sys.argv[1]
    version = subprocess.run([binary, "--version"], capture_output=True, text=True).stdout.strip()
    print(f"{version}; openai-python {openai.__version__}; Python {sys.version.split()[0]}", flush=True)
    checks = Checks()
    check_definitions(checks, binary)
    with Smock(binary) as smock:
        for case in CASES:
            try:
                case(checks, smock)
            except Exception as error:
                checks.raised(case.__name__.replace("_", "-"), error)
    if checks.failed:
        print(f"\n{len(checks.failed)} of {checks.count} checks failed. smock's log:\n{''.join(smock.log)}")
        return 1
    print(f"\nAll {checks.count} checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
