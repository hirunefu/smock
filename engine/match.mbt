// Matching a request against the conditions of a Stub. An omitted
// condition matches anything; every given condition must hold.

///|
/// A request being matched. The parts that conditions compare are decoded
/// at most once, whatever the number of Stubs the request is matched
/// against, and only when a condition needs them.
priv struct Incoming {
  request : Request
  /// The percent-decoded path, without the query.
  path : String
  /// The decoded query parameters, as (name, value), in request order,
  /// once a query condition needs them.
  mut query : Array[(String, String)]?
  /// The body parsed as JSON, once a `json` condition needs it.
  mut json : ParsedBody
  /// The body read as a form, once a `form` condition needs it.
  mut form : FormBody
  /// The body parsed as XML, once an `xml` condition needs it.
  mut xml : ParsedXml
}

///|
/// The request body as JSON: not parsed yet, parsed, or not JSON.
priv enum ParsedBody {
  NotParsed
  Parsed(Json)
  NotJson
}

///|
/// The request body as a form: not read yet, read into where each of its
/// fields starts, in request order, as `field_starts` finds them, or not a
/// form. Names and values are decoded only when they are compared.
priv enum FormBody {
  NotRead
  Fields(FixedArray[Int32])
  NotForm
}

///|
/// The request body as XML: not parsed yet, parsed, or not a document that
/// the XML module accepts.
priv enum ParsedXml {
  XmlNotParsed
  XmlParsed(@xml.Document)
  NotXml
}

///|
fn Incoming::new(request : Request) -> Incoming {
  {
    request,
    path: decoded_path(request.target),
    query: None,
    json: NotParsed,
    form: NotRead,
    xml: XmlNotParsed,
  }
}

///|
/// Whether the request meets every one of `conditions`.
fn Incoming::meets(
  self : Incoming,
  conditions : @definitions.Conditions,
) -> Bool {
  // Plain loops, with no closure or iterator per Stub, since a request may
  // be matched against many.
  if conditions.meth is Some(meth) && meth != self.request.meth {
    return false
  }
  if conditions.path is Some(path) && !path.meets(self.path) {
    return false
  }
  for i in 0..<conditions.query.length() {
    if !self.query_meets(conditions.query[i]) {
      return false
    }
  }
  for i in 0..<conditions.headers.length() {
    if !self.header_meets(conditions.headers[i]) {
      return false
    }
  }
  for i in 0..<conditions.cookies.length() {
    if !self.cookie_meets(conditions.cookies[i]) {
      return false
    }
  }
  match conditions.body {
    Some(condition) => self.body_meets(condition)
    None => true
  }
}

///|
/// Whether `condition`, on a query parameter, holds for the request: an
/// exact value or a pattern holds when one of the parameter's decoded
/// values meets it, so a repeated parameter matches when any of its values
/// does; an operator is about all of them (see `ValueCondition::holds`).
fn Incoming::query_meets(
  self : Incoming,
  condition : (String, @definitions.ValueCondition),
) -> Bool {
  let (name, value) = condition
  let wanted = value.value_test()
  let parameters = self.query_parameters()
  let mut found = false
  for i in 0..<parameters.length() {
    let parameter = parameters[i]
    if parameter.0 == name && wanted.meets(parameter.1) {
      found = true
      break
    }
  }
  value.holds(found~)
}

///|
/// The decoded query parameters of the request, as (name, value), in
/// request order. They are decoded at most once.
fn Incoming::query_parameters(self : Incoming) -> Array[(String, String)] {
  match self.query {
    Some(query) => query
    None => {
      let query = query_parameters(self.request.target)
      self.query = Some(query)
      query
    }
  }
}

///|
/// Whether `condition`, on a header whose name is in lower case, holds for
/// the request, as `query_meets` says for a query parameter. Names are
/// compared case-insensitively, and each header field line is one value.
fn Incoming::header_meets(
  self : Incoming,
  condition : (String, @definitions.ValueCondition),
) -> Bool {
  let (lower_name, value) = condition
  let wanted = value.value_test()
  let headers = self.request.headers
  let mut found = false
  for i in 0..<headers.length() {
    let header = headers[i]
    if is_name(header.0, lower_name) && wanted.meets(header.1) {
      found = true
      break
    }
  }
  value.holds(found~)
}

///|
/// Whether the header name `name` is `lower_name`, which is in lower case,
/// in any case. Header names are ASCII.
fn is_name(name : StringView, lower_name : String) -> Bool {
  if name.length() != lower_name.length() {
    return false
  }
  for i in 0..<name.length() {
    let c = name[i]
    let lower = if c >= 'A' && c <= 'Z' { c + 0x20 } else { c }
    if lower != lower_name[i] {
      return false
    }
  }
  true
}

///|
/// Whether the request body meets `condition`.
fn Incoming::body_meets(
  self : Incoming,
  condition : @definitions.BodyCondition,
) -> Bool {
  match condition {
    Exact(body) => body == self.request.body
    Pattern(pattern) => pattern.matches(self.request.body)
    Json(expected) =>
      match self.body_json() {
        Some(body) => expected.matches(body)
        None => false
      }
    Form(fields) => {
      // A body that is not a form fails even a condition with no field, as
      // a body that is not JSON fails `json: {}`.
      if self.form_fields() is None {
        return false
      }
      for i in 0..<fields.length() {
        if !self.form_meets(fields[i]) {
          return false
        }
      }
      true
    }
    Xml(conditions) => {
      // A body that is not XML fails even a condition with no path.
      if self.body_xml() is None {
        return false
      }
      for i in 0..<conditions.length() {
        if !self.xml_meets(conditions[i]) {
          return false
        }
      }
      true
    }
  }
}

