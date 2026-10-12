// Reading and validating Definition files. The JSON Schema in
// schema/v1/definitions.json is the contract: what it rejects, smock
// rejects too. Rules that span the definition set (unique Mock names and
// Stub IDs, Stubs that name a declared Mock) are beyond the Schema.

///|
/// Parses a Definition file, JSON or YAML, into its top-level object, or
/// the problem that stops it from being read, as a JSON Pointer and a
/// message. A YAML file gives the tree of the equivalent JSON file, so
/// everything after parsing is shared.
fn parse_file(
  name : String,
  bytes : Bytes,
) -> Result[Map[String, Json], (String, String)] {
  let yaml = name.has_suffix(".yaml") || name.has_suffix(".yml")
  if !yaml && !name.has_suffix(".json") {
    return Err(("", "a Definition file name ends in .json, .yaml or .yml"))
  }
  let text = @utf8.decode(bytes) catch {
    _ => return Err(("", "not valid UTF-8"))
  }
  let json = if yaml {
    @yaml.parse(text) catch {
      ParseError(pointer~, message~) => return Err((pointer, message))
    }
  } else {
    @json.parse(text) catch {
      err => return Err(("", "not valid JSON: \{err}"))
    }
  }
  match json {
    Object(top) => Ok(top)
    _ => Err(("", "must be an object"))
  }
}

///|
/// The names of the Mocks the parsed files declare, so that a Stub may name
/// a Mock declared in any file, earlier or later.
fn declared_mocks(
  files : Array[(String, Result[Map[String, Json], (String, String)])],
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
/// Reads Definition files one after another, collecting what they declare
/// and every problem in them.
priv struct Reader {
  diagnostics : Array[Diagnostic]
  /// The names of the Mocks any file of the set declares.
  declared : Set[String]
  /// The Mocks read so far, without their Stubs.
  mocks : Array[Mock]
  /// Where each Mock name was first declared, as `<file>: <pointer>`.
  mock_names : Map[String, String]
  /// The Stubs read so far.
  stubs : Array[Stub]
  /// Where each Stub ID was first used, as `<file>: <pointer>`.
  stub_ids : Map[String, String]
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
    stubs: [],
    stub_ids: Map([]),
  }
}

