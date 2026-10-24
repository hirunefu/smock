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
//   which the judge holds HEADERS frames against, which counts the streams
//   open against `--http2-max-concurrent-streams`, and which every
//   RST_STREAM smock sends goes into, through `H2Connection::reset`;
// - the mapping from a stream onto the engine's request (`H2Request`,
//   http2_requests.mbt);
// - the response encoding (`response_fields`, http2_responses.mbt);
// - the writing of what the `Conn` queues, through the connection's one
//   writer (`H2Writer`, http2_output.mbt);
// - the tasks of the streams whose responses wait (`H2Connection::wait`),
//   and the slow writes of bodies larger than the client's windows, which
//   resume as the client widens them (`H2Connection::write_slowly`,
//   http2_windows.mbt).
//
// Each stream's request takes the steps every request to the Mocks takes
// (requests.mbt). Until they get forms of their own, some cases are served
// in an interim way, so that a client's run ends rather than hangs:
//
// - a Fault or a stream of Server-Sent Events ends its stream with
//   RST_STREAM INTERNAL_ERROR, its Journal entry committed as the engine
//   made it;
// - one watch for the whole connection, as on HTTP/1.1: the idle timeout
//   while no stream is in progress, and the read timeout while a request
//   is arriving, from the read that brought the HEADERS of the first one
//   in progress; none while only responses wait, since a delay is smock's
//   own wait, nor while a body waits for the client to widen a window;
//   past it, the connection closes without GOAWAY;
// - for the drain, the connection is idle while no stream is in progress,
//   and while smock drains, it closes, without GOAWAY, as soon as none is;
// - no body or header limit applies beyond moonhttp's own.

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
/// `read`, the connection preface first, and returns whether `stream` can
/// still be written to: not after a write timed out. `connection` is kept
/// told whether the connection is idle, so that a drain can close it.
///
/// One task reads, a frame at a time, hands each frame to the connection's
/// `Conn`, and handles the events it produced, in order; before it reads
/// again, it writes what the `Conn` queued. A stream's request reaches the
/// engine when the client ends the stream, and its response is queued
/// while that event is handled, unless it waits: a response with a delay
/// is queued by a task of its own, once the delay is over, and a body
/// larger than the client's windows goes out from a task of its own as the
/// client widens them, so that the other streams are answered meanwhile. A
/// stream the client resets before it ends never reaches the engine.
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
    let conn = @http2.Conn::new(Server, settings=h2_settings(self.settings))
    let h2 : H2Connection = {
      ports: self,
      conn,
      reader: FrameReader::new(read),
      writer: H2Writer::new(conn),
      requests: Map([]),
      streams: StreamRecord::new(),
      waiting: Map([]),
      blocked: Map([]),
      claimed: 0,
      group,
      watchdog,
      connection,
      idle_timeout,
      read_timeout: self.settings.read_timeout_ms.to_int64(),
      now,
      read_at: now,
      idle_deadline: now + idle_timeout,
      read_deadline: now,
      became_idle: false,
      reading: false,
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
  /// Every write to the client goes through it.
  writer : H2Writer
  /// The requests in progress, by stream: begun, and neither ended nor
  /// reset by the client.
  requests : Map[Int32, H2Request]
  /// The client's streams: the highest ID seen, the streams open, and the
  /// streams this side reset.
  streams : StreamRecord
  /// The tasks of the streams whose response waits, by stream: from the end
  /// of the request until the response is queued in full, its body
  /// included, or the stream is reset. A task then lives on only to write
  /// what it queued, so each task is that of a stream in progress, and the
  /// streams waiting are never more than the concurrent streams the
  /// connection allows.
  waiting : Map[Int32, @async.Task[Unit]]
  /// The slow writes waiting for the client to widen a window, by stream,
  /// in the order they began to wait, which a `Map` keeps.
  blocked : Map[Int32, WindowWait]
  /// The octets of the connection window that the slow writes woken from
  /// `blocked`, whose tasks have not run yet, are to send, so that no other
  /// stream takes them meanwhile.
  mut claimed : Int32
  /// The task group the connection is served in, where the tasks of
  /// waiting streams run. They end with the connection.
  group : @async.TaskGroup[Unit]
  /// The timeouts of the connection's waits on its client.
  watchdog : Watchdog
  connection : Connection
  idle_timeout : Int64
  read_timeout : Int64
  /// The time, as `@async.now()` gives it, read again after each wait of
  /// the reader: for reading or for writing.
  mut now : Int64
  /// When the last read returned.
  mut read_at : Int64
  /// While no stream is in progress, when the connection times out.
  mut idle_deadline : Int64
  /// While a request is arriving, when the connection times out.
  mut read_deadline : Int64
  /// Whether the last stream in progress has ended since the connection
  /// last read, so that the idle timeout starts again once what was queued
  /// is written.
  mut became_idle : Bool
  /// Whether the reader waits for more from the client.
  mut reading : Bool
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
/// GOAWAY, and the connection ends. A stream's task writes to `out`.
fn[S : @io.Writer] H2Connection::hand(
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
        if self.requests.is_empty() {
          self.read_deadline = self.read_at + self.read_timeout
        }
        self.requests[stream] = H2Request::new(fields)
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
          self.respond(stream, request, out)
          self.end_stream()
        }
      }
      // A window the client widened, of a stream or of the connection, or
      // every stream's, by a SETTINGS frame that raised the initial window.
      WindowUpdated(stream~, ..) => self.widened(stream)
      Settings(_) => self.widened(0)
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
        if self.requests.contains(stream) {
          self.requests.remove(stream)
          self.end_stream()
        } else {
          self.stop_waiting(stream)
        }
      }
      // Trailers are ignored. The `Conn` has acknowledged SETTINGS and
      // answered PING itself, and the client's GOAWAY asks nothing of a
      // stream.
      _ => ()
    }
  }
}

