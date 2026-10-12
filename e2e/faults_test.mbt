// Seam 2 tests of Faults: a delayed status line, a connection closed
// without a response, a partial response, and replay from --seed.

///|
/// Mock `m` with Stubs that answer `GET /slow` after a fixed delay of
/// 1500 ms, `GET /fast` at once, `GET /close` by closing the connection,
/// `GET /partial` with half its body, and `GET /coin` by closing the
/// connection half of the time, as the process generator decides.
let faults : String =
  #|{ "mocks": [{ "name": "m" }],
  #|  "stubs": [
  #|    { "id": "slow", "mock": "m", "request": { "path": "/slow" },
  #|      "response": { "status": 200, "body": "slow" },
  #|      "fault": { "delay": { "fixed": 1500 } } },
  #|    { "id": "fast", "mock": "m", "request": { "path": "/fast" },
  #|      "response": { "status": 200, "body": "fast" } },
  #|    { "id": "close", "mock": "m", "request": { "path": "/close" },
  #|      "response": { "status": 200, "body": "never sent" },
  #|      "fault": { "connection": { "kind": "close" } } },
  #|    { "id": "partial", "mock": "m", "request": { "path": "/partial" },
  #|      "response": { "status": 200, "headers": { "Content-Type": "text/plain" },
  #|        "body": "0123456789" },
  #|      "fault": { "connection": { "kind": "partial", "probability": 1 } } },
  #|    { "id": "coin", "mock": "m", "request": { "path": "/coin" },
  #|      "response": { "status": 200, "body": "heads" },
  #|      "fault": { "connection": { "kind": "close", "probability": 0.5 } } } ] }

///|
/// Every byte smock sends on `conn` until it closes the connection with a
/// FIN, with `\r\n` shown as `\n`. A reset fails the test.
async fn read_to_end(conn : Conn) -> String {
  let received = @buffer.Buffer()
  let result = @async.with_timeout_opt(patience_ms, () => {
    while conn.read_some() is Some(bytes) {
      received.write_bytes(bytes)
    }
  })
  guard result is Some(_) else { fail("the connection stayed open") }
  @utf8.decode_lossy(received.to_bytes()).replace_all(old="\r\n", new="\n")
}

///|
async test "a delay holds back the status line, while smock keeps answering other connections" {
  with_definitions([("m.json", faults)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let slow = smock.connect()
      defer slow.close()
      let start = @async.now()
      slow.write("GET /slow HTTP/1.1\r\nHost: localhost\r\n\r\n")
      let fast = smock.send("GET", "/fast")
      let fast_ms = @async.now() - start
      // Nothing of the slow response, not even its status line, comes
      // before its delay is over.
      let early = @async.with_timeout_opt(500, () => slow.read_some())
      let slow_response = read_response(slow)
      let slow_ms = @async.now() - start
      inspect(
        [
          "fast answered during the delay: \{fast_ms < 1500}",
          "slow sent nothing in the meantime: \{early is None}",
          "slow answered after at least 1500 ms: \{slow_ms >= 1500}",
          "---",
          fast,
          "---",
          slow_response,
        ].join("\n"),
        content=(
          #|fast answered during the delay: true
          #|slow sent nothing in the meantime: true
          #|slow answered after at least 1500 ms: true
          #|---
          #|HTTP/1.1 200 OK
          #|Smock-Mock: m; via=default
          #|Content-Length: 4
          #|
          #|fast
          #|---
          #|HTTP/1.1 200 OK
          #|Smock-Mock: m; via=default
          #|Content-Length: 4
          #|
          #|slow
        ),
      )
    })
  })
}

///|
async test "a close Fault ends the connection with a FIN, without a byte of response" {
  let _ = on_both_ports(files=[("m.json", faults)], (smock, over) => {
    let conn = smock.connect(over~)
    defer conn.close()
    conn.write("GET /close HTTP/1.1\r\nHost: localhost\r\n\r\n")
    let received = read_to_end(conn)
    // smock carries on with other connections.
    let next = smock.connect(over~)
    defer next.close()
    next.write("GET /fast HTTP/1.1\r\nHost: localhost\r\n\r\n")
    inspect(
      "received: \{received.escape()}\nthen: \{status_line(read_response(next))}",
      content=(
        #|received: ""
        #|then: HTTP/1.1 200 OK
      ),
    )
  })
}

