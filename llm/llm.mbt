// LLM responses: a reply declared by its content, written in one LLM API's
// wire form. The package does no I/O and draws no wait: the definitions
// read and check a declaration with its vocabularies, and the engine hands
// it the declaration's strings, the request, the time and the ids
// generator for each request.

///|
/// The LLM API whose wire form a reply takes, as `api` names it. It is
/// never inferred from the request's path.
pub(all) enum Api {
  /// OpenAI Chat Completions: `openai-chat`.
  OpenaiChat
  /// OpenAI Responses: `openai-responses`.
  OpenaiResponses
  /// Anthropic Messages: `anthropic-messages`.
  AnthropicMessages
} derive(Debug, Eq)

///|
/// The API's name, as `api` gives it.
pub fn Api::name(self : Api) -> String {
  match self {
    OpenaiChat => "openai-chat"
    OpenaiResponses => "openai-responses"
    AnthropicMessages => "anthropic-messages"
  }
}

///|
/// The load check of `api`: the API that `value` names, or the message of
/// the load error when it names none, which lists the names it can take.
pub fn read_api(value : Json) -> Result[Api, String] {
  match value {
    String("openai-chat") => Ok(OpenaiChat)
    String("openai-responses") => Ok(OpenaiResponses)
    String("anthropic-messages") => Ok(AnthropicMessages)
    _ =>
      Err(
        "must be \"openai-chat\", \"openai-responses\" or \"anthropic-messages\"",
      )
  }
}

///|
/// A stop reason as `stopReason` writes it: a word of the Stub's API,
/// checked when the definitions are loaded or the Stub is added. Only
/// `read_stop_reason` makes one.
pub struct StopReason {
  /// The word, as the API writes it.
  word : String
} derive(Debug, Eq)

///|
/// The stop reasons of `api`, in the order its reference lists them. Any of
/// them may be written, whatever the reply's content.
fn stop_reasons(api : Api) -> ReadOnlyArray[String] {
  match api {
    // `function_call` is deprecated, and still a word of the API.
    OpenaiChat =>
      ["stop", "length", "tool_calls", "content_filter", "function_call"]
    // Responses has no stop word: its words are the incomplete reasons,
    // and a reply that gives one is incomplete.
    OpenaiResponses =>
      ["max_output_tokens", "max_messages", "content_filter", "steered"]
    AnthropicMessages =>
      [
        "end_turn", "max_tokens", "stop_sequence", "tool_use", "pause_turn", "refusal",
        "model_context_window_exceeded",
      ]
  }
}

///|
/// The load check of `stopReason` on a Stub of `api`: the stop reason that
/// `value` writes, or the message of the load error when it is not a word
/// of the API, which names the API and lists its words.
pub fn read_stop_reason(api : Api, value : Json) -> Result[StopReason, String] {
  let words = stop_reasons(api)
  if value is String(word) && words.contains(word) {
    return Ok({ word, })
  }
  Err("must be a stop reason of \{api.name()}: \{listed(words)}")
}

///|
/// `words` as a load error lists them: each one quoted, separated by
/// commas, the last one after "or".
fn listed(words : ReadOnlyArray[String]) -> String {
  let out = StringBuilder()
  for i, word in words {
    if i > 0 {
      out.write_string(if i == words.length() - 1 { " or " } else { ", " })
    }
    out.write_string("\"\{word}\"")
  }
  out.to_string()
}

///|
/// The member of a mid-stream error that gives the vendor's kind of error:
/// `type`, or `code` for `openai-responses`, whose error event names it so.
pub fn error_kind_member(api : Api) -> String {
  match api {
    OpenaiChat | AnthropicMessages => "type"
    OpenaiResponses => "code"
  }
}

///|
/// Anthropic's documented error types, in the order its reference lists
/// them.
let anthropic_error_types : ReadOnlyArray[String] = [
  "invalid_request_error", "authentication_error", "billing_error", "permission_error",
  "not_found_error", "conflict_error", "request_too_large", "rate_limit_error", "api_error",
  "timeout_error", "overloaded_error",
]

///|
/// The load check of a mid-stream error's `type`, or `code` for
/// `openai-responses`, on a Stub of `api`: the kind that `value` writes, or
/// the message of the load error. An OpenAI type or code is any non-empty
/// string; an `anthropic-messages` type is one of Anthropic's documented
/// error types, which the message lists.
pub fn read_error_kind(api : Api, value : Json) -> Result[String, String] {
  match api {
    OpenaiChat | OpenaiResponses =>
      match value {
        String(kind) if kind != "" => Ok(kind)
        _ => Err("must be a non-empty string")
      }
    AnthropicMessages =>
      match value {
        String(kind) if anthropic_error_types.contains(kind) => Ok(kind)
        _ =>
          Err(
            "must be an error type of \{api.name()}: \{listed(anthropic_error_types)}",
          )
      }
  }
}

///|
/// What an `llm` field declares, apart from its strings: the parts that are
/// never templates, checked when the definitions are loaded or the Stub is
/// added.
pub struct Declaration {
  api : Api
  /// `chunkSize`: the code points each piece of the text holds in a
  /// stream, the last piece shorter, from 1 to `max_chunk_size`.
  chunk_size : Int
  /// The token counts the reply reports.
  usage : Usage
  /// The stop reason as written, or `None` to derive it from the reply's
  /// content. For `openai-responses` it is an incomplete reason, and `None`
  /// means the reply completed.
  stop_reason : StopReason?
  /// The error that cuts the stream, or `None` for a stream that ends as
  /// usual. Its message is among the strings.
  error : MidStreamError?
} derive(Debug, Eq)

///|
/// A declaration for the API `api` whose pieces of text hold `chunk_size`
/// code points, 4 by default, and whose reply reports the token counts
/// `usage`, both 0 by default, and the stop reason `stop_reason`, derived
/// when it is left out. Its stream is cut by `error` when given. The
/// definitions check that `chunk_size` is from 1 to `max_chunk_size`.
pub fn Declaration::Declaration(
  api~ : Api,
  chunk_size? : Int = default_chunk_size,
  usage? : Usage = Usage(input=0, output=0),
  stop_reason? : StopReason,
  error? : MidStreamError,
) -> Declaration {
  { api, chunk_size, usage, stop_reason, error, }
}

///|
/// A mid-stream error as `error` declares it, apart from its message: the
/// API's own error, which a stream sends after part of its text and in
/// place of the rest of the reply. A request that does not stream gets the
/// ordinary reply.
pub struct MidStreamError {
  /// `after`: how many code points of the text the stream sends before the
  /// error, from 0.
  after : Int
  /// The error's `type`, or its `code` for `openai-responses`, sent as
  /// written.
  kind : String
} derive(Debug, Eq)

///|
/// The error that follows `after` code points of the text, whose `type`, or
/// `code` for `openai-responses`, is `kind`. The definitions check `kind`
/// with `read_error_kind`, and that `after` is not past the text.
pub fn MidStreamError::MidStreamError(
  after~ : Int,
  kind~ : String,
) -> MidStreamError {
  { after, kind, }
}

///|
/// The largest `chunkSize`.
pub let max_chunk_size : Int = 1_000_000

///|
/// The token counts a reply reports, as declared: smock counts and
/// estimates nothing. Each API places them in its own members, with their
/// total where it gives one.
pub struct Usage {
  /// The tokens of the prompt.
  input : Int64
  /// The tokens of the reply.
  output : Int64
} derive(Debug, Eq)

///|
/// The usage of `input` tokens in the prompt and `output` in the reply.
pub fn Usage::Usage(input~ : Int64, output~ : Int64) -> Usage {
  { input, output, }
}

///|
/// The largest token count a usage can declare, 2^53 - 1: up to it, a JSON
/// number holds every integer exactly.
pub let max_token_count : Int64 = 9_007_199_254_740_991L

///|
/// The load check of a mid-stream error's `after` on a reply whose text,
/// as written, is `text`, the join of its chunks when it gives them: it may
/// reach the end of the text, counted in code points, and not pass it. The
/// message of the load error gives the text's length.
pub fn check_error_after(after : Int, text : String) -> Result[Unit, String] {
  let mut length = 0
  for _ in text {
    length += 1
  }
  if after > length {
    let unit = if length == 1 { "code point" } else { "code points" }
    Err("is past the end of the text, which has \{length} \{unit}")
  } else {
    Ok(())
  }
}

