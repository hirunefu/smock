// The replica warning of the Admin API. Replicas share no state (ADR 0002),
// so in a deployment of several, every Admin API response warns that the
// state it shows or changes is that of the replica that answered alone.

///|
test "with one replica, Admin API responses carry no warning" {
  json_inspect(@engine.admin_warnings(replicas=1, replica="smock-0"), content=[])
}

///|
test "with more than one replica, every Admin API response warns that each replica keeps its own Ephemeral Stubs, Scenario state and Journal, and names the replica that answered" {
  json_inspect(
    @engine.admin_warnings(replicas=3, replica="smock-7d9f8-abcde"),
    content=[
      {
        "code": "per_replica_state",
        "message": "This deployment runs 3 replicas (--replicas), and each one keeps its own Ephemeral Stubs, Scenario state and Journal. This response comes from smock-7d9f8-abcde alone.",
      },
    ],
  )
}
