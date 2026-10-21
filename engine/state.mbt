// The bound on per-Session state: one count, for the whole process, of the
// bytes the state kept per Mock and Session takes, against one bound that
// the engine is created with. Each write is checked against it before it is
// taken, and the count is kept up to date as state is written and removed,
// so nothing is ever summed again. It counts the Variables and the copies
// of Data buckets; Scenario state stays outside it, and so do the initial
// values of Data buckets, which are part of the definition set.
//
// What counts follows ADR 0004's follow-up: beside the bytes of names and
// compact JSON, fixed overheads for each space, Variable, copy and JSON
// value, so that long Session keys or many tiny values cannot take far more
// memory than the bound counts.

///|
/// The bound on per-Session state an engine has by default: 64 MiB.
pub let default_state_max_bytes : Int = 64 * 1024 * 1024

///|
/// The count of per-Session state against its bound, and the writes the
/// bound refused. Every store of per-Session state shares the engine's one.
priv struct StateBound {
  /// The most bytes the count may hold.
  max_bytes : Int
  /// The bytes the count holds now. It never passes `max_bytes`, since a
  /// write that would take it there is refused.
  mut bytes : Int
  /// The writes the bound refused, since the process started: a request's
  /// or an Admin API set's.
  mut refused : Int64
}

///|
/// A bound of `max_bytes`, with nothing counted.
fn StateBound::new(max_bytes : Int) -> StateBound {
  { max_bytes, bytes: 0, refused: 0L, }
}

///|
/// Whether the count can grow by `more` bytes, which may be negative,
/// without passing the bound.
fn StateBound::fits(self : StateBound, more : Int64) -> Bool {
  self.bytes.to_int64() + more <= self.max_bytes.to_int64()
}

///|
/// Grows the count by `more` bytes, or shrinks it when `more` is negative.
/// A growth must fit (`fits`).
fn StateBound::add(self : StateBound, more : Int64) -> Unit {
  self.bytes = (self.bytes.to_int64() + more).to_int()
}

///|
/// Counts a refusal of writes, a request's or an Admin API set's, which
/// would grow the count by `more` bytes and do not fit, and says why, as
/// the 507 tells the client.
fn StateBound::refuse(self : StateBound, more : Int64) -> String {
  self.refused += 1L
  "the writes would take per-Session state from \{self.bytes} to \{self.bytes.to_int64() + more} bytes, above its bound of \{self.max_bytes} (--state-max-bytes)"
}

///|
/// What the bound on per-Session state counts, and what it refused.
pub(all) struct StateStats {
  /// The bytes the count holds now.
  bytes : Int
  /// The writes the bound refused since the process started, whatever
  /// resets came since: each refused request once, and each refused Admin
  /// API set once.
  writes_refused : Int64
} derive(Debug)

///|
/// What the bound on per-Session state counts now, and how many writes,
/// from requests and Admin API sets, it has refused since the process
/// started.
pub fn Engine::state_stats(self : Engine) -> StateStats {
  { bytes: self.state.bytes, writes_refused: self.state.refused, }
}

///|
/// What a space, one Mock with one Session or with none, counts while it
/// holds any state, beside its Mock name and its Session key.
let space_overhead : Int64 = 64L

///|
/// What each Variable counts beside its name and its value.
let variable_overhead : Int64 = 64L

///|
/// What each copy of a Data bucket counts beside the bucket's name and its
/// value.
let copy_overhead : Int64 = 64L

///|
/// What each JSON value in a value counts beside its compact JSON: each
/// object, array, string, number, boolean and null.
let json_value_overhead : Int64 = 16L

///|
/// The bytes the space of `mock` and `session` counts: the Mock name and
/// the Session key in UTF-8, none for the no-Session space, and
/// `space_overhead`.
fn space_bytes(mock : String, session : String?) -> Int64 {
  let key = match session {
    Some(key) => utf8_length(key)
    None => 0
  }
  utf8_length(mock).to_int64() + key.to_int64() + space_overhead
}

///|
/// The bytes a Variable named `name` counts beside its value: the name in
/// UTF-8 and `variable_overhead`.
fn variable_name_bytes(name : String) -> Int64 {
  utf8_length(name).to_int64() + variable_overhead
}

///|
/// The bytes a copy of the Data bucket `bucket` whose value is `value`
/// counts: the bucket's name in UTF-8, `copy_overhead`, and the value.
fn copy_bytes(bucket : String, value : Json) -> Int64 {
  utf8_length(bucket).to_int64() + copy_overhead + value_bytes(value)
}

///|
/// The bytes `value` counts: its compact JSON as smock writes it, in UTF-8,
/// and `json_value_overhead` for each JSON value in it.
fn value_bytes(value : Json) -> Int64 {
  @template.compact_length(value, per_value=json_value_overhead)
}

///|
/// The bytes a member named `name` whose value is `value` adds to an
/// object's count: the name as a JSON string, the colon and the value,
/// without the comma before it.
fn member_bytes(name : String, value : Json) -> Int64 {
  @template.compact_length(Json::string(name)) + 1L + value_bytes(value)
}

///|
/// The response to a request whose writes the bound on per-Session state
/// refused: 507, with what the bound counts.
fn state_limit_reached(stub : String, message : String) -> ResponsePlan {
  let body : Json = {
    "error": "state limit reached",
    "stub": Json::string(stub),
    "message": Json::string(message),
  }
  {
    status: 507,
    headers: [("Content-Type", "application/json")],
    body: Bytes(@template.compact_json_bytes(body)),
    delay_ms: 0,
    fault: None,
  }
}