///|
/// The strings of a declaration, as written, or rendered for the request.
pub struct Strings {
  /// The text of the reply: empty when left out, or the join of `chunks`.
  text : String
  /// The pieces `chunks` gives, which a stream sends as they are, each one
  /// on its own, an empty one included; or `None` for `text`, which a
  /// stream cuts into pieces of the declaration's chunk size.
  chunks : ReadOnlyArray[String]?
  /// The reply's id, sent as written, or `None` for a generated one.
  id : String?
  /// The reply's model, or `None` for the request's.
  model : String?
  /// The tool calls, after the text, in the order written: none when left
  /// out.
  tool_calls : ReadOnlyArray[ToolCall]
  /// The message of the declaration's mid-stream error: empty when it
  /// declares none.
  error_message : String
} derive(Debug, Eq)

///|
/// The strings of a reply whose text is `text`, empty by default; or, with
/// `chunks`, whose pieces are its elements and whose text is their join,
/// in place of `text`. The definitions refuse `text` beside `chunks`. Its
/// id is `id` when given and its model `model` when given, its tool calls
/// `tool_calls`, none by default, and the message of its mid-stream error
/// `error_message`, empty by default.
pub fn Strings::Strings(
  text? : String = "",
  chunks? : ReadOnlyArray[String],
  id? : String,
  model? : String,
  tool_calls? : ReadOnlyArray[ToolCall] = [],
  error_message? : String = "",
) -> Strings {
  match chunks {
    Some(chunks) =>
      {
        text: chunks.join(""),
        chunks: Some(chunks),
        id,
        model,
        tool_calls,
        error_message,
      }
    None => { text, chunks: None, id, model, tool_calls, error_message, }
  }
}

///|
/// Whether the reply carries its text: always without tool calls, and with
/// them only when the text is not empty. With tool calls, empty text gives
/// no content, so no piece either, even when `chunks` gives empty ones.
fn Strings::has_content(self : Strings) -> Bool {
  self.tool_calls.length() == 0 || self.text != ""
}

///|
/// A function tool call of a reply, as `toolCalls` declares it.
pub struct ToolCall {
  /// The function's name, sent as written. The definitions check that it
  /// is not empty, and nothing checks it against a vendor's naming rule.
  name : String
  /// The arguments' JSON text, as the reply sends it: not always valid
  /// JSON, since a string is sent as written.
  arguments : String
  /// The call id, sent as written, or `None` for a generated one.
  id : String?
} derive(Debug, Eq)

///|
/// The tool call of the function `name` with `arguments`, and the call id
/// `id` when given. A string is sent as written, so arguments that are not
/// valid JSON can be tested; any other value, an object as the definitions
/// allow, as compact JSON, its members in the order written and its numbers
/// as smock writes JSON.
pub fn ToolCall::ToolCall(
  name~ : String,
  arguments~ : Json,
  id? : String,
) -> ToolCall {
  let arguments = match arguments {
    String(text) => text
    value => @template.compact_json(value)
  }
  { name, arguments, id, }
}

///|
/// The pieces of the text that a stream sends, in order: the elements of
/// `chunks`, or the text cut into pieces of `size` code points; none when
/// the reply carries no content.
fn Strings::text_pieces(self : Strings, size : Int) -> ArrayView[String] {
  match self.chunks {
    _ if !self.has_content() => [][:]
    Some(chunks) => chunks[:]
    None => pieces(self.text, size)[:]
  }
}

///|
/// What smock sends for an LLM response, beside its status and the Stub's
/// own header fields.
pub struct Reply {
  /// The Content-Type smock sets, in place of any the Stub gives:
  /// `application/json` for the JSON reply, `text/event-stream` for the
  /// stream.
  content_type : String
  /// The request-id header field smock adds, as its name, in lower case,
  /// and its value, unless the Stub gives a field of that name: then the
  /// Stub's field takes its place.
  request_id : (String, String)
  /// The JSON reply, or the stream's events.
  body : ReplyBody
  /// What the waits of the stream complete, its closing event, or `None`
  /// when no event depends on them.
  priv closing : Closing?
  /// Whether the reply takes more than `max_reply_bytes` once encoded. It
  /// is then not to be sent: `check_size` says so.
  priv over : Bool
}

///|
/// The closing event of a Responses stream that completes, the stream's
/// last, whose `completed_at` is the time received plus the stream's waits
/// up to it. Until the waits are handed over, it gives the time received,
/// as with no wait.
priv struct Closing {
  /// The time the request was received, in milliseconds since the Unix
  /// epoch.
  received : Int64
  /// The Response object the closing event carries.
  response : Map[String, Json]
  /// The closing event's `sequence_number`.
  sequence_number : Int
}

///|
/// The two forms of a reply. The request decides between them: a request
/// whose body is a JSON object with `stream` exactly `true` gets the
/// stream, any other the JSON reply.
pub enum ReplyBody {
  /// The reply as one JSON document, in UTF-8.
  Json(Bytes)
  /// The reply as Server-Sent Events, in the order they are sent, the
  /// API's end marker included.
  Events(Array[Event])
}

///|
/// One Server-Sent Event of a streamed reply, with its wait slot.
pub struct Event {
  /// The wait the event takes before it is written.
  wait : WaitSlot
  /// The event type, sent as an `event:` line, or `None` for none.
  event : String?
  /// The data: one line of compact JSON, or the API's end marker.
  data : String
}

///|
/// Where a wait of the stream's pacing goes. The package draws no wait: the
/// engine draws one for each slot that takes one.
pub enum WaitSlot {
  /// No wait: the event follows the one before it at once, or the head
  /// when it is the first. The events that open or close the reply, a
  /// block or an item take it.
  NoWait
  /// The wait before the first piece, counted from the head; in a reply
  /// with no piece, before its closing events.
  First
  /// The wait before each piece after the first.
  Interval
}

///|
/// The reply that `declaration`, with its strings `strings`, gives to a
/// request whose body is the JSON `request`, or `None` when the body is
/// not JSON, received at `now` (milliseconds since the Unix epoch): the
/// stream when the body is a JSON object whose `stream` is exactly `true`,
/// otherwise the JSON reply. A declared mid-stream error cuts an
/// `openai-chat` or `anthropic-messages` stream; the JSON reply leaves it
/// out. Its ids draw from `ids`, the request's ids generator, and the
/// reply's id is the strings' `id` when given, as is each tool call's call
/// id. Its model is the strings' `model` when given, otherwise the
/// request's.
pub fn reply(
  declaration : Declaration,
  strings : Strings,
  request~ : Json?,
  now~ : Int64,
  ids~ : @prng.Generator,
) -> Reply {
  let ids = draw_ids(ids, strings.tool_calls.length())
  let created = now / 1000L
  let model = match strings.model {
    Some(model) => model
    None => request_model(request)
  }
  match declaration.api {
    OpenaiChat => {
      let id = reply_id(strings, "chatcmpl-", ids)
      let request_id = ("x-request-id", "req_" + ids.request)
      if asks_to_stream(request) {
        chat_stream(
          declaration,
          strings,
          id~,
          created~,
          model~,
          usage=asks_for_usage(request),
          calls=ids.calls,
          request_id~,
        )
      } else {
        chat_reply(
          declaration,
          strings,
          id~,
          created~,
          model~,
          calls=ids.calls,
          request_id~,
        )
      }
    }
    OpenaiResponses => {
      let id = reply_id(strings, "resp_", ids)
      let message_id = "msg_" + ids.message
      let request_id = ("x-request-id", "req_" + ids.request)
      if asks_to_stream(request) {
        responses_stream(
          declaration,
          strings,
          id~,
          message_id~,
          received=now,
          model~,
          request~,
          functions=ids.functions,
          calls=ids.calls,
          request_id~,
        )
      } else {
        responses_reply(
          declaration,
          strings,
          id~,
          message_id~,
          created~,
          model~,
          request~,
          functions=ids.functions,
          calls=ids.calls,
          request_id~,
        )
      }
    }
    AnthropicMessages => {
      let id = reply_id(strings, "msg_", ids)
      let request_id = ("request-id", "req_" + ids.request)
      if asks_to_stream(request) {
        messages_stream(
          declaration,
          strings,
          id~,
          model~,
          request~,
          calls=ids.calls,
          request_id~,
        )
      } else {
        messages_reply(
          declaration,
          strings,
          id~,
          model~,
          request~,
          calls=ids.calls,
          request_id~,
        )
      }
    }
  }
}

///|
/// The reply's id: the strings' `id` as written when given, otherwise
/// `prefix`, the API's, and the reply's slot of `ids`.
fn reply_id(strings : Strings, prefix : String, ids : Ids) -> String {
  match strings.id {
    Some(id) => id
    None => prefix + ids.reply
  }
}

