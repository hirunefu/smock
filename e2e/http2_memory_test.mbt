// Seam 2 tests of the memory an HTTP/2 connection holds, over h2c and h2:
// while it is open, about what an HTTP/1.1 connection holds over the same
// transport, and once it has closed, nothing. A connection that kept its
// memory after it closed would make smock's RSS grow with every connection
// a client opens, until a memory limit kills it. The fields a client sends
// with every request are decoded once per connection, as over HTTP/1.1, so
// the Journal entries of its requests share them.

///|
/// Opens `count` HTTP/2 connections to smock with `open`, one after
/// another, and has each answer one request for `/small`. Closes each once
/// its response has come, or, with `hold`, keeps them all open and returns
/// them.
async fn connect_many(
  count : Int32,
  open : async () -> H2Client,
  hold~ : Bool = false,
) -> Array[H2Client] {
  let held = []
  for _ in 0..<count {
    let client = open()
    let response = client.request("GET", "/small", authority="localhost")
    if response.status != 200 {
      client.close()
      fail("a connection got \{response.brief()}")
    }
    if hold {
      held.push(client)
    } else {
      client.close()
    }
  }
  held
}

///|
/// What HTTP/2 connections added to smock's RSS
/// (`Smock::connection_memory`), in KiB per connection.
struct ConnectionMemory {
  /// What each added while it was open, having answered one request.
  open : Double
  /// What each added once it had closed.
  closed : Double
}

///|
/// `true` when `kib` is at most `bound`, else `false` with `kib` to one
/// decimal, so that a snapshot reads the same while a bound holds, and
/// shows what was measured once it breaks.
fn at_most(kib : Double, bound : Double) -> String {
  if kib <= bound {
    "true"
  } else {
    "false (\{(kib * 10.0).round() / 10.0} KiB)"
  }
}

///|
/// How long the tests wait for smock to end connections their clients
/// closed, before they read its RSS, in milliseconds.
let closing_wait_ms : Int32 = 300

///|
/// Measures what HTTP/2 connections that `open` opens add to smock's RSS.
/// While `held` connections are open, `held` more open, and each of those
/// gives `open`. Once all have closed, `cycled` connections open and close
/// one after another, then `cycled` more, and each of those gives `closed`.
/// Only the later connections of each part count: the first take the memory
/// smock holds and does not use, and for `closed`, the later ones then take
/// what the first freed, as on a server that has run a while.
async fn Smock::connection_memory(
  self : Smock,
  open : async () -> H2Client,
  held~ : Int32,
  cycled~ : Int32,
) -> ConnectionMemory {
  let clients = connect_many(held, open, hold=true)
  let first = resident_set(self.pid)
  let more = connect_many(held, open, hold=true)
  let with_open = resident_set(self.pid)
  for client in [..clients, ..more] {
    client.close()
  }
  let _ = connect_many(cycled, open)
  @async.sleep(closing_wait_ms)
  let warm = resident_set(self.pid)
  let _ = connect_many(cycled, open)
  @async.sleep(closing_wait_ms)
  let after = resident_set(self.pid)
  {
    open: (with_open - first) / 1024.0 / held.to_double(),
    closed: (after - warm) / 1024.0 / cycled.to_double(),
  }
}

///|
async test "h2c: an open connection costs smock at most 48 KiB, and a closed one nothing: 200 connections opened and closed one after another leave its RSS within 1 MiB" {
  with_definitions(output_definitions(), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let memory = smock.connection_memory(
        () => smock.h2c(),
        held=100,
        cycled=200,
      )
      inspect(
        [
          "open: at most 48 KiB each: \{at_most(memory.open, 48.0)}",
          "closed: at most 5 KiB each: \{at_most(memory.closed, 5.0)}",
        ].join("\n"),
        content=(
          #|open: at most 48 KiB each: true
          #|closed: at most 5 KiB each: true
        ),
      )
    })
  })
}

///|
async test "h2: an open connection costs smock at most 128 KiB, its TLS included, and a closed one nothing: 200 connections opened and closed one after another leave its RSS within 1 MiB" {
  with_definitions(output_definitions(), dir => {
    with_certificates(certs => {
      let _ = with_smock(["--dir", dir, "--port", "0", ..certs.args()], smock => {
        let memory = smock.connection_memory(
          () => smock.h2(),
          held=100,
          cycled=200,
        )
        inspect(
          [
            "open: at most 128 KiB each: \{at_most(memory.open, 128.0)}",
            "closed: at most 5 KiB each: \{at_most(memory.closed, 5.0)}",
          ].join("\n"),
          content=(
            #|open: at most 128 KiB each: true
            #|closed: at most 5 KiB each: true
          ),
        )
      })
    })
  })
}

///|
/// The fields of a request as a browser or an SDK sends them, about 700
/// octets: the same with every request.
let usual_fields : Array[(String, String)] = [
  ("user-agent", "storefront/3.8.1 okhttp/4.12.0"),
  ("accept", "application/json"),
  ("accept-encoding", "gzip, deflate"),
  ("accept-language", "en-GB,en;q=0.9"),
  (
    "authorization", "Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJzdG9yZWZyb250IiwiYXVkIjoiY2F0YWxvZyIsImV4cCI6MTkyNDk5MjAwMH0.bm90LWEtcmVhbC1zaWduYXR1cmUtYmVuY2htYXJrLW9ubHk",
  ),
  ("traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"),
  ("tracestate", "congo=t61rcWkgMzE"),
  ("baggage", "tenant=acme-eu,smock-session=memory,deployment=perf"),
  ("x-request-id", "0f8fad5b-d9cb-469f-a165-70867728950e"),
]

///|
/// Sends `count` requests for `/small` with `usual_fields` on `client`, one
/// after another.
async fn H2Client::ask_usual(self : H2Client, count : Int32) -> Unit {
  for _ in 0..<count {
    let response = self.request(
      "GET",
      "/small",
      authority="localhost",
      headers=usual_fields,
    )
    if response.status != 200 {
      fail("a request got \{response.brief()}")
    }
  }
}

///|
async test "h2c: the Journal entries of requests that send the same fields again share them: 2,000 requests with about 700 octets of fields add at most 1 KiB each to smock's RSS" {
  with_definitions(output_definitions(), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      client.ask_usual(500)
      let warm = resident_set(smock.pid)
      client.ask_usual(2000)
      let after = resident_set(smock.pid)
      let each = (after - warm) / 1024.0 / 2000.0
      inspect(
        "at most 1 KiB each: \{at_most(each, 1.0)}",
        content="at most 1 KiB each: true",
      )
    })
  })
}

///|
test "a memory bound kept reads true, and a broken one shows what was measured" {
  inspect(
    [at_most(4.96, 5.0), at_most(5.0, 5.0), at_most(129.38, 128.0)].join("\n"),
    content=(
      #|true
      #|true
      #|false (129.4 KiB)
    ),
  )
}
