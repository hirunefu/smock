// Seam 2 tests of the Descriptor set that serves a gRPC call, over h2c:
// `:authority` chooses the call's Mock, and the call is decoded and
// answered with that Mock's own set, the Default Mock's for a Host that no
// Mock lists. The call's Mock and set are looked up again when its request
// ends, and the decoding, the engine and the encoding then use one version
// of the definition set, so a reload never makes a call decoded with one
// version of a set and answered with another. The sets are versions 1 and
// 2 of gRPC's helloworld.proto, version 2 with a field `version` in each
// message, and the messages are protoc-encoded fixtures
// (scripts/gen-protobuf-fixtures.sh).

///|
/// HelloRequest `{name: "Tom", version: 2}` of version 2 of
/// helloworld.proto, which version 1 decodes as `{name: "Tom"}`.
let hello_v2_request_path : String = "fixtures/protobuf/helloworld-v2/hello-request.binpb"

///|
/// The framed HelloRequest of version 2.
async fn hello_v2_request() -> Bytes {
  framed(@fs.read_file(hello_v2_request_path).binary())
}

///|
/// The entries of the Journal, one per line: the Mock, the Stub, the gRPC
/// status and the body's data and size, each as JSON.
async fn answered_by(smock : Smock) -> String {
  let (_, journal) = smock.journal()
  guard journal is Object({ "entries": Array(entries), .. }) else {
    fail("no entries: \{journal.stringify()}")
  }
  let out = []
  for entry in entries {
    guard entry
      is Object(
        {
          "mock": mock,
          "stub": stub,
          "grpcStatus": grpc_status,
          "request": Object(
            { "body": Object({ "data": data, "size": size, .. }), .. }
          ),
          ..
        }
      ) else {
      fail("not an entry: \{entry.stringify()}")
    }
    out.push(
      "\{mock.stringify()} \{stub.stringify()} \{grpc_status.stringify()} \{data.stringify()}/\{size.stringify()}",
    )
  }
  out.join("\n")
}

///|
/// Two Mocks whose sets are versions 1 and 2 of helloworld.proto, each with
/// a Stub on SayHello: `greeter-v1`, the Default Mock, and `greeter-v2`,
/// for the Host `v2.greeter.svc`, whose Stub requires the field `version`
/// that only its set has.
let two_versions : String =
  #|mocks:
  #|  - name: greeter-v1
  #|    default: true
  #|    grpc: { descriptorSet: v1/greeter.binpb }
  #|  - name: greeter-v2
  #|    hosts: [v2.greeter.svc]
  #|    grpc: { descriptorSet: v2/greeter.binpb }
  #|stubs:
  #|  - id: hello-v1
  #|    mock: greeter-v1
  #|    request: { path: /helloworld.Greeter/SayHello }
  #|    response: { json: { message: Hello from v1 } }
  #|  - id: hello-v2
  #|    mock: greeter-v2
  #|    request: { path: /helloworld.Greeter/SayHello, body: { json: { version: 2 } } }
  #|    response: { json: { message: Hello from v2, version: 2 } }

