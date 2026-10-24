// HTTP/2 connections, served through the `http2` package of
// moonbitstack/moonhttp (ADR 0005). Each connection has one moonhttp
// `Conn`, which keeps its frames, stream states, flow control, settings,
// field validation and header compression; smock owns the I/O, the mapping
// onto the engine and the timeouts. The loop here ties together parts that
// change apart:
//
// - the frame reader (`FrameReader`, http2_frames.mbt), with
//   `H2Connection::judge`, where each frame is judged before it reaches
//   the `Conn`;
// - the record of the client's streams (`StreamRecord`, http2_streams.mbt),
//   which the judge holds HEADERS frames against, and which every
//   RST_STREAM smock sends goes into, through `H2Connection::reset`;
// - the mapping from a stream onto the engine's request (`H2Request`,
//   http2_requests.mbt);
// - the response encoding (`response_fields`, http2_responses.mbt);
// - the writing of what the `Conn` queues (`write_queued`,
//   http2_output.mbt).
//
// Each stream's request takes the steps every request to the Mocks takes
// (requests.mbt). Until they get forms of their own, some cases are served
// in an interim way, so that a client's run ends rather than hangs:
//
// - a delay is waited in the reader, so the connection's other streams
//   wait too;
// - a Fault, a stream of Server-Sent Events, or a body larger than the open
//   windows ends its stream with RST_STREAM INTERNAL_ERROR, its Journal
//   entry committed as the engine made it;
// - one watch for the whole connection, as on HTTP/1.1: the idle timeout
//   while no stream is in progress, and the read timeout while one is,
//   from the read that brought its HEADERS; past it, the connection closes
//   without GOAWAY;
// - for the drain, the connection is idle while no stream is in progress,
//   and while smock drains, it closes, without GOAWAY, as soon as none is;
// - no body or header limit applies beyond moonhttp's own.

///|
/// The settings smock advertises on every HTTP/2 connection: RFC 9113's
/// defaults for the header table (4,096 octets), the initial window (65,535
/// octets), the frame size (16,384 octets) and extended CONNECT (off), with
/// at most 100 concurrent streams, and moonhttp's own bound on a header
/// list, 64 KiB.
let h2_settings : @http2.Settings = @http2.Settings::new(
  header_table_size=4096,
  max_concurrent_streams=Some(100),
  initial_window_size=65535,
  max_frame_size~,
  max_header_list_size=Some(65536),
  enable_connect_protocol=false,
)

///|
/// Serves one HTTP/2 connection, `stream`, whose client has sent the octets
/// `read`, the connection preface first, and returns whether `stream` can
/// still be written to: not after a write timed out. `connection` is kept
/// told whether the connection is idle, so that a drain can close it.
///
/// One task reads, a frame at a time, hands each frame to the connection's
/// `Conn`, and handles the events it produced, in order; before it reads
/// again, it writes what the `Conn` queued. A stream's request reaches the
/// engine when the client ends the stream, and its response is queued
/// while that event is handled. A stream the client resets before it ends
/// never reaches the engine.
async fn[S : @io.Reader + @io.Writer] MockPorts::serve_http2(
  self : MockPorts,
  stream : S,
  connection : Connection,
  read : Bytes,
) -> Bool {
  let mut writable = true
  @async.with_task_group(group => {
    let watchdog = Watchdog::new(
      group,
      write_timeout=self.settings.write_timeout_ms,
    )
    // A write that timed out ends the group.
    defer {
      writable = !watchdog.write_timed_out
    }
    let now = @async.now()
    let idle_timeout = self.settings.idle_timeout_ms.to_int64()
    let h2 : H2Connection = {
      ports: self,
      conn: @http2.Conn::new(Server, settings=h2_settings),
      reader: FrameReader::new(read),
      requests: Map([]),
      streams: StreamRecord::new(),
      watchdog,
      connection,
      idle_timeout,
      read_timeout: self.settings.read_timeout_ms.to_int64(),
      now,
      read_at: now,
      idle_deadline: now + idle_timeout,
      read_deadline: now,
      became_idle: false,
      last_read: Stopwatch::start(),
    }
    h2.serve(stream, { stream, watchdog, })
  })
  // A read that timed out ended the task group while the connection waited.
  connection.idle = false
  writable
}

