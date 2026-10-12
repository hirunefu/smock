// Seam 2 tests of the Admin API foundation: authentication, the replica
// header and warning, the error shape and status. Every response is checked
// against the OpenAPI document (contract_test.mbt).

///|
/// Two Mocks with Hosts; `users` is the Default Mock.
let users_and_orders : String =
  #|mocks:
  #|  - name: users
  #|    hosts: [users.example.com, "Users.Example.com:8080"]
  #|    default: true
  #|  - name: orders
  #|    hosts: [orders.example.com]

///|
async test "status shows the build smock --version prints, and the Mocks with their Hosts and the Default Mock" {
  let (_, version_line) = smock_stdout(["--version"])
  with_definitions([("mocks.yaml", users_and_orders)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let response = smock.admin("GET", "/v1/status")
      conforms("GET", "/v1/status", response)
      guard response.json() is Object(status) &&
        status.get("version") is Some(String(version)) &&
        status.get("commit") is Some(String(commit)) &&
        status.get("toolchain") is Some(String(toolchain)) else {
        fail("no build in \{response.body}")
      }
      inspect(
        "smock \{version} (commit \{commit}, \{toolchain})" ==
        version_line.trim().to_owned(),
        content="true",
      )
      json_inspect(status.get("mocks").unwrap_or(Json::null()), content=[
        {
          "name": "users",
          "hosts": ["users.example.com", "Users.Example.com:8080"],
          "default": true,
        },
        { "name": "orders", "hosts": ["orders.example.com"], "default": false },
      ])
      json_inspect(status.get("warnings").unwrap_or(Json::null()), content=[])
    })
  })
}

///|
async test "without Definition files, status shows the one empty Default Mock" {
  let _ = with_smock(["--port", "0"], smock => {
    let response = smock.admin("GET", "/v1/status")
    conforms("GET", "/v1/status", response)
    guard response.json() is Object(status) else { fail(response.body) }
    json_inspect(status.get("mocks").unwrap_or(Json::null()), content=[
      { "name": "default", "hosts": [], "default": true },
    ])
  })
}
