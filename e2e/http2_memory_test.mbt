// Seam 2 tests of the memory an HTTP/2 connection holds, over h2c and h2:
// while it is open, about what an HTTP/1.1 connection holds over the same
// transport, and once it has closed, nothing. A connection that kept its
// memory after it closed would make smock's RSS grow with every connection
// a client opens, until a memory limit kills it.

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
          "open: at most 48 KiB each: \{memory.open <= 48.0}",
          "closed: at most 5 KiB each: \{memory.closed <= 5.0}",
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
            "open: at most 128 KiB each: \{memory.open <= 128.0}",
            "closed: at most 5 KiB each: \{memory.closed <= 5.0}",
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