///|
async test "two Mocks whose sets define one package in two versions each decode and answer a call with their own set, chosen by :authority, and the Default Mock answers other Hosts with its own" {
  with_definitions([("greeter.yaml", two_versions)], dir => {
    @fs.mkdir("\{dir}/files")
    @fs.mkdir("\{dir}/files/v1")
    @fs.mkdir("\{dir}/files/v2")
    write_bytes(
      dir,
      "files/v1/greeter.binpb",
      @fs.read_file(greeter_set_path).binary(),
    )
    write_bytes(
      dir,
      "files/v2/greeter.binpb",
      @fs.read_file(greeter_v2_set_path).binary(),
    )
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let out = []
      for authority in ["v2.greeter.svc", "v1.greeter.svc", "other.svc"] {
        out.push("\{authority}:")
        out.push(
          client
          .call(
            "/helloworld.Greeter/SayHello",
            authority~,
            body=hello_v2_request(),
          )
          .render(),
        )
      }
      out.push("Journal:")
      out.push(answered_by(smock))
      inspect(
        out.join("\n"),
        content=(
          #|v2.greeter.svc:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  date: <now>
          #|DATA 00000000110a0d48656c6c6f2066726f6d2076321002
          #|TRAILERS
          #|  grpc-status: 0
          #|(end)
          #|v1.greeter.svc:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  smock-mock: greeter-v1; via=default
          #|  date: <now>
          #|DATA 000000000f0a0d48656c6c6f2066726f6d207631
          #|TRAILERS
          #|  grpc-status: 0
          #|(end)
          #|other.svc:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  smock-mock: greeter-v1; via=default
          #|  date: <now>
          #|DATA 000000000f0a0d48656c6c6f2066726f6d207631
          #|TRAILERS
          #|  grpc-status: 0
          #|(end)
          #|Journal:
          #|"greeter-v2" "hello-v2" "OK" "{\"name\":\"Tom\",\"version\":2}"/12
          #|"greeter-v1" "hello-v1" "OK" "{\"name\":\"Tom\"}"/12
          #|"greeter-v1" "hello-v1" "OK" "{\"name\":\"Tom\"}"/12
        ),
      )
    })
  })
}

///|
/// The Definition file of the Default Mock `greeter`, whose set is
/// `greeter.binpb`, with one Stub on SayHello for `version`, 1 or 2, of
/// helloworld.proto: `hello-v1` answers every call; `hello-v2` answers a
/// call whose message has the field `version`, which only version 2's set
/// decodes, and replies with it, which only version 2's set encodes, so
/// version 1's set refuses this file.
fn versioned_greeter(version : Int32) -> String {
  let stub = if version == 1 {
    (
      #|  - id: hello-v1
      #|    mock: greeter
      #|    request: { path: /helloworld.Greeter/SayHello }
      #|    response: { json: { message: Hello from v1 } }
    )
  } else {
    (
      #|  - id: hello-v2
      #|    mock: greeter
      #|    request: { path: /helloworld.Greeter/SayHello, body: { json: { version: 2 } } }
      #|    response: { json: { message: Hello from v2, version: 2 } }
    )
  }
  (
    #|mocks:
    #|  - name: greeter
    #|    grpc: { descriptorSet: greeter.binpb }
    #|stubs:
    #|
  ) +
  stub
}

///|
/// Waits until a reload after the status `before` swaps in a new
/// definition set, through at most two reloads that do not, and returns
/// the status then.
async fn Smock::swapped(
  self : Smock,
  before : Map[String, Json],
) -> Map[String, Json] {
  let mut last = before
  for _ in 0..<3 {
    let status = self.reloaded(last)
    if status.get("lastReload")
      is Some(Object({ "result": String("swapped"), .. })) {
      return status
    }
    last = status
  }
  fail("no reload swapped: \{last_reload(last)}")
}

///|
/// Moves the definitions in `dir` to `version`, 1 or 2, of helloworld.proto
/// and its Stub (`versioned_greeter`), and waits until a reload swaps them
/// in. The file version 1's set refuses is written while version 1's set is
/// there, so that no reload serves a set with the Stub of the other
/// version: to version 2, the Definition file first, then the set; to
/// version 1, the set first.
async fn Smock::switch_to(self : Smock, dir : String, version : Int32) -> Unit {
  let before = self.status()
  let set = if version == 1 { greeter_set_path } else { greeter_v2_set_path }
  let write_file = () => {
    @fs.write_file("\{dir}/greeter.yaml", versioned_greeter(version))
  }
  let write_set = () => {
    write_bytes(dir, "files/greeter.binpb", @fs.read_file(set).binary())
  }
  if version == 1 {
    write_set()
    write_file()
  } else {
    write_file()
    write_set()
  }
  let _ = self.swapped(before)
}

///|
/// The metadata of a gRPC call, as gRPC clients send it.
let call_metadata : Array[(String, String)] = [
  ("content-type", "application/grpc"),
  ("te", "trailers"),
]

