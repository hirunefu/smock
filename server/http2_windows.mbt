// The flow control of an HTTP/2 connection's responses: a body larger than
// the client's windows goes out in a task of its own (a slow write), as the
// client widens them, while the connection's other streams go on. The
// `Conn` keeps the windows, and reports each widening as an event, which
// `H2Connection::hand` (http2.mbt) passes on to `widened`.
//
// The streams that wait for window take it in the order they began to
// wait: one woken for part of the connection window has that part set
// aside until its task has sent it, and one that has sent what its windows
// allowed waits again, behind the others. Priority signals are ignored.
//
// The write timeout runs while they wait, since a client that keeps a
// window at zero would otherwise hold their bodies for good: for the
// connection window, it closes the connection; for a stream's own window,
// it resets that stream. Each widening of the window waited for restarts
// it.

///|
/// A slow write while it waits for the client to widen a window.
priv struct WindowWait {
  /// Wakes the stream's task.
  ready : @async.CondVar
  /// How much of the body is still to send.
  mut rest : Int32
  /// Whether the task has been woken and has not run since.
  mut woken : Bool
  /// While the task is woken, how much of the connection window is set
  /// aside for it.
  mut claim : Int32
  /// While the stream's own window is at zero, when the write timeout
  /// resets the stream; `forever` while it is not (`watch_windows`).
  mut deadline : Int64
}

///|
/// The client has widened the window of `stream` with WINDOW_UPDATE, or,
/// for 0, that of the connection: progress, which restarts the write
/// timeout of the slow writes that wait for that window. Then the slow
/// writes that can send now are woken (`widened`).
fn H2Connection::window_updated(self : H2Connection, stream : Int32) -> Unit {
  if stream == 0 {
    self.window_deadline = forever
  }
  self.widened(stream)
}

///|
/// The client's SETTINGS, now in force, are `settings`. One that raised the
/// initial window has widened every stream's window by as much: progress,
/// which restarts the write timeout of the slow writes that wait for their
/// own windows. Then the slow writes that can send now are woken
/// (`widened`).
fn H2Connection::settings_received(
  self : H2Connection,
  settings : @http2.Settings,
) -> Unit {
  if settings.initial_window_size > self.initial_window {
    for _, wait in self.blocked {
      wait.deadline = forever
    }
  }
  self.initial_window = settings.initial_window_size
  self.widened(0)
}

///|
/// Starts at `now` the write timeouts of the waits for window that have
/// not started, and stops those of the waits that are over:
///
/// - the connection's, which runs from when a slow write waits while the
///   connection window has no free part, or from when that part runs out
///   while one waits, until none waits or the client widens that window;
/// - each slow write's own (`WindowWait::deadline`), which runs while its
///   stream's own window is at zero and the connection window is open,
///   until the client widens the stream's window. While the connection
///   window is at zero, `Conn::window` cannot tell, so each stays as it is.
///
/// The widenings (`window_updated`, `settings_received`) stop them, as
/// progress; this starts again those still due, from `now`. It is called
/// whenever the windows or the slow writes may have changed: by the reader
/// before each read, by a slow write before it waits, by a stream's task
/// once it is done, and by the watchdog (`H2Connection::expire`). With no
/// slow write, it costs a compare.
fn H2Connection::watch_windows(self : H2Connection, now : Int64) -> Unit {
  if self.blocked.is_empty() {
    self.window_deadline = forever
    return
  }
  let timeout = self.watchdog.write_timeout
  if self.conn.window(0) > self.claimed {
    self.window_deadline = forever
  } else if self.window_deadline == forever {
    self.window_deadline = now + timeout
    self.watchdog.read_by(self.window_deadline, now)
  }
  guard self.conn.window(0) > 0 else { return }
  for stream, wait in self.blocked {
    if wait.woken || self.conn.window(stream) > 0 {
      wait.deadline = forever
    } else if wait.deadline == forever {
      wait.deadline = now + timeout
      self.watchdog.read_by(wait.deadline, now)
    }
  }
}

