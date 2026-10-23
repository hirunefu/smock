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
} derive(Debug, Eq)

///|
/// The strings of a reply whose text is `text`.
pub fn Strings::Strings(text~ : String) -> Strings {
  { text, }
}

///|
/// What smock sends for an LLM response, beside its status and the Stub's
/// own header fields.
pub struct Reply {
  /// The Content-Type smock sets, in place of any the Stub gives.
  content_type : String
  /// The body: the reply as one JSON document, in UTF-8.
  body : Bytes
}

///|
/// The reply that `declaration`, with its strings `strings`, gives to a
/// request whose body is the JSON `request`, or `None` when the body is
/// not JSON, received at `now` (milliseconds since the Unix epoch). Its ids
/// draw from `ids`, the request's ids generator.
pub fn reply(
  declaration : Declaration,
  strings : Strings,
  request~ : Json?,
  now~ : Int64,
  ids~ : @prng.Generator,
) -> Reply {
  let ids = draw_ids(ids)
  let created = now / 1000L
  let model = request_model(request)
  match declaration.api {
    OpenaiChat => chat_reply(strings, ids~, created~, model~)
  }
}

///|
/// The ids of one reply, each drawn in its slot of a fixed order: the
/// reply's, then the Responses message item's. Every slot draws, whether
/// or not the reply's API uses it, so that an id keeps its draws whatever
/// the API.
priv struct Ids {
  /// The reply's id, without its prefix.
  reply : String
}

///|
/// Draws the ids of one reply from `ids`, slot by slot.
fn draw_ids(ids : @prng.Generator) -> Ids {
  let reply = draw_id(ids)
  // The Responses message item's slot.
  ignore(draw_id(ids))
  { reply, }
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
/// from `ids`, `created` (seconds since the Unix epoch) and `model`: one
/// `chat.completion` object, in the members and the order of the
/// reference's example, with the example's fixed values.
fn chat_reply(
  strings : Strings,
  ids~ : Ids,
  created~ : Int64,
  model~ : String,
) -> Reply {
  let message : Json = {
    "role": "assistant",
    "content": Json::string(strings.text),
    "refusal": Json::null(),
    "annotations": [],
  }
  let body : Json = {
    "id": Json::string("chatcmpl-" + ids.reply),
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
    body: @template.compact_json_bytes(body),
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
