// Seam 2 tests of gRPC Stubs' `json` conditions over h2c and through
// `smock check`: checked against the input type when the files load, and
// normalised to smock's decoded form, so that conditions written with
// proto names, enum numbers, an enum alias or a float that rounding
// changes meet the calls that send those values. The set is
// fixtures/protobuf/users/users.proto, and the messages are what protoc
// encodes from the .txtpb files beside it
// (scripts/gen-protobuf-fixtures.sh), so the codec is never checked
// against itself.

///|
/// The directory of the users fixtures.
let users_dir : String = "fixtures/protobuf/users"

///|
/// The framed message that protoc encoded from `<name>.txtpb` in the users
/// fixtures.
async fn users_message(name : String) -> Bytes {
  framed(@fs.read_file("\{users_dir}/\{name}.binpb").binary())
}

///|
/// Runs `f` with a definitions directory holding `users.yaml`, whose text
/// is `yaml`, and the set of users.proto at `files/users.binpb`.
async fn with_users_set(yaml : String, f : async (String) -> Unit) -> Unit {
  with_definitions([("users.yaml", yaml)], dir => {
    @fs.mkdir("\{dir}/files")
    write_bytes(
      dir,
      "files/users.binpb",
      @fs.read_file("\{users_dir}/users.binpb").binary(),
    )
    f(dir)
  })
}

///|
/// The `grpc-status` of `reply`: from its trailers, or from its HEADERS
/// when it is Trailers-Only.
fn GrpcReply::status(self : GrpcReply) -> String {
  let fields = match self.trailers {
    Some(trailers) => trailers
    None => self.head
  }
  for field in fields {
    if field.0 == "grpc-status" {
      return field.1
    }
  }
  "none"
}

///|
async test "the ticket's example: a condition with a proto name and an enum number meets a call that sends those values, and an unmatched call's Near miss shows it normalised" {
  let yaml =
    #|mocks:
    #|  - name: users
    #|    grpc: { descriptorSet: users.binpb }
    #|stubs:
    #|  - id: example
    #|    mock: users
    #|    request: { path: /users.Users/Find, body: { json: { user_id: 42, status: 1 } } }
    #|    response: { json: { id: found } }
  with_users_set(yaml, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let found = client.call("/users.Users/Find", body=users_message("query"))
      // A Query of user 42 with no status meets no Stub.
      let unmatched = client.call(
        "/users.Users/Find",
        body=users_message("ratio-9-99"),
      )
      inspect("\{found.status()} \{unmatched.status()}", content="0 12")
      inspect(
        smock.bodies(),
        content=(
          #|"example": {"userId":42,"status":"ACTIVE","ratio":0.1,"token":"+/8=","labels":{"7":"seven"},"history":["ACTIVE","SUSPENDED"],"profile":{"displayName":"Tom","scores":{"math_score":90}},"friends":[{"displayName":"Ann","scores":{}}]}
          #|null: {"userId":42,"status":"STATUS_UNSPECIFIED","ratio":9.99,"token":"","labels":{},"history":[],"friends":[]}
        ),
      )
      let (_, journal) = smock.journal()
      guard journal
        is Object({ "entries": [_, Object({ "nearMiss": near_miss, .. })], .. }) else {
        fail("not two entries: \{journal.stringify()}")
      }
      inspect(
        near_miss.stringify(),
        content=(
          #|{"stub":"example","stubSource":"file","failed":[{"condition":"body","expected":{"json":{"userId":42,"status":"ACTIVE"}},"actual":["{\"userId\":42,\"status\":\"STATUS_UNSPECIFIED\",\"ratio\":9.99,\"token\":\"\",\"labels\":{},\"history\":[],\"friends\":[]}"]}]}
        ),
      )
    })
  })
}

