// Scenario state: the current state of each Scenario, per Mock and per
// Session. A Stub's scenario clause can require a state for the Stub to
// match, and move the Scenario to another state when the Stub is chosen.
// The state moves in `Engine::handle`, at the match decision, which is
// synchronous and single-threaded, so checking a state and moving it needs
// no lock (ADR 0003).

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
/// Whether `stub` can match in the current states, `states`: it has no
/// clause, its clause has no `requires`, or the Scenario is in the state it
/// requires.
fn scenario_allows(
  stub : @definitions.Stub,
  states : Map[String, String]?,
) -> Bool {
  match stub.scenario {
    Some({ requires: Some(required), name, .. }) =>
      current_state(states, name) == required
    _ => true
  }
}