///|
/// Hands the reply the waits the engine drew for its stream, before the
/// stream is sent: `waits[i]` milliseconds before the `i`-th event, 0 for
/// an event that takes no wait, one for each event, or no element at all
/// when no event waits. An event whose content depends on the waits is
/// completed with them: the `completed_at` of a Responses stream's
/// `response.completed`, the time received plus the waits up to it, in
/// whole seconds. No Chat Completions or Anthropic Messages event depends
/// on them, nor does `response.incomplete`, whose `completed_at` is null,
/// so those streams are left as they are, and a JSON reply has no wait.
pub fn Reply::complete(self : Reply, waits : FixedArray[Int]) -> Unit {
  guard self.closing is Some(closing) && self.body is Events(events) else {
    return
  }
  // The closing event is the last, so every wait comes before it, its own
  // included.
  let mut waited = 0L
  for i in 0..<waits.length() {
    waited += waits[i].to_int64()
  }
  let completed_at = (closing.received + waited) / 1000L
  // The event was written with the time received, as with no wait.
  if completed_at == closing.received / 1000L {
    return
  }
  closing.response["completed_at"] = Json::number(completed_at.to_double())
  let last = events.length() - 1
  events[last] = {
    wait: events[last].wait,
    event: events[last].event,
    data: event_data(
      "response.completed",
      "\"response\":\{@template.compact_json(Json::object(closing.response))}",
      closing.sequence_number,
      "",
    ),
  }
}

///|
/// The most bytes a reply takes once encoded: 1 MiB, the bound of a
/// rendered body. It is counted apart from the rendered strings, which
/// their rendering counts as a body.
pub let max_reply_bytes : Int = @template.max_output

///|
/// Whether `self` takes at most `max_reply_bytes` bytes of UTF-8 once
/// encoded: its JSON body, or every event of its stream as it is sent. A
/// reply over the bound is not to be sent: its JSON body is not written,
/// and its stream stops soon after the event that passed the bound. The
/// message says which form passed it. The waits `complete` hands over
/// change only a Responses stream's `completed_at`, whose whole seconds
/// keep their 10 digits from 2001 to 2286, so they change no size.
pub fn Reply::check_size(self : Reply) -> Result[Unit, String] {
  guard self.over else { return Ok(()) }
  match self.body {
    Json(_) => Err("the reply takes more than 1 MiB as a JSON body")
    Events(_) => Err("the reply takes more than 1 MiB as a stream")
  }
}

///|
/// The time a load check encodes a reply at, 2026-10-23T00:00:00Z, in
/// milliseconds since the Unix epoch. Every time from 2001 to 2286 has as
/// many digits of whole seconds, so a reply takes as many bytes whenever
/// it is sent.
let load_time : Int64 = 1_792_713_600_000L

///|
/// The body of the request a load check streams a reply to: it sets
/// `stream` and `stream_options.include_usage`, so that a Chat Completions
/// stream carries its usage chunk, and gives no model.
let load_stream_request : Json = {
  "stream": true,
  "stream_options": { "include_usage": true },
}

///|
/// The load check of the size of the reply that `declaration` gives with
/// its strings as written, `strings`: `Reply::check_size` of its JSON
/// reply, to a request whose body is not JSON, and of its stream, to one
/// whose body is `load_stream_request`. Neither request gives a model or a
/// setting a Responses object copies, and every id takes as many bytes
/// whatever is drawn. The message of the load error says which of the two
/// forms passes the bound, or that both do.
pub fn check_reply_size(
  declaration : Declaration,
  strings : Strings,
) -> Result[Unit, String] {
  let ids = ids_generator(0)
  let json = reply(declaration, strings, request=None, now=load_time, ids~)
  let stream = reply(
    declaration,
    strings,
    request=Some(load_stream_request),
    now=load_time,
    ids~,
  )
  match (json.over, stream.over) {
    (false, false) => Ok(())
    (true, false) => Err("the reply takes more than 1 MiB as a JSON body")
    (false, true) => Err("the reply takes more than 1 MiB as a stream")
    (true, true) =>
      Err("the reply takes more than 1 MiB as a JSON body and as a stream")
  }
}

///|
/// The JSON reply whose body is `body`, with the request-id header field
/// `request_id`. Its bytes are counted first, without writing them, and a
/// body that takes more than `max_reply_bytes` is not written.
fn json_reply(body : Json, request_id : (String, String)) -> Reply {
  let over = @template.compact_length(body) > max_reply_bytes.to_int64()
  {
    content_type: "application/json",
    request_id,
    body: Json(if over { b"" } else { @template.compact_json_bytes(body) }),
    closing: None,
    over,
  }
}

///|
/// The events of one stream as they are added, with the bytes they take as
/// they are sent, counted as each one is added.
priv struct Stream {
  /// The events so far, in the order they are sent.
  events : Array[Event]
  /// The bytes of UTF-8 the events so far take as they are sent.
  mut bytes : Int
}

///|
/// The events of a new stream, with room for `capacity` of them.
fn Stream::new(capacity : Int) -> Stream {
  { events: Array(capacity~), bytes: 0, }
}

///|
/// Adds the event of type `event`, or of none, whose data is `data`, with
/// the wait slot `wait`, and counts the bytes it takes as it is sent: its
/// `event:` line when it has a type, its one `data:` line and the blank
/// line after them. A type is ASCII.
fn Stream::push(
  self : Stream,
  wait : WaitSlot,
  event : String?,
  data : String,
) -> Unit {
  // `data: `, the line feed after it and the blank line.
  let mut bytes = 8 + utf8_length(data)
  if event is Some(name) {
    // `event: ` and the line feed after it.
    bytes += 8 + name.length()
  }
  self.bytes += bytes
  self.events.push({ wait, event, data, })
}

///|
/// Whether the events so far take more than `max_reply_bytes`.
fn Stream::over(self : Stream) -> Bool {
  self.bytes > max_reply_bytes
}

///|
/// The reply of the stream, with the request-id header field `request_id`
/// and the closing event `closing` its waits complete, none by default.
fn Stream::reply(
  self : Stream,
  request_id : (String, String),
  closing? : Closing? = None,
) -> Reply {
  {
    content_type: "text/event-stream",
    request_id,
    body: Events(self.events),
    closing,
    over: self.over(),
  }
}

///|
/// The bytes of UTF-8 that `text` takes, valid UTF-16 as compact JSON
/// gives it: 1 for a code unit below U+0080, 2 below U+0800, 2 for each
/// surrogate of a pair, and 3 for any other.
fn utf8_length(text : String) -> Int {
  let mut length = text.length()
  for i in 0..<text.length() {
    let unit = text[i].to_int()
    if unit >= 0x80 {
      length += if unit < 0x800 || (unit >= 0xD800 && unit < 0xE000) {
        1
      } else {
        2
      }
    }
  }
  length
}

///|
/// Whether the request whose body is the JSON `request` asks for the
/// stream: its body is a JSON object with `stream` exactly `true`. A body
/// that is not JSON, a missing `stream`, `false` and the string `"true"`
/// ask for the JSON reply.
fn asks_to_stream(request : Json?) -> Bool {
  request is Some(Object(members)) && members.get("stream") is Some(True)
}

///|
/// Whether the streamed request whose body is the JSON `request` asks for
/// Chat Completions' usage chunk: its `stream_options.include_usage` is
/// exactly `true`.
fn asks_for_usage(request : Json?) -> Bool {
  request is Some(Object(members)) &&
  members.get("stream_options") is Some(Object(options)) &&
  options.get("include_usage") is Some(True)
}

///|
/// The call id of `call`: its `id` as written when given, otherwise
/// `prefix`, the API's, and `drawn`, its call id's slot.
fn call_id(call : ToolCall, prefix : String, drawn : String) -> String {
  match call.id {
    Some(id) => id
    None => prefix + drawn
  }
}

///|
/// The ids of one reply, each drawn in its slot of a fixed order: the
/// reply's, then the Responses message item's, then two for each tool
/// call, the Responses function call's item id and then its call id, and
/// the request-id header's, last. Every slot draws, whether or not the
/// reply's API uses it or the Stub fixes its id, so that fixing one id
/// changes no other and an id keeps its draws whatever the API.
priv struct Ids {
  /// The reply's id, without its prefix.
  reply : String
  /// The Responses message item's id, without its prefix.
  message : String
  /// Each tool call's Responses function call item id, without its prefix,
  /// in the order written.
  functions : FixedArray[String]
  /// Each tool call's call id, without its prefix, in the order written.
  calls : FixedArray[String]
  /// The request id of the request-id header, without its prefix.
  request : String
}

///|
/// The function call item ids and the call ids of a reply with no tool
/// call, shared by every such reply.
let no_calls : FixedArray[String] = []

