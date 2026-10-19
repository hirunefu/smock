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
  /// Where the Stub comes from.
  stub_source : StubSource
  /// The conditions it failed, in the order method, path, query
  /// parameters, headers, cookies, body or XML paths, Scenario state.
  failed : Array[FailedCondition]
} derive(Debug)

///|
/// A condition of a Stub that a request failed, with what the Stub expects
/// and what the request carries.
pub(all) struct FailedCondition {
  condition : Condition
  expected : Expected
  /// The values the request carries for the condition, in order: one for
  /// the method, the path and the body; every value of a query parameter,
  /// header or cookie, which may be repeated, or of the nodes an XML path
  /// selects; none when it is absent, or when the body is not XML. The path and
  /// query values are percent-decoded, as conditions compare them. For a
  /// Scenario, the one state it is in for the request's Session.
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
  /// The cookie with this name.
  Cookie(String)
  Body
  /// The path into an XML body, as the Stub writes it.
  Xml(String)
  /// The state that the Stub's Scenario clause requires of the Scenario
  /// with this name.
  Scenario(String)
} derive(Debug, Eq)

///|
/// The name of the condition, as the Near miss reports it: `method`,
/// `path`, `query:<name>`, `header:<name>`, `cookie:<name>`, `body`,
/// `xml:<path>` or
/// `scenario:<name>`.
pub fn Condition::to_string(self : Condition) -> String {
  match self {
    Method => "method"
    Path => "path"
    Query(name) => "query:\{name}"
    Header(name) => "header:\{name}"
    Cookie(name) => "cookie:\{name}"
    Body => "body"
    Xml(path) => "xml:\{path}"
    Scenario(name) => "scenario:\{name}"
  }
}

///|
/// The value a condition expects, as the Stub gives it, operators
/// included.
pub(all) enum Expected {
  /// Exactly this text.
  Exact(String)
  /// A pattern, as the Stub writes it, that must match the whole value.
  Pattern(String)
  /// A `json` condition: the body parses as JSON and contains this value.
  Json(Json)
  /// `$not`: the condition inside does not hold.
  Not(Expected)
  /// `$exists`: the name is present when true, absent when false.
  Exists(Bool)
} derive(Debug)

///|
/// The JSON form of the Near miss, the `NearMiss` schema of the Admin API
/// document.
pub impl ToJson for NearMiss with fn to_json(self) {
  {
    "stub": Json::string(self.stub),
    "stubSource": Json::string(self.stub_source.name()),
    "failed": Json::array(self.failed.map(failed => ToJson::to_json(failed))),
  }
}

///|
pub impl ToJson for FailedCondition with fn to_json(self) {
  {
    "condition": Json::string(self.condition.to_string()),
    "expected": ToJson::to_json(self.expected),
    "actual": Json::array(self.actual.map(Json::string)),
  }
}

///|
/// An exact value is a string, a pattern `{"pattern": ...}`, a `json`
/// condition `{"json": ...}` and an operator `{"$not": ...}` or
/// `{"$exists": ...}`, as in Definition files.
pub impl ToJson for Expected with fn to_json(self) {
  match self {
    Exact(text) => Json::string(text)
    Pattern(source) => { "pattern": Json::string(source) }
    Json(value) => { "json": value }
    Not(expected) => { "$not": ToJson::to_json(expected) }
    Exists(present) => { "$exists": Json::boolean(present) }
  }
}

