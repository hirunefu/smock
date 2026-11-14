// Seam 2 tests of gRPC replies: a gRPC Stub's `json` reply is read as
// ProtoJSON and encoded with its method's output type, when the files load
// for a static reply, and on each call once rendered for a templated one.
// The set is fixtures/protobuf/replies/replies.proto, and the reply bytes
// are compared with protoc's encodings of the same messages, which
// scripts/gen-protobuf-fixtures.sh writes, so the encoder is never checked
// against itself.

///|
/// The set of fixtures/protobuf/replies/replies.proto.
let replies_set_path : String = "fixtures/protobuf/replies/replies.binpb"

///|
/// The set of fixtures/protobuf/unserved/unserved.proto, whose output types
/// reach types that gRPC Stubs do not serve yet.
let unserved_set_path : String = "fixtures/protobuf/unserved/unserved.binpb"

///|
/// The framed reply that protoc encodes from
/// fixtures/protobuf/replies/<name>.txtpb.
async fn protoc_reply(name : String) -> Bytes {
  framed(@fs.read_file("fixtures/protobuf/replies/\{name}.binpb").binary())
}

///|
/// Runs `f` with a definitions directory holding `replies.yaml`, which
/// declares the Mock `accounts`, the Default Mock, whose set is
/// replies.proto's, and the Mock `clock`, whose set is unserved.proto's,
/// then holds `stubs`, the lines of its `stubs` array; and with the two
/// sets at `files/replies.binpb` and `files/unserved.binpb`.
async fn with_accounts(stubs : String, f : async (String) -> Unit) -> Unit {
  let yaml =
    #|mocks:
    #|  - name: accounts
    #|    default: true
    #|    grpc: { descriptorSet: replies.binpb }
    #|  - name: clock
    #|    hosts: [clock.svc]
    #|    grpc: { descriptorSet: unserved.binpb }
    #|stubs:
    #|
  with_definitions([("replies.yaml", yaml + stubs)], dir => {
    @fs.mkdir("\{dir}/files")
    write_bytes(
      dir,
      "files/replies.binpb",
      @fs.read_file(replies_set_path).binary(),
    )
    write_bytes(
      dir,
      "files/unserved.binpb",
      @fs.read_file(unserved_set_path).binary(),
    )
    f(dir)
  })
}

///|
async test "the gRPC Stubs' example: a static reply with an int64 as a string, an enum by its number and a repeated string has the bytes protoc encodes" {
  let stubs =
    #|  - id: user
    #|    mock: accounts
    #|    request: { path: /replies.Accounts/GetUser }
    #|    response: { json: { user_id: "42", status: 1, tags: [a, b] } }
  with_accounts(stubs, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let reply = client.call("/replies.Accounts/GetUser")
      inspect(
        reply.render(),
        content=(
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  smock-mock: accounts; via=default
          #|  date: <now>
          #|DATA 000000000a082a10011a01611a0162
          #|TRAILERS
          #|  grpc-status: 0
          #|(end)
        ),
      )
      // protoc's encoding of {userId: 42, status: ACTIVE, tags: [a, b]}.
      inspect(reply.data == [protoc_reply("user")], content="true")
    })
  })
}

