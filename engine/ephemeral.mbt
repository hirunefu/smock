// Ephemeral Stubs: Stubs added to an existing Mock through the Admin API,
// each for one Session or for the no-Session space. They are tried before
// the Stubs from Definition files, and they survive a reload unless their
// Mock is gone.

///|
/// A Stub added to an existing Mock through the Admin API. It applies only
/// to the requests for its Mock that carry its Session, or, added without
/// a Session, to the requests for its Mock that carry none. Its JSON form
/// is the `EphemeralStub` schema of the Admin API document.
pub struct EphemeralStub {
  /// The ID smock assigned it: `eph-<n>`, where `n` counts the Ephemeral
  /// Stubs added since the process started, from 1.
  id : String
  /// The Mock it belongs to.
  mock : String
  /// The Session it applies to, or `None` for the no-Session space.
  session : String?
  /// The Stub as it was added: a Stub in the shape Definition files use,
  /// without `id` and `mock`.
  added : Map[String, Json]
  /// The Stub, validated and compiled.
  priv stub : @definitions.Stub
  /// Its own generator, when it has a seed, created from the seed when it
  /// was added.
  priv generator : @prng.Generator?
}

///|
/// `{id, mock, session}` and then the members of the Stub as it was added.
pub impl ToJson for EphemeralStub with fn to_json(self) {
  let out : Map[String, Json] = {
    "id": Json::string(self.id),
    "mock": Json::string(self.mock),
    "session": match self.session {
      Some(session) => Json::string(session)
      None => Json::null()
    },
  }
  for key, value in self.added {
    out[key] = value
  }
  Json::object(out)
}

///|
/// Ephemeral Stubs, by Mock, then by Session (`None` for the no-Session
/// space), each list in the order its Stubs are tried. No list is empty,
/// and no Mock is without one, so that Sessions that come and go leave
/// nothing behind.
priv struct EphemeralStubs {
  by_mock : Map[String, Map[String?, Array[EphemeralStub]]]
  /// The `n` of the last ID assigned.
  mut last_n : Int
}

///|
fn EphemeralStubs::new() -> EphemeralStubs {
  { by_mock: Map([]), last_n: 0, }
}

///|
/// Removes the Ephemeral Stubs of every Mock and Session for which
/// `remove` holds, and returns how many it removed.
fn EphemeralStubs::remove_where(
  self : EphemeralStubs,
  remove : (String, String?) -> Bool,
) -> Int {
  let mut count = 0
  for mock in self.by_mock.keys().collect() {
    let by_session = self.by_mock[mock]
    for session in by_session.keys().collect() {
      if remove(mock, session) {
        count += by_session[session].length()
        by_session.remove(session)
      }
    }
    if by_session.is_empty() {
      self.by_mock.remove(mock)
    }
  }
  count
}

///|
/// The Ephemeral Stubs of `mock` for `session`, in the order they are
/// tried: by priority, a lower number first and Stubs without a priority
/// last, then the newest first. There are none when the list is absent.
fn EphemeralStubs::of(
  self : EphemeralStubs,
  mock : String,
  session : String?,
) -> Array[EphemeralStub]? {
  match self.by_mock.get(mock) {
    Some(by_session) => by_session.get(session)
    None => None
  }
}

///|
/// Adds an Ephemeral Stub to the Mock `mock`, for `session`, or for the
/// no-Session space when it is `None`. `stub` is a Stub in the shape
/// Definition files use, without `id` and `mock`, with an inline body. It
/// is validated and compiled like a Stub from a Definition file, with the
/// environment variables the engine was created with, and gets the next
/// ID, `eph-<n>`. A Stub with a seed gets its own generator, from
/// its seed.
///
/// Raises `UnknownMock` when no Mock has the name `mock`, and
/// `InvalidStub`, with every problem, when the Stub is not valid.
pub fn Engine::add_ephemeral_stub(
  self : Engine,
  mock~ : String,
  session~ : String?,
  stub : Json,
) -> EphemeralStub raise AdminError {
  self.check_mock(mock)
  let ephemeral = self.ephemeral
  let n = ephemeral.last_n + 1
  let id = "eph-\{n}"
  let compiled = match
    @definitions.ephemeral_stub(stub, id~, mock~, env=self.env) {
    Ok(compiled) => compiled
    Err(problems) => raise InvalidStub(problems)
  }
  guard stub is Object(fields) else { abort("a valid Stub is an object") }
  ephemeral.last_n = n
  let generator = match compiled.fault {
    Some({ seed: Some(seed), .. }) => Some(@prng.Generator(seed))
    _ => None
  }
  let added : EphemeralStub = {
    id,
    mock,
    session,
    added: fields.copy(),
    stub: compiled,
    generator,
  }
  let by_session = match ephemeral.by_mock.get(mock) {
    Some(by_session) => by_session
    None => {
      let by_session = Map([])
      ephemeral.by_mock[mock] = by_session
      by_session
    }
  }
  let list = match by_session.get(session) {
    Some(list) => list
    None => {
      let list = []
      by_session[session] = list
      list
    }
  }
  // The newest is tried first among equal priorities: it goes before every
  // Stub whose priority is not lower.
  let at = list.search_by(other => other.stub.compare_priority(compiled) >= 0)
  list.insert(at.unwrap_or(list.length()), added)
  added
}

