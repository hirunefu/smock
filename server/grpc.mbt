// The gRPC layer of the HTTP/2 mapping: an HTTP/2 stream whose
// `content-type` is `application/grpc` is a gRPC unary call. Once its
// request has ended, its one message is taken from the body, the call's
// Mock and the method its `:path` names are looked up, the message is
// decoded into JSON, and the engine decides the call as a POST to the
// method's path, with the metadata as headers, the JSON as the body and
// the gRPC call marker. The reply JSON is then encoded with the method's
// output type and written as gRPC writes it: HEADERS, one DATA frame with
// the framed message, then trailers with `grpc-status: 0`. The lookup, the
// decoding, `handle` and the encoding run with no await between them, so a
// reload never splits them.
//
// What the layer cannot serve yet gets Trailers-Only, one HEADERS block
// that ends the stream, with `:status` 200, `grpc-status` INTERNAL and a
// fixed ASCII `grpc-message`. A call that does not reach the engine is
// counted as rejected traffic and is not journaled; one that does is
// journaled as the engine planned it.

///|
/// The content type of gRPC calls, as the octets of a field value.
let grpc_content_type : Bytes = @utf8.encode(@grpc.content_type)

///|
/// Whether `value`, the value of a request's `content-type` field, makes
/// its stream a gRPC call: it is `application/grpc` exactly.
fn is_grpc_content_type(value : Bytes) -> Bool {
  value == grpc_content_type
}

///|
/// Answers the gRPC call that has arrived in full on `stream`: through the
/// engine, when the call can be served, or else with Trailers-Only
/// INTERNAL, as `refuse_call` sends it. A reply whose framed message fits
/// the windows is queued at once; the rest of a larger one is sent in a
/// task of its own (`write_slowly`), which writes to `out`, with the
/// trailers after it.
fn[S : @io.Writer + ReadOutput] H2Connection::answer_call(
  self : H2Connection,
  stream : Int32,
  request : H2Request,
  out : WatchedStream[S],
) -> Unit {
  let ports = self.ports
  let incoming = request.to_engine()
  if incoming.meth != "POST" {
    self.refuse_call(stream, "the method must be POST")
    return
  }
  guard @grpc.next_message(incoming.body)
    is Message(flag=b'\x00', message~, rest~) &&
    @grpc.next_message(rest) is Done else {
    self.refuse_call(stream, "the request is not one uncompressed message")
    return
  }
  guard ports.engine.mock_for_call(incoming, authority?=request.authority)
    is Some(mock) else {
    self.refuse_call(stream, "no Mock for this Host")
    return
  }
  guard mock.descriptor_set is Some(set) else {
    self.refuse_call(stream, "the Mock has no Descriptor set")
    return
  }
  guard set.find_method(incoming.target) is Some(rpc) else {
    self.refuse_call(stream, "unknown method")
    return
  }
  if rpc.client_streaming || rpc.server_streaming {
    self.refuse_call(stream, "streaming methods are not served yet")
    return
  }
  // A message that does not parse, or whose type has a field that smock
  // does not decode yet, does not decode.
  let json = @protobuf.decode_json(set.input_of(rpc), message) catch {
    _ => {
      self.refuse_call(stream, "the request message cannot be decoded")
      return
    }
  }
  let outcome = ports.decide(
    { ..incoming, body: json, },
    authority?=request.authority,
    grpc={ path: incoming.target, octets: incoming.body.length(), },
    now=self.now,
  )
  let plan = outcome.plan
  let date = ports.dates.at(self.now)
  guard outcome.is_grpc_reply() else {
    let message = match outcome.content_error {
      _ if outcome.matched is None => "no Stub matched"
      Some({ failure: Template(_), .. }) => "template failed"
      Some({ failure: Data(_), .. }) => "data write failed"
      None => "state limit reached"
    }
    let fields = trailers_only(
      @grpc.Internal,
      message,
      smock_mock_of(plan.headers),
      date~,
    )
    self.headers_only(stream, fields, outcome.journal, partial=false)
    self.ended_in_place(request, outcome)
    return
  }
  // A static reply was checked against the output type at load; a
  // templated one is checked here, once rendered.
  let reply = encode_reply(set.output_of(rpc), plan.body) catch {
    _ => {
      let fields = trailers_only(
        @grpc.Internal,
        "template failed",
        smock_mock_of(plan.headers),
        date~,
      )
      self.headers_only(stream, fields, outcome.journal, partial=false)
      self.ended_in_place(request, outcome)
      return
    }
  }
  let rest = self.queue_reply(
    stream,
    reply_head(plan.headers, date~),
    @grpc.frame(reply),
    outcome.journal,
  )
  if rest.length() > 0 {
    self.write_slowly(
      stream,
      request,
      rest,
      outcome,
      out,
      trailers=ok_trailers(),
    )
    return
  }
  self.ended_in_place(request, outcome)
}

///|
/// The reply message that `body`, a plan's body, holds as JSON, encoded
/// with `output`: an empty body is an empty message. Raises when the body
/// is not JSON, or not a message of the type.
fn encode_reply(
  output : @protobuf.MessageDescriptor,
  body : @engine.Body,
) -> Bytes raise {
  guard body is Bytes(json) else { fail("a reply is not events") }
  if json.length() == 0 {
    return b""
  }
  @protobuf.encode_json(output, @json.parse(@utf8.decode(json)))
}

