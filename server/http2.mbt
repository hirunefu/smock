// HTTP/2 connections, h2c on the plain port and h2 on the TLS port, served
// through the `http2` package of moonbitstack/moonhttp (ADR 0005). Each
// connection has one moonhttp `Conn`, which keeps its frames, stream
// states, flow control, settings, field validation and header compression;
// smock owns the I/O, the mapping onto the engine and the timeouts. The
// loop here ties together parts that change apart:
//
// - the frame reader (`FrameReader`, http2_frames.mbt), with
//   `H2Connection::judge`, where each frame is judged before it reaches
//   the `Conn`;
// - the record of the client's streams (`StreamRecord`, http2_streams.mbt),
//   which the judge holds HEADERS frames against, which counts the streams
//   open against `--http2-max-concurrent-streams`, and which every
//   RST_STREAM smock sends goes into, through `H2Connection::reset`;
// - the mapping from a stream onto the engine's request (`H2Request`,
//   http2_requests.mbt), with the checks of HTTP/1.1's rules and of
//   `--body-limit`, which refuse a stream with 400 or 413
//   (`H2Connection::refuse`);
// - the response encoding (`response_fields`, http2_responses.mbt);
// - the writing of what the `Conn` queues, through the connection's one
//   writer (`H2Writer`, http2_output.mbt);
// - the tasks of the streams whose responses wait (`H2Connection::wait`);
// - the deadlines of the connection and of its streams, which the
//   connection's one watchdog keeps (`H2Connection::expire`).
//
// Each stream's request takes the steps every request to the Mocks takes
// (requests.mbt). Until they get forms of their own, some cases are served
// in an interim way, so that a client's run ends rather than hangs:
//
// - a Fault, a stream of Server-Sent Events, or a body larger than the open
//   windows ends its stream with RST_STREAM INTERNAL_ERROR, its Journal
//   entry committed as the engine made it;
// - for the drain, the connection is idle while no stream is in progress,
//   and while smock drains, it closes, without GOAWAY, as soon as none is;
// - no header limit applies beyond moonhttp's own.

///|
/// The settings smock advertises on every HTTP/2 connection of a process
/// with the settings `settings`: RFC 9113's defaults for the header table
/// (4,096 octets), the initial window (65,535 octets), the frame size
/// (16,384 octets) and extended CONNECT (off), with at most
/// `--http2-max-concurrent-streams` concurrent streams, and moonhttp's own
/// bound on a header list, 64 KiB.
///
/// The `Conn` holds the client to these from the first stream, before the
/// client acknowledges them: moonhttp applies the limits that protect this
/// side as soon as it sends them.
fn h2_settings(settings : @settings.ServeSettings) -> @http2.Settings {
  @http2.Settings::new(
    header_table_size=4096,
    max_concurrent_streams=Some(settings.http2_max_concurrent_streams),
    initial_window_size=65535,
    max_frame_size~,
    max_header_list_size=Some(65536),
    enable_connect_protocol=false,
  )
}

