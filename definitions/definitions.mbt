///|
/// A definition set as Definitions receives it: the Definition files and the
/// body files, as (relative name, bytes) pairs. Definitions does no I/O; the
/// caller reads them, such as from the definitions directory.
pub(all) struct DefinitionSet {
  /// The Definition files, named relative to the definitions directory,
  /// such as `users.json`. Their order does not matter: Definitions takes
  /// them in byte-wise name order.
  files : Array[(String, Bytes)]
  /// The body files, named relative to the body-file subdirectory, such as
  /// `users/1.json`.
  body_files : Array[(String, Bytes)]
}

///|
/// A problem in a definition set: the file it is in, a JSON Pointer
/// (RFC 6901) to the value it is about within that file, and a message.
/// The pointer is `""` when the problem is about the whole file.
pub(all) struct Diagnostic {
  file : String
  pointer : String
  message : String
} derive(Debug, Eq)

///|
/// `<file>: <pointer>: <message>`, or `<file>: <message>` when the problem
/// is about the whole file.
pub fn Diagnostic::to_string(self : Diagnostic) -> String {
  if self.pointer == "" {
    "\{self.file}: \{self.message}"
  } else {
    "\{self.file}: \{self.pointer}: \{self.message}"
  }
}

///|
/// An immutable snapshot of a valid definition set: what the engine serves.
pub struct Snapshot {
  /// The Mocks, in declaration order: file-name order, then position in the
  /// file. When no Definition file declares a Mock, this is one empty Mock
  /// named `default`.
  mocks : ReadOnlyArray[Mock]
}

///|
/// A Mock and its Stubs.
pub struct Mock {
  name : String
  /// The Stubs of this Mock, in the order they are tried.
  stubs : ReadOnlyArray[Stub]
}

///|
/// A Stub from a Definition file.
pub struct Stub {
  id : String
  /// The name of the Mock the Stub belongs to.
  mock : String
  request : Conditions
  response : Response
}

///|
/// The conditions a request must meet for a Stub to match it. An omitted
/// condition matches anything.
pub struct Conditions {
  /// The method, compared exactly.
  meth : String?
  /// The path, without the query, compared exactly.
  path : String?
}

///|
/// A static response.
pub struct Response {
  status : Int
  headers : ReadOnlyArray[(String, String)]
  body : Bytes
}

///|
/// The Default Mock: the only Mock, when there is exactly one. With several
/// Mocks there is none yet.
pub fn Snapshot::default_mock(self : Snapshot) -> Mock? {
  if self.mocks.length() == 1 {
    Some(self.mocks[0])
  } else {
    None
  }
}

///|
/// Validates a definition set and builds its snapshot, or returns every
/// problem found.
pub fn load(set : DefinitionSet) -> Result[Snapshot, Array[Diagnostic]] {
  let reader = Reader::{ diagnostics: [], mocks: [], stubs: [], }
  for file in sorted_by_name(set.files) {
    let (name, bytes) = file
    reader.read_file(name, bytes)
  }
  if reader.diagnostics.length() > 0 {
    return Err(reader.diagnostics)
  }
  let mocks = if reader.mocks.length() == 0 {
    ["default"]
  } else {
    reader.mocks
  }
  Ok({
    mocks: ReadOnlyArray::from_iter(
      mocks
      .iter()
      .map(name => Mock::{
        name,
        stubs: ReadOnlyArray::from_iter(
          reader.stubs.iter().filter(stub => stub.mock == name),
        ),
      }),
    ),
  })
}

///|
/// `files` in byte-wise order of their names (UTF-8).
fn sorted_by_name(files : Array[(String, Bytes)]) -> Array[(String, Bytes)] {
  let sorted = files.copy()
  sorted.sort_by((a, b) => @utf8.encode(a.0).lexical_compare(@utf8.encode(b.0)))
  sorted
}

///|
/// Reads Definition files one after another, collecting what they declare
/// and every problem in them.
priv struct Reader {
  diagnostics : Array[Diagnostic]
  /// The names of the Mocks declared so far.
  mocks : Array[String]
  /// The Stubs declared so far.
  stubs : Array[Stub]
}

///|
fn Reader::read_file(self : Reader, name : String, bytes : Bytes) -> Unit {
  let file = File::{ name, diagnostics: self.diagnostics, }
  if name.has_suffix(".yaml") || name.has_suffix(".yml") {
    file.error(
      "", "YAML Definition files are not supported yet; write this file as JSON",
    )
    return
  }
  if !name.has_suffix(".json") {
    file.error("", "a Definition file name ends in .json, .yaml or .yml")
    return
  }
  let text = @utf8.decode(bytes) catch {
    _ => {
      file.error("", "not valid UTF-8")
      return
    }
  }
  let json = @json.parse(text) catch {
    err => {
      file.error("", "not valid JSON: \{err}")
      return
    }
  }
  guard json is Object(top) else {
    file.error("", "must be an object")
    return
  }
  if file.array(top, "", "mocks") is Some(mocks) {
    for i, mock in mocks {
      if file.read_mock(child("/mocks", i.to_string()), mock) is Some(name) {
        self.mocks.push(name)
      }
    }
  }
  if file.array(top, "", "stubs") is Some(stubs) {
    for i, stub in stubs {
      if file.read_stub(child("/stubs", i.to_string()), stub) is Some(stub) {
        self.stubs.push(stub)
      }
    }
  }
}

