// Scenario state: the current state of each Scenario, per Mock and per
// Session. A Stub's scenario clause can require a state for the Stub to
// match, and move the Scenario to another state when the Stub is chosen.
// The state moves in `Engine::handle`, at the match decision, which is
// synchronous and single-threaded, so checking a state and moving it needs
// no lock (ADR 0003). A reload that swaps in new definitions keeps each
// state that is still a known state of its Mock, Session and Scenario, and
// sends any other back to Started.

///|
/// How a request moved a Scenario: the clause of the Stub that answered it,
/// with the state the Scenario was in and the state it is in after. Without
/// `moveTo`, `to` is `from`.
pub(all) struct ScenarioMove {
  /// The Scenario's name, within the Mock that answered.
  name : String
  /// The state the Scenario was in when the Stub was chosen.
  from : String
  /// The state the Scenario is in after.
  to : String
} derive(Debug, Eq)

///|
/// The JSON form of the move, the `ScenarioMove` schema of the Admin API
/// document: `{"name", "from", "to"}`.
pub impl ToJson for ScenarioMove with fn to_json(self) {
  {
    "name": Json::string(self.name),
    "from": Json::string(self.from),
    "to": Json::string(self.to),
  }
}

///|
/// The state of each Scenario that is not in `Started`, by Mock, then by
/// Session (`None` for the no-Session space), then by Scenario name. A
/// Scenario without an entry is in `Started`, so a move back to `Started`
/// deletes its entry. No map is empty, and no Mock or Session is without
/// one, so that Sessions that come and go leave nothing behind.
priv struct ScenarioStates {
  by_mock : Map[String, Map[String?, Map[String, String]]]
}

///|
/// No state stored: every Scenario of every Mock and Session is in
/// `Started`.
fn ScenarioStates::new() -> ScenarioStates {
  { by_mock: Map([]), }
}

///|
/// The states of the Scenarios of `mock` for `session` that are not in
/// `Started`, by Scenario name. There are none when the map is absent.
fn ScenarioStates::of(
  self : ScenarioStates,
  mock : String,
  session : String?,
) -> Map[String, String]? {
  match self.by_mock.get(mock) {
    Some(by_session) => by_session.get(session)
    None => None
  }
}

///|
/// Moves the Scenario `name` of `mock` for `session` to `state`. A move to
/// `Started` deletes its entry, and any map it leaves empty.
fn ScenarioStates::set(
  self : ScenarioStates,
  mock : String,
  session : String?,
  name : String,
  state : String,
) -> Unit {
  if state == @definitions.initial_state {
    guard self.by_mock.get(mock) is Some(by_session) &&
      by_session.get(session) is Some(states) else {
      return
    }
    states.remove(name)
    if states.is_empty() {
      by_session.remove(session)
      if by_session.is_empty() {
        self.by_mock.remove(mock)
      }
    }
    return
  }
  let by_session = match self.by_mock.get(mock) {
    Some(by_session) => by_session
    None => {
      let by_session = Map([])
      self.by_mock[mock] = by_session
      by_session
    }
  }
  let states = match by_session.get(session) {
    Some(states) => states
    None => {
      let states = Map([])
      by_session[session] = states
      states
    }
  }
  states[name] = state
}

///|
/// The current state of the Scenario `name`, among `states`, the states of
/// one Mock and Session that are not in `Started`.
fn current_state(states : Map[String, String]?, name : String) -> String {
  guard states is Some(states) && states.get(name) is Some(state) else {
    return @definitions.initial_state
  }
  state
}

///|
/// Whether a Stub with the Scenario clause `clause` can match in the current
/// states, `states`: it has no clause, its clause has no `requires`, or the
/// Scenario is in the state it requires.
fn scenario_allows(
  clause : @definitions.ScenarioClause?,
  states : Map[String, String]?,
) -> Bool {
  match clause {
    Some({ requires: Some(required), name, .. }) =>
      current_state(states, name) == required
    _ => true
  }
}

///|
/// The known states of the Scenarios of the Mock `mock` for `session`
/// (`None` for the no-Session space), by Scenario name. The known states of
/// a Scenario are:
///
/// - `Started`;
/// - every state that the `requires` and `moveTo` of the Mock's file Stubs
///   name for it;
/// - every state that the `requires` and `moveTo` of the Session's own
///   Ephemeral Stubs in the Mock name for it.
///
/// Here are the Scenarios that those Stubs name, and those that the Session
/// holds a state for although no Stub names them any more, such as after it
/// deleted the Ephemeral Stubs that did. The only known state of those, as
/// of any Scenario not here, is `Started`. They come in byte-wise order of
/// their names, and each one's states start with `Started`, then the others
/// in byte-wise order, as the Admin API lists them.
///
/// It goes through the Session's Ephemeral Stubs, so it is computed off the
/// request path, never in `Engine::handle`. It is for reloads, which check
/// the stored states against it, and for the Admin API operations that
/// list and set states.
fn Engine::known_states(
  self : Engine,
  mock : @definitions.Mock,
  session : String?,
) -> Map[String, Array[String]] {
  let by_scenario = @definitions.StatesByScenario::new()
  // The snapshot holds the file part, computed at load.
  for scenario in mock.scenarios {
    for state in scenario.states {
      by_scenario.add(scenario.name, Some(state))
    }
  }
  if self.ephemeral.of(mock.name, session) is Some(list) {
    for e in list {
      match e.stub.serves {
        Ordinary(ordinary) =>
          if ordinary.scenario is Some(clause) {
            by_scenario.add_clause(clause)
          }
        Crud(_) => ()
      }
    }
  }
  if self.scenarios.of(mock.name, session) is Some(held) {
    for name, _ in held {
      by_scenario.add(name, None)
    }
  }
  by_scenario.sorted()
}

