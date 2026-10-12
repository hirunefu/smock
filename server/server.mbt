///|
/// Runs `smock serve`: loads the definitions and the TLS certificate files,
/// or without them generates a self-signed certificate, listens on the
/// plain, the TLS and the admin port, and serves until the process is
/// stopped. The plain and TLS ports serve the same Mocks; the admin port
/// serves the Admin API.
///
/// Returns the exit status when it stops by itself: 1 when Admin API
/// authentication is on and no token is set, the definition set is invalid,
/// the default TLS certificate or a Mock's own cannot be loaded, the
/// self-signed certificate cannot be generated, or a port cannot be listened
/// on. Every problem is logged first.
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
  // Watching starts before the first load, so that no change made while it
  // reads the files goes unnoticed. Without a definitions directory, there
  // is nothing to watch and nothing to reload.
  let watch = match settings.dir {
    None => None
    Some(dir) => Some(@watch.Watch(dir))
  }
  defer (if watch is Some(watch) { watch.close() })
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
  // The directories of the certificate and key files are watched too, also
  // from before the first load.
  let tls_watches = []
  if settings.tls is Some(files) {
    let pairs = [files, ..settings.tls_mock_certs.values()]
    for dir in tls_dirs(pairs) {
      tls_watches.push((dir, @watch.Watch(dir)))
    }
  }
  defer tls_watches.each(watch => watch.1.close())
  let engine = @engine.Engine(
    snapshot,
    journal=@engine.JournalSettings(
      enabled=settings.journal,
      max_entries=settings.journal_max_entries,
      max_bytes=settings.journal_max_bytes,
      body_limit=settings.journal_body_limit,
    ),
  )
  let metrics = @metrics.Registry()
  let build = @buildinfo.current()
  build.register_metric(metrics)
  let reloads = register_reload_metric(metrics)
  let tls = match settings.tls {
    None => None
    Some(files) =>
      match
        Certificates::load(
          files,
          settings.tls_mock_certs,
          engine~,
          logger~,
          metrics~,
        ) {
        Some(certificates) => Some((files, certificates))
        None => return 1
      }
  }
  // The process generator. Its seed is logged, so that a run can be
  // replayed with --seed.
  let seed = match settings.seed {
    Some(seed) => seed
    None => random_seed()
  }
  let rand = @prng.Generator(seed)
  logger.info("random seed", fields={
    "seed": Json::number(seed.to_double(), repr=seed.to_string()),
  })
  // Without certificate files, the TLS port presents a self-signed
  // certificate generated for the Hosts served.
  let certificate = match tls {
    Some((_, certificates)) => Files(certificates)
    None =>
      match SelfSignedCertificate::generate(engine, logger) {
        Some(certificate) => SelfSigned(certificate)
        None => return 1
      }
  }
  let admin = Admin::new(
    engine,
    build,
    metrics~,
    journal_metrics=JournalMetrics::register(metrics),
    logger~,
    token~,
    replica=replica_name(),
    replicas=settings.replicas,
    session_header=settings.session_header,
    session_member=settings.session_member,
  )
  guard listen(logger, "plain", settings.port) is Some(plain) else { return 1 }
  defer plain.close()
  guard listen(logger, "tls", settings.tls_port) is Some(tls_listener) else {
    return 1
  }
  defer tls_listener.close()
  guard listen(logger, "admin", settings.admin_port) is Some(admin_listener) else {
    return 1
  }
  defer admin_listener.close()
  logger.info("listening", fields={
    "listener": "plain",
    "address": Json::string("0.0.0.0:\{plain.addr.port()}"),
  })
  let tls_fields : Map[String, Json] = {
    "listener": "tls",
    "address": Json::string("0.0.0.0:\{tls_listener.addr.port()}"),
  }
  if tls is Some((files, _)) {
    tls_fields["cert_file"] = Json::string(files.cert_file)
    tls_fields["key_file"] = Json::string(files.key_file)
  }
  logger.info("listening", fields=tls_fields)
  logger.info("listening", fields={
    "listener": "admin",
    "address": Json::string("0.0.0.0:\{admin_listener.addr.port()}"),
  })
  @async.with_task_group(group => {
    if watch is Some(watch) && settings.dir is Some(dir) {
      let reloader : Reloader = {
        dir,
        body_file_dir: settings.body_file_dir,
        engine,
        logger,
        reloads,
        last_read: (snapshot.digest, []),
        after_swap: () => certificate.after_swap(engine, logger),
      }
      group.spawn_bg(() => reloader.run(watch))
    }
    if tls is Some((_, certificates)) {
      for watch in tls_watches {
        let (dir, watch) = watch
        group.spawn_bg(() => certificates.run(dir, watch))
      }
    }
    group.spawn_bg(() => {
      accept_loop(group, plain, conn => {
        serve_mocks(conn, engine, rand, settings)
      })
    })
    group.spawn_bg(() => {
      accept_loop(group, tls_listener, conn => {
        // A connection that is still in its handshake has sent no request
        // bytes, so the idle timeout bounds the handshake too. It gets the
        // certificate presented when its handshake starts: a later one is
        // for later connections.
        let stream = @async.with_timeout_opt(settings.idle_timeout_ms, () => {
          TlsStream::accept(conn, name => certificate.select(name))
        })
        guard stream is Some(Some(stream)) else { return }
        serve_mocks(stream, engine, rand, settings)
        stream.shutdown()
      })
    })
    group.spawn_bg(() => {
      accept_loop(group, admin_listener, conn => {
        serve_connection(
          conn,
          settings,
          respond=(stream, request) => {
            @io.Writer::write(stream, admin.respond(request))
            request.keep_alive
          },
          reject=status => admin.reject(status),
        )
      })
    })
  })
  // The listeners serve until the process is stopped.
  0
}