///|
/// Serves one HTTP/2 connection, `stream`, whose client has sent the octets
/// `read` so far, and returns whether `stream` can still be written to: not
/// after a write timed out. `connection` is kept told whether the
/// connection is idle, so that a drain can close it. On the plain port,
/// `read` starts with the connection preface, which told the connection
/// apart from HTTP/1.1; on the TLS port, where ALPN did, it is empty, and
/// the `Conn` checks the preface as it comes (a wrong one gets GOAWAY
/// PROTOCOL_ERROR).
///
/// One task reads, a frame at a time, hands each frame to the connection's
/// `Conn`, and handles the events it produced, in order; before it reads
/// again, it writes what the `Conn` queued. A stream's request reaches the
/// engine when the client ends the stream, and its response is queued
/// while that event is handled, unless it waits: a response with a delay
/// is queued by a task of its own, once the delay is over, so that the
/// other streams are answered meanwhile. A stream the client resets before
/// it ends never reaches the engine, nor does one whose request HTTP/1.1's
/// rules refuse, which gets 400 instead, or whose body is over
/// `--body-limit`, which gets 413.
async fn[S : @io.Reader + @io.Writer + ReadOutput] MockPorts::serve_http2(
  self : MockPorts,
  stream : S,
  connection : Connection,
  read : Bytes,
) -> Bool {
  // Its streams' tasks write while it reads, so every write goes through
  // its writer, even what a read writes.
  ReadOutput::hold_read_output(stream)
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
    let out : WatchedStream[S] = { stream, watchdog, }
    let now = @async.now()
    let idle_timeout = self.settings.idle_timeout_ms.to_int64()
    let conn = @http2.Conn::new(Server, settings=h2_settings(self.settings))
    let h2 : H2Connection = {
      ports: self,
      conn,
      reader: FrameReader::new(read),
      writer: H2Writer::new(conn),
      requests: Map([]),
      streams: StreamRecord::new(),
      refused: 0,
      refused_status: 0,
      continuing: 0,
      waiting: Map([]),
      group,
      watchdog,
      connection,
      idle_timeout,
      read_timeout: self.settings.read_timeout_ms.to_int64(),
      now,
      read_at: now,
      idle_deadline: now + idle_timeout,
      header_at: now,
      header_stream: 0,
      became_idle: false,
      reading: false,
      closing: false,
      close_at: forever,
      last_read: Stopwatch::start(),
    }
    watchdog.expired = Some(now => h2.expire(now, out))
    watchdog.read_by(h2.idle_deadline, now)
    h2.serve(stream, out)
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
  /// Every write to the client goes through it.
  writer : H2Writer
  /// The requests in progress, by stream: begun, and neither ended nor
  /// reset by the client.
  requests : Map[Int32, H2Request]
  /// The client's streams: the highest ID seen, the streams open, and the
  /// streams this side reset.
  streams : StreamRecord
  /// The stream whose request smock refuses with `refused_status` for the
  /// frame being handled, or 0: 400 for a request HTTP/1.1's rules refuse,
  /// 413 for a body over `--body-limit`. It gets that status once it is
  /// known whether that frame ended the stream: on its `End` event, or else
  /// once the frame's events are all taken. One frame brings at most one
  /// such stream.
  mut refused : Int32
  /// The status `refused` gets.
  mut refused_status : Int32
  /// The stream whose request, begun by the frame being handled, asks for
  /// `100 Continue`, or 0. It gets it once the frame's events are all taken,
  /// unless that frame ended the stream, since then no body is to come.
  mut continuing : Int32
  /// The tasks of the streams whose response waits, by stream: from the end
  /// of the request until the response is queued, or the stream is reset.
  /// A task then lives on only to write what it queued, so each task is
  /// that of a stream in progress, and the streams waiting are never more
  /// than the concurrent streams the connection allows.
  waiting : Map[Int32, @async.Task[Unit]]
  /// The task group the connection is served in, where the tasks of
  /// waiting streams run. They end with the connection.
  group : @async.TaskGroup[Unit]
  /// The timeouts of the connection's waits on its client, and its
  /// deadlines (`expire`).
  watchdog : Watchdog
  connection : Connection
  idle_timeout : Int64
  read_timeout : Int64
  /// The time, as `@async.now()` gives it, read again after each wait of
  /// the reader: for reading or for writing.
  mut now : Int64
  /// When the last read returned.
  mut read_at : Int64
  /// While the connection is idle, when it times out: from when it opens,
  /// and from when what was queued is written after the last stream in
  /// progress ends. `forever` from when a stream begins.
  mut idle_deadline : Int64
  /// When the last field block began: the read that brought its HEADERS.
  mut header_at : Int64
  /// The stream of the last field block.
  mut header_stream : Int32
  /// Whether the last stream in progress has ended since the connection
  /// last read, so that the idle timeout starts again once what was queued
  /// is written.
  mut became_idle : Bool
  /// Whether the reader waits for more from the client.
  mut reading : Bool
  /// Whether smock has queued a GOAWAY with NO_ERROR, and closes the
  /// connection (`close_after_goaway`).
  mut closing : Bool
  /// Once that GOAWAY is written, when the connection closes if the client
  /// has not closed it first; `forever` before.
  mut close_at : Int64
  /// Started at the last read.
  mut last_read : Stopwatch
}

