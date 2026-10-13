// The Admin API on the admin port: JSON over HTTP/1.1, as the OpenAPI
// document openapi/admin.json defines it.

///|
/// The Admin API of one smock process.
priv struct Admin {
  /// Where the process is in its life, which the probes report.
  lifecycle : Lifecycle
  build : @buildinfo.BuildInfo
  /// The metrics `/metrics` serves.
  metrics : @metrics.Registry
  /// The metrics of the Journal, brought up to date on each scrape.
  journal_metrics : JournalMetrics
  /// Where changes made through the Admin API are logged.
  logger : @log.Logger
  /// The token every operation needs, as UTF-8, or `None` when
  /// authentication is off.
  token : Bytes?
  /// The replica's name, as the `Smock-Replica` header carries it.
  replica : String
  /// The warnings every JSON response carries.
  warnings : Json
  /// Where calls carry the calling Session, as requests to the Mocks
  /// carry theirs.
  sessions : SessionCarrier
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
  /// What answers a call.
  answer : (Admin, Call) -> Reply
}

///|
/// One call of an operation.
priv struct Call {
  request : @http1.Request
  /// Each `{name}` of the route's path, with the segment of the request's
  /// path it stands for, as sent: still percent-encoded.
  params : Map[String, String]
  /// The body, parsed as JSON, for an operation that takes one and a
  /// request that has one.
  body : Json?
}

///|
/// The path parameter `name` of the call, percent-decoded, with bytes that
/// are not UTF-8 as U+FFFD: such as the Mock name `users api` in
/// `/v1/mocks/users%20api/stubs`.
fn Call::param(self : Call, name : String) -> String {
  @percent.decode_lossy(self.params[name])
}

///|
/// Everything the admin port serves: the operations of the OpenAPI
/// document, openapi/admin.json.
let routes : Array[Route] = [
  route("/v1/status", "GET", status),
  route("/v1/mocks/{mock}/stubs", "GET", list_stubs),
  route("/v1/mocks/{mock}/stubs", "POST", add_stub, takes_body=true),
  route("/v1/mocks/{mock}/stubs/{id}", "DELETE", delete_stub),
  route("/v1/reset", "POST", reset, takes_body=true),
  route("/v1/journal/query", "POST", query_journal, takes_body=true),
  route("/v1/journal/verify", "POST", verify_journal, takes_body=true),
  route("/v1/journal/unmatched", "GET", list_unmatched),
  route("/v1/stubs/{id}/render", "POST", render, takes_body=true),
  route("/startupz", "GET", startup_probe, open=true),
  route("/readyz", "GET", readiness_probe, open=true),
  route("/livez", "GET", liveness_probe, open=true),
  route("/metrics", "GET", metrics, open=true),
]

///|
fn route(
  path : String,
  meth : String,
  answer : (Admin, Call) -> Reply,
  open? : Bool = false,
  takes_body? : Bool = false,
) -> Route {
  { path, meth, open, takes_body, answer, }
}

///|
/// Creates the Admin API of a process whose life `lifecycle` follows.
///
/// - `metrics` holds the metrics `/metrics` serves, among them
///   `journal_metrics`.
/// - `logger` logs each change made through the Admin API.
/// - `token` is the bearer token every operation needs, or `None` to turn
///   authentication off.
/// - `replica` is the replica's name, such as the Pod's hostname.
/// - `replicas` is how many replicas the deployment runs.
/// - `sessions` says where calls carry the calling Session.
fn Admin::new(
  lifecycle : Lifecycle,
  build : @buildinfo.BuildInfo,
  metrics~ : @metrics.Registry,
  journal_metrics~ : JournalMetrics,
  logger~ : @log.Logger,
  token~ : String?,
  replica~ : String,
  replicas~ : Int,
  sessions~ : SessionCarrier,
) -> Admin {
  let replica = @engine.header_safe(replica)
  {
    lifecycle,
    build,
    metrics,
    journal_metrics,
    logger,
    token: token.map(token => @utf8.encode(token)),
    replica,
    warnings: @engine.admin_warnings(replicas~, replica~).to_json(),
    sessions,
  }
}

///|
/// The encoded response to `request`.
fn Admin::respond(self : Admin, request : @http1.Request) -> Bytes {
  self.encode(self.handle(request), request~)
}

