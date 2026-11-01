// Seam 2 tests of the mockoon log format over HTTP/2, h2c on the plain port
// and h2 on the TLS port: each request a Mock handles writes one
// Transaction recorded line to stdout, as over HTTP/1.1, once its stream's
// response has ended, however it ends. Lines are compared whole, byte for
// byte, with only the value of `timestamp` masked, once its form is checked.

///|
async test "h2c and h2: with SMOCK_LOG_FORMAT=mockoon, each request a Mock handles writes one Transaction recorded line, with :method and :path up to ?, as over HTTP/1.1" {
  with_definitions(mockoon_mocks(), dir => {
    with_certificates(certs => {
      let args = ["--dir", dir, "--port", "0", ..certs.args()]
      let env = { "SMOCK_LOG_FORMAT": "mockoon" }
      let _ = with_smock(args, env~, smock => {
        let out = []
        for tls in [false, true] {
          let client = if tls { smock.h2() } else { smock.h2c() }
          defer client.close()
          let requests = [
            ("GET", "/users/1?verbose=true", "localhost"),
            ("GET", "/users/a%20b", "localhost"),
            ("GET", "/orders/1", "unknown.example.com"),
          ]
          for request in requests {
            let (meth, path, authority) = request
            let response = client.request(meth, path, authority~)
            out.push("\{meth} \{path}: \{response.status}")
          }
        }
        // Read while smock runs: a line held in a buffer would not come.
        let lines = smock.transaction_lines(6)
        out.push(masked_lines(lines))
        inspect(
          out.join("\n"),
          content=(
            #|GET /users/1?verbose=true: 200
            #|GET /users/a%20b: 404
            #|GET /orders/1: 404
            #|GET /users/1?verbose=true: 200
            #|GET /users/a%20b: 404
            #|GET /orders/1: 404
            #|{"app":"smock","environmentName":"users","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/users/1","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
            #|{"app":"smock","environmentName":"users","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/users/a%20b","requestProxied":false,"responseStatus":404,"timestamp":"<timestamp>"}
            #|{"app":"smock","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/orders/1","requestProxied":false,"responseStatus":404,"timestamp":"<timestamp>"}
            #|{"app":"smock","environmentName":"users","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/users/1","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
            #|{"app":"smock","environmentName":"users","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/users/a%20b","requestProxied":false,"responseStatus":404,"timestamp":"<timestamp>"}
            #|{"app":"smock","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/orders/1","requestProxied":false,"responseStatus":404,"timestamp":"<timestamp>"}
          ),
        )
      })
    })
  })
}

///|
async test "h2c: a delayed response logs after its delay, while a fast stream on the connection logs at once, and a Server-Sent Event stream logs once, after its last event" {
  with_definitions([("slow.json", slow)], dir => {
    let env = { "SMOCK_LOG_FORMAT": "mockoon" }
    let _ = with_smock(["--dir", dir, "--port", "0"], env~, smock => {
      let out = []
      let client = smock.h2c()
      defer client.close()
      let start = @async.now()
      let delayed = client.send("GET", "/delayed", authority="localhost")
      let quick = client.request("GET", "/quick", authority="localhost")
      out.push("/quick answers: \{quick.status}")
      let line = smock.transaction_lines(1)[0]
      out.push(mask_timestamp(line))
      out.push("written during the delay: \{written_at(line) - start < 1000}")
      out.push("/delayed answers: \{client.response(delayed).status}")
      let line = smock.transaction_lines(2)[1]
      out.push(mask_timestamp(line))
      out.push("written after the delay: \{written_at(line) - start >= 1000}")
      let start = @async.now()
      let stream = client.send("GET", "/stream", authority="localhost")
      guard client.stream_event(stream) is Response(_) else {
        fail("no HEADERS")
      }
      guard client.stream_event(stream) is Data(_) else {
        fail("no first event")
      }
      @async.sleep(300)
      out.push(
        "after the first event: \{transactions(smock.stdout).length() - 2} lines",
      )
      let rest = client.response(stream)
      out.push("/stream ends: \{rest.ended}")
      let line = smock.transaction_lines(3)[2]
      out.push(mask_timestamp(line))
      out.push(
        "written after the last event: \{written_at(line) - start >= 1000}",
      )
      // The stream is one request: no more lines come.
      @async.sleep(300)
      out.push("lines in all: \{transactions(smock.stdout).length()}")
      inspect(
        out.join("\n"),
        content=(
          #|/quick answers: 200
          #|{"app":"smock","environmentName":"slow","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/quick","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
          #|written during the delay: true
          #|/delayed answers: 200
          #|{"app":"smock","environmentName":"slow","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/delayed","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
          #|written after the delay: true
          #|after the first event: 0 lines
          #|/stream ends: end
          #|{"app":"smock","environmentName":"slow","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/stream","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
          #|written after the last event: true
          #|lines in all: 3
        ),
      )
    })
  })
}

