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
  priv stub_locations : Map[String, Location]
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
  /// The header fields of the response when no Stub matches, in order: the
  /// Mock's `noMatch.headers`, sent with smock's own.
  no_match_headers : ReadOnlyArray[(String, String)]
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
  /// The Scenarios that the Mock's Stubs name, each with its file states,
  /// in byte-wise order of their names. A Scenario has no declaration: it
  /// exists because Stubs name it.
  scenarios : ReadOnlyArray[ScenarioFileStates]
} derive(Debug, Eq)

///|
/// Whether any Stub of the Mock has a Scenario clause. A Mock without one
/// pays only this test for Scenarios when it answers a request, unless the
/// request's Session added an Ephemeral Stub with a clause to it.
pub fn Mock::has_scenarios(self : Mock) -> Bool {
  self.scenarios.length() > 0
}

///|
/// The file states of a Scenario that a Mock's Stubs name: the Scenario's
/// name, and the states that the Stubs in the Definition files name for it.
/// A Scenario is a named state machine within the Mock, identified by the
/// Mock and its name.
pub struct ScenarioFileStates {
  /// The Scenario's name, within its Mock.
  name : String
  /// `initial_state` first, then every other state that the `requires` and
  /// `moveTo` of the Mock's Stubs name for the Scenario, in byte-wise
  /// order.
  states : ReadOnlyArray[String]
} derive(Debug, Eq)

///|
/// The state every Scenario starts in, compared case-sensitively.
pub let initial_state : String = "Started"

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
  /// The Stub's Scenario clause, if it has `scenario`.
  scenario : ScenarioClause?
  response : Response
  /// The Faults the Stub injects when it matches, if it has `fault`.
  fault : Fault?
} derive(Debug, Eq)

///|
/// A Stub's Scenario clause: the state a Scenario of the Stub's Mock must
/// be in for the Stub to match, the state the Stub moves it to when it is
/// chosen, or both. It is not a request condition: it depends on the
/// engine's state, not on the request alone.
pub struct ScenarioClause {
  /// The Scenario's name.
  name : String
  /// The state the Scenario must be in. Without it, the Stub matches in
  /// every state.
  requires : String?
  /// The state the Scenario moves to when the Stub is chosen.
  move_to : String?
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
  /// The seed of the Stub's own generator, from 0 to `max_seed`.
  seed : UInt64?
} derive(Debug, Eq)

///|
/// The longest duration a Definition file can give, in milliseconds, such
/// as a delay: the largest `Int`, about 24 days.
pub let max_milliseconds : Int = @int.MAX_VALUE

///|
/// The largest seed, 2^53 - 1: up to it, a JSON number holds every integer
/// exactly.
pub let max_seed : UInt64 = 9007199254740991

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
/// The kind's name, as Definition files and the Journal write it: `reset`,
/// `close` or `partial`.
pub fn ConnectionKind::name(self : ConnectionKind) -> String {
  match self {
    Reset => "reset"
    Close => "close"
    Partial => "partial"
  }
}

///|
/// The kind with the name `name`, if any.
fn connection_kind(name : String) -> ConnectionKind? {
  [Reset, Close, Partial].iter().find_first(kind => kind.name() == name)
}

///|
/// The conditions a request must meet for a Stub to match it. An omitted
/// condition matches anything.
pub struct Conditions {
  /// The method, compared exactly.
  meth : String?
  /// The path: the percent-decoded path of the request, without its query,
  /// meets it.
  path : ValueCondition?
  /// Query parameters as (name, condition): each condition must hold for
  /// the decoded values of the parameter with that name, as
  /// `ValueCondition::holds` says.
  query : ReadOnlyArray[(String, ValueCondition)]
  /// Headers as (name in lower case, condition): each condition must hold
  /// for the values of the header with that name, as
  /// `ValueCondition::holds` says. Names are compared case-insensitively.
  headers : ReadOnlyArray[(String, ValueCondition)]
  /// Cookies as (name, condition): each condition must hold for the values
  /// of the cookies with that name, from every `Cookie` field, as
  /// `ValueCondition::holds` says. Names are compared exactly, case and
  /// all, and values as sent.
  cookies : ReadOnlyArray[(String, ValueCondition)]
  /// The body: its text, a pattern, a `json` condition, conditions on the
  /// fields of a form, or conditions on the values at paths into it as
  /// XML.
  body : BodyCondition?
} derive(Debug, Eq)