///|
async test "static replies with both spellings of names, 64-bit integers as strings, enums by number, a packed = false field, maps, a oneof and no json have the bytes protoc encodes" {
  let stubs =
    #|  - id: maxima
    #|    mock: accounts
    #|    request: { path: /replies.Accounts/GetEverything, headers: { x-tenant: maxima } }
    #|    response:
    #|      json:
    #|        aDouble: 1.7976931348623157e308
    #|        a_float: 3.4028235e38
    #|        anInt32: 2147483647
    #|        an_int64: "9223372036854775807"
    #|        aUint32: "4294967295"
    #|        a_uint64: "18446744073709551615"
    #|        aSint32: 2147483647
    #|        a_sint64: "9223372036854775807"
    #|        aFixed32: 4294967295
    #|        a_fixed64: "18446744073709551615"
    #|        anSfixed32: 2147483647
    #|        an_sfixed64: "9223372036854775807"
    #|        a_bool: true
    #|        aString: "\"\\ é ☺ 😈"
    #|        some_bytes: AAH7_w
    #|        status: 2
    #|        alias: r
    #|  - id: lists
    #|    mock: accounts
    #|    request: { path: /replies.Accounts/GetEverything, headers: { x-tenant: lists } }
    #|    response:
    #|      json:
    #|        int32s: [1, -1, 300]
    #|        unpacked_int32s: [1, -2]
    #|        doubles: [0.5, 1e100]
    #|        floats: [0.1, 9.99]
    #|        int64s: ["9223372036854775807", -1]
    #|        uint64s: ["18446744073709551615", "0"]
    #|        sint32s: [-1, 1, -2147483648]
    #|        sint64s: ["-9223372036854775808"]
    #|        fixed32s: [1, 4294967295]
    #|        sfixed64s: [-1]
    #|        bools: [true, false, true]
    #|        statuses: [ACTIVE, 0, SUSPENDED, 7]
    #|        strings: ["", x]
    #|        byte_strings: [/w==, ""]
    #|        nesteds: [{ label: a }, {}]
    #|  - id: maps
    #|    mock: accounts
    #|    request: { path: /replies.Accounts/GetEverything, headers: { x-tenant: maps } }
    #|    response:
    #|      json:
    #|        counts: { b: 2, a: 1, "": 0 }
    #|        names: { "10": ten, "-1": minus one, "2": "" }
    #|        by_flag: { "true": { label: "yes" }, "false": {} }
    #|        byId: { "7": STATUS_UNSPECIFIED, "-9223372036854775808": ACTIVE }
    #|        blobs: { "18446744073709551615": AQ== }
    #|        bySint: { "-2": 1.5 }
    #|        by_fixed: { "1": true }
    #|  - id: choice
    #|    mock: accounts
    #|    request: { path: /replies.Accounts/GetEverything, headers: { x-tenant: choice } }
    #|    response: { json: { nested: {}, maybe: 0, number: null, word: "" } }
    #|  - id: inner
    #|    mock: accounts
    #|    request: { path: /replies.Accounts/GetEverything, headers: { x-tenant: inner } }
    #|    response:
    #|      json: { inner: { label: outer, recursive: { an_int32: 1, inner: { label: inner } } } }
    #|  - id: empty
    #|    mock: accounts
    #|    request: { path: /replies.Accounts/GetEverything, headers: { x-tenant: empty } }
    #|    response: {}
  with_accounts(stubs, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let out = []
      for tenant in ["maxima", "lists", "maps", "choice", "inner"] {
        let reply = client.call("/replies.Accounts/GetEverything", headers=[
          ("x-tenant", tenant),
        ])
        let same = reply.data == [protoc_reply(tenant)]
        out.push(
          "\{tenant}: \{if same { "protoc's bytes" } else { reply.render() }}",
        )
      }
      // An empty message: a DATA frame with the prefix alone.
      let reply = client.call("/replies.Accounts/GetEverything", headers=[
        ("x-tenant", "empty"),
      ])
      out.push("empty: DATA \{reply.data.map(hex).join(" ")}")
      inspect(
        out.join("\n"),
        content=(
          #|maxima: protoc's bytes
          #|lists: protoc's bytes
          #|maps: protoc's bytes
          #|choice: protoc's bytes
          #|inner: protoc's bytes
          #|empty: DATA 0000000000
        ),
      )
    })
  })
}

///|
async test "a templated reply is rendered from the request, then read as ProtoJSON and encoded" {
  let stubs =
    #|  - id: user
    #|    mock: accounts
    #|    request: { path: /replies.Accounts/GetUser }
    #|    response: { template: true, json: { userId: "7", display_name: "${body.name}" } }
  with_accounts(stubs, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let reply = client.call("/replies.Accounts/GetUser")
      // protoc encodes `user_id: 7 display_name: "Tom"` as 08072203546f6d.
      inspect(
        reply.render(),
        content=(
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  smock-mock: accounts; via=default
          #|  date: <now>
          #|DATA 000000000708072203546f6d
          #|TRAILERS
          #|  grpc-status: 0
          #|(end)
        ),
      )
      let (_, page) = smock.journal()
      inspect(
        answers(page),
        content=(
          #|"user" 200 "OK"
        ),
      )
    })
  })
}