///|
async test "a reload between a call's HEADERS and the end of its request: the call is decoded and answered with the set served when the request ends, or gets the answer its HEADERS would get then" {
  with_definitions([("greeter.yaml", versioned_greeter(1))], dir => {
    @fs.mkdir("\{dir}/files")
    write_bytes(
      dir,
      "files/greeter.binpb",
      @fs.read_file(greeter_set_path).binary(),
    )
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let out = []
      let first = client.send(
        "POST",
        "/helloworld.Greeter/SayHello",
        authority="localhost",
        headers=call_metadata,
        end=false,
      )
      smock.switch_to(dir, 2)
      client.send_data(first, hello_v2_request())
      out.push("HEADERS under version 1, the message under version 2:")
      out.push(client.reply(first).render())
      let second = client.send(
        "POST",
        "/helloworld.Greeter/SayHello",
        authority="localhost",
        headers=call_metadata,
        end=false,
      )
      let before = smock.status()
      @fs.write_file(
        "\{dir}/greeter.yaml",
        (
          #|mocks:
          #|  - name: greeter
        ),
      )
      let _ = smock.swapped(before)
      client.send_data(second, hello_v2_request())
      out.push("HEADERS under version 2, the message once the Mock has no set:")
      out.push(client.reply(second).render())
      out.push("Journal:")
      out.push(answered_by(smock))
      inspect(
        out.join("\n"),
        content=(
          #|HEADERS under version 1, the message under version 2:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|DATA 00000000110a0d48656c6c6f2066726f6d2076321002
          #|TRAILERS
          #|  grpc-status: 0
          #|(end)
          #|HEADERS under version 2, the message once the Mock has no set:
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 12
          #|  grpc-message: the Mock has no Descriptor set
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|(end)
          #|Journal:
          #|"greeter" "hello-v2" "OK" "{\"name\":\"Tom\",\"version\":2}"/12
          #|"greeter" null "UNIMPLEMENTED" ""/12
        ),
      )
    })
  })
}

///|
async test "a set swapped by reloads while calls run: each call is decoded and answered with one version of it" {
  with_definitions([("greeter.yaml", versioned_greeter(1))], dir => {
    @fs.mkdir("\{dir}/files")
    write_bytes(
      dir,
      "files/greeter.binpb",
      @fs.read_file(greeter_set_path).binary(),
    )
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      // Each answer as the client got it and as the Journal recorded it:
      // the Stub, the gRPC status, the decoded body, and the reply's
      // message; with how many calls got it.
      let seen : Map[String, Int32] = Map([])
      let stop = Ref(false)
      @async.with_task_group(group => {
        let calls = group.spawn(() => {
          let mut n = 0
          while !stop.val {
            n += 1
            let reply = client.call(
              "/helloworld.Greeter/SayHello",
              headers=[("x-call", n.to_string())],
              body=hello_v2_request(),
            )
            let (_, page) = smock.journal(
              query="{\"filter\":{\"headers\":{\"x-call\":\"\{n}\"}}}",
            )
            guard page
              is Object(
                {
                  "entries": [
                    Object(
                      {
                        "stub": stub,
                        "grpcStatus": grpc_status,
                        "request": Object(
                          { "body": Object({ "data": data, .. }), .. }
                        ),
                        ..
                      }
                    ),
                  ],
                  ..
                }
              ) else {
              fail("call \{n} is not journaled once: \{page.stringify()}")
            }
            let message = reply.data.map(hex).join(" ")
            let line = "\{stub.stringify()} \{grpc_status.stringify()} \{data.stringify()} DATA \{message}"
            seen[line] = seen.get(line).unwrap_or(0) + 1
            @async.sleep(20)
          }
          n
        })
        for version in [2, 1, 2, 1] {
          smock.switch_to(dir, version)
        }
        stop.val = true
        let _ = calls.wait()
      })
      let lines = seen.keys().collect()
      lines.sort()
      inspect(
        lines.join("\n"),
        content=(
          #|"hello-v1" "OK" "{\"name\":\"Tom\"}" DATA 000000000f0a0d48656c6c6f2066726f6d207631
          #|"hello-v2" "OK" "{\"name\":\"Tom\",\"version\":2}" DATA 00000000110a0d48656c6c6f2066726f6d2076321002
        ),
      )
    })
  })
}
