// Reading and validating Definition files. The JSON Schema in
// schema/v1/definitions.json is the contract: what it rejects, smock
// rejects too. Rules that span the definition set (unique Mock names,
// Hosts and Stub IDs, at most one Default Mock, Stubs that name a declared
// Mock) are beyond the Schema.

///|
/// Parses a Definition file, JSON or YAML, into its top-level object, or
/// the problem that stops it from being read. A YAML file gives the tree of
/// the equivalent JSON file, so everything after parsing is shared.
fn parse_file(
  name : String,
  bytes : Bytes,
) -> Result[Map[String, Json], Diagnostic] {
  let problem = (pointer : String, message : String) => {
    Err(Diagnostic::{ file: name, pointer, message, })
  }
  let yaml = name.has_suffix(".yaml") || name.has_suffix(".yml")
  if !yaml && !name.has_suffix(".json") {
    return problem("", "a Definition file name ends in .json, .yaml or .yml")
  }
  let text = @utf8.decode(bytes) catch {
    _ => return problem("", "not valid UTF-8")
  }
  let json = if yaml {
    @yaml.parse(text) catch {
      ParseError(pointer~, message~) => return problem(pointer, message)
    }
  } else {
    let json = @json.parse(text) catch {
      err => return problem("", "not valid JSON: \{err}")
    }
    if first_duplicate_key(text) is Some(pointer) {
      return problem(pointer, "duplicate key")
    }
    json
  }
  match json {
    Object(top) => Ok(top)
    _ => problem("", "must be an object")
  }
}

///|
/// The names of the Mocks the parsed files declare, so that a Stub may name
/// a Mock declared in any file, earlier or later.
fn declared_mocks(
  files : Array[(String, Result[Map[String, Json], Diagnostic])],
) -> Set[String] {
  let names = Set([])
  for file in files {
    guard file.1 is Ok(top) && top.get("mocks") is Some(Array(mocks)) else {
      continue
    }
    for mock in mocks {
      if mock is Object(mock) && mock.get("name") is Some(String(name)) {
        names.add(name)
      }
    }
  }
  names
}

///|
/// Where a value is in a definition set: the Definition file it is in, and
/// the JSON Pointer to it within that file.
priv struct Location {
  file : String
  pointer : String
} derive(Debug, Eq)

///|
/// `<file>: <pointer>`, as problems name a place.
impl Show for Location with fn output(self, logger) {
  logger.write_string("\{self.file}: \{self.pointer}")
}

///|
/// A Mock's claim to what only one Mock may have, such as a Host: the
/// Mock's name and where the claim is made.
priv struct Claim {
  mock : String
  at : Location
}

///|
/// Reads Definition files one after another, collecting what they declare
/// and every problem in them.
priv struct Reader {
  diagnostics : Array[Diagnostic]
  /// The names of the Mocks any file of the set declares.
  declared : Set[String]
  /// The Mocks read so far.
  mocks : Array[MockDecl]
  /// Where each Mock name was first declared.
  mock_names : Map[String, Location]
  /// Each Host claimed so far, normalised, with its claim.
  hosts : Map[String, Claim]
  /// The claim of the Mock marked `default` so far, if any.
  mut default_mock : Claim?
  /// The Stubs read so far.
  stubs : Array[Stub]
  /// Where each Stub ID was first used: the Stub's `id` member.
  stub_ids : Map[String, Location]
  /// Where each Stub read so far is declared, by its ID: the Stub itself.
  stub_locations : Map[String, Location]
  /// The body files, by their name relative to the body-file subdirectory.
  body_files : Map[String, Bytes]
}

///|
fn Reader::new(
  declared~ : Set[String],
  body_files~ : Map[String, Bytes],
) -> Reader {
  {
    diagnostics: [],
    declared,
    body_files,
    mocks: [],
    mock_names: Map([]),
    hosts: Map([]),
    default_mock: None,
    stubs: [],
    stub_ids: Map([]),
    stub_locations: Map([]),
  }
}

///|
/// A Mock as a Definition file declares it.
priv struct MockDecl {
  name : String
  /// The Hosts, as declared, each with its JSON Pointer.
  hosts : Array[(String, String)]
  /// The JSON Pointer of `default` when it is true.
  default : String?
  /// The status of the response when no Stub matches.
  no_match_status : Int
  /// The header fields of the response when no Stub matches.
  no_match_headers : Array[(String, String)]
  /// Whether the Journal records the requests the Mock answers.
  journal : Bool
}

