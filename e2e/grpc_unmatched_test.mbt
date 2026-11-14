// Seam 2 tests of unmatched gRPC calls over h2c: a call that no gRPC Stub
// matches gets Trailers-Only UNIMPLEMENTED with the fixed message `no Stub
// matched`, and its Near miss in a `smock-near-miss` trailer, in the form
// of the HTTP `Smock-Near-Miss` header. The Journal keeps the full Near
// miss, the unmatched list and the unmatched counter include the call, and
// the Mock's `noMatch` never reaches it. The set is gRPC's helloworld.proto,
// and the messages are protoc-encoded fixtures
// (scripts/gen-protobuf-fixtures.sh).

///|
/// The Mock `greeter`, the Default Mock, with the set, and one gRPC Stub on
/// SayHello that requires the metadata `x-tenant: acme`: the ticket's
/// example.
let tenant_example : String =
  #|mocks:
  #|  - name: greeter
  #|    grpc: { descriptorSet: greeter.binpb }
  #|stubs:
  #|  - id: hello
  #|    mock: greeter
  #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-tenant: acme } }
  #|    response: { json: { message: Hello Tom } }

///|
async test "a call without the metadata a Stub requires gets Trailers-Only UNIMPLEMENTED no Stub matched, with smock-near-miss naming the Stub and the condition, and is journaled and counted as unmatched" {
  with_greeter_set([("greeter.yaml", tenant_example)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      inspect(
        client.call("/helloworld.Greeter/SayHello").render(),
        content=(
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 12
          #|  grpc-message: no Stub matched
          #|  smock-mock: greeter; via=default
          #|  smock-near-miss: hello; failed=header:x-tenant
          #|  date: <now>
          #|(end)
        ),
      )
      inspect(
        smock.last_entry(),
        content=(
          #|{"seq":1,"receivedAt":"<time>","durationMs":"<ms>","session":null,"host":"localhost","mock":"greeter","viaDefault":true,"digest":"<digest>","request":{"method":"POST","target":"/helloworld.Greeter/SayHello","version":"HTTP/2","headers":[{"name":"content-type","value":"application/grpc"},{"name":"te","value":"trailers"}],"body":{"encoding":"utf-8","data":"{\"name\":\"Tom\"}","size":10,"truncated":false}},"stub":null,"stubSource":null,"scenario":null,"responseIndex":null,"crud":null,"variablesWritten":[],"dataWritten":[],"dataError":null,"nearMiss":{"stub":"hello","stubSource":"file","failed":[{"condition":"header:x-tenant","expected":"acme","actual":[]}]},"status":200,"grpcStatus":"UNIMPLEMENTED","fault":null,"templateError":null}
        ),
      )
      let unmatched = smock.admin("GET", "/v1/journal/unmatched")
      guard unmatched.json()
        is Object(
          {
            "entries": [Object({ "seq": seq, "grpcStatus": grpc_status, .. })],
            ..
          }
        ) else {
        fail("not one unmatched entry: \{unmatched.json().stringify()}")
      }
      inspect(
        "\{seq.stringify()} \{grpc_status.stringify()}",
        content="1 \"UNIMPLEMENTED\"",
      )
      inspect(
        smock.metric("smock_unmatched_requests_total"),
        content=(
          #|smock_unmatched_requests_total{mock="greeter"} 1
        ),
      )
      // The same call with the metadata is served.
      debug_inspect(
        client.call("/helloworld.Greeter/SayHello", headers=[
          ("x-tenant", "acme"),
        ]).trailers,
        content="Some([(\"grpc-status\", \"0\")])",
      )
    })
  })
}

///|
async test "a Mock's noMatch status and headers never reach an unmatched call, and still answer an HTTP request to the same path" {
  let yaml =
    #|mocks:
    #|  - name: greeter
    #|    grpc: { descriptorSet: greeter.binpb }
    #|    noMatch: { status: 501, headers: { X-Missing: "yes" } }
    #|stubs:
    #|  - id: hello
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-tenant: acme } }
    #|    response: { json: { message: Hello Tom } }
  with_greeter_set([("greeter.yaml", yaml)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      inspect(
        client.call("/helloworld.Greeter/SayHello").render(),
        content=(
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 12
          #|  grpc-message: no Stub matched
          #|  smock-mock: greeter; via=default
          #|  smock-near-miss: hello; failed=header:x-tenant
          #|  date: <now>
          #|(end)
        ),
      )
      // An HTTP request never matches a gRPC Stub, so its Near miss names
      // none, and it gets the Mock's noMatch.
      inspect(
        smock.send("POST", "/helloworld.Greeter/SayHello"),
        content=(
          #|HTTP/1.1 501 Not Implemented
          #|Content-Type: application/json
          #|X-Missing: yes
          #|Smock-Mock: greeter; via=default
          #|Date: <now>
          #|Content-Length: 27
          #|
          #|{"error":"no Stub matched"}
        ),
      )
      let (_, page) = smock.journal()
      inspect(
        answers(page),
        content=(
          #|null 200 "UNIMPLEMENTED"
          #|null 501 -
        ),
      )
    })
  })
}

///|
async test "an unmatched call to a Mock without gRPC Stubs has no Near miss, though an HTTP Stub takes its path, and its answer no smock-near-miss trailer" {
  let yaml =
    #|mocks:
    #|  - name: greeter
    #|    grpc: { descriptorSet: greeter.binpb }
    #|stubs:
    #|  - id: greeter-paths
    #|    mock: greeter
    #|    request: { method: POST, path: { pattern: "/helloworld\\.Greeter/.*" } }
    #|    response: { status: 200, body: Hello }
  with_greeter_set([("greeter.yaml", yaml)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      inspect(
        client.call("/helloworld.Greeter/SayHello").render(),
        content=(
          #|HEADERS
          #|  :status: 200
          #|  content-type: application/grpc
          #|  grpc-status: 12
          #|  grpc-message: no Stub matched
          #|  smock-mock: greeter; via=default
          #|  date: <now>
          #|(end)
        ),
      )
      let unmatched = smock.admin("GET", "/v1/journal/unmatched")
      guard unmatched.json()
        is Object({ "entries": [Object({ "nearMiss": near_miss, .. })], .. }) else {
        fail("not one unmatched entry: \{unmatched.json().stringify()}")
      }
      inspect(near_miss.stringify(), content="null")
    })
  })
}
