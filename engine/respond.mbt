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
/// The pick, a step of the match decision: the index, among `stub`'s
/// `responses`, of the one a matched request whose one draw is `draw` gets.
///
/// The pick draws from a generator of its own, seeded with `draw` XOR
/// `pick_mask`: a number below the sum of the weights, by rejection
/// sampling, as `fake.pick` does. It takes the response whose share of the
/// running total holds that number, in the order written. A Stub with
/// `response` takes no pick and draws nothing: `None`, for its one
/// response.
fn pick_response(stub : @definitions.Stub, draw : UInt64) -> Int? {
  guard stub.total_weight is Some(total) else { return None }
  let mut n = @prng.Generator(draw ^ pick_mask)
    .below(total.to_uint64())
    .to_int()
  let responses = stub.responses
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
/// The plan of a response with `template` on, of the Stub with the ID
/// `stub`, rendered in `context`, the response's rendering for the
/// request, without Faults. `status` is the response's status.
///
/// When a template cannot be rendered, the plan is a 500 that says so, and
/// the error comes with it.
fn respond(
  stub : String,
  status : Int,
  template : @definitions.ResponseTemplate,
  context : @template.Context,
) -> (ResponsePlan, TemplateError?) {
  try render_template(status, template, context) catch {
    RenderError(at~, message~) => {
      let error = { at, message, }
      (template_failed(stub, error), Some(error))
    }
  } noraise {
    plan => (plan, None)
  }
}

///|
/// Renders `template`: header values in the order written, then the body or
/// the events in order.
fn render_template(
  status : Int,
  template : @definitions.ResponseTemplate,
  context : @template.Context,
) -> ResponsePlan raise @template.RenderError {
  let headers = []
  for header in template.headers {
    headers.push((header.0, header.1.render(context)))
  }
  let body : Body = match template.body {
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
      Events(ReadOnlyArray::from_array(rendered))
    }
  }
  let headers = match body {
    // Server-Sent Events are always sent as text/event-stream.
    Events(_) =>
      [
        ("Content-Type", "text/event-stream"),
        ..headers.filter(header => header.0.to_lower() != "content-type"),
      ]
    Bytes(_) => headers
  }
  { status, headers, body, delay_ms: 0, fault: None, }
}

///|
/// The response to a request whose template could not be rendered: 500,
/// with what went wrong.
fn template_failed(stub : String, error : TemplateError) -> ResponsePlan {
  let body : Json = {
    "error": "template failed",
    "stub": Json::string(stub),
    "at": Json::string(error.at),
    "message": Json::string(error.message),
  }
  {
    status: 500,
    headers: [("Content-Type", "application/json")],
    body: Bytes(@template.compact_json_bytes(body)),
    delay_ms: 0,
    fault: None,
  }
}
