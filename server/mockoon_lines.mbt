// The Mockoon-equivalent lines of the mockoon log format, which smock
// writes to stdout: a Server started line for each Mock once the plain and
// TLS ports listen, a Transaction recorded line for each request a Mock
// handles, and a Server stopped line for each Mock when the drain ends, all
// built by the log package from a prefix cached for each Mock.

///|
/// The Mockoon-equivalent lines: where they go, and the start of each
/// Mock's lines. smock holds one only in the mockoon log format.
priv struct MockoonLines {
  out : StdoutLines
  /// The prefix of each Mock's lines (`@log.mockoon_prefix`), by Mock name,
  /// for the definition set served, in the order the Admin API's status
  /// lists the Mocks.
  mut prefixes : Map[String, String]
  /// The prefix of the lines about a request no Mock answered.
  no_mock : String
}

///|
/// The lines of the definition set `engine` serves, written through `out`.
fn MockoonLines::new(
  engine : @engine.Engine,
  out : StdoutLines,
) -> MockoonLines {
  let lines = { out, prefixes: Map([]), no_mock: @log.mockoon_prefix(None), }
  lines.rebuild(engine)
  lines
}

///|
/// Builds the prefix of each Mock that `engine` serves, anew: when the first
/// definition set loads, and after each reload that swaps the set.
fn MockoonLines::rebuild(self : MockoonLines, engine : @engine.Engine) -> Unit {
  let prefixes = Map([])
  for mock in engine.status().mocks {
    prefixes[mock.name] = @log.mockoon_prefix(Some(mock.name))
  }
  self.prefixes = prefixes
}

///|
/// Writes the `Server started on port <port>` line of each Mock served, in
/// the order the Admin API's status lists them, with the time now, once the
/// plain and TLS listeners are open, `port` being the plain one's.
async fn MockoonLines::started(self : MockoonLines, port : Int32) -> Unit {
  let at = @async.now()
  self.write_each(prefix => @log.started_line(prefix, port~, at~))
}

///|
/// Writes the `Server stopped` line of each Mock served, in the order the
/// Admin API's status lists them, with the time now, once the drain ends: a
/// Mock that a reload added included.
async fn MockoonLines::stopped(self : MockoonLines) -> Unit {
  let at = @async.now()
  self.write_each(prefix => @log.stopped_line(prefix, at~))
}

///|
/// Writes the line that `line` builds from the prefix of each Mock served,
/// in the order the Admin API's status lists them, all in one write, so
/// that no other line comes between them.
async fn MockoonLines::write_each(
  self : MockoonLines,
  line : (String) -> String,
) -> Unit {
  let lines = self.prefixes.values().map(line).collect()
  if lines.length() > 0 {
    self.out.write(lines.join("\n"))
  }
}

///|
/// The prefix of the lines about a request that `resolution` says who
/// answered. A request answered by a definition set just swapped out may
/// name a Mock with no cached prefix: its prefix is built for the line.
fn MockoonLines::prefix(
  self : MockoonLines,
  resolution : @engine.Resolution,
) -> String {
  match resolution {
    ByHost(name) | ViaDefault(name) =>
      match self.prefixes.get(name) {
        Some(prefix) => prefix
        None => @log.mockoon_prefix(Some(name))
      }
    NoMock => self.no_mock
  }
}

///|
/// Writes the Transaction recorded line of `request`, which the engine
/// decided `outcome` for, with the time now: with its planned status, as
/// the Journal records it, also when the request ended before the status
/// was sent, or with the reset or close Fault that ended it before any
/// status.
///
/// When the Stub that matched failed its own content, the request's error
/// line (`serving_error`) comes first, in the same write, so that no other
/// line comes between them.
async fn MockoonLines::transaction(
  self : MockoonLines,
  request : @http1.Request,
  outcome : @engine.Outcome,
) -> Unit {
  let ended : @log.TransactionEnd = match outcome.plan.fault {
    Some(Reset) => Reset
    Some(Close) => Close
    Some(Partial) | None => Status(outcome.plan.status)
  }
  let error = self.serving_error(outcome)
  let line = @log.transaction_line(
    self.prefix(outcome.resolution),
    meth=request.meth,
    target=request.target,
    ended~,
    at=@async.now(),
  )
  match error {
    Some(error) => self.out.write("\{error}\n\{line}")
    None => self.out.write(line)
  }
}

///|
/// The `Error while serving the content: …` line of `outcome`, with the
/// time now, when the Stub that matched failed its own content: a template
/// that could not be rendered, a value of its `variables` or `dataWrites`
/// included, or a data write that could not be applied. It names the
/// error's message, as the 500's body gives it, the Stub's path as written
/// and the Stub ID. Any other outcome, a 507 from the state bound included,
/// has none, also when a connection Fault replaces the 500.
fn MockoonLines::serving_error(
  self : MockoonLines,
  outcome : @engine.Outcome,
) -> String? {
  let message = match outcome.template_error {
    Some(error) => error.message
    None =>
      match outcome.data_error {
        Some(error) => error.message
        None => return None
      }
  }
  guard outcome.matched is Some(FromFile(stub) | Ephemeral(stub)) else {
    abort("a template or data error comes from the Stub that matched")
  }
  Some(
    @log.serving_error_line(
      self.prefix(outcome.resolution),
      message~,
      path=outcome.failed_stub_path,
      stub~,
      at=@async.now(),
    ),
  )
}

///|
/// Writes the lines of `request` once the request path is done with it, if
/// the engine decided an outcome for it, which `pending` then holds, and
/// empties `pending`.
async fn MockoonLines::write_pending(
  self : MockoonLines,
  request : @http1.Request,
  pending : PendingLine,
) -> Unit {
  guard pending.outcome is Some(outcome) else { return }
  pending.outcome = None
  self.transaction(request, outcome)
}

///|
/// The engine's outcome for the request of one connection whose Transaction
/// recorded line is still to be written. The request path sets it where it
/// counts the request, after the response's last byte, without waiting, and
/// the line is written once the request path is done with the request. So
/// the request path waits for nothing more there, and the json format,
/// which writes no line, adds only a test to it.
priv struct PendingLine {
  mut outcome : @engine.Outcome?
}

///|
fn PendingLine::new() -> PendingLine {
  { outcome: None, }
}
