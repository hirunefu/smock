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
}

///|
/// The request body as JSON: not parsed yet, parsed, or not JSON.
priv enum ParsedBody {
  NotParsed
  Parsed(Json)
  NotJson
}

///|
fn Incoming::new(request : Request) -> Incoming {
  { request, path: decoded_path(request.target), query: None, json: NotParsed, }
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
fn is_name(name : String, lower_name : String) -> Bool {
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
  }
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