///|
/// A seed for the process generator from the platform's entropy: an integer
/// from 0 to 2^53 - 1, like the seeds `--seed` takes.
fn random_seed() -> UInt64 {
  @random.Rand::new().uint64() & 0x1FFFFFFFFFFFFFUL
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
///
/// The engine's plan for a request may hold back the response by a delay:
/// the status line is written once the delay is over, and meanwhile other
/// connections are served as usual. A connection Fault in the plan ends the
/// connection instead of the response, or part of the way through it.
///
/// The request's Journal entry, if the engine returned one, is committed
/// just before the response's last bytes are written, so that a client
/// that has the whole response finds its request in the Journal: before
/// the last event of a stream of Server-Sent Events. A request that ends
/// otherwise, as with a connection Fault or a client that goes away, is
/// committed when it ends, before the connection closes. The entry's timing
/// is filled in last.
async fn[S : @io.Reader + @io.Writer] serve_mocks(
  stream : S,
  engine : @engine.Engine,
  rand : @prng.Generator,
  settings : @settings.ServeSettings,
) -> Unit {
  serve_connection(
    stream,
    settings,
    respond=(stream, request) => {
      let engine_request = to_engine_request(request)
      let session = @engine.session_of(
        engine_request.headers,
        header=settings.session_header,
        member_name=settings.session_member,
      )
      let outcome = engine.handle(
        engine_request,
        session~,
        now=@async.now(),
        rand~,
      )
      let plan = outcome.plan
      let pending = Ref(outcome.journal)
      let commit = () => {
        if pending.val is Some(entry) {
          pending.val = None
          engine.commit(entry)
        }
      }
      defer {
        commit()
        if outcome.journal is Some(entry) {
          entry.finish(at=@async.now())
        }
      }
      if plan.delay_ms > 0 {
        @async.sleep(plan.delay_ms)
      }
      match plan.fault {
        None => write_response(stream, plan, request, before_last=commit)
        // Closing the connection sends a FIN. The engine does not plan a
        // reset yet, since Definitions reject it.
        Some(Close) | Some(Reset) => false
        Some(Partial) => write_response(stream, plan, request, partial=true)
      }
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
/// - `respond` writes the response to each request to `stream`, or part of
///   it, and returns whether the connection stays open after it. While it
///   waits, the connection reads nothing, and other connections are served
///   as usual.
/// - `reject` gives the encoded response, with `Connection: close`, to
///   bytes that are not a valid request or are over a limit, with the status
///   the codec chose.
async fn[S : @io.Reader + @io.Writer] serve_connection(
  stream : S,
  settings : @settings.ServeSettings,
  respond~ : async (S, @http1.Request) -> Bool,
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
        if !respond(stream, request) {
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
    version: match request.version {
      Http10 => "HTTP/1.0"
      Http11 => "HTTP/1.1"
    },
    headers: request.headers.map(header => {
      (header.name, @utf8.decode_lossy(header.value))
    }),
    body: request.body,
  }
}

///|
/// Writes the response `plan` describes, as the answer to `request`, and
/// returns whether the connection stays open after it. With `partial`, as a
/// partial Fault, it writes the status line, the header fields and the
/// first half of the body, and the connection closes.
///
/// Server-Sent Events are streamed: the head at once, then each event after
/// its delay. Waiting suspends only this connection's task, so the others
/// are served meanwhile. A client that closes the connection mid-stream
/// makes a later write fail, which ends the stream and the connection. The
/// first half of a stream is the first half of its events, rounded down,
/// and a stream cut short is not ended: a chunked one lacks its last chunk.
///
/// `before_last` is called just before the response's last bytes are
/// written: before the whole response when it is written at once, and
/// before the last event of a stream, or its end when it has none. A
/// response cut short never calls it.
async fn[S : @io.Writer] write_response(
  stream : S,
  plan : @engine.ResponsePlan,
  request : @http1.Request,
  partial? : Bool = false,
  before_last? : () -> Unit = () => (),
) -> Bool {
  match plan.body {
    Bytes(body) => {
      let response = @http1.encode_response(
        plan.status,
        plan.headers,
        body,
        request~,
      )
      if partial {
        @io.Writer::write(stream, cut_short(response))
        return false
      }
      before_last()
      @io.Writer::write(stream, response)
      request.keep_alive
    }
    Events(events) => {
      let response = @http1.ResponseStream(plan.status, plan.headers, request~)
      @io.Writer::write(stream, response.head())
      let count = if partial { events.length() / 2 } else { events.length() }
      for i, event in events[:count] {
        if event.delay_ms > 0 {
          @async.sleep(event.delay_ms)
        }
        let data = @http1.encode_sse_event(
          event.data,
          event?=event.event,
          id?=event.id,
        )
        if !partial && i == count - 1 {
          before_last()
        }
        write_some(stream, response.part(data))
      }
      if partial {
        return false
      }
      if count == 0 {
        before_last()
      }
      write_some(stream, response.end())
      response.keeps_open()
    }
  }
}

///|
/// Writes `bytes` unless there are none, as for the body of a response to
/// HEAD.
async fn[S : @io.Writer] write_some(stream : S, bytes : Bytes) -> Unit {
  if bytes.length() > 0 {
    @io.Writer::write(stream, bytes)
  }
}

///|
/// The first part of the encoded `response`, as a partial Fault sends it:
/// the status line, the header fields and the first half of the body. The
/// head ends at the first empty line, since header values hold no CR or LF.
fn cut_short(response : Bytes) -> BytesView {
  let head = match response[:].find(b"\r\n\r\n") {
    Some(i) => i + 4
    None => response.length()
  }
  response[:head + (response.length() - head) / 2]
}
