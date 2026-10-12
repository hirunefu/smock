///|
/// Runs `smock serve`: loads the definitions and the TLS certificate, if
/// any, listens on the plain port, on the admin port and, with a
/// certificate, on the TLS port, and serves until the process is stopped.
/// The plain and TLS ports serve the same Mocks; the admin port serves the
/// Admin API.
///
/// Returns the exit status when it stops by itself: 1 when Admin API
/// authentication is on and no token is set, the definition set is invalid,
/// the TLS certificate cannot be loaded or a port cannot be listened on.
/// Every problem is logged first.
pub async fn serve(
  settings : @settings.ServeSettings,
  logger : @log.Logger,
) -> Int {
  let token = if settings.admin_auth {
    match read_admin_token(settings, logger) {
      Some(token) => Some(token)
      None => return 1
    }
  } else {
    None
  }
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
  let admin = Admin::new(
    engine,
    @buildinfo.current(),
    token~,
    replica=replica_name(),
    replicas=settings.replicas,
  )
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
  guard listen(logger, "admin", settings.admin_port) is Some(admin_listener) else {
    return 1
  }
  defer admin_listener.close()
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
  logger.info("listening", fields={
    "listener": "admin",
    "address": Json::string("0.0.0.0:\{admin_listener.addr.port()}"),
  })
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      accept_loop(group, plain, conn => {
        serve_mocks(conn, engine, rand, settings)
      })
    })
    if tls is Some((_, config)) && tls_listener is Some(listener) {
      group.spawn_bg(() => {
        accept_loop(group, listener, conn => {
          // A connection that is still in its handshake has sent no
          // request bytes, so the idle timeout bounds the handshake too.
          let stream = @async.with_timeout_opt(settings.idle_timeout_ms, () => {
            TlsStream::accept(conn, config)
          })
          guard stream is Some(Some(stream)) else { return }
          serve_mocks(stream, engine, rand, settings)
          stream.shutdown()
        })
      })
    }
    group.spawn_bg(() => {
      accept_loop(group, admin_listener, conn => {
        serve_connection(
          conn,
          settings,
          respond=request => admin.respond(request),
          reject=status => admin.reject(status),
        )
      })
    })
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
/// Serves the requests for the Mocks that arrive on one connection of the
/// plain or the TLS port.
async fn[S : @io.Reader + @io.Writer] serve_mocks(
  stream : S,
  engine : @engine.Engine,
  rand : @random.Rand,
  settings : @settings.ServeSettings,
) -> Unit {
  serve_connection(
    stream,
    settings,
    respond=request => {
      let outcome = engine.handle(
        to_engine_request(request),
        // Sessions come with the "Sessions and Ephemeral Stubs" ticket.
        session=None,
        now=@async.now(),
        rand~,
      )
      encode(outcome.plan, request)
    },
    reject=status => @http1.encode_response(status, [], b"", close=true),
  )
}

///|
/// Serves the requests that arrive on one connection, in turn, until the
/// client closes it, a request asks to close it, a request cannot be parsed
/// or is over a limit, or a timeout runs out:
///
/// - the idle timeout, while the connection waits for a request: from when
///   it opens, then from each response;
/// - the read timeout, while a request arrives: from its first byte until
///   all of it, body included, has arrived.
///
/// It reads and writes only through `stream`, so the same loop serves any
/// byte stream: a TCP connection, or a TLS session on top of one. Nothing is
/// logged per request.
///
/// - `respond` gives the encoded response to each request.
/// - `reject` gives the encoded response, with `Connection: close`, to
///   bytes that are not a valid request or are over a limit, with the status
///   the codec chose.
async fn[S : @io.Reader + @io.Writer] serve_connection(
  stream : S,
  settings : @settings.ServeSettings,
  respond~ : (@http1.Request) -> Bytes,
  reject~ : (Int) -> Bytes,
) -> Unit {
  let parser = @http1.Parser(
    header_size_limit=settings.header_size_limit,
    header_count_limit=settings.header_count_limit,
    body_limit=settings.body_limit,
  )
  let buf = FixedArray::make(16 * 1024, b'\x00')
  let idle_timeout = settings.idle_timeout_ms.to_int64()
  let read_timeout = settings.read_timeout_ms.to_int64()
  let mut idle_deadline = @async.now() + idle_timeout
  let mut read_deadline : Int64? = None
  let mut last_read = @async.now()
  for ;; {
    match parser.next() {
      Complete(request) => {
        @io.Writer::write(stream, respond(request))
        if !request.keep_alive {
          return
        }
        idle_deadline = @async.now() + idle_timeout
        read_deadline = None
      }
      Continue =>
        @io.Writer::write(stream, @http1.encode_response(100, [], b""))
      NeedMore => {
        let deadline = if parser.in_request() {
          // The request began with the bytes of the last read, or earlier.
          let deadline = read_deadline.unwrap_or(last_read + read_timeout)
          read_deadline = Some(deadline)
          deadline
        } else {
          read_deadline = None
          idle_deadline
        }
        let remaining = deadline - @async.now()
        if remaining <= 0L {
          return
        }
        let read = @async.with_timeout_opt(remaining.to_int(), () => {
          @io.Reader::read(stream, buf)
        })
        guard read is Some(n) && n > 0 else { return }
        last_read = @async.now()
        parser.feed(buf.unsafe_reinterpret_as_bytes()[:n])
      }
      Invalid(status~) => {
        @io.Writer::write(stream, reject(status))
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
/// The bytes of the response `plan` describes, as the answer to `request`.
/// Delays, connection Faults and Server-Sent Events come with their own
/// tickets; the engine does not plan them yet.
fn encode(plan : @engine.ResponsePlan, request : @http1.Request) -> Bytes {
  let body = match plan.body {
    Bytes(body) => body
    Events(_) => b""
  }
  @http1.encode_response(plan.status, plan.headers, body, request~)
}
