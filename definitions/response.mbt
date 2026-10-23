// Reading a Stub's response: its status, its headers, and a body given
// inline, from a body file, as JSON, as Server-Sent Events or as an LLM
// reply. With `template` on, the header values, the body, the events and
// an LLM reply's strings are templates, parsed here, when the definition
// set is loaded or the Stub is added, and rendered for each request by the
// engine.

///|
/// The body of a response, as written: which field gives it, its JSON
/// Pointer and its value.
priv enum BodyField {
  NoBody
  Inline(String, String)
  File(String, Bytes)
  JsonBody(String, Json)
  EventList(Array[EventDecl])
  LlmField(LlmDecl)
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
/// An `llm` as written: its declaration and timing, which are never
/// templates, and its strings, each with its JSON Pointer, which make the
/// reply's strings as written or are parsed as its templates.
priv struct LlmDecl {
  declaration : @llm.Declaration
  timing : LlmTiming
  /// The JSON Pointer of `llm`.
  pointer : String
  /// `text` and its JSON Pointer, when given.
  text : (String, String)?
  /// Each element of `chunks` and its JSON Pointer, when given.
  chunks : Array[(String, String)]?
  /// `id` and its JSON Pointer, when given.
  id : (String, String)?
  /// `model` and its JSON Pointer, when given.
  model : (String, String)?
  /// The tool calls that give both a name and arguments, in the order
  /// written.
  tool_calls : Array[ToolCallDecl]
  /// The `message` of a valid `error` and its JSON Pointer.
  error_message : (String, String)?
}

///|
/// A tool call as written: each field with its JSON Pointer.
priv struct ToolCallDecl {
  name : (String, String)
  /// An object or a string.
  arguments : (Json, String)
  id : (String, String)?
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
  // An `llm` needs it before it is read below: its text is known only once
  // rendered.
  let templated = response.get("template") is Some(True)
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
        body = match self.read_llm(field, value, templated~) {
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
      Some((headers, body)) =>
        (ResponseHeaders::Templated(headers), body, false)
      None =>
        (
          ResponseHeaders::Written(ReadOnlyArray::from_array([])),
          Bytes(b""),
          false,
        )
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
      LlmField(llm) => Llm(self.written_llm(stub_pointer, llm))
    }
    (ResponseHeaders::Written(written), body, serves_ranges)
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
/// templates, and the body: its templates, or an LLM reply with its
/// templates, or `None` when one of them has a problem. `stub_pointer` is
/// the JSON Pointer of the Stub: a template's own pointer is within the
/// Stub. The templates may read the Data buckets `buckets`.
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
    LlmField(llm) => {
      // Never escaped: smock writes what they give into the JSON it builds.
      let kind = @template.TextKind::Body(Plain)
      // `Some(None)` for a field left out, `None` for one with a problem.
      let optional = (field : (String, String)?) => {
        match field {
          None => Some(None)
          Some((source, pointer)) =>
            text(source, pointer, kind).map(text => Some(text))
        }
      }
      // Each field is parsed, so that every problem is reported.
      let id = optional(llm.id)
      let model = optional(llm.model)
      let reply_text = match (llm.chunks, llm.text) {
        (Some(chunks), _) => {
          let parsed = []
          for chunk in chunks {
            if text(chunk.0, chunk.1, kind) is Some(chunk) {
              parsed.push(chunk)
            }
          }
          if parsed.length() == chunks.length() {
            Some(LlmText::Chunks(ReadOnlyArray::from_array(parsed)))
          } else {
            None
          }
        }
        (None, Some((source, pointer))) =>
          text(source, pointer, kind).map(text => LlmText::Whole(text))
        (None, None) =>
          text("", child_pointer(llm.pointer, "text"), kind).map(text => {
            LlmText::Whole(text)
          })
      }
      let tool_calls = []
      // The call ids with no expression, which are checked as written.
      let literal_ids = []
      for call in llm.tool_calls {
        let id = optional(call.id)
        if id is Some(Some(id)) &&
          id.literal() is Some(value) &&
          call.id is Some((_, pointer)) {
          literal_ids.push((value, pointer))
        }
        let name = text(call.name.0, call.name.1, kind)
        let arguments = match call.arguments {
          (String(source), pointer) =>
            text(source, pointer, kind).map(text => {
              ArgumentsTemplate::Text(text)
            })
          (value, pointer) =>
            match
              @template.Structured::parse(
                value,
                pointer=template_pointer(stub_pointer, pointer),
                env=self.env,
                buckets~,
                role="a tool call's arguments",
              ) {
              Ok(template) => Some(ArgumentsTemplate::Json(template))
              Err(problems) => {
                problems.each(report)
                None
              }
            }
        }
        if id is Some(id) && name is Some(name) && arguments is Some(arguments) {
          tool_calls.push(ToolCallTemplate::{ id, name, arguments, })
        }
      }
      // Templated ids are compared when they are rendered.
      self.check_tool_call_ids(literal_ids)
      let error_message = optional(llm.error_message)
      if id is Some(id) &&
        model is Some(model) &&
        reply_text is Some(reply_text) &&
        tool_calls.length() == llm.tool_calls.length() &&
        error_message is Some(error_message) {
        Some(
          Llm({
            declaration: llm.declaration,
            strings: LlmStrings::Templated({
              id,
              model,
              text: reply_text,
              tool_calls: ReadOnlyArray::from_array(tool_calls),
              error_message,
            }),
            timing: llm.timing,
            pointer: template_pointer(stub_pointer, llm.pointer),
          }),
        )
      } else {
        None
      }
    }
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
/// form the reply takes; `text`, empty when left out, or `chunks`, its
/// pieces, in its place; `chunkSize`, the code points of each piece cut
/// from `text` or from a tool call's arguments; `toolCalls`, none when left
/// out; the reply's `id` and `model`, generated and the request's when left
/// out; `usage`, 0 tokens when left out; `stopReason`, a word of that API,
/// derived when left out; `timing`, no waits when left out; and `error`, a
/// mid-stream error, none when left out. It has none when `api` is missing
/// or names no API, and then neither the stop reason nor the error is
/// checked. When `templated`, the response has `template` on, so the
/// error's `after` is not checked against the text, which is known only
/// once it is rendered. The strings are kept with their JSON Pointers, and
/// are parsed as templates once the whole response is read.
fn File::read_llm(
  self : File,
  pointer : String,
  json : Json,
  templated~ : Bool,
) -> LlmDecl? {
  guard json is Object(fields) else {
    self.error(pointer, "must be an object")
    return None
  }
  let mut api = None
  let mut text = None
  let mut chunks = None
  let mut chunk_size = None
  let mut tool_calls = []
  let mut id = None
  let mut model = None
  let mut usage = @llm.Usage(input=0, output=0)
  let mut timing = { first: None, interval: None, }
  for key, value in fields {
    let field = child_pointer(pointer, key)
    match key {
      "api" =>
        match @llm.read_api(value) {
          Ok(named) => api = Some(named)
          Err(message) => self.error(field, message)
        }
      "text" => text = Some((self.string(field, value).unwrap_or(""), field))
      "chunks" => chunks = Some(self.read_chunks(field, value))
      "chunkSize" =>
        chunk_size = self
          .read_integer(
            field,
            value,
            min=1L,
            max=@llm.max_chunk_size.to_int64(),
          )
          .map(n => n.to_int())
      "toolCalls" => tool_calls = self.read_tool_calls(field, value)
      "id" => id = self.string(field, value).map(id => (id, field))
      "model" => model = self.string(field, value).map(model => (model, field))
      "usage" => usage = self.read_usage(field, value)
      // Checked below, against the API, which may come after them.
      "stopReason" | "error" => ()
      "timing" => timing = self.read_llm_timing(field, value)
      _ => self.unknown_field(field)
    }
  }
  self.require(fields, pointer, "api")
  if fields.contains("text") && fields.contains("chunks") {
    self.error(pointer, "has \"text\" and \"chunks\"; give at most one of them")
  }
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
  let mut error = None
  let mut error_message = None
  if fields.get("error") is Some(value) {
    // The text as written: with `chunks`, their join, in place of `text`.
    // A template's is known only once rendered.
    let whole = match chunks {
      _ if templated => None
      Some(chunks) => Some(chunks.map(chunk => chunk.0).join(""))
      None => Some(text.map_or("", text => text.0))
    }
    let error_pointer = child_pointer(pointer, "error")
    if self.read_llm_error(api, error_pointer, value, whole)
      is Some((declared, message)) {
      error = Some(declared)
      error_message = Some((message, child_pointer(error_pointer, "message")))
    }
  }
  Some({
    declaration: @llm.Declaration(
      api~,
      chunk_size?,
      usage~,
      stop_reason?,
      error?,
    ),
    timing,
    pointer,
    text,
    chunks,
    id,
    model,
    tool_calls,
    error_message,
  })
}

///|
/// Reads the `error` of an `llm` whose API is `api` and whose text, as
/// written, is `text`, or `None` when it is a template: `after`, the code
/// points of the text before the error, from 0, by default 0, and not past
/// the end of a text as written; `type`, or `code` for `openai-responses`,
/// checked with the API's vocabulary; and `message`, non-empty as written.
/// The other one of `type` and `code` is refused with a message that names
/// the member to give in its place, so that the load error points at the
/// member to rewrite when `api` changes. It has none when a member is
/// missing or refused.
fn File::read_llm_error(
  self : File,
  api : @llm.Api,
  pointer : String,
  json : Json,
  text : String?,
) -> (@llm.MidStreamError, String)? {
  guard json is Object(fields) else {
    self.error(pointer, "must be an object")
    return None
  }
  let kind_member = @llm.error_kind_member(api)
  let mut after = Some(0)
  let mut kind = None
  let mut message = None
  let mut valid = true
  for key, value in fields {
    let field = child_pointer(pointer, key)
    match key {
      "after" => {
        after = self
          .read_integer(field, value, min=0L, max=@int.MAX_VALUE.to_int64())
          .map(n => n.to_int())
        if after is Some(after) &&
          text is Some(text) &&
          @llm.check_error_after(after, text) is Err(problem) {
          self.error(field, problem)
          valid = false
        }
      }
      "type" | "code" if key == kind_member =>
        match @llm.read_error_kind(api, value) {
          Ok(written) => kind = Some(written)
          Err(problem) => self.error(field, problem)
        }
      "type" | "code" => {
        self.error(
          field,
          "is not a field of an \{api.name()} error; give \"\{kind_member}\" in its place",
        )
        valid = false
      }
      "message" => message = self.name(field, value)
      _ => {
        self.unknown_field(field)
        valid = false
      }
    }
  }
  // A member given under the other name is reported above, with the one
  // to give.
  if !fields.contains("type") && !fields.contains("code") {
    self.require(fields, pointer, kind_member)
  }
  self.require(fields, pointer, "message")
  match (after, kind, message) {
    (Some(after), Some(kind), Some(message)) if valid =>
      Some((@llm.MidStreamError(after~, kind~), message))
    _ => None
  }
}

///|
/// The LLM reply that `llm` declares, its strings as written. Two of its
/// tool calls with the same `id` are refused, since the call ids of a reply
/// must differ, and so is a reply whose JSON reply or stream takes more
/// than `@llm.max_reply_bytes` once encoded, as `@llm.check_reply_size`
/// finds. `stub_pointer` is the JSON Pointer of its Stub.
fn File::written_llm(
  self : File,
  stub_pointer : String,
  llm : LlmDecl,
) -> LlmReply {
  let ids = []
  let tool_calls = []
  for call in llm.tool_calls {
    if call.id is Some(id) {
      ids.push(id)
    }
    tool_calls.push(
      @llm.ToolCall(
        name=call.name.0,
        arguments=call.arguments.0,
        id?=call.id.map(id => id.0),
      ),
    )
  }
  self.check_tool_call_ids(ids)
  // With `chunks`, the text is their join, in place of `text`.
  let strings = @llm.Strings(
    text=llm.text.map_or("", text => text.0),
    chunks?=llm.chunks.map(chunks => {
      ReadOnlyArray::from_iter(chunks.iter().map(chunk => chunk.0))
    }),
    id?=llm.id.map(id => id.0),
    model?=llm.model.map(model => model.0),
    tool_calls=ReadOnlyArray::from_array(tool_calls),
    error_message?=llm.error_message.map(message => message.0),
  )
  if @llm.check_reply_size(llm.declaration, strings) is Err(message) {
    self.error(llm.pointer, message)
  }
  {
    declaration: llm.declaration,
    strings: LlmStrings::Written(strings),
    timing: llm.timing,
    pointer: template_pointer(stub_pointer, llm.pointer),
  }
}

///|
/// Reports each tool call id of `ids`, given as (id, JSON Pointer) in the
/// order written, that an earlier one of them has: the call ids of a reply
/// must differ.
fn File::check_tool_call_ids(
  self : File,
  ids : Array[(String, String)],
) -> Unit {
  // Where each id is given first.
  let first : Map[String, String] = Map([])
  for entry in ids {
    let (id, pointer) = entry
    match first.get(id) {
      Some(earlier) =>
        self.error(
          pointer,
          "the tool call id \{id.escape()} is already used at \{self.at(earlier)}",
        )
      None => first[id] = pointer
    }
  }
}

///|
/// Reads the `toolCalls` of an `llm`: a list of function tool calls, in the
/// order the reply sends them. Each one needs `name`, a non-empty text that
/// no vendor's naming rule checks, and `arguments`, a JSON object or a
/// string, and may give `id`, its call id, as text. A call that lacks one
/// of them is left out. Whether two of them have the same `id` is checked
/// once the response is read, since a templated id is compared when it is
/// rendered.
fn File::read_tool_calls(
  self : File,
  pointer : String,
  json : Json,
) -> Array[ToolCallDecl] {
  let items = self.array(pointer, json)
  let tool_calls = []
  for i, item in items {
    let call_pointer = child_pointer(pointer, i.to_string())
    guard item is Object(fields) else {
      self.error(call_pointer, "must be an object")
      continue
    }
    let mut name = None
    let mut arguments = None
    let mut id = None
    for key, value in fields {
      let field = child_pointer(call_pointer, key)
      match key {
        "name" => name = self.name(field, value).map(name => (name, field))
        "arguments" =>
          match value {
            Object(_) | String(_) => arguments = Some((value, field))
            _ => self.error(field, "must be an object or a string")
          }
        "id" => id = self.string(field, value).map(id => (id, field))
        _ => self.unknown_field(field)
      }
    }
    self.require(fields, call_pointer, "name")
    self.require(fields, call_pointer, "arguments")
    if name is Some(name) && arguments is Some(arguments) {
      tool_calls.push(ToolCallDecl::{ name, arguments, id, })
    }
  }
  tool_calls
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

///|
/// Reads the `chunks` of an `llm`: a list of at least one text, each one
/// piece of the reply's text, an empty one included. Each comes with its
/// JSON Pointer.
fn File::read_chunks(
  self : File,
  pointer : String,
  json : Json,
) -> Array[(String, String)] {
  let items = self.array(pointer, json)
  if json is Array([]) {
    self.error(pointer, "must not be an empty array")
  }
  let chunks = []
  for i, item in items {
    let field = child_pointer(pointer, i.to_string())
    chunks.push((self.string(field, item).unwrap_or(""), field))
  }
  chunks
}

///|
/// Reads the `timing` of an LLM reply: `first` and `interval`, each one
/// distribution of the delay Fault, without `probability`, and each none
/// when left out.
fn File::read_llm_timing(
  self : File,
  pointer : String,
  json : Json,
) -> LlmTiming {
  let mut first = None
  let mut interval = None
  guard json is Object(timing) else {
    self.error(pointer, "must be an object")
    return { first, interval, }
  }
  for key, value in timing {
    let field = child_pointer(pointer, key)
    match key {
      "first" => first = self.read_wait(field, value)
      "interval" => interval = self.read_wait(field, value)
      _ => self.unknown_field(field)
    }
  }
  { first, interval, }
}
