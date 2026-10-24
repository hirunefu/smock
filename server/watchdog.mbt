// The timeouts of a connection's waits on its client, kept by one
// `Watchdog` per connection, which runs one sleeper task at a time. Nothing
// here knows HTTP: the HTTP/1.1 and HTTP/2 connection loops
// (`serve_connection`, `MockPorts::serve_http2`) give the watchdog the
// deadline of each read, and their writes go through a `WatchedStream`,
// which gives each write the write timeout.

///|
/// The timeouts of one connection's waits on its client: each read has the
/// deadline it is given, and each write the write timeout from when it
/// starts to wait, which is when it starts and again after each progress.
/// A read and a write may wait at once, as on an HTTP/2 connection, whose
/// streams' tasks write while it reads; each keeps its own deadline.
///
/// Rather than each wait setting up a timer of its own, which costs a task
/// group, a task and a timer per wait, the watchdog runs one task per
/// connection, its sleeper, which sleeps until the earliest deadline of the
/// waits in progress and, when a wait is still in progress at its deadline,
/// ends the connection's task group, which cancels it. A wait whose
/// deadline is later than the sleeper's wake-up only moves the deadline,
/// and the sleeper goes back to sleep until it when it wakes; only a wait
/// whose deadline is earlier replaces the sleeper with a new one. A sleeper
/// never sleeps longer than the write timeout, so that a write, whose
/// deadline is that far away, never starts one: a response adds no task or
/// timer. While nothing waits on the client, as during a delay, the sleeper
/// never ends the group.
priv struct Watchdog {
  /// The task group the connection is served in.
  group : @async.TaskGroup[Unit]
  /// The write timeout, in milliseconds.
  write_timeout : Int64
  /// While a read waits for bytes from the client, when it times out, in
  /// `@async.now()` milliseconds; `forever` while none waits.
  mut read_deadline : Int64
  /// While a write waits for room for its bytes, for the client to read
  /// what it was sent, when it times out; `forever` while none waits.
  mut write_deadline : Int64
  /// When the current sleeper wakes next: `forever` before the first.
  mut wakes_at : Int64
  /// The current sleeper, by its number: a sleeper that a newer one
  /// replaced does nothing more.
  mut sleeper : (Int32, @async.Task[Unit])?
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
  write_timeout~ : Int32,
) -> Watchdog {
  {
    group,
    write_timeout: write_timeout.to_int64(),
    read_deadline: forever,
    write_deadline: forever,
    wakes_at: forever,
    sleeper: None,
    write_timed_out: false,
  }
}

///|
/// A read starts waiting at `now`, as `@async.now()` gave it, until
/// `deadline` at the latest. A read already waiting gets that deadline.
fn Watchdog::reading(self : Watchdog, deadline : Int64, now : Int64) -> Unit {
  self.read_deadline = deadline
  self.start(now)
}

///|
/// A write starts waiting at `now`, as `@async.now()` gave it: when it
/// starts, or after it has made progress. It may wait until the write
/// timeout after `now`.
fn Watchdog::writing(self : Watchdog, now : Int64) -> Unit {
  self.write_deadline = now + self.write_timeout
  self.start(now)
}

///|
/// The read has stopped waiting.
fn Watchdog::stop_reading(self : Watchdog) -> Unit {
  self.read_deadline = forever
}

///|
/// The write has stopped waiting.
fn Watchdog::stop_writing(self : Watchdog) -> Unit {
  self.write_deadline = forever
}

///|
/// When the first of the waits in progress times out: `forever` while
/// none is in progress.
fn Watchdog::deadline(self : Watchdog) -> Int64 {
  if self.read_deadline < self.write_deadline {
    self.read_deadline
  } else {
    self.write_deadline
  }
}

///|
/// A wait has started at `now`, or its deadline has moved: a new sleeper
/// replaces the current one when that one would wake too late.
fn Watchdog::start(self : Watchdog, now : Int64) -> Unit {
  if self.deadline() < self.wakes_at {
    let number = match self.sleeper {
      Some((number, sleeper)) => {
        sleeper.cancel()
        number + 1
      }
      None => 0
    }
    self.wakes_at = self.wake_up(now)
    let sleeper = self.group.spawn(no_wait=true, () => self.run_sleeper(number))
    self.sleeper = Some((number, sleeper))
  }
}

///|
/// When a sleeper that goes to sleep at `now` wakes: at the first deadline
/// of the waits in progress, and at the latest the write timeout after
/// `now`.
fn Watchdog::wake_up(self : Watchdog, now : Int64) -> Int64 {
  let latest = now + self.write_timeout
  let deadline = self.deadline()
  if deadline < latest {
    deadline
  } else {
    latest
  }
}

///|
/// The sleeper numbered `number`, until a newer one replaces it: it sleeps
/// until its wake-up, then ends the group when a wait in progress is past
/// its deadline, and otherwise sleeps again.
async fn Watchdog::run_sleeper(self : Watchdog, number : Int32) -> Unit {
  while self.sleeper is Some((current, _)) && current == number {
    let now = @async.now()
    if now >= self.wakes_at {
      if now >= self.deadline() {
        self.write_timed_out = now >= self.write_deadline
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
/// call `Watchdog::writing` itself, then write to `stream`.
impl[S : @io.Writer] @io.Writer for WatchedStream[S] with fn write_once(
  self,
  data,
  offset~,
  len~,
) {
  self.watchdog.writing(@async.now())
  let n = @io.Writer::write_once(self.stream, data, offset~, len~)
  self.watchdog.stop_writing()
  n
}
