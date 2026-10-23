// Seam 2 tests of the drain on SIGTERM: smock stops accepting connections,
// closes the idle ones, lets responses in progress finish, cuts what is
// still running when the drain timeout expires, and exits with status 0.

///|
/// Mock `m`, whose Stubs answer `GET /fast` at once, `GET /slow` after a
/// delay of 1000 ms, `GET /stalled` after a delay of 60 s, `GET /ticks` with
/// a stream of 100 events, one every 100 ms, and `GET /brief` with a stream
/// of 10 such events.
let drain_defs : String = {
  let tick = "{ \"delay\": 100, \"data\": \"tick\" }"
  let ticks = Array::make(100, tick)
  let brief = Array::make(10, tick)
  let defs =
    $|{ "mocks": [{ "name": "m" }],
    $|  "stubs": [
    $|    { "id": "fast", "mock": "m", "request": { "path": "/fast" },
    $|      "response": { "status": 200, "body": "fast" } },
    $|    { "id": "slow", "mock": "m", "request": { "path": "/slow" },
    $|      "response": { "status": 200, "body": "slow" },
    $|      "fault": { "delay": { "fixed": 1000 } } },
    $|    { "id": "stalled", "mock": "m", "request": { "path": "/stalled" },
    $|      "response": { "status": 200, "body": "stalled" },
    $|      "fault": { "delay": { "fixed": 60000 } } },
    $|    { "id": "ticks", "mock": "m", "request": { "path": "/ticks" },
    $|      "response": { "status": 200, "events": [\{ticks.join(", ")}] } },
    $|    { "id": "brief", "mock": "m", "request": { "path": "/brief" },
    $|      "response": { "status": 200, "events": [\{brief.join(", ")}] } } ] }
  defs
}

///|
/// How long a test waits after sending a request before it sends SIGTERM,
/// so that smock has received the request by then.
let settle_ms : Int = 300

///|
/// Whether a new connection to `port` is accepted or refused.
async fn connection_to(port : Int) -> String {
  try @socket.Tcp::connect(@socket.Addr::parse("127.0.0.1:\{port}")) catch {
    err =>
      if err.to_string().contains("Connection refused") {
        "refused"
      } else {
        "failed: \{err}"
      }
  } noraise {
    conn => {
      conn.close()
      "accepted"
    }
  }
}

///|
/// The log entries about the drain, without their time.
fn drain_entries(logs : Array[String]) -> String {
  let out = []
  for line in logs {
    let entry = @json.parse(line) catch { _ => continue }
    guard entry is Object(fields) &&
      fields.get("msg") is Some(String(msg)) &&
      msg.contains("drain") else {
      continue
    }
    fields.remove("time")
    out.push(Json::object(fields).stringify())
  }
  out.join("\n")
}