///|
async test "h2c: a reset Fault (RST_STREAM) or a close Fault (GOAWAY) logs fault and no responseStatus, and a partial Fault the status it wrote, in place and after a delay, as the Journal records them" {
  with_definitions(fault_definitions(), dir => {
    let env = { "SMOCK_LOG_FORMAT": "mockoon" }
    let _ = with_smock(["--dir", dir, "--port", "0"], env~, smock => {
      let out = []
      let batches = [
        ["/reset", "/partial", "/fast"],
        ["/late-partial", "/late-ticks", "/late-reset"],
        ["/close"],
        ["/late-close"],
      ]
      for paths in batches {
        let client = smock.h2c()
        defer client.close()
        let streams = []
        for path in paths {
          streams.push(client.send("GET", path))
        }
        for i, stream in streams {
          let response = client.response(stream)
          out.push("\{paths[i]}: \{response.status}, \{response.ended}")
        }
      }
      let lines = smock.transaction_lines(8)
      out.push(masked_lines(lines))
      out.push(smock.journal_endings())
      inspect(
        out.join("\n"),
        content=(
          #|/reset: 0, reset INTERNAL_ERROR
          #|/partial: 200, reset INTERNAL_ERROR
          #|/fast: 200, end
          #|/late-partial: 200, reset INTERNAL_ERROR
          #|/late-ticks: 200, reset INTERNAL_ERROR
          #|/late-reset: 0, reset INTERNAL_ERROR
          #|/close: 0, closed
          #|/late-close: 0, closed
          #|{"app":"smock","environmentName":"m","fault":"reset","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/reset","requestProxied":false,"timestamp":"<timestamp>"}
          #|{"app":"smock","environmentName":"m","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/partial","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
          #|{"app":"smock","environmentName":"m","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/fast","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
          #|{"app":"smock","environmentName":"m","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/late-partial","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
          #|{"app":"smock","environmentName":"m","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/late-ticks","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
          #|{"app":"smock","environmentName":"m","fault":"reset","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/late-reset","requestProxied":false,"timestamp":"<timestamp>"}
          #|{"app":"smock","environmentName":"m","fault":"close","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/close","requestProxied":false,"timestamp":"<timestamp>"}
          #|{"app":"smock","environmentName":"m","fault":"close","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/late-close","requestProxied":false,"timestamp":"<timestamp>"}
          #|GET /reset: fault reset
          #|GET /partial: 200
          #|GET /fast: 200
          #|GET /late-partial: 200
          #|GET /late-ticks: 200
          #|GET /late-reset: fault reset
          #|GET /close: fault close
          #|GET /late-close: fault close
        ),
      )
    })
  })
}

///|
async test "h2c: a stream the client resets while its response waits, for a delay or for its next event, logs its planned status once, when the reset comes, as the Journal records it" {
  with_definitions([("slow.json", slow)], dir => {
    let env = { "SMOCK_LOG_FORMAT": "mockoon" }
    let _ = with_smock(["--dir", dir, "--port", "0"], env~, smock => {
      let out = []
      let client = smock.h2c()
      defer client.close()
      let delayed = client.send("GET", "/delayed", authority="localhost")
      @async.sleep(200)
      let reset_at = @async.now()
      client.conn.reset(delayed, code=@http2.error_cancel)
      client.flush()
      let line = smock.transaction_lines(1)[0]
      out.push(mask_timestamp(line))
      out.push(
        "written at the reset, before the delay is over: \{written_at(line) - reset_at < 500}",
      )
      let stream = client.send("GET", "/stream", authority="localhost")
      guard client.stream_event(stream) is Response(_) else {
        fail("no HEADERS")
      }
      guard client.stream_event(stream) is Data(_) else {
        fail("no first event")
      }
      let reset_at = @async.now()
      client.conn.reset(stream, code=@http2.error_cancel)
      client.flush()
      let line = smock.transaction_lines(2)[1]
      out.push(mask_timestamp(line))
      out.push(
        "written at the reset, before the last event: \{written_at(line) - reset_at < 500}",
      )
      // Each was one request: no more lines come once their waits are over.
      @async.sleep(1200)
      out.push("lines in all: \{transactions(smock.stdout).length()}")
      out.push(smock.journal_endings())
      inspect(
        out.join("\n"),
        content=(
          #|{"app":"smock","environmentName":"slow","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/delayed","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
          #|written at the reset, before the delay is over: true
          #|{"app":"smock","environmentName":"slow","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/stream","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
          #|written at the reset, before the last event: true
          #|lines in all: 2
          #|GET /delayed: 200
          #|GET /stream: 200
        ),
      )
    })
  })
}

