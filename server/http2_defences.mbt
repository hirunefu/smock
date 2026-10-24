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
  /// How many SETTINGS acknowledgements smock is owed: one for the SETTINGS
  /// frame it opens the connection with, until it comes.
  mut settings_owed : Int32
  /// How many PING acknowledgements smock is owed: one for each PING it has
  /// sent, until it comes. smock sends no PING of its own yet, so every
  /// acknowledgement counts.
  mut pings_owed : Int32
}

///|
/// The count of a connection that has had no frame yet.
fn NoWorkFrames::new() -> NoWorkFrames {
  { times: [], oldest: 0, settings_owed: 1, pings_owed: 0, }
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
/// is, as the log names it, or `None` for a frame that does some work:
///
/// - a SETTINGS frame that is not an acknowledgement, and an
///   acknowledgement that smock is not owed;
/// - a PING that asks for an acknowledgement, when smock has sent no
///   HEADERS or DATA since the client's last PING. gRPC counts PINGs so,
///   so that a client that sends one after each DATA frame it receives, to
///   estimate its bandwidth, does no harm while answers stream to it;
/// - a PING acknowledgement that answers no PING smock sent;
/// - a PRIORITY frame, since smock ignores priority signals;
/// - a DATA frame that carries no data, padded or not, and ends no stream;
/// - a DATA, WINDOW_UPDATE or RST_STREAM frame on a stream already closed,
///   and HEADERS on a stream this side reset, which the `Conn` ignores, as
///   the record of the client's streams (`StreamRecord`) tells them;
/// - a frame of a type RFC 9113 does not define, which is ignored.
///
/// `frame` is the whole frame, its header included. It runs before
/// `StreamRecord::see` takes the frame into the record.
fn H2Connection::no_work(
  self : H2Connection,
  head : @http2.FrameHeader,
  frame : BytesView,
) -> String? {
  let ftype = head.ftype
  let ack = (head.flags & @http2.flag_ack) != 0
  let counted = self.no_work_frames
  if ftype == @http2.frame_data {
    if (head.flags & @http2.flag_end_stream) == 0 && carries(head, frame) == 0 {
      Some("empty DATA")
    } else if self.closed(head.stream_id) {
      Some("DATA on a closed stream")
    } else {
      None
    }
  } else if ftype == @http2.frame_window_update {
    if self.closed(head.stream_id) {
      Some("WINDOW_UPDATE on a closed stream")
    } else {
      None
    }
  } else if ftype == @http2.frame_rst_stream {
    // Spec F's exception goes here: a client reset of a gRPC call that smock
    // ended with DEADLINE_EXCEEDED does not count, once per stream.
    if self.closed(head.stream_id) {
      Some("RST_STREAM on a closed stream")
    } else {
      None
    }
  } else if ftype == @http2.frame_headers {
    // HEADERS on a stream closed otherwise end the connection
    // (`StreamRecord::see`).
    if !self.streams.in_block &&
      head.stream_id % 2 == 1 &&
      self.streams.state(head.stream_id) is Reset {
      Some("HEADERS on a stream smock reset")
    } else {
      None
    }
  } else if ftype == @http2.frame_settings {
    if !ack {
      Some("SETTINGS")
    } else if counted.settings_owed > 0 {
      counted.settings_owed -= 1
      None
    } else {
      Some("SETTINGS acknowledgement")
    }
  } else if ftype == @http2.frame_ping {
    if ack {
      if counted.pings_owed > 0 {
        counted.pings_owed -= 1
        None
      } else {
        Some("PING acknowledgement")
      }
    } else if self.writer.responded {
      self.writer.responded = false
      None
    } else {
      Some("PING")
    }
  } else if ftype == @http2.frame_priority {
    Some("PRIORITY")
  } else if ftype > @http2.frame_continuation {
    Some("unknown type")
  } else {
    None
  }
}

///|
/// Whether `stream` is a client stream that is already closed: used, and
/// neither open nor idle, whether this side reset it or not.
fn H2Connection::closed(self : H2Connection, stream : Int32) -> Bool {
  stream % 2 == 1 && self.streams.state(stream) is (Closed | Reset)
}

///|
/// How many octets of data the DATA frame `frame`, whose header is `head`,
/// carries: its payload less its padding. A padded frame too short for its
/// padding, which the `Conn` refuses, carries some.
fn carries(head : @http2.FrameHeader, frame : BytesView) -> Int32 {
  if (head.flags & @http2.flag_padded) == 0 {
    head.length
  } else if head.length == 0 || frame[9].to_int() >= head.length {
    1
  } else {
    head.length - 1 - frame[9].to_int()
  }
}

///|
/// Ends the connection for the defence against the pattern `pattern`,
/// which a frame of the kind `frame` tripped, when there is one: queues
/// GOAWAY ENHANCE_YOUR_CALM, with the name of the pattern as its debug
/// data, and logs one line, at level `warn`, that names them. It adds no
/// metric. The caller then writes what is queued and ends the connection,
/// so the line is the connection's only one, and its streams in progress
/// end with it: their tasks are cancelled, and commit their Journal
/// entries as they end.
fn H2Connection::calm(
  self : H2Connection,
  pattern : String,
  frame? : String,
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
