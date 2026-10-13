///|
/// Runs `smock serve`: listens on the admin port, loads the definitions and
/// the TLS certificate files, generating a self-signed default certificate
/// without default files, then listens on the plain and the TLS port, and
/// serves until SIGTERM, then drains. The plain and TLS ports serve the
/// same Mocks; the admin port serves the Admin API and the probes, from
/// before the definitions load, so that the startup probe can tell that
/// they have not loaded yet, until the drain ends.
///
/// Returns the exit status: 0 after the drain, and 1 when Admin API
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
  // The directories of the certificate and key files are watched too, also
  // from before the first load.
  let tls_watches = []
  let pairs = match settings.tls {
    Some(files) => [files, ..settings.tls_mock_certs.values()]
    None => [..settings.tls_mock_certs.values()]
  }
  for dir in tls_dirs(pairs) {
    tls_watches.push(@watch.Watch(dir))
  }
  defer tls_watches.each(watch => watch.close())
  // The process generator. Its seed is logged, so that a run can be
  // replayed with --seed.
  let seed = match settings.seed {
    Some(seed) => seed
    None => @settings.random_seed()
  }
  let rand = @prng.Generator(seed)
  logger.info("random seed", fields={
    "seed": Json::number(seed.to_double(), repr=seed.to_string()),
  })
  let metrics = @metrics.Registry()
  let build = @buildinfo.current()
  build.register_metric(metrics)
  let reloads = register_reload_metric(metrics)
  let traffic = Traffic::register(metrics)
  let lifecycle = Lifecycle::new()
  let admin = Admin::new(
    lifecycle,
    build,
    metrics~,
    journal_metrics=JournalMetrics::register(metrics),
    logger~,
    token~,
    replica=replica_name(),
    replicas=settings.replicas,
    sessions={
      header: settings.session_header,
      member_name: settings.session_member,
    },
  )
  guard listen(logger, "admin", settings.admin_port) is Some(admin_listener) else {
    return 1
  }
  defer admin_listener.close()
  logger.info("listening", fields={
    "listener": "admin",
    "address": Json::string("0.0.0.0:\{admin_listener.addr.port()}"),
  })
  // The runtime cancels the whole program on SIGTERM, as on SIGINT and
  // SIGHUP. The watcher below notices that and starts the drain, while the
  // server runs protected from the cancellation, so that it can drain and
  // then return its exit status. Catching the cancellation keeps the runtime
  // from ending the process with the signal, so that it exits with that
  // status.
  let status = Ref(0)
  let _ = @async.handle_cancellation(() => {
    @async.with_task_group(group => {
      group.spawn_bg(no_wait=true, () => {
        let _ = @async.handle_cancellation(sleep_forever)
        lifecycle.drain()
      })
      group.spawn_bg(() => {
        status.val = @async.protect_from_cancel(() => {
          run(
            settings,
            logger,
            lifecycle,
            admin,
            admin_listener,
            metrics~,
            watch~,
            tls_watches~,
            rand~,
            reloads~,
            traffic~,
          )
        })
      })
    })
  })
  status.val
}

///|
/// Sleeps until the task is cancelled.
async fn sleep_forever() -> Unit {
  for ;; {
    @async.sleep(0x7fffffff)
  }
}

