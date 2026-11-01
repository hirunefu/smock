// The writer of whole lines to stdout, which every line of the mockoon log
// format goes through: smock's own log entries and the Mockoon-equivalent
// lines alike.

///|
/// Writes whole lines to stdout: each line and its newline by one write,
/// which goes on until the whole line is out. No line waits in a buffer that
/// holds lines back, as `println`'s would on a pipe. Lines come out in the
/// order they are given, whether by `write`, which returns once the line is
/// out, or by `push`, which a synchronous caller such as the logger uses.
///
/// The async library writes to stdout from its thread pool, so a write that
/// waits, as when the reader of stdout stops reading, holds up only the task
/// that waits for it: every other connection goes on. A request's lines are
/// written by `write`, which its own task waits for. smock's own lines,
/// which `push` gives, wait in a queue of at most `own_line_bound` lines,
/// and a line beyond it is dropped and counted (`LogMetrics`), so a stalled
/// reader never makes smock's memory grow without bound.
///
/// Two writes to stdout at once would abort the process, so every line goes
/// through the one `StdoutLines` of the process, which writes them in turn.
/// A line that cannot be written, as when stdout is closed, is dropped: the
/// library's event loop ignores SIGPIPE, so the write fails with EPIPE
/// rather than ending smock.
pub struct StdoutLines {
  /// The lines given and not written yet, oldest first.
  priv queued : @deque.Deque[String]
  /// Whether each line of `queued`, in the same order, is one of smock's
  /// own, which `push` gave.
  priv own : @deque.Deque[Bool]
  /// How many lines of `queued` are smock's own.
  priv own_queued : Ref[Int32]
  /// How many of smock's own lines `push` dropped because `own_line_bound`
  /// of them were waiting.
  priv mut dropped : Int64
  /// Wakes the task that writes the lines `push` queues (`run`).
  priv pushed : @cond_var.Cond
  /// Writes every line queued, in its turn: `flush` runs it protected from
  /// cancellation. It is made once, with the writer, so that `flush` makes
  /// no closure for each line.
  priv write_queued : async () -> Unit
}

///|
/// The most of smock's own lines that wait to be written, when stdout is
/// slow or its reader has stopped reading.
let own_line_bound = 1024

///|
/// The writer of whole lines to stdout. A process has one in the mockoon
/// log format, and none in the json format: `smock serve` creates it and
/// hands it to the logger and to `serve`.
pub fn StdoutLines::new() -> StdoutLines {
  StdoutLines::writing_to(async fn(bytes) noraise {
    @stdio.stdout.write(bytes) catch {
      _ => ()
    }
  })
}

///|
/// A writer of whole lines through `sink`, which writes each line's bytes:
/// to stdout, or, in tests, wherever a test wants them.
fn StdoutLines::writing_to(sink : async (Bytes) -> Unit noraise) -> StdoutLines {
  // Held while lines are written.
  let turn = @async.Mutex()
  let queued = @deque.Deque([])
  let own = @deque.Deque([])
  let own_queued = Ref(0)
  {
    queued,
    own,
    own_queued,
    dropped: 0L,
    pushed: @cond_var.Cond(),
    write_queued: async fn() {
      turn.acquire()
      defer turn.release()
      // Lines given while one is written are written in the same turn, so
      // that whoever waits for the turn finds its own line already out.
      while queued.pop_front() is Some(line) {
        if own.pop_front() is Some(true) {
          own_queued.val -= 1
        }
        let bytes = @buffer.Buffer(size_hint=line.length() + 1)
        bytes.write_string_utf8(line)
        bytes.write_byte(b'\n')
        sink(bytes.to_bytes())
      }
    },
  }
}

///|
/// Queues `line`, one of smock's own, for the task that `run` runs, which
/// writes it, after every line given before it, as soon as the calling task
/// lets it run. This is how a synchronous caller, such as the logger,
/// writes a line: it cannot wait for the write itself. When
/// `own_line_bound` of smock's own lines are waiting already, `line` is
/// dropped and counted instead.
pub fn StdoutLines::push(self : StdoutLines, line : String) -> Unit {
  if self.own_queued.val >= own_line_bound {
    self.dropped += 1L
    return
  }
  self.queued.push_back(line)
  self.own.push_back(true)
  self.own_queued.val += 1
  self.pushed.signal()
}

///|
/// Writes `line` and a newline to stdout, after every line given before it,
/// or drops it when it cannot be written, and returns once it is out. Only
/// the calling task waits for it, however long stdout takes. A line, once
/// given, is written whole even when the task is cancelled meanwhile, as
/// when the drain cuts its connection.
async fn StdoutLines::write(self : StdoutLines, line : String) -> Unit {
  self.queued.push_back(line)
  self.own.push_back(false)
  self.flush()
}

///|
/// Writes every line given and not written yet, and returns once they are
/// out, even when the task is cancelled meanwhile. `serve` calls it last,
/// so that no line is left when the process exits.
async fn StdoutLines::flush(self : StdoutLines) -> Unit {
  @async.protect_from_cancel(self.write_queued)
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

///|
/// The metric of the lines of smock's own that the mockoon log format
/// dropped because its queue was full, read from `StdoutLines` when
/// `/metrics` is scraped, so writing a line costs nothing for it. It is 0
/// in the json format, which writes no line through `StdoutLines`.
priv struct LogMetrics {
  /// `smock_log_lines_dropped_total`.
  dropped : @metrics.CounterSeries
  /// The writer of the mockoon log format, or `None` in the json format.
  stdout : StdoutLines?
  /// The dropped lines the counter has counted so far.
  mut counted : Int64
}

///|
/// Registers the metric of the lines that `stdout` drops in `metrics`.
fn LogMetrics::register(
  metrics : @metrics.Registry,
  stdout : StdoutLines?,
) -> LogMetrics {
  let dropped = metrics
    .counter(
      "smock_log_lines_dropped_total",
      help="Log entries of smock's own dropped in the mockoon log format (--log-format) because \{own_line_bound} of them were waiting for stdout, as when its reader stops reading. A request's lines are never dropped: its connection waits for them.",
      labels=[],
    )
    .labels([])
  dropped.inc(by=0)
  { dropped, stdout, counted: 0L, }
}

///|
/// Brings the metric up to date with the lines dropped so far.
fn LogMetrics::update(self : LogMetrics) -> Unit {
  guard self.stdout is Some(stdout) && stdout.dropped > self.counted else {
    return
  }
  self.dropped.inc(by=(stdout.dropped - self.counted).to_double())
  self.counted = stdout.dropped
}
