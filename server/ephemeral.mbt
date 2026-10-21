// The Admin API operations on Ephemeral Stubs, and reset, which clears
// Journal entries too. Each is scoped to the calling Session, named the way
// mocked requests name theirs, and each change is logged.

///|
/// The calling Session of `request`: the member of the Session header that
/// mocked requests carry it in, or `None` for the no-Session space.
fn Admin::session(self : Admin, request : @http1.Request) -> String? {
  self.sessions.session_of(decoded_headers(request))
}

///|
/// A Session as JSON: its key, or `null` for the no-Session space.
fn session_json(session : String?) -> Json {
  match session {
    Some(session) => Json::string(session)
    None => Json::null()
  }
}

///|
/// The calling Session `session`, as error messages name it: the calling
/// Session, or the no-Session space for `None`.
fn caller(session : String?) -> String {
  match session {
    Some(_) => "the calling Session"
    None => "the no-Session space"
  }
}

///|
/// The error reply to an operation the engine refused, for the calling
/// Session `session`.
fn Admin::refused(
  self : Admin,
  error : @engine.AdminError,
  session : String?,
) -> Reply {
  match error {
    UnknownMock(mock) =>
      self.error(
        404,
        "unknown_mock",
        "no Mock is named \{mock.escape()}: Mocks come only from Definition files",
      )
    UnknownEphemeralStub(mock~, id~) =>
      self.error(
        404,
        "unknown_stub",
        "\{caller(session)} has no Ephemeral Stub \{id.escape()} in the Mock \{mock.escape()}",
      )
    UnknownScenario(mock~, scenario~) =>
      self.error(
        404,
        "unknown_scenario",
        "no Stub of the Mock \{mock.escape()} names the Scenario \{scenario.escape()}, in the Definition files or among the Ephemeral Stubs of \{caller(session)}",
      )
    UnknownState(mock~, scenario~, state~, known~) =>
      self.error(
        400,
        "unknown_state",
        "\{state.escape()} is not a known state of the Scenario \{scenario.escape()} of the Mock \{mock.escape()} for \{caller(session)}, which are \{known.map(known => known.escape()).join(", ")}",
      )
    InvalidVariableName(name) =>
      self.error(
        400,
        "invalid_request",
        "\{name.escape()} is not a Variable name: 1 to \{@definitions.max_variable_name} ASCII letters, digits, _ and -",
      )
    UnknownVariable(mock~, name~) =>
      self.error(
        404,
        "unknown_variable",
        "\{caller(session)} has no Variable \{name.escape()} in the Mock \{mock.escape()}",
      )
    UnknownBucket(mock~, bucket~) =>
      self.error(
        404,
        "unknown_bucket",
        "the Mock \{mock.escape()} declares no Data bucket \{bucket.escape()}: Data buckets come only from Definition files",
      )
    InvalidData(bucket~, key~, problems~) => {
      let each = problems.map(problem => {
        if problem.pointer == "" {
          problem.message
        } else {
          "\{problem.pointer} \{problem.message}"
        }
      })
      self.error(
        400,
        "invalid_data",
        "the value breaks the rules of the Data bucket \{bucket.escape()}, keyed by \{key.escape()}: \{each.join("; ")}",
      )
    }
    StateLimitReached(message) =>
      self.error(507, "state_limit_reached", message)
    InvalidStub(problems) =>
      self.error(
        400,
        "invalid_stub",
        problems.map(problem => problem.to_string()).join("\n"),
      )
    JournalOff(None) =>
      self.error(
        409, "journal_off", "the Journal is off (--journal off): smock records no request",
      )
    JournalOff(Some(mock)) =>
      self.error(
        409,
        "journal_off",
        "the Journal is off for the Mock \{mock.escape()} (\"journal\": false in the Definition files): smock records none of its requests",
      )
  }
}

