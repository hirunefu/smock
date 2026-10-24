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
fn pick_response(ordinary : @definitions.Ordinary, draw : UInt64) -> Int32? {
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
/// - an LLM reply is written in its API's wire form, from its strings as
///   written or, with `template` on, rendered after the header values,
///   with Content-Type the one that form takes, its model read from the
///   request's JSON body unless it gives its own, its time `now`, and its
///   ids drawn from the request's ids generator, made from `draw`. A tool
///   call id that renders as an earlier one's is a render error. Its
///   request-id header field follows the response's, unless the response
///   gives one of that name. A stream's events wait as its `timing` says,
///   the waits drawn from the request's waits generator, made from `draw`
///   too. A reply that takes more than `@llm.max_reply_bytes` once encoded
///   is a render error at the `llm` field, and its waits are not drawn.
///
/// Every template of the response renders in one rendering for the
/// request: `context`, the one that the Stub's Variables left, or, without
/// one, the request's first rendering, made here from `now`, `draw`,
/// `vars`, `data` and `copies` as `first_context` makes it, the first time
/// a template needs it. A response as written makes none.
///
/// Raises `RenderError` when a template cannot be rendered, a rule across
/// rendered values is broken, or an LLM reply is over the size bound: the
/// request then gets `template_failed`.
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
  // Room for the fields that byte ranges add after the response's, or for
  // the Content-Type and the request-id field of an LLM reply, and for the
  // Smock-Mock field the Default Mock adds.
  let room = if response.serves_ranges || response.body is Llm(_) {
    3
  } else {
    2
  }
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
      let strings = match llm.strings {
        Written(strings) => strings
        Templated(templates) => {
          let rendering = match context {
            Some(rendering) => rendering
            None => first_context(incoming, now~, draw~, vars~, data~, copies~)
          }
          render_strings(templates, rendering)
        }
      }
      let reply = @llm.reply(
        llm.declaration,
        strings,
        request=incoming.body_json(),
        now~,
        ids=@llm.ids_generator(draw),
      )
      if reply.check_size() is Err(message) {
        raise @template.RenderError(at=llm.pointer, message~)
      }
      set_content_type(headers, reply.content_type)
      add_unless_given(headers, reply.request_id)
      let body : Body = match reply.body {
        Json(json) => Bytes(json)
        Events(events) => {
          let waits = draw_waits(events, llm.timing, draw)
          reply.complete(waits)
          Events(sse_events(events, waits))
        }
      }
      { status, headers, body, delay_ms: 0, fault: None, }
    }
  }
}

///|
/// Renders `templates`, the strings of an LLM reply with `template` on, in
/// `context`, after the response's header values, in the order the
/// helpers draw: `id`, `model`, the text or each chunk, each tool call's
/// `id`, `name` and `arguments`, then the mid-stream error's `message`.
/// Each chunk gives one piece; the text is cut into pieces after it is
/// rendered, and a message that renders empty is sent empty.
///
/// Raises `RenderError` when a template cannot be rendered, or when a tool
/// call's rendered id is an earlier call's, since the call ids of a reply
/// must differ.
fn render_strings(
  templates : @definitions.LlmTemplates,
  context : @template.Context,
) -> @llm.Strings raise @template.RenderError {
  let id = match templates.id {
    Some(id) => Some(id.render(context))
    None => None
  }
  let model = match templates.model {
    Some(model) => Some(model.render(context))
    None => None
  }
  let mut text = ""
  let mut chunks = None
  match templates.text {
    Whole(whole) => text = whole.render(context)
    Chunks(pieces) => {
      let rendered = Array(capacity=pieces.length())
      for i in 0..<pieces.length() {
        rendered.push(pieces[i].render(context))
      }
      chunks = Some(ReadOnlyArray::from_array(rendered))
    }
  }
  let calls = templates.tool_calls
  let tool_calls : Array[@llm.ToolCall] = Array(capacity=calls.length())
  for i in 0..<calls.length() {
    let call = calls[i]
    let call_id = match call.id {
      Some(template) => {
        let rendered = template.render(context)
        for j in 0..<i {
          if tool_calls[j].id is Some(earlier) &&
            earlier == rendered &&
            calls[j].id is Some(first) {
            raise @template.RenderError(
              at=template.pointer,
              message="the tool call id \{rendered.escape()} is already used at \{first.pointer}",
            )
          }
        }
        Some(rendered)
      }
      None => None
    }
    let name = call.name.render(context)
    let arguments = match call.arguments {
      Text(arguments) => arguments.render(context)
      Json(arguments) => @utf8.decode_lossy(arguments.render(context))
    }
    tool_calls.push(
      @llm.ToolCall(name~, arguments=Json::string(arguments), id?=call_id),
    )
  }
  let error_message = match templates.error_message {
    Some(message) => Some(message.render(context))
    None => None
  }
  @llm.Strings(
    text~,
    chunks?,
    id?,
    model?,
    tool_calls=ReadOnlyArray::from_array(tool_calls),
    error_message?,
  )
}

