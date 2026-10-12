// Rendering: the response of a named Stub for a sample request, whether or
// not the sample meets the Stub's conditions, with the conditions it fails.
// `smock render` and the Admin render operation both show it.

///|
/// A sample request to render a Stub for. Its JSON form is the
/// `SampleRequest` schema of the Admin API document, which
/// `smock render --request` reads too.
pub(all) struct SampleRequest {
  meth : String
  /// The path as Stub conditions compare it: percent-decoded, without the
  /// query.
  path : String
  /// The query parameters as decoded (name, value) pairs, in order. A
  /// repeated parameter appears once per value.
  query : Array[(String, String)]
  /// The header fields as (name, value) pairs, in order. A repeated field
  /// appears once per value.
  headers : Array[(String, String)]
  /// The body, sent as UTF-8.
  body : String
  /// The request's Session, or `None` for none.
  session : String?
} derive(Debug)

///|
/// A sample request that does not have the shape of the `SampleRequest`
/// schema: what is wrong, and a JSON Pointer (RFC 6901) to the value it is
/// about, `""` for the whole sample.
pub suberror InvalidSample {
  InvalidSample(pointer~ : String, message~ : String)
} derive(Debug)

///|
/// `<pointer>: <message>`, or the message alone when it is about the whole
/// sample.
pub fn InvalidSample::message(self : InvalidSample) -> String {
  let InvalidSample(pointer~, message~) = self
  if pointer == "" {
    message
  } else {
    "\{pointer}: \{message}"
  }
}

///|
/// Reads a sample request from its JSON form, the `SampleRequest` schema:
/// an object whose members are all optional. The method defaults to GET,
/// the path to `/`, the body to empty, and there is no Session by default.
/// Query parameters and header fields map a name to a value, or to the
/// values of a repeated one, in order.
pub fn SampleRequest::from_json(
  json : Json,
) -> SampleRequest raise InvalidSample {
  guard json is Object(members) else {
    raise InvalidSample(pointer="", message="must be a JSON object")
  }
  let mut meth = "GET"
  let mut path = "/"
  let mut query = []
  let mut headers = []
  let mut body = ""
  let mut session = None
  for name, value in members {
    let at = "/" + pointer_token(name)
    match name {
      "method" =>
        match value {
          String(value) if value != "" => meth = value
          _ =>
            raise InvalidSample(
              pointer=at,
              message="must be a non-empty string",
            )
        }
      "path" =>
        match value {
          String(value) if value.has_prefix("/") => path = value
          _ =>
            raise InvalidSample(
              pointer=at,
              message="must be a string that starts with /",
            )
        }
      "query" => query = values(value, at)
      "headers" => headers = values(value, at)
      "body" =>
        match value {
          String(value) => body = value
          _ => raise InvalidSample(pointer=at, message="must be a string")
        }
      "session" =>
        match value {
          String(value) => session = Some(value)
          Null => session = None
          _ =>
            raise InvalidSample(pointer=at, message="must be a string or null")
        }
      _ => raise InvalidSample(pointer=at, message="is not a known field")
    }
  }
  { meth, path, query, headers, body, session, }
}

///|
/// The (name, value) pairs of a `query` or `headers` member at `at`: an
/// object that maps each name to a string, or to an array of strings for a
/// repeated one.
fn values(
  json : Json,
  at : String,
) -> Array[(String, String)] raise InvalidSample {
  guard json is Object(members) else {
    raise InvalidSample(pointer=at, message="must be an object")
  }
  let out = []
  for name, value in members {
    let at = "\{at}/\{pointer_token(name)}"
    match value {
      String(value) => out.push((name, value))
      Array(items) =>
        for i, item in items {
          guard item is String(item) else {
            raise InvalidSample(
              pointer="\{at}/\{i}",
              message="must be a string",
            )
          }
          out.push((name, item))
        }
      _ =>
        raise InvalidSample(
          pointer=at,
          message="must be a string or an array of strings",
        )
    }
  }
  out
}

///|
/// `name` as a reference token of a JSON Pointer: `~` as `~0`, `/` as `~1`.
fn pointer_token(name : String) -> String {
  name.replace_all(old="~", new="~0").replace_all(old="/", new="~1")
}

