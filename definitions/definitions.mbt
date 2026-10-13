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
///
/// A problem in an Ephemeral Stub has no file: its file is `""`, and its
/// pointer points into the Stub as the Admin API received it.
pub(all) struct Diagnostic {
  file : String
  pointer : String
  message : String
} derive(Debug, Eq)

///|
/// `<file>: <pointer>: <message>`, or `<file>: <message>` when the problem
/// is about the whole file, each without `<file>: ` when there is no file.
/// It is always one line: line breaks and other control characters, such
/// as in a file name or a field name, are written as escapes like `\n` and
/// `\u{1b}`.
pub fn Diagnostic::to_string(self : Diagnostic) -> String {
  let parts = [self.file, self.pointer, self.message].filter(part => part != "")
  one_line(parts.join(": "))
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
/// Each Mock holds its Stubs in matching order and their match index, both
/// built with the snapshot.
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
  /// Where each Stub is declared, by its ID: the Definition file and the
  /// JSON Pointer to the Stub in it.
  priv stub_locations : Map[String, (String, String)]
  /// The definition set digest of the set the snapshot was built from, as
  /// `DefinitionSet::digest` gives it.
  digest : String
} derive(Debug, Eq)

///|
/// A Mock and its Stubs.
pub struct Mock {
  name : String
  /// The Hosts the Mock answers to, as declared.
  hosts : ReadOnlyArray[String]
  /// The status of the response when no Stub matches.
  no_match_status : Int
  /// Whether the Journal records the requests the Mock answers: the Mock's
  /// `journal`, true by default.
  journal : Bool
  /// The Stubs of this Mock, in the order they are tried: by priority,
  /// lower numbers first and Stubs without a priority last; Stubs of equal
  /// priority in declaration order, that is file-name order, then position
  /// in the file.
  stubs : ReadOnlyArray[Stub]
  /// The match index of `stubs`, which `candidates` looks up.
  priv index : MatchIndex
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
  /// The Faults the Stub injects when it matches, if it has `fault`.
  fault : Fault?
} derive(Debug, Eq)

///|
/// The Faults a Stub injects when it matches. Their random draws come from
/// the Stub's own generator when it has a seed, and otherwise from the
/// process generator.
pub struct Fault {
  /// A delay before the status line is written.
  delay : Delay?
  /// A connection Fault, injected instead of the response.
  connection : ConnectionFault?
  /// The seed of the Stub's own generator, from 0 to 2^53 - 1.
  seed : UInt64?
} derive(Debug, Eq)

///|
/// A delay drawn from a distribution, applied to a share of the matched
/// requests.
pub struct Delay {
  distribution : Distribution
  /// The share of matched requests the delay applies to, from 0 to 1.
  probability : Double
} derive(Debug, Eq)

///|
/// A distribution of delays, in whole milliseconds.
pub enum Distribution {
  /// Always this many milliseconds.
  Fixed(Int)
  /// A whole number of milliseconds drawn uniformly from `min` to `max`,
  /// both included. `min` does not exceed `max`.
  Uniform(min~ : Int, max~ : Int)
  /// A number of milliseconds drawn from a log-normal distribution with
  /// this median, where `sigma` is the standard deviation of its natural
  /// logarithm.
  Lognormal(median~ : Int, sigma~ : Double)
} derive(Debug, Eq)

///|
/// A connection Fault, applied to a share of the matched requests.
pub struct ConnectionFault {
  kind : ConnectionKind
  /// The share of matched requests the Fault applies to, from 0 to 1.
  probability : Double
} derive(Debug, Eq)

///|
/// How a connection Fault ends the connection.
pub enum ConnectionKind {
  /// Read the whole request, then reset the connection (an RST) without
  /// writing anything.
  Reset
  /// Close the connection without writing anything.
  Close
  /// Write the status line, the headers and the first half of the body,
  /// then close the connection.
  Partial
} derive(Debug, Eq)

