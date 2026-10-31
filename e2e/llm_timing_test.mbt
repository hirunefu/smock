// Seam 2 tests of the pacing of LLM streams over real sockets: the head and
// the opening chunk at once, each piece after its wait counted from the
// head, a client that leaves mid-stream, and a drain during a stream.

///|
/// A Mock `openai` whose Stub `paced` streams `Hi there!` in three pieces,
/// the first 400 ms after the head and each later one 300 ms after the one
/// before, its seed fixing its request id. `/v1/ticks` streams 200 pieces, one every 50 ms, which would
/// last 10 s, and `/hello` answers at once.
let paced_openai : String =
  $|{ "mocks": [{ "name": "openai" }],
  $|  "stubs": [
  $|    { "id": "paced", "mock": "openai",
  $|      "request": { "method": "POST", "path": "/v1/chat/completions" },
  $|      "response": { "status": 200,
  $|        "llm": { "api": "openai-chat", "text": "Hi there!",
  $|          "timing": { "first": { "fixed": 400 }, "interval": { "fixed": 300 } } } },
  $|      "fault": { "seed": 7 } },
  $|    { "id": "ticks", "mock": "openai",
  $|      "request": { "method": "POST", "path": "/v1/ticks" },
  $|      "response": { "status": 200,
  $|        "llm": { "api": "openai-chat", "text": "\{"tick".repeat(200)}",
  $|          "timing": { "first": { "fixed": 50 }, "interval": { "fixed": 50 } } } } },
  $|    { "id": "hello", "mock": "openai", "request": { "path": "/hello" },
  $|      "response": { "status": 200, "body": "hello" } } ] }

///|
/// What the Chat Completions chunk `event`, as read from the wire, carries:
/// the opening chunk, a piece, the closing chunk or the end marker.
fn chunk_carries(event : String) -> String {
  let data = event[event.find("data: ").unwrap_or(0) + 6:].to_owned()
  let json = @json.parse(data) catch { _ => return data.trim().to_owned() }
  match json {
    { "choices": [{ "delta": { "role": _, .. }, .. }], .. } => "opening chunk"
    { "choices": [{ "delta": { "content": String(piece), .. }, .. }], .. } =>
      "piece \{piece.escape()}"
    { "choices": [{ "finish_reason": String(_), .. }], .. } => "closing chunk"
    _ => data
  }
}

///|
/// Sends a streamed Chat Completions request to `path` on `conn`, as
/// `session` when it is given.
async fn ask_stream(conn : Conn, path : String, session? : String) -> Unit {
  conn.write(
    raw_request(
      "POST",
      path,
      host="localhost",
      headers=[("Content-Type", "application/json"), ..session_headers(session)],
      body="{\"model\":\"gpt-6-astra\",\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}]}",
    ),
  )
}

///|
async test "over a real socket, the head and the opening chunk arrive at once, the first piece first after the head, and each later piece interval after the one before" {
  with_definitions([("openai.json", paced_openai)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let conn = smock.connect()
      defer conn.close()
      let start = @async.now()
      ask_stream(conn, "/v1/chat/completions")
      let head = read_head(conn)
      let head_at = @async.now()
      let out = [
        "head \{head_arrival(head_at - start, 400)}:",
        head.trim_end(chars="\n").to_owned(),
      ]
      // When each event is due, in milliseconds after the head: the
      // opening chunk at once, the pieces "Hi t", "here" and "!", then the
      // closing chunk and [DONE] right after the last piece.
      for due in [0, 400, 700, 1000, 1000, 1000] {
        let event = @async.with_timeout_opt(patience_ms, () => {
          conn.read_until("\n\n")
        })
        guard event is Some(Some(event)) else {
          fail("the stream ended early:\n\{out.join("\n")}")
        }
        let elapsed = @async.now() - head_at
        let when = if due == 0 {
          head_arrival(elapsed, 400)
        } else {
          arrival(elapsed, due)
        }
        out.push("\{chunk_carries(event)} \{when}")
      }
      inspect(
        out.join("\n"),
        content=(
          #|head before 400 ms:
          #|HTTP/1.1 200 OK
          #|Content-Type: text/event-stream
          #|x-request-id: req_TZp9I060Mzd0w4SDwiWTe2c8
          #|Smock-Mock: openai; via=default
          #|Date: <now>
          #|Transfer-Encoding: chunked
          #|opening chunk before 400 ms
          #|piece "Hi t" at 400 ms
          #|piece "here" at 700 ms
          #|piece "!" at 1000 ms
          #|closing chunk at 1000 ms
          #|[DONE] at 1000 ms
        ),
      )
    })
  })
}

