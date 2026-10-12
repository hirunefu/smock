// The Admin API operations on Ephemeral Stubs, and reset, which clears
// Journal entries too. Each is scoped to the calling Session, named the way
// mocked requests name theirs, and each change is logged.

///|
/// The calling Session of `request`: the member of the Session header that
/// mocked requests carry it in, or `None` for the no-Session space.
fn Admin::session(self : Admin, request : @http1.Request) -> String? {
  @engine.session_of(
    request.headers.map(header => {
      (header.name, @utf8.decode_lossy(header.value))
    }),
    header=self.session_header,
    member_name=self.session_member,
  )
}

///|
/// The path segment at `index` of the request's path, percent-decoded, such
/// as the Mock name `users api` in `/v1/mocks/users%20api/stubs`.
fn path_segment(request : @http1.Request, index : Int) -> String {
  let segments = path_of(request.target).split("/").collect()
  @percent.decode_lossy(segments[index])
}

///|
/// The Mock an operation on `/v1/mocks/{mock}/...` names.
fn mock_of(request : @http1.Request) -> String {
  path_segment(request, 3)
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
    UnknownStub(mock~, id~) => {
      let caller = match session {
        Some(_) => "the calling Session"
        None => "the no-Session space"
      }
      self.error(
        404,
        "unknown_stub",
        "\{caller} has no Ephemeral Stub \{id.escape()} in the Mock \{mock.escape()}",
      )
    }
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
fn list_stubs(admin : Admin, request : @http1.Request, _body : Json?) -> Reply {
  let session = admin.session(request)
  let stubs = admin.engine().ephemeral_stubs(mock=mock_of(request), session~) catch {
      error => return admin.refused(error, session)
    }
  admin.json(200, {
    "stubs": Json::array(stubs.map(stub => ToJson::to_json(stub))),
  })
}

///|
/// Adds an Ephemeral Stub to a Mock for the calling Session, and logs it.
fn add_stub(admin : Admin, request : @http1.Request, body : Json?) -> Reply {
  let session = admin.session(request)
  let mock = mock_of(request)
  guard body is Some(body) else {
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
fn delete_stub(admin : Admin, request : @http1.Request, _body : Json?) -> Reply {
  let session = admin.session(request)
  let mock = mock_of(request)
  let id = path_segment(request, 5)
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
fn reset(admin : Admin, request : @http1.Request, body : Json?) -> Reply {
  let session = admin.session(request)
  guard reset_scope(body, session) is Some(scope) else {
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