///|
/// A condition on a value of a request, such as its path or a header
/// value, as the Stub writes it, operators included.
///
/// A query parameter, a header or a cookie is a name that the request
/// carries any number of values under. An exact value or a pattern holds
/// when one of the values meets it, so it fails when the name is absent; an
/// operator is about the name as a whole. The path is a name with exactly
/// one value.
pub enum ValueCondition {
  /// An exact value or a pattern: one of the name's values passes the
  /// test.
  Has(ValueTest)
  /// `$not`: the condition does not hold. With an exact value or a pattern
  /// inside, no value of the name meets it, or the name is absent.
  Not(ValueCondition)
  /// `$exists`: the name is present, with any value, when true, and absent
  /// when false.
  Exists(Bool)
} derive(Debug, Eq)

///|
/// The test that each value of a name is given for a value condition, as
/// `ValueCondition::value_test` gives it.
pub enum ValueTest {
  /// The value is exactly this text.
  Exact(String)
  /// The pattern matches the whole value.
  Pattern(Pattern)
  /// Every value passes, so that a name has a value that passes it exactly
  /// when the name is present: the test of `$exists`. A Stub writes
  /// `$exists: true` as `Exists(true)`, not as a condition that has this
  /// test.
  Any
} derive(Debug, Eq)

///|
/// Whether `value` passes the test.
pub fn ValueTest::meets(self : ValueTest, value : String) -> Bool {
  match self {
    Exact(exact) => value == exact
    Pattern(pattern) => pattern.matches(@utf8.encode(value))
    Any => true
  }
}

///|
/// Whether `value`, the one value of a name such as the path, meets the
/// condition: it is exactly the given text, or the pattern matches the
/// whole of it; an operator holds as `holds` says for a name with this one
/// value.
pub fn ValueCondition::meets(self : ValueCondition, value : String) -> Bool {
  match self {
    Has(wanted) => wanted.meets(value)
    Not(inner) => !inner.meets(value)
    Exists(present) => present
  }
}

///|
/// The test that each value of a name is given for the condition: the
/// exact value or the pattern inside its operators, or, for `$exists`, the
/// test that every value passes.
///
/// Whether a name holds the condition depends only on whether one of its
/// values passes this test, which `holds` turns into the outcome. So a
/// matcher, whatever the operators, scans the values of a name once, stops
/// at the first that passes, and gives `holds` the result. The test is
/// part of the condition, so getting it allocates nothing.
pub fn ValueCondition::value_test(self : ValueCondition) -> ValueTest {
  match self {
    Has(wanted) => wanted
    Not(inner) => inner.value_test()
    Exists(_) => Any
  }
}

///|
/// Whether the condition holds for a name, given whether one of the name's
/// values passes `value_test`, `found`:
///
/// - an exact value or a pattern holds when one does, so it fails when the
///   name is absent;
/// - `$not` holds when its condition does not: with an exact value or a
///   pattern inside, when none does, or the name is absent;
/// - `$exists` holds when the name is present, with any value, or absent,
///   as it says.
pub fn ValueCondition::holds(self : ValueCondition, found~ : Bool) -> Bool {
  match self {
    Has(_) => found
    Not(inner) => !inner.holds(found~)
    Exists(present) => found == present
  }
}

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
  /// The body parses as JSON and contains the condition's value.
  Json(JsonCondition)
  /// A `form` condition, as (name, condition): the body is a form, as the
  /// request's Content-Type says, and each condition holds for the decoded
  /// values of the field with that name, as `ValueCondition::holds` says.
  /// A body that is not a form fails the condition, even one with no
  /// field, and every one of them, operators included.
  Form(ReadOnlyArray[(String, ValueCondition)])
  /// An `xml` condition, as (path, condition): the body parses as XML, and
  /// each condition holds for the values of the nodes its path selects, as
  /// `ValueCondition::holds` says, a path that selects nothing being a name
  /// that is absent. A body that does not parse fails the condition, even
  /// one with no path, and every one of them, operators included.
  Xml(ReadOnlyArray[(@xml.Path, ValueCondition)])
} derive(Debug, Eq)