///|
async test "a client that leaves mid-stream ends the stream at smock's next write, the Journal records its request, and smock keeps serving" {
  with_definitions([("openai.json", paced_openai)], dir => {
    let stopped = with_smock(["--dir", dir, "--port", "0"], smock => {
      let conn = smock.connect()
      ask_stream(conn, "/v1/ticks", session="left-mid-stream")
      let _ = read_head(conn)
      // The opening chunk, then the first piece.
      for _ in 0..<2 {
        guard conn.read_until("\n\n") is Some(_) else {
          fail("the stream ended early")
        }
      }
      let streaming = open_files(smock.pid)
      conn.close()
      // smock notices when it next writes to the closed connection, 50 ms
      // later, and then closes its end of it.
      let ended = @async.with_timeout_opt(3000, () => {
        while open_files(smock.pid) >= streaming {
          @async.sleep(20)
        }
      })
      let recorded = smock.journal_count(
        "left-mid-stream", "{ \"filter\": { \"path\": \"/v1/ticks\" } }",
      )
      inspect(
        [
          if ended is Some(_) {
            "the stream ended"
          } else {
            "the stream still runs 3 s after the client closed"
          },
          "in the Journal: \{recorded}",
          smock.send("GET", "/hello"),
        ].join("\n"),
        content=(
          #|the stream ended
          #|in the Journal: 1
          #|HTTP/1.1 200 OK
          #|Smock-Mock: openai; via=default
          #|Date: <now>
          #|Content-Length: 5
          #|
          #|hello
        ),
      )
    })
    // smock logged nothing about the closed connection, and stopped only
    // when the test sent SIGTERM.
    inspect(
      "status \{stopped.status}\n\{log_entries(stopped.logs)}",
      content=(
        #|status 0
        #|{"level":"info","msg":"smock starting","version":"*","commit":"*","toolchain":"*","adminAuth":"on"}
        #|{"level":"info","msg":"random seed","seed":"*"}
        #|{"level":"info","msg":"journal byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"state byte bound","maxBytes":"*","source":"*","memoryLimit":"*"}
        #|{"level":"info","msg":"listening","listener":"admin","address":"0.0.0.0:*"}
        #|{"level":"info","msg":"self-signed certificate in use","sha256Fingerprint":"*","names":["localhost","127.0.0.1","::1"]}
        #|{"level":"info","msg":"listening","listener":"plain","address":"0.0.0.0:*"}
        #|{"level":"info","msg":"listening","listener":"tls","address":"0.0.0.0:*"}
        #|{"level":"info","msg":"drain started","timeoutMs":20000}
        #|{"level":"info","msg":"drain ended","connectionsCut":0}
      ),
    )
  })
}

///|
async test "on SIGTERM, a drain waits for a stream in progress to send its waits and its last event, then smock exits with status 0" {
  with_definitions([("openai.json", paced_openai)], dir => {
    let stopped = with_smock(
      ["--dir", dir, "--port", "0", "--drain-timeout-ms", "10000"],
      smock => {
        let stream = smock.connect()
        defer stream.close()
        ask_stream(stream, "/v1/chat/completions")
        let _ = read_head(stream)
        let start = @async.now()
        smock.terminate()
        let (last, _, events) = until_end(stream, start)
        let status = smock.exited()
        inspect(
          [
            "the stream ended with [DONE] and its last chunk: \{events.has_suffix("data: [DONE]\n\n\n0\n\n")}",
            "its last piece came after its waits, well before the drain timeout: \{last >= 900L && last < 3000L}",
            "exit status \{status}",
          ].join("\n"),
          content=(
            #|the stream ended with [DONE] and its last chunk: true
            #|its last piece came after its waits, well before the drain timeout: true
            #|exit status 0
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
}