///|
/// Declares `mock`, at `pointer` in `file`, unless an earlier Mock has its
/// name. Then claims its Hosts, unless another Mock claims one of them
/// already, and makes it the Default Mock when it is marked `default`,
/// unless an earlier Mock is.
fn Reader::declare_mock(
  self : Reader,
  file : File,
  pointer : String,
  mock : MockDecl,
) -> Unit {
  let name = mock.name
  let name_pointer = child_pointer(pointer, "name")
  if self.mock_names.get(name) is Some(earlier) {
    file.error(
      name_pointer,
      "the Mock name \{name.escape()} is already declared at \{earlier}",
    )
    return
  }
  self.mock_names[name] = file.at(name_pointer)
  self.mocks.push(mock)
  for declared in mock.hosts {
    let (host, host_pointer) = declared
    let host = normalize_host(host)
    match self.hosts.get(host) {
      Some({ mock: owner, .. }) if owner == name => ()
      Some({ mock: owner, at: earlier, }) =>
        file.error(
          host_pointer,
          "the Host \{host.escape()} is already claimed by the Mock \{owner.escape()} at \{earlier}",
        )
      None => self.hosts[host] = { mock: name, at: file.at(host_pointer), }
    }
  }
  if mock.default is Some(default_pointer) {
    match self.default_mock {
      Some({ mock: owner, at: earlier, }) =>
        file.error(
          default_pointer,
          "the Default Mock is already \{owner.escape()}, marked at \{earlier}",
        )
      None =>
        self.default_mock = Some({ mock: name, at: file.at(default_pointer), })
    }
  }
}

///|
/// Declares `stub`, at `pointer` in `file`, unless an earlier Stub has its
/// ID or no file declares its Mock.
fn Reader::declare_stub(
  self : Reader,
  file : File,
  pointer : String,
  stub : Stub,
) -> Unit {
  let mut ok = stub.id != "" && stub.mock != ""
  if stub.id != "" {
    let id_pointer = child_pointer(pointer, "id")
    match self.stub_ids.get(stub.id) {
      Some(earlier) => {
        file.error(
          id_pointer,
          "the Stub ID \{stub.id.escape()} is already used at \{earlier}",
        )
        ok = false
      }
      None => self.stub_ids[stub.id] = file.at(id_pointer)
    }
  }
  if stub.mock != "" && !self.declared.contains(stub.mock) {
    file.error(
      child_pointer(pointer, "mock"),
      "no file declares the Mock \{stub.mock.escape()}",
    )
    ok = false
  }
  if ok {
    self.stubs.push(stub)
    self.stub_locations[stub.id] = file.at(pointer)
  }
}

///|
/// Reads the Definition file `name`, parsed as `parsed`.
fn Reader::read_file(
  self : Reader,
  name : String,
  parsed : Result[Map[String, Json], Diagnostic],
) -> Unit {
  let file = File::{
    name,
    diagnostics: self.diagnostics,
    body_files: Some(self.body_files),
  }
  let top = match parsed {
    Ok(top) => top
    Err(problem) => {
      self.diagnostics.push(problem)
      return
    }
  }
  // Without version, a file is read as version 1. The rest of a file in
  // another version means something else, so it is not read.
  match top.get("version") {
    None | Some(Number(1.0, ..)) => ()
    Some(_) => {
      file.error("/version", "must be 1, the only format version")
      return
    }
  }
  for key, value in top {
    let pointer = child_pointer("", key)
    match key {
      "version" => ()
      "mocks" =>
        for i, mock in file.array(pointer, value) {
          let mock_pointer = child_pointer(pointer, i.to_string())
          if file.read_mock(mock_pointer, mock) is Some(mock) {
            self.declare_mock(file, mock_pointer, mock)
          }
        }
      "stubs" =>
        for i, stub in file.array(pointer, value) {
          let stub_pointer = child_pointer(pointer, i.to_string())
          if file.read_stub(stub_pointer, stub) is Some(stub) {
            self.declare_stub(file, stub_pointer, stub)
          }
        }
      _ => file.unknown_field(pointer)
    }
  }
}

///|
/// One Definition file being read: its name and where its problems go.
///
/// The readers report every problem they find and return what they could
/// read. A definition set with any problem never becomes a snapshot, so
/// what they return then does not matter.
priv struct File {
  name : String
  diagnostics : Array[Diagnostic]
  /// The body files of the set, which Stubs refer to, or `None` for an
  /// Ephemeral Stub, whose body must be inline.
  body_files : Map[String, Bytes]?
}

///|
/// Where the value at `pointer` in the file is.
fn File::at(self : File, pointer : String) -> Location {
  { file: self.name, pointer, }
}

///|
fn File::error(self : File, pointer : String, message : String) -> Unit {
  self.diagnostics.push({ file: self.name, pointer, message, })
}

///|
fn File::unknown_field(self : File, pointer : String) -> Unit {
  self.error(pointer, "is not a known field")
}

///|
/// Reports `key` missing from `object`, the value at `pointer`.
fn File::require(
  self : File,
  object : Map[String, Json],
  pointer : String,
  key : String,
) -> Unit {
  if !object.contains(key) {
    self.error(pointer, "needs \"\{key}\"")
  }
}

///|
/// Reads a Mock. It has none when it has no usable name.
fn File::read_mock(self : File, pointer : String, json : Json) -> MockDecl? {
  guard json is Object(mock) else {
    self.error(pointer, "must be an object")
    return None
  }
  let mut name = None
  let mut hosts = []
  let mut default = None
  let mut no_match_status = 404
  let mut no_match_headers = []
  let mut journal = true
  for key, value in mock {
    let field = child_pointer(pointer, key)
    match key {
      "name" => name = self.name(field, value)
      "hosts" => hosts = self.read_hosts(field, value)
      "default" =>
        match value {
          True => default = Some(field)
          False => ()
          _ => self.error(field, "must be true or false")
        }
      "noMatch" => {
        let (status, headers) = self.read_no_match(field, value)
        no_match_status = status
        no_match_headers = headers
      }
      "journal" =>
        match value {
          True => journal = true
          False => journal = false
          _ => self.error(field, "must be true or false")
        }
      _ => self.unknown_field(field)
    }
  }
  self.require(mock, pointer, "name")
  name.map(name => {
    name,
    hosts,
    default,
    no_match_status,
    no_match_headers,
    journal,
  })
}

