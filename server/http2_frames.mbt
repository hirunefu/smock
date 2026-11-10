// The frame reader of an HTTP/2 connection: what smock reads, split into
// the connection preface and then whole frames, so that the connection's
// moonhttp `Conn` gets one frame at a time (http2.mbt) and each frame can
// be judged before it reaches it (`H2Connection::judge`). The reader also
// caps the header table size that the client's SETTINGS frames allow
// (`FrameReader::cap_header_table`).

///|
/// The largest frame payload smock accepts: the SETTINGS_MAX_FRAME_SIZE it
/// advertises, RFC 9113's default.
let max_frame_size : Int32 = 16384

///|
/// The largest HPACK table smock encodes its responses with, in octets: RFC
/// 9113's default SETTINGS_HEADER_TABLE_SIZE, however large a table the
/// client allows.
let encoding_table_size : Int32 = 4096

///|
/// What an HTTP/2 connection reads, split into the connection preface and
/// then whole frames. Its buffer holds one frame of the size smock
/// advertises, with its header: what a read brings goes in after what it
/// holds, so it holds at most the frames of one read and part of the next
/// frame. Only that part is moved to the start of the buffer, once, to make
/// room for the rest of its frame.
priv struct FrameReader {
  buf : FixedArray[Byte]
  /// Where the octets not yet split off start.
  mut start : Int32
  /// Where the octets read end.
  mut end : Int32
  /// Whether the connection preface is still to be split off.
  mut preface : Bool
}

///|
/// What `FrameReader::next` split off.
priv enum Split {
  /// The client's connection preface, its 24 octets, which come first.
  Preface(BytesView)
  /// A whole frame, its header included, and its header decoded. A
  /// SETTINGS frame has had its header table size capped
  /// (`FrameReader::cap_header_table`).
  Frame(@http2.FrameHeader, BytesView)
  /// The header of a frame larger than smock advertises, which is a
  /// connection error (RFC 9113, section 4.2).
  TooLarge
  /// Nothing whole: the reader needs to read more.
  NeedMore
}

///|
/// A reader that starts with the octets `read`, read from the connection
/// before it: the preface first.
fn FrameReader::new(read : Bytes) -> FrameReader {
  let size = 9 + max_frame_size
  let buf = FixedArray::make(
    if read.length() > size {
      read.length()
    } else {
      size
    },
    b'\x00',
  )
  buf.blit_from_bytes(0, read, 0, read.length())
  { buf, start: 0, end: read.length(), preface: true, }
}

///|
/// Splits off the preface, then the next whole frame, if the reader holds
/// it. What it returns is valid until the next read.
fn FrameReader::next(self : FrameReader) -> Split {
  let held = self.end - self.start
  let bytes = self.buf.unsafe_reinterpret_as_bytes()
  if self.preface {
    let length = @http2.preface.length()
    if held < length {
      return NeedMore
    }
    self.preface = false
    return Preface(self.take(bytes, length))
  }
  if held < 9 {
    return NeedMore
  }
  let head = @http2.FrameHeader::decode(bytes, offset=self.start) catch {
    _ => return NeedMore
  }
  if head.length > max_frame_size {
    return TooLarge
  }
  if held < 9 + head.length {
    return NeedMore
  }
  if head.ftype == @http2.frame_settings {
    self.cap_header_table(head.length)
  }
  Frame(head, self.take(bytes, 9 + head.length))
}

///|
/// Whether octets of the preface have come and it is still to be split
/// off: once `next` needs more, the reader then holds part of it, and the
/// rest is still to come.
fn FrameReader::preface_begun(self : FrameReader) -> Bool {
  self.preface && self.end > self.start
}

///|
/// Lowers each SETTINGS_HEADER_TABLE_SIZE over `encoding_table_size`, read
/// as unsigned, to `encoding_table_size`, in the SETTINGS frame at the start
/// of what the reader holds, whose payload is `length` octets, before the
/// `Conn` sees it. moonhttp sizes the table it encodes responses with from
/// that setting, with no cap, and indexes every response field it cannot
/// match exactly: with a huge table nothing is evicted, so the table and the
/// cost of each lookup would grow for the life of the connection. An encoder
/// may use any table size up to the decoder's maximum (RFC 9113, section
/// 4.3.1; RFC 7541, section 4.2), so the client still sees a valid table.
/// The frame's other settings pass unchanged, and so do octets past its last
/// whole setting, which the `Conn` refuses.
fn FrameReader::cap_header_table(self : FrameReader, length : Int32) -> Unit {
  let buf = self.buf
  let end = self.start + 9 + length
  let mut at = self.start + 9
  // Each setting is an identifier of two octets, then a value of four.
  while at + 6 <= end {
    let id = (buf[at].to_int() << 8) | buf[at + 1].to_int()
    let low = (buf[at + 4].to_int() << 8) | buf[at + 5].to_int()
    if id == @http2.settings_header_table_size &&
      (
        buf[at + 2] != b'\x00' ||
        buf[at + 3] != b'\x00' ||
        low > encoding_table_size
      ) {
      buf[at + 2] = b'\x00'
      buf[at + 3] = b'\x00'
      buf[at + 4] = (encoding_table_size >> 8).to_byte()
      buf[at + 5] = (encoding_table_size & 0xFF).to_byte()
    }
    at += 6
  }
}

///|
/// The next `length` octets held, `bytes` being the buffer.
fn FrameReader::take(
  self : FrameReader,
  bytes : Bytes,
  length : Int32,
) -> BytesView {
  let taken = bytes[self.start:self.start + length]
  self.start += length
  taken
}

///|
/// Drops what the reader holds, for the next read to go to the start of its
/// buffer.
fn FrameReader::drop_held(self : FrameReader) -> Unit {
  self.start = 0
  self.end = 0
}

///|
/// Reads more from `stream`, after what the reader holds, and returns how
/// many octets came: 0 once the client has closed the connection. The
/// octets of a frame not yet whole move to the start of the buffer first.
async fn[S : @io.Reader] FrameReader::read(
  self : FrameReader,
  stream : S,
) -> Int32 {
  if self.start > 0 {
    let held = self.end - self.start
    self.buf.blit_to(self.buf, len=held, src_offset=self.start, dst_offset=0)
    self.start = 0
    self.end = held
  }
  let n = @io.Reader::read(stream, self.buf, offset=self.end)
  self.end += n
  n
}
