// Benchmark of the match index: `moon bench -p smock/smock/engine --release`.
//
// It looks up Stubs in a small and a large definition set, with and without
// the index. With the index, a lookup takes about as long with 10,000 Stubs
// as with 100; without it, the time grows with the number of Stubs.

///|
/// An engine with and without the match index, serving one Mock `m` with
/// `count` Stubs `GET /items/<i>`, a path-pattern Stub in the middle of
/// the matching order and a Stub without conditions last. Also returns the
/// requests the benchmark sends: 16 paths spread over the Stubs.
fn bench_set(count : Int) -> (Twins, Array[@engine.Request]) raise {
  let stubs = StringBuilder()
  for i in 0..<count {
    if i == count / 2 {
      stubs.write_string(
        (
          #|{ "id": "health", "mock": "m",
          #|  "request": { "path": { "pattern": "/health(/.*)?" } },
          #|  "response": { "status": 200 } },
        ),
      )
    }
    stubs.write_string(
      (
        $|{ "id": "item-\{i}", "mock": "m",
        $|  "request": { "method": "GET", "path": "/items/\{i}" },
        $|  "response": { "status": 200, "body": "item \{i}" } },
      ),
    )
  }
  stubs.write_string(
    (
      #|{ "id": "fallback", "mock": "m", "response": { "status": 404 } }
    ),
  )
  let twins = twins([
    ("m.json", "{ \"mocks\": [{ \"name\": \"m\" }], \"stubs\": [\{stubs}] }"),
  ])
  let requests = Array::makei(16, k => {
    let i = (count - 1) * k / 15
    @engine.Request::{
      meth: "GET",
      target: "/items/\{i}",
      headers: [("Host", "m.test"), ("Accept", "application/json")],
      body: b"",
    }
  })
  (twins, requests)
}

///|
test "match index: lookups with 100 and 10,000 Stubs" (b : @bench.T) {
  let rand = @random.Rand::chacha8(seed=b"smock-seam-1-fixed-seed-32-bytes")
  for count in [100, 10_000] {
    let (twins, requests) = bench_set(count)
    // Both engines answer every request from its own Stub.
    for request in requests {
      let outcome = twins.send(request)
      guard outcome.journal.stub is Some(id) &&
        id == "item-\{request.target[7:]}" else {
        fail("\{request.target} -> \{@debug.to_string(outcome.journal.stub)}")
      }
    }
    b.bench(name="indexed, \{count} Stubs", () => {
      for request in requests {
        b.keep(
          twins.indexed.handle(request, session=None, now=fixed_now, rand~),
        )
      }
    })
    b.bench(name="linear, \{count} Stubs", () => {
      for request in requests {
        b.keep(twins.linear.handle(request, session=None, now=fixed_now, rand~))
      }
    })
  }
}