///|
/// Reads the Hosts of a Mock, each with its JSON Pointer.
fn File::read_hosts(
  self : File,
  pointer : String,
  json : Json,
) -> Array[(String, String)] {
  let out = []
  for i, host in self.array(pointer, json) {
    let field = child_pointer(pointer, i.to_string())
    match host {
      String(host) if is_host(host) && is_reachable_host(host) =>
        out.push((host, field))
      String(host) if host.contains("*") =>
        self.error(field, "must be an exact name: Hosts have no wildcards")
      _ =>
        self.error(
          field, "must be a host name or an IP address, optionally with a port, such as users.example.com or [::1]:8080",
        )
    }
  }
  out
}

///|
/// Reads how a Mock answers when no Stub matches, and returns the status
/// and the header fields.
fn File::read_no_match(
  self : File,
  pointer : String,
  json : Json,
) -> (Int, Array[(String, String)]) {
  let mut status = 404
  let mut headers = []
  guard json is Object(fields) else {
    self.error(pointer, "must be an object")
    return (status, headers)
  }
  for key, value in fields {
    let field = child_pointer(pointer, key)
    match key {
      "status" => status = self.read_status(field, value)
      "headers" =>
        headers = self
          .read_headers(field, value, set_by_smock=no_match_names_set_by_smock)
          .map(header => (header.0, header.1))
      _ => self.unknown_field(field)
    }
  }
  (status, headers)
}

///|
/// Reads a response status: an integer from 200 to 599.
fn File::read_status(self : File, pointer : String, json : Json) -> Int {
  self
  .read_integer(pointer, json, min=200L, max=599L)
  .map_or(0, n => n.to_int())
}

///|
/// Reads an integer from `min` to `max`, which a JSON number holds exactly,
/// or reports that the value must be one.
fn File::read_integer(
  self : File,
  pointer : String,
  json : Json,
  min~ : Int64,
  max~ : Int64,
) -> Int64? {
  match json {
    Number(n, ..) if n == n.floor() &&
      n >= min.to_double() &&
      n <= max.to_double() => Some(n.to_int64())
    _ => {
      self.error(pointer, "must be an integer from \{min} to \{max}")
      None
    }
  }
}

///|
/// Reads a Stub. Its ID or its Mock name is `""` when it has no usable one.
fn File::read_stub(self : File, pointer : String, json : Json) -> Stub? {
  guard json is Object(stub) else {
    self.error(pointer, "must be an object")
    return None
  }
  let mut id = ""
  let mut mock = ""
  let mut priority = None
  let mut request = no_conditions()
  let mut response = Response::{
    status: 0,
    headers: ReadOnlyArray::from_array([]),
    body: Bytes(b""),
    template: None,
  }
  let mut fault = None
  let mut scenario = None
  for key, value in stub {
    let field = child_pointer(pointer, key)
    match key {
      "id" => id = self.name(field, value).unwrap_or("")
      "mock" => mock = self.name(field, value).unwrap_or("")
      "request" => request = self.read_conditions(field, value)
      "response" => response = self.read_response(pointer, field, value)
      "priority" => priority = self.read_priority(field, value)
      "fault" => fault = self.read_fault(field, value)
      "scenario" => scenario = self.read_scenario(field, value)
      _ => self.unknown_field(field)
    }
  }
  self.require(stub, pointer, "id")
  self.require(stub, pointer, "mock")
  self.require(stub, pointer, "response")
  Some({ id, mock, priority, request, scenario, response, fault, })
}

///|
/// Reads a Scenario clause: the Scenario's `name`, and `requires`,
/// `moveTo` or both, each a non-empty name.
fn File::read_scenario(
  self : File,
  pointer : String,
  json : Json,
) -> ScenarioClause? {
  guard json is Object(clause) else {
    self.error(pointer, "must be an object")
    return None
  }
  let mut name = None
  let mut requires = None
  let mut move_to = None
  for key, value in clause {
    let field = child_pointer(pointer, key)
    match key {
      "name" => name = self.name(field, value)
      "requires" => requires = self.name(field, value)
      "moveTo" => move_to = self.name(field, value)
      _ => self.unknown_field(field)
    }
  }
  self.require(clause, pointer, "name")
  // A clause without either does nothing, which is surely a mistake.
  if !clause.contains("requires") && !clause.contains("moveTo") {
    self.error(pointer, "must give requires, moveTo or both")
  }
  name.map(name => { name, requires, move_to, })
}

