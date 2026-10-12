///|
/// The engine decides the response to each request from the current
/// snapshot. It does no I/O: the caller gives it the request, the Session
/// key, the time and a random source, and carries out the plan it returns.
pub struct Engine {
  priv snapshot : @definitions.Snapshot
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
  /// The response to send.
  plan : ResponsePlan
  /// The Journal entry for the request. The caller commits it.
  journal : JournalEntry
  /// The Near miss, when no Stub matched.
  near_miss : NearMiss?
} derive(Debug)

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
  { snapshot, }
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
  ignore(rand)
  let mock = self.snapshot.default_mock()
  let path = path_of(request.target)
  let matched = match mock {
    Some(mock) =>
      mock.stubs.iter().find_first(stub => matches(stub, request, path))
    None => None
  }
  let plan : ResponsePlan = match matched {
    Some(stub) =>
      {
        status: stub.response.status,
        headers: stub.response.headers.iter().collect(),
        body: Bytes(stub.response.body),
        delay_ms: 0,
        fault: None,
      }
    None =>
      { status: 404, headers: [], body: Bytes(b""), delay_ms: 0, fault: None, }
  }
  {
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
/// Whether `request`, whose path is `path`, meets every condition of `stub`.
fn matches(stub : @definitions.Stub, request : Request, path : String) -> Bool {
  let conditions = stub.request
  conditions.meth.map_or(true, meth => meth == request.meth) &&
  conditions.path.map_or(true, expected => expected == path)
}

///|
/// The path of a request target: everything before the query.
fn path_of(target : String) -> String {
  match target.find("?") {
    Some(i) => target[:i].to_owned()
    None => target
  }
}