///|
async test "on SIGTERM, smock refuses new connections, closes idle ones at once, fails /readyz, finishes the responses in progress, closing their connections after them, and exits with status 0 as soon as nothing is in flight" {
  with_definitions([("m.json", drain_defs)], dir => {
    with_certificates(certs => {
      let stopped = with_smock(
        [
          "--dir",
          dir,
          "--port",
          "0",
          "--drain-timeout-ms",
          "10000",
          ..certs.args(),
        ],
        smock => {
          let idle = []
          for over in [Plain, Tls(certs)] {
            let conn = smock.connect(over~)
            conn.write("GET /fast HTTP/1.1\r\nHost: localhost\r\n\r\n")
            let _ = read_response(conn)
            idle.push(conn)
          }
          defer idle.each(conn => conn.close())
          let slow = smock.connect()
          defer slow.close()
          slow.write("GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n")
          // A stream that began before SIGTERM, and ends during the drain.
          let stream = smock.connect()
          defer stream.close()
          stream.write("GET /brief HTTP/1.1\r\nHost: localhost\r\n\r\n")
          let _ = read_head(stream)
          @async.sleep(settle_ms)
          let start = @async.now()
          smock.terminate()
          let out = []
          for i, conn in idle {
            let (elapsed, received) = ended(conn, start)
            out.push(
              "idle \{["plain", "TLS"][i]} connection closed at once: \{elapsed < 1000 && received == ""}",
            )
          }
          out.push(smock.probes())
          out.push("new plain connection: \{connection_to(smock.port)}")
          out.push("new TLS connection: \{connection_to(smock.tls_port)}")
          out.push(read_response(slow))
          let answered = @async.now() - start
          out.push(
            "answered after its delay, well before the drain timeout: \{answered < 3000}",
          )
          out.push("then closed: \{closed(slow)}")
          let (_, stream_end, events) = until_end(stream, start)
          out.push(
            "the stream ended with its last chunk: \{events.has_suffix("\n0\n\n")}, then closed, well before the drain timeout: \{stream_end < 3000}",
          )
          let status = smock.exited()
          let exited = @async.now() - start
          out.push(
            "exit status \{status}, once nothing was in flight: \{exited < 3000}",
          )
          inspect(
            out.join("\n"),
            content=(
              #|idle plain connection closed at once: true
              #|idle TLS connection closed at once: true
              #|/startupz: 200 {"status":"ok","warnings":[]}
              #|/readyz: 503 {"error":"not_ready","message":"smock is draining its connections before it exits","warnings":[]}
              #|/livez: 200 {"status":"ok","warnings":[]}
              #|new plain connection: refused
              #|new TLS connection: refused
              #|HTTP/1.1 200 OK
              #|Smock-Mock: m; via=default
              #|Date: <now>
              #|Connection: close
              #|Content-Length: 4
              #|
              #|slow
              #|answered after its delay, well before the drain timeout: true
              #|then closed: true
              #|the stream ended with its last chunk: true, then closed, well before the drain timeout: true
              #|exit status 0, once nothing was in flight: true
            ),
          )
        },
      )
      inspect(
        drain_entries(stopped.logs),
        content=(
          #|{"level":"info","msg":"drain started","timeoutMs":10000}
          #|{"level":"info","msg":"drain ended","connectionsCut":0}
        ),
      )
    })
  })
}

///|
/// Reads `conn` until smock ends it, and returns when the last bytes came
/// and when the end came, in milliseconds after `since`, and every byte
/// received, with `\r\n` shown as `\n`.
async fn until_end(conn : Conn, since : Int64) -> (Int64, Int64, String) {
  let (last, end, received) = received_until_end(conn, since)
  (last, end, @utf8.decode_lossy(received).replace_all(old="\r\n", new="\n"))
}

///|
async test "a request still arriving when SIGTERM comes is answered once the rest of it arrives, with Connection: close, and its connection closes after the response" {
  with_definitions([("m.json", drain_defs)], dir => {
    with_certificates(certs => {
      let _ = with_smock(
        [
          "--dir",
          dir,
          "--port",
          "0",
          "--drain-timeout-ms",
          "10000",
          ..certs.args(),
        ],
        smock => {
          let conns = []
          for over in [Plain, Tls(certs)] {
            let conn = smock.connect(over~)
            // The head, without the empty line that ends it.
            conn.write("GET /fast HTTP/1.1\r\nHost: localhost\r\n")
            conns.push(conn)
          }
          defer conns.each(conn => conn.close())
          @async.sleep(settle_ms)
          smock.terminate()
          @async.sleep(settle_ms)
          let out = []
          for i, conn in conns {
            conn.write("\r\n")
            out.push("\{["plain", "TLS"][i]}:")
            out.push(read_response(conn))
            out.push("then closed: \{closed(conn)}")
          }
          out.push("exit status \{smock.exited()}")
          inspect(
            out.join("\n"),
            content=(
              #|plain:
              #|HTTP/1.1 200 OK
              #|Smock-Mock: m; via=default
              #|Date: <now>
              #|Connection: close
              #|Content-Length: 4
              #|
              #|fast
              #|then closed: true
              #|TLS:
              #|HTTP/1.1 200 OK
              #|Smock-Mock: m; via=default
              #|Date: <now>
              #|Connection: close
              #|Content-Length: 4
              #|
              #|fast
              #|then closed: true
              #|exit status 0
            ),
          )
        },
      )
    })
  })
}

