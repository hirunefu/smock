// The per-Session store: the state kept per Mock and per Session, which is
// the Variables and the copies of Data buckets. Stubs write it at the match
// decision, in `Engine::handle`, and the Admin API reads and writes it.
// Both are synchronous and single-threaded, so reading it and writing it
// needs no lock (ADR 0003). What it holds counts against the bound on
// per-Session state, which the store keeps up to date as it writes and
// removes.

///|
/// What is kept per Mock and Session: the Variables, and the copies of Data
/// buckets. Each kind is kept by Mock, then by Session (`None` for the
/// no-Session space), then by name. No map is empty, and no Mock or Session
/// is without one, so that Sessions that come and go leave nothing behind.
///
/// A space, one Mock with one Session or with none, counts its Mock name
/// and its Session key once while it holds any Variable or copy.
priv struct SessionStore {
  /// The Variables, by Mock, then by Session, then by name.
  variables : Map[String, Map[String?, Map[String, Json]]]
  /// The copies of Data buckets, by Mock, then by Session.
  copies : Map[String, Map[String?, Copies]]
  /// The engine's bound on per-Session state.
  state : StateBound
}

///|
/// The copies of Data buckets that one space holds: one Session's copies,
/// or the no-Session space's, of one Mock's buckets. A bucket has a copy
/// only once the space wrote to it; until then, it reads the initial value.
priv struct Copies {
  /// The value of each copy, by the bucket's name: what templates read.
  values : Map[String, Json]
  /// What each copy counts against the bound on per-Session state, by the
  /// bucket's name, as `copy_bytes` gives it. It is kept as the copy is
  /// written, so dropping a copy gives back what it counted without
  /// measuring the copy again.
  bytes : Map[String, Int64]
}

///|
/// Nothing stored, counting against `state`.
fn SessionStore::new(state : StateBound) -> SessionStore {
  { variables: Map([]), copies: Map([]), state, }
}

///|
/// The Variables of `mock` for `session`, by name. There are none when the
/// map is absent. While no Variable is stored, as when no Stub writes any,
/// it looks nothing up.
fn SessionStore::variables_of(
  self : SessionStore,
  mock : String,
  session : String?,
) -> Map[String, Json]? {
  if self.variables.is_empty() {
    return None
  }
  match self.variables.get(mock) {
    Some(by_session) => by_session.get(session)
    None => None
  }
}

///|
/// The copies of Data buckets of `mock` that `session` holds, by the
/// bucket's name. There are none when the map is absent. While no copy is
/// stored, it looks nothing up.
fn SessionStore::copies_of(
  self : SessionStore,
  mock : String,
  session : String?,
) -> Copies? {
  if self.copies.is_empty() {
    return None
  }
  match self.copies.get(mock) {
    Some(by_session) => by_session.get(session)
    None => None
  }
}

///|
/// The values of the copies of Data buckets of `mock` that `session` holds,
/// by the bucket's name, as templates read them in place of the buckets'
/// initial values. There are none when the space holds no copy.
fn SessionStore::copy_values(
  self : SessionStore,
  mock : String,
  session : String?,
) -> Map[String, Json]? {
  match self.copies_of(mock, session) {
    Some(copies) => Some(copies.values)
    None => None
  }
}

///|
/// Whether the space of `mock` and `session` holds any Variable or copy,
/// and so counts against the bound.
fn SessionStore::holds(
  self : SessionStore,
  mock : String,
  session : String?,
) -> Bool {
  self.variables_of(mock, session) is Some(_) ||
  self.copies_of(mock, session) is Some(_)
}

///|
/// How many bytes the count grows by when the space of `mock` and
/// `session` is written to: what the space counts while it holds nothing
/// yet, otherwise 0.
fn SessionStore::space_growth(
  self : SessionStore,
  mock : String,
  session : String?,
) -> Int64 {
  if self.holds(mock, session) {
    0L
  } else {
    space_bytes(mock, session)
  }
}

///|
/// How many bytes the count of per-Session state would grow by if the
/// Variables `names` of `mock` for `session` were written, each with the
/// value at the same index of `values`: negative when it would shrink.
/// `before` is what the space's Variables are now, as `variables_of` gives
/// them. The space counts when it holds nothing yet, each new Variable
/// counts its name, and each value counts in place of the one it replaces.
fn SessionStore::variable_growth(
  self : SessionStore,
  mock : String,
  session : String?,
  before : Map[String, Json]?,
  names : ReadOnlyArray[String],
  values : Array[Json],
) -> Int64 {
  if names.length() == 0 {
    return 0L
  }
  let mut more = 0L
  match before {
    None => {
      more = self.space_growth(mock, session)
      for i in 0..<names.length() {
        more += variable_name_bytes(names[i]) + value_bytes(values[i])
      }
    }
    Some(variables) =>
      for i in 0..<names.length() {
        more += value_bytes(values[i])
        match variables.get(names[i]) {
          Some(old) => more -= value_bytes(old)
          None => more += variable_name_bytes(names[i])
        }
      }
  }
  more
}

///|
/// Writes the Variables `names` of `mock` for `session`, each to the value
/// at the same index of `values`, at once, and grows the count of
/// per-Session state by `growth`, what `variable_growth` gives for them,
/// which must fit. Writing nothing creates no map.
fn SessionStore::write_variables(
  self : SessionStore,
  mock : String,
  session : String?,
  names : ReadOnlyArray[String],
  values : Array[Json],
  growth~ : Int64,
) -> Unit {
  if names.length() == 0 {
    return
  }
  self.state.add(growth)
  let by_session = match self.variables.get(mock) {
    Some(by_session) => by_session
    None => {
      let by_session = Map([])
      self.variables[mock] = by_session
      by_session
    }
  }
  let variables = match by_session.get(session) {
    Some(variables) => variables
    None => {
      let variables = Map([])
      by_session[session] = variables
      variables
    }
  }
  for i in 0..<names.length() {
    variables[names[i]] = values[i]
  }
}

