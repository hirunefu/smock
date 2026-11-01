// The Mockoon-equivalent lines of the mockoon log format, which smock
// writes to stdout: a Server started line for each Mock once the plain and
// TLS ports listen, a Transaction recorded line for each request a Mock
// handles, after an Error while serving the content line when its Stub's
// content failed, and a Server stopped line for each Mock when the drain
// ends, all built by the log package from a prefix cached for each Mock.

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
  for name in engine.mock_names() {
    prefixes[name] = @log.mockoon_prefix(Some(name))
  }
  self.prefixes = prefixes
}

///|
/// Writes the `Server started on port <port>` line of each Mock served, in
/// the order the Admin API's status lists them, with the time now, once the
/// plain and TLS listeners are open, `port` being the plain one's. The
/// lines are queued together, so that no other line comes between them.
async fn MockoonLines::started(self : MockoonLines, port : Int32) -> Unit {
  let at = @async.now()
  for _, prefix in self.prefixes {
    self.out.queue(@log.started_line(prefix, port~, at~))
  }
  self.out.flush()
}

///|
/// Writes the `Server stopped` line of each Mock served, in the order the
/// Admin API's status lists them, with the time now, once the drain ends: a
/// Mock that a reload added included. The lines are queued together, so
/// that no other line comes between them.
async fn MockoonLines::stopped(self : MockoonLines) -> Unit {
  let at = @async.now()
  for _, prefix in self.prefixes {
    self.out.queue(@log.stopped_line(prefix, at~))
  }
  self.out.flush()
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
/// Writes the Transaction recorded line of the request with the method
/// `meth` and the target `target`, which the engine decided `outcome` for,
/// with the time now (`transaction_line`), and returns once it is out.
///
/// When the Stub that matched failed its own content, the request's error
/// line (`serving_error`) comes first, queued with it, so that no other line
/// comes between them.
async fn MockoonLines::transaction(
  self : MockoonLines,
  meth~ : String,
  target~ : String,
  outcome : @engine.Outcome,
) -> Unit {
  let error = self.serving_error(outcome)
  let line = self.transaction_line(meth~, target~, outcome)
  if error is Some(error) {
    self.out.queue(error)
  }
  self.out.write(line)
}

///|
/// Queues the lines that `transaction` writes, for the next flush of `out`,
/// so that the lines of several requests go out together.
fn MockoonLines::queue_transaction(
  self : MockoonLines,
  meth~ : String,
  target~ : String,
  outcome : @engine.Outcome,
) -> Unit {
  if self.serving_error(outcome) is Some(error) {
    self.out.queue(error)
  }
  self.out.queue(self.transaction_line(meth~, target~, outcome))
}

///|
/// The Transaction recorded line of the request with the method `meth` and
/// the target `target`, which the engine decided `outcome` for, with the
/// time now: with its planned status, as the Journal records it, also when
/// the request ended before the status was sent, or with the reset or close
/// Fault that ended it before any status.
fn MockoonLines::transaction_line(
  self : MockoonLines,
  meth~ : String,
  target~ : String,
  outcome : @engine.Outcome,
) -> String {
  let ended : @log.TransactionEnd = match outcome.plan.fault {
    Some(Reset) => Reset
    Some(Close) => Close
    Some(Partial) | None => Status(outcome.plan.status)
  }
  @log.transaction_line(
    self.prefix(outcome.resolution),
    meth~,
    target~,
    ended~,
    at=@async.now(),
  )
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
  guard outcome.content_error is Some(error) else { return None }
  Some(
    @log.serving_error_line(
      self.prefix(outcome.resolution),
      message=error.failure.message(),
      path=error.path,
      stub=error.stub,
      at=@async.now(),
    ),
  )
}

///|
/// The engine's outcome for the request of one connection whose Transaction
/// recorded line is still to be written, with the lines it goes to. The
/// request path sets it where it counts the request, after the response's
/// last byte, without waiting, and the line is written once the request
/// path is done with the request. So the request path waits for nothing
/// more there, and the json format, which writes no line, adds only a test
/// to it.
priv struct PendingLine {
  lines : MockoonLines
  mut outcome : @engine.Outcome?
}

///|
/// A pending line of a connection whose lines go to `lines`, with no
/// outcome yet.
fn PendingLine::new(lines : MockoonLines) -> PendingLine {
  { lines, outcome: None, }
}

///|
/// Writes the lines of `request` once the request path is done with it, if
/// the engine decided an outcome for it, which the pending line then holds,
/// and empties the pending line.
async fn PendingLine::write(
  self : PendingLine,
  request : @http1.Request,
) -> Unit {
  guard self.outcome is Some(outcome) else { return }
  self.outcome = None
  self.lines.transaction(meth=request.meth, target=request.target, outcome)
}