///|
async test "conditions written with proto names, enum numbers and an enum alias meet calls; map keys, which are data, are matched as written" {
  let yaml =
    #|mocks:
    #|  - name: users
    #|    grpc: { descriptorSet: users.binpb }
    #|stubs:
    #|  - id: proto-names
    #|    mock: users
    #|    request:
    #|      path: /users.Users/Find
    #|      headers: { x-case: proto-names }
    #|      body: { json: { user_id: 42, profile: { display_name: Tom, scores: { math_score: 90 } } } }
    #|    response: { json: { id: proto-names } }
    #|  - id: enum-numbers
    #|    mock: users
    #|    request:
    #|      path: /users.Users/Find
    #|      headers: { x-case: enum-numbers }
    #|      body: { json: { status: 1, history: [1, 2] } }
    #|    response: { json: { id: enum-numbers } }
    #|  - id: enum-alias
    #|    mock: users
    #|    request:
    #|      path: /users.Users/Find
    #|      headers: { x-case: enum-alias }
    #|      body: { json: { status: ENABLED, history: { $includes: ENABLED } } }
    #|    response: { json: { id: enum-alias } }
    #|  - id: data-keys
    #|    mock: users
    #|    request:
    #|      path: /users.Users/Find
    #|      headers: { x-case: data-keys }
    #|      body: { json: { labels: { "7": seven }, friends: { $includes: { displayName: Ann } }, token: "+/8=" } }
    #|    response: { json: { id: data-keys } }
  with_users_set(yaml, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let statuses = []
      for case in ["proto-names", "enum-numbers", "enum-alias", "data-keys"] {
        let reply = client.call(
          "/users.Users/Find",
          headers=[("x-case", case)],
          body=users_message("query"),
        )
        statuses.push("\{case}: \{reply.status()}")
      }
      inspect(
        statuses.join("\n"),
        content=(
          #|proto-names: 0
          #|enum-numbers: 0
          #|enum-alias: 0
          #|data-keys: 0
        ),
      )
      inspect(
        answered_by(smock),
        content=(
          #|"users" "proto-names" "OK" "{\"userId\":42,\"status\":\"ACTIVE\",\"ratio\":0.1,\"token\":\"+/8=\",\"labels\":{\"7\":\"seven\"},\"history\":[\"ACTIVE\",\"SUSPENDED\"],\"profile\":{\"displayName\":\"Tom\",\"scores\":{\"math_score\":90}},\"friends\":[{\"displayName\":\"Ann\",\"scores\":{}}]}"/63
          #|"users" "enum-numbers" "OK" "{\"userId\":42,\"status\":\"ACTIVE\",\"ratio\":0.1,\"token\":\"+/8=\",\"labels\":{\"7\":\"seven\"},\"history\":[\"ACTIVE\",\"SUSPENDED\"],\"profile\":{\"displayName\":\"Tom\",\"scores\":{\"math_score\":90}},\"friends\":[{\"displayName\":\"Ann\",\"scores\":{}}]}"/63
          #|"users" "enum-alias" "OK" "{\"userId\":42,\"status\":\"ACTIVE\",\"ratio\":0.1,\"token\":\"+/8=\",\"labels\":{\"7\":\"seven\"},\"history\":[\"ACTIVE\",\"SUSPENDED\"],\"profile\":{\"displayName\":\"Tom\",\"scores\":{\"math_score\":90}},\"friends\":[{\"displayName\":\"Ann\",\"scores\":{}}]}"/63
          #|"users" "data-keys" "OK" "{\"userId\":42,\"status\":\"ACTIVE\",\"ratio\":0.1,\"token\":\"+/8=\",\"labels\":{\"7\":\"seven\"},\"history\":[\"ACTIVE\",\"SUSPENDED\"],\"profile\":{\"displayName\":\"Tom\",\"scores\":{\"math_score\":90}},\"friends\":[{\"displayName\":\"Ann\",\"scores\":{}}]}"/63
        ),
      )
    })
  })
}

