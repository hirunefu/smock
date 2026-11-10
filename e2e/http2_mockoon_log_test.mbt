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
        .map(e => e.to_owned())
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

///|
async test "h2c: a stream and a delayed response that the drain timeout cuts each log the planned status when they are cut, before drain ended and Server stopped" {
  with_definitions([("m.json", drain_defs)], dir => {
    let env = {
      "SMOCK_LOG_FORMAT": "mockoon",
      "SMOCK_DRAIN_TIMEOUT_MS": "1500",
    }
    let stopped = with_smock(["--dir", dir, "--port", "0"], env~, smock => {
      let client = smock.h2c()
      defer client.close()
      let ticks = client.send("GET", "/ticks", authority="localhost")
      guard client.stream_event(ticks) is Response(_) else {
        fail("no HEADERS")
      }
      let _ = client.send("GET", "/stalled", authority="localhost")
      @async.sleep(settle_ms)
      let start = @async.now()
      smock.terminate()
      let status = smock.exited()
      let lines = smock.transaction_lines(2)
      let cut = lines
        .iter()
        .all(line => (written_at(line) - start >= 1500) catch { _ => false })
      inspect(
        (
          $|\{masked_lines(lines)}
          $|written once the drain timeout cut them: \{cut}
          $|exit status \{status}
        ),
        content=(
          #|{"app":"smock","environmentName":"m","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/ticks","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
          #|{"app":"smock","environmentName":"m","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/stalled","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
          #|written once the drain timeout cut them: true
          #|exit status 0
        ),
      )
    })
    // The lines of the drain, in order: the cut requests' lines come
    // before the drain ends.
    guard stopped.stdout.search_by(line => message_of(line) == "drain started")
      is Some(started) else {
      fail("no drain started line:\n\{stopped.stdout.join("\n")}")
    }
    inspect(
      stopped.stdout[started:].map(message_of).join("\n"),
      content=(
        #|drain started
        #|Transaction recorded
        #|Transaction recorded
        #|drain ended
        #|Server stopped
      ),
    )
  })
}

///|
async test "h2c: a template failure and a data write failure write the error line, then the Transaction recorded line, in place, after a delay, and when a reset Fault replaces the 500, with the Journal off" {
  with_definitions(failing_shop(), dir => {
    let env = { "SMOCK_LOG_FORMAT": "mockoon", "SMOCK_JOURNAL": "off" }
    let _ = with_smock(["--dir", dir, "--port", "0"], env~, smock => {
      let client = smock.h2c()
      defer client.close()
      let out = []
      let requests = [
        ("/orders", "{\"customer\":{}}"),
        ("/visits", ""),
        ("/slow-orders", "{}"),
        ("/reset-orders", "{}"),
      ]
      for request in requests {
        let (path, body) = request
        let response = client.request("POST", path, body=@utf8.encode(body))
        out.push("\{path}: \{response.status}, \{response.ended}")
      }
      smock.transaction_lines(4) |> ignore
      let lines = served_lines(smock.stdout)
      // Each line takes its own time, and the error line comes first.
      let mut ordered = true
      for i in 0..<(lines.length() / 2) {
        if written_at(lines[2 * i]) > written_at(lines[2 * i + 1]) {
          ordered = false
        }
      }
      out.push(masked_lines(lines))
      out.push(
        "each error line written at or before its Transaction recorded line: \{ordered}",
      )
      inspect(
        out.join("\n"),
        content=(
          #|/orders: 500, end
          #|/visits: 500, end
          #|/slow-orders: 500, end
          #|/reset-orders: 0, reset INTERNAL_ERROR
          #|{"app":"smock","environmentName":"shop","level":"error","message":"Error while serving the content: body.customer.name is missing","routePath":"/orders","routeUUID":"create-order","timestamp":"<timestamp>"}
          #|{"app":"smock","environmentName":"shop","level":"info","message":"Transaction recorded","requestMethod":"POST","requestPath":"/orders","requestProxied":false,"responseStatus":500,"timestamp":"<timestamp>"}
          #|{"app":"smock","environmentName":"shop","level":"error","message":"Error while serving the content: the Data bucket \"visits\" holds a number, and \"merge\" needs an object","routePath":"/visits","routeUUID":"visit","timestamp":"<timestamp>"}
          #|{"app":"smock","environmentName":"shop","level":"info","message":"Transaction recorded","requestMethod":"POST","requestPath":"/visits","requestProxied":false,"responseStatus":500,"timestamp":"<timestamp>"}
          #|{"app":"smock","environmentName":"shop","level":"error","message":"Error while serving the content: body.customer.name is missing","routePath":"/slow-orders","routeUUID":"slow-order","timestamp":"<timestamp>"}
          #|{"app":"smock","environmentName":"shop","level":"info","message":"Transaction recorded","requestMethod":"POST","requestPath":"/slow-orders","requestProxied":false,"responseStatus":500,"timestamp":"<timestamp>"}
          #|{"app":"smock","environmentName":"shop","level":"error","message":"Error while serving the content: body.customer.name is missing","routePath":"/reset-orders","routeUUID":"reset-order","timestamp":"<timestamp>"}
          #|{"app":"smock","environmentName":"shop","fault":"reset","level":"info","message":"Transaction recorded","requestMethod":"POST","requestPath":"/reset-orders","requestProxied":false,"timestamp":"<timestamp>"}
          #|each error line written at or before its Transaction recorded line: true
        ),
      )
    })
  })
}

