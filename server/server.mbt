///|
/// Runs `smock serve`: loads the definitions, listens on the plain port and
/// serves until the process is stopped.
///
/// Returns the exit status when it stops by itself: 1 when the definition
/// set is invalid or the port cannot be listened on. Every problem is
/// logged first.
pub async fn serve(
  settings : @settings.ServeSettings,
  logger : @log.Logger,
) -> Int {
  let snapshot = match load(settings) {
    Ok(snapshot) => snapshot
    Err(diagnostics) => {
      for diagnostic in diagnostics {
        logger.error("invalid definitions", fields={
          "file": Json::string(diagnostic.file),
          "pointer": Json::string(diagnostic.pointer),
          "error": Json::string(diagnostic.message),
        })
      }
      return 1
    }
  }
  let engine = @engine.Engine(snapshot)
  let rand = @random.Rand::new()
  let address = "0.0.0.0:\{settings.port}"
  let listener = @socket.TcpServer(
    @socket.Addr::parse(address),
    reuse_addr=true,
  ) catch {
    err => {
      logger.error("cannot listen", fields={
        "listener": "plain",
        "address": Json::string(address),
        "error": Json::string(err.to_string()),
      })
      return 1
    }
  }
  defer listener.close()
  logger.info("listening", fields={
    "listener": "plain",
    "address": Json::string("0.0.0.0:\{listener.addr.port()}"),
  })
  @async.with_task_group(group => {
    for ;; {
      let (conn, _) = listener.accept()
      group.spawn_bg(allow_failure=true, () => {
        defer conn.close()
        serve_connection(conn, engine, rand)
      })
    }
  })
}

///|
/// Reads the definitions directory, if any, and builds the snapshot.
async fn load(
  settings : @settings.ServeSettings,
) -> Result[@definitions.Snapshot, Array[@definitions.Diagnostic]] {
  let (set, read_problems) = match settings.dir {
    Some(dir) => @defdir.read(dir, body_file_dir=settings.body_file_dir)
    None => ({ files: [], body_files: [], }, [])
  }
  match @definitions.load(set) {
    Ok(snapshot) if read_problems.length() == 0 => Ok(snapshot)
    Ok(_) => Err(read_problems)
    Err(problems) => Err([..read_problems, ..problems])
  }
}

///|
/// Serves the requests that arrive on one connection, in turn, until the
/// client closes it, a request asks to close it, or a request cannot be
/// parsed.
///
/// It reads and writes only through `stream`, so the same loop serves any
/// byte stream: a TCP connection, or a TLS session on top of one.
async fn[S : @io.Reader + @io.Writer] serve_connection(
  stream : S,
  engine : @engine.Engine,
  rand : @random.Rand,
) -> Unit {
  let parser = @http1.Parser()
  let buf = FixedArray::make(16 * 1024, b'\x00')
  for ;; {
    match parser.next() {
      Complete(request) => {
        let outcome = engine.handle(
          to_engine_request(request),
          // Sessions come with the "Sessions and Ephemeral Stubs" ticket.
          session=None,
          now=@async.now(),
          rand~,
        )
        let close = !request.keep_alive
        @io.Writer::write(stream, encode(outcome.plan, close~))
        if close {
          return
        }
      }
      NeedMore => {
        let n = @io.Reader::read(stream, buf)
        if n == 0 {
          return
        }
        parser.feed(buf.unsafe_reinterpret_as_bytes()[:n])
      }
      Invalid(status~) => {
        @io.Writer::write(
          stream,
          @http1.encode_response(status, [("Connection", "close")], b""),
        )
        return
      }
    }
  }
}

///|
/// The engine's view of a parsed request. Header values are decoded as
/// UTF-8, with invalid bytes replaced by U+FFFD.
fn to_engine_request(request : @http1.Request) -> @engine.Request {
  {
    meth: request.meth,
    target: request.target,
    headers: request.headers.map(header => {
      (header.name, @utf8.decode_lossy(header.value))
    }),
    body: request.body,
  }
}

///|
/// The bytes of the response `plan` describes. Delays, connection Faults
/// and Server-Sent Events come with their own tickets; the engine does not
/// plan them yet.
fn encode(plan : @engine.ResponsePlan, close~ : Bool) -> Bytes {
  let body = match plan.body {
    Bytes(body) => body
    Events(_) => b""
  }
  let headers = if close {
    [..plan.headers, ("Connection", "close")]
  } else {
    plan.headers
  }
  @http1.encode_response(plan.status, headers, body)
}
