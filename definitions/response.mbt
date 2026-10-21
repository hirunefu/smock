// Reading a Stub's response: its status, its headers, and a body given
// inline, from a body file, as JSON or as Server-Sent Events. With
// `template` on, the header values, the body and the events are templates,
// parsed here, when the definition set is loaded or the Stub is added, and
// rendered for each request by the engine.

///|
/// The body of a response, as written: which field gives it, its JSON
/// Pointer and its value.
priv enum BodyField {
  NoBody
  Inline(String, String)
  File(String, Bytes)
  JsonBody(String, Json)
  EventList(Array[EventDecl])
}

///|
/// A Server-Sent Event as written.
priv struct EventDecl {
  delay_ms : Int
  /// The event type and its JSON Pointer.
  event : (String, String)?
  /// The event ID and its JSON Pointer.
  id : (String, String)?
  /// `data` or `json`, and its JSON Pointer.
  data : EventValue
}

///|
priv enum EventValue {
  NoData
  Data(String, String)
  JsonData(String, Json)
}

///|
/// Reads the `responses` of the Stub at `stub_pointer`: the value `json` at
/// `pointer`, 1 to `max_responses` responses, each the shape of `response`
/// plus `weight`, an integer from 1 to `max_weight`, by default 1. Returns
/// them in the order written, with the sum of their weights.
fn File::read_responses(
  self : File,
  stub_pointer : String,
  pointer : String,
  json : Json,
) -> (Array[WeightedResponse], Int) {
  let items = self.array(pointer, json)
  if json is Array(_) && (items.length() < 1 || items.length() > max_responses) {
    self.error(pointer, "must hold 1 to \{max_responses} responses")
  }
  let responses = []
  let mut total = 0
  for i, item in items {
    let at = child_pointer(pointer, i.to_string())
    let mut weight = 1
    let mut item = item
    if item is Object(fields) && fields.get("weight") is Some(value) {
      weight = self
        .read_integer(
          child_pointer(at, "weight"),
          value,
          min=1L,
          max=max_weight.to_int64(),
        )
        .map_or(1, n => n.to_int())
      // The rest is a response like any other.
      let fields = fields.copy()
      fields.remove("weight")
      item = Json::object(fields)
    }
    responses.push({
      weight,
      response: self.read_response(stub_pointer, at, item),
    })
    total += weight
  }
  (responses, total)
}

///|
/// Reads the response of the Stub at `stub_pointer`: the value `json` at
/// `pointer`.
fn File::read_response(
  self : File,
  stub_pointer : String,
  pointer : String,
  json : Json,
) -> Response {
  let mut status = 0
  let headers : Array[(String, String, String)] = []
  let mut body : BodyField = NoBody
  let mut template = false
  guard json is Object(response) else {
    self.error(pointer, "must be an object")
    return {
      status,
      headers: ReadOnlyArray::from_array([]),
      body: Bytes(b""),
      template: None,
      serves_ranges: false,
      reads_variables: false,
    }
  }
  for key, value in response {
    let field = child_pointer(pointer, key)
    match key {
      "status" => status = self.read_status(field, value)
      "headers" => headers.append(self.read_headers(field, value))
      "body" => body = Inline(field, self.string(field, value).unwrap_or(""))
      "bodyFile" => body = File(field, self.read_body_file(field, value))
      "json" => body = JsonBody(field, value)
      "events" => body = EventList(self.read_events(field, value))
      "template" =>
        match value {
          True => template = true
          False => template = false
          _ => self.error(field, "must be true or false")
        }
      _ => self.unknown_field(field)
    }
  }
  self.require(response, pointer, "status")
  let bodies = ["body", "bodyFile", "json", "events"].filter(key => {
    response.contains(key)
  })
  if bodies.length() > 1 {
    let given = bodies.map(key => "\"\{key}\"").join(" and ")
    self.error(
      pointer,
      "has \{given}; give at most one of \"body\", \"bodyFile\", \"json\" and \"events\"",
    )
  }
  // A JSON body is sent as JSON unless the Stub says otherwise.
  if body is JsonBody(_, _) &&
    !headers.iter().any(header => header.0.to_lower() == "content-type") {
    headers.push(("Content-Type", "application/json", pointer))
  }
  let static_headers = ReadOnlyArray::from_iter(
    headers.iter().map(header => (header.0, header.1)),
  )
  if template {
    let template = self.parse_templates(stub_pointer, headers, body)
    return {
      status,
      headers: static_headers,
      body: Bytes(b""),
      template,
      serves_ranges: false,
      reads_variables: template is Some(template) && template.reads_variables(),
    }
  }
  // A 200 from a body file, without templates, serves byte ranges, unless
  // its headers give Content-Range or Accept-Ranges themselves.
  let serves_ranges = status == 200 &&
    body is File(_, _) &&
    !headers
    .iter()
    .any(header => header.0.to_lower() is ("content-range" | "accept-ranges"))
  let body : ResponseBody = match body {
    NoBody => Bytes(b"")
    Inline(_, text) => Bytes(@utf8.encode(text))
    File(_, bytes) => Bytes(bytes)
    JsonBody(_, value) => Bytes(@template.compact_json_bytes(value))
    EventList(events) =>
      Events(
        ReadOnlyArray::from_iter(
          events
          .iter()
          .map(event => SseEvent::{
            delay_ms: event.delay_ms,
            event: event.event.map(field => field.0),
            id: event.id.map(field => field.0),
            data: match event.data {
              NoData => ""
              Data(_, data) => data
              JsonData(_, value) => @template.compact_json(value)
            },
          }),
        ),
      )
  }
  {
    status,
    headers: static_headers,
    body,
    template: None,
    serves_ranges,
    reads_variables: false,
  }
}

