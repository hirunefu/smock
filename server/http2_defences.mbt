// The defences of an HTTP/2 connection against a client that makes it work
// for nothing. `H2Connection::judge` (http2.mbt) counts each frame that
// does no work before the `Conn` sees it, and past the bound the connection
// ends with GOAWAY ENHANCE_YOUR_CALM (`H2Connection::calm`), as every
// defence that closes a connection ends it.

///|
/// How many frames that do no work a client may send in any one second.
let no_work_bound : Int32 = 100

///|
/// The span of time `no_work_bound` holds for, in milliseconds.
let no_work_window_ms : Int64 = 1000

///|
/// What an HTTP/2 connection counts of its client's frames that do no
/// work. Its memory is bounded however long the connection lives: the times
/// of the last `no_work_bound` of them.
priv struct NoWorkFrames {
  /// When each of the frames counted last arrived, oldest first until there
  /// are `no_work_bound`; then a ring, whose oldest is at `oldest`.
  times : Array[Int64]
  /// Once `times` is full, the index of its oldest time, which the next
  /// frame counted replaces.
  mut oldest : Int32
}

///|
/// The count of a connection that has had no frame yet.
fn NoWorkFrames::new() -> NoWorkFrames {
  { times: [], oldest: 0, }
}

///|
/// Counts a frame that does no work, arrived at `at`, and returns whether
/// it passes the bound: whether it is the last of more than `no_work_bound`
/// such frames within one second.
fn NoWorkFrames::count(self : NoWorkFrames, at : Int64) -> Bool {
  if self.times.length() < no_work_bound {
    self.times.push(at)
    return false
  }
  if at - self.times[self.oldest] < no_work_window_ms {
    return true
  }
  self.times[self.oldest] = at
  self.oldest = (self.oldest + 1) % no_work_bound
  false
}

///|
/// What kind of frame that does no work the frame whose header is `head`
/// is, as the log names it, or `None` for a frame that does some work. A
/// PING that asks for an acknowledgement does no work.
fn H2Connection::no_work(
  _self : H2Connection,
  head : @http2.FrameHeader,
  _frame : BytesView,
) -> String? {
  let ack = (head.flags & @http2.flag_ack) != 0
  if head.ftype == @http2.frame_ping && !ack {
    return Some("PING")
  }
  if head.ftype == @http2.frame_settings && !ack {
    return Some("SETTINGS")
  }
  None
}

///|
/// Ends the connection for a defence that `pattern` names, which the frame
/// that `frame` names, when there is one, tripped: queues GOAWAY
/// ENHANCE_YOUR_CALM, with the name of the pattern as its debug data, and
/// logs one line that names them. The caller then writes what is queued
/// and ends the connection, so the line is the connection's only one.
fn H2Connection::calm(
  self : H2Connection,
  pattern : String,
  frame~ : String? = None,
) -> Unit {
  self.conn.goaway(
    code=@http2.error_enhance_your_calm,
    debug=@utf8.encode(pattern),
  ) catch {
    _ => ()
  }
  let fields : Map[String, Json] = { "pattern": Json::string(pattern) }
  if frame is Some(frame) {
    fields["frame"] = Json::string(frame)
  }
  self.ports.logger.warn("HTTP/2 connection closed by a defence", fields~)
}