///|
/// Reads the Faults of a Stub.
fn File::read_fault(self : File, pointer : String, json : Json) -> Fault? {
  guard json is Object(fault) else {
    self.error(pointer, "must be an object")
    return None
  }
  let mut delay = None
  let mut connection = None
  let mut seed = None
  for key, value in fault {
    let field = child_pointer(pointer, key)
    match key {
      "delay" => delay = self.read_delay(field, value)
      "connection" => connection = self.read_connection_fault(field, value)
      "seed" => seed = self.read_seed(field, value)
      _ => self.unknown_field(field)
    }
  }
  Some({ delay, connection, seed, })
}

///|
/// Reads a delay: exactly one distribution, and a probability.
fn File::read_delay(self : File, pointer : String, json : Json) -> Delay? {
  guard json is Object(delay) else {
    self.error(pointer, "must be an object")
    return None
  }
  let mut distribution = None
  let mut probability = 1.0
  for key, value in delay {
    let field = child_pointer(pointer, key)
    match key {
      "fixed" =>
        distribution = self.read_milliseconds(field, value).map(ms => Fixed(ms))
      "uniform" => distribution = self.read_uniform(field, value)
      "lognormal" => distribution = self.read_lognormal(field, value)
      "probability" => probability = self.read_probability(field, value)
      _ => self.unknown_field(field)
    }
  }
  let given = ["fixed", "uniform", "lognormal"].filter(key => {
    delay.contains(key)
  })
  match given.length() {
    0 =>
      self.error(
        pointer, "needs one of \"fixed\", \"uniform\" and \"lognormal\"",
      )
    1 => ()
    _ => {
      let given = given.map(key => "\"\{key}\"").join(" and ")
      self.error(
        pointer,
        "has \{given}; give exactly one of \"fixed\", \"uniform\" and \"lognormal\"",
      )
    }
  }
  distribution.map(distribution => { distribution, probability, })
}

///|
/// Reads a uniform distribution: `min` and `max`, where `min` does not
/// exceed `max`.
fn File::read_uniform(
  self : File,
  pointer : String,
  json : Json,
) -> Distribution? {
  guard json is Object(uniform) else {
    self.error(pointer, "must be an object")
    return None
  }
  let mut min = None
  let mut max = None
  for key, value in uniform {
    let field = child_pointer(pointer, key)
    match key {
      "min" => min = self.read_milliseconds(field, value)
      "max" => max = self.read_milliseconds(field, value)
      _ => self.unknown_field(field)
    }
  }
  self.require(uniform, pointer, "min")
  self.require(uniform, pointer, "max")
  guard min is Some(min) && max is Some(max) else { return None }
  if min > max {
    self.error(pointer, "\"min\" (\{min}) must not exceed \"max\" (\{max})")
    return None
  }
  Some(Uniform(min~, max~))
}

///|
/// Reads a log-normal distribution: its `median` and its `sigma`.
fn File::read_lognormal(
  self : File,
  pointer : String,
  json : Json,
) -> Distribution? {
  guard json is Object(lognormal) else {
    self.error(pointer, "must be an object")
    return None
  }
  let mut median = None
  let mut sigma = None
  for key, value in lognormal {
    let field = child_pointer(pointer, key)
    match key {
      "median" => median = self.read_milliseconds(field, value)
      "sigma" =>
        match value {
          Number(n, ..) if n >= 0.0 => sigma = Some(n)
          _ => self.error(field, "must be a number of 0 or more")
        }
      _ => self.unknown_field(field)
    }
  }
  self.require(lognormal, pointer, "median")
  self.require(lognormal, pointer, "sigma")
  guard median is Some(median) && sigma is Some(sigma) else { return None }
  Some(Lognormal(median~, sigma~))
}

///|
/// Reads a connection Fault: its kind and a probability.
fn File::read_connection_fault(
  self : File,
  pointer : String,
  json : Json,
) -> ConnectionFault? {
  guard json is Object(connection) else {
    self.error(pointer, "must be an object")
    return None
  }
  let mut kind = None
  let mut probability = 1.0
  for key, value in connection {
    let field = child_pointer(pointer, key)
    match key {
      "kind" =>
        match value {
          String(name) if connection_kind(name) is Some(named) =>
            kind = Some(named)
          _ => self.error(field, "must be \"reset\", \"close\" or \"partial\"")
        }
      "probability" => probability = self.read_probability(field, value)
      _ => self.unknown_field(field)
    }
  }
  self.require(connection, pointer, "kind")
  kind.map(kind => { kind, probability, })
}

///|
/// Reads a probability: a number from 0 to 1.
fn File::read_probability(self : File, pointer : String, json : Json) -> Double {
  match json {
    Number(n, ..) if n >= 0.0 && n <= 1.0 => n
    _ => {
      self.error(pointer, "must be a number from 0 to 1")
      1.0
    }
  }
}

///|
/// Reads a duration in whole milliseconds: an integer from 0 to
/// `max_milliseconds`.
fn File::read_milliseconds(self : File, pointer : String, json : Json) -> Int? {
  self
  .read_integer(pointer, json, min=0L, max=max_milliseconds.to_int64())
  .map(n => n.to_int())
}

