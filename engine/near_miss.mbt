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
  /// parameters, headers, cookies, body, form fields or XML paths,
  /// Scenario state.
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
  /// header, cookie or form field, which may be repeated, or of the nodes
  /// an XML path selects; none when it is absent, or when the body is not a
  /// form or not XML. The path, query and form values are percent-decoded,
  /// as conditions compare them. For a Scenario, the one state it is in for
  /// the request's Session.
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
  /// The field of a form body with this name.
  Form(String)
  /// The path into an XML body, as the Stub writes it.
  Xml(String)
  /// The state that the Stub's Scenario clause requires of the Scenario
  /// with this name.
  Scenario(String)
} derive(Debug, Eq)

///|
/// The name of the condition, as the Near miss reports it: `method`,
/// `path`, `query:<name>`, `header:<name>`, `cookie:<name>`, `body`,
/// `form:<name>`, `xml:<path>` or `scenario:<name>`.
pub fn Condition::to_string(self : Condition) -> String {
  match self {
    Method => "method"
    Path => "path"
    Query(name) => "query:\{name}"
    Header(name) => "header:\{name}"
    Cookie(name) => "cookie:\{name}"
    Body => "body"
    Form(name) => "form:\{name}"
    Xml(path) => "xml:\{path}"
    Scenario(name) => "scenario:\{name}"
  }
}

///|
/// The value a condition expects, as the Stub gives it, operators included.
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
  /// A `form` condition with no field: the request's Content-Type says
  /// that its body is a form.
  Form
  /// An `xml` condition with no path: the body parses as XML.
  Xml
  /// A CRUD Stub's path: the request path is this list path, or an item
  /// path under it.
  CrudPath(String)
  /// The methods a CRUD Stub serves at the request path's shape, or at
  /// either shape when the path is neither its list path nor an item path,
  /// in the order GET, POST, PUT, PATCH, DELETE.
  CrudMethods(ReadOnlyArray[String])
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
/// condition `{"json": ...}`, an operator `{"$not": ...}` or
/// `{"$exists": ...}`, and an empty `form` or `xml` condition
/// `{"form": {}}` or `{"xml": {}}`, as in Definition files. What a CRUD
/// Stub expects is `{"crud": "<path>"}` or `{"crud": [<methods>]}`.
pub impl ToJson for Expected with fn to_json(self) {
  match self {
    Exact(text) => Json::string(text)
    Pattern(source) => { "pattern": Json::string(source) }
    Json(value) => { "json": value }
    Not(expected) => { "$not": ToJson::to_json(expected) }
    Exists(present) => { "$exists": Json::boolean(present) }
    Form => { "form": {} }
    Xml => { "xml": {} }
    CrudPath(path) => { "crud": Json::string(path) }
    CrudMethods(methods) =>
      { "crud": Json::array(methods.iter().map(Json::string).collect()) }
  }
}

///|
/// The `Smock-Near-Miss` header value: `<stub-id>; failed=<condition>,...`.
/// It is ASCII only and carries no expected or actual value: the Stub ID,
/// the names of query parameters, headers, cookies, form fields and
/// Scenarios, and XML paths are written as `header_safe` writes them, so
/// no name can add a field or change the header's meaning.
fn NearMiss::header_value(self : NearMiss) -> String {
  let failed = self.failed
    .map(failed => {
      match failed.condition {
        Query(name) => "query:\{header_safe(name)}"
        Header(name) => "header:\{header_safe(name)}"
        Cookie(name) => "cookie:\{header_safe(name)}"
        Form(name) => "form:\{header_safe(name)}"
        Xml(path) => "xml:\{header_safe(path)}"
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
  /// A condition on the body as a whole: an exact, pattern or `json`
  /// condition, or a `form` or `xml` condition with no field or path,
  /// which fails when the request's Content-Type does not say the body is
  /// a form, or the body is not XML.
  Body(@definitions.BodyCondition)
  Form(String, @definitions.ValueCondition)
  Xml(@xml.Path, @definitions.ValueCondition)
  /// The Scenario `name`, the state the Stub requires of it, and the state
  /// it is in.
  Scenario(name~ : String, required~ : String, current~ : String)
  /// The method of a request to a CRUD Stub, which serves only these
  /// methods at the request path's shape.
  CrudMethod(ReadOnlyArray[String])
  /// The path of a request to a CRUD Stub with this path, which is neither
  /// its list path nor an item path.
  CrudPath(String)
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
    let failed = match stub.serves {
      Ordinary(ordinary) => {
        let failed = self.failed(ordinary.request)
        // The state a Stub requires counts after its request conditions.
        if ordinary.scenario is Some({ name, requires: Some(required), .. }) {
          let current = current_state(states, name)
          if current != required {
            failed.push(Failed::Scenario(name~, required~, current~))
          }
        }
        failed
      }
      Crud(crud) => self.crud_failed(crud)
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
/// body. The fields of a `form` condition and the paths of an `xml`
/// condition count one by one, in the Stub's order; such a condition with
/// no field or path counts as the body.
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
    Some(Form(fields)) if fields.length() > 0 =>
      for condition in fields {
        if !self.form_meets(condition) {
          out.push(Failed::Form(condition.0, condition.1))
        }
      }
    Some(Xml(paths)) if paths.length() > 0 =>
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
/// The conditions of the CRUD Stub `crud` that the request fails, in the
/// order method, path. A CRUD Stub counts two: the path, which fails when
/// it is neither the list path nor an item path, and the method, which
/// fails when the Stub does not serve it at the path's shape, or at either
/// shape when the path fails.
fn Incoming::crud_failed(
  self : Incoming,
  crud : @definitions.Crud,
) -> Array[Failed] {
  let out = []
  let shape = crud.shape(self.path)
  let methods = @definitions.crud_methods(shape)
  let mut served = false
  for i in 0..<methods.length() {
    if methods[i] == self.request.meth {
      served = true
      break
    }
  }
  if !served {
    out.push(Failed::CrudMethod(methods))
  }
  if shape is None {
    out.push(Failed::CrudPath(crud.path))
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
        actual: @cookies.parse(self.request.headers).get(name).unwrap_or([]),
      }
    Body(body) =>
      {
        condition: Body,
        expected: match body {
          Exact(bytes) => Exact(@utf8.decode_lossy(bytes))
          Pattern(pattern) => Pattern(pattern.source)
          Json(condition) => Json(condition.to_json())
          // Only a condition with no field or path fails as the body; any
          // other fails field by field, or path by path.
          Form(_) => Form
          Xml(_) => Xml
        },
        actual: [@utf8.decode_lossy(self.request.body)],
      }
    Form(name, value) =>
      {
        condition: Form(name),
        expected: expected(value),
        actual: self.form_values(name),
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
    CrudMethod(methods) =>
      {
        condition: Method,
        expected: CrudMethods(methods),
        actual: [self.request.meth],
      }
    CrudPath(path) =>
      { condition: Path, expected: CrudPath(path), actual: [self.path], }
  }
}

///|
/// What a value condition expects, as the Stub writes it.
fn expected(condition : @definitions.ValueCondition) -> Expected {
  match condition {
    Has(Exact(text)) => Exact(text)
    Has(Pattern(pattern)) => Pattern(pattern.source)
    // The test that every value passes is that of `$exists: true`.
    Has(Any) => Exists(true)
    Not(inner) => Not(expected(inner))
    Exists(present) => Exists(present)
  }
}
