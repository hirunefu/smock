///|
/// The engine decides the response to each request from the current
/// snapshot. It does no I/O: the caller gives it the request, the Session
/// key, the time and a random source, and carries out the plan it returns.
pub struct Engine {
  /// The snapshot served. A reload replaces it whole, between two calls.
  priv mut snapshot : @definitions.Snapshot
  /// The generators of the Stubs of the snapshot that have a seed, by Stub
  /// ID. A reload that swaps the snapshot creates them anew.
  priv mut generators : Map[String, @prng.Generator]
  /// Whether Stubs are found through the snapshot's match index, rather
  /// than by trying every Stub of the Mock in matching order.
  priv match_index : Bool
  /// The result of the last reload, if there was one.
  priv mut last_reload : ReloadResult?
  /// The Ephemeral Stubs, by Mock and Session.
  priv ephemeral : EphemeralStubs
  /// The Journal: the entries committed, oldest first, within its bound.
  priv journal : Journal
}

///|
/// A request as the engine sees it, whatever protocol carried it.
pub(all) struct Request {
  meth : String
  /// The request target as sent, such as `/users/1?x=y`.
  target : String
  /// The protocol version, as the Journal records it, such as `HTTP/1.1`.
  version : String
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
  /// The Journal entry for the request, uncommitted: the caller commits it.
  /// There is none when the Journal is off, globally or for the Mock that
  /// answered.
  journal : JournalEntry?
  /// The Near miss, when no Stub matched.
  near_miss : NearMiss?
  /// The Stub that matched, if any, and where it comes from.
  matched : MatchedStub?
} derive(Debug)

///|
/// The Stub that matched a request, by its ID, and where it comes from. A
/// Stub from a Definition file may have an ID that looks like one smock
/// assigns, so only this tells the two apart.
pub(all) enum MatchedStub {
  /// A Stub from a Definition file.
  FromFile(String)
  /// An Ephemeral Stub, added through the Admin API.
  Ephemeral(String)
} derive(Debug, Eq)

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
  fault : @definitions.ConnectionKind?
} derive(Debug)

///|
/// A response body: bytes sent at once, or a stream of Server-Sent Events,
/// each written after waiting its `delay_ms` milliseconds.
pub(all) enum Body {
  Bytes(Bytes)
  Events(ReadOnlyArray[@definitions.SseEvent])
} derive(Debug)

