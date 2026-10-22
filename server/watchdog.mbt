// The timeouts of a connection's waits on its client, kept by one watchdog
// task per connection. Nothing here knows HTTP: the HTTP/1.1 connection loop
// (`serve_connection`) gives the watchdog the deadline of each read, and its
// writes go through a `WatchedStream`, which gives each write the write
// timeout.

///|
/// What a connection waits on its client for.
priv enum Wait {
  /// Nothing: smock handles a request, or waits on itself, as during a
  /// delay or between the events of a stream.
  Nothing
  /// Bytes from the client.
  Read
  /// Room for bytes it writes: the client to read what it was sent.
  Write
}

///|
/// The timeouts of one connection's waits on its client: each read has the
/// deadline it is given, and each write the write timeout from when it
/// starts to wait, which is when it starts and again after each progress.
/// Rather than each wait setting up a timer of its own, which costs a task
/// group, a task and a timer per wait, one watchdog task per connection
/// sleeps until the deadline of the wait in progress and, when that wait is
/// still in progress at its deadline, ends the connection's task group,
/// which cancels it. A wait whose deadline is later than the watchdog's
/// wake-up only moves the deadline, and the watchdog goes back to sleep
/// until it when it wakes; only a wait whose deadline is earlier starts a
/// new watchdog. The watchdog never sleeps longer than the write timeout,
/// so that a write, whose deadline is that far away, never starts one: a
/// response adds no task or timer. While nothing waits on the client, as
/// during a delay, the watchdog never ends the group.
priv struct Watchdog {
  /// The task group the connection is served in.
  group : @async.TaskGroup[Unit]
  /// The write timeout, in milliseconds.
  write_timeout : Int64
  /// What the connection waits on its client for.
  mut wait : Wait
  /// When the wait in progress times out, in `@async.now()` milliseconds.
  mut deadline : Int64
  /// When the current watchdog wakes next: `forever` before the first.
  mut wakes_at : Int64
  /// The current watchdog, by its number: a watchdog that a newer one
  /// replaced does nothing more.
  mut task : (Int, @async.Task[Unit])?
  /// Whether a write that timed out ended the group: the client then takes
  /// nothing more, and nothing more can be written to it.
  mut write_timed_out : Bool
}

///|
/// A wake-up time that never comes.
let forever : Int64 = 0x7fffffffffffffffL

///|
/// The watchdog of a connection served in `group`, whose writes time out
/// after `write_timeout` milliseconds without progress.
fn Watchdog::new(
  group : @async.TaskGroup[Unit],
  write_timeout~ : Int,
) -> Watchdog {
  {
    group,
    write_timeout: write_timeout.to_int64(),
    wait: Nothing,
    deadline: 0L,
    wakes_at: forever,
    task: None,
    write_timed_out: false,
  }
}

///|
/// A read starts waiting at `now`, as `@async.now()` gave it, until
/// `deadline` at the latest.
fn Watchdog::read(self : Watchdog, deadline : Int64, now : Int64) -> Unit {
  self.start(Read, deadline, now)
}

///|
/// A write starts waiting at `now`, as `@async.now()` gave it: when it
/// starts, or after it has made progress. It may wait until the write
/// timeout after `now`.
fn Watchdog::write(self : Watchdog, now : Int64) -> Unit {
  self.start(Write, now + self.write_timeout, now)
}

///|
/// The read or the write has stopped waiting.
fn Watchdog::stop(self : Watchdog) -> Unit {
  self.wait = Nothing
}

///|
/// `wait` starts at `now`, until `deadline` at the latest.
fn Watchdog::start(
  self : Watchdog,
  wait : Wait,
  deadline : Int64,
  now : Int64,
) -> Unit {
  self.wait = wait
  self.deadline = deadline
  if deadline < self.wakes_at {
    // The current watchdog would wake too late.
    let number = match self.task {
      Some((number, task)) => {
        task.cancel()
        number + 1
      }
      None => 0
    }
    self.wakes_at = self.wake_up(now)
    let task = self.group.spawn(no_wait=true, () => self.watch(number))
    self.task = Some((number, task))
  }
}

///|
/// When a watchdog that goes to sleep at `now` wakes: at the deadline of
/// the wait in progress, and at the latest the write timeout after `now`.
fn Watchdog::wake_up(self : Watchdog, now : Int64) -> Int64 {
  let latest = now + self.write_timeout
  if self.wait is (Read | Write) && self.deadline < latest {
    self.deadline
  } else {
    latest
  }
}

///|
/// The watchdog numbered `number`.
async fn Watchdog::watch(self : Watchdog, number : Int) -> Unit {
  while self.task is Some((current, _)) && current == number {
    let now = @async.now()
    if now >= self.wakes_at {
      if self.wait is (Read | Write) && now >= self.deadline {
        self.write_timed_out = self.wait is Write
        self.group.return_immediately(())
        return
      }
      self.wakes_at = self.wake_up(now)
    }
    @async.sleep((self.wakes_at - now).to_int())
  }
}

///|
/// A connection's byte stream, `stream`, whose writes `watchdog` bounds by
/// the write timeout. Each `write_once` that returns has made progress, so
/// that the next one has the whole write timeout again: a client that keeps
/// reading, however slowly, is never cut, while one that stops reading is,
/// the write timeout after the last bytes it took. Reads go to `stream`
/// itself, with the deadline their caller gives `watchdog`.
///
/// Over TLS, `stream` writes a whole TLS record in each `write_once`, so the
/// progress that counts is a record taken whole.
priv struct WatchedStream[S] {
  stream : S
  watchdog : Watchdog
}

///|
/// Writes what `stream` takes of `data`, reading the time first. A caller
/// that already has it, as one that has not waited since it read it, can
/// call `Watchdog::write` itself, then write to `stream`.
impl[S : @io.Writer] @io.Writer for WatchedStream[S] with fn write_once(
  self,
  data,
  offset~,
  len~,
) {
  self.watchdog.write(@async.now())
  let n = @io.Writer::write_once(self.stream, data, offset~, len~)
  self.watchdog.stop()
  n
}