///|
async test "a templated reply that does not fit the output type gets Trailers-Only INTERNAL template failed, and its Journal entry's templateError says why" {
  let stubs =
    #|  - id: user
    #|    mock: accounts
    #|    request: { path: /replies.Accounts/GetUser, headers: { x-tenant: user } }
    #|    response: { template: true, json: { userId: "${header.x-user}" } }
    #|  - id: users
    #|    mock: accounts
    #|    request: { path: /replies.Accounts/GetUser, headers: { x-tenant: users } }
    #|    responses:
    #|      - { template: true, json: { tags: "${body.name}" } }
  with_accounts(stubs, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let reply = client.call("/replies.Accounts/GetUser", headers=[
        ("x-tenant", "user"),
        ("x-user", "x"),
      ])
      inspect(
        reply.render(),
        content=(
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 13
          #|  grpc-message: template failed
          #|  smock-mock: accounts; via=default
          #|  date: <now>
          #|(end)
        ),
      )
      let _ = client.call("/replies.Accounts/GetUser", headers=[
        ("x-tenant", "users"),
      ])
      let (_, page) = smock.journal()
      inspect(
        answers(page),
        content=(
          #|"user" 200 "INTERNAL" x-tenant=user templateError={"at":"/response/json/userId","message":"must be an integer from -9223372036854775808 to 9223372036854775807: the field user_id of replies.User has the type int64"}
          #|"users" 200 "INTERNAL" x-tenant=users templateError={"at":"/responses/0/json/tags","message":"must be an array: the field tags of replies.User is repeated"}
        ),
      )
    })
  })
}

///|
async test "smock check reports a static reply that is not a message of the output type at the value at fault, and output types that reach types not served yet at the path" {
  let stubs =
    #|  - id: null-in-a-list
    #|    mock: accounts
    #|    request: { path: /replies.Accounts/GetUser }
    #|    response: { json: { tags: [a, null] } }
    #|  - id: two-members
    #|    mock: accounts
    #|    request: { path: /replies.Accounts/GetEverything }
    #|    response: { json: { word: a, number: 1 } }
    #|  - id: both-spellings
    #|    mock: accounts
    #|    request: { path: /replies.Accounts/GetUser }
    #|    responses: [{ json: { user_id: 1, userId: 2 } }]
    #|  - id: unknown-key
    #|    mock: accounts
    #|    request: { path: /replies.Accounts/GetUser }
    #|    response: { json: { userid: 1 } }
    #|  - id: out-of-range
    #|    mock: accounts
    #|    request: { path: /replies.Accounts/GetEverything }
    #|    response: { json: { nested: { recursive: { anInt32: 2147483648 } } } }
    #|  - id: now
    #|    mock: clock
    #|    request: { path: /unserved.Clock/Now }
    #|    response: { json: {} }
    #|  - id: schedule
    #|    mock: clock
    #|    request: { path: /unserved.Clock/Schedule }
    #|    response: { json: {} }
    #|  - id: stamp
    #|    mock: clock
    #|    request: { path: /unserved.Clock/Stamp }
    #|    response: { json: {} }
    #|  - id: templated
    #|    mock: accounts
    #|    request: { path: /replies.Accounts/GetUser }
    #|    response: { template: true, json: { userid: 1 } }
    #|  - id: fits
    #|    mock: accounts
    #|    request: { path: /replies.Accounts/GetUser }
    #|    response: { json: { userId: "1", tags: null } }
  with_accounts(stubs, dir => {
    inspect(
      check([dir]),
      content=(
        #|status 1
        #|replies.yaml: /stubs/0/response/json/tags/1: cannot be null: it is an element of the repeated field tags of replies.User
        #|replies.yaml: /stubs/1/response/json/number: sets the oneof choice of replies.Everything, as "word" does: give one member of a oneof at most
        #|replies.yaml: /stubs/2/responses/0/json/userId: names the field user_id of replies.User, as "user_id" does: give a field once, by its proto name or its JSON name
        #|replies.yaml: /stubs/3/response/json/userid: is not a field of replies.User
        #|replies.yaml: /stubs/4/response/json/nested/recursive/anInt32: must be an integer from -2147483648 to 2147483647: the field an_int32 of replies.Everything has the type int32
        #|replies.yaml: /stubs/5/request/path: the output type unserved.TimeReply is not served yet: the field at of unserved.TimeReply has the type google.protobuf.Timestamp, and gRPC Stubs do not serve the well-known types yet
        #|replies.yaml: /stubs/6/request/path: the output type unserved.ScheduleReply is not served yet: the field start of unserved.ScheduleReply.Slot has the type google.protobuf.Timestamp, and gRPC Stubs do not serve the well-known types yet
        #|replies.yaml: /stubs/6/request/path: the output type unserved.ScheduleReply is not served yet: the field note of unserved.ScheduleReply.Slot has the type old.Note, which old.proto defines, a proto2 file, and gRPC Stubs serve only types of proto3 files so far
        #|replies.yaml: /stubs/7/request/path: the output type google.protobuf.Timestamp is not served yet: it is a well-known type, and gRPC Stubs do not serve the well-known types yet
        #|
      ),
    )
  })
}