///|
async test "Server-Sent Event streams and delays still running when the drain timeout expires are cut, and smock exits with status 0" {
  with_definitions([("m.json", drain_defs)], dir => {
    let stopped = with_smock(
      ["--dir", dir, "--port", "0"],
      env={ "SMOCK_DRAIN_TIMEOUT_MS": "1500" },
      smock => {
        let stream = smock.connect()
        defer stream.close()
        stream.write("GET /ticks HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let _ = read_head(stream)
        let stalled = smock.connect()
        defer stalled.close()
        stalled.write("GET /stalled HTTP/1.1\r\nHost: localhost\r\n\r\n")
        @async.sleep(settle_ms)
        let start = @async.now()
        smock.terminate()
        let (streamed, delayed) = @async.with_task_group(group => {
          let streamed = group.spawn(() => until_end(stream, start))
          let delayed = group.spawn(() => until_end(stalled, start))
          (streamed.wait(), delayed.wait())
        })
        let status = smock.exited()
        let exited = @async.now() - start
        let (last_event, stream_end, events) = streamed
        let (_, delay_end, response) = delayed
        inspect(
          (
            $|the stream went on during the drain: \{last_event >= 1000}
            $|then was cut at the drain timeout: \{stream_end >= 1500 && stream_end < 3000}
            $|without its last chunk: \{!events.has_suffix("0\n\n")}
            $|the delayed response was cut at the drain timeout: \{delay_end >= 1500 && delay_end < 3000}
            $|before a byte of it was sent: \{response == ""}
            $|exit status \{status}, once the drain timeout expired: \{exited >= 1500 && exited < 3000}
          ),
          content=(
            #|the stream went on during the drain: true
            #|then was cut at the drain timeout: true
            #|without its last chunk: true
            #|the delayed response was cut at the drain timeout: true
            #|before a byte of it was sent: true
            #|exit status 0, once the drain timeout expired: true
          ),
        )
      },
    )
    inspect(
      drain_entries(stopped.logs),
      content=(
        #|{"level":"info","msg":"drain started","timeoutMs":1500}
        #|{"level":"info","msg":"drain ended","connectionsCut":2}
      ),
    )
  })
}

///|
async test "a client that stops reading does not hold up the drain: with a longer write timeout, its connection is cut at the drain timeout, on the plain and the TLS port" {
  with_definitions(big_files(), dir => {
    with_certificates(certs => {
      let stopped = with_smock(
        [
          "--dir",
          dir,
          "--port",
          "0",
          "--drain-timeout-ms",
          "1000",
          "--write-timeout-ms",
          "30000",
          ..certs.args(),
        ],
        smock => {
          // Each asks for the large body and never reads, so smock's write
          // waits on it until the drain timeout cuts it.
          let stuck = []
          for over in [Plain, Tls(certs)] {
            let conn = smock.connect(over~)
            conn.write("GET /big HTTP/1.1\r\nHost: localhost\r\n\r\n")
            stuck.push(conn)
          }
          defer stuck.each(conn => conn.close())
          @async.sleep(settle_ms)
          let start = @async.now()
          smock.terminate()
          let status = smock.exited()
          let exited = @async.now() - start
          inspect(
            "exit status \{status}, once the drain timeout expired: \{exited >= 1000 && exited < 3000}",
            content="exit status 0, once the drain timeout expired: true",
          )
        },
      )
      inspect(
        drain_entries(stopped.logs),
        content=(
          #|{"level":"info","msg":"drain started","timeoutMs":1000}
          #|{"level":"info","msg":"drain ended","connectionsCut":2}
        ),
      )
    })
  })
}

///|
async test "SIGINT and SIGHUP end smock at once, without a drain: a response still delayed is cut, and nothing about a drain is logged" {
  with_definitions([("m.json", drain_defs)], dir => {
    let out = []
    for signal in ["INT", "HUP"] {
      let stopped = with_smock(
        ["--dir", dir, "--port", "0", "--drain-timeout-ms", "10000"],
        smock => {
          let stalled = smock.connect()
          defer stalled.close()
          stalled.write("GET /stalled HTTP/1.1\r\nHost: localhost\r\n\r\n")
          @async.sleep(settle_ms)
          let start = @async.now()
          let _ = @process.run("kill", ["-\{signal}", smock.pid.to_string()])
          let (_, end, response) = until_end(stalled, start)
          let status = smock.exited()
          let exited = @async.now() - start
          out.push(
            "SIG\{signal}: the delayed response was cut at once: \{end < 2000 && response == ""}; exit status \{status}, at once: \{exited < 2000}",
          )
        },
      )
      out.push("a drain logged: \{drain_entries(stopped.logs) != ""}")
    }
    inspect(
      out.join("\n"),
      content=(
        #|SIGINT: the delayed response was cut at once: true; exit status -2, at once: true
        #|a drain logged: false
        #|SIGHUP: the delayed response was cut at once: true; exit status -1, at once: true
        #|a drain logged: false
      ),
    )
  })
}
