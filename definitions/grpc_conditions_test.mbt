// gRPC Stubs' `json` body conditions at load: checked against the input
// type of the Stub's method, and normalised to smock's decoded form, the
// form in which a call's message reaches the Stubs. The set is
// fixtures/protobuf/users/users.proto (users_set_test.mbt), which
// scripts/gen-protobuf-fixtures.sh builds with protoc.

///|
/// Loads `a.yaml`, which declares the Mock `users`, whose set is
/// users.proto, and the Mock `plain`, with no set, and then `stubs`, the
/// lines of its `stubs` array. Renders what the loader makes of them: every
/// problem, one per line, as `smock check` prints it; or, for a valid set,
/// each Stub's `json` body condition as matching sees it, then each
/// warning.
fn conditions(stubs : String) -> String raise {
  let yaml =
    #|mocks:
    #|  - { name: users, grpc: { descriptorSet: users.binpb } }
    #|  - { name: plain }
    #|stubs:
    #|
  match
    @definitions.load({
      files: [("a.yaml", @utf8.encode(yaml + stubs))],
      body_files: [("users.binpb", set_bytes(users_set))],
    }) {
    Ok(snapshot) => {
      let lines = []
      for mock in snapshot.mocks {
        for stub in mock.stubs {
          let condition = match stub.serves {
            Ordinary({ request: { body: Some(Json(condition)), .. }, .. }) =>
              condition.to_json().stringify()
            _ => "no json condition"
          }
          lines.push("\{stub.id}: \{condition}")
        }
      }
      for warning in snapshot.warnings() {
        lines.push(warning.to_string())
      }
      lines.join("\n")
    }
    Err(problems) => problems.map(problem => problem.to_string()).join("\n")
  }
}

///|
test "the ticket's example: a proto name becomes its JSON name and an enum number its name; a misspelt key, and an int64 written as a string, are problems, the second suggesting the number" {
  inspect(
    conditions(
      (
        #|  - id: example
        #|    mock: users
        #|    request: { path: /users.Users/Find, body: { json: { user_id: 42, status: 1 } } }
        #|    response: { json: { id: found } }
      ),
    ),
    content=(
      #|example: {"userId":42,"status":"ACTIVE"}
    ),
  )
  inspect(
    conditions(
      (
        #|  - id: misspelt
        #|    mock: users
        #|    request: { path: /users.Users/Find, body: { json: { usr_id: 42 } } }
        #|    response: { json: { id: found } }
        #|  - id: a-string
        #|    mock: users
        #|    request: { path: /users.Users/Find, body: { json: { user_id: "42" } } }
        #|    response: { json: { id: found } }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/request/body/json/usr_id: is not a field of users.Query
      #|a.yaml: /stubs/1/request/body/json/user_id: must be written 42, as smock prints it: the field user_id of users.Query has the type int64
    ),
  )
}