///|
/// The `Smock-Near-Miss` header value: `<stub-id>; failed=<condition>,...`.
/// It is ASCII only and carries no expected or actual value: the Stub ID,
/// the names of query parameters, headers, cookies and Scenarios, and XML
/// paths are
/// written as `header_safe` writes them, so no name can add a field or
/// change the header's meaning.
fn NearMiss::header_value(self : NearMiss) -> String {
  let failed = self.failed
    .map(failed => {
      match failed.condition {
        Query(name) => "query:\{header_safe(name)}"
        Header(name) => "header:\{header_safe(name)}"
        Xml(path) => "xml:\{header_safe(path)}"
        Cookie(name) => "cookie:\{header_safe(name)}"
        Scenario(name) => "scenario:\{header_safe(name)}"
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
  Cookie(String, @definitions.ValueCondition)
  Body(@definitions.BodyCondition)
  Xml(@xml.Path, @definitions.ValueCondition)
  /// The Scenario `name`, the state the Stub requires of it, and the state
  /// it is in.
  Scenario(name~ : String, required~ : String, current~ : String)
}

///|
/// The Near miss among `candidates`, each with where it comes from, in
/// matching order, none of which the request meets in the current states,
/// `states`: the one with the fewest failed conditions, the earlier one on
/// a tie. There is none without candidates.
fn Incoming::near_miss(
  self : Incoming,
  candidates : Iter[(@definitions.Stub, StubSource)],
  states : Map[String, String]?,
) -> NearMiss? {
  let mut best : (@definitions.Stub, StubSource, Array[Failed])? = None
  for candidate in candidates {
    let (stub, source) = candidate
    let failed = self.failed(stub.request)
    // The state a Stub requires counts after its request conditions.
    if stub.scenario is Some({ name, requires: Some(required), .. }) {
      let current = current_state(states, name)
      if current != required {
        failed.push(Failed::Scenario(name~, required~, current~))
      }
    }
    match best {
      Some((_, _, fewest)) if fewest.length() <= failed.length() => ()
      _ => best = Some((stub, source, failed))
    }
  }
  best.map(best => {
    let (stub, stub_source, failed) = best
    {
      stub: stub.id,
      stub_source,
      failed: failed.map(failed => self.explain(failed)),
    }
  })
}

///|
/// The conditions among `conditions` that the request fails, each counted
/// once, in the order method, path, query parameters, headers, cookies,
/// body. The paths of an `xml` condition count one by one, in the Stub's
/// order.
fn Incoming::failed(
  self : Incoming,
  conditions : @definitions.Conditions,
) -> Array[Failed] {
  let out = []
  if conditions.meth is Some(meth) && meth != self.request.meth {
    out.push(Failed::Method(meth))
  }
  if conditions.path is Some(path) && !path.meets(self.path) {
    out.push(Failed::Path(path))
  }
  for condition in conditions.query {
    if !self.query_meets(condition) {
      out.push(Failed::Query(condition.0, condition.1))
    }
  }
  for condition in conditions.headers {
    if !self.header_meets(condition) {
      out.push(Failed::Header(condition.0, condition.1))
    }
  }
  for condition in conditions.cookies {
    if !self.cookie_meets(condition) {
      out.push(Failed::Cookie(condition.0, condition.1))
    }
  }
  match conditions.body {
    Some(Xml(paths)) =>
      for condition in paths {
        if !self.xml_meets(condition) {
          out.push(Failed::Xml(condition.0, condition.1))
        }
      }
    Some(body) if !self.body_meets(body) => out.push(Failed::Body(body))
    _ => ()
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
    Cookie(name, value) =>
      {
        condition: Cookie(name),
        expected: expected(value),
        actual: cookie_values(self.request.headers, name),
      }
    Body(body) =>
      {
        condition: Body,
        expected: match body {
          Exact(bytes) => Exact(@utf8.decode_lossy(bytes))
          Pattern(pattern) => Pattern(pattern.source)
          Json(condition) => Json(condition.to_json())
          // Each path of an `xml` condition fails on its own, as `Xml`.
          Xml(_) => abort("an xml condition fails path by path")
        },
        actual: [@utf8.decode_lossy(self.request.body)],
      }
    Xml(path, value) =>
      {
        condition: Xml(path.to_string()),
        expected: expected(value),
        actual: match self.body_xml() {
          Some(document) => document.select(path)
          None => []
        },
      }
    Scenario(name~, required~, current~) =>
      {
        condition: Scenario(name),
        expected: Exact(required),
        actual: [current],
      }
  }
}

///|
/// What a value condition expects, as the Stub writes it.
fn expected(condition : @definitions.ValueCondition) -> Expected {
  match condition {
    Exact(text) => Exact(text)
    Pattern(pattern) => Pattern(pattern.source)
    Not(inner) => Not(expected(inner))
    Exists(present) => Exists(present)
  }
}
