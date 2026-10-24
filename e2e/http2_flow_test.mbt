// Seam 2 tests of flow control over h2c: a response body larger than the
// client's windows goes out as the windows allow, from a task of its own (a
// slow write), which resumes when the client widens a window, while the
// connection's other streams go on.

///|
/// A body of `lines` lines, each a number of seven digits and a newline,
/// counting from 0, so that a part sent twice, lost or out of order shows.
fn numbered(lines : Int32) -> String {
  let out = StringBuilder()
  for i in 0..<lines {
    let digits = i.to_string()
    out.write_string("0".repeat(7 - digits.length()))
    out.write_string(digits)
    out.write_char('\n')
  }
  out.to_string()
}

///|
/// The body of `GET /big`: 150,000 octets, more than both of the windows a
/// client starts with (65,535 octets each).
let big_body : String = numbered(18_750)

///|
/// The body of `GET /medium`: 65,544 octets, nine more than the connection
/// window a client starts with.
let medium_body : String = numbered(8193)

///|
/// Mock `m`, for `localhost`, with Stubs that answer `GET /big` with
/// `big_body`, `GET /medium` with `medium_body`, `GET /item` with a short
/// body, and `GET /slow-big` with `big_body` after a delay of 300 ms.
fn flow_definitions() -> Array[(String, String)] {
  [
    (
      "m.json",
      (
        #|{ "mocks": [{ "name": "m", "hosts": ["localhost"] }],
        #|  "stubs": [
        #|    { "id": "big", "mock": "m", "request": { "path": "/big" },
        #|      "response": { "status": 200, "bodyFile": "big.txt" } },
        #|    { "id": "medium", "mock": "m", "request": { "path": "/medium" },
        #|      "response": { "status": 200, "bodyFile": "medium.txt" } },
        #|    { "id": "item", "mock": "m", "request": { "path": "/item" },
        #|      "response": { "status": 200, "body": "hello" } },
        #|    { "id": "slow-big", "mock": "m", "request": { "path": "/slow-big" },
        #|      "response": { "status": 200, "bodyFile": "big.txt" },
        #|      "fault": { "delay": { "fixed": 300 } } } ] }
      ),
    ),
    ("files/big.txt", big_body),
    ("files/medium.txt", medium_body),
  ]
}

///|
/// A response as a test shows it, with its body replaced by whether it is
/// `expected`, and its length.
fn H2Response::checked(self : H2Response, expected : String) -> String {
  let body = @utf8.decode_lossy(self.body)
  let shown : H2Response = { ..self, body: b"", }
  let gap = if self.ended == "end" { "" } else { "\n" }
  "\{shown.render()}\{gap}body: \{self.body.length()} octets, as the Stub gives it: \{body == expected}"
}

///|
async test "h2c: a response body larger than both of the client's windows goes out within them, as the client widens them, and arrives in full" {
  with_definitions(flow_definitions(), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let response = client.request("GET", "/big", authority="localhost")
      let entries = smock.journal_once(1, within=1000)
      inspect(
        [response.checked(big_body), ..entries].join("\n"),
        content=(
          #|200
          #|accept-ranges: bytes
          #|date: <now>
          #|content-length: 150000
          #|
          #|body: 150000 octets, as the Stub gives it: true
          #|/big: stub "big", status 200
        ),
      )
    })
  })
}

///|
/// Reads frames until `stop` holds for one, or smock ends the connection,
/// and shows each as `render_frame` does, one per line, except that DATA
/// frames in a row on one stream show as one line: how many there are,
/// their octets, and whether the last ends the stream.
async fn RawH2::runs_until(
  self : RawH2,
  stop : (@http2.Frame) -> Bool,
) -> String {
  let out = []
  // The stream, frame count and octets of the DATA frames in a row so far.
  let mut run = (0, 0, 0)
  let flush = (end : Bool) => {
    let (stream, frames, octets) = run
    if frames > 0 {
      let ended = if end { " END_STREAM" } else { "" }
      out.push("DATA \{stream}\{ended}: \{frames} frames, \{octets} octets")
    }
    run = (0, 0, 0)
  }
  for ;; {
    guard self.read_frame() is Some(frame) else {
      flush(false)
      out.push("closed")
      break
    }
    match frame {
      Data(stream_id~, data~, end_stream~, ..) => {
        if run.0 != stream_id {
          flush(false)
        }
        run = (stream_id, run.1 + 1, run.2 + data.length())
        if end_stream {
          flush(true)
        }
      }
      _ => {
        flush(false)
        out.push(self.render_frame(frame))
      }
    }
    if stop(frame) {
      flush(false)
      break
    }
  }
  out.join("\n")
}