///|
/// Draws the ids of one reply with `tool_calls` tool calls from `ids`, slot
/// by slot.
fn draw_ids(ids : @prng.Generator, tool_calls : Int) -> Ids {
  let reply = draw_id(ids)
  let message = draw_id(ids)
  let functions = if tool_calls == 0 {
    no_calls
  } else {
    FixedArray::make(tool_calls, "")
  }
  let calls = if tool_calls == 0 {
    no_calls
  } else {
    FixedArray::make(tool_calls, "")
  }
  for i in 0..<tool_calls {
    // The Responses function call's item id, then the call id.
    functions[i] = draw_id(ids)
    calls[i] = draw_id(ids)
  }
  let request = draw_id(ids)
  { reply, message, functions, calls, request, }
}

///|
/// The characters an id draws from: A-Z, a-z and 0-9.
let id_alphabet : Array[Char] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".to_array()

///|
/// The characters of an id after its prefix.
let id_length : Int = 24

///|
/// One id without its prefix: `id_length` characters, each drawn from
/// `ids` with every one of `id_alphabet` equally likely.
fn draw_id(ids : @prng.Generator) -> String {
  let out = StringBuilder(size_hint=id_length)
  for _ in 0..<id_length {
    let i = ids.below(id_alphabet.length().to_uint64()).to_int()
    out.write_char(id_alphabet[i])
  }
  out.to_string()
}

///|
/// The `model` of the request `request` when it is a string, otherwise the
/// empty string.
fn request_model(request : Json?) -> String {
  match request {
    Some(Object(members)) =>
      match members.get("model") {
        Some(String(model)) => model
        _ => ""
      }
    _ => ""
  }
}

///|
/// The Chat Completions reply of `declaration` with the strings `strings`,
/// the reply's id `id`, `created` (seconds since the Unix epoch), `model`,
/// the tool calls' drawn call ids `calls` and the request-id header field
/// `request_id`: one `chat.completion` object, in the members and the
/// order of the reference's example, with the example's fixed values. With
/// tool calls, the message gives them after its content, as the reference's
/// "Functions" example does, and its content is null when the text is
/// empty.
fn chat_reply(
  declaration : Declaration,
  strings : Strings,
  id~ : String,
  created~ : Int64,
  model~ : String,
  calls~ : FixedArray[String],
  request_id~ : (String, String),
) -> Reply {
  let content = if strings.has_content() {
    Json::string(strings.text)
  } else {
    Json::null()
  }
  let message : Json = if strings.tool_calls.length() == 0 {
    {
      "role": "assistant",
      "content": content,
      "refusal": Json::null(),
      "annotations": [],
    }
  } else {
    {
      "role": "assistant",
      "content": content,
      "tool_calls": chat_tool_calls(strings.tool_calls, calls),
      "refusal": Json::null(),
      "annotations": [],
    }
  }
  let body : Json = {
    "id": Json::string(id),
    "object": "chat.completion",
    "created": Json::number(created.to_double()),
    "model": Json::string(model),
    "choices": [
      {
        "index": 0,
        "message": message,
        "logprobs": Json::null(),
        "finish_reason": Json::string(chat_finish_reason(declaration, strings)),
      },
    ],
    "usage": chat_usage(declaration.usage),
    "service_tier": "default",
  }
  json_reply(body, request_id)
}

///|
/// The `tool_calls` of a Chat Completions message: each of `tool_calls`,
/// with its call id from `calls`, the drawn ones, and its arguments as a
/// JSON string.
fn chat_tool_calls(
  tool_calls : ReadOnlyArray[ToolCall],
  calls : FixedArray[String],
) -> Json {
  let out : Array[Json] = Array(capacity=tool_calls.length())
  for i in 0..<tool_calls.length() {
    let call = tool_calls[i]
    out.push({
      "id": Json::string(call_id(call, "call_", calls[i])),
      "type": "function",
      "function": {
        "name": Json::string(call.name),
        "arguments": Json::string(call.arguments),
      },
    })
  }
  Json::array(out)
}

///|
/// The finish reason of `declaration`'s Chat Completions reply with the
/// strings `strings`: the stop reason written, or the one derived from the
/// content when none is. A word of the API needs no escaping in JSON.
fn chat_finish_reason(declaration : Declaration, strings : Strings) -> String {
  match declaration.stop_reason {
    Some(reason) => reason.word
    // Derived: a reply with tool calls asks for them, any other stops.
    None => if strings.tool_calls.length() > 0 { "tool_calls" } else { "stop" }
  }
}

///|
/// The Chat Completions stream of `declaration` with the strings
/// `strings`, whose text and tool-call arguments are cut into pieces of the
/// declaration's chunk size unless they give the text's pieces, the reply's
/// id `id`, `created` (seconds since the Unix epoch), `model`, the tool
/// calls' drawn call ids `calls` and the request-id header field
/// `request_id`:
/// `chat.completion.chunk` events with no `event:` line, each one `data:`
/// line of compact JSON with the same id, `created` and model. The opening
/// chunk gives the assistant's role and an empty content, or a null one
/// when tool calls follow no text, and one chunk follows per piece of the
/// text. Each tool call `k` then opens with a chunk that gives its index
/// `k`, call id, type and name, and empty arguments, and one chunk follows
/// per piece of its arguments, with the index alone. The closing chunk
/// gives the finish reason, and `[DONE]` ends the stream. With `usage`,
/// every chunk carries `"usage":null`, and the usage chunk, with no
/// choice, comes before `[DONE]`. A declared mid-stream error cuts the
/// text after its `after` code points and follows it as an error data
/// frame with the message `strings.error_message`, in place of the tool
/// calls and every chunk after them, so the stream has no end marker.
fn chat_stream(
  declaration : Declaration,
  strings : Strings,
  id~ : String,
  created~ : Int64,
  model~ : String,
  usage~ : Bool,
  calls~ : FixedArray[String],
  request_id~ : (String, String),
) -> Reply {
  let chunks = ChatChunks::new(id~, created~, model~, usage~)
  let tool_calls = strings.tool_calls
  let pace = Pace::new()
  let text_pieces = match declaration.error {
    Some(error) =>
      pieces_before(strings.text_pieces(declaration.chunk_size), error.after)
    None => strings.text_pieces(declaration.chunk_size)
  }
  let opening = if strings.has_content() {
    "{\"role\":\"assistant\",\"content\":\"\"}"
  } else {
    "{\"role\":\"assistant\",\"content\":null}"
  }
  let out = Stream::new(text_pieces.length() + tool_calls.length() + 4)
  out.push(NoWait, None, chunks.chunk(opening, "null"))
  for piece in text_pieces {
    // A stream over the bound is not sent, so it stops here.
    if out.over() {
      return out.reply(request_id)
    }
    let delta = "{\"content\":\{@template.compact_json(Json::string(piece))}}"
    out.push(pace.piece(), None, chunks.chunk(delta, "null"))
  }
  if declaration.error is Some(error) {
    // The error takes the wait a next piece would.
    out.push(pace.piece(), None, chat_error(error, strings.error_message))
    return out.reply(request_id)
  }
  for k in 0..<tool_calls.length() {
    if out.over() {
      return out.reply(request_id)
    }
    let call = tool_calls[k]
    // The call id and the name as JSON strings.
    let quoted_id = @template.compact_json(
      Json::string(call_id(call, "call_", calls[k])),
    )
    let quoted_name = @template.compact_json(Json::string(call.name))
    out.push(
      NoWait,
      None,
      chunks.chunk(
        "{\"tool_calls\":[{\"index\":\{k},\"id\":\{quoted_id},\"type\":\"function\",\"function\":{\"name\":\{quoted_name},\"arguments\":\"\"}}]}",
        "null",
      ),
    )
    for piece in pieces(call.arguments, declaration.chunk_size) {
      if out.over() {
        return out.reply(request_id)
      }
      let piece = @template.compact_json(Json::string(piece))
      out.push(
        pace.piece(),
        None,
        chunks.chunk(
          "{\"tool_calls\":[{\"index\":\{k},\"function\":{\"arguments\":\{piece}}}]}",
          "null",
        ),
      )
    }
  }
  out.push(
    pace.closing(),
    None,
    chunks.chunk("{}", "\"\{chat_finish_reason(declaration, strings)}\""),
  )
  if usage {
    out.push(NoWait, None, chunks.usage_chunk(declaration.usage))
  }
  out.push(NoWait, None, "[DONE]")
  out.reply(request_id)
}