///|
/// Declares `mock`, whose name is at `pointer` in `file`, unless an
/// earlier Mock has that name.
fn Reader::declare_mock(
  self : Reader,
  file : File,
  pointer : String,
  mock : Mock,
) -> Unit {
  let name = mock.name
  match self.mock_names.get(name) {
    Some(earlier) =>
      file.error(
        pointer,
        "the Mock name \{name.escape()} is already declared at \{earlier}",
      )
    None => {
      self.mock_names[name] = "\{file.name}: \{pointer}"
      self.mocks.push(mock)
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
    let id_pointer = child(pointer, "id")
    match self.stub_ids.get(stub.id) {
      Some(earlier) => {
        file.error(
          id_pointer,
          "the Stub ID \{stub.id.escape()} is already used at \{earlier}",
        )
        ok = false
      }
      None => self.stub_ids[stub.id] = "\{file.name}: \{id_pointer}"
    }
  }
  if stub.mock != "" && !self.declared.contains(stub.mock) {
    file.error(
      child(pointer, "mock"),
      "no file declares the Mock \{stub.mock.escape()}",
    )
    ok = false
  }
  if ok {
    self.stubs.push(stub)
  }
}

///|
/// Reads the Definition file `name`, parsed as `parsed`.
fn Reader::read_file(
  self : Reader,
  name : String,
  parsed : Result[Map[String, Json], (String, String)],
) -> Unit {
  let file = File::{
    name,
    diagnostics: self.diagnostics,
    body_files: self.body_files,
  }
  let top = match parsed {
    Ok(top) => top
    Err((pointer, message)) => {
      file.error(pointer, message)
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
    let pointer = child("", key)
    match key {
      "version" => ()
      "mocks" =>
        for i, mock in file.array(pointer, value) {
          let mock_pointer = child(pointer, i.to_string())
          if file.read_mock(mock_pointer, mock) is Some(mock) {
            self.declare_mock(file, child(mock_pointer, "name"), mock)
          }
        }
      "stubs" =>
        for i, stub in file.array(pointer, value) {
          let stub_pointer = child(pointer, i.to_string())
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
  /// The body files of the set, which Stubs refer to.
  body_files : Map[String, Bytes]
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
/// Reports a field the JSON Schema defines but smock does not implement
/// yet. Such a field is never ignored.
fn File::not_supported(self : File, pointer : String) -> Unit {
  self.error(pointer, "is not supported yet")
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
/// Reads a Mock, without its Stubs, or nothing when it has no usable name.
fn File::read_mock(self : File, pointer : String, json : Json) -> Mock? {
  guard json is Object(fields) else {
    self.error(pointer, "must be an object")
    return None
  }
  let mut name = None
  let mut mock = empty_mock("")
  for key, value in fields {
    let field = child(pointer, key)
    match key {
      "name" => name = self.name(field, value)
      "noMatch" =>
        mock = { ..mock, no_match_status: self.read_no_match(field, value), }
      "hosts" | "default" | "journal" => self.not_supported(field)
      _ => self.unknown_field(field)
    }
  }
  self.require(fields, pointer, "name")
  name.map(name => { ..mock, name, })
}

///|
/// Reads how a Mock answers when no Stub matches, and returns the status.
fn File::read_no_match(self : File, pointer : String, json : Json) -> Int {
  let mut status = 404
  guard json is Object(fields) else {
    self.error(pointer, "must be an object")
    return status
  }
  for key, value in fields {
    let field = child(pointer, key)
    match key {
      "status" => status = self.read_status(field, value)
      _ => self.unknown_field(field)
    }
  }
  status
}

///|
/// Reads a response status: an integer from 200 to 599.
fn File::read_status(self : File, pointer : String, json : Json) -> Int {
  match json {
    Number(n, ..) if n == n.floor() && n >= 200.0 && n <= 599.0 => n.to_int()
    _ => {
      self.error(pointer, "must be an integer from 200 to 599")
      0
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
    body: b"",
  }
  for key, value in stub {
    let field = child(pointer, key)
    match key {
      "id" => id = self.name(field, value).unwrap_or("")
      "mock" => mock = self.name(field, value).unwrap_or("")
      "request" => request = self.read_conditions(field, value)
      "response" => response = self.read_response(field, value)
      "priority" => priority = self.read_priority(field, value)
      "fault" => self.not_supported(field)
      _ => self.unknown_field(field)
    }
  }
  self.require(stub, pointer, "id")
  self.require(stub, pointer, "mock")
  self.require(stub, pointer, "response")
  Some({ id, mock, priority, request, response, })
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
    body: None,
  }
}

///|
/// Reads a priority: a 32-bit integer.
fn File::read_priority(self : File, pointer : String, json : Json) -> Int? {
  match json {
    Number(n, ..) if n == n.floor() && n >= -2147483648.0 && n <= 2147483647.0 =>
      Some(n.to_int())
    _ => {
      self.error(pointer, "must be an integer from -2147483648 to 2147483647")
      None
    }
  }
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
  let mut body = None
  for key, value in request {
    let field = child(pointer, key)
    match key {
      "method" =>
        match value {
          String(value) if is_token(value) => meth = Some(value)
          _ => self.error(field, "must be an HTTP token, such as GET")
        }
      "path" =>
        match value {
          String(value) if value.has_prefix("/") => path = Some(value)
          String(_) => self.error(field, "must start with /")
          Object(_) =>
            self.error(field, "pattern conditions are not supported yet")
          _ => self.error(field, "must be a string")
        }
      "query" => query = self.read_value_conditions(field, value)
      "headers" =>
        headers = self
          .read_value_conditions(field, value, header_names=true)
          .map(header => (header.0.to_lower(), header.1))
      "body" => body = self.read_body_condition(field, value)
      _ => self.unknown_field(field)
    }
  }
  {
    meth,
    path,
    query: ReadOnlyArray::from_array(query),
    headers: ReadOnlyArray::from_array(headers),
    body,
  }
}

///|
/// Reads a condition on the request body: an exact text, or an object
/// holding a `json` condition.
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
    match key {
      "json" => out = Some(Json(value))
      "pattern" => ()
      _ => self.unknown_field(child(pointer, key))
    }
  }
  match (condition.contains("json"), condition.contains("pattern")) {
    (true, true) =>
      self.error(pointer, "needs \"json\" or \"pattern\", not both")
    (false, true) =>
      self.error(pointer, "pattern conditions are not supported yet")
    (false, false) => self.error(pointer, "needs \"json\" or \"pattern\"")
    (true, false) => ()
  }
  out
}

///|
/// Reads conditions on named values, such as query parameters: an object
/// whose members are names and exact values. With `header_names`, each
/// name must be a valid header name.
fn File::read_value_conditions(
  self : File,
  pointer : String,
  json : Json,
  header_names? : Bool = false,
) -> Array[(String, String)] {
  let out = []
  guard json is Object(conditions) else {
    self.error(pointer, "must be an object")
    return out
  }
  for name, value in conditions {
    let field = child(pointer, name)
    if header_names && !is_token(name) {
      self.error(field, "is not a valid header name")
      continue
    }
    match value {
      String(value) => out.push((name, value))
      Object(_) => self.error(field, "pattern conditions are not supported yet")
      _ => self.error(field, "must be a string")
    }
  }
  out
}

///|
fn File::read_response(self : File, pointer : String, json : Json) -> Response {
  let mut status = 0
  let mut headers = []
  let mut body = b""
  guard json is Object(response) else {
    self.error(pointer, "must be an object")
    return { status, headers: ReadOnlyArray::from_array(headers), body, }
  }
  for key, value in response {
    let field = child(pointer, key)
    match key {
      "status" => status = self.read_status(field, value)
      "headers" => headers = self.read_headers(field, value)
      "body" => body = @utf8.encode(self.string(field, value).unwrap_or(""))
      "bodyFile" => body = self.read_body_file(field, value)
      "template" | "events" => self.not_supported(field)
      _ => self.unknown_field(field)
    }
  }
  self.require(response, pointer, "status")
  let bodies = ["body", "bodyFile", "events"].filter(key => {
    response.contains(key)
  })
  if bodies.length() > 1 {
    let given = bodies.map(key => "\"\{key}\"").join(" and ")
    self.error(
      pointer,
      "has \{given}; give at most one of \"body\", \"bodyFile\" and \"events\"",
    )
  }
  { status, headers: ReadOnlyArray::from_array(headers), body, }
}

///|
/// Reads a reference to a body file and returns the file's bytes. The path
/// is relative to the body-file subdirectory and stays inside it: its
/// names are not empty, and none starts with `.`, as smock skips such
/// files.
fn File::read_body_file(self : File, pointer : String, json : Json) -> Bytes {
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
  match self.body_files.get(path) {
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
/// Reads response headers: an object whose members are field names and
/// string values.
fn File::read_headers(
  self : File,
  pointer : String,
  json : Json,
) -> Array[(String, String)] {
  let out = []
  guard json is Object(headers) else {
    self.error(pointer, "must be an object")
    return out
  }
  for name, value in headers {
    let field = child(pointer, name)
    if !is_token(name) {
      self.error(field, "is not a valid header name")
    } else if name.to_lower()
      is ("content-length" | "transfer-encoding" | "connection") {
      self.error(field, "is set by smock and cannot be given")
    }
    match value {
      String(value) =>
        if is_field_value(value) {
          out.push((name, value))
        } else {
          self.error(
            field, "must not contain control characters other than tab",
          )
        }
      _ => self.error(field, "must be a string")
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
/// The JSON Pointer to member or element `key` of the value at `pointer`.
fn child(pointer : String, key : String) -> String {
  let escaped = key
    .replace_all(old="~", new="~0")
    .replace_all(old="/", new="~1")
  "\{pointer}/\{escaped}"
}

///|
/// Whether `s` is an HTTP token, as a header name must be.
fn is_token(s : String) -> Bool {
  if s == "" {
    return false
  }
  for c in s {
    let ok = (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      "!#$%&'*+-.^_`|~".contains_char(c)
    if !ok {
      return false
    }
  }
  true
}

///|
/// Whether `s` can be written as a header value: no control characters
/// other than tab.
fn is_field_value(s : String) -> Bool {
  for c in s {
    if (c < ' ' && c != '\t') || c == '\u{7f}' {
      return false
    }
  }
  true
}