///|
/// What the loop of an HTTP/2 connection keeps between its waits.
priv struct H2Connection {
  ports : MockPorts
  conn : @http2.Conn
  reader : FrameReader
  /// The requests in progress, by stream: begun, and neither ended nor
  /// reset by the client.
  requests : Map[Int32, H2Request]
  /// The client's streams: the highest ID seen, the streams open, and the
  /// streams this side reset.
  streams : StreamRecord
  /// The timeouts of the connection's waits on its client.
  watchdog : Watchdog
  connection : Connection
  idle_timeout : Int64
  read_timeout : Int64
  /// The time, as `@async.now()` gives it, read again after each wait: for
  /// reading, for writing, or for a delay.
  mut now : Int64
  /// When the last read returned.
  mut read_at : Int64
  /// While no stream is in progress, when the connection times out.
  mut idle_deadline : Int64
  /// While a stream is in progress, when the connection times out.
  mut read_deadline : Int64
  /// Whether the last stream in progress has ended since the connection
  /// last read, so that the idle timeout starts again once what was queued
  /// is written.
  mut became_idle : Bool
  /// Started at the last read.
  mut last_read : Stopwatch
}

///|
/// Splits what the connection reads into the preface and whole frames,
/// hands each to the `Conn` and handles its events, until the connection
/// ends. A frame larger than smock advertises, or a connection error the
/// `Conn` raises, ends it with GOAWAY.
async fn[S : @io.Reader + @io.Writer] H2Connection::serve(
  self : H2Connection,
  stream : S,
  out : WatchedStream[S],
) -> Unit {
  for ;; {
    let octets = match self.reader.next() {
      Preface(preface) => preface
      Frame(head, frame) =>
        match self.judge(head, frame) {
          None => frame
          Some(code) => {
            self.conn.goaway(code~) catch {
              _ => ()
            }
            let _ = write_queued(self.conn, out)
            return
          }
        }
      TooLarge => {
        self.conn.goaway(code=@http2.error_frame_size_error) catch {
          _ => ()
        }
        let _ = write_queued(self.conn, out)
        return
      }
      NeedMore => {
        if !self.read_more(stream, out) {
          return
        }
        continue
      }
    }
    if !self.hand(octets) {
      // The GOAWAY of the `Conn`'s connection error goes out first.
      let _ = write_queued(self.conn, out)
      return
    }
  }
}

///|
/// Judges `frame`, a whole frame from the client whose header is `head`,
/// against the stream state the frames before it left, before the `Conn`
/// sees it: `None` hands it to the `Conn`, and `Some(code)` ends the
/// connection with GOAWAY `code` instead. HEADERS on a client stream ID
/// already used, whose stream is neither open nor reset by this side, get
/// `PROTOCOL_ERROR` (RFC 9113, section 5.1.1); the `Conn` enforces the rest
/// of RFC 9113's rules.
fn H2Connection::judge(
  self : H2Connection,
  head : @http2.FrameHeader,
  _frame : BytesView,
) -> Int32? {
  if self.streams.see(head) {
    None
  } else {
    Some(@http2.error_protocol_error)
  }
}

///|
/// Hands the `Conn` `octets`, the preface or one whole frame, and handles
/// the events they produce, in order, until the `Conn` needs more. Returns
/// false when they break the connection: the `Conn` has then queued its
/// GOAWAY, and the connection ends.
async fn H2Connection::hand(self : H2Connection, octets : BytesView) -> Bool {
  self.conn.receive(octets) catch {
    _ => return false
  }
  for ;; {
    let event = self.conn.next() catch { _ => return false }
    match event {
      NeedData | Closed => {
        // A new stream whose field block brought no `Request` event was
        // refused by moonhttp, which reports nothing for it.
        self.streams.settle()
        return true
      }
      Request(stream~, fields~) => {
        if self.requests.is_empty() {
          self.read_deadline = self.read_at + self.read_timeout
        }
        self.requests[stream] = H2Request::new(fields)
        self.streams.opened(stream)
      }
      Data(stream~, data~) => {
        if self.requests.get(stream) is Some(request) {
          request.receive(data)
        }
        // Handed back as it is taken, so that the windows reopen as the
        // body arrives.
        self.conn.acknowledge(stream, data.length()) catch {
          _ => return false
        }
      }
      End(stream~) => {
        self.streams.ended_by_client(stream)
        if self.requests.get(stream) is Some(request) {
          self.requests.remove(stream)
          self.respond(stream, request)
          self.end_stream()
        }
      }
      Reset(stream~, remote~, ..) => {
        // smock's own resets give no event, so one not from the client is
        // moonhttp's.
        if remote {
          self.streams.reset_by_client(stream)
        } else {
          self.streams.remember(stream, by_smock=false)
        }
        if self.requests.contains(stream) {
          self.requests.remove(stream)
          self.end_stream()
        }
      }
      // Trailers are ignored. The `Conn` has acknowledged SETTINGS and
      // answered PING itself, and window updates and the client's GOAWAY
      // ask nothing of a stream that is answered at once.
      _ => ()
    }
  }
}

///|
/// A stream is no longer in progress. Once none is, the idle timeout runs
/// again, from when what was queued is written.
fn H2Connection::end_stream(self : H2Connection) -> Unit {
  if self.requests.is_empty() {
    self.became_idle = true
  }
}