///|
/// A Scenario of a Mock as one Session sees it: the state it is in and its
/// known states, as the Admin API lists and sets it. Its JSON form is the
/// `Scenario` schema of the Admin API document.
pub(all) struct Scenario {
  /// The Scenario's name, within its Mock.
  name : String
  /// The state the Scenario is in for the Session.
  state : String
  /// The known states of the Scenario for the Session: `Started` first,
  /// then the others in byte-wise order.
  states : Array[String]
} derive(Debug, Eq)

///|
/// `{"name", "state", "states"}`.
pub impl ToJson for Scenario with fn to_json(self) {
  {
    "name": Json::string(self.name),
    "state": Json::string(self.state),
    "states": Json::array(self.states.map(Json::string)),
  }
}

///|
/// The Mock named `mock` in the snapshot served.
///
/// Raises `UnknownMock` when no Mock has the name.
fn Engine::mock_named(
  self : Engine,
  mock : String,
) -> @definitions.Mock raise AdminError {
  for m in self.snapshot.mocks {
    if m.name == mock {
      return m
    }
  }
  raise UnknownMock(mock)
}

///|
/// The Scenarios of the Mock `mock` for `session`, or for the no-Session
/// space when it is `None`, in byte-wise order of their names, each with
/// the state it is in for the Session and its known states. They are the
/// Scenarios that the Mock's file Stubs name, those that the Session's own
/// Ephemeral Stubs in the Mock name, and those that the Session holds a
/// state for although no Stub names them any more, such as after it
/// deleted the Ephemeral Stubs that did: the only known state of those is
/// `Started`. A Session's state may be outside the known states, when only
/// an Ephemeral Stub it deleted named that state.
///
/// Raises `UnknownMock` when no Mock has the name `mock`.
pub fn Engine::list_scenarios(
  self : Engine,
  mock~ : String,
  session~ : String?,
) -> Array[Scenario] raise AdminError {
  let known = self.known_states(self.mock_named(mock), session)
  let held = self.scenarios.of(mock, session)
  let listed = []
  for name, states in known {
    listed.push({ name, state: current_state(held, name), states, })
  }
  listed
}

///|
/// Moves the Scenario `scenario` of the Mock `mock` to `state` for
/// `session`, or for the no-Session space when it is `None`, and returns
/// the Scenario as it is after. Setting `Started` resets the Scenario.
///
/// The Scenario must be one that `Engine::list_scenarios` lists for the
/// Session, and the state one of its known states. So every state stored
/// is one that the files or the Session's own Ephemeral Stubs name, and a
/// typo cannot leave a Scenario in a state that no Stub matches.
///
/// Raises `UnknownMock` when no Mock has the name `mock`,
/// `UnknownScenario` when the Mock has no such Scenario for the Session,
/// and `UnknownState` when the state is not one of its known states.
pub fn Engine::set_scenario_state(
  self : Engine,
  mock~ : String,
  session~ : String?,
  scenario~ : String,
  state~ : String,
) -> Scenario raise AdminError {
  let known = self.known_states(self.mock_named(mock), session)
  guard known.get(scenario) is Some(states) else {
    raise UnknownScenario(mock~, scenario~)
  }
  if !states.contains(state) {
    raise UnknownState(mock~, scenario~, state~, known=states)
  }
  self.scenarios.set(mock, session, scenario, state)
  { name: scenario, state, states, }
}

///|
/// Checks every stored state against the snapshot just swapped in, whose
/// Mocks are `mocks`, by name, and against the Ephemeral Stubs that stayed.
/// It drops the states of each Mock that is gone, keeps each state that is
/// one of the known states of its Mock, Session and Scenario, and drops any
/// other, which sends its Scenario back to `Started`. Returns how many it
/// sent back.
fn Engine::prune_scenario_states(
  self : Engine,
  mocks : Map[String, @definitions.Mock],
) -> Int {
  // The states of a Mock that is gone go with it, and are not counted.
  self.scenarios.remove_where((mock, _) => !mocks.contains(mock)) |> ignore
  self.scenarios.retain((mock, session) => {
    // A Scenario that no Stub names any more knows only `Started`, which is
    // never stored, so its state goes.
    let known = self.known_states(mocks[mock], session)
    (scenario, state) => {
      known.get(scenario) is Some(states) && states.contains(state)
    }
  })
}

///|
/// Keeps each state that its test holds for and clears every other, which
/// sends its Scenario back to `Started`, and returns how many states it
/// cleared. For each Mock and Session that has a state, `keep` gives the
/// test, before any of their states is cleared; the test takes the name of
/// a Scenario and its state. Like any move back to `Started`, it leaves no
/// map empty.
fn ScenarioStates::retain(
  self : ScenarioStates,
  keep : (String, String?) -> (String, String) -> Bool,
) -> Int {
  let mut cleared = 0
  for mock in self.by_mock.keys().collect() {
    let by_session = self.by_mock[mock]
    for session in by_session.keys().collect() {
      let kept = keep(mock, session)
      let states = by_session[session]
      for name in states.keys().collect() {
        if !kept(name, states[name]) {
          states.remove(name)
          cleared += 1
        }
      }
      if states.is_empty() {
        by_session.remove(session)
      }
    }
    if by_session.is_empty() {
      self.by_mock.remove(mock)
    }
  }
  cleared
}

///|
/// Clears the states of every Mock and Session for which `remove` holds,
/// which sends their Scenarios back to `Started`, and returns how many
/// states it cleared.
fn ScenarioStates::remove_where(
  self : ScenarioStates,
  remove : (String, String?) -> Bool,
) -> Int {
  self.retain((mock, session) => {
    let removed = remove(mock, session)
    (_, _) => !removed
  })
}