///|
/// A `json` condition on the request body: a JSON value the body must
/// contain, in which an object whose only member is `pattern`, with a
/// string, is a pattern, an object whose only key is `$not`, `$exists` or
/// `$includes` is an operator, and a key `$$name` is the key `$name`.
/// `File::read_json_condition` reads one. The value is the condition's own
/// copy, as written, which nothing outside can change, so the snapshot
/// stays as it was loaded.
pub struct JsonCondition {
  priv value : Json
  /// The value, read into arrays, so that matching it walks no map.
  priv expected : Expected
}

///|
/// A JSON value as a condition expects it: an object as its keys, `$$name`
/// read as `$name`, and the values expected under them, in order; an array
/// as the values expected in it; a pattern object as its pattern; an
/// operator object as its operator; any other value as itself.
priv enum Expected {
  Object(FixedArray[String], FixedArray[Expected])
  Array(FixedArray[Expected])
  /// A pattern object: an object whose only member is `pattern`, with a
  /// string.
  Pattern(Pattern)
  Scalar(Json)
  /// `$not`: the value does not meet the condition. A missing key meets it
  /// when it does not meet the condition inside, as `missing_meets` says.
  Not(Expected)
  /// `$exists`: the value is present, whatever it is, when true, and
  /// missing when false.
  Exists(Bool)
  /// `$includes`: the value is an array with an element that meets the
  /// condition.
  Includes(Expected)
}

///|
/// Whether `actual` contains the condition's value: a pattern object's
/// pattern matches the whole of a string, or of a number's or a boolean's
/// JSON text; any other object has each listed key, with a value that
/// contains the listed one; an array has the same length, and each element
/// contains the listed one; any other value is equal, numbers by their
/// value (see `same_number`).
///
/// An operator is about the value in its place: `$not` holds when the
/// value does not contain its condition, `$exists` when the value is
/// present or missing, as it says, and `$includes` when the value is an
/// array with an element that contains its condition. A missing key meets
/// only `$exists: false` and `$not` of a condition that it does not meet,
/// and `actual` itself is always present.
pub fn JsonCondition::matches(self : JsonCondition, actual : Json) -> Bool {
  contains(actual, self.expected)
}

///|
fn contains(actual : Json, expected : Expected) -> Bool {
  match (expected, actual) {
    (Object(keys, values), Object(actual)) => {
      for i in 0..<keys.length() {
        let met = match actual.get(keys[i]) {
          Some(value) => contains(value, values[i])
          None => missing_meets(values[i])
        }
        if !met {
          return false
        }
      }
      true
    }
    (Not(inner), _) => !contains(actual, inner)
    (Exists(present), _) => present
    (Includes(inner), Array(actual)) => {
      for i in 0..<actual.length() {
        if contains(actual[i], inner) {
          return true
        }
      }
      false
    }
    (Array(expected), Array(actual)) => {
      if expected.length() != actual.length() {
        return false
      }
      for i in 0..<expected.length() {
        if !contains(actual[i], expected[i]) {
          return false
        }
      }
      true
    }
    (
      Scalar(Number(expected, repr=expected_text)),
      Number(actual, repr=actual_text),
    ) => same_number(expected, expected_text, actual, actual_text)
    (Scalar(String(expected)), String(actual)) => expected == actual
    (Pattern(pattern), String(actual)) => pattern.matches(@utf8.encode(actual))
    // A number as `stringify` writes it: in its shortest form, or as
    // written when a Double cannot hold it.
    (Pattern(pattern), Number(_)) =>
      pattern.matches(@utf8.encode(actual.stringify()))
    (Pattern(pattern), True) => pattern.matches(b"true")
    (Pattern(pattern), False) => pattern.matches(b"false")
    (Scalar(True), True) | (Scalar(False), False) | (Scalar(Null), Null) => true
    _ => false
  }
}