///|
async test "h2c: a stream smock refuses before it reaches a Mock (431, 413, 400, REFUSED_STREAM) or that the client resets before its request ends gets no Transaction recorded line" {
  with_definitions([("slow.json", slow)], dir => {
    let env = { "SMOCK_LOG_FORMAT": "mockoon" }
    let args = [
      "--dir", dir, "--port", "0", "--http2-max-concurrent-streams", "1", "--header-size-limit",
      "400", "--body-limit", "10",
    ]
    let _ = with_smock(args, env~, smock => {
      let client = smock.h2c()
      defer client.close()
      let out = []
      let big = client.request("GET", "/quick", authority="localhost", headers=[
        ("x-big", "x".repeat(500)),
      ])
      out.push("a header list over the limit: \{big.status}, \{big.ended}")
      let malformed = client.request("GET", "/quick", authority="localhost", headers=[
        ("host", "elsewhere.example.com"),
      ])
      out.push(
        "a host that differs from :authority: \{malformed.status}, \{malformed.ended}",
      )
      let unfinished = client.send(
        "POST",
        "/quick",
        authority="localhost",
        end=false,
      )
      client.conn.reset(unfinished, code=@http2.error_cancel)
      client.flush()
      // Last, since the client counts the stream open until it reads the
      // RST_STREAM NO_ERROR that follows the 413.
      let over = client.send(
        "POST",
        "/quick",
        authority="localhost",
        headers=[("content-length", "100")],
        end=false,
      )
      let over = client.response(over)
      out.push("a body over the limit: \{over.status}, \{over.ended}")
      // A client of its own, since moonhttp's client opens no stream past
      // the limit: stream 3 comes while stream 1 waits for its delay.
      let raw = smock.raw_h2()
      defer raw.close()
      raw.send([
        headers_frame(
          1,
          raw.block(request_fields("GET", "/delayed", "localhost")),
        ),
        headers_frame(
          3,
          raw.block(request_fields("GET", "/quick", "localhost")),
        ),
      ])
      out.push(raw.frames_until_stream_ends(1))
      // Only the delayed stream reached a Mock.
      @async.sleep(settle_ms)
      out.push(masked_lines(transactions(smock.stdout)))
      out.push(smock.journal_endings())
      inspect(
        out.join("\n"),
        content=(
          #|a header list over the limit: 431, end
          #|a host that differs from :authority: 400, end
          #|a body over the limit: 413, end
          #|SETTINGS [MAX_CONCURRENT_STREAMS=1, MAX_HEADER_LIST_SIZE=800]
          #|SETTINGS ACK
          #|RST_STREAM 3 REFUSED_STREAM
          #|HEADERS 1 END_HEADERS [:status: 200, smock-mock: slow; via=default, date: <now>, content-length: 4]
          #|DATA 1 END_STREAM 4 octets
          #|{"app":"smock","environmentName":"slow","level":"info","message":"Transaction recorded","requestMethod":"GET","requestPath":"/delayed","requestProxied":false,"responseStatus":200,"timestamp":"<timestamp>"}
          #|GET /delayed: 200
        ),
      )
    })
  })
}

///|
async test "h2c and h2: with no request refused, the Transaction recorded lines number the requests that smock_requests_total counts" {
  with_definitions([("m.json", faults)], dir => {
    with_certificates(certs => {
      let args = ["--dir", dir, "--port", "0", ..certs.args()]
      let env = { "SMOCK_LOG_FORMAT": "mockoon" }
      // Requests that end every way: a whole response, a 404, a reset and a
      // partial Fault on one connection; a close Fault on one of its own;
      // and a client that closes its connection during a delay.
      let stopped = with_smock(args, env~, smock => {
        for tls in [false, true] {
          let client = if tls { smock.h2() } else { smock.h2c() }
          defer client.close()
          for path in ["/fast", "/nope", "/reset", "/partial"] {
            let _ = client.request("GET", path, authority="localhost")
          }
          let closing = if tls { smock.h2() } else { smock.h2c() }
          defer closing.close()
          let _ = closing.request("GET", "/close", authority="localhost")
          let gone = if tls { smock.h2() } else { smock.h2c() }
          let _ = gone.send("GET", "/slow", authority="localhost")
          @async.sleep(settle_ms)
          gone.close()
        }
        let lines = smock.transaction_lines(12).length()
        let mut counted = 0.0
        for sample in smock.metrics().1 {
          if sample.name == "smock_requests_total" {
            counted += sample.value
          }
        }
        inspect(
          "requests counted: \{counted}\nlines: \{lines}",
          content=(
            #|requests counted: 12
            #|lines: 12
          ),
        )
      })
      inspect(
        transactions(stopped.stdout).length(),
        content=(
          #|12
        ),
      )
    })
  })
}
