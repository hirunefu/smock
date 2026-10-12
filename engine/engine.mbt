///|
/// The engine decides the response to each request from the current
/// snapshot. It does no I/O: the caller gives it the request, the Session
/// key, the time and a random source, and carries out the plan it returns.
pub struct Engine {
  /// The snapshot served. A reload replaces it whole, between two calls.
  priv mut snapshot : @definitions.Snapshot
  /// The result of the last reload, if there was one.
  priv mut last_reload : ReloadResult?
}

///|
/// A request as the engine sees it, whatever protocol carried it.
pub(all) struct Request {
  meth : String
  /// The request target as sent, such as `/users/1?x=y`.
  target : String
  /// The header fields in the order they were sent.
  headers : Array[(String, String)]
  body : Bytes
} derive(Debug)

///|
/// What the engine decided for one request.
pub(all) struct Outcome {
  /// Which Mock answered the request, if any.
  resolution : Resolution
  /// The response to send.
  plan : ResponsePlan
  /// The Journal entry for the request. The caller commits it.
  journal : JournalEntry
  /// The Near miss, when no Stub matched.
  near_miss : NearMiss?
} derive(Debug)

///|
/// Which Mock answered a request, and how the engine chose it.
pub(all) enum Resolution {
  /// The Mock whose Hosts include the request's Host.
  ByHost(String)
  /// The Default Mock, because no Mock lists the request's Host.
  ViaDefault(String)
  /// None: no Mock lists the request's Host and there is no Default Mock.
  NoMock
} derive(Debug, Eq)

///|
/// The response to send, and how to send it.
pub(all) struct ResponsePlan {
  status : Int
  headers : Array[(String, String)]
  body : Body
  /// How long to wait, in milliseconds, before writing the status line.
  delay_ms : Int
  /// A connection Fault to inject instead of a normal response.
  fault : ConnectionFault?
} derive(Debug)

///|
/// A response body: bytes sent at once, or a stream of Server-Sent Events.
pub(all) enum Body {
  Bytes(Bytes)
  Events(Array[SseEvent])
} derive(Debug)

///|
/// One Server-Sent Event, written after waiting `delay_ms` milliseconds.
pub(all) struct SseEvent {
  delay_ms : Int
  event : String?
  id : String?
  data : String
} derive(Debug)

///|
/// A connection-level Fault.
pub(all) enum ConnectionFault {
  /// Reset the connection after reading the request.
  Reset
  /// Close the connection without writing anything.
  Close
  /// Write the status line, the headers and the first half of the body,
  /// then close the connection.
  Partial
} derive(Debug)

///|
/// A Journal entry the caller commits to the Journal.
pub(all) struct JournalEntry {
  session : String?
  /// The Mock that answered, if any.
  mock : String?
  meth : String
  target : String
  headers : Array[(String, String)]
  body : Bytes
  /// The ID of the Stub that matched, if any.
  stub : String?
  status : Int
  /// When the request was received, in milliseconds since the Unix epoch.
  received_at : Int64
} derive(Debug)

///|
/// The Stub that came closest to matching a request that matched nothing,
/// and the conditions it failed.
pub(all) struct NearMiss {
  stub : String
  failed : Array[String]
} derive(Debug)

///|
/// Creates an engine that serves `snapshot`.
pub fn Engine::Engine(snapshot : @definitions.Snapshot) -> Engine {
  { snapshot, last_reload: None, }
}

///|
/// The engine's side of the Admin API status: what it serves.
pub(all) struct Status {
  /// The Mocks, in declaration order.
  mocks : Array[MockStatus]
  /// The definition set digest of the definition set served.
  digest : String
  /// The result of the last reload, or `None` before the first one.
  last_reload : ReloadResult?
} derive(Debug)

///|
/// A Mock as the Admin API status shows it.
pub(all) struct MockStatus {
  name : String
  /// The Hosts the Mock answers to, as declared.
  hosts : Array[String]
  /// Whether the Mock is the Default Mock.
  is_default : Bool
} derive(Debug)

///|
/// What the engine serves: the Mocks with their Hosts, and which one is the
/// Default Mock.
pub fn Engine::status(self : Engine) -> Status {
  let default_name = self.snapshot.default_mock().map(mock => mock.name)
  {
    mocks: self.snapshot.mocks
    .iter()
    .map(mock => MockStatus::{
      name: mock.name,
      hosts: mock.hosts.iter().collect(),
      is_default: default_name == Some(mock.name),
    })
    .collect(),
    digest: self.snapshot.digest,
    last_reload: self.last_reload,
  }
}