///|
async test "float conditions 0.1 and 9.99 meet calls that send those floats, and 16777217 meets what a call of it prints, 16777216" {
  let yaml =
    #|mocks:
    #|  - name: users
    #|    grpc: { descriptorSet: users.binpb }
    #|stubs:
    #|  - id: tenth
    #|    mock: users
    #|    request: { path: /users.Users/Find, body: { json: { ratio: 0.1 } } }
    #|    response: { json: { id: tenth } }
    #|  - id: nine-ninety-nine
    #|    mock: users
    #|    request: { path: /users.Users/Find, body: { json: { ratio: 9.99 } } }
    #|    response: { json: { id: nine-ninety-nine } }
    #|  - id: rounded
    #|    mock: users
    #|    request: { path: /users.Users/Find, body: { json: { ratio: 16777217 } } }
    #|    response: { json: { id: rounded } }
  with_users_set(yaml, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      for name in ["query", "ratio-9-99", "ratio-16777217"] {
        let reply = client.call("/users.Users/Find", body=users_message(name))
        guard reply.status() == "0" else { fail("\{name}: \{reply.render()}") }
      }
      inspect(
        smock.bodies(),
        content=(
          #|"tenth": {"userId":42,"status":"ACTIVE","ratio":0.1,"token":"+/8=","labels":{"7":"seven"},"history":["ACTIVE","SUSPENDED"],"profile":{"displayName":"Tom","scores":{"math_score":90}},"friends":[{"displayName":"Ann","scores":{}}]}
          #|"nine-ninety-nine": {"userId":42,"status":"STATUS_UNSPECIFIED","ratio":9.99,"token":"","labels":{},"history":[],"friends":[]}
          #|"rounded": {"userId":42,"status":"STATUS_UNSPECIFIED","ratio":16777216,"token":"","labels":{},"history":[],"friends":[]}
        ),
      )
    })
  })
}

///|
async test "templates, find, $each, Variables and data writes read the decoded body, so they see JSON names only" {
  let yaml =
    #|mocks:
    #|  - name: users
    #|    grpc: { descriptorSet: users.binpb }
    #|data:
    #|  - { mock: users, name: seen, json: null }
    #|stubs:
    #|  - id: spelled
    #|    mock: users
    #|    request: { path: /users.Users/Find, body: { json: { user_id: 42 } } }
    #|    variables:
    #|      user: ${body.userId}
    #|      by-proto-name: ${body.user_id ?? 'missing'}
    #|      statuses: { $each: body.history, as: s, do: "${s}" }
    #|      friend: ${find(body.friends, 'displayName', 'Ann').displayName}
    #|      friend-by-proto-name: ${find(body.friends, 'display_name', 'Ann') ?? 'missing'}
    #|    dataWrites:
    #|      - { op: set, bucket: seen, value: { user: "${body.userId}", by-proto-name: "${body.user_id ?? 'missing'}" } }
    #|    response:
    #|      template: true
    #|      json: { id: "${body.userId} ${body.user_id ?? 'missing'} ${body.profile.displayName}" }
  with_users_set(yaml, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let reply = client.call("/users.Users/Find", body=users_message("query"))
      // Found { id: "42 missing Tom" }: field 1, 14 octets, framed.
      inspect(
        reply.render(),
        content=(
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  smock-mock: users; via=default
          #|  date: <now>
          #|DATA 00000000100a0e3432206d697373696e6720546f6d
          #|TRAILERS
          #|  grpc-status: 0
          #|(end)
        ),
      )
      inspect(
        smock.admin("GET", "/v1/mocks/users/variables").body,
        content=(
          #|{"variables":{"by-proto-name":"missing","friend":"Ann","friend-by-proto-name":"missing","statuses":["ACTIVE","SUSPENDED"],"user":42},"warnings":[]}
        ),
      )
      inspect(
        smock.admin("GET", "/v1/mocks/users/data/seen").body,
        content=(
          #|{"bucket":{"name":"seen","key":null,"newKey":null,"written":true,"value":{"user":42,"by-proto-name":"missing"}},"warnings":[]}
        ),
      )
    })
  })
}

