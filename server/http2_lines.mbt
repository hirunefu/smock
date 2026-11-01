// The mockoon log format on an HTTP/2 connection: the Transaction recorded
// line of each stream whose request reached the engine, with `:method` and
// the target, written once the stream's response has ended, as over
// HTTP/1.1, after its error line when its Stub's content failed. A stream
// that never reached the engine, refused by smock or by moonhttp, or reset
// by the client before its request ended, gets none, as a request the
// HTTP/1.1 codec rejects gets none.
//
// A line is written by the task that ran the stream's response, once what
// it queued is written:
//
// - a response queued in place, while an event was handled, by the reader,
//   before it reads again (`H2Connection::read_more`);
// - a response that waited in a task of its own, for a delay, for window or
//   for its events, by that task, as it ends (`H2Connection::end_task`);
// - a response that a reset cut short while its task waited, by whichever
//   task writes the output that follows the reset: the reader, after a
//   client's reset, or the task that writes smock's own RST_STREAM or
//   GOAWAY (`H2Connection::expire`, `close_after_goaway`);
// - and any line still to write when the connection ends, by the end of its
//   task group, once every stream's task has ended: a drain that cuts the
//   connection, or a write that timed out, included.
//
// The json format writes no line: the connection holds no `H2Lines`, and
// each request costs a test of that where it is counted.

///|
/// The request of an HTTP/2 stream that reached the engine, whose
/// Transaction recorded line is still to be written: its method and its
/// target, as the engine saw them, and the engine's outcome for it.
priv struct H2Line {
  meth : String
  target : String
  outcome : @engine.Outcome
}

///|
/// The Transaction recorded lines of one HTTP/2 connection's streams that
/// are still to be written, in the mockoon log format only.
priv struct H2Lines {
  lines : MockoonLines
  /// The lines of the streams whose responses have ended, oldest first.
  ended : Array[H2Line]
}

///|
/// The lines of a new connection, which go to `lines`.
fn H2Lines::new(lines : MockoonLines) -> H2Lines {
  { lines, ended: [], }
}

///|
/// Writes the lines of the streams whose responses have ended, oldest first,
/// and returns once they are out: those that end meanwhile too.
async fn H2Lines::write_ended(self : H2Lines) -> Unit {
  while self.ended.length() > 0 {
    for line in self.ended {
      self.lines.queue_transaction(
        meth=line.meth,
        target=line.target,
        line.outcome,
      )
    }
    self.ended.clear()
    self.lines.out.flush()
  }
}

///|
/// The response to the request on a stream, which the engine decided
/// `outcome` for, has been queued in place, while an event was handled, in
/// full or as far as a Fault lets it go: the request is counted, and in the
/// mockoon log format its line waits for the reader to write it, once what
/// is queued is written (`write_ended`).
fn H2Connection::ended_in_place(
  self : H2Connection,
  request : H2Request,
  outcome : @engine.Outcome,
) -> Unit {
  self.ports.done(outcome, self.last_read)
  if self.lines is Some(lines) {
    lines.ended.push({ meth: request.meth, target: request.target, outcome, })
  }
}

///|
/// In the mockoon log format, writes the lines of the streams whose
/// responses have ended, once their last frames are written: when another
/// task is writing to `out`, it waits until that task has written them.
async fn H2Connection::write_ended(self : H2Connection) -> Unit {
  guard self.lines is Some(lines) && lines.ended.length() > 0 else { return }
  self.writer.wait()
  lines.write_ended()
}