///|
/// Queues on `stream` the reply whose HEADERS are `head` and whose framed
/// message is `framed`, and commits the Journal entry `entry` just before
/// the trailers that end the stream. A message that fits the windows is
/// queued whole, in one DATA frame that does not end the stream, then the
/// trailers. One that does not fit gets as much as the windows allow; the
/// rest is returned, which the caller sends in the stream's task, with the
/// trailers after it and the entry still to commit. HEADERS or trailers the
/// `Conn` refuses get RST_STREAM INTERNAL_ERROR, the entry committed just
/// before (`reset_after`).
fn H2Connection::queue_reply(
  self : H2Connection,
  stream : Int32,
  head : Array[@header.Header],
  framed : Bytes,
  entry : @engine.JournalEntry?,
) -> BytesView {
  self.conn.headers(stream, head) catch {
    _ => {
      self.reset_after(stream, entry)
      return framed[0:0]
    }
  }
  let room = self.room(stream)
  if framed.length() > room {
    if room > 0 {
      self.conn.data(stream, framed[0:room]) catch {
        _ => return framed[0:0]
      }
    }
    return framed[room:]
  }
  // The message fits the windows, so the `Conn` takes it.
  self.conn.data(stream, framed) catch {
    _ => return framed[0:0]
  }
  self.ports.commit(entry)
  self.end_with_trailers(stream, ok_trailers())
  framed[0:0]
}

///|
/// Ends `stream`, whose reply's message is queued, with the trailers
/// `trailers`. Trailers the `Conn` refuses get RST_STREAM INTERNAL_ERROR
/// instead. It runs where the reply is queued, so the reset leaves the
/// stream's task be.
fn H2Connection::end_with_trailers(
  self : H2Connection,
  stream : Int32,
  trailers : Array[@header.Header],
) -> Unit {
  self.conn.headers(stream, trailers, end=true) catch {
    _ => {
      self.reset(stream, @http2.error_internal_error, own_task=true)
      return
    }
  }
  self.streams.ended_by_smock(stream)
}

///|
/// Answers `stream`, a gRPC call whose request has ended and that this
/// layer cannot serve, with Trailers-Only INTERNAL and the fixed ASCII
/// `message`, and counts it as rejected traffic. It never reached the
/// engine, so it has no Journal entry.
fn H2Connection::refuse_call(
  self : H2Connection,
  stream : Int32,
  message : String,
) -> Unit {
  let fields = trailers_only(
    @grpc.Internal,
    message,
    None,
    date=self.ports.dates.at(self.now),
  )
  self.conn.headers(stream, fields, end=true) catch {
    _ => {
      self.reset(stream, @http2.error_internal_error)
      return
    }
  }
  self.streams.ended_by_smock(stream)
  self.ports.rejected(self.last_read)
}

///|
/// The HEADERS of a gRPC reply: `:status` 200, `content-type:
/// application/grpc`, then each of `headers` as `response_fields` sends a
/// header field, then `date` with the value `date`, unless `headers` give
/// one. A gRPC reply has no `content-length`.
fn reply_head(
  headers : ArrayView[(String, String)],
  date~ : String,
) -> Array[@header.Header] {
  let fields = Array(capacity=headers.length() + 3)
  fields.push(@header.Header::{ name: b":status", value: b"200", })
  fields.push({ name: b"content-type", value: grpc_content_type, })
  let mut has_date = false
  for header in headers {
    let name = lower_case(header.0)
    if is_connection_specific(name) {
      continue
    }
    if name == b"date" {
      has_date = true
    }
    fields.push({ name, value: @http1.field_octets(trimmed(header.1)), })
  }
  if !has_date {
    fields.push({ name: b"date", value: @http1.field_octets(date), })
  }
  fields
}

///|
/// The trailers of a reply that succeeded: `grpc-status: 0`.
fn ok_trailers() -> Array[@header.Header] {
  [{ name: b"grpc-status", value: b"0", }]
}

///|
/// The fields of a Trailers-Only answer, one HEADERS block that ends the
/// stream: `:status` 200, `content-type: application/grpc`, `grpc-status`
/// with the code of `status`, `grpc-message` with `message`, fixed ASCII
/// text, then `smock-mock` when `mock` gives its value, and `date` with the
/// value `date`.
fn trailers_only(
  status : @grpc.Status,
  message : String,
  mock : String?,
  date~ : String,
) -> Array[@header.Header] {
  let fields = [
    @header.Header::{ name: b":status", value: b"200", },
    { name: b"content-type", value: grpc_content_type, },
    { name: b"grpc-status", value: decimal(status.code()), },
    { name: b"grpc-message", value: @http1.field_octets(message), },
  ]
  if mock is Some(value) {
    fields.push({ name: b"smock-mock", value: @http1.field_octets(value), })
  }
  fields.push({ name: b"date", value: @http1.field_octets(date), })
  fields
}

///|
/// The value of the `Smock-Mock` field among `headers`, a plan's, which the
/// engine adds when the Default Mock answered: smock's own field, which a
/// Trailers-Only answer carries. The plan's other fields, such as the
/// Mock's `noMatch.headers`, never reach a gRPC call.
fn smock_mock_of(headers : Array[(String, String)]) -> String? {
  for header in headers {
    if header.0 == "Smock-Mock" {
      return Some(header.1)
    }
  }
  None
}