///|
async test "h2c: a close Fault ends the connection's other streams, and a stream whose response waited logs its planned status, as a client that goes away does" {
  with_definitions(fault_definitions(), dir => {
    let env = { "SMOCK_LOG_FORMAT": "mockoon" }
    let _ = with_smock(["--dir", dir, "--port", "0"], env~, smock => {
      let out = []
      let client = smock.h2c()
      defer client.close()
      let ticks = client.send("GET", "/ticks")
      let later = client.send("GET", "/later")
      let close = client.send("GET", "/close")
      for stream in [ticks, later, close] {
        let response = client.response(stream)
        out.push("stream \{stream}: \{response.status}, \{response.ended}")
      }
      let lines = smock.transaction_lines(3)
      out.push(masked_lines(lines))
      // The cut streams log no more once their waits would have ended.
      @async.sleep(700)
      out.push("lines in all: \{transactions(smock.stdout).length()}")
      // The cut streams' entries are committed as their tasks end, in
      // either order.
      let entries = smock
        .journal_endings()
        .split("\n")
        .map(e => e.to_string())
        .collect()
      entries.sort_by((a, b) => a.lexical_compare(b))
      out.push(entries.join("\n"))
      inspect(
        out.join("\n"),
        content=(
          #|stream 1: 200, closed
          #|stream 3: 0, closed
          #|stream 5: 0, closed
          #|{"app":"smock","environmentName":"m","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/ticks","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
          #|{"app":"smock","environmentName":"m","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/later","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
          #|{"app":"smock","environmentName":"m","fault":"close","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/close","requestProxied":false,"timestamp":"<timestamp>"}
          #|lines in all: 3
          #|GET /close: fault close
          #|GET /later: 200
          #|GET /ticks: 200
        ),
      )
    })
  })
}

///|
async test "h2c: a response the write timeout cuts logs its planned status when it is cut: a stream whose own window stays at zero at its RST_STREAM, a connection whose window stays at zero when it closes" {
  with_definitions(flow_definitions(), dir => {
    let env = { "SMOCK_LOG_FORMAT": "mockoon" }
    let _ = with_smock(
      ["--dir", dir, "--port", "0", "--write-timeout-ms", "500"],
      env~,
      smock => {
        let out = []
        // Stream windows of 0, with the connection window open: stream 1's
        // body waits for its own window until the write timeout resets it,
        // while stream 3's widens and its body goes out.
        let raw = smock.raw_h2(settings=false)
        defer raw.close()
        let start = @async.now()
        raw.send([
          Settings(params=[(@http2.settings_initial_window_size, 0)], ack=false),
          raw.get(1, "/item"),
          raw.get(3, "/item"),
          WindowUpdate(stream_id=3, increment=5),
        ])
        let frames = raw.frames_until(start, frame => frame is RstStream(..))
        out.push("stream 1 ended by \{frames.shown[frames.shown.length() - 1]}")
        let lines = smock.transaction_lines(2)
        out.push(masked_lines(lines))
        let reset_ms = written_at(lines[1]) - start
        out.push(
          "stream 1's line at its reset, after at least 500 ms: \{reset_ms >= 500}, within 2000 ms: \{reset_ms < 2000}",
        )
        // Wide stream windows, so that only the connection window of 65,535
        // octets holds the body back, until the write timeout closes the
        // connection.
        let raw = smock.raw_h2(settings=false)
        defer raw.close()
        let start = @async.now()
        raw.send([
          Settings(
            params=[(@http2.settings_initial_window_size, 1_000_000)],
            ack=false,
          ),
          raw.get(1, "/big"),
        ])
        let frames = raw.frames_until(start, _ => false)
        out.push("the connection ended by \{frames.how}")
        let line = smock.transaction_lines(3)[2]
        out.push(mask_timestamp(line))
        let closed_ms = written_at(line) - start
        out.push(
          "written when the connection closed, after at least 500 ms: \{closed_ms >= 500}, within 2000 ms: \{closed_ms < 2000}",
        )
        inspect(
          out.join("\n"),
          content=(
            #|stream 1 ended by RST_STREAM 1 CANCEL
            #|{"app":"smock","environmentName":"m","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/item","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
            #|{"app":"smock","environmentName":"m","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/item","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
            #|stream 1's line at its reset, after at least 500 ms: true, within 2000 ms: true
            #|the connection ended by a FIN
            #|{"app":"smock","environmentName":"m","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/big","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
            #|written when the connection closed, after at least 500 ms: true, within 2000 ms: true
          ),
        )
      },
    )
  })
}

///|
async test "h2c: a stream whose client closes the connection during its delay logs its planned status when the connection ends, as the Journal records it" {
  with_definitions([("slow.json", slow)], dir => {
    let env = { "SMOCK_LOG_FORMAT": "mockoon" }
    let _ = with_smock(["--dir", dir, "--port", "0"], env~, smock => {
      let out = []
      let client = smock.h2c()
      let _ = client.send("GET", "/delayed", authority="localhost")
      @async.sleep(200)
      let closed_at = @async.now()
      client.close()
      let line = smock.transaction_lines(1)[0]
      out.push(mask_timestamp(line))
      out.push(
        "written when the connection ended, before the delay is over: \{written_at(line) - closed_at < 500}",
      )
      @async.sleep(1000)
      out.push("lines in all: \{transactions(smock.stdout).length()}")
      out.push(smock.journal_endings())
      inspect(
        out.join("\n"),
        content=(
          #|{"app":"smock","environmentName":"slow","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/delayed","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
          #|written when the connection ended, before the delay is over: true
          #|lines in all: 1
          #|GET /delayed: 200
        ),
      )
    })
  })
}