///|
/// How much of a response body smock may send on `stream` now: the smaller
/// of the stream's window and the connection's, less what is set aside for
/// the other slow writes woken before it. `own` is what is still set aside
/// for the stream's own slow write, which it may send.
fn H2Connection::room(
  self : H2Connection,
  stream : Int32,
  own~ : Int32 = 0,
) -> Int32 {
  let room = self.conn.window(stream)
  let others = self.claimed - own
  guard others > 0 else { return room }
  let free = self.conn.window(0) - others
  if free <= 0 {
    0
  } else if free < room {
    free
  } else {
    room
  }
}

///|
/// The client has widened the window of `stream` with WINDOW_UPDATE, which
/// restarts the write timeout of its slow write, if it waits, or, for 0,
/// that of the connection, or every stream's with SETTINGS: the slow writes
/// that can send now are woken, in the order they began to wait, until the
/// free part of the connection window is set aside.
fn H2Connection::widened(self : H2Connection, stream : Int32) -> Unit {
  if self.blocked.is_empty() {
    return
  }
  let free = self.conn.window(0) - self.claimed
  if stream != 0 {
    if self.blocked.get(stream) is Some(wait) {
      wait.deadline = forever
      let _ = self.wake(stream, wait, free)
    }
    return
  }
  let mut free = free
  for blocked, wait in self.blocked {
    if free <= 0 {
      break
    }
    free -= self.wake(blocked, wait, free)
  }
}

///|
/// Wakes the task of the slow write of `stream`, which waits as `wait`
/// says, if it can send any of the `free` octets of the connection window
/// that are not set aside, sets aside what it will send, and returns how
/// much that is.
fn H2Connection::wake(
  self : H2Connection,
  stream : Int32,
  wait : WindowWait,
  free : Int32,
) -> Int32 {
  if wait.woken {
    return 0
  }
  let mut claim = self.conn.window(stream)
  if free < claim {
    claim = free
  }
  if wait.rest < claim {
    claim = wait.rest
  }
  if claim <= 0 {
    return 0
  }
  wait.woken = true
  wait.claim = claim
  self.claimed += claim
  wait.ready.signal()
  claim
}

///|
/// `stream` was reset while its slow write waits for window, if it does:
/// it waits no more, and what was set aside for it, if its task was woken,
/// goes to the streams waiting after it.
fn H2Connection::unblock(self : H2Connection, stream : Int32) -> Unit {
  guard self.blocked.get(stream) is Some(wait) else { return }
  self.blocked.remove(stream)
  if wait.woken {
    wait.woken = false
    self.claimed -= wait.claim
    self.widened(0)
  }
}

///|
/// Sends `rest`, the part of the body of the response on `stream` that did
/// not fit the windows when it was queued, in a task of its own, a slow
/// write, which writes to `out` (`trickle`). `outcome` is what the engine
/// decided for the request; its request is counted when the task ends.
/// With a partial Fault, `rest` is the rest of the half that Fault sends,
/// and once it is queued the task resets the stream with RST_STREAM
/// INTERNAL_ERROR (`reset_after`).
///
/// The task ends with its stream, as the task of a delay does (`wait`):
/// when the body is queued in full and written, when a reset cancels it,
/// or when the connection ends.
fn[S : @io.Writer + ReadOutput] H2Connection::write_slowly(
  self : H2Connection,
  stream : Int32,
  rest : BytesView,
  outcome : @engine.Outcome,
  out : WatchedStream[S],
) -> Unit {
  // The read that brought the request in full.
  let stopwatch = self.last_read
  let task = self.group.spawn(no_wait=true, () => {
    defer self.ports.done(outcome, stopwatch)
    let partial = outcome.plan.fault is Some(Partial)
    let finished = self.trickle(
      stream,
      rest,
      outcome.journal,
      out,
      end=!partial,
    )
    self.end_task(stream, out, finished~, reset=partial)
  })
  self.waiting[stream] = task
}