///|
/// Serves the Admin API on `admin_listener`, from now until it returns;
/// loads the definitions and the TLS certificates; listens on the plain and
/// the TLS port; serves the Mocks there until the drain starts; and drains.
/// Returns the exit status: 0 after the drain, or 1 when the definition set
/// is invalid, a TLS certificate cannot be loaded or generated, or a port
/// cannot be listened on.
///
/// The drain closes the plain and TLS listeners and the idle connections at
/// once. The responses in progress go on, and end with
/// `Connection: close`; Server-Sent Event streams and delays go on too. When
/// none is left, or when the drain timeout expires and cuts those still
/// open, the drain ends. The admin port serves throughout, so the probes can
/// be read during the drain.
async fn run(
  settings : @settings.ServeSettings,
  logger : @log.Logger,
  lifecycle : Lifecycle,
  admin : Admin,
  admin_listener : @socket.TcpServer,
  metrics~ : @metrics.Registry,
  watch~ : @watch.Watch?,
  tls_watches~ : Array[@watch.Watch],
  rand~ : @prng.Generator,
  reloads~ : @metrics.Counter,
  traffic~ : Traffic,
) -> Int {
  let connections = Connections::new()
  @async.with_task_group(group => {
    // The admin port serves until the end, and neither it nor its
    // connections keep smock from stopping.
    group.spawn_bg(no_wait=true, () => {
      accept_loop(admin_listener, conn => {
        group.spawn_bg(no_wait=true, allow_failure=true, () => {
          defer conn.close()
          serve_connection(
            conn,
            settings,
            respond=(stream, request) => {
              @io.Writer::write(stream, admin.respond(request))
              @http1.keeps_open(request~)
            },
            reject=status => admin.reject(status),
          )
        })
      })
    })
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
    let engine = @engine.Engine(
      snapshot,
      journal=@engine.JournalSettings(
        enabled=settings.journal,
        max_entries=settings.journal_max_entries,
        max_bytes=settings.journal_max_bytes,
        body_limit=settings.journal_body_limit,
      ),
    )
    lifecycle.started(engine)
    let ports : MockPorts = {
      engine,
      rand,
      settings,
      sessions: admin.sessions,
      traffic,
      lifecycle,
      logger,
    }
    // Without default certificate files, the TLS port presents a
    // self-signed certificate generated for the Hosts served, unless SNI
    // chooses a Mock's own.
    guard Certificates::load(
        settings.tls,
        settings.tls_mock_certs,
        engine~,
        logger~,
        metrics~,
      )
      is Some(certificates) else {
      return 1
    }
    guard listen(logger, "plain", settings.port) is Some(plain) else {
      return 1
    }
    guard listen(logger, "tls", settings.tls_port) is Some(tls_listener) else {
      plain.close()
      return 1
    }
    lifecycle.serving()
    logger.info("listening", fields={
      "listener": "plain",
      "address": Json::string("0.0.0.0:\{plain.addr.port()}"),
    })
    let tls_fields : Map[String, Json] = {
      "listener": "tls",
      "address": Json::string("0.0.0.0:\{tls_listener.addr.port()}"),
    }
    if settings.tls is Some(files) {
      add_file_fields(tls_fields, files)
    }
    logger.info("listening", fields=tls_fields)
    if watch is Some(watch) && settings.dir is Some(dir) {
      let reloader : Reloader = {
        dir,
        body_file_dir: settings.body_file_dir,
        engine,
        logger,
        reloads,
        last_read: (snapshot.digest, []),
        after_swap: () => certificates.after_swap(),
      }
      group.spawn_bg(no_wait=true, () => reloader.run(watch))
    }
    for watch in tls_watches {
      group.spawn_bg(no_wait=true, () => certificates.run(watch))
    }
    let listening = group.spawn(() => {
      @async.with_task_group(listeners => {
        listeners.spawn_bg(() => {
          defer plain.close()
          accept_loop(plain, conn => {
            connections.serve(group, conn, connection => {
              let _ = ports.serve(conn, conn, connection)
            })
          })
        })
        listeners.spawn_bg(() => {
          defer tls_listener.close()
          accept_loop(tls_listener, conn => {
            connections.serve(group, conn, connection => {
              // A connection that is still in its handshake has sent no
              // request bytes, so the idle timeout bounds the handshake too.
              // It gets the certificate presented when its handshake
              // starts: a later one is for later connections.
              let stream = @async.with_timeout_opt(settings.idle_timeout_ms, () => {
                TlsStream::accept(conn, name => certificates.select(name))
              })
              guard stream is Some(Some(stream)) else { return }
              let was_reset = ports.serve(stream, conn, connection)
              // A reset sends no close_notify: the RST alone ends the
              // connection.
              if !was_reset {
                stream.shutdown()
              }
            })
          })
        })
      })
    })
    lifecycle.wait_for_drain()
    logger.info("drain started", fields={
      "timeoutMs": Json::number(settings.drain_timeout_ms.to_double()),
    })
    // Cancelling the accept loops closes the listeners, so that new
    // connections are refused.
    listening.cancel()
    listening.wait() catch {
      _ => ()
    }
    connections.close_idle()
    let ended = @async.with_timeout_opt(settings.drain_timeout_ms, () => {
      connections.wait_all_ended()
    })
    let cut = if ended is Some(_) { 0 } else { connections.cut() }
    logger.info("drain ended", fields={
      "connectionsCut": Json::number(cut.to_double()),
    })
    0
  })
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
/// Accepts connections on `listener` and hands each one to `serve`, which
/// serves it in a task of its own, until the task is cancelled.
async fn accept_loop(
  listener : @socket.TcpServer,
  serve : (@socket.Tcp) -> Unit,
) -> Unit {
  for ;; {
    let (conn, _) = listener.accept()
    serve(conn)
  }
}

///|
/// What the plain and the TLS port serve the Mocks with, the same for every
/// connection.
priv struct MockPorts {
  engine : @engine.Engine
  /// The process generator, which Faults of Stubs without a seed of their
  /// own draw from.
  rand : @prng.Generator
  settings : @settings.ServeSettings
  /// Where requests carry their Session, as Admin API calls carry it.
  sessions : SessionCarrier
  /// Where each request is counted.
  traffic : Traffic
  /// Whether smock drains.
  lifecycle : Lifecycle
  logger : @log.Logger
}

///|
/// Serves the requests for the Mocks that arrive on one connection of the
/// plain or the TLS port: `stream`, which reads and writes through `tcp`,
/// the connection's socket. Returns whether a reset Fault ended it: closing
/// `tcp` then resets the connection with an RST, and the caller must write
/// nothing more to it.
///
/// The engine's plan for a request may hold back the response by a delay:
/// the status line is written once the delay is over, and meanwhile other
/// connections are served as usual. A connection Fault in the plan ends the
/// connection instead of the response, or part of the way through it. A
/// reset comes once the whole request, body included, has been read, and
/// nothing is written before it; when it cannot be set up, the failure is
/// logged and the connection closes as for a close Fault.
///
/// The request's Journal entry, if the engine returned one, is committed
/// just before the response's last bytes are written, so that a client
/// that has the whole response finds its request in the Journal: before
/// the last event of a stream of Server-Sent Events. A request that ends
/// otherwise, as with a connection Fault or a client that goes away, is
/// committed when it ends, before the connection closes. The entry's timing
/// is filled in then.
///
/// Each request is counted in the traffic metrics once its response is
/// written, or once the connection ends before it is, with the time from
/// the request being read in full to then. Nothing is counted before the
/// response, so counting never holds one back.
///
/// While smock drains, a response says `Connection: close`, and the
/// connection closes after it.
async fn[S : @io.Reader + @io.Writer] MockPorts::serve(
  self : MockPorts,
  stream : S,
  tcp : @socket.Tcp,
  connection : Connection,
) -> Bool {
  let was_reset = Ref(false)
  serve_connection(
    stream,
    self.settings,
    connection~,
    respond=(stream, request) => {
      // The request has just been read in full.
      let stopwatch = Stopwatch::start()
      let engine_request = to_engine_request(request)
      let session = self.sessions.session_of(engine_request.headers)
      let outcome = self.engine.handle(
        engine_request,
        session~,
        now=@async.now(),
        rand=self.rand,
      )
      defer self.traffic.record(outcome, stopwatch.seconds())
      let plan = outcome.plan
      let pending = Ref(outcome.journal)
      let commit = () => {
        if pending.val is Some(entry) {
          pending.val = None
          self.engine.commit(entry)
        }
      }
      // Deferred after the count, so it runs before it.
      defer {
        commit()
        if outcome.journal is Some(entry) {
          entry.finish(at=@async.now())
        }
      }
      if plan.delay_ms > 0 {
        @async.sleep(plan.delay_ms)
      }
      let keep_open = match plan.fault {
        None =>
          write_response(
            stream,
            plan,
            request,
            close=self.lifecycle.is_draining(),
            before_last=commit,
          )
        // Closing the connection sends an RST, once the Journal entry is
        // committed, so that a client that sees the reset finds it there.
        Some(Reset) => {
          was_reset.val = reset_on_close(tcp, self.logger)
          false
        }
        // Closing the connection sends a FIN.
        Some(Close) => false
        Some(Partial) => write_response(stream, plan, request, partial=true)
      }
      // A response that began before the drain, such as a stream, and ends
      // during it closes its connection too.
      keep_open && !self.lifecycle.is_draining()
    },
    reject=status => @http1.encode_response(status, [], b"", close=true),
  )
  was_reset.val
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
/// - `connection`, when given, is kept told whether the connection is idle,
///   so that a drain can close it.
async fn[S : @io.Reader + @io.Writer] serve_connection(
  stream : S,
  settings : @settings.ServeSettings,
  respond~ : async (S, @http1.Request) -> Bool,
  reject~ : (Int) -> Bytes,
  connection? : Connection,
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
        if connection is Some(connection) {
          connection.idle = !parser.in_request()
        }
        let read = @async.with_timeout_opt(remaining.to_int(), () => {
          @io.Reader::read(stream, buf)
        })
        if connection is Some(connection) {
          connection.idle = false
        }
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
    headers: decoded_headers(request),
    body: request.body,
  }
}

///|
/// The header fields of `request`, with their values decoded as UTF-8 and
/// invalid bytes replaced by U+FFFD.
fn decoded_headers(request : @http1.Request) -> Array[(String, String)] {
  request.headers.map(header => (header.name, @utf8.decode_lossy(header.value)))
}

///|
/// Where requests carry their Session: a member of a header in W3C Baggage
/// form, as `--session-header` and `--session-member` name them. Requests
/// to the Mocks and Admin API calls carry it the same way.
priv struct SessionCarrier {
  header : String
  member_name : String
}

///|
/// The Session `headers` carry, or `None` for the no-Session space.
fn SessionCarrier::session_of(
  self : SessionCarrier,
  headers : Array[(String, String)],
) -> String? {
  @engine.session_of(headers, header=self.header, member_name=self.member_name)
}

///|
/// Writes the response `plan` describes, as the answer to `request`, and
/// returns whether the connection stays open after it. With `close`, the
/// response says `Connection: close`, and the connection closes after it.
/// With `partial`, as a partial Fault, it writes the status line, the header
/// fields and the first half of the body, and the connection closes.
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
  close? : Bool = false,
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
        close~,
      )
      if partial {
        @io.Writer::write(stream, cut_short(response))
        return false
      }
      before_last()
      @io.Writer::write(stream, response)
      @http1.keeps_open(request~, close~)
    }
    Events(events) => {
      let response = @http1.ResponseStream(
        plan.status,
        plan.headers,
        request~,
        close~,
      )
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