///|
/// Whether `frame` ends `stream`: DATA or HEADERS with END_STREAM, or
/// RST_STREAM.
fn ends_stream(frame : @http2.Frame, stream : Int32) -> Bool {
  match frame {
    Data(stream_id~, end_stream=true, ..)
    | Headers(stream_id~, end_stream=true, ..)
    | RstStream(stream_id~, ..) => stream_id == stream
    _ => false
  }
}

///|
/// A PING from the client, whose acknowledgement shows where smock's
/// answers to the frames before it end.
let fence : @http2.Frame = Ping(
  payload=b"\x00\x00\x00\x00\x00\x00\x00\x01",
  ack=false,
)

///|
async test "h2c: a client SETTINGS frame that raises the initial window resumes a stream waiting for window, as h2spec's http2/6.9.2/1 checks" {
  with_definitions(flow_definitions(), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2(settings=false)
      defer raw.close()
      let out = []
      // A window of 0: the HEADERS go out, and the body waits.
      raw.send([
        Settings(params=[(@http2.settings_initial_window_size, 0)], ack=false),
        raw.get(1, "/item"),
        fence,
      ])
      out.push(raw.frames_until_ping_ack())
      out.push("--- the initial window raised to 3")
      raw.send([
        Settings(params=[(@http2.settings_initial_window_size, 3)], ack=false),
      ])
      out.push(raw.runs_until(frame => frame is Data(..)))
      out.push("--- the initial window raised to 100")
      raw.send([
        Settings(params=[(@http2.settings_initial_window_size, 100)], ack=false),
      ])
      out.push(raw.runs_until(frame => ends_stream(frame, 1)))
      inspect(
        out.join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 1 END_HEADERS [:status: 200, date: <now>, content-length: 5]
          #|--- the initial window raised to 3
          #|SETTINGS ACK
          #|DATA 1: 1 frames, 3 octets
          #|--- the initial window raised to 100
          #|SETTINGS ACK
          #|DATA 1 END_STREAM: 1 frames, 2 octets
        ),
      )
    })
  })
}

///|
async test "h2c: a client that grants window one octet at a time, on the stream or on the connection, gets one small DATA frame for each grant, and its whole response" {
  with_definitions(flow_definitions(), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2(settings=false)
      defer raw.close()
      let out = []
      // On the stream: a window of 1 for "hello".
      raw.send([
        Settings(params=[(@http2.settings_initial_window_size, 1)], ack=false),
        raw.get(1, "/item"),
      ])
      let body = @buffer.Buffer()
      let mut frames = 0
      while raw.read_frame() is Some(frame) {
        if frame is Data(data~, end_stream~, ..) {
          frames += 1
          body.write_bytes(data)
          out.push(raw.render_frame(frame))
          if end_stream {
            break
          }
          raw.send([WindowUpdate(stream_id=1, increment=1)])
        }
      }
      out.push(
        "on the stream: \{frames} DATA frames, body \{@utf8.decode_lossy(body.to_bytes())}",
      )
      // On the connection: the stream's window wide open, and a body nine
      // octets larger than the connection window.
      let raw = smock.raw_h2(settings=false)
      defer raw.close()
      raw.send([
        Settings(
          params=[(@http2.settings_initial_window_size, 0x7fffffff)],
          ack=false,
        ),
        raw.get(1, "/medium"),
      ])
      let body = @buffer.Buffer()
      let granted = []
      while raw.read_frame() is Some(frame) {
        if frame is Data(data~, end_stream~, ..) {
          body.write_bytes(data)
          if body.length() > 65535 {
            granted.push(raw.render_frame(frame))
          }
          if end_stream {
            break
          }
          if body.length() >= 65535 {
            raw.send([WindowUpdate(stream_id=0, increment=1)])
          }
        }
      }
      out.push("---")
      out.append(granted)
      out.push(
        "on the connection: \{granted.length()} DATA frames after the first 65535 octets, body as the Stub gives it: \{@utf8.decode_lossy(body.to_bytes()) == medium_body}",
      )
      inspect(
        out.join("\n"),
        content=(
          #|DATA 1 1 octets
          #|DATA 1 1 octets
          #|DATA 1 1 octets
          #|DATA 1 1 octets
          #|DATA 1 END_STREAM 1 octets
          #|on the stream: 5 DATA frames, body hello
          #|---
          #|DATA 1 1 octets
          #|DATA 1 1 octets
          #|DATA 1 1 octets
          #|DATA 1 1 octets
          #|DATA 1 1 octets
          #|DATA 1 1 octets
          #|DATA 1 1 octets
          #|DATA 1 1 octets
          #|DATA 1 END_STREAM 1 octets
          #|on the connection: 9 DATA frames after the first 65535 octets, body as the Stub gives it: true
        ),
      )
    })
  })
}

