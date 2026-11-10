// HTTP/2 by prior knowledge (h2c) on the plain port: a connection whose
// first 24 octets are the HTTP/2 connection preface (RFC 9113, section 3.4)
// is HTTP/2, and any other is HTTP/1.1. The check runs before the HTTP/1.1
// loop of `serve_connection` reads its first request, on the plain port
// only: the TLS port chooses HTTP/2 by ALPN, and the admin port never looks
// for the preface.

///|
/// What the first octets of a connection turned out to be.
priv enum Preface {
  /// Not the HTTP/2 connection preface: the parser has every octet read so
  /// far, for the HTTP/1.1 loop to go on with.
  Absent
  /// The HTTP/2 connection preface: the octets read so far, the preface
  /// first.
  Present(Bytes)
  /// Neither: the client closed the connection, or a timeout passed, first.
  Ended
}

///|
/// Reads the first octets of the connection from `stream`, into the loop's
/// buffer, until they tell whether they are the HTTP/2 connection preface.
///
/// While the octets received are a proper prefix of the preface, it reads
/// on. As soon as one differs, the connection is HTTP/1.1: the parser gets
/// every octet read so far, so a near-preface stays HTTP/1.1 and an
/// `HTTP/2.0` request line still gets 505. An HTTP/1.1 request rarely starts
/// with `P`, so it costs a request one comparison of its first octets.
///
/// The idle timeout bounds the wait for the first octet, as it does a
/// request's first byte, and the connection is idle for the drain until it
/// comes. The read timeout then runs from the first octet: for the rest of
/// the preface, and for the rest of a request that turns out to be
/// HTTP/1.1, which the HTTP/1.1 loop then times from that first octet too.
async fn[S : @io.Reader] ConnectionLoop::read_preface(
  self : ConnectionLoop,
  stream : S,
) -> Preface {
  let preface = @http2.preface
  let mut held = 0
  for ;; {
    let deadline = if held == 0 {
      self.idle_deadline
    } else {
      self.read_since + self.read_timeout
    }
    if deadline - self.now <= 0L {
      return Ended
    }
    if self.connection is Some(connection) {
      connection.idle = held == 0
    }
    self.watchdog.reading(deadline, self.now)
    let n = @io.Reader::read(stream, self.buf, offset=held)
    self.watchdog.stop_reading()
    if self.connection is Some(connection) {
      connection.idle = false
    }
    guard n > 0 else { return Ended }
    self.last_read = Stopwatch::start()
    self.now = @async.now()
    if held == 0 {
      self.read_since = self.now
    }
    let read = held + n
    let compared = if read < preface.length() { read } else { preface.length() }
    for i in held..<compared {
      if self.buf[i] != preface[i] {
        self.parser.feed(self.buf.unsafe_reinterpret_as_bytes()[:read])
        return Absent
      }
    }
    if read >= preface.length() {
      return Present(self.buf.unsafe_reinterpret_as_bytes()[:read].to_owned())
    }
    held = read
  }
}
