// The writing of what an HTTP/2 connection's `Conn` queues: its SETTINGS,
// the acknowledgements and window updates it owes, the resets and
// GOAWAY it sends, and the responses smock queues on its streams. Every
// octet goes through the connection's one writer, `H2Writer`, and then
// through its `WatchedStream`, so each write has the write timeout.
//
// The output is bounded: whenever what is queued and not yet written passes
// `output_bound`, the reader has it written before it hands the `Conn`
// another frame, and a stream's task queues no more DATA until what it
// queued is written. So a client that stops reading makes smock stop
// reading too, holding no more than about one frame's replies and
// responses past the bound, and the write timeout closes the connection.

///|
/// The output bound, in octets: past it, what a connection has queued and
/// not yet written is written before more is queued.
let output_bound : Int64 = 16_384

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
/// reader before each read, and before it hands the `Conn` a frame while
/// the output passes the output bound (`hold`), and a stream's task once
/// its response is queued. Only one task writes at a time; while it does, a
/// task that asks leaves what it queued to it, and it writes that too
/// before it stops. So no task ever waits to write the socket while another
/// does, which moonbitlang/async does not allow (it aborts the process). A
/// task that must see the output written before it goes on, as the reader
/// past the output bound, waits for the one writing to stop instead, and
/// so does the last write of a connection that ends.
///
/// A write that fails ends the connection, so a writer never stays busy on
/// a connection that goes on. A stream's task that a reset would cancel
/// writes with `write_for`, and a reset leaves it be while it writes, so
/// that no task stops in the middle of a frame.
priv struct H2Writer {
  conn : @http2.Conn
  /// What was taken from the `Conn` and not yet handed to a write, oldest
  /// first (`take`).
  taken : Array[Bytes]
  /// The octets taken from the `Conn` so far.
  mut queued : Int64
  /// The octets written so far: `queued` less these are the output not yet
  /// written, which the output bound holds to.
  mut written : Int64
  /// Whether a task is writing.
  mut busy : Bool
  /// While a stream's task writes with `write_for`, that stream; else 0.
  mut writing_for : Int32
  /// Whether a task asked the writer to write while another was writing,
  /// so that the one writing writes once more: what the `Conn` queued
  /// since, and the output reads left.
  mut more : Bool
  /// Whether it has taken a HEADERS or DATA frame to write since the reader
  /// last set it to false, at the client's last PING
  /// (`H2Connection::no_work`).
  mut responded : Bool
  /// Signalled when a task stops writing.
  done : @async.CondVar
}

///|
/// The writer of what `conn` queues.
fn H2Writer::new(conn : @http2.Conn) -> H2Writer {
  {
    conn,
    taken: [],
    queued: 0,
    written: 0,
    busy: false,
    writing_for: 0,
    more: false,
    responded: false,
    done: @async.CondVar::Cond(),
  }
}

///|
/// Takes what the `Conn` has queued since it was last taken, to be written
/// after what was taken before it. The reader takes it after each frame, so
/// that the output bound counts it; an empty `Conn` costs nothing.
fn H2Writer::take(self : H2Writer) -> Unit {
  let queued = self.conn.take()
  if queued.length() > 0 {
    self.taken.push(queued)
    self.queued += queued.length().to_int64()
    self.sends(queued)
  }
}

///|
/// The octets taken from the `Conn` and not yet written: those in `taken`,
/// and those of the write in progress.
fn H2Writer::unwritten(self : H2Writer) -> Int64 {
  self.queued - self.written
}

///|
/// Empties `taken`, and returns what it held, as one run of octets: the one
/// part it held as it is, else the parts joined, so that one write sends
/// them all.
fn H2Writer::joined(self : H2Writer) -> Bytes {
  match self.taken.length() {
    0 => b""
    1 => {
      let only = self.taken[0]
      self.taken.clear()
      only
    }
    _ => {
      let mut length = 0
      for part in self.taken {
        length += part.length()
      }
      let joined = FixedArray::make(length, b'\x00')
      let mut at = 0
      for part in self.taken {
        joined.blit_from_bytes(at, part, 0, part.length())
        at += part.length()
      }
      self.taken.clear()
      joined.unsafe_reinterpret_as_bytes()
    }
  }
}

///|
/// Writes to `out` what was taken and what the `Conn` has queued, and the
/// output reads left, and returns whether there was anything to write.
/// While another task is writing, it leaves what is queued to that task,
/// which writes it before it stops, and returns false.
async fn[S : @io.Writer + ReadOutput] H2Writer::write(
  self : H2Writer,
  out : WatchedStream[S],
) -> Bool {
  if self.busy {
    self.more = true
    return false
  }
  self.take()
  if self.taken.is_empty() && !ReadOutput::has_read_output(out.stream) {
    return false
  }
  self.busy = true
  for ;; {
    let queued = self.joined()
    write_queued(out, queued)
    self.written += queued.length().to_int64()
    self.take()
    if !self.more && self.taken.is_empty() {
      break
    }
    self.more = false
  }
  self.busy = false
  self.done.broadcast()
  true
}

///|
/// Takes what the `Conn` has queued since, and while the output not yet
/// written passes `output_bound`, has it written before the reader goes
/// on: the reader writes it itself, or, while a stream's task writes, waits
/// until that task stops, having written it too. Returns whether the reader
/// waited. The reader calls it before it hands the `Conn` each frame, so
/// that a client that does not read the replies and responses smock queues
/// makes it stop reading.
async fn[S : @io.Writer + ReadOutput] H2Writer::hold(
  self : H2Writer,
  out : WatchedStream[S],
) -> Bool {
  self.take()
  if self.unwritten() <= output_bound {
    return false
  }
  while self.unwritten() > output_bound {
    if self.busy {
      self.done.wait()
    } else {
      let _ = self.write(out)
    }
  }
  true
}

///|
/// The writer has taken `queued` to write, whole frames as the `Conn`
/// queues them: `responded` becomes true if they hold a HEADERS or DATA
/// frame. It reads only the frames' headers, and none once `responded` is
/// true.
fn H2Writer::sends(self : H2Writer, queued : Bytes) -> Unit {
  let mut at = 0
  while !self.responded && at + 9 <= queued.length() {
    let ftype = queued[at + 3].to_int()
    if ftype == @http2.frame_headers || ftype == @http2.frame_data {
      self.responded = true
    }
    at += 9 +
      (
        (queued[at].to_int() << 16) |
        (queued[at + 1].to_int() << 8) |
        queued[at + 2].to_int()
      )
  }
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
  while self.busy {
    self.done.wait()
  }
  let _ = self.write(out)
}
