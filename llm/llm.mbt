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
} derive(Debug, Eq)

///|
/// The API's name, as `api` gives it.
pub fn Api::name(self : Api) -> String {
  match self {
    OpenaiChat => "openai-chat"
  }
}

///|
/// The load check of `api`: the API that `value` names, or the message of
/// the load error when it names none, which lists the names it can take.
pub fn read_api(value : Json) -> Result[Api, String] {
  match value {
    String("openai-chat") => Ok(OpenaiChat)
    _ => Err("must be \"openai-chat\"")
  }
}

///|
/// What an `llm` field declares, apart from its strings: the parts that are
/// never templates, checked when the definitions are loaded or the Stub is
/// added.
pub struct Declaration {
  api : Api
} derive(Debug, Eq)

///|
/// A declaration for the API `api`.
pub fn Declaration::Declaration(api~ : Api) -> Declaration {
  { api, }
}

///|
/// The strings of a declaration, as written, or rendered for the request.
pub struct Strings {
  /// The text of the reply: empty when left out.
  text : String
  /// The reply's id, sent as written, or `None` for a generated one.
  id : String?
  /// The reply's model, or `None` for the request's.
  model : String?
} derive(Debug, Eq)

///|
/// The strings of a reply whose text is `text`, whose id is `id` when given
/// and whose model is `model` when given.
pub fn Strings::Strings(
  text~ : String,
  id? : String,
  model? : String,
) -> Strings {
  { text, id, model, }
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
/// otherwise the JSON reply. Its ids draw from `ids`, the request's ids
/// generator, and the reply's id is the strings' `id` when given. Its
/// model is the strings' `model` when given, otherwise the request's.
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
  let streams = asks_to_stream(request)
  match declaration.api {
    OpenaiChat => {
      let id = reply_id(strings, "chatcmpl-", ids)
      let request_id = ("x-request-id", "req_" + ids.request)
      if streams {
        chat_stream(strings, id~, created~, model~, request_id~)
      } else {
        chat_reply(strings, id~, created~, model~, request_id~)
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
/// Whether the request whose body is the JSON `request` asks for the
/// stream: its body is a JSON object with `stream` exactly `true`. A body
/// that is not JSON, a missing `stream`, `false` and the string `"true"`
/// ask for the JSON reply.
fn asks_to_stream(request : Json?) -> Bool {
  request is Some(Object(members)) && members.get("stream") is Some(True)
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
  /// The request id of the request-id header, without its prefix.
  request : String
}

///|
/// Draws the ids of one reply from `ids`, slot by slot.
fn draw_ids(ids : @prng.Generator) -> Ids {
  let reply = draw_id(ids)
  // The Responses message item's slot.
  ignore(draw_id(ids))
  // The tool calls' slots go here, before the request-id header's.
  let request = draw_id(ids)
  { reply, request, }
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
/// The Chat Completions reply with the strings `strings`, the reply's id
/// `id`, `created` (seconds since the Unix epoch), `model` and the
/// request-id header field `request_id`: one `chat.completion` object, in
/// the members and the order of the reference's example, with the
/// example's fixed values.
fn chat_reply(
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
        "finish_reason": "stop",
      },
    ],
    "usage": chat_usage(input=0, output=0),
    "service_tier": "default",
  }
  {
    content_type: "application/json",
    request_id,
    body: Json(@template.compact_json_bytes(body)),
  }
}

///|
/// The Chat Completions stream with the strings `strings`, the reply's id
/// `id`, `created` (seconds since the Unix epoch), `model` and the
/// request-id header field `request_id`:
/// `chat.completion.chunk` events with no `event:` line, each one `data:`
/// line of compact JSON with the same id, `created` and model. The opening
/// chunk gives the assistant's role and an empty content, one chunk follows
/// per piece of the text, then the closing chunk gives the finish reason,
/// and `[DONE]` ends the stream.
fn chat_stream(
  strings : Strings,
  id~ : String,
  created~ : Int64,
  model~ : String,
  request_id~ : (String, String),
) -> Reply {
  let chunks = ChatChunks::new(id~, created~, model~)
  let pieces = pieces(strings.text, default_chunk_size)
  let pace = Pace::new()
  let events = Array(capacity=pieces.length() + 3)
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
    data: chunks.chunk("{}", "\"stop\""),
  })
  events.push({ wait: NoWait, event: None, data: "[DONE]", })
  { content_type: "text/event-stream", request_id, body: Events(events), }
}

///|
/// The chunks of one Chat Completions stream, which share their id,
/// `created` and model.
priv struct ChatChunks {
  /// The compact JSON every chunk begins with, up to its delta: the id,
  /// `object`, `created`, the model and the choice's `index`.
  head : String
}

///|
/// The chunks of the stream whose id is `id`, `created` (seconds since the
/// Unix epoch) and `model`.
fn ChatChunks::new(
  id~ : String,
  created~ : Int64,
  model~ : String,
) -> ChatChunks {
  let created = @template.compact_json(Json::number(created.to_double()))
  let id = @template.compact_json(Json::string(id))
  let model = @template.compact_json(Json::string(model))
  {
    head: "{\"id\":\{id},\"object\":\"chat.completion.chunk\",\"created\":\{created},\"model\":\{model},\"choices\":[{\"index\":0,\"delta\":",
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
  let tail = ",\"logprobs\":null,\"finish_reason\":"
  let out = StringBuilder(
    size_hint=self.head.length() +
      delta.length() +
      tail.length() +
      finish_reason.length() +
      3,
  )
  out.write_string(self.head)
  out.write_string(delta)
  out.write_string(tail)
  out.write_string(finish_reason)
  out.write_string("}]}")
  out.to_string()
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
  let piece = StringBuilder(size_hint=size)
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
/// Chat Completions' usage of `input` and `output` tokens, with the detail
/// objects of the reference's example, their counts 0.
fn chat_usage(input~ : Int64, output~ : Int64) -> Json {
  {
    "prompt_tokens": Json::number(input.to_double()),
    "completion_tokens": Json::number(output.to_double()),
    "total_tokens": Json::number((input + output).to_double()),
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
