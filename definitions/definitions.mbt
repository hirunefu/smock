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
/// problem found, in file-name order and then in the order they appear in
/// each file.
pub fn load(set : DefinitionSet) -> Result[Snapshot, Array[Diagnostic]] {
  let files = sorted_by_name(set.files).map(file => {
    (file.0, parse_file(file.0, file.1))
  })
  let reader = Reader::new(declared=declared_mocks(files))
  for file in files {
    reader.read_file(file.0, file.1)
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
