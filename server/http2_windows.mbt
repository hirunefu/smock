// The flow control of an HTTP/2 connection's responses: a body larger than
// the client's windows goes out in a task of its own (a slow write), as the
// client widens them, while the connection's other streams go on. The
// `Conn` keeps the windows, and reports each widening as an event, which
// `H2Connection::hand` (http2.mbt) passes on to `widened`.
//
// The streams that wait for window take it in the order they began to
// wait: one woken for part of the connection window has that part set
// aside until its task runs, and one that has sent what its windows
// allowed waits again, behind the others. Priority signals are ignored.

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
}

///|
/// How much of a response body smock may send on `stream` now: the smaller
/// of the stream's window and the connection's, less what is set aside for
/// the slow writes woken before it.
fn H2Connection::room(self : H2Connection, stream : Int32) -> Int32 {
  let room = self.conn.window(stream)
  guard self.claimed > 0 else { return room }
  let free = self.conn.window(0) - self.claimed
  if free <= 0 {
    0
  } else if free < room {
    free
  } else {
    room
  }
}

///|
/// The client has widened the window of `stream`, or, for 0, that of the
/// connection, or every stream's with SETTINGS: the slow writes that can
/// send now are woken, in the order they began to wait, until the free
/// part of the connection window is set aside.
fn H2Connection::widened(self : H2Connection, stream : Int32) -> Unit {
  if self.blocked.is_empty() {
    return
  }
  let free = self.conn.window(0) - self.claimed
  if stream != 0 {
    if self.blocked.get(stream) is Some(wait) {
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
    let _ = self.trickle(stream, rest, outcome.journal, out)
    self.waiting.remove(stream)
    let _ = self.writer.write(out)
    self.answered(out)
  })
  self.waiting[stream] = task
}

///|
/// Sends `rest`, the part of the body of the response on `stream` that did
/// not fit the windows, from the stream's task, and commits the Journal
/// entry `entry` just before the DATA frame that ends the stream, or when
/// the task is cancelled before it. Returns whether all of `rest` was
/// queued: not when a reset of the stream, or the end of the connection,
/// came first. With `end` false, `rest` is one event of a stream of
/// Server-Sent Events that is not the last (`send_events`): it does not
/// end the stream, and `entry` is `None`.
///
/// Each time, it sends what the windows allow, in DATA frames no larger
/// than the client's frame size, and has the writer write them to `out`.
/// When the windows allow nothing, it waits until the client widens the
/// stream's window, the connection's, or every stream's with SETTINGS
/// (`widened`). So a client that grants window a few octets at a time gets
/// one small DATA frame for each grant, and its whole response in the end.
/// What it queues last is left for the caller to write.
///
/// A reset of the stream cancels the task at once while it waits. While it
/// writes, the reset leaves it be (`H2Writer::write_for`), and it ends as
/// soon as the write is done.
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
  // What was set aside for the task when it was last woken.
  let mut claim = 0
  for ;; {
    let room = self.room(stream)
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
    if n < claim {
      // Windows that shrank since leave part of what was set aside: the
      // streams waiting after this one may send it.
      self.widened(0)
    }
    claim = 0
    if last {
      if end {
        self.streams.ended_by_smock(stream)
      }
      return true
    }
    // What is queued, the HEADERS included, goes out before the task waits;
    // the windows may widen while the writer writes.
    let wrote = self.writer.write_for(out, stream)
    // A reset while the task wrote did not cancel it: it ends now.
    guard self.waiting.contains(stream) else { return false }
    if wrote || n > 0 {
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
        }
        held = Some(wait)
        wait
      }
    }
    wait.rest = rest.length()
    self.blocked[stream] = wait
    wait.ready.wait()
    // A reset since the task was woken has taken it out of `blocked`.
    guard wait.woken else { return false }
    wait.woken = false
    claim = wait.claim
    self.claimed -= claim
    self.blocked.remove(stream)
  }
}
