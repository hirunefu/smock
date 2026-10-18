// The Admin API operations on Scenarios: listing the calling Session's
// Scenarios of a Mock, with the state each is in and its known states, and
// setting the state of one. Both are scoped to the calling Session, named
// the way mocked requests name theirs, and a set is logged.

///|
/// Lists the calling Session's Scenarios of a Mock, by name.
fn list_scenarios(admin : Admin, call : Call) -> Reply {
  let session = admin.session(call.request)
  let scenarios = admin
    .engine()
    .list_scenarios(mock=call.param("mock"), session~) catch {
      error => return admin.refused(error, session)
    }
  admin.json(200, {
    "scenarios": Json::array(scenarios.map(scenario => scenario.to_json())),
  })
}

///|
/// Sets the state of one of the calling Session's Scenarios of a Mock, to
/// the state the body names, and logs it.
fn set_scenario(admin : Admin, call : Call) -> Reply {
  let session = admin.session(call.request)
  guard scenario_state(call.body) is Some(state) else {
    return admin.error(
      400, "invalid_request", "the body must be {\"state\":<name>}, the state to set the Scenario to",
    )
  }
  let mock = call.param("mock")
  let scenario = admin
    .engine()
    .set_scenario_state(
      mock~,
      session~,
      scenario=call.param("scenario"),
      state~,
    ) catch {
      error => return admin.refused(error, session)
    }
  admin.logger.info("Scenario state set", fields={
    "mock": Json::string(mock),
    "session": session_json(session),
    "scenario": Json::string(scenario.name),
    "state": Json::string(scenario.state),
  })
  admin.json(200, { "scenario": scenario.to_json() })
}

///|
/// The state a set body names: `{"state":<name>}`, where the name is a
/// non-empty string, with no other member. Any other body names none.
fn scenario_state(body : Json?) -> String? {
  guard body is Some(Object(fields)) &&
    fields.length() == 1 &&
    fields.get("state") is Some(String(state)) &&
    state != "" else {
    return None
  }
  Some(state)
}