///|
/// Whether a missing key meets `expected`: only an operator can, as
/// `$exists: false` or `$not` of a condition that a missing key does not
/// meet.
fn missing_meets(expected : Expected) -> Bool {
  match expected {
    Not(inner) => !missing_meets(inner)
    Exists(present) => !present
    _ => false
  }
}

///|
/// Whether `a` and `b` are the same JSON value, so that conditions on them
/// match the same bodies: objects with the same keys and the same value for
/// each, arrays of the same values in the same order, and scalars as
/// `contains` compares them, except that a number kept as text is never
/// the same as one that is not. `same_number` compares a body's number kept
/// as text with the first by its text and with the second by its Double, so
/// 12345678901234567890 and 1.2345678901234567890e19, equal as Doubles,
/// match different bodies.
fn same_value(a : Json, b : Json) -> Bool {
  match (a, b) {
    (Object(a), Object(b)) =>
      a.length() == b.length() &&
      a
      .iter()
      .all(entry => b.get(entry.0) is Some(value) && same_value(entry.1, value))
    (Array(a), Array(b)) => {
      if a.length() != b.length() {
        return false
      }
      for i, value in a {
        if !same_value(value, b[i]) {
          return false
        }
      }
      true
    }
    (Number(a, repr=a_text), Number(b, repr=b_text)) =>
      (a_text is None) == (b_text is None) && same_number(a, a_text, b, b_text)
    _ => a == b
  }
}

///|
/// Whether two parsed JSON numbers, `a` and `b`, have the same value.
///
/// The parser keeps a number's source text, `a_text` or `b_text`, when its
/// Double cannot hold it: an integer above 2^53, or a number beyond a
/// Double's range, which becomes an infinity. Two such numbers are compared
/// by their text, as exact decimals, so that two 64-bit IDs that differ in
/// their last digit differ. Any other pair is compared by their Doubles.
fn same_number(
  a : Double,
  a_text : String?,
  b : Double,
  b_text : String?,
) -> Bool {
  match (a_text, b_text) {
    (Some(a_text), Some(b_text)) =>
      canonical_number(a_text) == canonical_number(b_text)
    _ => a == b
  }
}

///|
/// The JSON number `text` written so that two numbers whose exponents have
/// at most 18 digits have the same canonical text exactly when they have
/// the same value: `0`, or an optional `-`, the significant digits without
/// leading or trailing zeros, `e` and the power of ten of the last digit.
/// It takes time linear in the length of `text`, however large its
/// exponent.
fn canonical_number(text : String) -> String {
  let negative = text.has_prefix("-")
  let digits = StringBuilder()
  let mut fraction_digits = 0
  let mut in_fraction = false
  let exponent = StringBuilder()
  let mut exponent_negative = false
  let mut in_exponent = false
  for c in text {
    match c {
      '-' if in_exponent => exponent_negative = true
      '-' | '+' => ()
      '.' => in_fraction = true
      'e' | 'E' => in_exponent = true
      _ if in_exponent => exponent.write_char(c)
      _ => {
        digits.write_char(c)
        if in_fraction {
          fraction_digits += 1
        }
      }
    }
  }
  let digits = digits.to_string()
  let mut start = 0
  while start < digits.length() && digits[start] == '0' {
    start += 1
  }
  if start == digits.length() {
    return "0"
  }
  let mut end = digits.length()
  while digits[end - 1] == '0' {
    end -= 1
  }
  let significant = digits[start:end].to_owned()
  // The power of ten of the last significant digit is the exponent plus
  // `shift`, which the length of `text` bounds.
  let shift = digits.length() - end - fraction_digits
  let exponent = exponent.to_string()
  let mut first = 0
  while first < exponent.length() && exponent[first] == '0' {
    first += 1
  }
  let exponent = exponent[first:].to_owned()
  let sign = if negative { "-" } else { "" }
  // An Int64 holds any exponent of at most 18 digits plus the shift. A
  // longer one is kept as written, with the shift apart: such numbers are
  // equal only when written alike.
  if exponent.length() <= 18 {
    let mut power = 0L
    for c in exponent {
      power = power * 10L + (c.to_int() - '0'.to_int()).to_int64()
    }
    if exponent_negative {
      power = -power
    }
    "\{sign}\{significant}e\{power + shift.to_int64()}"
  } else {
    let exponent_sign = if exponent_negative { "-" } else { "" }
    "\{sign}\{significant}e\{exponent_sign}\{exponent}+\{shift}"
  }
}