///|
async test "h2c: two bodies larger than the windows, on one connection, both arrive in full" {
  with_definitions(flow_definitions(), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = smock.h2c()
      defer client.close()
      let first = client.send("GET", "/big", authority="localhost")
      let second = client.send("GET", "/big", authority="localhost")
      let second_response = client.response(second)
      let first_response = client.response(first)
      inspect(
        [
          first_response.checked(big_body),
          "---",
          second_response.checked(big_body),
          "---",
          ..smock.journal_once(2, within=1000),
        ].join("\n"),
        content=(
          #|200
          #|accept-ranges: bytes
          #|date: <now>
          #|content-length: 150000
          #|
          #|body: 150000 octets, as the Stub gives it: true
          #|---
          #|200
          #|accept-ranges: bytes
          #|date: <now>
          #|content-length: 150000
          #|
          #|body: 150000 octets, as the Stub gives it: true
          #|---
          #|/big: stub "big", status 200
          #|/big: stub "big", status 200
        ),
      )
    })
  })
}

///|
/// A predicate on frames that holds once `octets` of DATA on `stream` have
/// come, counting from when it is made.
fn data_seen(stream : Int32, octets : Int32) -> (@http2.Frame) -> Bool {
  let mut seen = 0
  frame => {
    if frame is Data(stream_id~, data~, ..) && stream_id == stream {
      seen += data.length()
    }
    seen >= octets
  }
}

///|
/// A predicate on frames that holds once each of `streams` has ended,
/// counting from when it is made.
fn all_ended(streams : Array[Int32]) -> (@http2.Frame) -> Bool {
  let left = streams.copy()
  frame => {
    for i, stream in left {
      if ends_stream(frame, stream) {
        left.remove(i) |> ignore
        break
      }
    }
    left.is_empty()
  }
}