///|
async test "smock check reports each condition that does not fit the input type at the value at fault, suggesting the printed form where ProtoJSON reads a value smock never prints, and warns of a gRPC Stub shadowed once normalised" {
  let invalid =
    #|mocks:
    #|  - name: users
    #|    grpc: { descriptorSet: users.binpb }
    #|stubs:
    #|  - id: misspelt
    #|    mock: users
    #|    request: { path: /users.Users/Find, body: { json: { usr_id: 42 } } }
    #|    response: { json: { id: found } }
    #|  - id: an-int64-as-a-string
    #|    mock: users
    #|    request: { path: /users.Users/Find, body: { json: { user_id: "42" } } }
    #|    response: { json: { id: found } }
    #|  - id: beyond-a-float
    #|    mock: users
    #|    request: { path: /users.Users/Find, body: { json: { ratio: 1e39 } } }
    #|    response: { json: { id: found } }
    #|  - id: unpadded
    #|    mock: users
    #|    request: { path: /users.Users/Find, body: { json: { token: "+/8" } } }
    #|    response: { json: { id: found } }
    #|  - id: url-safe
    #|    mock: users
    #|    request: { path: /users.Users/Find, body: { json: { token: "-_8=" } } }
    #|    response: { json: { id: found } }
    #|  - id: a-map-key
    #|    mock: users
    #|    request: { path: /users.Users/Find, body: { json: { labels: { "007": seven } } } }
    #|    response: { json: { id: found } }
    #|  - id: an-unknown-enum-name
    #|    mock: users
    #|    request: { path: /users.Users/Find, body: { json: { history: [ACTIVE, ACTIV] } } }
    #|    response: { json: { id: found } }
  let shadowed =
    #|mocks:
    #|  - name: users
    #|    grpc: { descriptorSet: users.binpb }
    #|stubs:
    #|  - id: by-proto-name
    #|    mock: users
    #|    request: { path: /users.Users/Find, body: { json: { user_id: 42, status: 1 } } }
    #|    response: { json: { id: first } }
    #|  - id: by-json-name
    #|    mock: users
    #|    request:
    #|      path: /users.Users/Find
    #|      headers: { x-tenant: acme }
    #|      body: { json: { userId: 42, status: ENABLED } }
    #|    response: { json: { id: second } }
  let out = []
  for yaml in [invalid, shadowed] {
    with_users_set(yaml, dir => out.push(check([dir])))
  }
  inspect(
    out.join("---\n"),
    content=(
      #|status 1
      #|users.yaml: /stubs/0/request/body/json/usr_id: is not a field of users.Query
      #|users.yaml: /stubs/1/request/body/json/user_id: must be written 42, as smock prints it: the field user_id of users.Query has the type int64
      #|users.yaml: /stubs/2/request/body/json/ratio: must be a number within the range of a float, or "NaN", "Infinity" or "-Infinity": the field ratio of users.Query has the type float
      #|users.yaml: /stubs/3/request/body/json/token: must be written "+/8=", as smock prints it: the field token of users.Query has the type bytes
      #|users.yaml: /stubs/4/request/body/json/token: must be written "+/8=", as smock prints it: the field token of users.Query has the type bytes
      #|users.yaml: /stubs/5/request/body/json/labels/007: must be written "7", as smock prints it: the keys of the map field labels of users.Query have the type int32
      #|users.yaml: /stubs/6/request/body/json/history/1: must be the name of a value of users.Status, or an integer from -2147483648 to 2147483647: the elements of the field history of users.Query have the type users.Status
      #|---
      #|status 0
      #|users.yaml: /stubs/1: warning: the Stub "by-json-name" can never match: the Stub "by-proto-name" at users.yaml: /stubs/0 is tried first and matches every request this one would
      #|
    ),
  )
}