///|
/// Lists the calling Session's Ephemeral Stubs of a Mock, in the order they
/// are tried.
fn list_stubs(admin : Admin, call : Call) -> Reply {
  let session = admin.session(call.request)
  let stubs = admin.engine().ephemeral_stubs(mock=call.param("mock"), session~) catch {
      error => return admin.refused(error, session)
    }
  admin.json(200, {
    "stubs": Json::array(stubs.map(stub => ToJson::to_json(stub))),
  })
}

///|
/// Adds an Ephemeral Stub to a Mock for the calling Session, and logs it.
fn add_stub(admin : Admin, call : Call) -> Reply {
  let session = admin.session(call.request)
  let mock = call.param("mock")
  guard call.body is Some(body) else {
    return admin.error(
      400, "invalid_request", "the body must be the Ephemeral Stub to add, a JSON object",
    )
  }
  let stub = admin.engine().add_ephemeral_stub(mock~, session~, body) catch {
      error => return admin.refused(error, session)
    }
  admin.logger.info("Ephemeral Stub added", fields={
    "mock": Json::string(mock),
    "session": session_json(session),
    "id": Json::string(stub.id),
  })
  admin.json(201, { "stub": ToJson::to_json(stub) })
}

///|
/// Deletes one of the calling Session's Ephemeral Stubs, and logs it.
fn delete_stub(admin : Admin, call : Call) -> Reply {
  let session = admin.session(call.request)
  let mock = call.param("mock")
  let id = call.param("id")
  admin.engine().delete_ephemeral_stub(mock~, session~, id~) catch {
    error => return admin.refused(error, session)
  }
  admin.logger.info("Ephemeral Stub deleted", fields={
    "mock": Json::string(mock),
    "session": session_json(session),
    "id": Json::string(id),
  })
  admin.json(200, { "id": Json::string(id) })
}

///|
/// Resets the scope the body names: the calling Session, one Mock or
/// everything. Logs what it removed.
fn reset(admin : Admin, call : Call) -> Reply {
  let session = admin.session(call.request)
  guard reset_scope(call.body, session) is Some(scope) else {
    return admin.error(
      400, "invalid_request", "the body must be {\"scope\":\"session\"}, {\"scope\":\"mock\",\"mock\":<name>} or {\"scope\":\"all\"}",
    )
  }
  let removed = admin.engine().reset(scope) catch {
      error => return admin.refused(error, session)
    }
  let removed : Json = {
    "ephemeralStubs": Json::number(removed.ephemeral_stubs.to_double()),
    "journalEntries": Json::number(removed.journal_entries.to_double()),
    "scenarioStates": Json::number(removed.scenario_states.to_double()),
    "variables": Json::number(removed.variables.to_double()),
    "dataBuckets": Json::number(removed.data_buckets.to_double()),
  }
  let (scope_name, fields) : (String, Map[String, Json]) = match scope {
    Session(session) => ("session", { "session": session_json(session) })
    Mock(mock) => ("mock", { "mock": Json::string(mock) })
    All => ("all", Map([]))
  }
  let logged : Map[String, Json] = { "scope": Json::string(scope_name) }
  for key, value in fields {
    logged[key] = value
  }
  logged["removed"] = removed
  admin.logger.info("reset", fields=logged)
  admin.json(200, { "scope": Json::string(scope_name), "removed": removed })
}

///|
/// The scope a reset body names, for the calling Session `session`:
/// `{"scope":"session"}`, `{"scope":"mock","mock":<name>}` or
/// `{"scope":"all"}`, with no other member. Any other body names none.
fn reset_scope(body : Json?, session : String?) -> @engine.ResetScope? {
  guard body is Some(Object(fields)) else { return None }
  match (fields.get("scope"), fields.get("mock"), fields.length()) {
    (Some(String("session")), None, 1) => Some(Session(session))
    (Some(String("mock")), Some(String(mock)), 2) if mock != "" =>
      Some(Mock(mock))
    (Some(String("all")), None, 1) => Some(All)
    _ => None
  }
}
