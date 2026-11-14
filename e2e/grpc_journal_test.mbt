// Seam 2 tests of gRPC calls in the Journal: each entry records the gRPC
// status the call got as `grpcStatus`, beside its HTTP status, 200 for a
// reply. Queries, verification and the unmatched list take gRPC calls by
// their Mock, `POST`, the method's path and their metadata as headers. The
// set is gRPC's helloworld.proto, and the messages are protoc-encoded
// fixtures (scripts/gen-protobuf-fixtures.sh). Every Admin API response is
// checked against the OpenAPI document (contract_test.mbt).

///|
/// The entries of `page`, a Journal page, one per line: the Stub, the HTTP
/// status and the gRPC status, each as JSON, `-` for a member the entry
/// does not have, then the `x-tenant` metadata the call sent, if any.
fn answers(page : Json) -> String raise {
  guard page is Object({ "entries": Array(entries), .. }) else {
    fail("not a Journal page: \{page.stringify()}")
  }
  let lines = []
  for entry in entries {
    guard entry is Object(members) else { fail("not an entry") }
    let shown = (name : String) => {
      members.get(name).map_or("-", value => value.stringify())
    }
    let mut tenant = ""
    if members.get("request") is Some(Object({ "headers": Array(headers), .. })) {
      for header in headers {
        if header
          is Object({ "name": String("x-tenant"), "value": String(value), .. }) {
          tenant = " x-tenant=\{value}"
        }
      }
    }
    lines.push(
      "\{shown("stub")} \{shown("status")} \{shown("grpcStatus")}\{tenant}",
    )
  }
  lines.join("\n")
}

///|
async test "a call's entry records grpcStatus OK beside its HTTP status 200, an unmatched call's INTERNAL, and queries, verification and the unmatched list take calls by Mock, POST, path and metadata" {
  let yaml =
    #|mocks:
    #|  - name: greeter
    #|    grpc: { descriptorSet: greeter.binpb }
    #|stubs:
    #|  - id: hello
    #|    mock: greeter
    #|    request: { path: /helloworld.Greeter/SayHello, headers: { x-tenant: acme } }
    #|    response: { json: { message: Hello Tom } }
  with_greeter_set([("greeter.yaml", yaml)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let acme = [("x-tenant", "acme")]
      let call = client.call("/helloworld.Greeter/SayHello", headers=acme)
      debug_inspect(call.trailers, content="Some([(\"grpc-status\", \"0\")])")
      let by_path = "{\"mock\":\"greeter\",\"method\":\"POST\",\"path\":\"/helloworld.Greeter/SayHello\"}"
      let (_, page) = smock.journal(query="{\"filter\":\{by_path}}")
      inspect(answers(page), content="\"hello\" 200 \"OK\" x-tenant=acme")
      inspect(
        smock.call(
          "POST",
          "/v1/journal/verify",
          body="{\"filter\":\{by_path},\"exactly\":1}",
        ),
        content=(
          #|200 {"ok":true,"count":1,"evicted":0,"reason":null,"warnings":[]}
        ),
      )
      // Two calls that no Stub matches: smock answers INTERNAL.
      for headers in [[], [("x-tenant", "other")]] {
        let reply = client.call("/helloworld.Greeter/SayHello", headers~)
        guard reply.head.contains(("grpc-status", "13")) else {
          fail("not INTERNAL: \{reply.render()}")
        }
      }
      let (_, page) = smock.journal(query="{\"filter\":\{by_path}}")
      inspect(
        answers(page),
        content=(
          #|"hello" 200 "OK" x-tenant=acme
          #|null 404 "INTERNAL"
          #|null 404 "INTERNAL" x-tenant=other
        ),
      )
      // Metadata filters as headers do.
      let (_, page) = smock.journal(
        query="{\"filter\":{\"headers\":{\"x-tenant\":\"acme\"}}}",
      )
      inspect(answers(page), content="\"hello\" 200 \"OK\" x-tenant=acme")
      inspect(
        smock.call(
          "POST",
          "/v1/journal/verify",
          body="{\"filter\":\{by_path},\"exactly\":3}",
        ),
        content=(
          #|200 {"ok":true,"count":3,"evicted":0,"reason":null,"warnings":[]}
        ),
      )
      let unmatched = smock.admin("GET", "/v1/journal/unmatched")
      inspect(
        answers(unmatched.json()),
        content=(
          #|null 404 "INTERNAL"
          #|null 404 "INTERNAL" x-tenant=other
        ),
      )
    })
  })
}