///|
/// Whether `condition`, on a field of a form body, holds for the request,
/// as `query_meets` says for a query parameter. A body that is not a form
/// fails it, whatever its operators.
fn Incoming::form_meets(
  self : Incoming,
  condition : (String, @definitions.ValueCondition),
) -> Bool {
  guard self.form_fields() is Some(starts) else { return false }
  let body = self.request.body
  let (name, value) = condition
  let wanted = value.value_test()
  let mut found = false
  for i in 0..<starts.length() {
    let start = starts[i]
    let end = piece_end(body, start)
    let equals = name_end(body, start, end)
    if form_text_is(body[start:equals], name) &&
      form_value_meets(field_value(body, equals, end), wanted) {
      found = true
      break
    }
  }
  value.holds(found~)
}

///|
/// Whether the encoded form value `value` passes `wanted`. Only a pattern
/// needs the value decoded; an exact value is compared in place.
fn form_value_meets(value : BytesView, wanted : @definitions.ValueTest) -> Bool {
  match wanted {
    Any => true
    Exact(text) => form_text_is(value, text)
    Pattern(pattern) => pattern.matches(form_utf8(value))
  }
}

///|
/// The decoded values of the field `name` of the request body, in request
/// order, none when the body is not a form, as `is_form` says.
fn Incoming::form_values(self : Incoming, name : String) -> Array[String] {
  let values = []
  guard self.form_fields() is Some(starts) else { return values }
  let body = self.request.body
  for i in 0..<starts.length() {
    let start = starts[i]
    let end = piece_end(body, start)
    let equals = name_end(body, start, end)
    if form_text_is(body[start:equals], name) {
      values.push(form_decode(field_value(body, equals, end)))
    }
  }
  values
}

///|
/// Where each field of the request body starts, as `field_starts` finds
/// them, or `None` when the body is not a form, as `is_form` says. They are
/// found at most once.
fn Incoming::form_fields(self : Incoming) -> FixedArray[Int32]? {
  match self.form {
    Fields(starts) => return Some(starts)
    NotForm => return None
    NotRead => ()
  }
  self.form = if is_form(self.request.headers) {
    Fields(field_starts(self.request.body))
  } else {
    NotForm
  }
  self.form_fields()
}

///|
/// Whether the request's Content-Type, its first Content-Type field, says
/// that its body is a form: its media type, compared case-insensitively and
/// without its parameters, is application/x-www-form-urlencoded.
fn is_form(headers : Array[(String, String)]) -> Bool {
  for i in 0..<headers.length() {
    let header = headers[i]
    if is_name(header.0, "content-type") {
      let value = header.1
      let media_type = match value.find(";") {
        Some(end) => value[:end]
        None => value[:]
      }
      return is_name(
        media_type.trim(chars=" \t"),
        "application/x-www-form-urlencoded",
      )
    }
  }
  false
}

///|
/// The request body parsed as JSON, or `None` when it is not JSON in UTF-8.
/// It is parsed at most once.
fn Incoming::body_json(self : Incoming) -> Json? {
  match self.json {
    Parsed(json) => return Some(json)
    NotJson => return None
    NotParsed => ()
  }
  let parsed = try @json.parse(@utf8.decode(self.request.body)) catch {
    _ => NotJson
  } noraise {
    json => Parsed(json)
  }
  self.json = parsed
  self.body_json()
}

///|
/// Whether `condition`, on the values at a path into an XML body, holds for
/// the request, as `query_meets` says for a query parameter: the nodes the
/// path selects are the values of a name, which is absent when there are
/// none. A body that is not XML fails every such condition.
fn Incoming::xml_meets(
  self : Incoming,
  condition : (@xml.Path, @definitions.ValueCondition),
) -> Bool {
  guard self.body_xml() is Some(document) else { return false }
  let (path, value) = condition
  let wanted = value.value_test()
  // The selected nodes are walked one at a time, with no list of them or of
  // their values: `$exists` reads no value, an exact value is compared in
  // place, and only a pattern may need a value decoded.
  let mut found = false
  let mut node = document.first_node(path)
  while node >= 0 {
    let meets = match wanted {
      Any => true
      Exact(text) => document.value_is(path, node, text)
      Pattern(pattern) => pattern.matches(document.utf8_value(path, node))
    }
    if meets {
      found = true
      break
    }
    node = document.next_node(path, node)
  }
  value.holds(found~)
}

///|
/// The request body parsed as XML, or `None` when it is not a document that
/// the XML module accepts. It is parsed at most once.
fn Incoming::body_xml(self : Incoming) -> @xml.Document? {
  match self.xml {
    XmlParsed(document) => return Some(document)
    NotXml => return None
    XmlNotParsed => ()
  }
  let parsed = try @xml.parse(self.request.body) catch {
    _ => NotXml
  } noraise {
    document => XmlParsed(document)
  }
  self.xml = parsed
  self.body_xml()
}