///|
/// What the seed of the waits generator is XORed with, the request's one
/// draw: a constant of its own, so that the waits draw another sequence
/// than the pick, the Fault decisions, the helpers and the ids made from
/// the same draw.
let waits_mask : UInt64 = 0x589965CC75374CC3

///|
/// The waits of a stream none of whose events waits: none at all.
let no_waits : FixedArray[Int32] = []

///|
/// The waits of the events of an LLM reply's stream, in milliseconds, one
/// per event in order, for a request whose one draw is `draw`. An event
/// whose wait slot is `first` waits a wait drawn from `timing.first`, one
/// whose slot is `interval` a wait drawn from `timing.interval`, and any
/// other none. Each wait is drawn on its own, in order, with the delay
/// Fault's sampler, from the request's waits generator, seeded with `draw`
/// XOR `waits_mask`. A wait that `timing` leaves out is none and draws
/// nothing. A reply without `timing` draws nothing at all, and its waits
/// are `no_waits`.
fn draw_waits(
  events : Array[@llm.Event],
  timing : @definitions.LlmTiming,
  draw : UInt64,
) -> FixedArray[Int32] {
  if timing.first is None && timing.interval is None {
    return no_waits
  }
  let waits = FixedArray::make(events.length(), 0)
  let generator = @prng.Generator(draw ^ waits_mask)
  for i in 0..<events.length() {
    let distribution = match events[i].wait {
      NoWait => None
      First => timing.first
      Interval => timing.interval
    }
    if distribution is Some(distribution) {
      waits[i] = sample(distribution, generator)
    }
  }
  waits
}

///|
/// The Server-Sent Events of an LLM reply's stream, in order, as an `events`
/// response sends them: each one's type and data, with no ID, after its
/// wait in `waits`, in milliseconds, or at once when `waits` is empty.
fn sse_events(
  events : Array[@llm.Event],
  waits : FixedArray[Int32],
) -> ReadOnlyArray[@definitions.SseEvent] {
  let waited = waits.length() > 0
  let out = Array(capacity=events.length())
  for i in 0..<events.length() {
    let event = events[i]
    out.push(
      @definitions.SseEvent(
        delay_ms=if waited { waits[i] } else { 0 },
        event=event.event,
        id=None,
        data=event.data,
      ),
    )
  }
  ReadOnlyArray::from_array(out)
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
    if !is_name(field.0, "content-type") {
      headers[kept] = field
      kept += 1
    }
  }
  headers.truncate(kept)
  headers.insert(0, ("Content-Type", media_type))
}

///|
/// Adds `field`, whose name is in lower case, after the fields of
/// `headers`, unless one of them has its name, in any case: a field the
/// Stub gives then takes its place.
fn add_unless_given(
  headers : Array[(String, String)],
  field : (String, String),
) -> Unit {
  for i in 0..<headers.length() {
    if is_name(headers[i].0, field.0) {
      return
    }
  }
  headers.push(field)
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
  status : Int32,
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
fn json_failure(status : Int32, body : Json) -> ResponsePlan {
  {
    status,
    headers: [("Content-Type", "application/json")],
    body: Bytes(@template.compact_json_bytes(body)),
    delay_ms: 0,
    fault: None,
  }
}