///|
/// The condition's value, as a copy of its own.
pub impl ToJson for JsonCondition with fn to_json(self) {
  deep_copy(self.value)
}

///|
/// Conditions are equal when their values are, with numbers compared as
/// matching compares them. Patterns and operators are compared as written:
/// whether an object is a pattern object or an operator object depends
/// only on its members, so equal values hold the same patterns and
/// operators in the same places.
pub impl Eq for JsonCondition with fn equal(self, other) {
  same_value(self.value, other.value)
}

///|
/// Shows the condition's value.
pub impl Debug for JsonCondition with fn to_repr(self) {
  Repr::ctor("JsonCondition", [(None, Debug::to_repr(self.value))])
}

///|
/// A copy of `json` that shares no object or array with it.
fn deep_copy(json : Json) -> Json {
  match json {
    Object(members) => {
      let out = Map([])
      for key, value in members {
        out[key] = deep_copy(value)
      }
      Json::object(out)
    }
    Array(items) => Json::array(items.map(deep_copy))
    other => other
  }
}

///|
/// A Stub's response.
pub struct Response {
  status : Int
  /// The header fields, in the order written. A header given an array has
  /// one field per value, in array order. A `json` body adds
  /// `Content-Type: application/json` at the end unless one is given.
  headers : ReadOnlyArray[(String, String)]
  /// The body, when the response is not a template.
  body : ResponseBody
  /// With `template` on: the response's templates, parsed when the
  /// definition set was loaded or the Stub was added. They give the header
  /// values and the body or events of each response, rendered for its
  /// request, instead of `headers` and `body`.
  template : ResponseTemplate?
} derive(Debug, Eq)

///|
/// The templates of a response with `template` on.
pub struct ResponseTemplate {
  /// The header fields, their values text templates, in the order written.
  /// A header given an array has one field per value, in array order.
  /// `Content-Type` is never templated.
  headers : ReadOnlyArray[(String, @template.Text)]
  body : BodyTemplate
} derive(Debug, Eq)

///|
/// The body of a response with `template` on.
pub enum BodyTemplate {
  /// `body` or `bodyFile`: a text template, escaped by the media type of
  /// the response's `Content-Type`. An empty body is an empty text.
  Text(@template.Text)
  /// `json`: a structured template.
  Json(@template.Structured)
  /// `events`: Server-Sent Events, each templated.
  Events(ReadOnlyArray[EventTemplate])
} derive(Debug, Eq)

///|
/// A Server-Sent Event of a response with `template` on.
pub struct EventTemplate {
  /// How long to wait before writing the event, in milliseconds.
  delay_ms : Int
  /// The event type.
  event : @template.Text?
  /// The event ID.
  id : @template.Text?
  data : EventData
} derive(Debug, Eq)