///|
/// Splits what the connection reads into the preface and whole frames,
/// hands each to the `Conn` and handles its events, until the connection
/// ends. A frame larger than smock advertises, or a connection error the
/// `Conn` raises, ends it with GOAWAY.
async fn[S : @io.Reader + @io.Writer + ReadOutput] H2Connection::serve(
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
            self.writer.write_last(out)
            return
          }
        }
      TooLarge => {
        self.conn.goaway(code=@http2.error_frame_size_error) catch {
          _ => ()
        }
        self.writer.write_last(out)
        return
      }
      NeedMore => {
        if !self.read_more(stream, out) {
          return
        }
        continue
      }
    }
    if !self.hand(octets, out) {
      // The GOAWAY of the `Conn`'s connection error goes out first.
      self.writer.write_last(out)
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
///
/// HEADERS that begin a field block start the read timeout of its stream's
/// request: its first frame.
fn H2Connection::judge(
  self : H2Connection,
  head : @http2.FrameHeader,
  _frame : BytesView,
) -> Int32? {
  if head.ftype == @http2.frame_headers && !self.streams.in_block {
    self.header_at = self.read_at
    self.header_stream = head.stream_id
    self.watchdog.read_by(self.read_at + self.read_timeout, self.now)
  }
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
/// GOAWAY, and the connection ends. A stream's task writes to `out`.
fn[S : @io.Writer + ReadOutput] H2Connection::hand(
  self : H2Connection,
  octets : BytesView,
  out : WatchedStream[S],
) -> Bool {
  self.conn.receive(octets) catch {
    _ => return false
  }
  for ;; {
    let event = self.conn.next() catch { _ => return false }
    match event {
      NeedData | Closed => {
        // A frame that ends the stream brings its `End` after its `Request`
        // or `Data`, so a refused request still here has not ended.
        if self.refused != 0 {
          let stream = self.refused
          self.refused = 0
          self.refuse(stream, self.refused_status, ended=false)
        }
        if self.continuing != 0 {
          let stream = self.continuing
          self.continuing = 0
          self.send_continue(stream)
        }
        // A new stream whose field block brought no `Request` event was
        // refused by moonhttp, which reports nothing for it.
        self.streams.settle()
        return true
      }
      Request(stream~, fields~) => {
        self.streams.opened(stream)
        // moonhttp refuses a stream past the limit before it reports one,
        // since smock advertised the limit; this holds the bound whatever
        // a version of moonhttp enforces.
        if self.streams.open_count() >
          self.ports.settings.http2_max_concurrent_streams {
          self.reset(stream, @http2.error_refused_stream)
          continue
        }
        let request = H2Request::new(
          fields,
          deadline=self.header_at + self.read_timeout,
        )
        if request.is_malformed() {
          self.refused = stream
          self.refused_status = 400
          continue
        }
        // Refused before any of the body is read, as on HTTP/1.1.
        if request.declared > self.ports.settings.body_limit.to_int64() {
          self.refused = stream
          self.refused_status = 413
          continue
        }
        if request.continues {
          self.continuing = stream
        }
        // The watchdog has had its deadline since its HEADERS came.
        self.idle_deadline = forever
        self.requests[stream] = request
      }
      Data(stream~, data~) => {
        if self.requests.get(stream) is Some(request) {
          // A body that passes the limit is refused before it is kept.
          if data.length() > self.ports.settings.body_limit - request.received() {
            self.requests.remove(stream)
            self.refused = stream
            self.refused_status = 413
          } else {
            request.receive(data)
          }
        }
        // Handed back as it is taken, so that the windows reopen as the
        // body arrives.
        self.conn.acknowledge(stream, data.length()) catch {
          _ => return false
        }
      }
      End(stream~) => {
        self.streams.ended_by_client(stream)
        if stream == self.continuing {
          self.continuing = 0
        }
        if stream == self.refused {
          self.refused = 0
          self.refuse(stream, self.refused_status, ended=true)
        } else if self.requests.get(stream) is Some(request) {
          self.requests.remove(stream)
          self.respond(stream, request, out)
          self.end_stream()
        }
      }
      // A reset from the client, or one moonhttp sent for the client's
      // frames.
      Reset(stream~, remote~, ..) => {
        // smock's own resets give no event, so one not from the client is
        // moonhttp's.
        if remote {
          self.streams.reset_by_client(stream)
        } else {
          self.streams.remember(stream, by_smock=false)
        }
        // moonhttp reset a refused request for one of RFC 9113's own
        // rules, such as a `content-length` that HEADERS ending the stream
        // do not match: the stream ends with that bare RST_STREAM.
        if stream == self.refused {
          self.refused = 0
        }
        if stream == self.continuing {
          self.continuing = 0
        }
        if self.requests.contains(stream) {
          self.requests.remove(stream)
          self.end_stream()
        } else {
          self.stop_waiting(stream)
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
/// Ends the wait of `stream`, reset while its response waits in a task, if
/// it does: the task is cancelled at once, and commits the stream's Journal
/// entry as it ends. Every reset of a waiting stream ends its wait here.
fn H2Connection::stop_waiting(self : H2Connection, stream : Int32) -> Unit {
  if self.waiting.get(stream) is Some(task) {
    self.waiting.remove(stream)
    task.cancel()
    self.end_stream()
  }
}

///|
/// A stream is no longer in progress. Once none is, the idle timeout runs
/// again, from when what was queued is written.
fn H2Connection::end_stream(self : H2Connection) -> Unit {
  if self.requests.is_empty() && self.waiting.is_empty() {
    self.became_idle = true
  }
}

///|
/// Whether no stream is in progress: no request arriving, no response
/// waiting, and none being written.
fn H2Connection::idle(self : H2Connection) -> Bool {
  self.requests.is_empty() && self.waiting.is_empty() && !self.writer.busy
}

///|
/// Writes what the `Conn` queued, then reads more from `stream`, and
/// returns whether the connection goes on: not once the client has closed
/// it, or smock drains and no stream is in progress, nor after a GOAWAY
/// with NO_ERROR, once what the client sends after it has been read and
/// discarded (`discard`). The read has no deadline of its own: the
/// connection's watchdog keeps them all (`expire`).
async fn[S : @io.Reader + @io.Writer + ReadOutput] H2Connection::read_more(
  self : H2Connection,
  stream : S,
  out : WatchedStream[S],
) -> Bool {
  if self.writer.write(out) {
    self.now = @async.now()
  }
  if self.closing {
    self.discard(stream)
    return false
  }
  let idle = self.idle()
  if idle && self.became_idle {
    self.idle_deadline = self.now + self.idle_timeout
    self.watchdog.read_by(self.idle_deadline, self.now)
    self.became_idle = false
  }
  if idle && self.ports.lifecycle.is_draining() {
    return false
  }
  self.connection.idle = idle
  self.reading = true
  let n = self.reader.read(stream)
  self.reading = false
  self.connection.idle = false
  guard n > 0 else { return false }
  self.last_read = Stopwatch::start()
  self.now = @async.now()
  self.read_at = self.now
  if self.closing {
    self.discard(stream)
    return false
  }
  true
}

///|
/// How long smock reads and discards what a client sends after a GOAWAY
/// with NO_ERROR, at most, before it closes the connection, in
/// milliseconds.
let closing_ms : Int64 = 1000

///|
/// Reads and discards what the client sends after a GOAWAY with NO_ERROR,
/// until it closes the connection; the watchdog closes it first after
/// `closing_ms` (`close_after_goaway`).
async fn[S : @io.Reader] H2Connection::discard(
  self : H2Connection,
  stream : S,
) -> Unit {
  self.reader.drop_held()
  while self.reader.read(stream) > 0 {
    self.reader.drop_held()
  }
}

///|
/// Called by the connection's watchdog at `now`, when the earliest
/// deadline it was given has come, or one before it that no longer
/// counts; returns the next, or one that has passed to end the
/// connection. What it queues, RST_STREAM frames or a GOAWAY, is written
/// to `out` by a task that writes it and ends, so that the watchdog never
/// waits on the client itself. While smock closes the connection after a
/// GOAWAY, the time it closes is the only deadline.
///
/// - The read timeout of each stream runs from the read that brought the
///   first frame of its request to its end. Past it, smock resets the
///   stream with CANCEL, and the other streams go on. A field block still
///   open at its stream's deadline holds the whole connection: the
///   connection gets GOAWAY with NO_ERROR and closes instead.
/// - The idle timeout runs while no stream is in progress; frames that
///   open no stream, such as PING, SETTINGS and WINDOW_UPDATE, do not
///   restart it, and a field block that has begun holds it off. Past it,
///   the connection gets GOAWAY with NO_ERROR and closes.
///
/// Neither is logged.
fn[S : @io.Writer + ReadOutput] H2Connection::expire(
  self : H2Connection,
  now : Int64,
  out : WatchedStream[S],
) -> Int64 {
  if self.closing {
    return self.close_at
  }
  if self.idle_until() <= now || self.block_deadline() <= now {
    self.go_away(out)
    return forever
  }
  let late = []
  for stream, request in self.requests {
    if request.deadline <= now {
      late.push(stream)
    }
  }
  if late.length() > 0 {
    for stream in late {
      self.reset(stream, @http2.error_cancel)
    }
    self.group.spawn_bg(no_wait=true, () => {
      let _ = self.writer.write(out)
      self.answered()
    })
  }
  self.next_deadline()
}

///|
/// The earliest deadline of the connection: the idle deadline, that of
/// each request in progress, and that of a field block still open.
fn H2Connection::next_deadline(self : H2Connection) -> Int64 {
  let mut next = self.idle_until()
  for _, request in self.requests {
    if request.deadline < next {
      next = request.deadline
    }
  }
  let block = self.block_deadline()
  if block < next {
    next = block
  }
  next
}

///|
/// When the idle timeout ends the connection: its idle deadline, unless a
/// field block has begun, which holds it off, as the first byte of a
/// request does over HTTP/1.1; `forever` then.
fn H2Connection::idle_until(self : H2Connection) -> Int64 {
  if self.streams.in_block {
    forever
  } else {
    self.idle_deadline
  }
}

///|
/// While a field block is open, the deadline of its stream's request: that
/// of the request in progress for trailers, else the read timeout after
/// the read that brought its HEADERS; `forever` while none is.
fn H2Connection::block_deadline(self : H2Connection) -> Int64 {
  guard self.streams.in_block else { return forever }
  match self.requests.get(self.header_stream) {
    Some(request) => request.deadline
    None => self.header_at + self.read_timeout
  }
}

///|
/// Queues a GOAWAY with NO_ERROR, naming the highest stream the client has
/// opened, then closes the connection once the client has read it
/// (`close_after_goaway`).
fn[S : @io.Writer + ReadOutput] H2Connection::go_away(
  self : H2Connection,
  out : WatchedStream[S],
) -> Unit {
  self.conn.goaway() catch {
    _ => ()
  }
  self.close_after_goaway(out)
}

///|
/// Closes the connection, after the GOAWAY with NO_ERROR the `Conn` has
/// queued, once the client has read it. A task writes it to `out`; from
/// then on, smock reads and discards what the client sends (`discard`),
/// until the client closes the connection, or for `closing_ms` at most
/// after the GOAWAY is written. Closing a socket with unread input makes
/// the kernel send a reset, which can discard the GOAWAY before the client
/// reads it. moonbitlang/async offers no half-close, so smock does not shut
/// down its sending side first.
fn[S : @io.Writer + ReadOutput] H2Connection::close_after_goaway(
  self : H2Connection,
  out : WatchedStream[S],
) -> Unit {
  self.closing = true
  self.group.spawn_bg(no_wait=true, () => {
    self.writer.write_last(out)
    let now = @async.now()
    self.close_at = now + closing_ms
    self.watchdog.read_by(self.close_at, now)
  })
}

///|
/// Answers the request that has arrived in full on `stream`, through the
/// steps every request to the Mocks takes. A response with no delay is
/// queued at once, while the event is handled, with no task. One with a
/// delay waits in a task of its own (`wait`), which writes to `out`.
fn[S : @io.Writer + ReadOutput] H2Connection::respond(
  self : H2Connection,
  stream : Int32,
  request : H2Request,
  out : WatchedStream[S],
) -> Unit {
  let ports = self.ports
  let incoming = request.to_engine()
  let outcome = ports.decide(
    incoming,
    authority?=request.authority,
    now=self.now,
  )
  let head = incoming.meth == "HEAD"
  if outcome.plan.delay_ms > 0 {
    self.wait(stream, outcome, head~, out)
    return
  }
  self.queue(stream, outcome.plan, outcome.journal, head~, now=self.now)
  ports.done(outcome, self.last_read)
}

///|
/// Answers `stream`, whose request the engine decided `outcome` for, and
/// was a HEAD when `head` is true, in a task of its own: once the plan's
/// delay is over, the task queues the response and writes it to `out`,
/// while the connection's other streams are answered meanwhile.
///
/// The task ends with its stream, however the stream ends: when its
/// response is queued and written, when a reset cancels it
/// (`stop_waiting`), from the client, from moonhttp for the client's
/// frames or from smock (`reset`), or when the connection ends. Until the response is queued, the
/// Journal entry is committed when the task ends, as for a client that goes
/// away, and the request is counted then.
fn[S : @io.Writer + ReadOutput] H2Connection::wait(
  self : H2Connection,
  stream : Int32,
  outcome : @engine.Outcome,
  head~ : Bool,
  out : WatchedStream[S],
) -> Unit {
  // The read that brought the request in full.
  let stopwatch = self.last_read
  let task = self.group.spawn(no_wait=true, () => {
    let ports = self.ports
    let mut entry = outcome.journal
    defer {
      ports.commit(entry)
      ports.done(outcome, stopwatch)
    }
    @async.sleep(outcome.plan.delay_ms)
    // From here on the response ends the stream, and commits the entry.
    self.waiting.remove(stream)
    entry = None
    self.queue(stream, outcome.plan, outcome.journal, head~, now=@async.now())
    let _ = self.writer.write(out)
    self.answered()
  })
  self.waiting[stream] = task
}

///|
/// A stream's task has queued its response and asked the writer to write
/// it: the stream is no longer in progress. When none is, and the reader
/// already waits on the client with no deadline, as it does while only
/// responses wait, the wait gets the idle timeout from now, and the
/// connection becomes idle; while smock drains, it closes instead.
async fn H2Connection::answered(self : H2Connection) -> Unit {
  self.end_stream()
  guard self.became_idle && self.reading && self.idle() else { return }
  if self.ports.lifecycle.is_draining() {
    self.group.return_immediately(())
    return
  }
  let now = @async.now()
  self.became_idle = false
  self.idle_deadline = now + self.idle_timeout
  self.connection.idle = true
  self.watchdog.read_by(self.idle_deadline, now)
}

///|
/// Queues on `stream`, at `now`, the response `plan` describes to a request
/// that was a HEAD when `head` is true, and commits the Journal entry
/// `entry` just before the frame that ends the stream. A response whose
/// body fits the stream's windows is queued whole: its HEADERS, then its
/// body as DATA, which ends the stream. A response to HEAD, and one whose
/// status has no content, sends no DATA: its HEADERS end the stream.
///
/// For now, a Fault, a stream of Server-Sent Events or a body that does not
/// fit end the stream with RST_STREAM INTERNAL_ERROR instead, the entry
/// committed first, as the engine made it.
fn H2Connection::queue(
  self : H2Connection,
  stream : Int32,
  plan : @engine.ResponsePlan,
  entry : @engine.JournalEntry?,
  head~ : Bool,
  now~ : Int64,
) -> Unit {
  let ports = self.ports
  guard plan.fault is None && plan.body is Bytes(body) else {
    self.reset_after(stream, entry)
    return
  }
  // HEAD gets the length of the body without the body, as on HTTP/1.1.
  let sent = if has_content(plan.status) && !head { body } else { body[0:0] }
  guard sent.length() <= self.conn.window(stream) else {
    self.reset_after(stream, entry)
    return
  }
  let fields = response_fields(
    plan.status,
    plan.headers,
    body.length(),
    date=ports.dates.at(now),
  )
  if sent.length() == 0 {
    ports.commit(entry)
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
      self.reset_after(stream, entry)
      return
    }
  }
  ports.commit(entry)
  // The body fits the windows, so the `Conn` takes it.
  self.conn.data(stream, sent, end=true) catch {
    _ => return
  }
  self.streams.ended_by_smock(stream)
}

///|
/// Answers `stream`, whose request smock refuses, with `status` and no
/// body, as HTTP/1.1 answers such a request, and counts it as rejected
/// traffic: 400 for a request HTTP/1.1's rules refuse, 413 for a body over
/// `--body-limit`. The request never reaches the engine, so it has no
/// Journal entry. A request that has not `ended` is then reset, so that the
/// client stops sending it: with PROTOCOL_ERROR after a 400, as a malformed
/// request (RFC 9113, section 8.1.1), and with NO_ERROR after a 413 (section
/// 8.1). One that has ended gets its status alone. No `connection` field is
/// sent: the response ends only its stream.
fn H2Connection::refuse(
  self : H2Connection,
  stream : Int32,
  status : Int32,
  ended~ : Bool,
) -> Unit {
  let fields = response_fields(
    status,
    [],
    0,
    date=self.ports.dates.at(self.now),
  )
  self.conn.headers(stream, fields, end=true) catch {
    _ => {
      self.reset(stream, @http2.error_internal_error)
      return
    }
  }
  self.streams.ended_by_smock(stream)
  if !ended {
    let code = if status == 400 {
      @http2.error_protocol_error
    } else {
      @http2.error_no_error
    }
    self.reset(stream, code)
  }
  self.ports.rejected(self.last_read)
  self.end_stream()
}

///|
/// Tells the client to send the body of the request on `stream`, which asks
/// for it and has not ended: `100 Continue`, with no `date`, as on HTTP/1.1
/// (RFC 9110, section 6.6.1). An informational response does not end the
/// stream.
fn H2Connection::send_continue(self : H2Connection, stream : Int32) -> Unit {
  self.conn.headers(stream, [{ name: b":status", value: b"100", }]) catch {
    // The stream is open, so moonhttp takes it.
    _ => ()
  }
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
/// progress on the stream ends with it, and so does a response waiting in
/// the stream's task, when the reset comes from outside that task.
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
  } else {
    // A task that resets its own stream has left `waiting` already.
    self.stop_waiting(stream)
  }
}
