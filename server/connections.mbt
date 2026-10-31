// The connections of the plain and TLS ports, each served in its own task,
// so that a drain can close the idle ones, have the HTTP/2 ones send their
// GOAWAYs, and cut the rest.

///|
/// One connection of the plain or the TLS port.
priv struct Connection {
  /// Whether it waits for its next request and has received nothing of
  /// it: from when it opens, through a TLS handshake, until the first byte
  /// of a request, and again after each response. An HTTP/2 connection is
  /// never idle: it closes itself once it has drained (`drain`).
  mut idle : Bool
  /// While it is served over HTTP/2, what starts its drain, which tells the
  /// client with GOAWAY to send no more streams, then closes the connection
  /// once none is in progress (`H2Connection::start_drain`).
  mut drain : (() -> Unit)?
  /// The task that serves it.
  mut task : @async.Task[Unit]?
}

///|
/// The connections being served.
priv struct Connections {
  live : Map[Int32, Connection]
  mut next_id : Int32
  /// Signalled when a connection ends.
  ended : @async.CondVar
}

///|
fn Connections::new() -> Connections {
  { live: Map([]), next_id: 0, ended: @async.CondVar::Cond(), }
}

///|
/// Serves `conn` with `handle` in a task of `group`, and closes it after.
/// A connection that fails ends alone: the others carry on.
fn[X] Connections::serve(
  self : Connections,
  group : @async.TaskGroup[X],
  conn : @socket.Tcp,
  handle : async (Connection) -> Unit,
) -> Unit {
  let id = self.next_id
  self.next_id += 1
  let connection = { idle: true, drain: None, task: None, }
  self.live[id] = connection
  let task = group.spawn(allow_failure=true, () => {
    defer {
      self.live.remove(id)
      self.ended.broadcast()
    }
    defer conn.close()
    handle(connection)
  })
  connection.task = Some(task)
}

///|
/// Starts the drain of every connection: an HTTP/2 connection starts its
/// own, with GOAWAY, and an idle one of the others closes at once.
fn Connections::drain(self : Connections) -> Unit {
  for _, connection in self.live {
    if connection.drain is Some(drain) {
      drain()
    } else if connection.idle && connection.task is Some(task) {
      task.cancel()
    }
  }
}

///|
/// Waits until every connection has ended.
async fn Connections::wait_all_ended(self : Connections) -> Unit {
  while !self.live.is_empty() {
    self.ended.wait()
  }
}

///|
/// Cuts every connection still open, whatever it is doing, and returns
/// how many there were.
fn Connections::cut(self : Connections) -> Int32 {
  for _, connection in self.live {
    if connection.task is Some(task) {
      task.cancel()
    }
  }
  self.live.length()
}
