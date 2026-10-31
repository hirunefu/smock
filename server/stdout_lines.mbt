// The writer of whole lines to stdout, which every line of the mockoon log
// format goes through: smock's own log entries and the Mockoon-equivalent
// lines alike.

///|
/// Writes whole lines to stdout: each line and its newline by one write,
/// which goes on until the whole line is out. No line waits in a buffer, as
/// `println`'s would on a pipe. Lines come out in the order they are given,
/// whether by `write`, which returns once the line is out, or by `push`,
/// which a synchronous caller such as the logger uses.
///
/// The async library writes to stdout from its thread pool, one write at a
/// time, and two writes at once would abort the process, so every line goes
/// through the one `StdoutLines` of the process, which writes them in turn.
/// A line that cannot be written, as when stdout is closed, is dropped: the
/// library's event loop ignores SIGPIPE, so the write fails with EPIPE
/// rather than ending smock.
pub struct StdoutLines {
  /// Held while lines are written.
  priv turn : @async.Mutex
  /// The lines given and not written yet, oldest first.
  priv queued : @deque.Deque[String]
  /// Wakes the task that writes the lines `push` queues (`run`).
  priv pushed : @cond_var.Cond
}

///|
/// The writer of whole lines to stdout. A process has one: `smock serve`
/// creates it and hands it to the logger and to `serve`.
pub fn StdoutLines::new() -> StdoutLines {
  { turn: @async.Mutex(), queued: @deque.Deque([]), pushed: @cond_var.Cond(), }
}

///|
/// Queues `line` for the task that `run` runs, which writes it, after every
/// line given before it, as soon as the calling task lets it run. This is
/// how a synchronous caller, such as the logger, writes a line: it cannot
/// wait for the write itself.
pub fn StdoutLines::push(self : StdoutLines, line : String) -> Unit {
  self.queued.push_back(line)
  self.pushed.signal()
}

///|
/// Writes `line` and a newline to stdout, after every line given before it,
/// or drops it when it cannot be written, and returns once it is out. A
/// line, once given, is written whole even when the task is cancelled
/// meanwhile, as when the drain cuts its connection.
async fn StdoutLines::write(self : StdoutLines, line : String) -> Unit {
  self.queued.push_back(line)
  self.flush()
}

///|
/// Writes every line given and not written yet, and returns once they are
/// out, even when the task is cancelled meanwhile. `serve` calls it last,
/// so that no line is left when the process exits.
async fn StdoutLines::flush(self : StdoutLines) -> Unit {
  @async.protect_from_cancel(() => {
    self.turn.acquire()
    defer self.turn.release()
    // Lines given while one is written are written in the same turn, so
    // that whoever waits for the turn finds its own line already out.
    while self.queued.pop_front() is Some(line) {
      let bytes = @buffer.Buffer(size_hint=line.length() + 1)
      bytes.write_string_utf8(line)
      bytes.write_byte(b'\n')
      @stdio.stdout.write(bytes.to_bytes()) catch {
        _ => ()
      }
    }
  })
}

///|
/// Writes the lines `push` queues, as they come, until the task is
/// cancelled.
async fn StdoutLines::run(self : StdoutLines) -> Unit {
  for ;; {
    if self.queued.is_empty() {
      self.pushed.wait()
    } else {
      self.flush()
    }
  }
}
