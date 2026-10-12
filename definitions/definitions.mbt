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
  /// named `default`, with no Hosts.
  mocks : ReadOnlyArray[Mock]
  /// The Host index: each Host the Mocks declare, normalised, and the index
  /// in `mocks` of the Mock that declares it, in declaration order.
  priv host_index : Map[String, Int]
  /// The index in `mocks` of the Default Mock, if there is one.
  priv default_index : Int?
} derive(Debug, Eq)

///|
/// A Mock and its Stubs.
pub struct Mock {
  name : String
  /// The Hosts the Mock answers to, as declared.
  hosts : ReadOnlyArray[String]
  /// The Stubs of this Mock, in the order they are tried.
  stubs : ReadOnlyArray[Stub]
} derive(Debug, Eq)

///|
/// A Stub from a Definition file.
pub struct Stub {
  id : String
  /// The name of the Mock the Stub belongs to.
  mock : String
  request : Conditions
  response : Response
} derive(Debug, Eq)

///|
/// The conditions a request must meet for a Stub to match it. An omitted
/// condition matches anything.
pub struct Conditions {
  /// The method, compared exactly.
  meth : String?
  /// The path, without the query, compared exactly.
  path : String?
} derive(Debug, Eq)

///|
/// A static response.
pub struct Response {
  status : Int
  headers : ReadOnlyArray[(String, String)]
  body : Bytes
} derive(Debug, Eq)

///|
/// The Mock whose Hosts include `host`, a Host normalised by
/// `normalize_host`.
pub fn Snapshot::mock_for_host(self : Snapshot, host : String) -> Mock? {
  self.host_index.get(host).map(i => self.mocks[i])
}

///|
/// The Default Mock, which answers the requests whose Host no Mock lists:
/// the Mock marked `default`, or else the only Mock when there is exactly
/// one. Otherwise there is none.
pub fn Snapshot::default_mock(self : Snapshot) -> Mock? {
  self.default_index.map(i => self.mocks[i])
}

///|
/// Every Host the Mocks declare, normalised, in declaration order.
pub fn Snapshot::hosts(self : Snapshot) -> Array[String] {
  self.host_index.keys().collect()
}

///|
/// A Host as smock compares it: in lower case, without the port and without
/// a trailing dot. A bracketed IPv6 literal keeps its brackets, and an IPv6
/// literal without brackets, which cannot carry a port, gets them, so
/// `[::1]:8080`, `[::1]` and `::1` are the same Host.
pub fn normalize_host(host : String) -> String {
  let host = host.to_lower()
  if host.has_prefix("[") {
    return match host.find("]") {
      Some(end) => host[:end + 1].to_owned()
      None => host
    }
  }
  let name = match host.find(":") {
    Some(colon) if host.rev_find(":") == Some(colon) => host[:colon].to_owned()
    Some(_) => return "[\{host}]"
    None => host
  }
  if name.has_suffix(".") {
    name[:name.length() - 1].to_owned()
  } else {
    name
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
  if reader.mocks.length() == 0 {
    return Ok({
      mocks: ReadOnlyArray::from_array([
        {
          name: "default",
          hosts: ReadOnlyArray::from_array([]),
          stubs: ReadOnlyArray::from_array([]),
        },
      ]),
      host_index: Map([]),
      default_index: Some(0),
    })
  }
  let mocks = reader.mocks.map(mock => Mock::{
    name: mock.name,
    hosts: ReadOnlyArray::from_iter(mock.hosts.iter().map(host => host.0)),
    stubs: ReadOnlyArray::from_iter(
      reader.stubs.iter().filter(stub => stub.mock == mock.name),
    ),
  })
  let index_of = Map([])
  for i, mock in mocks {
    index_of[mock.name] = i
  }
  let host_index = Map([])
  for host, claim in reader.hosts {
    host_index[host] = index_of[claim.0]
  }
  let default_index = match reader.default_mock {
    Some((name, _)) => Some(index_of[name])
    None if mocks.length() == 1 => Some(0)
    None => None
  }
  Ok({ mocks: ReadOnlyArray::from_array(mocks), host_index, default_index, })
}

///|
/// `files` in byte-wise order of their names (UTF-8).
fn sorted_by_name(files : Array[(String, Bytes)]) -> Array[(String, Bytes)] {
  let sorted = files.copy()
  sorted.sort_by((a, b) => @utf8.encode(a.0).lexical_compare(@utf8.encode(b.0)))
  sorted
}