///|
/// What a reload did.
pub(all) struct ReloadResult {
  /// When the reload finished, in milliseconds since the Unix epoch.
  at : Int64
  result : ReloadOutcome
  /// The digest of the definition set served before the reload.
  old_digest : String
  /// The digest of the definition set served after it: the new set's when
  /// it was swapped in, otherwise `old_digest`.
  new_digest : String
  /// Every problem in the new set when it was invalid, as
  /// `@definitions.load` gives them; otherwise none.
  errors : Array[@definitions.Diagnostic]
} derive(Debug)

///|
/// How a reload ended.
pub(all) enum ReloadOutcome {
  /// The new set was valid and is served now.
  Swapped
  /// The new set has the digest of the one served, so nothing was swapped.
  Unchanged
  /// The new set was invalid, and the one served before still is.
  Failed
} derive(Debug, Eq)

///|
/// Reloads the definitions from `set`, read with the problems
/// `read_problems`, at the time `at` (milliseconds since the Unix epoch).
/// Every file is validated and a whole new snapshot is built:
///
/// - When it is valid and its digest differs from the served one, it
///   replaces the served snapshot at once. Plans the engine returned before
///   stay as they were: they hold their own bytes.
/// - When it is valid with the digest served, nothing is swapped.
/// - When it is invalid, the served snapshot stays.
///
/// Status shows the result as the last reload.
pub fn Engine::reload(
  self : Engine,
  set : @definitions.DefinitionSet,
  read_problems? : Array[@definitions.Diagnostic] = [],
  at~ : Int64,
) -> ReloadResult {
  let old_digest = self.snapshot.digest
  let (result, errors) : (ReloadOutcome, Array[@definitions.Diagnostic]) = match
    @definitions.load(set, read_problems~) {
    Ok(snapshot) if snapshot.digest == old_digest => (Unchanged, [])
    Ok(snapshot) => {
      self.snapshot = snapshot
      (Swapped, [])
    }
    Err(errors) => (Failed, errors)
  }
  let reload = {
    at,
    result,
    old_digest,
    new_digest: self.snapshot.digest,
    errors,
  }
  self.last_reload = Some(reload)
  reload
}

///|
/// Decides the response to `request`.
///
/// - `session` is the request's Session key, or `None` without a Session.
/// - `now` is the time the request was received, in milliseconds since the
///   Unix epoch.
/// - `rand` is the process's random source.
pub fn Engine::handle(
  self : Engine,
  request : Request,
  session~ : String?,
  now~ : Int64,
  rand~ : @random.Rand,
) -> Outcome {
  // Faults and templates draw from `rand` once their tickets land.
  ignore(rand)
  let host = host_of(request)
  let (resolution, mock) = match
    host.bind(host => self.snapshot.mock_for_host(host)) {
    Some(mock) => (ByHost(mock.name), Some(mock))
    None =>
      match self.snapshot.default_mock() {
        Some(mock) => (ViaDefault(mock.name), Some(mock))
        None => (NoMock, None)
      }
  }
  let incoming = Incoming::new(request)
  let matched = match mock {
    Some(mock) =>
      mock.stubs.iter().find_first(stub => incoming.meets(stub.request))
    None => None
  }
  let plan : ResponsePlan = match (mock, matched) {
    (None, _) => no_mock(host, self.snapshot.hosts())
    (Some(_), Some(stub)) => stub_response(stub.response)
    (Some(mock), None) => no_match(mock)
  }
  // A mistyped Host must not silently succeed.
  if resolution is ViaDefault(name) {
    plan.headers.push(("Smock-Mock", "\{header_safe(name)}; via=default"))
  }
  {
    resolution,
    plan,
    journal: {
      session,
      mock: mock.map(mock => mock.name),
      meth: request.meth,
      target: request.target,
      headers: request.headers,
      body: request.body,
      stub: matched.map(stub => stub.id),
      status: plan.status,
      received_at: now,
    },
    near_miss: None,
  }
}