///|
/// The data of Chat Completions' error frame for `error` with the message
/// `message`: an `error` object, in place of a chunk, whose `param` and
/// `code` are null.
fn chat_error(error : MidStreamError, message : String) -> String {
  let message = @template.compact_json(Json::string(message))
  let kind = @template.compact_json(Json::string(error.kind))
  "{\"error\":{\"message\":\{message},\"type\":\{kind},\"param\":null,\"code\":null}}"
}

///|
/// The chunks of one Chat Completions stream, which share their id,
/// `created` and model.
priv struct ChatChunks {
  /// The compact JSON every chunk begins with, up to its choices: the id,
  /// `object`, `created` and the model.
  head : String
  /// The compact JSON every chunk with a choice ends with, after the
  /// choice: `]}`, or `],"usage":null}` when the request asked for usage.
  tail : String
}

///|
/// The chunks of the stream whose id is `id`, `created` (seconds since the
/// Unix epoch) and `model`, each with `"usage":null` when `usage` is true.
fn ChatChunks::new(
  id~ : String,
  created~ : Int64,
  model~ : String,
  usage~ : Bool,
) -> ChatChunks {
  let created = @template.compact_json(Json::number(created.to_double()))
  let id = @template.compact_json(Json::string(id))
  let model = @template.compact_json(Json::string(model))
  {
    head: "{\"id\":\{id},\"object\":\"chat.completion.chunk\",\"created\":\{created},\"model\":\{model},\"choices\":[",
    tail: if usage {
      "],\"usage\":null}"
    } else {
      "]}"
    },
  }
}

///|
/// The chunk whose delta is `delta` and finish reason `finish_reason`, each
/// given as compact JSON.
fn ChatChunks::chunk(
  self : ChatChunks,
  delta : String,
  finish_reason : String,
) -> String {
  let choice = "{\"index\":0,\"delta\":"
  let middle = ",\"logprobs\":null,\"finish_reason\":"
  let out = StringBuilder(
    size_hint=self.head.length() +
      choice.length() +
      delta.length() +
      middle.length() +
      finish_reason.length() +
      1 +
      self.tail.length(),
  )
  out.write_string(self.head)
  out.write_string(choice)
  out.write_string(delta)
  out.write_string(middle)
  out.write_string(finish_reason)
  out.write_char('}')
  out.write_string(self.tail)
  out.to_string()
}

///|
/// The usage chunk, which ends a stream whose request asked for usage: no
/// choice, and the usage member of `usage`.
fn ChatChunks::usage_chunk(self : ChatChunks, usage : Usage) -> String {
  "\{self.head}],\"usage\":\{@template.compact_json(chat_usage(usage))}}"
}

///|
/// The Responses reply of `declaration` with the strings `strings`, the
/// reply's id `id`, the message item's id `message_id`, `created` (seconds
/// since the Unix epoch), `model`, the request's JSON body `request`, the
/// tool calls' drawn function call item ids `functions` and call ids
/// `calls`, and the request-id header field `request_id`: one Response
/// object, in the members and the order of the reference's examples, with
/// the example's fixed values. Its output holds the message item, left out
/// when tool calls follow empty text, then one `function_call` item per
/// tool call. A written stop reason is an incomplete reason, which makes
/// the reply and its message item incomplete; the function call items stay
/// completed.
fn responses_reply(
  declaration : Declaration,
  strings : Strings,
  id~ : String,
  message_id~ : String,
  created~ : Int64,
  model~ : String,
  request~ : Json?,
  functions~ : FixedArray[String],
  calls~ : FixedArray[String],
  request_id~ : (String, String),
) -> Reply {
  let status = responses_status(declaration)
  let tool_calls = strings.tool_calls
  let output : Array[Json] = Array(capacity=tool_calls.length() + 1)
  if strings.has_content() {
    output.push(message_item(message_id, status, strings.text))
  }
  for k in 0..<tool_calls.length() {
    let call = tool_calls[k]
    output.push(
      function_call_item(
        call,
        id="fc_" + functions[k],
        call_id=call_id(call, "call_", calls[k]),
        arguments=call.arguments,
        status="completed",
      ),
    )
  }
  let body = response_object(
    id~,
    created~,
    model~,
    request~,
    status~,
    // An incomplete Response never completed.
    completed_at=if declaration.stop_reason is Some(_) {
      Json::null()
    } else {
      Json::number(created.to_double())
    },
    incomplete_details=incomplete_details(declaration),
    output=Json::array(output),
    usage=responses_usage(declaration.usage),
  )
  json_reply(Json::object(body), request_id)
}

///|
/// The status `declaration`'s Response ends with: `incomplete` when it
/// writes a stop reason, an incomplete reason, otherwise `completed`.
fn responses_status(declaration : Declaration) -> String {
  match declaration.stop_reason {
    Some(_) => "incomplete"
    None => "completed"
  }
}

///|
/// The `incomplete_details` of `declaration`'s Response once it ends: the
/// incomplete reason written, or null for a Response that completed.
fn incomplete_details(declaration : Declaration) -> Json {
  match declaration.stop_reason {
    Some(reason) => { "reason": Json::string(reason.word) }
    None => Json::null()
  }
}

///|
/// The Responses message item whose id is `id` and status `status`, with
/// `text` in its one `output_text` part.
fn message_item(id : String, status : String, text : String) -> Json {
  {
    "id": Json::string(id),
    "type": "message",
    "status": Json::string(status),
    "role": "assistant",
    "content": [output_text_part(text)],
  }
}

///|
/// The Responses function call item of `call`, whose item id is `id`, call
/// id `call_id` and status `status`, with `arguments`, its arguments' text
/// so far, as a JSON string: the members and the order of the reference's
/// "Functions" example.
fn function_call_item(
  call : ToolCall,
  id~ : String,
  call_id~ : String,
  arguments~ : String,
  status~ : String,
) -> Json {
  {
    "type": "function_call",
    "id": Json::string(id),
    "call_id": Json::string(call_id),
    "name": Json::string(call.name),
    "arguments": Json::string(arguments),
    "status": Json::string(status),
  }
}

///|
/// The `output_text` content part whose text is `text`.
fn output_text_part(text : String) -> Json {
  {
    "type": "output_text",
    "text": Json::string(text),
    "annotations": [],
    "logprobs": [],
  }
}

///|
/// The Response object whose id is `id`, `created_at` `created` (seconds
/// since the Unix epoch) and model `model`, with the members `status`,
/// `completed_at`, `incomplete_details`, `output` and `usage` given, and
/// the settings it copies from `request`, the request's JSON body, as its
/// members in order. Its members and their order are the reference's
/// examples', and the members the examples do not show, which the request
/// may set, sit in the alphabetical order the examples keep. Each setting
/// is copied as given, without being interpreted; one the request leaves
/// out takes the example's value, or is left out when the examples do not
/// show it. `service_tier` keeps the example's value, and `conversation`
/// is not copied.
fn response_object(
  id~ : String,
  created~ : Int64,
  model~ : String,
  request~ : Json?,
  status~ : String,
  completed_at~ : Json,
  incomplete_details~ : Json,
  output~ : Json,
  usage~ : Json,
) -> Map[String, Json] {
  let given = match request {
    Some(Object(members)) => Some(members)
    _ => None
  }
  let object : Map[String, Json] = Map([], capacity=40)
  object["id"] = Json::string(id)
  object["object"] = "response"
  object["access_programs"] = Json::null()
  object["created_at"] = Json::number(created.to_double())
  object["status"] = Json::string(status)
  copy_given(object, given, "background")
  object["completed_at"] = completed_at
  object["error"] = Json::null()
  object["incomplete_details"] = incomplete_details
  object["instructions"] = copied(given, "instructions", Json::null())
  object["max_output_tokens"] = copied(given, "max_output_tokens", Json::null())
  copy_given(object, given, "max_tool_calls")
  object["model"] = Json::string(model)
  object["output"] = output
  object["parallel_tool_calls"] = copied(given, "parallel_tool_calls", true)
  object["previous_response_id"] = copied(
    given,
    "previous_response_id",
    Json::null(),
  )
  copy_given(object, given, "prompt_cache_key")
  object["reasoning"] = copied(given, "reasoning", {
    "effort": Json::null(),
    "summary": Json::null(),
  })
  copy_given(object, given, "safety_identifier")
  // The tier that served the reply, which the request does not decide.
  object["service_tier"] = "default"
  object["store"] = copied(given, "store", true)
  object["temperature"] = copied(given, "temperature", example_one)
  object["text"] = copied(given, "text", { "format": { "type": "text" } })
  object["tool_choice"] = copied(given, "tool_choice", "auto")
  object["tools"] = copied(given, "tools", [])
  copy_given(object, given, "top_logprobs")
  object["top_p"] = copied(given, "top_p", example_one)
  object["truncation"] = copied(given, "truncation", "disabled")
  object["usage"] = usage
  object["user"] = copied(given, "user", Json::null())
  object["metadata"] = copied(given, "metadata", {})
  object
}