///|
/// The data of a templated Server-Sent Event.
pub enum EventData {
  /// `data`: a text template, which may give several lines.
  Text(@template.Text)
  /// `json`: a structured template, sent as one line of compact JSON.
  Json(@template.Structured)
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
/// An event with these fields: one rendered from an `EventTemplate`.
pub fn SseEvent::SseEvent(
  delay_ms~ : Int,
  event~ : String?,
  id~ : String?,
  data~ : String,
) -> SseEvent {
  { delay_ms, event, id, data, }
}

///|
/// The Mock whose Hosts include `host`, a Host normalised by
/// `normalize_host`.
pub fn Snapshot::mock_for_host(self : Snapshot, host : String) -> Mock? {
  match self.host_index.get(host) {
    Some(i) => Some(self.mocks[i])
    None => None
  }
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
///
/// `env` holds the environment variables that templates may read, as
/// `--template-env` lists them, with the values the caller read: by
/// default, none. A template that reads another name is a problem. The
/// values are not part of the digest.
pub fn load(
  set : DefinitionSet,
  read_problems? : Array[Diagnostic] = [],
  env? : @template.Env = @template.Env([]),
) -> Result[Snapshot, Array[Diagnostic]] {
  let files = sorted_by_name(set.files).map(file => {
    (file.0, parse_file(file.0, file.1))
  })
  let reader = Reader::new(
    declared=declared_mocks(files),
    body_files=Map::from_array(set.body_files),
    env~,
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
          no_match_headers: ReadOnlyArray::from_array([]),
          journal: true,
          stubs: ReadOnlyArray::from_array([]),
          index: MatchIndex::new(ReadOnlyArray::from_array([])),
          scenarios: ReadOnlyArray::from_array([]),
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
      no_match_headers: ReadOnlyArray::from_array(mock.no_match_headers),
      journal: mock.journal,
      stubs,
      index: MatchIndex::new(stubs),
      scenarios: scenarios_of(stubs),
    }
  })
  let index_of = Map([])
  for i, mock in mocks {
    index_of[mock.name] = i
  }
  let host_index = Map([])
  for host, claim in reader.hosts {
    host_index[host] = index_of[claim.mock]
  }
  let default_index = match reader.default_mock {
    Some(claim) => Some(index_of[claim.mock])
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
/// The Scenarios that `stubs`, the Stubs of one Mock, name, in byte-wise
/// order of their names, each with its states: `initial_state`, then every
/// other state that the Stubs' `requires` and `moveTo` name for it, in
/// byte-wise order.
fn scenarios_of(
  stubs : ReadOnlyArray[Stub],
) -> ReadOnlyArray[ScenarioFileStates] {
  let by_scenario = StatesByScenario::new()
  for stub in stubs {
    if stub.scenario is Some(clause) {
      by_scenario.add_clause(clause)
    }
  }
  let scenarios = []
  for name, states in by_scenario.sorted() {
    scenarios.push(ScenarioFileStates::{
      name,
      states: ReadOnlyArray::from_array(states),
    })
  }
  ReadOnlyArray::from_array(scenarios)
}

///|
/// Scenario names, each with the states gathered for it, such as the
/// states that the `requires` and `moveTo` of a Mock's Stubs name. Every
/// Scenario has `initial_state`, so it is never gathered, and a Scenario
/// gathered without a state has only that one.
pub struct StatesByScenario {
  /// The states gathered, other than `initial_state`, by Scenario name.
  priv states : Map[String, Set[String]]
}

///|
/// No Scenario gathered yet.
pub fn StatesByScenario::new() -> StatesByScenario {
  { states: Map([]), }
}

///|
/// Gathers the Scenario `name`, and `state` for it unless it is `None` or
/// `initial_state`.
pub fn StatesByScenario::add(
  self : StatesByScenario,
  name : String,
  state : String?,
) -> Unit {
  let states = match self.states.get(name) {
    Some(states) => states
    None => {
      let states = Set([])
      self.states[name] = states
      states
    }
  }
  if state is Some(state) && state != initial_state {
    states.add(state)
  }
}

///|
/// Gathers the Scenario of `clause`, with the states its `requires` and
/// `moveTo` name.
pub fn StatesByScenario::add_clause(
  self : StatesByScenario,
  clause : ScenarioClause,
) -> Unit {
  self.add(clause.name, clause.requires)
  self.add(clause.name, clause.move_to)
}

///|
/// The Scenarios gathered, in byte-wise order of their names, each with its
/// states: `initial_state` first, then the others in byte-wise order.
pub fn StatesByScenario::sorted(
  self : StatesByScenario,
) -> Map[String, Array[String]] {
  let names = self.states.keys().collect()
  names.sort_by(compare_bytes)
  let sorted = Map([])
  for name in names {
    let others = self.states[name].iter().collect()
    others.sort_by(compare_bytes)
    sorted[name] = [initial_state, ..others]
  }
  sorted
}

///|
/// How `a` and `b` compare in byte-wise order of their UTF-8 encodings.
fn compare_bytes(a : String, b : String) -> Int {
  @utf8.encode(a).lexical_compare(@utf8.encode(b))
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
  sorted.sort_by((a, b) => compare_bytes(a.0, b.0))
  sorted
}
