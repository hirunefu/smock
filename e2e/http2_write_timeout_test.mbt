// Seam 2 tests of the write timeout over h2c, under flow control: it runs
// while a response body waits for the client to widen the connection
// window, and closes the connection past it, with no GOAWAY; a stream whose
// own window stays at zero is reset with CANCEL, alone. A window that
// widens, however slowly, restarts it, and smock's own waits never count.

///|
async test "h2c: a client that keeps the connection window at zero is closed at the write timeout, with no GOAWAY and no RST_STREAM, unlogged, and a new connection is served" {
  with_definitions(flow_definitions(), dir => {
    let stopped = with_smock(
      ["--dir", dir, "--port", "0", "--write-timeout-ms", "500"],
      smock => {
        let raw = smock.raw_h2(settings=false)
        defer raw.close()
        // Wide stream windows, so that only the connection window of 65,535
        // octets holds the body back.
        raw.send([
          Settings(
            params=[(@http2.settings_initial_window_size, 1_000_000)],
            ack=false,
          ),
          raw.get(1, "/big"),
        ])
        let start = @async.now()
        let frames = raw.frames_until(start, _ => false)
        let client = smock.h2c()
        defer client.close()
        let after = client.request("GET", "/item", authority="localhost")
        inspect(
          [
            ..frames.shown,
            "ended by \{frames.how}, after at least 500 ms: \{frames.end_ms >= 500}, within 2000 ms: \{frames.end_ms < 2000}",
            "a new connection: \{after.brief()}",
            "Journal:",
            ..smock.journal_once(2, within=1000),
          ].join("\n"),
          content=(
            #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
            #|SETTINGS ACK
            #|HEADERS 1 END_HEADERS [:status: 200, accept-ranges: bytes, date: <now>, content-length: 150000]
            #|DATA 1 16384 octets
            #|DATA 1 16384 octets
            #|DATA 1 16384 octets
            #|DATA 1 16383 octets
            #|ended by a FIN, after at least 500 ms: true, within 2000 ms: true
            #|a new connection: 200 hello (end)
            #|Journal:
            #|/big: stub "big", status 200
            #|/item: stub "item", status 200
          ),
        )
      },
    )
    // Timeouts are not logged.
    inspect(log_entries(stopped.logs), content=startup_only_h2c)
  })
}