///|
/// The request the sample stands for, with a target whose path and query
/// decode to exactly the sample's.
fn SampleRequest::to_request(self : SampleRequest) -> Request {
  let target = StringBuilder()
  target.write_string(
    self.path.split("/").map(segment => @percent.encode(segment)).join("/"),
  )
  for i, parameter in self.query {
    target.write_string(if i == 0 { "?" } else { "&" })
    target.write_string(@percent.encode(parameter.0))
    target.write_string("=")
    target.write_string(@percent.encode(parameter.1))
  }
  {
    meth: self.meth,
    target: target.to_string(),
    headers: self.headers,
    body: @utf8.encode(self.body),
  }
}

///|
/// A Stub's response, rendered for a sample request, with the Stub's
/// conditions that the sample fails. Its JSON form is the `Rendering`
/// schema of the Admin API document, without `warnings`.
pub(all) struct Rendering {
  /// The Stub's ID.
  stub : String
  /// The Stub's Mock.
  mock : String
  status : Int
  /// The header fields smock sends, in order, without those that depend on
  /// the connection, such as Content-Length.
  headers : Array[(String, String)]
  body : Body
  /// The conditions the sample fails, as in a Near miss, in the order
  /// method, path, query parameters, headers, body. Empty when it meets
  /// them all.
  failed : Array[FailedCondition]
} derive(Debug)

///|
/// No Stub from the Definition files has this ID.
pub suberror UnknownStub {
  UnknownStub(String)
} derive(Debug)

///|
pub fn UnknownStub::message(self : UnknownStub) -> String {
  let UnknownStub(id) = self
  "no Stub from the Definition files has the ID \{id.escape()}"
}

///|
/// Renders the response of the Stub with the ID `id`, a Stub from the
/// Definition files, for the sample request `sample`. The Stub is rendered
/// even when the sample fails its conditions; the rendering lists those it
/// fails, with what each expects and what the sample carries.
///
/// - `now` is the time the sample is received at, in milliseconds since the
///   Unix epoch.
/// - `rand` is the random source the rendering draws from.
///
/// Rendering changes nothing in the engine: no generator advances.
pub fn Engine::render(
  self : Engine,
  id : String,
  sample : SampleRequest,
  now~ : Int64,
  rand~ : @prng.Generator,
) -> Rendering raise UnknownStub {
  guard self.file_stub(id) is Some(stub) else { raise UnknownStub(id) }
  // A static response depends on neither the time nor the random source.
  ignore(now)
  ignore(rand)
  let incoming = Incoming::new(sample.to_request())
  let plan = stub_response(stub.response)
  {
    stub: stub.id,
    mock: stub.mock,
    status: plan.status,
    headers: plan.headers,
    body: plan.body,
    failed: incoming
    .failed(stub.request)
    .map(failed => incoming.explain(failed)),
  }
}

///|
/// The Stub from the Definition files with the ID `id`, if any.
fn Engine::file_stub(self : Engine, id : String) -> @definitions.Stub? {
  for mock in self.snapshot.mocks {
    for stub in mock.stubs {
      if stub.id == id {
        return Some(stub)
      }
    }
  }
  None
}

///|
/// The `Rendering` schema of the Admin API document, without `warnings`.
pub impl ToJson for Rendering with fn to_json(self) {
  let (body, events) = match self.body {
    Bytes(bytes) => (body_json(bytes), Json::null())
    Events(events) => (Json::null(), Json::array(events.map(event_json)))
  }
  {
    "stub": self.stub.to_json(),
    "mock": self.mock.to_json(),
    "response": {
      "status": self.status.to_json(),
      "headers": Json::array(
        self.headers.map(header => {
          "name": header.0.to_json(),
          "value": header.1.to_json(),
        }),
      ),
      "body": body,
      "events": events,
    },
    "failed": Json::array(self.failed.map(failed => ToJson::to_json(failed))),
  }
}

///|
/// The `Body` schema of the Admin API document: the bytes as text when they
/// are UTF-8, otherwise in base64, never truncated.
fn body_json(bytes : Bytes) -> Json {
  let (encoding, data) = try @utf8.decode(bytes) catch {
    _ => ("base64", @base64.encode(bytes))
  } noraise {
    text => ("utf-8", text)
  }
  {
    "encoding": encoding.to_json(),
    "data": data.to_json(),
    "size": bytes.length().to_json(),
    "truncated": false,
  }
}

///|
/// A Server-Sent Event as Definition files write it: its delay, its type
/// and ID when it has them, and its data.
fn event_json(event : SseEvent) -> Json {
  let out : Map[String, Json] = { "delay": event.delay_ms.to_json() }
  if event.event is Some(event) {
    out["event"] = event.to_json()
  }
  if event.id is Some(id) {
    out["id"] = id.to_json()
  }
  out["data"] = event.data.to_json()
  Json::object(out)
}
