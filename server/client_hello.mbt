// The name a TLS client asks for by SNI, read from its ClientHello before
// OpenSSL sees it, so that the name can choose the certificate the
// connection starts with. The ClientHello is sent in the clear, and OpenSSL
// works on bytes the server hands it, so the bytes read here go to OpenSSL
// unchanged afterwards: no C callback is needed (ADR 0001). Anything that
// is not a well-formed ClientHello reads as no name, and OpenSSL then
// fails the handshake as it would anyway.

///|
/// What the first bytes from a TLS client tell about the name it asks for.
priv enum ClientHello {
  /// More bytes are needed to tell.
  Incomplete
  /// The host name of the ClientHello's server_name extension (RFC 6066,
  /// section 3), if it has one. Also `None` for bytes that are not a TLS
  /// ClientHello.
  ServerName(String?)
}

///|
/// The most bytes read while looking for the end of the ClientHello. More
/// read as no name: OpenSSL then decides what they are.
const MAX_CLIENT_HELLO = 65536

///|
/// Reads the ClientHello at the start of `data`, the bytes a client has
/// sent so far. The ClientHello may span several TLS records, and a record
/// several reads.
fn read_client_hello(data : BytesView) -> ClientHello {
  // The handshake messages, gathered from the records read so far.
  let message = Buffer()
  let mut pos = 0
  for ;; {
    let gathered = message.to_bytes()
    if gathered.length() >= 4 {
      // A handshake message: its type (1 for ClientHello) and its length
      // in 3 bytes, then its body.
      if gathered[0] != b'\x01' {
        return ServerName(None)
      }
      let end = 4 + uint24(gathered[:], 1)
      if gathered.length() >= end {
        return ServerName(server_name(gathered[4:end]))
      }
    }
    if data.length() >= MAX_CLIENT_HELLO {
      return ServerName(None)
    }
    // The next record: its content type (22 for a handshake), its version
    // in 2 bytes and the length of its fragment in 2 bytes.
    if pos >= data.length() {
      return Incomplete
    }
    if data[pos] != b'\x16' {
      return ServerName(None)
    }
    if pos + 5 > data.length() {
      return Incomplete
    }
    let end = pos + 5 + uint16(data, pos + 3)
    if end > data.length() {
      return Incomplete
    }
    message.write_bytes(data[pos + 5:end])
    pos = end
  }
}

///|
/// The host name in the server_name extension of a ClientHello body, if
/// any.
fn server_name(hello : BytesView) -> String? {
  // The legacy version (2 bytes) and the random (32 bytes), then the
  // session ID, the cipher suites and the compression methods, each after
  // its length.
  let mut pos = 34
  for length_size in [1, 2, 1] {
    if pos + length_size > hello.length() {
      return None
    }
    let length = if length_size == 1 {
      hello[pos].to_int()
    } else {
      uint16(hello, pos)
    }
    pos += length_size + length
  }
  // The extensions, after their length. A ClientHello may have none.
  if pos + 2 > hello.length() {
    return None
  }
  let end = pos + 2 + uint16(hello, pos)
  if end > hello.length() {
    return None
  }
  pos += 2
  while pos + 4 <= end {
    let kind = uint16(hello, pos)
    let length = uint16(hello, pos + 2)
    pos += 4
    if pos + length > end {
      return None
    }
    if kind == 0 {
      return host_name(hello[pos:pos + length])
    }
    pos += length
  }
  None
}

///|
/// The host name in the server_name extension's list of names, if any.
fn host_name(list : BytesView) -> String? {
  if list.length() < 2 {
    return None
  }
  let end = 2 + uint16(list, 0)
  if end > list.length() {
    return None
  }
  let mut pos = 2
  while pos + 3 <= end {
    let kind = list[pos]
    let length = uint16(list, pos + 1)
    pos += 3
    if pos + length > end {
      return None
    }
    // Name type 0 is host_name, the only one defined.
    if kind == b'\x00' && length > 0 {
      return Some(@utf8.decode_lossy(list[pos:pos + length]))
    }
    pos += length
  }
  None
}

///|
/// The big-endian 16-bit number at `pos` in `data`.
fn uint16(data : BytesView, pos : Int32) -> Int32 {
  (data[pos].to_int() << 8) | data[pos + 1].to_int()
}

///|
/// The big-endian 24-bit number at `pos` in `data`.
fn uint24(data : BytesView, pos : Int32) -> Int32 {
  (data[pos].to_int() << 16) | uint16(data, pos + 1)
}