///|
/// The Responses stream of `declaration` with the strings `strings`, whose
/// text and tool-call arguments are cut into pieces of the declaration's
/// chunk size unless they give the text's pieces, the reply's id `id`, the
/// message item's id `message_id`, the time `received` (milliseconds since
/// the Unix epoch), `model`, the request's JSON body `request`, the tool
/// calls' drawn function call item ids `functions` and call ids `calls`,
/// and the request-id header field `request_id`. Each event has an
/// `event:` line equal to its `type`, and one `data:` line of compact JSON
/// whose `sequence_number` counts from 0, in the members and the order of
/// the reference's stream example: `response.created` and
/// `response.in_progress` give the Response object in progress; the
/// message item is opened at `output_index` 0, then its `output_text` part,
/// then one `response.output_text.delta` follows per piece, and the part
/// and the item are closed, unless tool calls follow empty text: then there
/// is no message item. Each tool call's `function_call` item follows at the
/// next `output_index`, opened with empty arguments, then one
/// `response.function_call_arguments.delta` per piece of its arguments,
/// and its arguments and the item are closed. `response.completed`, or
/// `response.incomplete` when a stop reason is written, gives the whole
/// Response object. No `[DONE]` follows. The closing event's
/// `completed_at` is the time received until `Reply::complete` adds the
/// stream's waits.
fn responses_stream(
  declaration : Declaration,
  strings : Strings,
  id~ : String,
  message_id~ : String,
  received~ : Int64,
  model~ : String,
  request~ : Json?,
  functions~ : FixedArray[String],
  calls~ : FixedArray[String],
  request_id~ : (String, String),
) -> Reply {
  let created = received / 1000L
  let tool_calls = strings.tool_calls
  let text_pieces = strings.text_pieces(declaration.chunk_size)
  let pace = Pace::new()
  let out = ResponsesEvents::new(
    text_pieces.length() + 4 * tool_calls.length() + 8,
  )
  // The Response in progress, the same in both opening events.
  let opening = response_object(
    id~,
    created~,
    model~,
    request~,
    status="in_progress",
    completed_at=Json::null(),
    incomplete_details=Json::null(),
    output=[],
    usage=Json::null(),
  )
  let opening = "\"response\":\{@template.compact_json(Json::object(opening))}"
  out.push(NoWait, "response.created", opening)
  out.push(NoWait, "response.in_progress", opening)
  let status = responses_status(declaration)
  // The items the closing event's Response holds, in output_index order.
  let output : Array[Json] = Array(capacity=tool_calls.length() + 1)
  // The message item, the reply's first, at output_index 0, unless tool
  // calls follow empty text.
  if strings.has_content() {
    let item_id = @template.compact_json(Json::string(message_id))
    out.push(
      NoWait,
      "response.output_item.added",
      "\"output_index\":0,\"item\":{\"id\":\{item_id},\"type\":\"message\",\"status\":\"in_progress\",\"role\":\"assistant\",\"content\":[]}",
    )
    let part_of = "\"item_id\":\{item_id},\"output_index\":0,\"content_index\":0"
    out.push(
      NoWait,
      "response.content_part.added",
      "\{part_of},\"part\":\{@template.compact_json(output_text_part(""))}",
    )
    for piece in text_pieces {
      // A stream over the bound is not sent, so it stops here.
      if out.stream.over() {
        return out.stream.reply(request_id)
      }
      out.push(
        pace.piece(),
        "response.output_text.delta",
        "\{part_of},\"delta\":\{@template.compact_json(Json::string(piece))}",
        after=no_logprobs,
      )
    }
    // Each closing event of the item carries the whole text.
    if out.stream.over() {
      return out.stream.reply(request_id)
    }
    // A reply with no piece waits before its first closing event. With
    // tool calls after it, the text is not empty, so it has a piece.
    out.push(
      pace.closing(),
      "response.output_text.done",
      "\{part_of},\"text\":\{@template.compact_json(Json::string(strings.text))}",
      after=no_logprobs,
    )
    if out.stream.over() {
      return out.stream.reply(request_id)
    }
    out.push(
      pace.closing(),
      "response.content_part.done",
      "\{part_of},\"part\":\{@template.compact_json(output_text_part(strings.text))}",
    )
    if out.stream.over() {
      return out.stream.reply(request_id)
    }
    let item = message_item(message_id, status, strings.text)
    out.push(
      pace.closing(),
      "response.output_item.done",
      "\"output_index\":0,\"item\":\{@template.compact_json(item)}",
    )
    output.push(item)
  }
  for k in 0..<tool_calls.length() {
    if out.stream.over() {
      return out.stream.reply(request_id)
    }
    let call = tool_calls[k]
    let output_index = output.length()
    let item_id = "fc_" + functions[k]
    let call_id = call_id(call, "call_", calls[k])
    let added = function_call_item(
      call,
      id=item_id,
      call_id~,
      arguments="",
      status="in_progress",
    )
    out.push(
      NoWait,
      "response.output_item.added",
      "\"output_index\":\{output_index},\"item\":\{@template.compact_json(added)}",
    )
    let arguments_of = "\"item_id\":\{@template.compact_json(Json::string(item_id))},\"output_index\":\{output_index}"
    for piece in pieces(call.arguments, declaration.chunk_size) {
      if out.stream.over() {
        return out.stream.reply(request_id)
      }
      out.push(
        pace.piece(),
        "response.function_call_arguments.delta",
        "\{arguments_of},\"delta\":\{@template.compact_json(Json::string(piece))}",
      )
    }
    // An earlier item's closing events follow at once, so that a reply
    // waits only before its pieces; the last item's are the reply's first
    // closing events, which a reply with no piece waits before.
    let last = k == tool_calls.length() - 1
    // Each closing event of the item carries the whole arguments.
    if out.stream.over() {
      return out.stream.reply(request_id)
    }
    out.push(
      if last {
        pace.closing()
      } else {
        NoWait
      },
      "response.function_call_arguments.done",
      "\{arguments_of},\"arguments\":\{@template.compact_json(Json::string(call.arguments))}",
    )
    if out.stream.over() {
      return out.stream.reply(request_id)
    }
    let item = function_call_item(
      call,
      id=item_id,
      call_id~,
      arguments=call.arguments,
      status="completed",
    )
    out.push(
      if last {
        pace.closing()
      } else {
        NoWait
      },
      "response.output_item.done",
      "\"output_index\":\{output_index},\"item\":\{@template.compact_json(item)}",
    )
    output.push(item)
  }
  // The closing event carries the whole text and every item.
  if out.stream.over() {
    return out.stream.reply(request_id)
  }
  // Until the waits are handed over, the Response completes when it is
  // received, as with no wait. An incomplete one never completes.
  let completes = declaration.stop_reason is None
  let response = response_object(
    id~,
    created~,
    model~,
    request~,
    status~,
    completed_at=if completes {
      Json::number(created.to_double())
    } else {
      Json::null()
    },
    incomplete_details=incomplete_details(declaration),
    output=Json::array(output),
    usage=responses_usage(declaration.usage),
  )
  let sequence_number = out.next
  out.push(
    pace.closing(),
    if completes {
      "response.completed"
    } else {
      "response.incomplete"
    },
    "\"response\":\{@template.compact_json(Json::object(response))}",
  )
  out.stream.reply(
    request_id,
    closing=if completes {
      Some({ received, response, sequence_number, })
    } else {
      None
    },
  )
}

///|
/// The members that end a text event of a Responses stream, after its
/// `sequence_number`, as the reference's example places them: no log
/// probabilities.
let no_logprobs : String = ",\"logprobs\":[]"

///|
/// The events of one Responses stream, numbered as they are added.
priv struct ResponsesEvents {
  /// The events so far.
  stream : Stream
  /// The `sequence_number` of the next event.
  mut next : Int
}

///|
/// The events of a new stream, with room for `capacity` of them.
fn ResponsesEvents::new(capacity : Int) -> ResponsesEvents {
  { stream: Stream::new(capacity), next: 0, }
}

///|
/// Adds the event of type `kind` whose members after `type` and before
/// `sequence_number` are `members`, and after it `after`, each given as
/// compact JSON, with the wait slot `wait` and the next `sequence_number`.
fn ResponsesEvents::push(
  self : ResponsesEvents,
  wait : WaitSlot,
  kind : String,
  members : String,
  after? : String = "",
) -> Unit {
  let sequence_number = self.next
  self.next += 1
  self.stream.push(
    wait,
    Some(kind),
    event_data(kind, members, sequence_number, after),
  )
}