///|
async test "h2c: streams waiting on the connection window get it in the order they became ready: after a connection WINDOW_UPDATE, the stream that waited first sends its DATA first, one that has sent waits behind the others, and a new response waits behind them all" {
  with_definitions(flow_definitions(), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2(settings=false)
      defer raw.close()
      let out = []
      // Wide stream windows, so that only the connection window of 65,535
      // octets holds the bodies back. Stream 3 takes all of it at once and
      // waits for more; stream 1, after its delay, finds none, and waits
      // behind it.
      raw.send([
        Settings(
          params=[(@http2.settings_initial_window_size, 1_000_000)],
          ack=false,
        ),
        raw.get(1, "/slow-big"),
        raw.get(3, "/big"),
      ])
      out.push(raw.runs_until(frame => frame is Headers(stream_id=1, ..)))
      out.push("--- the connection window widened by 500")
      raw.send([WindowUpdate(stream_id=0, increment=500)])
      out.push(raw.runs_until(data_seen(3, 500)))
      // Stream 3 now waits behind stream 1, which gets the next 500 octets,
      // though stream 5's short body, which comes with them, would fit.
      out.push("--- the connection window widened by 500, and stream 5 opened")
      raw.send([WindowUpdate(stream_id=0, increment=500), raw.get(5, "/item")])
      out.push(raw.runs_until(data_seen(1, 500)))
      out.push("--- the connection window widened by 250000")
      raw.send([WindowUpdate(stream_id=0, increment=250_000)])
      let rest = raw.runs_until(all_ended([1, 3, 5])).split("\n").collect()
      // Stream 3 waited first; streams 1 and 5 began to wait again at about
      // the same time.
      out.push(rest[0].to_owned())
      let after = rest[1:].iter().map(line => line.to_owned()).collect()
      after.sort()
      out.append(after)
      inspect(
        out.join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 3 END_HEADERS [:status: 200, accept-ranges: bytes, date: <now>, content-length: 150000]
          #|DATA 3: 4 frames, 65535 octets
          #|HEADERS 1 END_HEADERS [:status: 200, accept-ranges: bytes, date: <now>, content-length: 150000]
          #|--- the connection window widened by 500
          #|DATA 3: 1 frames, 500 octets
          #|--- the connection window widened by 500, and stream 5 opened
          #|HEADERS 5 END_HEADERS [:status: 200, date: <now>, content-length: 5]
          #|DATA 1: 1 frames, 500 octets
          #|--- the connection window widened by 250000
          #|DATA 3 END_STREAM: 6 frames, 83965 octets
          #|DATA 5 END_STREAM: 1 frames, 5 octets
          #|DATA 1 END_STREAM: 10 frames, 149500 octets
        ),
      )
    })
  })
}

///|
async test "h2c: a fast stream is answered at once while a large body on the same connection waits for window" {
  with_definitions(flow_definitions(), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2(settings=false)
      defer raw.close()
      let out = []
      // Stream windows of 1,000 octets: stream 1's body waits for its own
      // window, while stream 3's short body fits at once.
      raw.send([
        Settings(
          params=[(@http2.settings_initial_window_size, 1000)],
          ack=false,
        ),
        raw.get(1, "/big"),
        raw.get(3, "/item"),
        fence,
      ])
      out.push(raw.frames_until_ping_ack())
      out.push("--- both windows widened")
      raw.send([
        WindowUpdate(stream_id=0, increment=100_000),
        WindowUpdate(stream_id=1, increment=149_000),
      ])
      out.push(raw.runs_until(frame => ends_stream(frame, 1)))
      out.push("---")
      out.append(smock.journal_once(2, within=1000))
      inspect(
        out.join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 1 END_HEADERS [:status: 200, accept-ranges: bytes, date: <now>, content-length: 150000]
          #|DATA 1 1000 octets
          #|HEADERS 3 END_HEADERS [:status: 200, date: <now>, content-length: 5]
          #|DATA 3 END_STREAM 5 octets
          #|--- both windows widened
          #|DATA 1 END_STREAM: 10 frames, 149000 octets
          #|---
          #|/item: stub "item", status 200
          #|/big: stub "big", status 200
        ),
      )
    })
  })
}

