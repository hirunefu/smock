// Server-Sent Events on an HTTP/2 connection: one event stream per HTTP/2
// stream. Its HEADERS go out as soon as the response is due, and its events
// from a task of its own, each after its delay, so that the connection's
// other streams, other event streams among them, go on meanwhile. The DATA
// of the last event ends the HTTP/2 stream. A reset of the stream, from the
// client or by moonhttp for the client's frames, cancels the task at once
// (`H2Connection::stop_waiting`, http2.mbt), as it does a delay.

///|
/// Answers `stream`, whose request the engine decided `outcome` for, a
/// stream of Server-Sent Events `events` with no delay of its own, and was
/// a HEAD when `head` is true, or a CONNECT when `connect` is true: its
/// HEADERS are queued at once, while the event is handled, and its events
/// go out from a task of its own, which writes to `out` (`send_events`). A
/// response with no body is its HEADERS alone, and needs no task
/// (`open_events`).
///
/// The task ends with its stream, as the task of a delay does
/// (`H2Connection::wait`): when its last event is queued and written, when
/// a reset cancels it, or when the connection ends. The request is counted
/// then.
fn[S : @io.Writer + ReadOutput] H2Connection::start_events(
  self : H2Connection,
  stream : Int32,
  outcome : @engine.Outcome,
  events : ReadOnlyArray[@definitions.SseEvent],
  head~ : Bool,
  connect~ : Bool,
  out : WatchedStream[S],
) -> Unit {
  let ports = self.ports
  // The read that brought the request in full.
  let stopwatch = self.last_read
  let more = self.open_events(
    stream,
    outcome.plan,
    outcome.journal,
    events.length(),
    head~,
    connect~,
    now=self.now,
  )
  if !more {
    ports.done(outcome, stopwatch)
    return
  }
  let task = self.group.spawn(no_wait=true, () => {
    defer ports.done(outcome, stopwatch)
    let partial = outcome.plan.fault is Some(Partial)
    if self.send_events(stream, events, outcome.journal, out, partial~) &&
      partial {
      self.reset_after(stream, None)
    }
    self.waiting.remove(stream)
    let _ = self.writer.write(out)
    self.answered()
  })
  self.waiting[stream] = task
}

///|
/// Queues on `stream`, at `now`, the HEADERS of the stream of `count`
/// Server-Sent Events that `plan` describes, to a request that was a HEAD
/// when `head` is true, or a CONNECT when `connect` is true: the plan's
/// status and headers, among them the `content-type: text/event-stream`
/// the engine gives every event stream, and no `content-length`, since the
/// length of the events is not known. Returns whether the events are to
/// follow (`send_events`), with the Journal entry `entry` still to commit.
///
/// A response with no body, to HEAD, with status 204 or 304, or with no
/// events, is its HEADERS alone, which end the stream, with `entry`
/// committed just before: no event is waited for, as over HTTP/1.1. So is
/// a 2xx to a CONNECT, which has no content over HTTP/2 (`has_content`).
///
/// It runs while the event is handled, or in the stream's own task after a
/// delay, which goes on once it returns: so a reset here leaves the task
/// be.
fn H2Connection::open_events(
  self : H2Connection,
  stream : Int32,
  plan : @engine.ResponsePlan,
  entry : @engine.JournalEntry?,
  count : Int32,
  head~ : Bool,
  connect~ : Bool,
  now~ : Int64,
) -> Bool {
  let ports = self.ports
  let partial = plan.fault is Some(Partial)
  let fields = response_fields(
    plan.status,
    plan.headers,
    0,
    date=ports.dates.at(now),
    streamed=true,
  )
  let sent = if partial { count / 2 } else { count }
  if head || sent == 0 || !has_content(plan.status, connect~) {
    if partial {
      self.conn.headers(stream, fields) catch {
        _ => {
          self.reset_after(stream, entry)
          return false
        }
      }
      self.reset_after(stream, entry)
      return false
    }
    ports.commit(entry)
    self.conn.headers(stream, fields, end=true) catch {
      _ => {
        self.reset_after(stream, None)
        return false
      }
    }
    self.streams.ended_by_smock(stream)
    return false
  }
  self.conn.headers(stream, fields) catch {
    _ => {
      self.reset_after(stream, entry)
      return false
    }
  }
  true
}

///|
/// Sends `events`, the events of the stream of Server-Sent Events on
/// `stream`, whose HEADERS are queued, from the stream's task: each after
/// its delay, counted from the event before it or, for the first, from the
/// HEADERS, encoded as over HTTP/1.1, as DATA within the windows and the
/// client's frame size (`trickle`). Each event is written to `out` before
/// the next one's delay; the DATA of the last one ends the stream, and the
/// caller writes it. The Journal entry `entry` is committed just before
/// the last event, or when the task is cancelled before it.
///
/// A reset of the stream cancels the task at once, during a delay or while
/// an event waits for window; one while the task writes ends it as soon as
/// the write is done.
async fn[S : @io.Writer + ReadOutput] H2Connection::send_events(
  self : H2Connection,
  stream : Int32,
  events : ReadOnlyArray[@definitions.SseEvent],
  entry : @engine.JournalEntry?,
  out : WatchedStream[S],
  partial~ : Bool,
) -> Bool {
  let ports = self.ports
  let mut entry = entry
  defer ports.commit(entry)
  // The HEADERS, queued before the task began, go out before the first
  // event's delay.
  let _ = self.writer.write_for(out, stream)
  guard self.waiting.contains(stream) else { return false }
  let count = if partial { events.length() / 2 } else { events.length() }
  let last = count - 1
  for i in 0..<count {
    let event = events[i]
    if event.delay_ms > 0 {
      @async.sleep(event.delay_ms)
    }
    let data = @http1.encode_sse_event(
      event.data,
      event?=event.event,
      id?=event.id,
    )
    let ends = i == last && !partial
    if ends {
      ports.commit(entry)
      entry = None
    }
    guard self.trickle(stream, data, None, out, end=ends) else { return false }
    if i == last {
      return true
    }
    let _ = self.writer.write_for(out, stream)
    // A reset while the task wrote did not cancel it: it ends now.
    guard self.waiting.contains(stream) else { return false }
  }
  true
}
