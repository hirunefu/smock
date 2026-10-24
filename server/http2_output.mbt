// The writing of what an HTTP/2 connection's `Conn` queues: its SETTINGS,
// the acknowledgements and window updates it owes, the resets and
// GOAWAY it sends, and the responses smock queues on its streams. Every
// octet goes through the connection's `WatchedStream`, so each write has
// the write timeout.

///|
/// Writes what `conn` has queued for the client to `out`, and returns
/// whether there was anything to write.
async fn[S : @io.Writer] write_queued(
  conn : @http2.Conn,
  out : WatchedStream[S],
) -> Bool {
  let queued = conn.take()
  if queued.length() == 0 {
    return false
  }
  @io.Writer::write(out, queued)
  true
}