///|
/// The conditions a request must meet for a Stub to match it. An omitted
/// condition matches anything.
pub struct Conditions {
  /// The method, compared exactly.
  meth : String?
  /// The path: the percent-decoded path of the request, without its query,
  /// meets it.
  path : ValueCondition?
  /// Query parameters as (name, condition): each must be present, and one
  /// of its decoded values must meet the condition.
  query : ReadOnlyArray[(String, ValueCondition)]
  /// Headers as (name in lower case, condition): each must be present, and
  /// one of its values must meet the condition. Names are compared
  /// case-insensitively.
  headers : ReadOnlyArray[(String, ValueCondition)]
  /// The body.
  body : BodyCondition?
} derive(Debug, Eq)

///|
/// A condition on a value of a request, such as its path or a header
/// value.
pub enum ValueCondition {
  /// The value is exactly this text.
  Exact(String)
  /// The pattern matches the whole value.
  Pattern(Pattern)
} derive(Debug, Eq)

///|
/// A pattern condition: an RE2 pattern, in the subset the RE2 module
/// supports, compiled when the definition set was loaded. Matching it
/// never compiles anything, and takes time linear in the length of the
/// value.
pub struct Pattern {
  /// The pattern as the Definition file gives it.
  source : String
  priv regex : @re2.Regex
}

///|
/// Whether the pattern matches the whole of `value`, which is UTF-8. A
/// byte that is not part of well-formed UTF-8 is not a character, so a
/// value that contains one never matches.
pub fn Pattern::matches(self : Pattern, value : BytesView) -> Bool {
  self.regex.full_match(value)
}

///|
/// Patterns are equal when they are written the same.
pub impl Eq for Pattern with fn equal(self, other) {
  self.source == other.source
}

///|
/// Shows the pattern as it is written.
pub impl Debug for Pattern with fn to_repr(self) {
  Repr::ctor("Pattern", [(None, Repr::string(self.source))])
}

///|
/// A condition on the request body.
pub enum BodyCondition {
  /// The body is exactly these bytes: the text of the condition in UTF-8.
  Exact(Bytes)
  /// The pattern matches the whole body.
  Pattern(Pattern)
  /// The body parses as JSON and contains this value: an object has each
  /// listed key, with a value that contains the listed one; an array has
  /// the same length, and each element contains the listed one; any other
  /// value is equal, numbers by their value.
  Json(Json)
} derive(Debug, Eq)

///|
/// A Stub's response.
pub struct Response {
  status : Int
  headers : ReadOnlyArray[(String, String)]
  body : ResponseBody
} derive(Debug, Eq)

///|
/// The body of a Stub's response.
pub enum ResponseBody {
  /// Bytes sent at once: the inline body in UTF-8, or the bytes of the body
  /// file, read when the snapshot was built.
  Bytes(Bytes)
  /// Server-Sent Events, streamed one after another.
  Events(ReadOnlyArray[SseEvent])
} derive(Debug, Eq)