///|
/// One Definition file being read: its name and where its problems go.
priv struct File {
  name : String
  diagnostics : Array[Diagnostic]
}

///|
fn File::error(self : File, pointer : String, message : String) -> Unit {
  self.diagnostics.push({ file: self.name, pointer, message, })
}

///|
/// Reads a Mock and returns its name.
fn File::read_mock(self : File, pointer : String, json : Json) -> String? {
  guard json is Object(mock) else {
    self.error(pointer, "must be an object")
    return None
  }
  self.required_name(mock, pointer, "name")
}

///|
fn File::read_stub(self : File, pointer : String, json : Json) -> Stub? {
  guard json is Object(stub) else {
    self.error(pointer, "must be an object")
    return None
  }
  let id = self.required_name(stub, pointer, "id")
  let mock = self.required_name(stub, pointer, "mock")
  let request = self.read_conditions(pointer, stub)
  let response = self.read_response(pointer, stub)
  match (id, mock, request, response) {
    (Some(id), Some(mock), Some(request), Some(response)) =>
      Some({ id, mock, request, response, })
    _ => None
  }
}

///|
fn File::read_conditions(
  self : File,
  stub_pointer : String,
  stub : Map[String, Json],
) -> Conditions? {
  let pointer = child(stub_pointer, "request")
  match stub.get("request") {
    None => Some({ meth: None, path: None, })
    Some(Object(request)) => {
      let meth = self.optional_string(request, pointer, "method")
      let path = self.optional_string(request, pointer, "path")
      match (meth, path) {
        (Ok(meth), Ok(path)) => Some({ meth, path, })
        _ => None
      }
    }
    Some(_) => {
      self.error(pointer, "must be an object")
      None
    }
  }
}

///|
fn File::read_response(
  self : File,
  stub_pointer : String,
  stub : Map[String, Json],
) -> Response? {
  let pointer = child(stub_pointer, "response")
  let response = match stub.get("response") {
    Some(Object(response)) => response
    Some(_) => {
      self.error(pointer, "must be an object")
      return None
    }
    None => {
      self.error(stub_pointer, "needs a response")
      return None
    }
  }
  let status = match response.get("status") {
    Some(Number(n, ..)) if n == n.floor() && n >= 200.0 && n <= 599.0 =>
      Some(n.to_int())
    Some(_) => {
      self.error(child(pointer, "status"), "must be an integer from 200 to 599")
      None
    }
    None => {
      self.error(pointer, "needs a status")
      None
    }
  }
  let headers = self.read_headers(child(pointer, "headers"), response)
  let body = match self.optional_string(response, pointer, "body") {
    Ok(body) => Some(@utf8.encode(body.unwrap_or("")))
    Err(_) => None
  }
  match (status, headers, body) {
    (Some(status), Some(headers), Some(body)) =>
      Some({ status, headers: ReadOnlyArray::from_array(headers), body, })
    _ => None
  }
}

///|
/// Reads response headers: an object whose members are field names and
/// string values.
fn File::read_headers(
  self : File,
  pointer : String,
  response : Map[String, Json],
) -> Array[(String, String)]? {
  let headers = match response.get("headers") {
    None => return Some([])
    Some(Object(headers)) => headers
    Some(_) => {
      self.error(pointer, "must be an object")
      return None
    }
  }
  let out = []
  let mut ok = true
  for name, value in headers {
    let value_pointer = child(pointer, name)
    if !is_token(name) {
      self.error(value_pointer, "is not a valid header name")
      ok = false
    } else if name.to_lower()
      is ("content-length" | "transfer-encoding" | "connection") {
      self.error(value_pointer, "is set by smock and cannot be given")
      ok = false
    }
    match value {
      String(value) =>
        if is_field_value(value) {
          out.push((name, value))
        } else {
          self.error(
            value_pointer, "must not contain control characters other than tab",
          )
          ok = false
        }
      _ => {
        self.error(value_pointer, "must be a string")
        ok = false
      }
    }
  }
  if ok {
    Some(out)
  } else {
    None
  }
}

///|
/// Reads a required, non-empty string member such as a name or an ID.
fn File::required_name(
  self : File,
  object : Map[String, Json],
  pointer : String,
  key : String,
) -> String? {
  match object.get(key) {
    Some(String(value)) if value != "" => Some(value)
    Some(_) => {
      self.error(child(pointer, key), "must be a non-empty string")
      None
    }
    None => {
      self.error(pointer, "needs \"\{key}\"")
      None
    }
  }
}

///|
/// Reads an optional string member.
fn File::optional_string(
  self : File,
  object : Map[String, Json],
  pointer : String,
  key : String,
) -> Result[String?, Unit] {
  match object.get(key) {
    None => Ok(None)
    Some(String(value)) => Ok(Some(value))
    Some(_) => {
      self.error(child(pointer, key), "must be a string")
      Err(())
    }
  }
}

///|
/// Reads an optional array member.
fn File::array(
  self : File,
  object : Map[String, Json],
  pointer : String,
  key : String,
) -> Array[Json]? {
  match object.get(key) {
    None => None
    Some(Array(items)) => Some(items)
    Some(_) => {
      self.error(child(pointer, key), "must be an array")
      None
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
