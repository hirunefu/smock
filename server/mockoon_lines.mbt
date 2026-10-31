// The Mockoon-equivalent lines of the mockoon log format, which smock
// writes to stdout: a Transaction recorded line for each request a Mock
// handles, built by the log package from a prefix cached for each Mock.

///|
/// The Mockoon-equivalent lines: where they go, and the start of each
/// Mock's lines. smock holds one only in the mockoon log format.
priv struct MockoonLines {
  out : StdoutLines
  /// The prefix of each Mock's lines (`@log.mockoon_prefix`), by Mock name,
  /// for the definition set served.
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
  let line = @log.transaction_line(
    self.prefix(outcome.resolution),
    meth=request.meth,
    target=request.target,
    ended~,
    at=@async.now(),
  )
  self.out.write(line)
}

///|
/// Writes the line of `request` once the request path is done with it, if
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