///|
/// One Server-Sent Event of a response.
pub struct SseEvent {
  /// How long to wait before writing the event, in milliseconds: after the
  /// previous event, or after the head for the first one.
  delay_ms : Int
  /// The event type, one line.
  event : String?
  /// The event ID, one line without NUL characters.
  id : String?
  /// The data, which may span several lines.
  data : String
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
///
/// `read_problems` are the problems the caller had reading the set, such
/// as a file that cannot be read. A set read with problems is invalid
/// whatever its files hold; they come first among its problems.
pub fn load(
  set : DefinitionSet,
  read_problems? : Array[Diagnostic] = [],
) -> Result[Snapshot, Array[Diagnostic]] {
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
  if read_problems.length() > 0 || reader.diagnostics.length() > 0 {
    return Err([..read_problems, ..reader.diagnostics])
  }
  let digest = set.digest()
  if reader.mocks.length() == 0 {
    return Ok({
      mocks: ReadOnlyArray::from_array([
        {
          name: "default",
          hosts: ReadOnlyArray::from_array([]),
          no_match_status: 404,
          journal: true,
          stubs: ReadOnlyArray::from_array([]),
          index: MatchIndex::new(ReadOnlyArray::from_array([])),
        },
      ]),
      host_index: Map([]),
      default_index: Some(0),
      stub_locations: Map([]),
      digest,
    })
  }
  let mocks = reader.mocks.map(mock => {
    let stubs = ReadOnlyArray::from_array(
      in_matching_order(
        reader.stubs.iter().filter(stub => stub.mock == mock.name).collect(),
      ),
    )
    Mock::{
      name: mock.name,
      hosts: ReadOnlyArray::from_iter(mock.hosts.iter().map(host => host.0)),
      no_match_status: mock.no_match_status,
      journal: mock.journal,
      stubs,
      index: MatchIndex::new(stubs),
    }
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
  Ok({
    mocks: ReadOnlyArray::from_array(mocks),
    host_index,
    default_index,
    stub_locations: reader.stub_locations,
    digest,
  })
}

///|
/// `stubs`, given in declaration order, in the order they are tried: by
/// priority, lower numbers first and Stubs without a priority last, then in
/// declaration order.
fn in_matching_order(stubs : Array[Stub]) -> Array[Stub] {
  let indexed = stubs.mapi((i, stub) => (i, stub))
  indexed.sort_by((a, b) => {
    match a.1.compare_priority(b.1) {
      0 => a.0.compare(b.0)
      order => order
    }
  })
  indexed.map(entry => entry.1)
}

///|
/// How the priorities of two Stubs order them: negative when `self` is
/// tried before `other`, positive when after, and 0 when their priorities
/// do not decide. A lower number is tried first, and a Stub without a
/// priority after every Stub with one. Stubs from Definition files and
/// Ephemeral Stubs are each ordered by this rule.
pub fn Stub::compare_priority(self : Stub, other : Stub) -> Int {
  match (self.priority, other.priority) {
    (Some(p), Some(q)) => p.compare(q)
    (Some(_), None) => -1
    (None, Some(_)) => 1
    (None, None) => 0
  }
}

///|
/// The definition set digest: a short content hash of every Definition
/// file and body file, so that replicas serving the same files report the
/// same digest. It is the first 12 hex digits (lower case) of the SHA-256
/// of every file, framed one after another: the Definition files in
/// byte-wise order of their names, then the body files in the same order,
/// files with the same name in byte-wise order of their bytes. Each file is
///
/// - one byte, `D` for a Definition file or `B` for a body file;
/// - the length of its name in bytes, as an 8-byte big-endian number, then
///   its name in UTF-8;
/// - the length of its bytes, as an 8-byte big-endian number, then its
///   bytes.
///
/// Every part has its length, so two different sets never frame to the
/// same bytes, and the order the files come in does not matter.
pub fn DefinitionSet::digest(self : DefinitionSet) -> String {
  let framed = @buffer.Buffer()
  for kind in [(b'D', self.files), (b'B', self.body_files)] {
    let entries = kind.1.map(file => (@utf8.encode(file.0), file.1))
    entries.sort_by((a, b) => {
      match a.0.lexical_compare(b.0) {
        0 => a.1.lexical_compare(b.1)
        order => order
      }
    })
    for entry in entries {
      framed.write_byte(kind.0)
      framed.write_uint64_be(entry.0.length().to_uint64())
      framed.write_bytes(entry.0)
      framed.write_uint64_be(entry.1.length().to_uint64())
      framed.write_bytes(entry.1)
    }
  }
  let hex = StringBuilder()
  for byte in sha256(framed.to_bytes())[:6] {
    hex.write_string(byte.to_int().to_string(radix=16).pad_start(2, '0'))
  }
  hex.to_string()
}

///|
/// `files` in byte-wise order of their names (UTF-8).
fn sorted_by_name(files : Array[(String, Bytes)]) -> Array[(String, Bytes)] {
  let sorted = files.copy()
  sorted.sort_by((a, b) => @utf8.encode(a.0).lexical_compare(@utf8.encode(b.0)))
  sorted
}
