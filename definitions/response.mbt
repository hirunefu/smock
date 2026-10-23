// Reading a Stub's response: its status, its headers, and a body given
// inline, from a body file, as JSON, as Server-Sent Events or as an LLM
// reply. With `template` on, the header values, the body and the events
// are templates, parsed here, when the definition set is loaded or the Stub
// is added, and rendered for each request by the engine.

///|
/// The body of a response, as written: which field gives it, its JSON
/// Pointer and its value.
priv enum BodyField {
  NoBody
  Inline(String, String)
  File(String, Bytes)
  JsonBody(String, Json)
  EventList(Array[EventDecl])
  LlmField(LlmReply)
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
/// plus `weight`, an integer from 1 to `max_weight`, by default 1. Their
/// templates may read the Data buckets `buckets`. Returns them in the order
/// written, with the sum of their weights.
fn File::read_responses(
  self : File,
  stub_pointer : String,
  pointer : String,
  json : Json,
  buckets~ : @template.Buckets,
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
      response: self.read_response(stub_pointer, at, item, buckets~),
    })
    total += weight
  }
  (responses, total)
}

///|
/// Reads the response of the Stub at `stub_pointer`: the value `json` at
/// `pointer`. Its templates may read the Data buckets `buckets`.
fn File::read_response(
  self : File,
  stub_pointer : String,
  pointer : String,
  json : Json,
  buckets~ : @template.Buckets,
) -> Response {
  let mut status = 0
  let headers : Array[(String, String, String)] = []
  let mut body : BodyField = NoBody
  let mut template = false
  guard json is Object(response) else {
    self.error(pointer, "must be an object")
    return {
      status,
      headers: Written(ReadOnlyArray::from_array([])),
      body: Bytes(b""),
      serves_ranges: false,
      reads_variables: false,
      reads_data: false,
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
      "llm" =>
        body = match self.read_llm(field, value) {
          Some(reply) => LlmField(reply)
          None => NoBody
        }
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
  let bodies = ["body", "bodyFile", "json", "events", "llm"].filter(key => {
    response.contains(key)
  })
  if bodies.length() > 1 {
    let given = bodies.map(key => "\"\{key}\"").join(" and ")
    self.error(
      pointer,
      "has \{given}; give at most one of \"body\", \"bodyFile\", \"json\", \"events\" and \"llm\"",
    )
  }
  // A JSON body is sent as JSON unless the Stub says otherwise.
  if body is JsonBody(_, _) &&
    !headers.iter().any(header => header.0.to_lower() == "content-type") {
    headers.push(("Content-Type", "application/json", pointer))
  }
  let (headers, body, serves_ranges) = if template {
    // Templates that fail to parse are reported, and the set is not loaded,
    // so the response they leave is never sent.
    match self.parse_templates(stub_pointer, headers, body, buckets~) {
      Some((headers, body)) => (Templated(headers), body, false)
      None => (Written(ReadOnlyArray::from_array([])), Bytes(b""), false)
    }
  } else {
    let written = ReadOnlyArray::from_iter(
      headers.iter().map(header => (header.0, header.1)),
    )
    // A 200 from a body file, without templates, serves byte ranges, unless
    // its headers give Content-Range or Accept-Ranges themselves.
    let from_file = match body {
      File(_, _) => true
      NoBody | Inline(_, _) | JsonBody(_, _) | EventList(_) | LlmField(_) =>
        false
    }
    let serves_ranges = status == 200 &&
      from_file &&
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
      LlmField(reply) => Llm(reply)
    }
    (Written(written), body, serves_ranges)
  }
  {
    status,
    headers,
    body,
    serves_ranges,
    reads_variables: headers.reads(@template.Text::reads_vars) ||
    body.reads(@template.Text::reads_vars, @template.Structured::reads_vars),
    reads_data: headers.reads(@template.Text::reads_data) ||
    body.reads(@template.Text::reads_data, @template.Structured::reads_data),
  }
}

///|
/// Parses the templates of a response with `template` on, from its header
/// fields as (name, value, JSON Pointer) and its body, and reports every
/// problem in them. Returns the header fields, their values text
/// templates, and the body: its templates, or an LLM reply as written, or
/// `None` when one of them has a problem. `stub_pointer` is the JSON
/// Pointer of the Stub: a template's own pointer is within the Stub. The
/// templates may read the Data buckets `buckets`.
fn File::parse_templates(
  self : File,
  stub_pointer : String,
  headers : Array[(String, String, String)],
  body : BodyField,
  buckets~ : @template.Buckets,
) -> (ReadOnlyArray[(String, @template.Text)], ResponseBody)? {
  let mut ok = true
  let report = (problem : @template.Problem) => {
    self.report_template_problem(stub_pointer, problem)
    ok = false
  }
  let text = (source : String, pointer : String, kind : @template.TextKind) => {
    match
      @template.Text::parse(
        source,
        pointer=template_pointer(stub_pointer, pointer),
        kind~,
        env=self.env,
        buckets~,
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
      @template.Structured::parse(
        value,
        pointer=template_pointer(stub_pointer, pointer),
        env=self.env,
        buckets~,
      ) {
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
    text("", pointer, Body(escaping)).map(text => {
      ResponseBody::Template(Text(text))
    })
  }
  let body : ResponseBody? = match body {
    NoBody => empty(child_pointer(stub_pointer, "response"))
    Inline(pointer, source) =>
      text(source, pointer, Body(escaping)).map(text => Template(Text(text)))
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
          text(source, pointer, Body(escaping)).map(text => Template(Text(text)))
      }
    JsonBody(pointer, value) =>
      structured(value, pointer).map(json => Template(Json(json)))
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
      Some(Template(Events(ReadOnlyArray::from_array(templates))))
    }
    // The strings of an LLM reply are as written.
    LlmField(reply) => Some(Llm(reply))
  }
  guard ok && body is Some(body) else { return None }
  Some((ReadOnlyArray::from_array(header_templates), body))
}

///|
/// The JSON Pointer `pointer`, of a field of the Stub at `stub_pointer`,
/// made relative to the Stub, as a template's pointer is.
fn template_pointer(stub_pointer : String, pointer : String) -> String {
  pointer[stub_pointer.length():].to_owned()
}

///|
/// Reports `problem`, a problem in a template of the Stub at
/// `stub_pointer`, at its pointer within the file.
fn File::report_template_problem(
  self : File,
  stub_pointer : String,
  problem : @template.Problem,
) -> Unit {
  self.error(stub_pointer + problem.pointer, problem.message)
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

///|
/// Reads the `llm` of a response: `api`, which names the API whose wire
/// form the reply takes, `text`, empty when left out, the reply's `id` and
/// `model`, generated and the request's when left out, `usage`, 0 tokens
/// when left out, and `stopReason`, a word of that API, derived when left
/// out. It has none when `api` is missing or names no API, and then the
/// stop reason is not checked.
fn File::read_llm(self : File, pointer : String, json : Json) -> LlmReply? {
  guard json is Object(fields) else {
    self.error(pointer, "must be an object")
    return None
  }
  let mut api = None
  let mut text = ""
  let mut id = None
  let mut model = None
  let mut usage = @llm.Usage(input=0, output=0)
  for key, value in fields {
    let field = child_pointer(pointer, key)
    match key {
      "api" =>
        match @llm.read_api(value) {
          Ok(named) => api = Some(named)
          Err(message) => self.error(field, message)
        }
      "text" => text = self.string(field, value).unwrap_or("")
      "id" => id = self.string(field, value)
      "model" => model = self.string(field, value)
      "usage" => usage = self.read_usage(field, value)
      // Checked below, against the API, which may come after it.
      "stopReason" => ()
      _ => self.unknown_field(field)
    }
  }
  self.require(fields, pointer, "api")
  guard api is Some(api) else { return None }
  let stop_reason = match fields.get("stopReason") {
    Some(value) =>
      match @llm.read_stop_reason(api, value) {
        Ok(reason) => Some(reason)
        Err(message) => {
          self.error(child_pointer(pointer, "stopReason"), message)
          None
        }
      }
    None => None
  }
  Some({
    declaration: @llm.Declaration(api~, usage~, stop_reason?),
    strings: @llm.Strings(text~, id?, model?),
  })
}

///|
/// Reads the `usage` of an `llm`: `input` and `output`, each a token count
/// from 0 to `@llm.max_token_count`, 0 when left out or not one.
fn File::read_usage(self : File, pointer : String, json : Json) -> @llm.Usage {
  guard json is Object(fields) else {
    self.error(pointer, "must be an object")
    return @llm.Usage(input=0, output=0)
  }
  let mut input = 0L
  let mut output = 0L
  for key, value in fields {
    let field = child_pointer(pointer, key)
    match key {
      "input" => input = self.read_token_count(field, value)
      "output" => output = self.read_token_count(field, value)
      _ => self.unknown_field(field)
    }
  }
  @llm.Usage(input~, output~)
}

///|
/// Reads a token count: an integer from 0 to `@llm.max_token_count`, or 0
/// when it is not one.
fn File::read_token_count(self : File, pointer : String, json : Json) -> Int64 {
  self
  .read_integer(pointer, json, min=0L, max=@llm.max_token_count)
  .unwrap_or(0L)
}