///|
/// Parses the templates of a response with `template` on, from its header
/// fields as (name, value, JSON Pointer) and its body, and reports every
/// problem in them. `stub_pointer` is the JSON Pointer of the Stub: a
/// template's own pointer is within the Stub.
fn File::parse_templates(
  self : File,
  stub_pointer : String,
  headers : Array[(String, String, String)],
  body : BodyField,
) -> ResponseTemplate? {
  let mut ok = true
  let within = (pointer : String) => pointer[stub_pointer.length():].to_owned()
  let report = (problem : @template.Problem) => {
    self.error(stub_pointer + problem.pointer, problem.message)
    ok = false
  }
  let text = (source : String, pointer : String, kind : @template.TextKind) => {
    match
      @template.Text::parse(
        source,
        pointer=within(pointer),
        kind~,
        env=self.env,
      ) {
      Ok(text) => Some(text)
      Err(problem) => {
        report(problem)
        None
      }
    }
  }
  let structured = (value : Json, pointer : String) => {
    match
      @template.Structured::parse(value, pointer=within(pointer), env=self.env) {
      Ok(template) => Some(template)
      Err(problems) => {
        problems.each(report)
        None
      }
    }
  }
  let mut content_type = None
  let header_templates = []
  for header in headers {
    let (name, value, pointer) = header
    if name.to_lower() == "content-type" {
      content_type = Some(value)
      if value.contains("${") {
        self.error(
          pointer, "template: Content-Type is never templated, so it cannot contain ${",
        )
        ok = false
        continue
      }
    }
    if text(value, pointer, HeaderValue) is Some(template) {
      header_templates.push((name, template))
    }
  }
  let escaping = @template.escaping_for(content_type)
  let empty = (pointer : String) => {
    text("", pointer, Body(escaping)).map(text => BodyTemplate::Text(text))
  }
  let body = match body {
    NoBody => empty(child_pointer(stub_pointer, "response"))
    Inline(pointer, source) =>
      text(source, pointer, Body(escaping)).map(text => BodyTemplate::Text(text))
    File(pointer, bytes) =>
      try @utf8.decode(bytes) catch {
        _ => {
          self.error(
            pointer, "template: the body file is not UTF-8, so it cannot be a template",
          )
          None
        }
      } noraise {
        source =>
          text(source, pointer, Body(escaping)).map(text => {
            BodyTemplate::Text(text)
          })
      }
    JsonBody(pointer, value) =>
      structured(value, pointer).map(json => BodyTemplate::Json(json))
    EventList(events) => {
      let templates = []
      for event in events {
        let line = (field : (String, String)?) => {
          match field {
            None => Some(None)
            Some((value, pointer)) =>
              text(value, pointer, EventLine).map(text => Some(text))
          }
        }
        // Each field is parsed, so that every problem is reported.
        let event_type = line(event.event)
        let id = line(event.id)
        let data = match event.data {
          NoData => None
          Data(pointer, source) =>
            text(source, pointer, EventData).map(text => EventData::Text(text))
          JsonData(pointer, value) =>
            structured(value, pointer).map(json => EventData::Json(json))
        }
        if event_type is Some(event_type) &&
          id is Some(id) &&
          data is Some(data) {
          templates.push(EventTemplate::{
            delay_ms: event.delay_ms,
            event: event_type,
            id,
            data,
          })
        }
      }
      Some(BodyTemplate::Events(ReadOnlyArray::from_array(templates)))
    }
  }
  guard ok && body is Some(body) else { return None }
  Some({ headers: ReadOnlyArray::from_array(header_templates), body, })
}

///|
/// Reads the Server-Sent Events of a response.
fn File::read_events(
  self : File,
  pointer : String,
  json : Json,
) -> Array[EventDecl] {
  let events = []
  for i, event in self.array(pointer, json) {
    let event_pointer = child_pointer(pointer, i.to_string())
    guard event is Object(fields) else {
      self.error(event_pointer, "must be an object")
      continue
    }
    let mut delay_ms = 0
    let mut event_type = None
    let mut id = None
    let mut data = NoData
    for key, value in fields {
      let field = child_pointer(event_pointer, key)
      match key {
        "delay" => delay_ms = self.read_milliseconds(field, value).unwrap_or(0)
        "event" =>
          event_type = self
            .string_without(field, value, "\r\n", "must be one line")
            .map(value => (value, field))
        "id" =>
          id = self
            .string_without(
              field, value, "\u{0}\r\n", "must be one line without NUL characters",
            )
            .map(value => (value, field))
        "data" => data = Data(field, self.string(field, value).unwrap_or(""))
        "json" => data = JsonData(field, value)
        _ => self.unknown_field(field)
      }
    }
    match (fields.contains("data"), fields.contains("json")) {
      (true, true) =>
        self.error(
          event_pointer, "has \"data\" and \"json\"; give exactly one of them",
        )
      (false, false) => self.error(event_pointer, "needs \"data\" or \"json\"")
      _ => ()
    }
    events.push(EventDecl::{ delay_ms, event: event_type, id, data, })
  }
  events
}
