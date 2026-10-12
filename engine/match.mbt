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
  conditions.meth.map_or(true, meth => meth == self.request.meth) &&
  conditions.path.map_or(true, path => value_meets(self.path, path)) &&
  conditions.query.iter().all(condition => self.has_parameter(condition)) &&
  conditions.headers.iter().all(condition => self.has_header(condition)) &&
  conditions.body.map_or(true, condition => self.body_meets(condition))
}

///|
/// Whether the request has a query parameter with the name of `condition`
/// and a decoded value that meets it. A repeated parameter matches when
/// any of its values does.
fn Incoming::has_parameter(
  self : Incoming,
  condition : (String, @definitions.ValueCondition),
) -> Bool {
  let query = match self.query {
    Some(query) => query
    None => {
      let query = query_parameters(self.request.target)
      self.query = Some(query)
      query
    }
  }
  let (name, value) = condition
  query
  .iter()
  .any(parameter => parameter.0 == name && value_meets(parameter.1, value))
}

///|
/// Whether the request has a header with the name of `condition`, which is
/// in lower case, and a value that meets it. Names are compared
/// case-insensitively. A repeated header matches when any of its values
/// does.
fn Incoming::has_header(
  self : Incoming,
  condition : (String, @definitions.ValueCondition),
) -> Bool {
  let (lower_name, value) = condition
  self.request.headers
  .iter()
  .any(header => is_name(header.0, lower_name) && value_meets(header.1, value))
}

///|
/// Whether `value` meets `condition`: it is exactly the given text, or the
/// pattern matches the whole of it.
fn value_meets(value : String, condition : @definitions.ValueCondition) -> Bool {
  match condition {
    Exact(exact) => value == exact
    Pattern(pattern) => pattern.matches(@utf8.encode(value))
  }
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
        Some(body) => contains(body, expected)
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

///|
/// Whether `actual` contains `expected`: an object has each key of
/// `expected`, with a value that contains the expected one; an array has
/// the same length, and each element contains the expected one; any other
/// value is equal, numbers by their value.
fn contains(actual : Json, expected : Json) -> Bool {
  match (expected, actual) {
    (Object(expected), Object(actual)) =>
      expected
      .iter()
      .all(entry => {
        actual.get(entry.0) is Some(value) && contains(value, entry.1)
      })
    (Array(expected), Array(actual)) => {
      if expected.length() != actual.length() {
        return false
      }
      for i, value in expected {
        if !contains(actual[i], value) {
          return false
        }
      }
      true
    }
    (Number(expected, ..), Number(actual, ..)) => expected == actual
    (String(expected), String(actual)) => expected == actual
    (True, True) | (False, False) | (Null, Null) => true
    _ => false
  }
}