///|
async test "a partial Fault sends the status line, the headers and the first half of the body, then a FIN" {
  let _ = on_both_ports(files=[("m.json", faults)], (smock, over) => {
    let conn = smock.connect(over~)
    defer conn.close()
    conn.write("GET /partial HTTP/1.1\r\nHost: localhost\r\n\r\n")
    inspect(
      read_to_end(conn),
      content=(
        #|HTTP/1.1 200 OK
        #|Content-Type: text/plain
        #|Smock-Mock: m; via=default
        #|Content-Length: 10
        #|
        #|01234
      ),
    )
  })
}

///|
async test "a partial Fault on Server-Sent Events sends the head and the first half of the events, without ending the stream" {
  let defs =
    #|{ "mocks": [{ "name": "m" }],
    #|  "stubs": [{ "id": "ticks", "mock": "m", "request": { "path": "/ticks" },
    #|    "response": { "status": 200, "events": [
    #|      { "data": "one" }, { "delay": 20, "data": "two" },
    #|      { "delay": 20, "data": "three" }] },
    #|    "fault": { "connection": { "kind": "partial" } } }] }
  with_definitions([("m.json", defs)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let conn = smock.connect()
      defer conn.close()
      conn.write("GET /ticks HTTP/1.1\r\nHost: localhost\r\n\r\n")
      // One event of three: the stream lacks its last chunk, `0`.
      inspect(
        read_to_end(conn),
        content=(
          #|HTTP/1.1 200 OK
          #|Content-Type: text/event-stream
          #|Smock-Mock: m; via=default
          #|Transfer-Encoding: chunked
          #|
          #|b
          #|data: one
          #|
          #|
          #|
        ),
      )
    })
  })
}

///|
async test "a real HTTP client sees a partial response cut short" {
  with_definitions([("m.json", faults)], dir => {
    let _ = with_smock(["--dir", dir, "--port", "0"], smock => {
      let client = @http.Client("http://127.0.0.1:\{smock.port}")
      defer client.close()
      let response = client.get("/partial")
      let body = try client.read_all().text() catch {
        err => "error: \{err}"
      } noraise {
        body => "complete body: \{body}"
      }
      inspect(
        "\{response.code} \{response.reason}\n\{body.has_prefix("error")}",
        content=(
          #|200 OK
          #|true
        ),
      )
    })
  })
}

///|
/// Sends `GET /coin` `n` times, each on its own connection, and returns
/// what happened to each in turn: `-` for a closed connection, `+` for a
/// response.
async fn coin_flips(smock : Smock, n : Int) -> String {
  let out = StringBuilder()
  for _ in 0..<n {
    let conn = smock.connect()
    defer conn.close()
    conn.write(
      "GET /coin HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
    )
    out.write_string(if read_to_end(conn) == "" { "-" } else { "+" })
  }
  out.to_string()
}

///|
/// The seed of the `random seed` log entry in `logs`.
fn logged_seed(logs : Array[String]) -> String raise {
  for line in logs {
    let entry = @json.parse(line) catch { _ => continue }
    if entry is Object(entry) &&
      entry.get("msg") is Some(String("random seed")) &&
      entry.get("seed") is Some(seed) {
      return seed.stringify()
    }
  }
  fail("no random seed in the logs:\n\{logs.join("\n")}")
}

///|
async test "the process generator's seed is logged, and --seed or SMOCK_SEED replays its Fault decisions" {
  with_definitions([("m.json", faults)], dir => {
    let args = ["--dir", dir, "--port", "0"]
    let mut drawn = ""
    let first = with_smock(args, smock => drawn = coin_flips(smock, 24))
    let seed = logged_seed(first.logs)
    let mut by_flag = ""
    let second = with_smock([..args, "--seed", seed], smock => {
      by_flag = coin_flips(smock, 24)
    })
    let mut by_env = ""
    let third = with_smock(args, env={ "SMOCK_SEED": seed }, smock => {
      by_env = coin_flips(smock, 24)
    })
    inspect(
      [
        "some closed and some answered: \{drawn.contains("-") && drawn.contains("+")}",
        "--seed replays them: \{by_flag == drawn}",
        "SMOCK_SEED replays them: \{by_env == drawn}",
        "the seed is logged again: \{logged_seed(second.logs) == seed && logged_seed(third.logs) == seed}",
      ].join("\n"),
      content=(
        #|some closed and some answered: true
        #|--seed replays them: true
        #|SMOCK_SEED replays them: true
        #|the seed is logged again: true
      ),
    )
  })
}

///|
async test "--seed fixes the process generator's seed" {
  with_definitions([("m.json", faults)], dir => {
    let stopped = with_smock(
      ["--dir", dir, "--port", "0", "--seed", "9007199254740991"],
      _ => (),
    )
    inspect(logged_seed(stopped.logs), content="9007199254740991")
  })
}
