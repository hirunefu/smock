// The steps each request to the Mocks takes, on the plain and the TLS port,
// whatever protocol carries it. The protocol's connection loop reads the
// request and builds the engine's request from it, each header value
// decoded as `header_text` decodes it. Then:
//
// 1. `MockPorts::decide`: the engine decides the answer, for the Session
//    the request's header fields carry;
// 2. the loop writes the response the plan describes, with its own writer,
//    and commits the Journal entry with `MockPorts::commit` when it says:
//    just before the response's last bytes, or when the request ends
//    otherwise;
// 3. `MockPorts::done`: once the response is written, or the request ended
//    without it, the entry's timing is filled in, and the request is counted
//    in the request metrics with its `mock` and `stub` labels.
//
// A request the protocol layer rejects never reaches the engine, and is
// counted with `MockPorts::rejected` instead. The HTTP/1.1 loop
// (`MockPorts::serve`) takes these steps for each request. They are plain
// calls that allocate nothing of their own, so that a response written at
// once costs what it did before they were shared.

///|
/// The text of a header field's value, as the engine sees it: its bytes
/// read as UTF-8, with U+FFFD for invalid sequences.
fn header_text(value : BytesView) -> String {
  @utf8.decode_lossy(value)
}

///|
/// Decides the answer to `request`, received at `now`, for the Session its
/// header fields carry. `authority`, when given, is the request's Host,
/// ahead of its target and of any `host` field (see
/// `@engine.Engine::handle`). The caller then writes the response the
/// outcome's plan describes, commits its Journal entry with `commit`, and
/// ends with `done`.
fn MockPorts::decide(
  self : MockPorts,
  request : @engine.Request,
  authority? : String,
  now~ : Int64,
) -> @engine.Outcome {
  self.engine.handle(
    request,
    authority?,
    session=self.sessions.session_of(request.headers),
    now~,
    rand=self.rand,
  )
}

///|
/// Commits the Journal entry `entry`, if there is one. The caller commits
/// it just before the response's last bytes are written, so that a client
/// that has the whole response finds its request in the Journal, or, for a
/// request that ends otherwise, when it ends, before the connection closes.
fn MockPorts::commit(self : MockPorts, entry : @engine.JournalEntry?) -> Unit {
  if entry is Some(entry) {
    self.engine.commit(entry)
  }
}

///|
/// Ends the steps of a request the engine decided `outcome` for, once its
/// response is written or the request ended without it: fills in the
/// timing of its Journal entry, if it has one, and counts it in the request
/// metrics, with the seconds `stopwatch` gives since the request was read
/// in full.
fn MockPorts::done(
  self : MockPorts,
  outcome : @engine.Outcome,
  stopwatch : Stopwatch,
) -> Unit {
  if outcome.journal is Some(entry) {
    entry.finish(at=@async.now())
  }
  self.traffic.record(outcome, stopwatch.seconds())
}

///|
/// Counts a request the protocol layer rejected, once its error response
/// is written, with the seconds `stopwatch` gives since the read that
/// brought it. No Mock or Stub was tried, so it counts with `mock=""` and
/// `stub=""`, and is neither an unmatched request nor in the Journal.
fn MockPorts::rejected(self : MockPorts, stopwatch : Stopwatch) -> Unit {
  self.traffic.record_rejected(stopwatch.seconds())
}
