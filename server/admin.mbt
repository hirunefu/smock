// The Admin API on the admin port: JSON over HTTP/1.1, as the OpenAPI
// document openapi/admin.json defines it.

///|
/// The Admin API of one smock process.
priv struct Admin {
  engine : @engine.Engine
  build : @buildinfo.BuildInfo
  /// The replica's name, as the `Smock-Replica` header carries it.
  replica : String
  /// The warnings every JSON response carries.
  warnings : Json
}

///|
/// A response, before it is encoded.
priv struct Reply {
  status : Int
  headers : Array[(String, String)]
  body : Bytes
}

///|
/// An operation: a path, its method and what answers it.
priv struct Route {
  path : String
  meth : String
  answer : (Admin, @http1.Request) -> Reply
}

///|
/// The operations of the Admin API.
let routes : Array[Route] = [
  { path: "/v1/status", meth: "GET", answer: status, },
]

///|
/// Creates the Admin API of a process that serves through `engine`.
///
/// - `replica` is the replica's name, such as the Pod's hostname.
/// - `replicas` is how many replicas the deployment runs.
fn Admin::new(
  engine : @engine.Engine,
  build : @buildinfo.BuildInfo,
  replica~ : String,
  replicas~ : Int,
) -> Admin {
  let replica = header_safe(replica)
  let warnings : Array[Json] = if replicas > 1 {
    [
      {
        "code": "per_replica_state",
        "message": "This deployment runs \{replicas} replicas (--replicas), and each one keeps its own Ephemeral Stubs and Journal. This response comes from \{replica} alone.",
      },
    ]
  } else {
    []
  }
  { engine, build, replica, warnings: Json::array(warnings), }
}

///|
/// The encoded response to `request`.
fn Admin::respond(self : Admin, request : @http1.Request) -> Bytes {
  let reply = self.handle(request)
  @http1.encode_response(
    reply.status,
    [("Smock-Replica", self.replica), ..reply.headers],
    reply.body,
    request~,
  )
}

///|
/// The encoded response, with `Connection: close`, to bytes that are not a
/// valid request or are over a limit, with the status the codec chose.
fn Admin::reject(self : Admin, status : Int) -> Bytes {
  let (code, message) = match status {
    413 =>
      ("content_too_large", "the body is over the body limit (--body-limit)")
    431 =>
      (
        "header_fields_too_large", "the request head is over the header limits (--header-size-limit, --header-count-limit)",
      )
    501 =>
      (
        "not_implemented", "the request uses a transfer coding other than chunked",
      )
    505 =>
      ("http_version_not_supported", "the request is not HTTP/1.0 or HTTP/1.1")
    _ => ("bad_request", "the request is not valid HTTP/1.1")
  }
  let reply = self.error(status, code, message)
  @http1.encode_response(
    reply.status,
    [("Smock-Replica", self.replica), ..reply.headers],
    reply.body,
    close=true,
  )
}

///|
/// An error reply, in the form `{error, message, warnings}`.
fn Admin::error(
  self : Admin,
  status : Int,
  code : String,
  message : String,
) -> Reply {
  self.json(status, {
    "error": Json::string(code),
    "message": Json::string(message),
  })
}

///|
/// The reply to `request`.
fn Admin::handle(self : Admin, request : @http1.Request) -> Reply {
  let path = path_of(request.target)
  for route in routes {
    if route.path == path && route.meth == request.meth {
      return (route.answer)(self, request)
    }
  }
  self.json(404, {})
}

///|
/// A JSON reply: `body` with the `warnings` member added.
fn Admin::json(self : Admin, status : Int, body : Map[String, Json]) -> Reply {
  body["warnings"] = self.warnings
  {
    status,
    headers: [("Content-Type", "application/json")],
    body: @utf8.encode(Json::object(body).stringify()),
  }
}

///|
/// Shows what this replica runs and serves.
fn status(admin : Admin, _request : @http1.Request) -> Reply {
  let status = admin.engine.status()
  admin.json(200, {
    "version": Json::string(admin.build.version),
    "commit": Json::string(admin.build.commit),
    "toolchain": Json::string(admin.build.toolchain),
    "digest": Json::null(),
    "lastReload": Json::null(),
    "mocks": Json::array(
      status.mocks.map(mock => {
        "name": Json::string(mock.name),
        "hosts": Json::array(mock.hosts.map(host => Json::string(host))),
        "default": Json::boolean(mock.is_default),
      }),
    ),
  })
}

///|
/// The path of a request target, without the query.
fn path_of(target : String) -> String {
  match target.find("?") {
    Some(i) => target[:i].to_owned()
    None => target
  }
}

///|
/// `value` as it can be written in a header value, ASCII only: the
/// characters of an HTTP token stay as they are, except `%`, and every other
/// byte of its UTF-8 encoding is percent-encoded.
fn header_safe(value : String) -> String {
  let out = StringBuilder()
  for byte in @utf8.encode(value) {
    let c = byte.to_int().unsafe_to_char()
    let token = (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (c >= '0' && c <= '9') ||
      "!#$&'*+-.^_`|~".contains_char(c)
    if token {
      out.write_char(c)
    } else {
      out.write_string("%")
      out.write_string(
        byte.to_int().to_string(radix=16).to_upper().pad_start(2, '0'),
      )
    }
  }
  out.to_string()
}