///|
/// Reads a seed: an integer from 0 to `max_seed`.
fn File::read_seed(self : File, pointer : String, json : Json) -> UInt64? {
  self
  .read_integer(pointer, json, min=0L, max=max_seed.reinterpret_as_int64())
  .map(n => n.reinterpret_as_uint64())
}

///|
/// The conditions of a Stub without `request`: none, so it matches every
/// request.
fn no_conditions() -> Conditions {
  {
    meth: None,
    path: None,
    query: ReadOnlyArray::from_array([]),
    headers: ReadOnlyArray::from_array([]),
    cookies: ReadOnlyArray::from_array([]),
    body: None,
  }
}

///|
/// Reads a priority: a 32-bit integer.
fn File::read_priority(self : File, pointer : String, json : Json) -> Int? {
  self
  .read_integer(
    pointer,
    json,
    min=@int.MIN_VALUE.to_int64(),
    max=@int.MAX_VALUE.to_int64(),
  )
  .map(n => n.to_int())
}

///|
fn File::read_conditions(
  self : File,
  pointer : String,
  json : Json,
) -> Conditions {
  guard json is Object(request) else {
    self.error(pointer, "must be an object")
    return no_conditions()
  }
  let mut meth = None
  let mut path = None
  let mut query = []
  let mut headers = []
  let mut cookies = []
  let mut body = None
  for key, value in request {
    let field = child_pointer(pointer, key)
    match key {
      "method" =>
        match value {
          String(value) if @http1.is_token(value) => meth = Some(value)
          _ => self.error(field, "must be an HTTP token, such as GET")
        }
      "path" =>
        match value {
          String(value) if value.has_prefix("/") =>
            path = Some(ValueCondition::Exact(value))
          String(_) => self.error(field, "must start with /")
          Object(condition) =>
            path = self
              .read_pattern(field, condition)
              .map(pattern => ValueCondition::Pattern(pattern))
          _ => self.error(field, "must be a string or an object")
        }
      "query" => query = self.read_value_conditions(field, value)
      "headers" =>
        headers = self
          .read_value_conditions(field, value, header_names=true)
          .map(header => (header.0.to_lower(), header.1))
      "cookies" => cookies = self.read_value_conditions(field, value)
      "body" => body = self.read_body_condition(field, value)
      _ => self.unknown_field(field)
    }
  }
  {
    meth,
    path,
    query: ReadOnlyArray::from_array(query),
    headers: ReadOnlyArray::from_array(headers),
    cookies: ReadOnlyArray::from_array(cookies),
    body,
  }
}

///|
/// Reads a condition on the request body: an exact text, or an object
/// holding one of the kinds `body_kinds` lists: a `json` condition, a
/// pattern, a `form` condition or an `xml` condition.
fn File::read_body_condition(
  self : File,
  pointer : String,
  json : Json,
) -> BodyCondition? {
  let condition = match json {
    String(text) => return Some(Exact(@utf8.encode(text)))
    Object(condition) => condition
    _ => {
      self.error(pointer, "must be a string or an object")
      return None
    }
  }
  let mut out = None
  for key, value in condition {
    let field = child_pointer(pointer, key)
    match key {
      "json" =>
        out = self
          .read_json_condition(field, value)
          .map(condition => BodyCondition::Json(condition))
      "pattern" =>
        if self.string(field, value) is Some(source) &&
          self.compile(field, source) is Some(pattern) {
          out = Some(BodyCondition::Pattern(pattern))
        }
      "form" =>
        out = Some(
          BodyCondition::Form(
            ReadOnlyArray::from_array(self.read_value_conditions(field, value)),
          ),
        )
      "xml" =>
        out = self
          .read_xml_conditions(field, value)
          .map(conditions => BodyCondition::Xml(conditions))
      _ => self.unknown_field(field)
    }
  }
  let given = body_kinds.filter(kind => condition.contains(kind))
  match given.length() {
    0 => self.error(pointer, "needs \{listed_body_kinds}")
    1 => ()
    _ =>
      self.error(
        pointer,
        "has \{quoted_list(given, "and")}; give only one of \{listed_body_kinds}",
      )
  }
  out
}

///|
/// The kinds of body condition an object may hold, exactly one of them.
let body_kinds : Array[String] = ["json", "pattern", "form", "xml"]

///|
/// The kinds of body condition, as messages list them.
let listed_body_kinds : String = quoted_list(body_kinds, "or")

///|
/// Reads an `xml` condition, the object at `pointer`: paths into an XML
/// body, each compiled, and their value conditions. It has none when a path
/// does not compile or a condition is malformed, and each problem is
/// reported.
fn File::read_xml_conditions(
  self : File,
  pointer : String,
  json : Json,
) -> ReadOnlyArray[(@xml.Path, ValueCondition)]? {
  guard json is Object(members) else {
    self.error(pointer, "must be an object")
    return None
  }
  let out = []
  for source, value in members {
    let field = child_pointer(pointer, source)
    let path = try @xml.compile_path(source) catch {
      error => {
        self.error(field, "is not a valid XML path: \{error}")
        None
      }
    } noraise {
      path => Some(path)
    }
    if self.read_value_condition(field, value) is Some(condition) &&
      path is Some(path) {
      out.push((path, condition))
    }
  }
  guard out.length() == members.length() else { return None }
  Some(ReadOnlyArray::from_array(out))
}

