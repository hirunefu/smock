// The Admin API on the admin port: JSON over HTTP/1.1, as the OpenAPI
// document openapi/admin.json defines it.

///|
/// The Admin API of one smock process.
priv struct Admin {
  engine : @engine.Engine
  build : @buildinfo.BuildInfo
  /// The metrics `/metrics` serves.
  metrics : @metrics.Registry
  /// Where changes made through the Admin API are logged.
  logger : @log.Logger
  /// The token every operation needs, as UTF-8, or `None` when
  /// authentication is off.
  token : Bytes?
  /// The replica's name, as the `Smock-Replica` header carries it.
  replica : String
  /// The warnings every JSON response carries.
  warnings : Json
  /// The header that carries the calling Session, as W3C Baggage, and the
  /// member whose value is the Session key, as on mocked requests.
  session_header : String
  session_member : String
}

///|
/// A response, before it is encoded.
priv struct Reply {
  status : Int
  headers : Array[(String, String)]
  body : Bytes
}

///|
/// An operation of the Admin API, or another endpoint of the admin port.
priv struct Route {
  /// The path, where `{name}` stands for one path segment, such as
  /// `/v1/mocks/{mock}/stubs`.
  path : String
  meth : String
  /// Whether it is served without a token, as the probes and the metrics
  /// are.
  open : Bool
  /// Whether it takes a JSON request body.
  takes_body : Bool
  /// What answers a call, given the request and its body, parsed as JSON
  /// when there is one.
  answer : (Admin, @http1.Request, Json?) -> Reply
}

///|
/// Everything the admin port serves: the operations of the OpenAPI
/// document, openapi/admin.json. Those that later tickets build answer 501
/// until then.
let routes : Array[Route] = [
  route("/v1/status", "GET", status),
  route("/v1/mocks/{mock}/stubs", "GET", list_stubs),
  route("/v1/mocks/{mock}/stubs", "POST", add_stub, takes_body=true),
  route("/v1/mocks/{mock}/stubs/{id}", "DELETE", delete_stub),
  route("/v1/reset", "POST", reset, takes_body=true),
  route("/v1/journal/query", "POST", not_implemented, takes_body=true),
  route("/v1/journal/verify", "POST", not_implemented, takes_body=true),
  route("/v1/journal/unmatched", "GET", not_implemented),
  route("/v1/stubs/{id}/render", "POST", render, takes_body=true),
  route("/startupz", "GET", not_implemented, open=true),
  route("/readyz", "GET", not_implemented, open=true),
  route("/livez", "GET", not_implemented, open=true),
  route("/metrics", "GET", metrics, open=true),
]

///|
fn route(
  path : String,
  meth : String,
  answer : (Admin, @http1.Request, Json?) -> Reply,
  open? : Bool = false,
  takes_body? : Bool = false,
) -> Route {
  { path, meth, open, takes_body, answer, }
}

