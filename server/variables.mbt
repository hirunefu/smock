// The Admin API operations on Variables: listing the calling Session's
// Variables of a Mock, setting one and deleting one. Each is scoped to the
// calling Session, named the way mocked requests name theirs, and a set
// and a delete are logged.

///|
/// Lists the calling Session's Variables of a Mock, by name.
fn list_variables(admin : Admin, call : Call) -> Reply {
  let session = admin.session(call.request)
  let variables = admin
    .engine()
    .list_variables(mock=call.param("mock"), session~) catch {
      error => return admin.refused(error, session)
    }
  admin.json(200, { "variables": Json::object(variables) })
}

///|
/// Sets one of the calling Session's Variables of a Mock to the value the
/// body holds, and logs it.
fn set_variable(admin : Admin, call : Call) -> Reply {
  let session = admin.session(call.request)
  guard call.body is Some(value) else {
    return admin.error(
      400, "invalid_request", "the body must be the value to set the Variable to: any JSON value",
    )
  }
  let mock = call.param("mock")
  let name = call.param("name")
  admin.engine().set_variable(mock~, session~, name~, value) catch {
    error => return admin.refused(error, session)
  }
  admin.logger.info("Variable set", fields={
    "mock": Json::string(mock),
    "session": session_json(session),
    "variable": Json::string(name),
  })
  admin.json(200, { "name": Json::string(name), "value": value })
}

///|
/// Deletes one of the calling Session's Variables of a Mock, and logs it.
fn delete_variable(admin : Admin, call : Call) -> Reply {
  let session = admin.session(call.request)
  let mock = call.param("mock")
  let name = call.param("name")
  admin.engine().delete_variable(mock~, session~, name~) catch {
    error => return admin.refused(error, session)
  }
  admin.logger.info("Variable deleted", fields={
    "mock": Json::string(mock),
    "session": session_json(session),
    "variable": Json::string(name),
  })
  admin.json(200, { "name": Json::string(name) })
}
