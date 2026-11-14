// The gRPC side of the HTTP/2 harness: a unary call over moonhttp's
// client-side `Conn`, as gRPC clients make one, and its reply read frame by
// frame, trailers included. Messages are framed here, by hand, and come
// from protoc-encoded fixtures, so the tests never check smock's codec
// against itself.

///|
/// The protoc-encoded fixtures of gRPC's helloworld.proto.
let hello_request_path : String = "fixtures/protobuf/helloworld/hello-request.binpb"

///|
let hello_reply_path : String = "fixtures/protobuf/helloworld/hello-reply.binpb"

///|
/// `message` framed as gRPC frames an uncompressed message: flag 0, then its
/// length in 4 octets, big-endian, then its octets.
fn framed(message : Bytes) -> Bytes {
  let n = message.length()
  let out = @buffer.Buffer(size_hint=n + 5)
  out.write_byte(b'\x00')
  out.write_byte((n >> 24).to_byte())
  out.write_byte((n >> 16).to_byte())
  out.write_byte((n >> 8).to_byte())
  out.write_byte(n.to_byte())
  out.write_bytes(message)
  out.to_bytes()
}

///|
/// A reply to a gRPC call as the client got it, frame by frame.
struct GrpcReply {
  /// The fields of the HEADERS that answered, `:status` included, in order.
  head : Array[(String, String)]
  /// The octets of each DATA frame, in order.
  data : Array[Bytes]
  /// The fields of the trailers, when they came.
  trailers : Array[(String, String)]?
  /// How the stream ended: `"end"`, `"reset <code>"` with the code's name,
  /// or `"closed"` when the connection closed first.
  ended : String
}

///|
/// Makes a gRPC call to `path` with `body`, by default the framed
/// HelloRequest `{name: "Tom"}`: POST with `content-type: <content_type>`,
/// by default `application/grpc`, and `te: trailers`, as gRPC clients send
/// it, then `headers`. Reads its reply.
async fn H2Client::call(
  self : H2Client,
  path : String,
  authority~ : String = "localhost",
  content_type~ : String = "application/grpc",
  headers~ : Array[(String, String)] = [],
  body? : Bytes,
) -> GrpcReply {
  let body = match body {
    Some(body) => body
    None => framed(@fs.read_file(hello_request_path).binary())
  }
  let stream = self.send(
    "POST",
    path,
    authority~,
    headers=[("content-type", content_type), ("te", "trailers"), ..headers],
    body~,
  )
  self.reply(stream)
}

///|
/// Reads the reply on `stream` until the stream ends, is reset or the
/// connection closes.
async fn H2Client::reply(self : H2Client, stream : Int32) -> GrpcReply {
  let head = []
  let data = []
  let mut trailers = None
  let fields_of = (fields : Array[@header.Header]) => {
    fields.map(field => {
      (@utf8.decode_lossy(field.name), @utf8.decode_lossy(field.value))
    })
  }
  for ;; {
    match self.stream_event(stream) {
      Response(fields~, ..) => head.append(fields_of(fields))
      Data(data=octets, ..) => data.push(octets)
      Trailers(fields~, ..) => trailers = Some(fields_of(fields))
      End(_) => return { head, data, trailers, ended: "end", }
      Reset(code~, ..) =>
        return { head, data, trailers, ended: "reset \{error_name(code)}", }
      Closed => return { head, data, trailers, ended: "closed", }
      _ => ()
    }
  }
}

///|
/// The reply as a test shows it: `HEADERS` and each of its fields, with a
/// `date` that is the current time shown as `<now>`; `DATA` and the octets
/// of each DATA frame in hex; `TRAILERS` and their fields, when they came;
/// then how the stream ended.
fn GrpcReply::render(self : GrpcReply) -> String {
  let out = StringBuilder()
  out.write_string("HEADERS\n")
  for field in self.head {
    out.write_string("  \{shown_field(field.0, field.1)}\n")
  }
  for octets in self.data {
    out.write_string("DATA \{hex(octets)}\n")
  }
  if self.trailers is Some(trailers) {
    out.write_string("TRAILERS\n")
    for field in trailers {
      out.write_string("  \{field.0}: \{field.1}\n")
    }
  }
  out.write_string("(\{self.ended})")
  out.to_string()
}

///|
/// `octets` in lower-case hex.
fn hex(octets : Bytes) -> String {
  let out = StringBuilder()
  for octet in octets {
    out.write_string(octet.to_int().to_string(radix=16).pad_start(2, '0'))
  }
  out.to_string()
}

///|
/// Runs `f` with a definitions directory holding `files` and the set of
/// gRPC's helloworld.proto at `files/greeter.binpb`.
async fn with_greeter_set(
  files : Array[(String, String)],
  f : async (String) -> Unit,
) -> Unit {
  with_definitions(files, dir => {
    @fs.mkdir("\{dir}/files")
    write_bytes(
      dir,
      "files/greeter.binpb",
      @fs.read_file(greeter_set_path).binary(),
    )
    f(dir)
  })
}

///|
/// The last entry of the Journal, as `journal_shown` shows it.
async fn Smock::last_entry(self : Smock) -> String {
  let (_, journal) = self.journal()
  guard journal is Object({ "entries": Array(entries), .. }) &&
    entries.last() is Some(entry) else {
    return "no entry"
  }
  journal_shown(entry).stringify()
}
