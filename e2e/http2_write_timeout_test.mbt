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

///|
async test "h2c: a stream whose own window stays at zero for the write timeout while another stream completes is reset with CANCEL, alone: its entry is committed, and the connection goes on" {
  with_definitions(flow_definitions(), dir => {
    let stopped = with_smock(
      ["--dir", dir, "--port", "0", "--write-timeout-ms", "500"],
      smock => {
        let raw = smock.raw_h2(settings=false)
        defer raw.close()
        let out = []
        // Stream windows of 0, with the connection window open: both bodies
        // wait for their own windows.
        raw.send([
          Settings(params=[(@http2.settings_initial_window_size, 0)], ack=false),
          raw.get(1, "/item"),
          raw.get(3, "/item"),
          fence,
        ])
        let start = @async.now()
        out.push(raw.frames_until_ping_ack())
        // Stream 3's window widens a while later, and its body goes out,
        // while stream 1's stays at zero.
        @async.sleep(250)
        out.push("--- stream 3's window widened by 5")
        raw.send([WindowUpdate(stream_id=3, increment=5)])
        let frames = raw.frames_until(start, frame => frame is RstStream(..))
        out.append(frames.shown)
        out.push(
          "stream 1 reset after at least 500 ms: \{frames.end_ms >= 500}, within 2000 ms: \{frames.end_ms < 2000}",
        )
        out.push("--- stream 5 sent, and its window widened by 5")
        raw.send([raw.get(5, "/item"), WindowUpdate(stream_id=5, increment=5)])
        out.push(raw.frames_until_stream_ends(5))
        out.push("---")
        out.append(smock.journal_once(3, within=1000))
        inspect(
          out.join("\n"),
          content=(
            #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
            #|SETTINGS ACK
            #|HEADERS 1 END_HEADERS [:status: 200, date: <now>, content-length: 5]
            #|HEADERS 3 END_HEADERS [:status: 200, date: <now>, content-length: 5]
            #|--- stream 3's window widened by 5
            #|DATA 3 END_STREAM 5 octets
            #|RST_STREAM 1 CANCEL
            #|stream 1 reset after at least 500 ms: true, within 2000 ms: true
            #|--- stream 5 sent, and its window widened by 5
            #|HEADERS 5 END_HEADERS [:status: 200, date: <now>, content-length: 5]
            #|DATA 5 END_STREAM 5 octets
            #|---
            #|/item: stub "item", status 200
            #|/item: stub "item", status 200
            #|/item: stub "item", status 200
          ),
        )
      },
    )
    // Timeouts are not logged.
    inspect(log_entries(stopped.logs), content=startup_only_h2c)
  })
}

///|
/// Reads frames until DATA or RST_STREAM ends `stream`, or smock ends the
/// connection, and after each DATA frame on it that does not, waits
/// `pause_ms`, then sends `grant(n)`, a frame that widens a window, for the
/// `n`th time, counting from 1. Returns
/// the DATA and RST_STREAM frames of `stream`, as `render_frame` shows
/// them, and then `closed` if smock ended the connection.
async fn RawH2::granting(
  self : RawH2,
  stream : Int32,
  grant : (Int32) -> @http2.Frame,
  pause_ms~ : Int32,
) -> Array[String] {
  let out = []
  let mut granted = 0
  for ;; {
    guard self.read_frame() is Some(frame) else {
      out.push("closed")
      break
    }
    match frame {
      Data(stream_id~, end_stream~, ..) if stream_id == stream => {
        out.push(self.render_frame(frame))
        if end_stream {
          break
        }
        @async.sleep(pause_ms)
        granted += 1
        self.send([grant(granted)])
      }
      RstStream(stream_id~, ..) if stream_id == stream => {
        out.push(self.render_frame(frame))
        break
      }
      _ => ()
    }
  }
  out
}

///|
async test "h2c: a client that widens its windows slowly but steadily keeps its connection past the write timeout, by WINDOW_UPDATE on the stream or on the connection, or by SETTINGS that raise the initial window" {
  with_definitions(flow_definitions(), dir => {
    let _ = with_smock(
      ["--dir", dir, "--port", "0", "--write-timeout-ms", "500"],
      smock => {
        let out = []
        let raw = smock.raw_h2(settings=false)
        defer raw.close()
        // On the stream: a window of one octet for "hello", widened by one
        // octet every 200 ms, so that the body takes about 800 ms in all.
        raw.send([
          Settings(params=[(@http2.settings_initial_window_size, 1)], ack=false),
          raw.get(1, "/item"),
        ])
        let start = @async.now()
        out.append(
          raw.granting(
            1,
            _ => WindowUpdate(stream_id=1, increment=1),
            pause_ms=200,
          ),
        )
        out.push(
          "by WINDOW_UPDATE on the stream, longer than the write timeout: \{@async.now() - start > 500}",
        )
        // By SETTINGS: the initial window, still one octet, raised by one
        // octet every 200 ms.
        raw.send([raw.get(3, "/item")])
        let start = @async.now()
        out.append(
          raw.granting(
            3,
            n => {
              Settings(
                params=[(@http2.settings_initial_window_size, n + 1)],
                ack=false,
              )
            },
            pause_ms=200,
          ),
        )
        out.push(
          "by SETTINGS, longer than the write timeout: \{@async.now() - start > 500}",
        )
        // On the connection: wide stream windows, and a body nine octets
        // larger than the connection window, which widens by three octets
        // every 200 ms once it is used.
        let raw = smock.raw_h2(settings=false)
        defer raw.close()
        raw.send([
          Settings(
            params=[(@http2.settings_initial_window_size, 1_000_000)],
            ack=false,
          ),
          raw.get(1, "/medium"),
        ])
        let start = @async.now()
        let frames = raw.granting(
          1,
          _ => WindowUpdate(stream_id=0, increment=3),
          pause_ms=200,
        )
        // The first four frames take the connection window as it opened.
        for line in frames[4:] {
          out.push(line)
        }
        out.push(
          "by WINDOW_UPDATE on the connection, longer than the write timeout: \{@async.now() - start > 500}",
        )
        out.push("---")
        out.append(smock.journal_once(3, within=1000))
        inspect(
          out.join("\n"),
          content=(
            #|DATA 1 1 octets
            #|DATA 1 1 octets
            #|DATA 1 1 octets
            #|DATA 1 1 octets
            #|DATA 1 END_STREAM 1 octets
            #|by WINDOW_UPDATE on the stream, longer than the write timeout: true
            #|DATA 3 1 octets
            #|DATA 3 1 octets
            #|DATA 3 1 octets
            #|DATA 3 1 octets
            #|DATA 3 END_STREAM 1 octets
            #|by SETTINGS, longer than the write timeout: true
            #|DATA 1 3 octets
            #|DATA 1 3 octets
            #|DATA 1 END_STREAM 3 octets
            #|by WINDOW_UPDATE on the connection, longer than the write timeout: true
            #|---
            #|/item: stub "item", status 200
            #|/item: stub "item", status 200
            #|/medium: stub "medium", status 200
          ),
        )
      },
    )
  })
}