///|
/// Writes what the `Conn` queued, then reads more from `stream`, and
/// returns whether the connection goes on: not once the client has closed
/// it, its timeout has passed, or smock drains and no stream is in
/// progress.
async fn[S : @io.Reader + @io.Writer] H2Connection::read_more(
  self : H2Connection,
  stream : S,
  out : WatchedStream[S],
) -> Bool {
  if write_queued(self.conn, out) {
    self.now = @async.now()
  }
  let idle = self.requests.is_empty()
  if idle && self.became_idle {
    self.idle_deadline = self.now + self.idle_timeout
    self.became_idle = false
  }
  if idle && self.ports.lifecycle.is_draining() {
    return false
  }
  let deadline = if idle { self.idle_deadline } else { self.read_deadline }
  if deadline - self.now <= 0L {
    return false
  }
  self.connection.idle = idle
  // Past the deadline, the watchdog ends the task group, and with it this
  // read and the connection.
  self.watchdog.reading(deadline, self.now)
  let n = self.reader.read(stream)
  self.watchdog.stop()
  self.connection.idle = false
  guard n > 0 else { return false }
  self.last_read = Stopwatch::start()
  self.now = @async.now()
  self.read_at = self.now
  true
}

///|
/// Answers the request that has arrived in full on `stream`, through the
/// steps every request to the Mocks takes. A response whose body fits the
/// stream's windows is queued at once: its HEADERS, then its body as DATA,
/// which ends the stream. A response to HEAD, and one whose status has no
/// content, sends no DATA: its HEADERS end the stream. The Journal entry is
/// committed just before the frame that ends the stream is queued.
///
/// For now, a delay is waited here, so the connection's other streams wait
/// too; and a Fault, a stream of Server-Sent Events or a body that does not
/// fit end the stream with RST_STREAM INTERNAL_ERROR instead, the entry
/// committed first, as the engine made it.
async fn H2Connection::respond(
  self : H2Connection,
  stream : Int32,
  request : H2Request,
) -> Unit {
  let ports = self.ports
  let incoming = request.to_engine()
  let outcome = ports.decide(
    incoming,
    authority?=request.authority,
    now=self.now,
  )
  defer ports.done(outcome, self.last_read)
  let plan = outcome.plan
  if plan.delay_ms > 0 {
    @async.sleep(plan.delay_ms)
    self.now = @async.now()
  }
  guard plan.fault is None && plan.body is Bytes(body) else {
    self.reset_after(stream, outcome.journal)
    return
  }
  // HEAD gets the length of the body without the body, as on HTTP/1.1.
  let sent = if has_content(plan.status) && incoming.meth != "HEAD" {
    body
  } else {
    body[0:0]
  }
  guard sent.length() <= self.conn.window(stream) else {
    self.reset_after(stream, outcome.journal)
    return
  }
  let fields = response_fields(
    plan.status,
    plan.headers,
    body.length(),
    date=ports.dates.at(self.now),
  )
  if sent.length() == 0 {
    ports.commit(outcome.journal)
    self.conn.headers(stream, fields, end=true) catch {
      _ => {
        self.reset_after(stream, None)
        return
      }
    }
    self.streams.ended_by_smock(stream)
    return
  }
  self.conn.headers(stream, fields) catch {
    _ => {
      self.reset_after(stream, outcome.journal)
      return
    }
  }
  ports.commit(outcome.journal)
  // The body fits the windows, so the `Conn` takes it.
  self.conn.data(stream, sent, end=true) catch {
    _ => return
  }
  self.streams.ended_by_smock(stream)
}

///|
/// Commits the Journal entry `entry`, if there is one, then ends `stream`
/// with RST_STREAM INTERNAL_ERROR.
fn H2Connection::reset_after(
  self : H2Connection,
  stream : Int32,
  entry : @engine.JournalEntry?,
) -> Unit {
  self.ports.commit(entry)
  self.reset(stream, @http2.error_internal_error)
}

///|
/// Ends `stream` with RST_STREAM `code`, and records that smock reset it,
/// so that frames the client sent on it before it learnt of the reset are
/// ignored (RFC 9113, section 5.1). Every RST_STREAM smock sends goes
/// through here; moonhttp's own come as `Reset` events. A request still in
/// progress on the stream ends with it.
fn H2Connection::reset(
  self : H2Connection,
  stream : Int32,
  code : Int32,
) -> Unit {
  self.conn.reset(stream, code~) catch {
    // The stream is not open, or the connection has failed: nothing is
    // sent.
    _ => return
  }
  self.streams.remember(stream, by_smock=true)
  if self.requests.contains(stream) {
    self.requests.remove(stream)
    self.end_stream()
  }
}
