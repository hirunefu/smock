// The defences of an HTTP/2 connection against a client that makes it work
// for nothing. `H2Connection::judge` (http2.mbt) counts each frame that
// does no work before the `Conn` sees it, and past the bound the connection
// ends with GOAWAY ENHANCE_YOUR_CALM (`H2Connection::calm`), as every
// defence that closes a connection ends it. `H2Connection::hand` counts
// the streams that end reset before smock has finished their responses,
// against Rapid Reset and MadeYouReset (`H2Connection::reset_early`), which
// ends the connection the same way. A header block past moonhttp's
// bound as received, a CONTINUATION flood, is the `Conn`'s own connection
// error, which smock logs the same way (`H2Connection::flooded`).

///|
/// How many frames that do no work a client may send in any one second.
let no_work_bound : Int32 = 100

///|
/// The span of time `no_work_bound` holds for, in milliseconds.
let no_work_window_ms : Int64 = 1000

///|
/// The most PINGs that the HEADERS and DATA frames smock has sent can let
/// pass uncounted at once (`H2Writer::ping_credit`): as many as
/// `no_work_bound`. So a client that saves them up during a long response,
/// then sends nothing but PINGs, is cut once it has sent about twice the
/// bound in one second.
let ping_credit_bound : Int32 = no_work_bound

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
  /// sent, until it comes. smock sends one PING, after the first GOAWAY of
  /// a drain (`H2Connection::start_drain`).
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
/// - a PING that asks for an acknowledgement, beyond one for each HEADERS
///   or DATA frame smock has sent, of which at most `ping_credit_bound` are
///   saved up (`H2Writer::ping_credit`). So a client that sends one after
///   each DATA frame it receives, to estimate its bandwidth, does no harm
///   while answers stream to it, however many frames come between its
///   PINGs;
/// - a PING acknowledgement that answers no PING smock sent;
/// - a PRIORITY frame, since smock ignores priority signals;
/// - a DATA frame that carries no data, padded or not, and ends no stream;
/// - a CONTINUATION frame with no octets that ends no header block;
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
    } else if self.writer.ping_credit > 0 {
      self.writer.ping_credit -= 1
      None
    } else {
      Some("PING")
    }
  } else if ftype == @http2.frame_priority {
    Some("PRIORITY")
  } else if ftype == @http2.frame_continuation {
    // Outside a header block, or on a stream other than its own, it is a
    // connection error that the `Conn` raises.
    if head.length == 0 && (head.flags & @http2.flag_end_headers) == 0 {
      Some("empty CONTINUATION")
    } else {
      None
    }
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
/// How many streams a client may have had reset before smock finished their
/// responses, by its own RST_STREAM or by moonhttp for a stream error its
/// frames caused, before the defence against Rapid Reset (CVE-2023-44487)
/// and MadeYouReset (CVE-2025-8671) closes its connection: past it, once
/// they are also more than half of all the streams it began.
let early_reset_bound : Int32 = 100

///|
/// Counts a stream the client began that ended reset before smock had
/// finished its response, in the wake of `frame`, a whole frame with its
/// header, and returns whether that passes the bound
/// (`early_reset_bound`): the connection then ends with GOAWAY
/// ENHANCE_YOUR_CALM (`calm`). The count only grows, so a client that
/// cancels a stream now and then among many it lets finish is never cut.
fn H2Connection::reset_early(self : H2Connection, frame : BytesView) -> Bool {
  let streams = self.streams
  streams.cut += 1
  // More than half of the streams begun: more than the rest of them.
  guard streams.cut > early_reset_bound &&
    streams.cut > streams.begun - streams.cut else {
    return false
  }
  self.calm("Rapid Reset", frame=frame_name(frame))
  true
}

///|
/// Records `stream`, a new client stream whose field block, which ended in
/// `frame`, a whole frame with its header, brought no `Request` event, as
/// reset by this side, and returns whether it passes the bound on Rapid
/// Reset (`reset_early`):
///
/// - After the final GOAWAY of a drain, the `Conn` ignored it, since its ID
///   is above the last that the GOAWAY names. It does not count.
/// - Otherwise moonhttp refused it at open, which moonhttp reports with no
///   event, so smock cannot read the code it used. A stream refused while
///   as many streams are open as `--http2-max-concurrent-streams` allows
///   got REFUSED_STREAM (moonhttp 0.14.0 checks the limit before the
///   fields), which counts only once the client has acknowledged smock's
///   SETTINGS: before that, it may not know the limit. Any other got
///   `PROTOCOL_ERROR` or `ENHANCE_YOUR_CALM`, which counts. A list past
///   moonhttp's bound at the limit is taken for REFUSED_STREAM, so it too
///   counts only once the SETTINGS are acknowledged.
fn H2Connection::refused_at_open(
  self : H2Connection,
  stream : Int32,
  frame : BytesView,
) -> Bool {
  self.streams.remember(stream)
  if self.drain is Told {
    return false
  }
  if !self.settings_acked &&
    self.streams.open_count() >= self.max_concurrent_streams {
    return false
  }
  self.reset_early(frame)
}

///|
/// The type of `frame`, a whole frame with its header, as RFC 9113 names
/// it, for the log line of a defence.
fn frame_name(frame : BytesView) -> String {
  match frame[3].to_int() {
    0x0 => "DATA"
    0x1 => "HEADERS"
    0x2 => "PRIORITY"
    0x3 => "RST_STREAM"
    0x4 => "SETTINGS"
    0x5 => "PUSH_PROMISE"
    0x6 => "PING"
    0x7 => "GOAWAY"
    0x8 => "WINDOW_UPDATE"
    0x9 => "CONTINUATION"
    ftype => "type \{ftype}"
  }
}

///|
/// Ends the connection for the defence against the pattern `pattern`,
/// which a frame of the kind `frame` tripped, when there is one: queues
/// GOAWAY ENHANCE_YOUR_CALM, with the name of the pattern as its debug
/// data, and logs it (`defended`).
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
  self.defended(pattern, frame?)
}

///|
/// Logs the close of the connection by moonhttp's bound on a header block
/// as received, twice `--header-size-limit` (`header_list_bound`), which
/// `frame`, a HEADERS or CONTINUATION frame with its header, passed: the
/// defence against CONTINUATION floods. The `Conn` has queued GOAWAY
/// ENHANCE_YOUR_CALM already, with its own reason as debug data; it raises
/// no other connection error with that code. smock keeps no count of its
/// own for the bound: the e2e tests check moonhttp's from outside, so that
/// an upgrade that drops it fails them.
fn H2Connection::flooded(self : H2Connection, frame : BytesView) -> Unit {
  let kind = if frame[3].to_int() == @http2.frame_continuation {
    "CONTINUATION"
  } else {
    "HEADERS"
  }
  self.defended("CONTINUATION flood", frame=kind)
}

///|
/// Logs the close of the connection by the defence against the pattern
/// `pattern`, which a frame of the kind `frame` tripped, when there is one:
/// one line, at level `warn`, that names them. It adds no metric. The
/// caller then writes what is queued, the GOAWAY among it, and ends the
/// connection, so the line is the connection's only one, and its streams in
/// progress end with it: their tasks are cancelled, and commit their
/// Journal entries as they end.
fn H2Connection::defended(
  self : H2Connection,
  pattern : String,
  frame? : String,
) -> Unit {
  let fields : Map[String, Json] = { "pattern": Json::string(pattern) }
  if frame is Some(frame) {
    fields["frame"] = Json::string(frame)
  }
  self.ports.logger.warn("HTTP/2 connection closed by a defence", fields~)
}
