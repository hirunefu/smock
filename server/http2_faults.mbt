// Faults on an HTTP/2 connection. Each connection Fault takes its nearest
// HTTP/2 form, and the engine decides it as over HTTP/1.1, with the same
// draws and seeds:
//
// - `reset`: once the request has arrived in full, RST_STREAM
//   INTERNAL_ERROR on its stream alone (`H2Connection::reset_after`,
//   http2.mbt). The connection's other streams go on.
// - `partial`: the HEADERS, with the whole `content-length`, and half the
//   body (`H2Connection::queue`, http2.mbt), or half the events, rounded
//   down (`H2Connection::send_events`, http2_events.mbt), then RST_STREAM
//   INTERNAL_ERROR. A response with no body sends its HEADERS without
//   ending the stream, then the reset.
// - `close`: GOAWAY NO_ERROR, then the connection closes
//   (`H2Connection::close_by_fault`).
//
// Each runs where the response would: in place, while the event is
// handled, when it has no delay and what it sends fits the windows, and
// otherwise in the stream's task. RST_STREAM is a frame, so no Fault over
// HTTP/2 needs the socket option that HTTP/1.1's `reset` sets (ADR 0001).

///|
/// Carries out a close Fault on `stream`, whose Journal entry is `entry`:
/// the entry is committed, with no status, as the engine made it, then the
/// connection gets GOAWAY NO_ERROR naming the highest stream the client has
/// opened, so that the Fault's own stream and every stream handed to the
/// engine are at or below it (RFC 9113, section 8.7), and closes after it
/// (`close_after_goaway`).
///
/// Every other stream of the connection ends with it, as a request on an
/// HTTP/1.1 connection that a close Fault ends gets no response: no frame
/// goes out after the GOAWAY. A stream whose response waits in a task stops
/// waiting at once, and its entry is committed, as for a client that goes
/// away; one whose request is still arriving never reaches the engine,
/// since the reader hands the `Conn` no frame after the GOAWAY.
///
/// It runs while the event is handled, or in the stream's own task after a
/// delay, which goes on once it returns.
fn[S : @io.Writer + ReadOutput] H2Connection::close_by_fault(
  self : H2Connection,
  stream : Int32,
  entry : @engine.JournalEntry?,
  out : WatchedStream[S],
) -> Unit {
  self.ports.commit(entry)
  let others = []
  for waiting, _ in self.waiting {
    if waiting != stream {
      others.push(waiting)
    }
  }
  for other in others {
    self.stop_waiting(other)
  }
  self.go_away(out)
}