///|
/// The plan of a Stub's `response`. Server-Sent Events are sent with
/// `Content-Type: text/event-stream`, unless the Stub gives its own
/// Content-Type.
fn stub_response(response : @definitions.Response) -> ResponsePlan {
  let headers = []
  let body : Body = match response.body {
    Bytes(bytes) => Bytes(bytes)
    Events(events) => {
      if !response.headers.iter().any(h => h.0.to_lower() == "content-type") {
        headers.push(("Content-Type", "text/event-stream"))
      }
      Events(
        events
        .iter()
        .map(event => SseEvent::{
          delay_ms: event.delay_ms,
          event: event.event,
          id: event.id,
          data: event.data,
        })
        .collect(),
      )
    }
  }
  headers.push_iter(response.headers.iter())
  { status: response.status, headers, body, delay_ms: 0, fault: None, }
}

///|
/// The response of `mock` when no Stub matches.
fn no_match(mock : @definitions.Mock) -> ResponsePlan {
  {
    status: mock.no_match_status,
    headers: [("Content-Type", "application/json")],
    body: Bytes(b"{\"error\":\"no Stub matched\"}"),
    delay_ms: 0,
    fault: None,
  }
}

///|
/// The response to a request whose Host, normalised as `host`, no Mock
/// lists, when there is no Default Mock: 404 with the Hosts the Mocks
/// declare, `hosts`, normalised.
fn no_mock(host : String?, hosts : Array[String]) -> ResponsePlan {
  let body : Json = {
    "error": "no Mock for this Host",
    "host": host.map_or(Json::null(), host => Json::string(host)),
    "acceptedHosts": Json::array(hosts.map(host => Json::string(host))),
  }
  {
    status: 404,
    headers: [("Content-Type", "application/json")],
    body: Bytes(@utf8.encode(body.stringify())),
    delay_ms: 0,
    fault: None,
  }
}

///|
/// `name` as it can be written in a header value, ASCII only: the
/// characters of an HTTP token stay as they are, except `%`, and every
/// other byte of its UTF-8 encoding is percent-encoded. A Mock name can be
/// any text, so this keeps a name such as `a\r\nb` or `a; via=x` from
/// changing the response or the header's meaning.
fn header_safe(name : String) -> String {
  let out = StringBuilder()
  for byte in @utf8.encode(name) {
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

///|
/// The request's Host, normalised: the authority of an absolute-form
/// target, or else the `Host` header field. A request has none without
/// either, or when it is empty.
fn host_of(request : Request) -> String? {
  let raw = match authority_of(request.target) {
    Some(authority) => authority
    None =>
      match request.headers.search_by(h => h.0.to_lower() == "host") {
        Some(i) => request.headers[i].1
        None => ""
      }
  }
  match @definitions.normalize_host(raw) {
    "" => None
    host => Some(host)
  }
}

///|
/// The authority of an absolute-form request target, such as
/// `users.example.com:8080` in `http://users.example.com:8080/users/1`,
/// without any user information. Other targets have none.
fn authority_of(target : String) -> String? {
  guard scheme_end(target) is Some(end) else { return None }
  let rest = target[end + 3:]
  let authority = match rest.find_by(c => c is ('/' | '?' | '#')) {
    Some(i) => rest[:i]
    None => rest
  }
  let authority = match authority.rev_find("@") {
    Some(i) => authority[i + 1:]
    None => authority
  }
  Some(authority.to_owned())
}

///|
/// Where the scheme of an absolute-form target ends: the index of its
/// `://`.
fn scheme_end(target : String) -> Int? {
  guard target.find("://") is Some(end) && end > 0 else { return None }
  for i, c in target[:end] {
    let ok = (c >= 'a' && c <= 'z') ||
      (c >= 'A' && c <= 'Z') ||
      (i > 0 && ((c >= '0' && c <= '9') || c is ('+' | '-' | '.')))
    if !ok {
      return None
    }
  }
  Some(end)
}

///|
/// The path of a request target: everything before the query, after the
/// scheme and authority of an absolute-form target, where an empty path is
/// `/`.
fn path_of(target : String) -> String {
  let target = match scheme_end(target) {
    Some(end) => {
      let rest = target[end + 3:]
      match rest.find_by(c => c is ('/' | '?' | '#')) {
        Some(i) => rest[i:]
        None => ""
      }
    }
    None => target[:]
  }
  let path = match target.find("?") {
    Some(i) => target[:i]
    None => target
  }
  if path == "" {
    "/"
  } else {
    path.to_owned()
  }
}