///|
/// Reads a `json` condition, the value at `pointer`, with its operators,
/// and compiles each pattern in it. It has none when it is malformed, and
/// each problem is reported.
fn File::read_json_condition(
  self : File,
  pointer : String,
  json : Json,
) -> JsonCondition? {
  self
  .read_json_condition_value(pointer, json)
  .map(expected => JsonCondition::{ value: deep_copy(json), expected, })
}

///|
/// Reads `json`, the value at `pointer` in a `json` condition, as matching
/// expects it. An object whose only member is `pattern`, with a string, is
/// a pattern object, and its pattern is compiled. An object with a key that
/// starts with `$` but not with `$$` is an operator object; a key that
/// starts with `$$` writes the literal key without its first `$`. It has
/// none when it is malformed, and each problem is reported.
fn File::read_json_condition_value(
  self : File,
  pointer : String,
  json : Json,
) -> Expected? {
  match json {
    Object(members) => {
      if members.length() == 1 && members.get("pattern") is Some(String(source)) {
        return self
          .compile(child_pointer(pointer, "pattern"), source)
          .map(pattern => Expected::Pattern(pattern))
      }
      if operator_key(members) is Some(_) {
        return self.read_json_operator(pointer, members)
      }
      let keys = []
      let values = []
      for key, value in members {
        if self.read_json_condition_value(child_pointer(pointer, key), value)
          is Some(expected) {
          keys.push(if key.has_prefix("$$") { key[1:].to_owned() } else { key })
          values.push(expected)
        }
      }
      guard values.length() == members.length() else { return None }
      Some(Object(FixedArray::from_array(keys), FixedArray::from_array(values)))
    }
    Array(items) => {
      let values = []
      for i, item in items {
        if self.read_json_condition_value(
            child_pointer(pointer, i.to_string()),
            item,
          )
          is Some(expected) {
          values.push(expected)
        }
      }
      guard values.length() == items.length() else { return None }
      Some(Array(FixedArray::from_array(values)))
    }
    _ => Some(Scalar(json))
  }
}

///|
/// Reads `members`, the operator object at `pointer` in a `json` condition,
/// with its operand read as a value of a `json` condition in turn. It has
/// none when it is malformed.
fn File::read_json_operator(
  self : File,
  pointer : String,
  members : Map[String, Json],
) -> Expected? {
  guard self.read_operator(pointer, members, json_operators, literal_keys=true)
    is Some((key, operand)) else {
    return None
  }
  let at = child_pointer(pointer, key)
  match key {
    "$not" =>
      self
      .read_json_condition_value(at, operand)
      .map(expected => Expected::Not(expected))
    "$includes" =>
      self
      .read_json_condition_value(at, operand)
      .map(expected => Expected::Includes(expected))
    _ => self.read_exists(at, operand).map(present => Exists(present))
  }
}

///|
/// Reads conditions on named values, such as query parameters: an object
/// whose members are names and value conditions. Names are literal, even
/// when they start with `$`. With `header_names`, each name must be a valid
/// header name.
fn File::read_value_conditions(
  self : File,
  pointer : String,
  json : Json,
  header_names? : Bool = false,
) -> Array[(String, ValueCondition)] {
  let out = []
  guard json is Object(conditions) else {
    self.error(pointer, "must be an object")
    return out
  }
  for name, value in conditions {
    let field = child_pointer(pointer, name)
    if header_names && !@http1.is_token(name) {
      self.error(field, "is not a valid header name")
      continue
    }
    if self.read_value_condition(field, value) is Some(condition) {
      out.push((name, condition))
    }
  }
  out
}

///|
/// Reads a value condition, the value at `pointer`: an exact value, a
/// pattern condition, or an operator object, whose operand is read in
/// turn. It has none when it is malformed.
fn File::read_value_condition(
  self : File,
  pointer : String,
  json : Json,
) -> ValueCondition? {
  let members = match json {
    String(value) => return Some(Exact(value))
    Object(members) => members
    _ => {
      self.error(pointer, "must be a string or an object")
      return None
    }
  }
  guard operator_key(members) is Some(_) else {
    return self.read_pattern(pointer, members).map(pattern => Pattern(pattern))
  }
  guard self.read_operator(
      pointer,
      members,
      value_operators,
      literal_keys=false,
    )
    is Some((key, operand)) else {
    return None
  }
  let at = child_pointer(pointer, key)
  match key {
    "$not" =>
      self
      .read_value_condition(at, operand)
      .map(condition => ValueCondition::Not(condition))
    _ => self.read_exists(at, operand).map(present => Exists(present))
  }
}

///|
/// The operators of a query parameter's, a header's or a cookie's value, in
/// the order messages list them.
let value_operators : Array[String] = ["$not", "$exists"]

///|
/// The operators of a value in a `json` condition, in the order messages
/// list them. One of them where it is not allowed is reported as allowed
/// only in a `json` condition, not as unknown.
let json_operators : Array[String] = ["$not", "$exists", "$includes"]

