///|
/// Runs `smock serve`: loads the definitions and the TLS certificate, if
/// any, listens on the plain port and, with a certificate, on the TLS port,
/// and serves until the process is stopped. Both ports serve the same Mocks.
///
/// Returns the exit status when it stops by itself: 1 when the definition
/// set is invalid, the TLS certificate cannot be loaded or a port cannot be
/// listened on. Every problem is logged first.
pub async fn serve(
  settings : @settings.ServeSettings,
  logger : @log.Logger,
) -> Int {
  let snapshot = match
    @defdir.load(settings.dir, body_file_dir=settings.body_file_dir) {
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
  let tls = match settings.tls {
    None => None
    Some(files) =>
      match load_tls(files) {
        Ok(config) => Some((files, config))
        Err(message) => {
          logger.error("cannot load the TLS certificate", fields={
            "cert_file": Json::string(files.cert_file),
            "key_file": Json::string(files.key_file),
            "error": Json::string(message),
          })
          return 1
        }
      }
  }
  let engine = @engine.Engine(snapshot)
  let rand = @random.Rand::new()
  guard listen(logger, "plain", settings.port) is Some(plain) else { return 1 }
  defer plain.close()
  let tls_listener = match tls {
    None => None
    Some(_) => {
      guard listen(logger, "tls", settings.tls_port) is Some(listener) else {
        return 1
      }
      Some(listener)
    }
  }
  defer (if tls_listener is Some(listener) { listener.close() })
  logger.info("listening", fields={
    "listener": "plain",
    "address": Json::string("0.0.0.0:\{plain.addr.port()}"),
  })
  if tls is Some((files, _)) && tls_listener is Some(listener) {
    logger.info("listening", fields={
      "listener": "tls",
      "address": Json::string("0.0.0.0:\{listener.addr.port()}"),
      "cert_file": Json::string(files.cert_file),
      "key_file": Json::string(files.key_file),
    })
  }
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      accept_loop(group, plain, conn => serve_connection(conn, engine, rand))
    })
    if tls is Some((_, config)) && tls_listener is Some(listener) {
      group.spawn_bg(() => {
        accept_loop(group, listener, conn => {
          guard TlsStream::accept(conn, config) is Some(stream) else { return }
          serve_connection(stream, engine, rand)
          stream.shutdown()
        })
      })
    }
  })
  // The listeners serve until the process is stopped.
  0
}

///|
/// Listens on `port` of every IPv4 address, or logs why it cannot.
async fn listen(
  logger : @log.Logger,
  listener : String,
  port : Int,
) -> @socket.TcpServer? {
  let address = "0.0.0.0:\{port}"
  try @socket.TcpServer(@socket.Addr::parse(address), reuse_addr=true) catch {
    err => {
      logger.error("cannot listen", fields={
        "listener": Json::string(listener),
        "address": Json::string(address),
        "error": Json::string(err.to_string()),
      })
      None
    }
  } noraise {
    server => Some(server)
  }
}

///|
/// Accepts connections on `listener` and serves each one with `handle` in
/// its own task of `group`. A connection that fails ends alone: the others
/// carry on.
async fn[X] accept_loop(
  group : @async.TaskGroup[X],
  listener : @socket.TcpServer,
  handle : async (@socket.Tcp) -> Unit,
) -> Unit {
  for ;; {
    let (conn, _) = listener.accept()
    group.spawn_bg(allow_failure=true, () => {
      defer conn.close()
      handle(conn)
    })
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
