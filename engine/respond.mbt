// A matched Stub's response: the pick of one of its responses, and its
// plan, as written or rendered from its templates for the request.
// Templates were parsed when the definitions were loaded or the Stub was
// added; here they are only rendered.

///|
/// A template that could not be rendered for a request: a JSON Pointer to
/// the field, within the Stub, and what went wrong. The client then gets
/// a 500, and the Journal entry records it.
pub(all) struct TemplateError {
  at : String
  message : String
} derive(Debug, Eq)

///|
/// The `TemplateError` schema of the Admin API document.
pub impl ToJson for TemplateError with fn to_json(self) {
  { "at": Json::string(self.at), "message": Json::string(self.message) }
}

///|
/// What the pick's generator is seeded with, XOR the request's one draw. It
/// differs from the helpers' constant, so the pick, the Fault decisions and
/// the helpers each draw their own numbers.
let pick_mask : UInt64 = 0xE7037ED1A0B428DB

///|
/// The pick, a step of the match decision: the index, among the `responses`
/// of `ordinary`, of the one a matched request whose one draw is `draw`
/// gets. `ordinary` is what the matched Stub serves.
///
/// The pick draws from a generator of its own, seeded with `draw` XOR
/// `pick_mask`: a number below the sum of the weights, by rejection
/// sampling, as `fake.pick` does. It takes the response whose share of the
/// running total holds that number, in the order written. A Stub with
/// `response` takes no pick and draws nothing: `None`, for its one
/// response.
fn pick_response(ordinary : @definitions.Ordinary, draw : UInt64) -> Int? {
  guard ordinary.total_weight is Some(total) else { return None }
  let mut n = @prng.Generator(draw ^ pick_mask)
    .below(total.to_uint64())
    .to_int()
  let responses = ordinary.responses
  for i in 0..<responses.length() {
    let weight = responses[i].weight
    if n < weight {
      return Some(i)
    }
    n -= weight
  }
  // `total` is the sum of the weights, so the loop has returned.
  abort("the pick ran past the last response")
}

///|
/// Step 5 of the match decision, rendering and planning: the plan of
/// `response`, one of a Stub's responses, for the request `incoming`,
/// without Faults. Its header values, as written or rendered, come first,
/// then its body, planned by its kind:
///
/// - bytes as written are sent as they are, or, when the response serves
///   byte ranges, as the request's Range field asks;
/// - Server-Sent Events as written are streamed as they are;
/// - a body with `template` on is rendered;
/// - an LLM reply is written in its API's wire form, with Content-Type the
///   one that form takes, its model read from the request's JSON body, its
///   time `now`, and its ids drawn from the request's ids generator, made
///   from `draw`.
///
/// Every template of the response renders in one rendering for the
/// request: `context`, the one that the Stub's Variables left, or, without
/// one, the request's first rendering, made here from `now`, `draw`,
/// `vars`, `data` and `copies` as `first_context` makes it, the first time
/// a template needs it. A response as written makes none.
///
/// Raises `RenderError` when a template cannot be rendered: the request
/// then gets `template_failed`.
fn plan_response(
  response : @definitions.Response,
  incoming : Incoming,
  context : @template.Context?,
  now~ : Int64,
  draw~ : UInt64,
  vars~ : Map[String, Json]?,
  data~ : Map[String, Json],
  copies~ : Map[String, Json]?,
) -> ResponsePlan raise @template.RenderError {
  let status = response.status
  let mut context = context
  // Room for the fields that byte ranges add after the response's, and for
  // the Smock-Mock field the Default Mock adds.
  let room = if response.serves_ranges { 3 } else { 2 }
  let headers = match response.headers {
    Written(fields) => {
      let headers = Array(capacity=fields.length() + room)
      for i in 0..<fields.length() {
        headers.push(fields[i])
      }
      headers
    }
    Templated(fields) => {
      let rendering = match context {
        Some(rendering) => rendering
        None => first_context(incoming, now~, draw~, vars~, data~, copies~)
      }
      context = Some(rendering)
      let headers = Array(capacity=fields.length() + room)
      for i in 0..<fields.length() {
        let field = fields[i]
        headers.push((field.0, field.1.render(rendering)))
      }
      headers
    }
  }
  match response.body {
    Bytes(bytes) =>
      if response.serves_ranges {
        range_response(status, headers, bytes, incoming.request)
      } else {
        { status, headers, body: Bytes(bytes), delay_ms: 0, fault: None, }
      }
    Events(events) => {
      set_content_type(headers, "text/event-stream")
      { status, headers, body: Events(events), delay_ms: 0, fault: None, }
    }
    Template(template) => {
      let rendering = match context {
        Some(rendering) => rendering
        None => first_context(incoming, now~, draw~, vars~, data~, copies~)
      }
      render_body(status, headers, template, rendering)
    }
    Llm(llm) => {
      let reply = @llm.reply(
        llm.declaration,
        llm.strings,
        request=incoming.body_json(),
        now~,
        ids=@llm.ids_generator(draw),
      )
      set_content_type(headers, reply.content_type)
      { status, headers, body: Bytes(reply.body), delay_ms: 0, fault: None, }
    }
  }
}