///|
/// The key of `members`, an object in a value position, that makes it an
/// operator object, if any: the first key that starts with `$` but not with
/// `$$`, which writes a literal key that starts with `$` in a `json`
/// condition.
fn operator_key(members : Map[String, Json]) -> String? {
  for key, _ in members {
    if is_operator_like(key) {
      return Some(key)
    }
  }
  None
}

///|
/// Whether `key`, in an object in a value position, is reserved for
/// operators: it starts with `$` but not with `$$`.
fn is_operator_like(key : String) -> Bool {
  key.has_prefix("$") && !key.has_prefix("$$")
}

///|
/// Reads `members`, an operator object at `pointer`, and returns its
/// operator and the operator's operand. An operator is the only key of its
/// object, and it is one of `operators`, those allowed in its position;
/// each key that breaks this is reported, and then there is none. What is
/// reported does not depend on the order of the keys:
///
/// - each key that starts with `$` and is no operator at all is not an
///   operator; with `literal_keys`, in a `json` condition, the message
///   suggests `$$` for a literal key;
/// - each operator not allowed here is allowed only in a `json` condition;
/// - any other key is not allowed beside the operator, the first of
///   `json_operators` among the keys. When there is none, the object is
///   most likely literal JSON with keys that start with `$`, so only those
///   keys are reported.
fn File::read_operator(
  self : File,
  pointer : String,
  members : Map[String, Json],
  operators : Array[String],
  literal_keys~ : Bool,
) -> (String, Json)? {
  let operator = json_operators.search_by(key => members.contains(key))
  let mut valid = true
  for key, _ in members {
    let at = child_pointer(pointer, key)
    if is_operator_like(key) && !json_operators.contains(key) {
      let hint = if literal_keys {
        "; write \{("$" + key).escape()} for the literal key \{key.escape()}"
      } else {
        ""
      }
      self.error(
        at,
        "is not an operator: the operators here are \{quoted_list(operators, "and")}\{hint}",
      )
      valid = false
    } else if json_operators.contains(key) && !operators.contains(key) {
      self.error(at, "is allowed only in a json condition")
      valid = false
    } else if operator is Some(i) && key != json_operators[i] {
      self.error(
        at,
        "is not allowed beside \{json_operators[i].escape()}: an operator is the only key of its object",
      )
      valid = false
    }
  }
  match operator {
    Some(i) if valid => {
      let key = json_operators[i]
      members.get(key).map(operand => (key, operand))
    }
    _ => None
  }
}

///|
/// `words`, each in quotes, separated by commas, with `last` before the
/// last one: `"a"`, `"a" or "b"`, `"a", "b" or "c"`.
fn quoted_list(words : Array[String], last : String) -> String {
  let quoted = words.map(word => word.escape())
  match quoted.length() {
    0 => ""
    1 => quoted[0]
    n => quoted[:n - 1].join(", ") + " \{last} " + quoted[n - 1]
  }
}

///|
/// Reads the operand of `$exists`, the value at `pointer`: true or false.
fn File::read_exists(self : File, pointer : String, json : Json) -> Bool? {
  match json {
    True => Some(true)
    False => Some(false)
    _ => {
      self.error(pointer, "must be true or false")
      None
    }
  }
}

///|
/// Reads a pattern condition, the object at `pointer`, and compiles its
/// pattern. It has none when the object is malformed or the pattern does
/// not compile.
fn File::read_pattern(
  self : File,
  pointer : String,
  condition : Map[String, Json],
) -> Pattern? {
  let mut out = None
  for key, value in condition {
    let field = child_pointer(pointer, key)
    match key {
      "pattern" =>
        if self.string(field, value) is Some(source) {
          out = self.compile(field, source)
        }
      _ => self.unknown_field(field)
    }
  }
  self.require(condition, pointer, "pattern")
  out
}

///|
/// Compiles the pattern `source`, the value at `pointer`, or reports why
/// it does not compile, with the position of the problem in the pattern.
fn File::compile(self : File, pointer : String, source : String) -> Pattern? {
  try @re2.compile(source) catch {
    error => {
      self.error(pointer, "is not a valid pattern: \{error}")
      None
    }
  } noraise {
    regex => Some({ source, regex, })
  }
}

///|
/// Reads a string that contains none of the characters in `forbidden`, or
/// reports `message`.
fn File::string_without(
  self : File,
  pointer : String,
  json : Json,
  forbidden : String,
  message : String,
) -> String? {
  guard self.string(pointer, json) is Some(value) else { return None }
  if value.contains_any(chars=forbidden) {
    self.error(pointer, message)
    return None
  }
  Some(value)
}

///|
/// Reads a reference to a body file and returns the file's bytes. The path
/// is relative to the body-file subdirectory and stays inside it: its
/// names are not empty, and none starts with `.`, as smock skips such
/// files.
fn File::read_body_file(self : File, pointer : String, json : Json) -> Bytes {
  guard self.body_files is Some(body_files) else {
    self.error(
      pointer, "is not allowed in an Ephemeral Stub, whose body must be inline: give \"body\" instead",
    )
    return b""
  }
  guard self.string(pointer, json) is Some(path) else { return b"" }
  let inside = path
    .split("/")
    .all(name => !name.is_empty() && !name.has_prefix("."))
  if !inside {
    self.error(
      pointer, "must be a path inside the body-file subdirectory, such as users/1.json, with no name starting with .",
    )
    return b""
  }
  match body_files.get(path) {
    Some(bytes) => bytes
    None => {
      self.error(
        pointer,
        "no body file \{path.escape()} in the body-file subdirectory",
      )
      b""
    }
  }
}

