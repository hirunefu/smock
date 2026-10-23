"""The SDK job: reads smock's LLM responses with the official SDKs.

It checks llm-sdks/definitions/ with `smock check`, serves it with the given
smock binary, and calls each Stub through openai-python or
anthropic-sdk-python as applications call the API. Then it checks what the
SDK reads: the text, the tool calls and their parsed arguments, usage, stop
reasons, ids and the request id, and that the reply the SDK's stream helper
builds from a stream equals the one it parses from the JSON reply, apart
from differences listed by name.

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

import anthropic
import openai

DEFINITIONS = Path(__file__).resolve().parent / "definitions"

# How long smock may take to become ready, and to exit after SIGTERM, and
# how long one call may take.
START_TIMEOUT_S = 30
STOP_TIMEOUT_S = 10
CALL_TIMEOUT_S = 30

# The conversation every call sends, and the max_tokens that the Messages
# API requires. The Stubs do not read them.
MESSAGES = [{"role": "user", "content": "Hello!"}]
MAX_TOKENS = 1024

# Generated ids: the vendor's prefix and 24 characters from A-Z, a-z and
# 0-9.
CHAT_ID = re.compile(r"chatcmpl-[A-Za-z0-9]{24}")
CALL_ID = re.compile(r"call_[A-Za-z0-9]{24}")
REQUEST_ID = re.compile(r"req_[A-Za-z0-9]{24}")
MESSAGE_ID = re.compile(r"msg_[A-Za-z0-9]{24}")
TOOL_USE_ID = re.compile(r"toolu_[A-Za-z0-9]{24}")

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
MESSAGES_TEXT = "Hi! こんにちは。 👋🏽 How can I help?"
MESSAGES_TOOLS_TEXT = "Let me check both."
MESSAGES_TOOLS_CALLS = [
    ("toolu_sdk_weather", "get_weather", {"city": "東京", "days": 3, "units": {"temperature": "celsius"}}),
    ("toolu_sdk_time", "get_time", {"timezone": "Asia/Tokyo"}),
]
MESSAGES_CALL_ONLY_CALL = ("get_weather", {"city": "Paris"})

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

# The tools an application gives the Messages API. The Stubs do not read
# them, and anthropic-sdk-python parses a tool_use block's input without
# them.
MESSAGES_TOOLS = [
    {"name": name, "input_schema": {"type": "object", "properties": {}, "additionalProperties": True}}
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

# Where the message anthropic-sdk-python's Messages stream helper builds
# from a stream differs from the one it parses from the JSON reply, on
# purpose. Nothing does: the helper takes every member from the events,
# stop_details included.
MESSAGES_HELPER_DIFFERENCES = {}

# The differences of a Messages Stub whose ids are generated: each request
# gets its own.
MESSAGES_GENERATED_ID_DIFFERENCES = {
    "id": "generated for each request",
    "content.*.id": "generated for each request",
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

    def anthropic(self, **options):
        """An anthropic-sdk-python client of this smock, with max_retries=0
        unless the options say otherwise. Its base URL has no /v1, which
        the SDK adds."""
        options = {"max_retries": 0, "timeout": CALL_TIMEOUT_S, **options}
        return anthropic.Anthropic(base_url=self.url, api_key="test", **options)


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

    def raises(self, name, error_class, call):
        """Checks that a call raises error_class, as the vendor's reply
        makes it."""
        try:
            call()
        except error_class:
            self.check(name, True)
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


def messages_create(client, model, **options):
    return client.messages.create(model=model, max_tokens=MAX_TOKENS, messages=MESSAGES, **options)


def messages_stream(client, model, **options):
    """Reads a Messages stream as an application does with
    create(stream=True), and returns the request id from its header and its
    events."""
    with messages_create(client, model, stream=True, **options) as stream:
        return stream.response.headers.get("request-id"), list(stream)


def messages_helper(client, model, **options):
    """Reads a Messages stream with the stream() helper, as an application
    does, and returns the request id it reads from request-id, its events
    and the message it builds."""
    with client.messages.stream(model=model, max_tokens=MAX_TOKENS, messages=MESSAGES, **options) as stream:
        events = list(stream)
        return stream.request_id, events, stream.get_final_message()


def check_messages_usage(checks, name, usage, input_tokens, output_tokens):
    checks.equal(f"{name}: usage", None if usage is None else (usage.input_tokens, usage.output_tokens),
                 (input_tokens, output_tokens))


def blocks(message):
    """The content blocks of a message, each as its type and what it
    carries: the text, or the id, name and input of a tool use."""
    return [(block.type, block.text) if block.type == "text" else (block.type, block.id, block.name, block.input)
            for block in message.content]


def check_message_events(checks, name, events, reply_id, model, input_tokens, block_count):
    """Checks the frame of a Messages stream: message_start first, with the
    message's id and model, no content, no stop reason and the input
    tokens; message_delta and message_stop last; and between them each
    block in turn, at indexes from 0, opened, given its deltas and stopped.
    Returns the message_delta event."""
    types = [event.type for event in events]
    checks.equal(f"{name}: message_start first, message_delta and message_stop last",
                 (types[:1], types[-2:]), (["message_start"], ["message_delta", "message_stop"]))
    message = events[0].message
    checks.id(f"{name}: the id", message.id, reply_id)
    checks.equal(f"{name}: message_start's message",
                 (message.type, message.role, message.model, message.content, message.stop_reason,
                  message.stop_sequence, message.usage.input_tokens, message.usage.output_tokens),
                 ("message", "assistant", model, [], None, None, input_tokens, 0))
    within = [event for event in events if event.type.startswith("content_block_")]
    checks.check(f"{name}: every content_block event carries an integer index",
                 all(type(event.index) is int for event in within), repr([event.index for event in within]))
    checks.equal(f"{name}: each block opened, given its deltas and stopped, in turn",
                 block_outline(events[1:-2]),
                 [f"{step} {index}" for index in range(block_count)
                  for step in ("content_block_start", "content_block_delta", "content_block_stop")])
    return events[-2]


def block_outline(events):
    """The events of a Messages stream, each content_block event with its
    index, and each run of deltas of one block shown once."""
    outline = []
    for event in events:
        step = f"{event.type} {event.index}" if event.type.startswith("content_block_") else event.type
        if not (outline and outline[-1] == step and event.type == "content_block_delta"):
            outline.append(step)
    return outline


def text_deltas(events):
    """The text of each text delta of a Messages stream."""
    return [event.delta.text for event in events
            if event.type == "content_block_delta" and event.delta.type == "text_delta"]


def streamed_blocks(events):
    """The blocks of a Messages stream, each built from its events as
    anthropic-sdk-python's accumulator builds it: a text block as its type
    and text, a tool_use block as its type, id, name and partial_json,
    joined as text."""
    built = {}
    for event in events:
        if event.type == "content_block_start":
            block = event.content_block
            built[event.index] = [block.type, block.text] if block.type == "text" else [block.type, block.id,
                                                                                        block.name, ""]
        elif event.type == "content_block_delta":
            built[event.index][-1] += event.delta.text if event.delta.type == "text_delta" else event.delta.partial_json
    return [tuple(block) for block in built.values()]


def tool_use_starts(events):
    """Each tool_use block of a Messages stream as it opens, and the
    partial_json of its first delta."""
    starts = {event.index: [event.content_block.to_dict()] for event in events
              if event.type == "content_block_start" and event.content_block.type == "tool_use"}
    for event in events:
        if event.type == "content_block_delta" and len(starts.get(event.index, ())) == 1:
            starts[event.index].append(event.delta.partial_json)
    return [tuple(start) for start in starts.values()]


def messages_text(checks, smock):
    """Anthropic Messages, text only, with generated ids: create() with and
    without stream, and the stream() helper."""
    client = smock.anthropic()
    name = "messages-text: create"
    reply = messages_create(client, "messages-text")
    checks.equal(f"{name}: a message from the assistant", (reply.type, reply.role), ("message", "assistant"))
    checks.equal(f"{name}: one text block", blocks(reply), [("text", MESSAGES_TEXT)])
    checks.equal(f"{name}: the stop reason", (reply.stop_reason, reply.stop_sequence, reply.stop_details),
                 ("end_turn", None, None))
    check_messages_usage(checks, name, reply.usage, 23, 10)
    checks.id(f"{name}: the id", reply.id, MESSAGE_ID)
    checks.equal(f"{name}: the model", reply.model, "messages-text")
    checks.id(f"{name}: the request id", reply._request_id, REQUEST_ID)

    name = "messages-text: create(stream=True)"
    request_id, events = messages_stream(client, "messages-text")
    delta = check_message_events(checks, name, events, MESSAGE_ID, "messages-text", 23, 1)
    checks.equal(f"{name}: the text block opens empty",
                 [event.content_block.to_dict() for event in events if event.type == "content_block_start"],
                 [{"type": "text", "text": ""}])
    pieces = text_deltas(events)
    checks.equal(f"{name}: the text", "".join(pieces), MESSAGES_TEXT)
    checks.check(f"{name}: a piece ends between the code points of the emoji",
                 any(piece.endswith("👋") for piece in pieces), repr(pieces))
    checks.equal(f"{name}: message_delta's stop reason and output tokens",
                 (delta.delta.stop_reason, delta.delta.stop_sequence, delta.delta.stop_details,
                  delta.usage.output_tokens), ("end_turn", None, None, 10))
    checks.id(f"{name}: the request id", request_id, REQUEST_ID)

    name = "messages-text: stream()"
    request_id, events, built = messages_helper(client, "messages-text")
    checks.equal(f"{name}: the text events, joined",
                 "".join(event.text for event in events if event.type == "text"), MESSAGES_TEXT)
    checks.id(f"{name}: the id", built.id, MESSAGE_ID)
    checks.id(f"{name}: the request id", request_id, REQUEST_ID)
    checks.same(f"{name}: get_final_message() equals the JSON reply, apart from the listed differences",
                reply.model_dump(), built.model_dump(),
                {**MESSAGES_HELPER_DIFFERENCES, **MESSAGES_GENERATED_ID_DIFFERENCES})


def messages_tools(checks, smock):
    """Anthropic Messages, text and two tool calls, with fixed ids: create()
    with and without stream, and the stream() helper."""
    client = smock.anthropic()
    expected = [("text", MESSAGES_TOOLS_TEXT),
                *(("tool_use", call_id, call_name, arguments) for call_id, call_name, arguments in MESSAGES_TOOLS_CALLS)]
    name = "messages-tools: create"
    reply = messages_create(client, "messages-tools", tools=MESSAGES_TOOLS)
    checks.equal(f"{name}: the text block, then a tool_use block per call with its input", blocks(reply), expected)
    checks.equal(f"{name}: the stop reason", (reply.stop_reason, reply.stop_sequence, reply.stop_details),
                 ("tool_use", None, None))
    check_messages_usage(checks, name, reply.usage, 412, 87)
    checks.equal(f"{name}: the fixed id", reply.id, "msg_sdk_messages_tools")
    checks.equal(f"{name}: the fixed model", reply.model, "messages-tools-2026-10-23")
    checks.equal(f"{name}: the Stub's request id", reply._request_id, "req_sdk_messages_tools")

    name = "messages-tools: create(stream=True)"
    request_id, events = messages_stream(client, "messages-tools", tools=MESSAGES_TOOLS)
    delta = check_message_events(checks, name, events, "msg_sdk_messages_tools", "messages-tools-2026-10-23", 412, 3)
    checks.equal(f"{name}: each tool_use block opens with an empty input, then an empty partial_json",
                 tool_use_starts(events),
                 [({"type": "tool_use", "id": call_id, "name": call_name, "input": {}}, "")
                  for call_id, call_name, _ in MESSAGES_TOOLS_CALLS])
    checks.equal(f"{name}: the blocks, each tool_use block's partial_json joined and parsed",
                 [block if block[0] == "text" else (*block[:3], json.loads(block[3]))
                  for block in streamed_blocks(events)], expected)
    checks.equal(f"{name}: message_delta's stop reason and output tokens",
                 (delta.delta.stop_reason, delta.delta.stop_sequence, delta.usage.output_tokens), ("tool_use", None, 87))
    checks.equal(f"{name}: the Stub's request id", request_id, "req_sdk_messages_tools")

    name = "messages-tools: stream()"
    request_id, events, built = messages_helper(client, "messages-tools", tools=MESSAGES_TOOLS)
    checks.equal(f"{name}: the input of each tool_use block as it stops",
                 [(event.index, event.content_block.input) for event in events
                  if event.type == "content_block_stop" and event.content_block.type == "tool_use"],
                 [(index, arguments) for index, (_, _, arguments) in enumerate(MESSAGES_TOOLS_CALLS, start=1)])
    checks.equal(f"{name}: the Stub's request id", request_id, "req_sdk_messages_tools")
    checks.same(f"{name}: get_final_message() equals the JSON reply, apart from the listed differences",
                reply.model_dump(), built.model_dump(), MESSAGES_HELPER_DIFFERENCES)


def messages_call_only(checks, smock):
    """Anthropic Messages, one tool call and no text, with generated ids:
    create() and the stream() helper."""
    client = smock.anthropic()
    call_name, arguments = MESSAGES_CALL_ONLY_CALL
    name = "messages-call-only: create"
    reply = messages_create(client, "messages-call-only", tools=MESSAGES_TOOLS)
    checks.equal(f"{name}: one tool_use block, with its input",
                 [(block.type, block.name, block.input) for block in reply.content],
                 [("tool_use", call_name, arguments)])
    checks.id(f"{name}: the tool_use id", reply.content[0].id if reply.content else None, TOOL_USE_ID)
    checks.equal(f"{name}: the stop reason", reply.stop_reason, "tool_use")
    check_messages_usage(checks, name, reply.usage, 40, 12)
    checks.id(f"{name}: the id", reply.id, MESSAGE_ID)
    checks.id(f"{name}: the request id", reply._request_id, REQUEST_ID)

    name = "messages-call-only: stream()"
    request_id, events, built = messages_helper(client, "messages-call-only", tools=MESSAGES_TOOLS)
    checks.equal(f"{name}: the input of the tool_use block as it stops, at index 0",
                 [(event.index, event.content_block.input) for event in events if event.type == "content_block_stop"],
                 [(0, arguments)])
    checks.id(f"{name}: the tool_use id", built.content[0].id if built.content else None, TOOL_USE_ID)
    checks.id(f"{name}: the request id", request_id, REQUEST_ID)
    checks.same(f"{name}: get_final_message() equals the JSON reply, apart from the listed differences",
                reply.model_dump(), built.model_dump(),
                {**MESSAGES_HELPER_DIFFERENCES, **MESSAGES_GENERATED_ID_DIFFERENCES})


# The cases, in the order they run. Each calls the Stubs it names, and a
# case whose SDK raises unexpectedly fails without stopping the others.
CASES = [chat_text, chat_tools, chat_call_only, chat_length, messages_text, messages_tools, messages_call_only]


def main():
    if len(sys.argv) != 2:
        print("usage: python llm-sdks/check.py <smock binary>", file=sys.stderr)
        return 2
    binary = sys.argv[1]
    version = subprocess.run([binary, "--version"], capture_output=True, text=True).stdout.strip()
    print(f"{version}; openai-python {openai.__version__}; anthropic-sdk-python {anthropic.__version__}; "
          f"Python {sys.version.split()[0]}", flush=True)
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
