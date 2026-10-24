// The writing of what an HTTP/2 connection's `Conn` queues: its SETTINGS,
// the acknowledgements and window updates it owes, the resets and
// GOAWAY it sends, and the responses smock queues on its streams; and of
// the few frames smock builds itself, the first GOAWAY and the PING of a
// drain. Every octet goes through the connection's one writer, `H2Writer`,
// and then through its `WatchedStream`, so each write has the write
// timeout.

///|
/// What a read of a connection's byte stream may write besides what it
/// reads: on the TLS port, the records OpenSSL writes for the client while
/// it reads, such as an alert. Plain TCP has none. An HTTP/2 connection's
/// reader reads while its streams' tasks write, so its reads leave that
/// output to the connection's one writer (`H2Writer`), as every other
/// write. OpenSSL keeps it in order with what is written after it: each
/// later write sends it first.
priv trait ReadOutput {
  /// From now on, a read leaves the output it produces for the writer,
  /// rather than send it itself.
  fn hold_read_output(Self) -> Unit
  /// Whether reads may have left output that nothing has sent since.
  fn has_read_output(Self) -> Bool
  /// Sends the output reads left, with the write timeout of `watchdog`.
  async fn write_read_output(Self, Watchdog) -> Unit
}

///|
impl ReadOutput for @socket.Tcp with fn hold_read_output(_) {

}

///|
impl ReadOutput for @socket.Tcp with fn has_read_output(_) {
  false
}

///|
impl ReadOutput for @socket.Tcp with fn write_read_output(_, _) {

}

///|
/// The one writer of an HTTP/2 connection: every octet written to its
/// socket goes through it, in the order its `Conn` queued it, and on the
/// TLS port the output its reads left too (`ReadOutput`). Each task
/// that queues something then asks the writer to write it: the connection's
/// reader before each read, and a stream's task once its response is
/// queued. Only one task writes at a time; while it does, a task that asks
/// leaves what it queued to it, and it writes that too before it stops. So
/// no task ever waits to write the socket while another does, which
/// moonbitlang/async does not allow (it aborts the process), and none waits
/// for another to write but the reader, before the connection ends.
///
/// A write that fails ends the connection, so a writer never stays busy on
/// a connection that goes on. A stream's task that a reset would cancel
/// writes with `write_for`, and a reset leaves it be while it writes, so
/// that no task stops in the middle of a frame.
priv struct H2Writer {
  conn : @http2.Conn
  /// Whether a task is writing.
  mut busy : Bool
  /// While a stream's task writes with `write_for`, that stream; else 0.
  mut writing_for : Int32
  /// Whether a task asked the writer to write while another was writing,
  /// so that the one writing takes what the `Conn` queued once more.
  mut more : Bool
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
    more: false,
    done: @async.CondVar::Cond(),
  }
}

///|
/// Writes to `out` what the `Conn` has queued, and the output reads left,
/// and returns whether there was anything to write. While another task is
/// writing, it leaves what is queued to that task, which writes it before
/// it stops, and returns false.
async fn[S : @io.Writer + ReadOutput] H2Writer::write(
  self : H2Writer,
  out : WatchedStream[S],
) -> Bool {
  if self.busy {
    self.more = true
    return false
  }
  let queued = self.conn.take()
  if queued.length() == 0 && !ReadOutput::has_read_output(out.stream) {
    return false
  }
  self.busy = true
  write_queued(out, queued)
  while self.more {
    self.more = false
    write_queued(out, self.conn.take())
  }
  self.busy = false
  self.done.broadcast()
  true
}

///|
/// Writes `queued` to `out`, then the output reads left that the write
/// did not send.
async fn[S : @io.Writer + ReadOutput] write_queued(
  out : WatchedStream[S],
  queued : Bytes,
) -> Unit {
  if queued.length() > 0 {
    @io.Writer::write(out, queued)
  }
  if ReadOutput::has_read_output(out.stream) {
    ReadOutput::write_read_output(out.stream, out.watchdog)
  }
}

///|
/// Writes as `write` does, for the task of `stream`, which a reset of the
/// stream cancels, except while it writes here (`writes_for`): cut off
/// then, it would leave a frame half written, and the connection broken.
/// The task ends itself once the write is done instead.
async fn[S : @io.Writer + ReadOutput] H2Writer::write_for(
  self : H2Writer,
  out : WatchedStream[S],
  stream : Int32,
) -> Bool {
  if self.busy {
    self.more = true
    return false
  }
  self.writing_for = stream
  let wrote = self.write(out)
  self.writing_for = 0
  wrote
}

///|
/// Whether the task of `stream` is writing, with `write_for`.
fn H2Writer::writes_for(self : H2Writer, stream : Int32) -> Bool {
  self.busy && self.writing_for == stream
}

///|
/// Waits until no other task is writing, then writes to `out` what the
/// `Conn` has queued: the last frames of a connection that ends, such as
/// its GOAWAY, which would be lost if it ended while another task wrote.
async fn[S : @io.Writer + ReadOutput] H2Writer::write_last(
  self : H2Writer,
  out : WatchedStream[S],
) -> Unit {
  self.wait()
  let _ = self.write(out)
}

///|
/// Waits until no other task is writing.
async fn H2Writer::wait(self : H2Writer) -> Unit {
  while self.busy {
    self.done.wait()
  }
}

///|
/// Waits until no other task is writing, then writes to `out` `frames`,
/// which smock built itself rather than the `Conn`, ahead of what the
/// `Conn` has queued, which follows, as `write` writes it. A caller that
/// must decide, once the wait is over, whether to write at all waits first
/// itself (`wait`): this one then starts to write at once.
async fn[S : @io.Writer + ReadOutput] H2Writer::write_first(
  self : H2Writer,
  out : WatchedStream[S],
  frames : Bytes,
) -> Unit {
  self.wait()
  self.busy = true
  @io.Writer::write(out, frames)
  write_queued(out, self.conn.take())
  while self.more {
    self.more = false
    write_queued(out, self.conn.take())
  }
  self.busy = false
  self.done.broadcast()
}
