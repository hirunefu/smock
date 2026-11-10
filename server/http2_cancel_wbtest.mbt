///|
/// The Mock ports of an empty definition set with the default settings, in
/// the mockoon log format, whose lines go nowhere.
fn mockoon_ports() -> MockPorts raise {
  let settings = @settings.ServeSettings::from_matches(
    @settings.serve_command().parse(argv=[], env={}),
  )
  guard @definitions.load({ files: [], body_files: [], }) is Ok(snapshot) else {
    abort("an empty definition set is valid")
  }
  let engine = @engine.Engine(snapshot)
  let lifecycle = Lifecycle::new()
  lifecycle.started(engine)
  let stdout = StdoutLines::writing_to(_ => ())
  {
    engine,
    rand: @prng.Generator(1),
    settings,
    sessions: {
      header: settings.session_header,
      member_name: settings.session_member,
    },
    dates: @http1.DateCache(),
    traffic: Traffic::register(@metrics.Registry()),
    lifecycle,
    logger: @log.Logger(write_line=_ => (), now=() => 0L),
    mockoon: Some(MockoonLines::new(engine, stdout)),
  }
}

///|
async test "an HTTP/2 connection whose task is cancelled as its TLS handshake or its preface check ends stops at once, in the mockoon log format too" {
  // The drain or a cut can cancel a connection's task just as its TLS
  // handshake, run under with_timeout_opt, or its preface check, run in a
  // task group, ends: here the work inside each cancels the task. Both
  // still return normally, to a task that is cancelled, which goes on into
  // serve_http2. That returns at once, rather than enter a task group,
  // which would be cancelled before its body ran, and on which the
  // mockoon log format's `add_defer` aborted the process.
  let ports = mockoon_ports()
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer listener.close()
  let client = @socket.Tcp::connect(listener.addr)
  defer client.close()
  let (conn, _) = listener.accept()
  defer conn.close()
  let out = []
  for way in ["TLS handshake", "preface check"] {
    let task : Ref[@async.Task[Unit]?] = Ref(None)
    let cancel = () => if task.val is Some(task) { task.cancel() }
    let connection : Connection = { idle: true, drain: None, task: None, }
    @async.with_task_group(group => {
      task.val = Some(
        group.spawn(() => {
          if way == "TLS handshake" {
            let _ = @async.with_timeout_opt(1000, () => cancel())
          } else {
            @async.with_task_group(_ => cancel())
          }
          let cancelled = @async.is_being_cancelled()
          let writable = ports.serve_http2(conn, connection, b"")
          out.push("\{way}: cancelled \{cancelled}, writable \{writable}")
        }),
      )
    })
  }
  inspect(
    out.join("\n"),
    content=(
      #|TLS handshake: cancelled true, writable false
      #|preface check: cancelled true, writable false
    ),
  )
}