///|
/// Sends `rest`, the part of the body of the response on `stream` that did
/// not fit the windows, from the stream's task, and commits the Journal
/// entry `entry` just before the DATA frame that ends the stream, or when
/// the task is cancelled before it. Returns whether all of `rest` was
/// queued: not when a reset of the stream, or the end of the connection,
/// came first. With `end` false, the last DATA does not end the stream,
/// and `entry` is committed just before it: `rest` is one event of a
/// stream of Server-Sent Events that is not the last, or the last a partial
/// Fault sends, with `entry` `None` (`send_events`), or the rest of the
/// half of a body that a partial Fault sends, which the caller then resets.
///
/// Each time, once what was queued before is written (`drained`), it sends
/// what the windows allow, but no more than the output bound leaves for one
/// DATA frame (`H2Writer::frame_room`), and has the writer write it to
/// `out` before it sends more. So a client that does not read holds no more
/// of the body than that. When the windows allow nothing, it waits until
/// the client widens the stream's window, the connection's, or every
/// stream's with SETTINGS (`widened`). So a client that grants window a few
/// octets at a time gets one small DATA frame for each grant, and its whole
/// response in the end. What it queues last is left for the caller to
/// write.
///
/// What was set aside for the task when it was last woken stays set aside
/// while it waits for its writes, so that no stream behind it takes that
/// part of the connection window, until it has sent it or ends.
///
/// A reset of the stream cancels the task at once while it waits, as the
/// write timeout's does when a window stays at zero (`watch_windows`).
/// While it writes, the reset leaves it be (`H2Writer::write_for`), and it
/// ends as soon as the write is done.
async fn[S : @io.Writer + ReadOutput] H2Connection::trickle(
  self : H2Connection,
  stream : Int32,
  rest : BytesView,
  entry : @engine.JournalEntry?,
  out : WatchedStream[S],
  end~ : Bool = true,
) -> Bool {
  let ports = self.ports
  let mut entry = entry
  defer ports.commit(entry)
  // Made when the task first waits for window, so that an event that fits
  // the windows costs none.
  let mut held : WindowWait? = None
  let mut rest = rest
  // What is still set aside for the task since it was last woken, which
  // `claimed` counts until the task sends it.
  let mut claim = 0
  defer (if claim > 0 {
    self.claimed -= claim
    self.widened(0)
  })
  for ;; {
    // What was queued before, the task's own DATA included, goes out
    // before it queues more; the windows may widen meanwhile.
    guard self.drained(stream, out) else { return false }
    let window = self.room(stream, own=claim)
    let bound = self.writer.frame_room()
    let room = if window < bound { window } else { bound }
    let last = room >= rest.length()
    let n = if last { rest.length() } else { room }
    if last {
      ports.commit(entry)
      entry = None
    }
    if n > 0 {
      self.conn.data(stream, rest[0:n], end=last && end) catch {
        _ => return false
      }
      rest = rest[n:]
    }
    if window < claim {
      // Windows that shrank since leave part of what was set aside: the
      // streams waiting after this one may send it.
      self.claimed -= claim
      claim = 0
      self.widened(0)
    } else {
      let used = if n < claim { n } else { claim }
      claim -= used
      self.claimed -= used
    }
    if last {
      if end {
        self.streams.ended_by_smock(stream)
      }
      return true
    }
    // The bound held it back, or it sent what the windows allowed and may
    // send more once that is written.
    if window > 0 {
      continue
    }
    let wait = match held {
      Some(wait) => wait
      None => {
        let wait : WindowWait = {
          ready: @async.CondVar::Cond(),
          rest: 0,
          woken: false,
          claim: 0,
          deadline: forever,
        }
        held = Some(wait)
        wait
      }
    }
    wait.rest = rest.length()
    self.blocked[stream] = wait
    self.watch_windows(@async.now())
    wait.ready.wait()
    // A reset since the task was woken has taken it out of `blocked`.
    guard wait.woken else { return false }
    wait.woken = false
    claim = wait.claim
    self.blocked.remove(stream)
  }
}