///|
/// The data of the Responses event of type `kind` whose members after
/// `type` are `members`, then `sequence_number`, then `after`, each given
/// as compact JSON.
fn event_data(
  kind : String,
  members : String,
  sequence_number : Int,
  after : String,
) -> String {
  "{\"type\":\"\{kind}\",\{members},\"sequence_number\":\{sequence_number}\{after}}"
}

///|
/// The number 1 as the reference's examples write `temperature` and
/// `top_p`: `1.0`.
let example_one : Json = Json::number(1.0, repr="1.0")

///|
/// The member `name` of the request's members `given`, as given, or
/// `example`, the example's value, when the request does not give it.
fn copied(given : Map[String, Json]?, name : String, example : Json) -> Json {
  if given is Some(members) && members.get(name) is Some(value) {
    value
  } else {
    example
  }
}

///|
/// Copies the member `name` of the request's members `given` into `object`,
/// as given, when the request gives it.
fn copy_given(
  object : Map[String, Json],
  given : Map[String, Json]?,
  name : String,
) -> Unit {
  if given is Some(members) && members.get(name) is Some(value) {
    object[name] = value
  }
}

///|
/// The Responses usage member for `usage`: its counts and their total, with
/// the detail objects of the reference's example, their counts 0.
fn responses_usage(usage : Usage) -> Json {
  {
    "input_tokens": count(usage.input),
    "input_tokens_details": { "cached_tokens": 0, "cache_write_tokens": 0 },
    "output_tokens": count(usage.output),
    "output_tokens_details": { "reasoning_tokens": 0 },
    "total_tokens": count(usage.input + usage.output),
  }
}

///|
/// The Messages reply of `declaration` with the strings `strings`, the
/// reply's id `id`, `model`, the request's JSON body `request`, the tool
/// calls' drawn call ids `calls` and the request-id header field
/// `request_id`: one `message` object, in the members and the order of the
/// replies in Anthropic's guide on working with messages, the "Hello!" and
/// the `max_tokens` one. Its content is the text block, unless the text is
/// empty, then a `tool_use` block per tool call, as in the tool-use guide's
/// reply; with neither it holds no block, as in the vendor's refusal. A
/// refusal also carries `stop_details`.
fn messages_reply(
  declaration : Declaration,
  strings : Strings,
  id~ : String,
  model~ : String,
  request~ : Json?,
  calls~ : FixedArray[String],
  request_id~ : (String, String),
) -> Reply {
  let tool_calls = strings.tool_calls
  let content : Array[Json] = Array(capacity=tool_calls.length() + 1)
  if strings.text != "" {
    content.push({ "type": "text", "text": Json::string(strings.text) })
  }
  for k in 0..<tool_calls.length() {
    let call = tool_calls[k]
    content.push({
      "type": "tool_use",
      "id": Json::string(call_id(call, "toolu_", calls[k])),
      "name": Json::string(call.name),
      "input": tool_use_input(call),
    })
  }
  let stop_reason = messages_stop_reason(declaration, strings)
  let body : Map[String, Json] = {
    "id": Json::string(id),
    "type": "message",
    "role": "assistant",
    "content": Json::array(content),
    "model": Json::string(model),
    "stop_reason": Json::string(stop_reason),
    "stop_sequence": messages_stop_sequence(stop_reason, request),
  }
  if stop_reason == "refusal" {
    body["stop_details"] = refusal_details
  }
  body["usage"] = messages_usage(declaration.usage)
  json_reply(Json::object(body), request_id)
}

///|
/// The `input` of the `tool_use` block of `call`, which is always an object
/// in the vendor's replies: its arguments as that object when they are one,
/// as written or as a string that holds one, and otherwise the string they
/// are, as a JSON string.
fn tool_use_input(call : ToolCall) -> Json {
  let parsed = @json.parse(call.arguments) catch { _ => Json::null() }
  match parsed {
    Object(_) => parsed
    _ => Json::string(call.arguments)
  }
}

///|
/// The stop reason of `declaration`'s Messages reply with the strings
/// `strings`: the one written, or the one derived from the content when
/// none is.
fn messages_stop_reason(declaration : Declaration, strings : Strings) -> String {
  match declaration.stop_reason {
    Some(reason) => reason.word
    // Derived: a reply with tool calls asks for them, any other ends its
    // turn.
    None =>
      if strings.tool_calls.length() > 0 {
        "tool_use"
      } else {
        "end_turn"
      }
  }
}

///|
/// The `stop_sequence` of a Messages reply whose stop reason is
/// `stop_reason`, to a request whose body is the JSON `request`: with the
/// stop reason `stop_sequence`, the first of the request's
/// `stop_sequences` when that is a string, otherwise null. smock does not
/// choose which of them matched.
fn messages_stop_sequence(stop_reason : String, request : Json?) -> Json {
  if stop_reason == "stop_sequence" &&
    request is Some(Object(members)) &&
    members.get("stop_sequences") is Some(Array([String(first), ..])) {
    Json::string(first)
  } else {
    Json::null()
  }
}

///|
/// The Messages stream of `declaration` with the strings `strings`, whose
/// text and tool-call arguments are cut into pieces of the declaration's
/// chunk size unless they give the text's pieces, the reply's id `id`,
/// `model`, the request's JSON body `request`, the tool calls' drawn call
/// ids `calls` and the request-id header field `request_id`: events each
/// named with an `event:` line equal to its `type`, and one `data:` line of
/// compact JSON. `message_start` gives the message with no content, no stop
/// reason and the input tokens; the text block follows at index 0, with one
/// `text_delta` per piece, unless the text is empty; each tool call's
/// `tool_use` block follows at the next index, starting with an empty
/// `input` and an empty `partial_json`, with one `input_json_delta` per
/// piece of its arguments; then `message_delta` gives the stop members and
/// the output tokens, and `message_stop` ends the stream. There is no
/// `ping` event. A declared mid-stream error cuts the text after its
/// `after` code points, with no text block when none is sent, and follows
/// it as an `error` event with the message `strings.error_message`, in
/// place of the block's stop, the tool calls and every event after them.
fn messages_stream(
  declaration : Declaration,
  strings : Strings,
  id~ : String,
  model~ : String,
  request~ : Json?,
  calls~ : FixedArray[String],
  request_id~ : (String, String),
) -> Reply {
  // Empty text has no block, as in the JSON reply, even when `chunks`
  // gives empty pieces, so that both give the same message. Nor has text
  // that a mid-stream error cuts at 0.
  let has_text = match declaration.error {
    Some(error) => strings.text != "" && error.after > 0
    None => strings.text != ""
  }
  let text_pieces = match declaration.error {
    _ if !has_text => no_pieces
    Some(error) =>
      pieces_before(strings.text_pieces(declaration.chunk_size), error.after)
    None => strings.text_pieces(declaration.chunk_size)
  }
  let tool_calls = strings.tool_calls
  let pace = Pace::new()
  let out = Stream::new(text_pieces.length() + 4 * tool_calls.length() + 5)
  let message : Json = {
    "id": Json::string(id),
    "type": "message",
    "role": "assistant",
    "content": [],
    "model": Json::string(model),
    "stop_reason": Json::null(),
    "stop_sequence": Json::null(),
    "usage": {
      "input_tokens": count(declaration.usage.input),
      "output_tokens": 0,
    },
  }
  out.push(
    NoWait,
    Some("message_start"),
    "{\"type\":\"message_start\",\"message\":\{@template.compact_json(message)}}",
  )
  // The text block comes first, at index 0.
  if has_text {
    out.push(
      NoWait,
      Some("content_block_start"),
      content_block_start(0, "{\"type\":\"text\",\"text\":\"\"}"),
    )
    for piece in text_pieces {
      // A stream over the bound is not sent, so it stops here.
      if out.over() {
        return out.reply(request_id)
      }
      let delta = "{\"type\":\"text_delta\",\"text\":\{@template.compact_json(Json::string(piece))}}"
      out.push(
        pace.piece(),
        Some("content_block_delta"),
        content_block_delta(0, delta),
      )
    }
  }
  if declaration.error is Some(error) {
    // The error takes the wait a next piece would, and ends the stream.
    out.push(
      pace.piece(),
      Some("error"),
      messages_error(error, strings.error_message),
    )
    return out.reply(request_id)
  }
  if has_text {
    out.push(NoWait, Some("content_block_stop"), content_block_stop(0))
  }
  // Each tool call's block follows, at the next index.
  let first_call = if has_text { 1 } else { 0 }
  for k in 0..<tool_calls.length() {
    if out.over() {
      return out.reply(request_id)
    }
    let call = tool_calls[k]
    let index = first_call + k
    // The call id and the name as JSON strings.
    let quoted_id = @template.compact_json(
      Json::string(call_id(call, "toolu_", calls[k])),
    )
    let quoted_name = @template.compact_json(Json::string(call.name))
    out.push(
      NoWait,
      Some("content_block_start"),
      content_block_start(
        index,
        "{\"type\":\"tool_use\",\"id\":\{quoted_id},\"name\":\{quoted_name},\"input\":{}}",
      ),
    )
    // The empty first piece, as the vendor sends it, carries nothing, so it
    // takes no wait.
    out.push(
      NoWait,
      Some("content_block_delta"),
      content_block_delta(index, empty_json_delta),
    )
    for piece in pieces(call.arguments, declaration.chunk_size) {
      if out.over() {
        return out.reply(request_id)
      }
      let delta = "{\"type\":\"input_json_delta\",\"partial_json\":\{@template.compact_json(Json::string(piece))}}"
      out.push(
        pace.piece(),
        Some("content_block_delta"),
        content_block_delta(index, delta),
      )
    }
    out.push(NoWait, Some("content_block_stop"), content_block_stop(index))
  }
  let stop_reason = messages_stop_reason(declaration, strings)
  let delta : Map[String, Json] = {
    "stop_reason": Json::string(stop_reason),
    "stop_sequence": messages_stop_sequence(stop_reason, request),
  }
  if stop_reason == "refusal" {
    delta["stop_details"] = refusal_details
  }
  let message_delta : Json = {
    "type": "message_delta",
    "delta": Json::object(delta),
    "usage": { "output_tokens": count(declaration.usage.output) },
  }
  out.push(
    pace.closing(),
    Some("message_delta"),
    @template.compact_json(message_delta),
  )
  out.push(NoWait, Some("message_stop"), "{\"type\":\"message_stop\"}")
  out.reply(request_id)
}

