// The connections of the plain and TLS ports, each served in its own task,
// so that a drain can close the idle ones and cut the rest.

///|
/// One connection of the plain or the TLS port.
priv struct Connection {
  /// Whether it waits for its next request and has received nothing of
  /// it: from when it opens, through a TLS handshake, until the first byte
  /// of a request, and again after each response.
  mut idle : Bool
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
  let connection = { idle: true, task: None, }
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
/// Closes every idle connection.
fn Connections::close_idle(self : Connections) -> Unit {
  for _, connection in self.live {
    if connection.idle && connection.task is Some(task) {
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