///|
/// Creates the Admin API of a process that serves through `engine`.
///
/// - `metrics` holds the metrics `/metrics` serves.
/// - `logger` logs each change made through the Admin API.
/// - `token` is the bearer token every operation needs, or `None` to turn
///   authentication off.
/// - `replica` is the replica's name, such as the Pod's hostname.
/// - `replicas` is how many replicas the deployment runs.
/// - `session_header` and `session_member` name the calling Session's
///   header and its W3C Baggage member.
fn Admin::new(
  engine : @engine.Engine,
  build : @buildinfo.BuildInfo,
  metrics~ : @metrics.Registry,
  logger~ : @log.Logger,
  token~ : String?,
  replica~ : String,
  replicas~ : Int,
  session_header~ : String,
  session_member~ : String,
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
  {
    engine,
    build,
    metrics,
    logger,
    token: token.map(token => @utf8.encode(token)),
    replica,
    warnings: Json::array(warnings),
    session_header,
    session_member,
  }
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
/// The reply to `request`. Checks, in this order: the token, unless the
/// path is served without one; the path; the method; the JSON body, for an
/// operation that takes one.
fn Admin::handle(self : Admin, request : @http1.Request) -> Reply {
  let path = path_of(request.target)
  let at_path = routes.filter(route => path_matches(route.path, path))
  let open = at_path.length() > 0 && at_path.iter().all(route => route.open)
  if !open && self.token is Some(token) {
    match bearer_token(request) {
      None =>
        return self.unauthorized(
          "the Admin API needs Authorization: Bearer <token>",
        )
      Some(given) if !same_token(token, given) =>
        return self.unauthorized("the bearer token is wrong")
      Some(_) => ()
    }
  }
  if at_path.is_empty() {
    return self.error(404, "not_found", "no Admin API operation at \{path}")
  }
  // HEAD is GET without the body, which the codec leaves out.
  let meth = if request.meth == "HEAD" { "GET" } else { request.meth }
  guard at_path.search_by(route => route.meth == meth) is Some(i) else {
    let allowed = []
    for route in at_path {
      allowed.push(route.meth)
      if route.meth == "GET" {
        allowed.push("HEAD")
      }
    }
    let allow = allowed.join(", ")
    let reply = self.error(
      405,
      "method_not_allowed",
      "\{path} takes \{allow}, not \{request.meth}",
    )
    reply.headers.push(("Allow", allow))
    return reply
  }
  let route = at_path[i]
  let body = if route.takes_body && request.body.length() > 0 {
    let parsed = try @json.parse(@utf8.decode(request.body)) catch {
      @utf8.Malformed(_) => Err("it is not UTF-8")
      err => Err(err.to_string())
    } noraise {
      json => Ok(json)
    }
    match parsed {
      Ok(json) => Some(json)
      Err(reason) =>
        return self.error(
          400,
          "malformed_json",
          "the body is not valid JSON: \{reason}",
        )
    }
  } else {
    None
  }
  (route.answer)(self, request, body)
}

///|
/// Whether `path` fits the route path `template`, where `{name}` stands
/// for any one non-empty path segment.
fn path_matches(template : String, path : String) -> Bool {
  let expected = template.split("/").collect()
  let actual = path.split("/").collect()
  expected.length() == actual.length() &&
  expected
  .iter()
  .zip(actual.iter())
  .all(pair => {
    let (t, a) = pair
    (t.has_prefix("{") && t.has_suffix("}") && a != "") || t == a
  })
}

///|
/// Answers an operation that the document defines and a later ticket
/// builds.
fn not_implemented(
  admin : Admin,
  request : @http1.Request,
  _body : Json?,
) -> Reply {
  admin.error(
    501,
    "not_implemented",
    "\{request.meth} \{path_of(request.target)} is not implemented in this build",
  )
}

///|
/// The reply to a request without the right bearer token.
fn Admin::unauthorized(self : Admin, message : String) -> Reply {
  let reply = self.error(401, "unauthorized", message)
  reply.headers.push(("WWW-Authenticate", "Bearer"))
  reply
}

///|
/// The token of the request's `Authorization: Bearer <token>` field. A
/// request has none without exactly one Authorization field, or when the
/// field uses another scheme.
fn bearer_token(request : @http1.Request) -> BytesView? {
  let fields = request.headers.filter(header => {
    header.name.to_lower() == "authorization"
  })
  guard fields is [field] else { return None }
  let value = field.value[:]
  let scheme = "bearer"
  guard value.length() > scheme.length() &&
    value[scheme.length()] is (b' ' | b'\t') else {
    return None
  }
  for i, c in scheme {
    let byte = value[i]
    let lower = if byte >= b'A' && byte <= b'Z' { byte + 32 } else { byte }
    if lower.to_int() != c.to_int() {
      return None
    }
  }
  let mut start = scheme.length()
  while start < value.length() && value[start] is (b' ' | b'\t') {
    start += 1
  }
  if start == value.length() {
    None
  } else {
    Some(value[start:])
  }
}

///|
/// Whether `given` is `token`, compared in constant time: the time taken
/// depends on the length of `token` only, never on how much of `given`
/// matches it.
fn same_token(token : Bytes, given : BytesView) -> Bool {
  let mut difference = token.length() ^ given.length()
  for i, byte in token {
    let other = if given.length() == 0 {
      0
    } else {
      given[i % given.length()].to_int()
    }
    difference = difference | (byte.to_int() ^ other)
  }
  difference == 0
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
fn status(admin : Admin, _request : @http1.Request, _body : Json?) -> Reply {
  let status = admin.engine.status()
  admin.json(200, {
    "version": Json::string(admin.build.version),
    "commit": Json::string(admin.build.commit),
    "toolchain": Json::string(admin.build.toolchain),
    "digest": Json::string(status.digest),
    "lastReload": match status.last_reload {
      None => Json::null()
      Some(reload) =>
        {
          "at": Json::string(@log.format_time(reload.at)),
          "result": Json::string(outcome_name(reload.result)),
          "errors": diagnostics_json(reload.errors),
        }
    },
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
/// Renders the response of a Stub from the Definition files for the sample
/// request in the body, against the snapshot this replica serves now, as
/// `smock render` does. The `time` and `seed` query parameters give the
/// time the sample is received at and the seed of the random source the
/// rendering draws from; without them, the time is now and the seed is a
/// fresh one. Rendering changes nothing.
fn render(admin : Admin, request : @http1.Request, body : Json?) -> Reply {
  let invalid = (message : String) => {
    admin.error(400, "invalid_request", message)
  }
  let path = path_of(request.target)
  let segment = path["/v1/stubs/".length():path.length() - "/render".length()]
  let id = @percent.decode(segment) catch {
    _ =>
      return invalid(
        "the Stub ID in the path is not valid percent-encoded UTF-8",
      )
  }
  let now = match query_parameter(request.target, "time") {
    Err(message) => return invalid(message)
    Ok(None) => @async.now()
    Ok(Some(text)) =>
      match @settings.parse_time(text) {
        Some(time) => time
        None =>
          return invalid(
            "the time query parameter must be an RFC 3339 date-time, such as 2026-10-12T14:30:05Z",
          )
      }
  }
  let seed = match query_parameter(request.target, "seed") {
    Err(message) => return invalid(message)
    Ok(None) => random_seed()
    Ok(Some(text)) =>
      match @settings.parse_seed(text) {
        Some(seed) => seed
        None =>
          return invalid(
            "the seed query parameter must be an integer from 0 to 9007199254740991",
          )
      }
  }
  guard body is Some(json) else {
    return invalid("the body must be a sample request: a JSON object")
  }
  let sample = @engine.SampleRequest::from_json(json) catch {
    err => return invalid("the sample request is not valid: \{err.message()}")
  }
  let rendering = admin.engine.render(
    id,
    sample,
    now~,
    rand=@prng.Generator(seed),
  ) catch {
    err => return admin.error(404, "unknown_stub", err.message())
  }
  guard rendering.to_json() is Object(members) else {
    abort("a rendering is a JSON object")
  }
  admin.json(200, members)
}

///|
/// The value of the query parameter `name` in the request target `target`,
/// percent-decoded, if it is given. A `+` stays a plus sign, as in a time
/// zone offset. Fails with a message when the parameter is given more than
/// once or its value is not valid percent-encoded UTF-8.
fn query_parameter(target : String, name : String) -> Result[String?, String] {
  guard target.find("?") is Some(start) else { return Ok(None) }
  let mut found = None
  for parameter in target[start + 1:].split("&") {
    let (key, value) = match parameter.find("=") {
      Some(i) => (parameter[:i], parameter[i + 1:])
      None => (parameter, "")
    }
    if @percent.decode_lossy(key) != name {
      continue
    }
    if found is Some(_) {
      return Err("the \{name} query parameter is given more than once")
    }
    found = Some(
      @percent.decode(value) catch {
        _ =>
          return Err(
            "the \{name} query parameter is not valid percent-encoded UTF-8",
          )
      },
    )
  }
  Ok(found)
}

///|
/// Serves every metric in the Prometheus text format.
fn metrics(admin : Admin, _request : @http1.Request, _body : Json?) -> Reply {
  {
    status: 200,
    headers: [("Content-Type", "text/plain; version=0.0.4; charset=utf-8")],
    body: @utf8.encode(admin.metrics.render()),
  }
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