///|
/// Raises `UnknownMock` unless the snapshot served has a Mock named `mock`.
fn Engine::check_mock(self : Engine, mock : String) -> Unit raise AdminError {
  if !self.snapshot.mocks.iter().any(m => m.name == mock) {
    raise UnknownMock(mock)
  }
}

///|
/// The Ephemeral Stubs of the Mock `mock` for `session`, or for the
/// no-Session space when it is `None`, in the order they are tried: by
/// priority, then the newest first.
///
/// Raises `UnknownMock` when no Mock has the name `mock`.
pub fn Engine::ephemeral_stubs(
  self : Engine,
  mock~ : String,
  session~ : String?,
) -> Array[EphemeralStub] raise AdminError {
  self.check_mock(mock)
  self.ephemeral.of(mock, session).map_or([], list => list.copy())
}

///|
/// Deletes the Ephemeral Stub `id` of the Mock `mock` that was added for
/// `session`, or for the no-Session space when it is `None`. Another
/// Session's Ephemeral Stubs are unknown here.
///
/// Raises `UnknownMock` when no Mock has the name `mock`, and
/// `UnknownEphemeralStub` when `session` has no Ephemeral Stub `id` in it.
pub fn Engine::delete_ephemeral_stub(
  self : Engine,
  mock~ : String,
  session~ : String?,
  id~ : String,
) -> Unit raise AdminError {
  self.check_mock(mock)
  guard self.ephemeral.of(mock, session) is Some(list) &&
    list.search_by(stub => stub.id == id) is Some(i) else {
    raise UnknownEphemeralStub(mock~, id~)
  }
  list.remove(i) |> ignore
  if list.is_empty() {
    self.ephemeral.remove_where((m, s) => m == mock && s == session) |> ignore
  }
}

///|
/// What a reset clears.
pub(all) enum ResetScope {
  /// The Ephemeral Stubs, Journal entries and Scenario state of this
  /// Session, or of the no-Session space for `None`, across all Mocks, and
  /// its eviction count.
  Session(String?)
  /// The Ephemeral Stubs, Journal entries and Scenario state of this Mock,
  /// for every Session.
  Mock(String)
  /// Every Ephemeral Stub, the whole Journal, every Scenario state and
  /// every eviction count.
  All
} derive(Debug)

///|
/// What a reset removed.
pub(all) struct Removed {
  /// How many Ephemeral Stubs.
  ephemeral_stubs : Int
  /// How many Journal entries.
  journal_entries : Int
  /// How many Scenario states, each of one Mock, Session and Scenario,
  /// which are back in `Started`.
  scenario_states : Int
} derive(Debug)

///|
/// Clears the Ephemeral Stubs, the Journal entries and the Scenario state
/// in `scope`, which sends its Scenarios back to `Started`, and for the
/// scope of a Session or everything, the eviction counts. What Definition
/// files declare never changes.
///
/// Raises `UnknownMock` when the scope is a Mock that no Mock has the name
/// of and that the Journal holds no entries of. A Mock that a reload
/// removed has no Ephemeral Stubs left, but the entries it recorded remain,
/// and a reset of it clears them.
pub fn Engine::reset(
  self : Engine,
  scope : ResetScope,
) -> Removed raise AdminError {
  match scope {
    Session(session) =>
      {
        ephemeral_stubs: self.ephemeral.remove_where((_, s) => s == session),
        journal_entries: self.journal.reset_session(session),
        scenario_states: self.scenarios.remove_where((_, s) => s == session),
      }
    Mock(mock) => {
      let journal_entries = self.journal.remove_where(entry => {
        entry.mock == Some(mock)
      })
      if journal_entries == 0 {
        self.check_mock(mock)
      }
      {
        ephemeral_stubs: self.ephemeral.remove_where((m, _) => m == mock),
        journal_entries,
        scenario_states: self.scenarios.remove_where((m, _) => m == mock),
      }
    }
    All =>
      {
        ephemeral_stubs: self.ephemeral.remove_where((_, _) => true),
        journal_entries: self.journal.reset_all(),
        scenario_states: self.scenarios.remove_where((_, _) => true),
      }
  }
}