///|
async test "h2c: a stream reset while its body waits for window ends its slow write at once: its entry is committed, no more of its body is sent, and the window it was woken for goes to the stream waiting after it" {
  with_definitions(flow_definitions(), dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2(settings=false)
      defer raw.close()
      let out = []
      // Stream 1 takes the connection window and waits for more; stream 3,
      // with a short body, waits behind it.
      raw.send([
        Settings(
          params=[(@http2.settings_initial_window_size, 1_000_000)],
          ack=false,
        ),
        raw.get(1, "/big"),
        raw.get(3, "/item"),
      ])
      out.push(raw.runs_until(frame => frame is Headers(stream_id=3, ..)))
      // The window wakes stream 1, and the reset in the same read ends it
      // before it sends: stream 3 gets the window instead.
      out.push("--- the connection window widened by 10, and stream 1 reset")
      raw.send([
        WindowUpdate(stream_id=0, increment=10),
        RstStream(stream_id=1, error_code=@http2.error_cancel),
      ])
      out.push(raw.runs_until(frame => ends_stream(frame, 3)))
      out.push("--- nothing more on stream 1")
      raw.send([WindowUpdate(stream_id=0, increment=200_000), fence])
      let more = raw.frames_until_ping_ack()
      out.push(if more == "" { "(no frame)" } else { more })
      out.push("---")
      out.append(smock.journal_once(2, within=1000))
      inspect(
        out.join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 1 END_HEADERS [:status: 200, accept-ranges: bytes, date: <now>, content-length: 150000]
          #|DATA 1: 4 frames, 65535 octets
          #|HEADERS 3 END_HEADERS [:status: 200, date: <now>, content-length: 5]
          #|--- the connection window widened by 10, and stream 1 reset
          #|DATA 3 END_STREAM: 1 frames, 5 octets
          #|--- nothing more on stream 1
          #|(no frame)
          #|---
          #|/big: stub "big", status 200
          #|/item: stub "item", status 200
        ),
      )
    })
  })
}

///|
async test "h2c: a stream reset while its task writes part of its body to a client that does not read leaves every frame whole: the write goes out in full, then the next stream's response, and the task ends with its entry committed" {
  // A body of 9,000,000 octets, of which the client grants about 8,000,000
  // at once: more than the socket takes while the client does not read, so
  // the stream's task is still writing when the reset comes.
  let definitions = [
    (
      "m.json",
      (
        #|{ "mocks": [{ "name": "m", "hosts": ["localhost"] }],
        #|  "stubs": [
        #|    { "id": "huge", "mock": "m", "request": { "path": "/huge" },
        #|      "response": { "status": 200, "bodyFile": "huge.txt" } },
        #|    { "id": "item", "mock": "m", "request": { "path": "/item" },
        #|      "response": { "status": 200, "body": "hello" } } ] }
      ),
    ),
    ("files/huge.txt", "x".repeat(9_000_000)),
  ]
  with_definitions(definitions, dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let raw = smock.raw_h2(settings=false)
      defer raw.close()
      // A wide stream window: the connection window of 65,535 octets goes
      // at once, and the task waits for more.
      raw.send([
        Settings(
          params=[(@http2.settings_initial_window_size, 8_000_000)],
          ack=false,
        ),
        raw.get(1, "/huge"),
      ])
      let out = [raw.runs_until(data_seen(1, 65535))]
      // A WINDOW_UPDATE owes no reply, so the reader has nothing to write,
      // and the woken task writes its DATA itself.
      raw.send([WindowUpdate(stream_id=0, increment=8_000_000)])
      @async.sleep(300)
      raw.send([
        RstStream(stream_id=1, error_code=@http2.error_cancel),
        raw.get(3, "/item"),
      ])
      out.push(
        "--- the connection window widened by 8000000, then stream 1 reset and stream 3 sent",
      )
      out.push(raw.runs_until(frame => ends_stream(frame, 3)))
      // Stream 1's task ended once its write was done, and committed its
      // entry then.
      out.push("---")
      out.append(smock.journal_once(2, within=1000))
      inspect(
        out.join("\n"),
        content=(
          #|SETTINGS [MAX_CONCURRENT_STREAMS=100, MAX_HEADER_LIST_SIZE=32768]
          #|SETTINGS ACK
          #|HEADERS 1 END_HEADERS [:status: 200, accept-ranges: bytes, date: <now>, content-length: 9000000]
          #|DATA 1: 4 frames, 65535 octets
          #|--- the connection window widened by 8000000, then stream 1 reset and stream 3 sent
          #|DATA 1: 485 frames, 7934465 octets
          #|HEADERS 3 END_HEADERS [:status: 200, date: <now>, content-length: 5]
          #|DATA 3 END_STREAM: 1 frames, 5 octets
          #|---
          #|/item: stub "item", status 200
          #|/huge: stub "huge", status 200
        ),
      )
    })
  })
}