///|
/// The header names, in lower case, that smock sets on a Stub's response,
/// so that the Stub cannot give them.
let response_names_set_by_smock : Array[String] = [
  "content-length", "transfer-encoding", "connection", "smock-mock",
]

///|
/// The header names, in lower case, that smock sets on a Mock's response
/// when no Stub matches: those of a Stub's response, and the Content-Type
/// of its JSON body and the Near miss.
let no_match_names_set_by_smock : Array[String] = [
  ..response_names_set_by_smock, "content-type", "smock-near-miss",
]

///|
/// Reads response headers: an object whose members are field names and
/// values. A value is a string, or a non-empty array of strings to send
/// the field once per value, in order; Content-Type takes one string.
/// Returns the fields as (name, value, JSON Pointer of the value). Header
/// names are case-insensitive, so no two may differ only in case, a rule
/// the JSON Schema cannot express, and none may be one of `set_by_smock`.
fn File::read_headers(
  self : File,
  pointer : String,
  json : Json,
  set_by_smock? : Array[String] = response_names_set_by_smock,
) -> Array[(String, String, String)] {
  let out = []
  guard json is Object(headers) else {
    self.error(pointer, "must be an object")
    return out
  }
  // Each header name so far, as given, by its lower case.
  let names : Map[String, String] = Map([])
  for name, value in headers {
    let field = child_pointer(pointer, name)
    let lower = name.to_lower()
    if !@http1.is_token(name) {
      self.error(field, "is not a valid header name")
    } else if set_by_smock.contains(lower) {
      self.error(field, "is set by smock and cannot be given")
    } else if names.get(lower) is Some(earlier) {
      self.error(
        field,
        "the header name \{earlier.escape()} is already given: header names are case-insensitive",
      )
    } else {
      names[lower] = name
    }
    let push_field = (text : String, at : String) => {
      if @http1.is_field_value(text) {
        out.push((name, text, at))
      } else {
        self.error(at, "must not contain control characters other than tab")
      }
    }
    match value {
      String(text) => push_field(text, field)
      // smock reads Content-Type, to escape a templated body, so it takes
      // one string, where it can be given.
      _ if lower == "content-type" && !set_by_smock.contains(lower) =>
        self.error(field, "must be a string")
      Array([]) => self.error(field, "must not be an empty array")
      Array(items) =>
        for i, item in items {
          let at = child_pointer(field, i.to_string())
          match item {
            String(text) => push_field(text, at)
            _ => self.error(at, "must be a string")
          }
        }
      _ => self.error(field, "must be a string or an array of strings")
    }
  }
  out
}

///|
/// Reads a name or an ID: a non-empty string.
fn File::name(self : File, pointer : String, json : Json) -> String? {
  match json {
    String(value) if value != "" => Some(value)
    _ => {
      self.error(pointer, "must be a non-empty string")
      None
    }
  }
}

///|
fn File::string(self : File, pointer : String, json : Json) -> String? {
  match json {
    String(value) => Some(value)
    _ => {
      self.error(pointer, "must be a string")
      None
    }
  }
}

///|
/// The elements of an array, or none when `json` is not an array.
fn File::array(self : File, pointer : String, json : Json) -> Array[Json] {
  match json {
    Array(items) => items
    _ => {
      self.error(pointer, "must be an array")
      []
    }
  }
}

///|
/// The JSON Pointer (RFC 6901) to member or element `key` of the value at
/// `pointer`, with `key` escaped: `~` as `~0` and `/` as `~1`. The
/// pointers of Diagnostics are built with it, so a pointer built with it
/// elsewhere joins theirs.
pub fn child_pointer(pointer : String, key : String) -> String {
  let escaped = key
    .replace_all(old="~", new="~0")
    .replace_all(old="/", new="~1")
  "\{pointer}/\{escaped}"
}

///|
/// Whether `host`, which `is_host` accepts, is a Host a request can carry,
/// so that it can match: the value of a Host field, or an IPv6 address
/// without brackets, which then has no port; and not one that normalises
/// to no name, such as `.` or `:8080`. The JSON Schema cannot tell these
/// apart from the rest.
fn is_reachable_host(host : String) -> Bool {
  let value = if !host.contains("[") && host.find(":") != host.rev_find(":") {
    "[\{host}]"
  } else {
    host
  }
  @http1.is_host_value(value) && normalize_host(host) != ""
}

///|
/// Whether `s` can be a Host in a Definition file: letters, digits and
/// `.`, `_`, `:`, `[`, `]` and `-`, as the JSON Schema allows.
fn is_host(s : String) -> Bool {
  if s == "" {
    return false
  }
  for c in s {
    let ok = (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      "._:[]-".contains_char(c)
    if !ok {
      return false
    }
  }
  true
}
