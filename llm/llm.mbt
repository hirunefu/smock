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
} derive(Debug, Eq)

///|
/// The API's name, as `api` gives it.
pub fn Api::name(self : Api) -> String {
  match self {
    OpenaiChat => "openai-chat"
    OpenaiResponses => "openai-responses"
  }
}

///|
/// The load check of `api`: the API that `value` names, or the message of
/// the load error when it names none, which lists the names it can take.
pub fn read_api(value : Json) -> Result[Api, String] {
  match value {
    String("openai-chat") => Ok(OpenaiChat)
    String("openai-responses") => Ok(OpenaiResponses)
    _ => Err("must be \"openai-chat\" or \"openai-responses\"")
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
  let listed = StringBuilder()
  for i, word in words {
    if i > 0 {
      listed.write_string(if i == words.length() - 1 { " or " } else { ", " })
    }
    listed.write_string("\"\{word}\"")
  }
  Err("must be a stop reason of \{api.name()}: \{listed}")
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
} derive(Debug, Eq)

///|
/// A declaration for the API `api` whose pieces of text hold `chunk_size`
/// code points, 4 by default, and whose reply reports the token counts
/// `usage`, both 0 by default, and the stop reason `stop_reason`, derived
/// when it is left out. The definitions check that `chunk_size` is from 1
/// to `max_chunk_size`.
pub fn Declaration::Declaration(
  api~ : Api,
  chunk_size? : Int = default_chunk_size,
  usage? : Usage = Usage(input=0, output=0),
  stop_reason? : StopReason,
) -> Declaration {
  { api, chunk_size, usage, stop_reason, }
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
} derive(Debug, Eq)

///|
/// The strings of a reply whose text is `text`, empty by default; or, with
/// `chunks`, whose pieces are its elements and whose text is their join,
/// in place of `text`. The definitions refuse `text` beside `chunks`. Its
/// id is `id` when given and its model `model` when given.
pub fn Strings::Strings(
  text? : String = "",
  chunks? : ReadOnlyArray[String],
  id? : String,
  model? : String,
) -> Strings {
  match chunks {
    Some(chunks) => { text: chunks.join(""), chunks: Some(chunks), id, model, }
    None => { text, chunks: None, id, model, }
  }
}

///|
/// The pieces of the text that a stream sends, in order: the elements of
/// `chunks`, or the text cut into pieces of `size` code points.
fn Strings::text_pieces(self : Strings, size : Int) -> ArrayView[String] {
  match self.chunks {
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
/// otherwise the JSON reply. An `openai-responses` declaration gives the
/// JSON reply to both, since its stream is not written yet. Its ids draw
/// from `ids`, the request's ids generator, and the reply's id is the
/// strings' `id` when given. Its model is the strings' `model` when given,
/// otherwise the request's.
pub fn reply(
  declaration : Declaration,
  strings : Strings,
  request~ : Json?,
  now~ : Int64,
  ids~ : @prng.Generator,
) -> Reply {
  let ids = draw_ids(ids)
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
          request_id~,
        )
      } else {
        chat_reply(declaration, strings, id~, created~, model~, request_id~)
      }
    }
    // A streamed request gets the JSON reply too, for now.
    OpenaiResponses =>
      responses_reply(
        declaration,
        strings,
        id=reply_id(strings, "resp_", ids),
        message_id="msg_" + ids.message,
        created~,
        model~,
        request~,
        request_id=("x-request-id", "req_" + ids.request),
      )
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
/// completed with them. No Chat Completions event does, so its stream is
/// left as it is, and a JSON reply has no wait.
pub fn Reply::complete(self : Reply, waits : FixedArray[Int]) -> Unit {
  // Nothing to complete yet: only Chat Completions is written, and an API
  // whose events depend on the waits completes them here.
  ignore(self)
  ignore(waits)
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
/// The ids of one reply, each drawn in its slot of a fixed order: the
/// reply's, then the Responses message item's, then the request-id
/// header's, last. Every slot draws, whether or not the reply's API uses
/// it or the Stub fixes its id, so that fixing one id changes no other and
/// an id keeps its draws whatever the API.
priv struct Ids {
  /// The reply's id, without its prefix.
  reply : String
  /// The Responses message item's id, without its prefix.
  message : String
  /// The request id of the request-id header, without its prefix.
  request : String
}

///|
/// Draws the ids of one reply from `ids`, slot by slot.
fn draw_ids(ids : @prng.Generator) -> Ids {
  let reply = draw_id(ids)
  let message = draw_id(ids)
  // The tool calls' slots go here, before the request-id header's.
  let request = draw_id(ids)
  { reply, message, request, }
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
/// the reply's id `id`, `created` (seconds since the Unix epoch), `model`
/// and the request-id header field `request_id`: one `chat.completion`
/// object, in the members and the order of the reference's example, with
/// the example's fixed values.
fn chat_reply(
  declaration : Declaration,
  strings : Strings,
  id~ : String,
  created~ : Int64,
  model~ : String,
  request_id~ : (String, String),
) -> Reply {
  let message : Json = {
    "role": "assistant",
    "content": Json::string(strings.text),
    "refusal": Json::null(),
    "annotations": [],
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
        "finish_reason": Json::string(chat_finish_reason(declaration)),
      },
    ],
    "usage": chat_usage(declaration.usage),
    "service_tier": "default",
  }
  {
    content_type: "application/json",
    request_id,
    body: Json(@template.compact_json_bytes(body)),
  }
}

///|
/// The finish reason of `declaration`'s Chat Completions reply: the stop
/// reason written, or the one derived from the content when none is. A
/// word of the API needs no escaping in JSON.
fn chat_finish_reason(declaration : Declaration) -> String {
  match declaration.stop_reason {
    Some(reason) => reason.word
    // Derived: a reply with no tool call stops.
    None => "stop"
  }
}

///|
/// The Chat Completions stream of `declaration` with the strings
/// `strings`, whose text is cut into pieces of the declaration's chunk
/// size unless they give its pieces, the reply's id `id`, `created`
/// (seconds since the Unix epoch), `model` and the request-id header field
/// `request_id`:
/// `chat.completion.chunk` events with no `event:` line, each one `data:`
/// line of compact JSON with the same id, `created` and model. The opening
/// chunk gives the assistant's role and an empty content, one chunk follows
/// per piece of the text, then the closing chunk gives the finish reason,
/// and `[DONE]` ends the stream. With `usage`, every chunk carries
/// `"usage":null`, and the usage chunk, with no choice, comes before
/// `[DONE]`.
fn chat_stream(
  declaration : Declaration,
  strings : Strings,
  id~ : String,
  created~ : Int64,
  model~ : String,
  usage~ : Bool,
  request_id~ : (String, String),
) -> Reply {
  let chunks = ChatChunks::new(id~, created~, model~, usage~)
  let pieces = strings.text_pieces(declaration.chunk_size)
  let pace = Pace::new()
  let events = Array(capacity=pieces.length() + 4)
  events.push({
    wait: NoWait,
    event: None,
    data: chunks.chunk("{\"role\":\"assistant\",\"content\":\"\"}", "null"),
  })
  for piece in pieces {
    let delta = "{\"content\":\{@template.compact_json(Json::string(piece))}}"
    events.push({
      wait: pace.piece(),
      event: None,
      data: chunks.chunk(delta, "null"),
    })
  }
  events.push({
    wait: pace.closing(),
    event: None,
    data: chunks.chunk("{}", "\"\{chat_finish_reason(declaration)}\""),
  })
  if usage {
    events.push({
      wait: NoWait,
      event: None,
      data: chunks.usage_chunk(declaration.usage),
    })
  }
  events.push({ wait: NoWait, event: None, data: "[DONE]", })
  { content_type: "text/event-stream", request_id, body: Events(events), }
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
/// since the Unix epoch), `model`, the request's JSON body `request` and
/// the request-id header field `request_id`: one Response object, in the
/// members and the order of the reference's examples, with the example's
/// fixed values. A written stop reason is an incomplete reason, which makes
/// the reply and its message item incomplete.
fn responses_reply(
  declaration : Declaration,
  strings : Strings,
  id~ : String,
  message_id~ : String,
  created~ : Int64,
  model~ : String,
  request~ : Json?,
  request_id~ : (String, String),
) -> Reply {
  let status = match declaration.stop_reason {
    Some(_) => "incomplete"
    None => "completed"
  }
  let message : Json = {
    "id": Json::string(message_id),
    "type": "message",
    "status": Json::string(status),
    "role": "assistant",
    "content": [
      {
        "type": "output_text",
        "text": Json::string(strings.text),
        "annotations": [],
        "logprobs": [],
      },
    ],
  }
  let body = response_object(
    declaration,
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
    output=[message],
    usage=responses_usage(declaration.usage),
  )
  {
    content_type: "application/json",
    request_id,
    body: Json(@template.compact_json_bytes(body)),
  }
}

///|
/// The Response object of `declaration` whose id is `id`, `created_at`
/// `created` (seconds since the Unix epoch) and model `model`, with the
/// members `status`, `completed_at`, `output` and `usage` given, and the
/// settings it copies from `request`, the request's JSON body. Its members
/// and their order are the reference's examples', and the members the
/// examples do not show, which the request may set, sit in the alphabetical
/// order the examples keep. Each setting is copied as given, without being
/// interpreted; one the request leaves out takes the example's value, or is
/// left out when the examples do not show it. `service_tier` keeps the
/// example's value, and `conversation` is not copied.
fn response_object(
  declaration : Declaration,
  id~ : String,
  created~ : Int64,
  model~ : String,
  request~ : Json?,
  status~ : String,
  completed_at~ : Json,
  output~ : Json,
  usage~ : Json,
) -> Json {
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
  object["incomplete_details"] = match declaration.stop_reason {
    Some(reason) => { "reason": Json::string(reason.word) }
    None => Json::null()
  }
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
  Json::object(object)
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
/// The code points a piece of text holds by default.
let default_chunk_size : Int = 4

///|
/// `text` cut into pieces of `size` code points, the last one shorter. They
/// join to exactly `text` and never split a code point, so each one encodes
/// to valid UTF-8 on its own. Empty text has no piece.
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
