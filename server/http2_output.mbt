// The writing of what an HTTP/2 connection's `Conn` queues: its SETTINGS,
// the acknowledgements and window updates it owes, the resets and
// GOAWAY it sends, and the responses smock queues on its streams. Every
// octet goes through the connection's one writer, `H2Writer`, and then
// through its `WatchedStream`, so each write has the write timeout.

///|
/// The one writer of an HTTP/2 connection: every octet written to its
/// socket goes through it, in the order its `Conn` queued it. Each task
/// that queues something then asks the writer to write it: the connection's
/// reader before each read, and a stream's task once its response is
/// queued. Only one task writes at a time; while it does, a task that asks
/// leaves what it queued to it, and it writes that too before it stops. So
/// no task ever waits to write the socket while another does, which
/// moonbitlang/async does not allow (it aborts the process), and none waits
/// for another to write but the reader, before the connection ends.
///
/// A write that fails ends the connection, so a writer never stays busy on
/// a connection that goes on. A stream's task cancelled while it writes, as
/// when the client resets the stream, leaves the rest of what it took from
/// the `Conn` to the reader, which writes it before it reads again
/// (`H2Writer::abandon`), so that every frame still goes out whole.
priv struct H2Writer {
  conn : @http2.Conn
  /// Whether a task is writing.
  mut busy : Bool
  /// While a task writes, the stream it writes for, or 0 for the reader.
  mut writing_for : Int32
  /// Whether the task writing is cancelled, so that the reader writes what
  /// it leaves.
  mut abandoned : Bool
  /// Whether a task asked the writer to write while another was writing,
  /// so that the one writing takes what the `Conn` queued once more.
  mut more : Bool
  /// What the writer last took from the `Conn`, while it is not all
  /// written.
  mut taken : Bytes
  /// How much of `taken` is written.
  mut written : Int32
  /// Signalled when a task stops writing.
  done : @async.CondVar
}

///|
/// The writer of what `conn` queues.
fn H2Writer::new(conn : @http2.Conn) -> H2Writer {
  {
    conn,
    busy: false,
    writing_for: 0,
    abandoned: false,
    more: false,
    taken: b"",
    written: 0,
    done: @async.CondVar::Cond(),
  }
}

///|
/// Writes to `out` what the `Conn` has queued, after what a write that was
/// cancelled left, and returns whether there was anything to write. While
/// another task is writing, it leaves what is queued to that task, which
/// writes it before it stops, and returns false. A task that a reset may
/// cancel while it writes calls `write_for` instead.
async fn[S : @io.Writer] H2Writer::write(
  self : H2Writer,
  out : WatchedStream[S],
) -> Bool {
  if self.busy {
    self.more = true
    return false
  }
  if self.written < self.taken.length() {
    // What the `Conn` queued since then goes out after it.
    self.more = true
  } else {
    self.taken = self.conn.take()
    self.written = 0
    if self.taken.length() == 0 {
      return false
    }
  }
  self.busy = true
  for ;; {
    while self.written < self.taken.length() {
      self.written += @io.Writer::write_once(
        out,
        self.taken,
        offset=self.written,
        len=self.taken.length() - self.written,
      )
    }
    guard self.more else { break }
    self.more = false
    self.taken = self.conn.take()
    self.written = 0
  }
  self.taken = b""
  self.written = 0
  self.busy = false
  self.done.broadcast()
  true
}

///|
/// Writes as `write` does, for the task of `stream`, which a reset of the
/// stream cancels at once, even while it writes. Cancelled so, it stops
/// writing before what it took from the `Conn` is all written, and leaves
/// the rest to the reader (`abandon`).
async fn[S : @io.Writer] H2Writer::write_for(
  self : H2Writer,
  out : WatchedStream[S],
  stream : Int32,
) -> Bool {
  if self.busy {
    self.more = true
    return false
  }
  self.writing_for = stream
  defer {
    // Still busy: the write was cancelled before it ended.
    if self.busy {
      self.busy = false
      out.watchdog.stop_writing()
      self.done.broadcast()
    }
    self.writing_for = 0
  }
  self.write(out)
}

///|
/// The task of `stream` is cancelled. If it is writing, it stops before the
/// frames it took are all written, and the reader writes the rest, before
/// it reads again, instead of leaving them to the next write
/// (`H2Connection::read_more`).
fn H2Writer::abandon(self : H2Writer, stream : Int32) -> Unit {
  if self.busy && self.writing_for == stream {
    self.abandoned = true
  }
}

///|
/// Waits until no other task is writing, then writes to `out` what the
/// `Conn` has queued: the last frames of a connection that ends, such as
/// its GOAWAY, which would be lost if it ended while another task wrote,
/// and what a task cancelled while it wrote left.
async fn[S : @io.Writer] H2Writer::write_last(
  self : H2Writer,
  out : WatchedStream[S],
) -> Unit {
  while self.busy {
    self.done.wait()
  }
  let _ = self.write(out)
}