///|
/// The pieces of a stream that sends no text.
let no_pieces : ArrayView[String] = [][:]

///|
/// The delta that opens the arguments of a `tool_use` block: an empty
/// `partial_json`.
let empty_json_delta : String = "{\"type\":\"input_json_delta\",\"partial_json\":\"\"}"

///|
/// The data of the `content_block_start` event of the block at `index`,
/// whose opening content is `block`, given as compact JSON.
fn content_block_start(index : Int, block : String) -> String {
  "{\"type\":\"content_block_start\",\"index\":\{index},\"content_block\":\{block}}"
}

///|
/// The data of a `content_block_delta` event of the block at `index`,
/// whose delta is `delta`, given as compact JSON.
fn content_block_delta(index : Int, delta : String) -> String {
  "{\"type\":\"content_block_delta\",\"index\":\{index},\"delta\":\{delta}}"
}

///|
/// The data of the `content_block_stop` event of the block at `index`.
fn content_block_stop(index : Int) -> String {
  "{\"type\":\"content_block_stop\",\"index\":\{index}}"
}

///|
/// The data of Anthropic Messages' `error` event for `error` with the
/// message `message`: an `error` object with its type and message.
fn messages_error(error : MidStreamError, message : String) -> String {
  let message = @template.compact_json(Json::string(message))
  let kind = @template.compact_json(Json::string(error.kind))
  "{\"type\":\"error\",\"error\":{\"type\":\{kind},\"message\":\{message}}}"
}

///|
/// The `stop_details` of a refusal, whose `category` and `explanation`
/// take their documented value null.
let refusal_details : Json = {
  "type": "refusal",
  "category": Json::null(),
  "explanation": Json::null(),
}

///|
/// Messages' usage member for `usage`: its two counts, with no cache
/// counts, as the replies of the guide on working with messages give it.
fn messages_usage(usage : Usage) -> Json {
  { "input_tokens": count(usage.input), "output_tokens": count(usage.output) }
}

///|
/// The code points a piece of text holds by default.
let default_chunk_size : Int = 4

///|
/// The most pieces a stream cuts from one text or one tool call's
/// arguments: one more than fit within `max_reply_bytes`, since every event
/// that carries a piece takes more than 64 bytes as it is sent. A stream
/// that sends that many is over the bound, and so is one cut after them,
/// so the rest of a longer text is never cut.
let max_pieces : Int = max_reply_bytes / 64 + 1

///|
/// `text` cut into pieces of `size` code points, the last one shorter. They
/// join to exactly `text` and never split a code point, so each one encodes
/// to valid UTF-8 on its own. Empty text has no piece. Only the first
/// `max_pieces` pieces of a longer text are cut.
fn pieces(text : String, size : Int) -> Array[String] {
  let out = []
  // A piece holds no more than the text, whatever the size.
  let piece = StringBuilder(
    size_hint=if size < text.length() { size } else { text.length() },
  )
  let mut count = 0
  for c in text {
    piece.write_char(c)
    count += 1
    if count == size {
      out.push(piece.to_string())
      if out.length() == max_pieces {
        return out
      }
      piece.reset()
      count = 0
    }
  }
  if count > 0 {
    out.push(piece.to_string())
  }
  out
}

///|
/// The pieces of `pieces` that a stream cut after `after` code points of
/// its text sends: none when `after` is 0; otherwise those before the cut,
/// an empty one included, and the piece that reaches the cut, ending there.
/// The pieces after it are not sent, empty ones included. When the pieces
/// hold fewer code points, all of them are sent.
fn pieces_before(pieces : ArrayView[String], after : Int) -> ArrayView[String] {
  if after == 0 {
    return pieces[:0]
  }
  let mut left = after
  for i in 0..<pieces.length() {
    let piece = pieces[i]
    let mut held = 0
    for _ in piece {
      held += 1
    }
    if held == left {
      return pieces[:i + 1]
    }
    if held > left {
      // The piece that holds the cut ends there.
      let sent = pieces[:i].to_owned()
      sent.push(first_code_points(piece, left))
      return sent[:]
    }
    left -= held
  }
  pieces
}

///|
/// The first `count` code points of `text`, which holds more.
fn first_code_points(text : String, count : Int) -> String {
  let out = StringBuilder()
  let mut written = 0
  for c in text {
    if written == count {
      break
    }
    out.write_char(c)
    written += 1
  }
  out.to_string()
}

///|
/// The wait slots of one stream's events, given in the order they are
/// sent.
priv struct Pace {
  /// Whether an event has taken the `first` slot.
  mut started : Bool
}

///|
/// The wait slots of a new stream.
fn Pace::new() -> Pace {
  { started: false, }
}

///|
/// The slot of an event that carries a piece: `first` for the first one,
/// `interval` for each later one.
fn Pace::piece(self : Pace) -> WaitSlot {
  if self.started {
    Interval
  } else {
    self.started = true
    First
  }
}

///|
/// The slot of an event that closes the reply: none after a piece, and
/// `first` for the first closing event of a reply with no piece, so that
/// such a reply waits once before it ends.
fn Pace::closing(self : Pace) -> WaitSlot {
  if self.started {
    NoWait
  } else {
    self.started = true
    First
  }
}

///|
/// Chat Completions' usage member for `usage`: its counts and their total,
/// with the detail objects of the reference's example, their counts 0.
fn chat_usage(usage : Usage) -> Json {
  {
    "prompt_tokens": count(usage.input),
    "completion_tokens": count(usage.output),
    "total_tokens": count(usage.input + usage.output),
    "prompt_tokens_details": { "cached_tokens": 0, "audio_tokens": 0 },
    "completion_tokens_details": {
      "reasoning_tokens": 0,
      "audio_tokens": 0,
      "accepted_prediction_tokens": 0,
      "rejected_prediction_tokens": 0,
    },
  }
}

///|
/// The token count `n` as a JSON number, written as its integer text, so
/// that a total above 2^53 is written exactly.
fn count(n : Int64) -> Json {
  Json::number(n.to_double(), repr=n.to_string())
}

///|
/// What the seed of the ids generator is XORed with: a constant of its own,
/// so that ids draw another sequence than the pick, the Fault decisions and
/// the helpers made from the same draw.
let ids_mask : UInt64 = 0x8EBC6AF09C88C6E3UL

///|
/// The ids generator of a matched request, which every id of its reply
/// draws from: seeded with `draw`, the 64-bit output the request took from
/// its Stub's random source, XOR a fixed constant. So adding an LLM
/// response changes no Fault decision, no pick and no helper output, and
/// `fault.seed` and `--seed` replay its ids.
pub fn ids_generator(draw : UInt64) -> @prng.Generator {
  @prng.Generator(draw ^ ids_mask)
}