///|
/// Ends the wait of `stream`, reset while its response waits in a task, if
/// it does: the task is cancelled at once, and commits the stream's Journal
/// entry as it ends. Every reset of a waiting stream ends its wait here,
/// whether it waits for its delay or for a window.
fn H2Connection::stop_waiting(self : H2Connection, stream : Int32) -> Unit {
  if self.waiting.get(stream) is Some(task) {
    self.waiting.remove(stream)
    task.cancel()
    self.writer.abandon(stream)
    self.unblock(stream)
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
/// it, its timeout has passed, or smock drains and no stream is in
/// progress.
async fn[S : @io.Reader + @io.Writer] H2Connection::read_more(
  self : H2Connection,
  stream : S,
  out : WatchedStream[S],
) -> Bool {
  if self.writer.abandoned {
    // A stream's task was cancelled while it wrote: the reader waits for
    // it to stop, then writes what it left.
    self.writer.abandoned = false
    self.writer.write_last(out)
    self.now = @async.now()
  } else if self.writer.write(out) {
    self.now = @async.now()
  }
  let idle = self.idle()
  if idle && self.became_idle {
    self.idle_deadline = self.now + self.idle_timeout
    self.became_idle = false
  }
  if idle && self.ports.lifecycle.is_draining() {
    return false
  }
  // While only responses wait, the read has no deadline: the task that
  // ends the last of them gives it the idle timeout (`answered`).
  let deadline = if !self.requests.is_empty() {
    self.read_deadline
  } else if idle {
    self.idle_deadline
  } else {
    forever
  }
  if deadline - self.now <= 0L {
    return false
  }
  self.connection.idle = idle
  // Past the deadline, the watchdog ends the task group, and with it this
  // read and the connection.
  self.reading = true
  self.watchdog.reading(deadline, self.now)
  let n = self.reader.read(stream)
  self.watchdog.stop_reading()
  self.reading = false
  self.connection.idle = false
  guard n > 0 else { return false }
  self.last_read = Stopwatch::start()
  self.now = @async.now()
  self.read_at = self.now
  true
}

///|
/// Answers the request that has arrived in full on `stream`, through the
/// steps every request to the Mocks takes. A response with no delay whose
/// body fits the windows is queued at once, while the event is handled,
/// with no task. One with a delay waits in a task of its own (`wait`), and
/// so does the rest of a body larger than the windows (`write_slowly`);
/// each writes to `out`.
fn[S : @io.Writer] H2Connection::respond(
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
  let rest = self.queue(
    stream,
    outcome.plan,
    outcome.journal,
    head~,
    now=self.now,
  )
  if rest.length() > 0 {
    self.write_slowly(stream, rest, outcome, out)
    return
  }
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
/// frames or from smock (`reset`), or when the connection ends. A body
/// larger than the windows keeps the task until it is queued in full
/// (`trickle`). Until the response is queued, the Journal entry is
/// committed when the task ends, as for a client that goes away, and the
/// request is counted then.
fn[S : @io.Writer] H2Connection::wait(
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
    entry = None
    let rest = self.queue(
      stream,
      outcome.plan,
      outcome.journal,
      head~,
      now=@async.now(),
    )
    if rest.length() > 0 {
      self.trickle(stream, rest, outcome.journal, out)
    }
    self.waiting.remove(stream)
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
  self.watchdog.reading(self.idle_deadline, now)
}

///|
/// Queues on `stream`, at `now`, the response `plan` describes to a request
/// that was a HEAD when `head` is true, and commits the Journal entry
/// `entry` just before the frame that ends the stream. A response whose
/// body fits the stream's windows is queued whole: its HEADERS, then its
/// body as DATA, which ends the stream. A response to HEAD, and one whose
/// status has no content, sends no DATA: its HEADERS end the stream.
///
/// A body that does not fit gets its HEADERS and as much of the body as the
/// windows allow; `queue` then returns the rest, which the caller sends in
/// the stream's task as the windows widen (`trickle`), with the entry still
/// to commit. Otherwise it returns nothing.
///
/// For now, a Fault or a stream of Server-Sent Events ends the stream with
/// RST_STREAM INTERNAL_ERROR instead, the entry committed first, as the
/// engine made it.
///
/// It runs while the event is handled, when the stream has no task, or in
/// the stream's own task, which goes on once it returns: so a reset here
/// leaves the task be.
fn H2Connection::queue(
  self : H2Connection,
  stream : Int32,
  plan : @engine.ResponsePlan,
  entry : @engine.JournalEntry?,
  head~ : Bool,
  now~ : Int64,
) -> BytesView {
  let ports = self.ports
  guard plan.fault is None && plan.body is Bytes(body) else {
    self.reset_after(stream, entry)
    return b""
  }
  // HEAD gets the length of the body without the body, as on HTTP/1.1.
  let sent = if has_content(plan.status) && !head { body } else { body[0:0] }
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
        return sent
      }
    }
    self.streams.ended_by_smock(stream)
    return sent
  }
  self.conn.headers(stream, fields) catch {
    _ => {
      self.reset_after(stream, entry)
      return sent[0:0]
    }
  }
  let room = self.room(stream)
  if sent.length() > room {
    if room > 0 {
      self.conn.data(stream, sent[0:room]) catch {
        _ => return sent[0:0]
      }
    }
    return sent[room:]
  }
  ports.commit(entry)
  // The body fits the windows, so the `Conn` takes it.
  self.conn.data(stream, sent, end=true) catch {
    _ => return sent[0:0]
  }
  self.streams.ended_by_smock(stream)
  sent[0:0]
}

///|
/// Commits the Journal entry `entry`, if there is one, then ends `stream`
/// with RST_STREAM INTERNAL_ERROR. It is called from `queue`, so the reset
/// leaves the stream's task be.
fn H2Connection::reset_after(
  self : H2Connection,
  stream : Int32,
  entry : @engine.JournalEntry?,
) -> Unit {
  self.ports.commit(entry)
  self.reset(stream, @http2.error_internal_error, own_task=true)
}

///|
/// Ends `stream` with RST_STREAM `code`, and records that smock reset it,
/// so that frames the client sent on it before it learnt of the reset are
/// ignored (RFC 9113, section 5.1). Every RST_STREAM smock sends goes
/// through here; moonhttp's own come as `Reset` events. A request still in
/// progress on the stream ends with it, and so does a response waiting in
/// the stream's task, unless `own_task` is true: the stream's own task
/// resets it, and ends itself.
fn H2Connection::reset(
  self : H2Connection,
  stream : Int32,
  code : Int32,
  own_task~ : Bool = false,
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
  } else if !own_task {
    self.stop_waiting(stream)
  }
}
