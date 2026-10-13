// The Near miss: when no candidate Stub matches a request, the candidate
// that failed the fewest conditions, with what it expected and what the
// request carried. Matching stops at a candidate's first failed condition;
// the conditions are counted only here, after every candidate has failed,
// so a request that matches pays nothing for this.

///|
/// The Stub that came closest to matching a request that matched nothing,
/// and the conditions it failed. Its JSON form is the `NearMiss` schema of
/// the Admin API document.
pub(all) struct NearMiss {
  /// The Stub's ID.
  stub : String
  /// The conditions it failed, in the order method, path, query
  /// parameters, headers, body.
  failed : Array[FailedCondition]
} derive(Debug)

///|
/// A condition of a Stub that a request failed, with what the Stub expects
/// and what the request carries.
pub(all) struct FailedCondition {
  condition : Condition
  expected : Expected
  /// The values the request carries for the condition, in order: one for
  /// the method, the path and the body; every value of a query parameter or
  /// header, which may be repeated; none when it is absent. The path and
  /// query values are percent-decoded, as conditions compare them.
  actual : Array[String]
} derive(Debug)

///|
/// One condition of a Stub. Each counts once towards a Near miss.
pub(all) enum Condition {
  Method
  Path
  /// The query parameter with this name.
  Query(String)
  /// The header with this name, in lower case.
  Header(String)
  Body
} derive(Debug, Eq)

///|
/// The name of the condition, as the Near miss reports it: `method`,
/// `path`, `query:<name>`, `header:<name>` or `body`.
pub fn Condition::to_string(self : Condition) -> String {
  match self {
    Method => "method"
    Path => "path"
    Query(name) => "query:\{name}"
    Header(name) => "header:\{name}"
    Body => "body"
  }
}

///|
/// The value a condition expects, as the Stub gives it.
pub(all) enum Expected {
  /// Exactly this text.
  Exact(String)
  /// A pattern, as the Stub writes it, that must match the whole value.
  Pattern(String)
  /// A `json` condition: the body parses as JSON and contains this value.
  Json(Json)
} derive(Debug)

///|
/// The JSON form of the Near miss, the `NearMiss` schema of the Admin API
/// document.
pub impl ToJson for NearMiss with fn to_json(self) {
  {
    "stub": self.stub.to_json(),
    "failed": Json::array(self.failed.map(failed => ToJson::to_json(failed))),
  }
}

///|
pub impl ToJson for FailedCondition with fn to_json(self) {
  {
    "condition": self.condition.to_string().to_json(),
    "expected": ToJson::to_json(self.expected),
    "actual": Json::array(self.actual.map(value => value.to_json())),
  }
}

///|
/// An exact value is a string, a pattern `{"pattern": ...}` and a `json`
/// condition `{"json": ...}`, as in Definition files.
pub impl ToJson for Expected with fn to_json(self) {
  match self {
    Exact(text) => text.to_json()
    Pattern(source) => { "pattern": source.to_json() }
    Json(value) => { "json": value }
  }
}

///|
/// The `Smock-Near-Miss` header value: `<stub-id>; failed=<condition>,...`.
/// It is ASCII only and carries no expected or actual value: the Stub ID
/// and the names of query parameters and headers are written as
/// `header_safe` writes them, so no name can add a field or change the
/// header's meaning.
fn NearMiss::header_value(self : NearMiss) -> String {
  let failed = self.failed
    .map(failed => {
      match failed.condition {
        Query(name) => "query:\{header_safe(name)}"
        Header(name) => "header:\{header_safe(name)}"
        condition => condition.to_string()
      }
    })
    .join(",")
  "\{header_safe(self.stub)}; failed=\{failed}"
}

///|
/// A condition the request failed, as a reference into the Stub's
/// conditions. The explanation is built only for the Near miss.
priv enum Failed {
  Method(String)
  Path(@definitions.ValueCondition)
  Query(String, @definitions.ValueCondition)
  Header(String, @definitions.ValueCondition)
  Body(@definitions.BodyCondition)
}

///|
/// The Near miss among `candidates`, in matching order, none of which the
/// request meets: the one with the fewest failed conditions, the earlier
/// one on a tie. There is none without candidates.
fn Incoming::near_miss(
  self : Incoming,
  candidates : Iter[@definitions.Stub],
) -> NearMiss? {
  let mut best : (@definitions.Stub, Array[Failed])? = None
  for stub in candidates {
    let failed = self.failed(stub.request)
    match best {
      Some((_, fewest)) if fewest.length() <= failed.length() => ()
      _ => best = Some((stub, failed))
    }
  }
  best.map(best => {
    let (stub, failed) = best
    { stub: stub.id, failed: failed.map(failed => self.explain(failed)), }
  })
}

///|
/// The conditions among `conditions` that the request fails, each counted
/// once, in the order method, path, query parameters, headers, body.
fn Incoming::failed(
  self : Incoming,
  conditions : @definitions.Conditions,
) -> Array[Failed] {
  let out = []
  if conditions.meth is Some(meth) && meth != self.request.meth {
    out.push(Failed::Method(meth))
  }
  if conditions.path is Some(path) && !value_meets(self.path, path) {
    out.push(Failed::Path(path))
  }
  for condition in conditions.query {
    if !self.has_parameter(condition) {
      out.push(Failed::Query(condition.0, condition.1))
    }
  }
  for condition in conditions.headers {
    if !self.has_header(condition) {
      out.push(Failed::Header(condition.0, condition.1))
    }
  }
  if conditions.body is Some(body) && !self.body_meets(body) {
    out.push(Failed::Body(body))
  }
  out
}

///|
/// The full explanation of a failed condition: its name, what it expects
/// and what the request carries.
fn Incoming::explain(self : Incoming, failed : Failed) -> FailedCondition {
  match failed {
    Method(meth) =>
      { condition: Method, expected: Exact(meth), actual: [self.request.meth], }
    Path(path) =>
      { condition: Path, expected: expected(path), actual: [self.path], }
    Query(name, value) =>
      {
        condition: Query(name),
        expected: expected(value),
        actual: self
        .query_parameters()
        .iter()
        .filter(parameter => parameter.0 == name)
        .map(parameter => parameter.1)
        .collect(),
      }
    Header(lower_name, value) =>
      {
        condition: Header(lower_name),
        expected: expected(value),
        actual: self.request.headers
        .iter()
        .filter(header => is_name(header.0, lower_name))
        .map(header => header.1)
        .collect(),
      }
    Body(body) =>
      {
        condition: Body,
        expected: match body {
          Exact(bytes) => Exact(@utf8.decode_lossy(bytes))
          Pattern(pattern) => Pattern(pattern.source)
          Json(condition) => Json(condition.to_json())
        },
        actual: [@utf8.decode_lossy(self.request.body)],
      }
  }
}

///|
fn expected(condition : @definitions.ValueCondition) -> Expected {
  match condition {
    Exact(text) => Exact(text)
    Pattern(pattern) => Pattern(pattern.source)
  }
}