///|
/// Removes the Variable `name` of `mock` for `session` and gives back the
/// bytes it counted, and those of its space when the space holds nothing
/// more, so that no map is left empty. Returns whether there was such a
/// Variable.
fn SessionStore::remove_variable(
  self : SessionStore,
  mock : String,
  session : String?,
  name : String,
) -> Bool {
  guard self.variables.get(mock) is Some(by_session) &&
    by_session.get(session) is Some(variables) &&
    variables.get(name) is Some(value) else {
    return false
  }
  let mut bytes = variable_name_bytes(name) + value_bytes(value)
  variables.remove(name)
  if variables.is_empty() {
    by_session.remove(session)
    if by_session.is_empty() {
      self.variables.remove(mock)
    }
    if !self.holds(mock, session) {
      bytes += space_bytes(mock, session)
    }
  }
  self.state.add(-bytes)
  true
}

///|
/// How many bytes the count of per-Session state would grow by if the copy
/// of the bucket `bucket` of `mock` that `session` holds became a value
/// that counts `bytes`, as `copy_bytes` gives it: negative when it would
/// shrink. The space counts when it holds nothing yet, and the value counts
/// in place of the copy it replaces, if any.
fn SessionStore::copy_growth(
  self : SessionStore,
  mock : String,
  session : String?,
  bucket : String,
  bytes : Int64,
) -> Int64 {
  match self.copies_of(mock, session) {
    Some(copies) =>
      match copies.bytes.get(bucket) {
        Some(old) => bytes - old
        None => bytes
      }
    None => self.space_growth(mock, session) + bytes
  }
}

///|
/// Makes `value` the copy of the bucket `bucket` of `mock` that `session`
/// holds, in place of the copy it had, if any. `bytes` is what the copy
/// counts, as `copy_bytes` gives it, and the count of per-Session state
/// grows by `growth`, what `copy_growth` gives for it, which must fit.
fn SessionStore::write_copy(
  self : SessionStore,
  mock : String,
  session : String?,
  bucket : String,
  value : Json,
  bytes~ : Int64,
  growth~ : Int64,
) -> Unit {
  self.state.add(growth)
  let by_session = match self.copies.get(mock) {
    Some(by_session) => by_session
    None => {
      let by_session = Map([])
      self.copies[mock] = by_session
      by_session
    }
  }
  let copies = match by_session.get(session) {
    Some(copies) => copies
    None => {
      let copies = { values: Map([]), bytes: Map([]), }
      by_session[session] = copies
      copies
    }
  }
  copies.values[bucket] = value
  copies.bytes[bucket] = bytes
}

///|
/// Drops the copy of the bucket `bucket` of `mock` that `session` holds,
/// so that the bucket reads its initial value again, and gives back the
/// bytes it counted, and those of its space when the space holds nothing
/// more, so that no map is left empty. Returns whether there was such a
/// copy.
fn SessionStore::drop_copy(
  self : SessionStore,
  mock : String,
  session : String?,
  bucket : String,
) -> Bool {
  guard self.copies.get(mock) is Some(by_session) &&
    by_session.get(session) is Some(copies) &&
    copies.bytes.get(bucket) is Some(bytes) else {
    return false
  }
  let mut bytes = bytes
  copies.values.remove(bucket)
  copies.bytes.remove(bucket)
  if copies.values.is_empty() {
    by_session.remove(session)
    if by_session.is_empty() {
      self.copies.remove(mock)
    }
    if !self.holds(mock, session) {
      bytes += space_bytes(mock, session)
    }
  }
  self.state.add(-bytes)
  true
}

///|
/// Clears the Variables and the copies of every Mock and Session for which
/// `remove` holds, gives back the bytes they and their spaces counted, and
/// returns how many Variables it cleared. It leaves no map empty.
fn SessionStore::remove_where(
  self : SessionStore,
  remove : (String, String?) -> Bool,
) -> Int {
  let mut variable_count = 0
  for mock in self.variables.keys().collect() {
    let by_session = self.variables[mock]
    for session in by_session.keys().collect() {
      if remove(mock, session) {
        let variables = by_session[session]
        let mut bytes = 0L
        for name, value in variables {
          bytes += variable_name_bytes(name) + value_bytes(value)
        }
        // A space that holds copies too gives its bytes back with them.
        if self.copies_of(mock, session) is None {
          bytes += space_bytes(mock, session)
        }
        self.state.add(-bytes)
        variable_count += variables.length()
        by_session.remove(session)
      }
    }
    if by_session.is_empty() {
      self.variables.remove(mock)
    }
  }
  // The Variables of every space cleared here are gone already, so each
  // space gives its bytes back with its copies.
  for mock in self.copies.keys().collect() {
    let by_session = self.copies[mock]
    for session in by_session.keys().collect() {
      if remove(mock, session) {
        let copies = by_session[session]
        let mut bytes = space_bytes(mock, session)
        for _, counted in copies.bytes {
          bytes += counted
        }
        self.state.add(-bytes)
        by_session.remove(session)
      }
    }
    if by_session.is_empty() {
      self.copies.remove(mock)
    }
  }
  variable_count
}