///|
/// Creates an engine that serves `snapshot`. Each Stub with a seed gets its
/// own generator, created from its seed.
///
/// With `match_index=false`, the engine tries every Stub of the Mock in
/// matching order instead of finding them through the snapshot's match
/// index. The outcome is the same either way, only slower; tests use it as
/// the oracle the index is checked against.
///
/// `journal` bounds the Journal and says whether it is on.
pub fn Engine::Engine(
  snapshot : @definitions.Snapshot,
  match_index? : Bool = true,
  journal? : JournalSettings = JournalSettings(),
) -> Engine {
  {
    snapshot,
    generators: seeded_generators(snapshot),
    match_index,
    last_reload: None,
    ephemeral: EphemeralStubs::new(),
    journal: Journal::new(journal),
  }
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
/// The name of the Mock whose Hosts include `host`, compared as Host
/// resolution compares Hosts: case-insensitively, without a port and
/// without a trailing dot. `None` when no Mock lists it, even when there is
/// a Default Mock. It answers from the snapshot served, so it follows each
/// reload; the TLS port asks it which Mock an SNI name belongs to.
pub fn Engine::mock_for_host(self : Engine, host : String) -> String? {
  self.snapshot
  .mock_for_host(@definitions.normalize_host(host))
  .map(mock => mock.name)
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
/// Every way a reload can end.
pub fn ReloadOutcome::all() -> Array[ReloadOutcome] {
  [Swapped, Unchanged, Failed]
}

///|
/// The outcome's name, as the Admin API, the logs and the reload metric
/// give it: `swapped`, `unchanged` or `failed`.
pub fn ReloadOutcome::name(self : ReloadOutcome) -> String {
  match self {
    Swapped => "swapped"
    Unchanged => "unchanged"
    Failed => "failed"
  }
}

///|
/// Reloads the definitions from `set`, read with the problems
/// `read_problems`, at the time `at` (milliseconds since the Unix epoch).
/// Every file is validated and a whole new snapshot is built:
///
/// - When it is valid and its digest differs from the served one, it
///   replaces the served snapshot at once, and each Stub with a seed gets a
///   new generator, created from its seed. Plans the engine returned before
///   stay as they were: they hold their own bytes. Ephemeral Stubs stay,
///   generators included, except those of a Mock the new set does not
///   declare, which are dropped.
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
      self.generators = seeded_generators(snapshot)
      // Ephemeral Stubs stay, except those of the Mocks that are gone.
      let mocks = Set::from_iter(snapshot.mocks.iter().map(mock => mock.name))
      self.ephemeral.remove_where((mock, _) => !mocks.contains(mock)) |> ignore
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
/// - `rand` is the process generator. Fault decisions for Stubs without a
///   seed draw from it.
pub fn Engine::handle(
  self : Engine,
  request : Request,
  session~ : String?,
  now~ : Int64,
  rand~ : @prng.Generator,
) -> Outcome {
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
  // The Ephemeral Stubs of the Mock and the Session come first, in their
  // own order, then the Stubs from Definition files. The match index only
  // narrows the search among the latter. The Near miss of a request that
  // matched nothing is chosen among every candidate, in that order.
  let ephemeral = mock.bind(mock => self.ephemeral.of(mock.name, session))
  let matched_ephemeral = ephemeral.bind(list => {
    list.iter().find_first(e => incoming.meets(e.stub.request))
  })
  let matched : Match? = match (mock, matched_ephemeral) {
    (_, Some(e)) =>
      Some({ stub: e.stub, generator: e.generator, source: Ephemeral(e.id), })
    (Some(mock), None) => {
      let candidates = if self.match_index {
        mock.candidates(request.meth, incoming.path)
      } else {
        mock.stubs.iter()
      }
      candidates
      .find_first(stub => incoming.meets(stub.request))
      .map(stub => {
        stub,
        generator: self.generators.get(stub.id),
        source: FromFile(stub.id),
      })
    }
    (None, None) => None
  }
  let (plan, near_miss) : (ResponsePlan, NearMiss?) = match (mock, matched) {
    (None, _) => (no_mock(host, self.snapshot.hosts()), None)
    (Some(_), Some({ stub, generator, .. })) => {
      let (delay_ms, fault) = decide_faults(stub, generator.unwrap_or(rand))
      ({ ..stub_response(stub.response), delay_ms, fault, }, None)
    }
    (Some(mock), None) => {
      // Only now, when every candidate has failed, are conditions counted.
      let ephemeral = match ephemeral {
        Some(list) => list.iter().map(e => e.stub)
        None => Iter::empty()
      }
      let near_miss = incoming.near_miss(ephemeral.concat(mock.stubs.iter()))
      (no_match(mock, near_miss), near_miss)
    }
  }
  // A mistyped Host must not silently succeed.
  if resolution is ViaDefault(name) {
    plan.headers.push(("Smock-Mock", "\{header_safe(name)}; via=default"))
  }
  let stub = matched.map(matched => matched.stub.id)
  let journal = if self.journal.records(mock) {
    Some(
      self.journal.entry(
        request,
        session~,
        host~,
        resolution~,
        stub~,
        near_miss~,
        plan~,
        digest=self.snapshot.digest,
        now~,
      ),
    )
  } else {
    None
  }
  {
    resolution,
    plan,
    journal,
    near_miss,
    matched: matched.map(matched => matched.source),
  }
}

///|
/// The Stub that matched a request, with the generator its Fault decisions
/// draw from when it has a seed, and where it comes from.
priv struct Match {
  stub : @definitions.Stub
  /// Its own generator, when it has a seed.
  generator : @prng.Generator?
  source : MatchedStub
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
      Events(events)
    }
  }
  headers.push_iter(response.headers.iter())
  { status: response.status, headers, body, delay_ms: 0, fault: None, }
}

///|
/// The response of `mock` when no Stub matches, with the Near miss, if
/// any, in the `Smock-Near-Miss` header.
fn no_match(mock : @definitions.Mock, near_miss : NearMiss?) -> ResponsePlan {
  let headers = [("Content-Type", "application/json")]
  if near_miss is Some(near_miss) {
    headers.push(("Smock-Near-Miss", near_miss.header_value()))
  }
  {
    status: mock.no_match_status,
    headers,
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
/// `text` as it can be written in a header value, ASCII only: the
/// characters of an HTTP token stay as they are, except `%`, and every
/// other byte of its UTF-8 encoding is percent-encoded. A name, such as a
/// Mock name, can be any text, so this keeps a name such as `a\r\nb` or
/// `a; via=x` from changing the response or the header's meaning.
pub fn header_safe(text : String) -> String {
  if @http1.is_token(text) && !text.contains_char('%') {
    return text
  }
  let out = StringBuilder()
  for byte in @utf8.encode(text) {
    let c = byte.to_int().unsafe_to_char()
    if c != '%' && @http1.is_token(c.to_string()) {
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