///|
/// `reply` encoded, with the replica's name in `Smock-Replica` first, as
/// the answer to `request` when one was parsed. With `close`, it says
/// `Connection: close`.
fn Admin::encode(
  self : Admin,
  reply : Reply,
  request? : @http1.Request,
  close? : Bool = false,
) -> Bytes {
  @http1.encode_response(
    reply.status,
    [("Smock-Replica", self.replica), ..reply.headers],
    reply.body,
    request?,
    close~,
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
  self.encode(self.error(status, code, message), close=true)
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
/// path is served without one; the path; the method; that the first
/// definition set has loaded, unless the path is served without a token;
/// the JSON body, for an operation that takes one.
fn Admin::handle(self : Admin, request : @http1.Request) -> Reply {
  let path = path_of(request.target)
  let at_path = []
  for route in routes {
    if path_params(route.path, path) is Some(params) {
      at_path.push((route, params))
    }
  }
  let open = at_path.length() > 0 && at_path.iter().all(at => at.0.open)
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
  guard at_path.search_by(at => at.0.meth == meth) is Some(i) else {
    let allowed = []
    for at in at_path {
      let (route, _) = at
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
  let (route, params) = at_path[i]
  // Every operation but the probes and the metrics needs the definitions.
  if !route.open && self.lifecycle.engine is None {
    return self.not_started()
  }
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
  (route.answer)(self, { request, params, body, })
}

///|
/// The path parameters of `path` when it fits the route path `template`,
/// where `{name}` stands for any one non-empty path segment: each name with
/// its segment, as sent. `None` when it does not fit.
fn path_params(template : String, path : String) -> Map[String, String]? {
  let expected = template.split("/").collect()
  let actual = path.split("/").collect()
  if expected.length() != actual.length() {
    return None
  }
  let params = Map([])
  for i, t in expected {
    let a = actual[i]
    if t.has_prefix("{") && t.has_suffix("}") && a != "" {
      params[t[1:t.length() - 1].to_owned()] = a.to_owned()
    } else if t != a {
      return None
    }
  }
  Some(params)
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
/// A 200 JSON reply that carries `value`, a result the engine gives as a
/// JSON object, with the `warnings` member added.
fn[T : ToJson] Admin::result(self : Admin, value : T) -> Reply {
  guard value.to_json() is Object(members) else {
    abort("an Admin API result is a JSON object")
  }
  self.json(200, members)
}

///|
/// Shows what this replica runs and serves.
fn status(admin : Admin, _call : Call) -> Reply {
  let status = admin.engine().status()
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
          "result": Json::string(reload.result.name()),
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
/// The reply to an operation that needs the definitions before the first
/// definition set has loaded.
fn Admin::not_started(self : Admin) -> Reply {
  self.error(503, "not_started", "the first definition set has not loaded yet")
}

///|
/// The engine, for an operation that needs the definitions. `handle`
/// answers such an operation with `not_started` until the first definition
/// set has loaded, so the engine is there when it runs.
fn Admin::engine(self : Admin) -> @engine.Engine {
  match self.lifecycle.engine {
    Some(engine) => engine
    None => abort("an Admin API operation ran before the definitions loaded")
  }
}

///|
/// The reply of a probe that passes.
fn Admin::probe_ok(self : Admin) -> Reply {
  self.json(200, { "status": "ok" })
}

///|
/// The startup probe: it passes once the first definition set has loaded.
fn startup_probe(admin : Admin, _call : Call) -> Reply {
  match admin.lifecycle.engine {
    Some(_) => admin.probe_ok()
    None => admin.not_started()
  }
}

///|
/// The readiness probe: it passes while smock serves, also after a reload
/// that failed, since the previous definition set still serves. It fails
/// before startup completes and from the moment smock starts to drain.
fn readiness_probe(admin : Admin, _call : Call) -> Reply {
  match (admin.lifecycle.phase, admin.lifecycle.engine) {
    (Serving, _) => admin.probe_ok()
    (Starting, None) => admin.not_started()
    (Starting, Some(_)) =>
      admin.error(503, "not_ready", "the plain and TLS ports are not open yet")
    (Draining, _) =>
      admin.error(
        503, "not_ready", "smock is draining its connections before it exits",
      )
  }
}

///|
/// The liveness probe: it passes whenever the event loop answers it,
/// including while smock drains, so that a draining process is not killed
/// early.
fn liveness_probe(admin : Admin, _call : Call) -> Reply {
  admin.probe_ok()
}

///|
/// Renders the response of a Stub from the Definition files for the sample
/// request in the body, against the snapshot this replica serves now, as
/// `smock render` does. The `time` and `seed` query parameters give the
/// time the sample is received at and the seed of the random source the
/// rendering draws from; without them, the time is now and the seed is a
/// fresh one. Rendering changes nothing.
fn render(admin : Admin, call : Call) -> Reply {
  let invalid = (message : String) => {
    admin.error(400, "invalid_request", message)
  }
  let request = call.request
  let id = @percent.decode(call.params["id"]) catch {
    _ =>
      return invalid(
        "the Stub ID in the path is not valid percent-encoded UTF-8",
      )
  }
  let now = match query_parameter(request.target, "time") {
    Err(message) => return invalid(message)
    Ok(None) => @async.now()
    Ok(Some(text)) =>
      match @log.parse_time(text) {
        Some(time) => time
        None =>
          return invalid(
            "the time query parameter must be an RFC 3339 date-time, such as 2026-10-12T14:30:05Z",
          )
      }
  }
  let seed = match query_parameter(request.target, "seed") {
    Err(message) => return invalid(message)
    Ok(None) => @settings.random_seed()
    Ok(Some(text)) =>
      match @settings.parse_seed(text) {
        Some(seed) => seed
        None =>
          return invalid(
            "the seed query parameter must be an integer from 0 to \{@definitions.max_seed}",
          )
      }
  }
  guard call.body is Some(json) else {
    return invalid("the body must be a sample request: a JSON object")
  }
  let sample = @engine.SampleRequest::from_json(json) catch {
    err => return invalid("the sample request is not valid: \{err.message()}")
  }
  let rendering = admin
    .engine()
    .render(id, sample, now~, rand=@prng.Generator(seed)) catch {
      err => return admin.error(404, "unknown_stub", err.message())
    }
  admin.result(rendering)
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
/// Serves every metric in the Prometheus text format. The Journal's are
/// brought up to date first, once the definitions have loaded.
fn metrics(admin : Admin, _call : Call) -> Reply {
  if admin.lifecycle.engine is Some(engine) {
    admin.journal_metrics.update(engine.journal_stats())
  }
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
