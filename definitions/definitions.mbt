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
/// is about the whole file. It is always one line: line breaks and other
/// control characters, such as in a file name or a field name, are written
/// as escapes like `\n` and `\u{1b}`.
pub fn Diagnostic::to_string(self : Diagnostic) -> String {
  let line = if self.pointer == "" {
    "\{self.file}: \{self.message}"
  } else {
    "\{self.file}: \{self.pointer}: \{self.message}"
  }
  one_line(line)
}

///|
/// `s` with its control characters and Unicode line separators escaped.
fn one_line(s : String) -> String {
  let out = StringBuilder()
  for c in s {
    match c {
      '\n' => out.write_string("\\n")
      '\r' => out.write_string("\\r")
      '\t' => out.write_char(c)
      _ if c < ' ' ||
        c == '\u{7f}' ||
        c == '\u{85}' ||
        c == '\u{2028}' ||
        c == '\u{2029}' =>
        out.write_string("\\u{\{c.to_int().to_string(radix=16)}}")
      _ => out.write_char(c)
    }
  }
  out.to_string()
}

///|
/// An immutable snapshot of a valid definition set: what the engine serves.
pub struct Snapshot {
  /// The Mocks, in declaration order: file-name order, then position in the
  /// file. When no Definition file declares a Mock, this is one empty Mock
  /// named `default`.
  mocks : ReadOnlyArray[Mock]
} derive(Debug, Eq)

///|
/// A Mock and its Stubs.
pub struct Mock {
  name : String
  /// The status of the response when no Stub matches.
  no_match_status : Int
  /// The Stubs of this Mock, in the order they are tried: by priority,
  /// lower numbers first and Stubs without a priority last; Stubs of equal
  /// priority in declaration order, that is file-name order, then position
  /// in the file.
  stubs : ReadOnlyArray[Stub]
} derive(Debug, Eq)

///|
/// A Stub from a Definition file.
pub struct Stub {
  id : String
  /// The name of the Mock the Stub belongs to.
  mock : String
  /// The priority: a lower number is tried first, and a Stub without one
  /// after every Stub with one.
  priority : Int?
  request : Conditions
  response : Response
} derive(Debug, Eq)

///|
/// The conditions a request must meet for a Stub to match it. An omitted
/// condition matches anything.
pub struct Conditions {
  /// The method, compared exactly.
  meth : String?
  /// The path, compared exactly with the percent-decoded path of the
  /// request, without its query.
  path : String?
  /// Query parameters as (name, value): each must be present, and one of
  /// its decoded values must equal the given value.
  query : ReadOnlyArray[(String, String)]
  /// Headers as (name in lower case, value): each must be present, and one
  /// of its values must equal the given value. Names are compared
  /// case-insensitively.
  headers : ReadOnlyArray[(String, String)]
  /// The body.
  body : BodyCondition?
} derive(Debug, Eq)

///|
/// A condition on the request body.
pub enum BodyCondition {
  /// The body is exactly these bytes: the text of the condition in UTF-8.
  Exact(Bytes)
  /// The body parses as JSON and contains this value: an object has each
  /// listed key, with a value that contains the listed one; an array has
  /// the same length, and each element contains the listed one; any other
  /// value is equal, numbers by their value.
  Json(Json)
} derive(Debug, Eq)

///|
/// A static response.
pub struct Response {
  status : Int
  headers : ReadOnlyArray[(String, String)]
  /// The body: the inline body in UTF-8, or the bytes of the body file,
  /// read when the snapshot was built.
  body : Bytes
} derive(Debug, Eq)

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
/// problem found, in file-name order and then in the order they appear in
/// each file.
pub fn load(set : DefinitionSet) -> Result[Snapshot, Array[Diagnostic]] {
  let files = sorted_by_name(set.files).map(file => {
    (file.0, parse_file(file.0, file.1))
  })
  let reader = Reader::new(
    declared=declared_mocks(files),
    body_files=Map::from_array(set.body_files),
  )
  for file in files {
    reader.read_file(file.0, file.1)
  }
  if reader.diagnostics.length() > 0 {
    return Err(reader.diagnostics)
  }
  let mocks = if reader.mocks.length() == 0 {
    [empty_mock("default")]
  } else {
    reader.mocks
  }
  Ok({
    mocks: ReadOnlyArray::from_iter(
      mocks
      .iter()
      .map(mock => Mock::{
        ..mock,
        stubs: ReadOnlyArray::from_array(
          in_matching_order(
            reader.stubs.iter().filter(stub => stub.mock == mock.name).collect(),
          ),
        ),
      }),
    ),
  })
}

///|
/// A Mock named `name` with every setting at its default and no Stubs.
fn empty_mock(name : String) -> Mock {
  { name, no_match_status: 404, stubs: ReadOnlyArray::from_array([]), }
}

///|
/// `stubs`, given in declaration order, in the order they are tried: by
/// priority, lower numbers first and Stubs without a priority last, then in
/// declaration order.
fn in_matching_order(stubs : Array[Stub]) -> Array[Stub] {
  let indexed = stubs.mapi((i, stub) => (i, stub))
  indexed.sort_by((a, b) => {
    match (a.1.priority, b.1.priority) {
      (Some(p), Some(q)) if p != q => p.compare(q)
      (Some(_), None) => -1
      (None, Some(_)) => 1
      _ => a.0.compare(b.0)
    }
  })
  indexed.map(entry => entry.1)
}

///|
/// `files` in byte-wise order of their names (UTF-8).
fn sorted_by_name(files : Array[(String, Bytes)]) -> Array[(String, Bytes)] {
  let sorted = files.copy()
  sorted.sort_by((a, b) => @utf8.encode(a.0).lexical_compare(@utf8.encode(b.0)))
  sorted
}