///|
/// Gives `headers` the Content-Type `media_type`, which a kind of body sets
/// whatever the Stub gives: it comes first, in place of every Content-Type
/// field, and the other fields follow in order. It needs room for one field
/// more only when `headers` has no Content-Type.
fn set_content_type(
  headers : Array[(String, String)],
  media_type : String,
) -> Unit {
  let mut kept = 0
  for i in 0..<headers.length() {
    let field = headers[i]
    if field.0.to_lower() != "content-type" {
      headers[kept] = field
      kept += 1
    }
  }
  headers.truncate(kept)
  headers.insert(0, ("Content-Type", media_type))
}

///|
/// The first rendering for the request `incoming`, received at `now`
/// (milliseconds since the Unix epoch), whose one draw is `draw`: its
/// helpers draw from the request's helper generator, made from `draw`,
/// `vars.NAME` reads `vars`, and `data.NAME` reads the copy in `copies`, or
/// else the initial value in `data`, each by name. Every rendering for the
/// request that follows from it reads the same data.
fn first_context(
  incoming : Incoming,
  now~ : Int64,
  draw~ : UInt64,
  vars~ : Map[String, Json]?,
  data~ : Map[String, Json],
  copies~ : Map[String, Json]?,
) -> @template.Context {
  @template.Context::new(
    template_input(incoming),
    now~,
    rand=@template.helper_generator(draw),
    vars?,
    data~,
    copies?,
  )
}

///|
/// The request as templates see it.
fn template_input(incoming : Incoming) -> @template.Input {
  {
    meth: incoming.request.meth,
    path: incoming.path,
    query: incoming.query_parameters(),
    headers: incoming.request.headers,
    body: incoming.request.body,
  }
}

///|
/// Renders `template`, the body of a response with `template` on, in
/// `context`, after the response's header values: the body, or the events
/// in order. The plan is `status` with the header fields `headers`, and
/// Server-Sent Events are always sent as text/event-stream.
fn render_body(
  status : Int,
  headers : Array[(String, String)],
  template : @definitions.BodyTemplate,
  context : @template.Context,
) -> ResponsePlan raise @template.RenderError {
  let body : Body = match template {
    Text(text) => Bytes(@utf8.encode(text.render(context)))
    Json(json) => Bytes(json.render(context))
    Events(events) => {
      let rendered = []
      for event in events {
        context.advance(event.delay_ms)
        let event_type = match event.event {
          Some(text) => Some(text.render(context))
          None => None
        }
        let id = match event.id {
          Some(text) => Some(text.render(context))
          None => None
        }
        let data = match event.data {
          Text(text) => text.render(context)
          Json(json) => @utf8.decode_lossy(json.render(context))
        }
        rendered.push(
          @definitions.SseEvent(
            delay_ms=event.delay_ms,
            event=event_type,
            id~,
            data~,
          ),
        )
      }
      set_content_type(headers, "text/event-stream")
      Events(ReadOnlyArray::from_array(rendered))
    }
  }
  { status, headers, body, delay_ms: 0, fault: None, }
}

///|
/// The response to a request whose template could not be rendered: 500,
/// with what went wrong.
fn template_failed(stub : String, error : TemplateError) -> ResponsePlan {
  json_failure(500, {
    "error": "template failed",
    "stub": Json::string(stub),
    "at": Json::string(error.at),
    "message": Json::string(error.message),
  })
}

///|
/// A response of smock's own that says what went wrong: `status`, with
/// `body` in compact JSON, as `application/json`, and no delay or Fault.
fn json_failure(status : Int, body : Json) -> ResponsePlan {
  {
    status,
    headers: [("Content-Type", "application/json")],
    body: Bytes(@template.compact_json_bytes(body)),
    delay_ms: 0,
    fault: None,
  }
}
