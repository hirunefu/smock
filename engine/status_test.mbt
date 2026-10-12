// The engine side of the Admin API status: the Mocks it serves, with their
// Hosts, and which one is the Default Mock.

///|
/// The Mocks of `h`'s status, one per line.
fn mocks(h : Harness) -> String {
  h.engine.status().mocks
  .map(mock => {
    let default = if mock.is_default { " (default)" } else { "" }
    "\{mock.name}\{default}: \{mock.hosts.join(", ")}"
  })
  .join("\n")
}

///|
test "status lists the Mocks in declaration order, with their Hosts as declared, and marks the Default Mock" {
  let h = harness([
    mock_file(
      "users", "\"hosts\": [\"Users.Example.com:8080\", \"users.internal\"], \"default\": true",
    ),
    mock_file("orders", "\"hosts\": [\"orders.example.com\"]"),
  ])
  inspect(
    mocks(h),
    content=(
      #|orders: orders.example.com
      #|users (default): Users.Example.com:8080, users.internal
    ),
  )
}

///|
test "status marks no Mock when there is no Default Mock" {
  let h = harness([
    mock_file("users", "\"hosts\": [\"users.example.com\"]"),
    mock_file("orders", "\"hosts\": [\"orders.example.com\"]"),
  ])
  inspect(
    mocks(h),
    content=(
      #|orders: orders.example.com
      #|users: users.example.com
    ),
  )
}

///|
test "status marks the only Mock as the Default Mock" {
  let h = harness([mock_file("users", "\"hosts\": [\"users.example.com\"]")])
  inspect(mocks(h), content="users (default): users.example.com")
}

///|
test "without Definition files, status lists one empty Default Mock named default" {
  let h = harness([])
  inspect(mocks(h), content="default (default): ")
}
