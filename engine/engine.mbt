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
  /// The state of each Scenario, by Mock and Session.
  priv scenarios : ScenarioStates
  /// The per-Session store: the Variables and the copies of Data buckets,
  /// by Mock and Session.
  priv store : SessionStore
  /// The bound on per-Session state: the count of what the Variables and
  /// the copies take, which `store` keeps up to date, and the writes it
  /// refused.
  priv state : StateBound
  /// The Journal: the entries committed, oldest first, within its bound.
  priv journal : Journal
  /// The environment variables templates may read, with the values read
  /// at startup: every reload and Ephemeral Stub is read with them.
  priv env : @template.Env
}

///|
/// A request as the engine sees it, whatever protocol carried it.
#derive(Debug)
pub(all) struct Request {
  meth : String
  /// The request target as sent, such as `/users/1?x=y`.
  target : String
  /// The protocol version, as the Journal records it, such as `HTTP/1.1`.
  version : String
  /// The header fields in the order they were sent.
  headers : Array[(String, String)]
  body : Bytes
}

///|
/// The marker of a request that is a gRPC call, which `handle` takes beside
/// the request. The request is the call as the engine sees it: the method
/// `POST`, the target its `:path`, the metadata as headers, and the message
/// decoded into JSON as the body.
#derive(Debug)
pub(all) struct GrpcCall {
  /// The path that names the method called, such as
  /// `/helloworld.Greeter/SayHello`: the exact path of the gRPC Stubs on
  /// the method.
  path : String
  /// The count of octets the call's DATA frames brought: the size of the
  /// body as received, which the Journal entry records.
  octets : Int32
}

///|
/// What the engine decided for one request.
#derive(Debug)
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
  /// How the request moved a Scenario of the Mock that answered: the
  /// clause of the Stub that matched, with the state before and after.
  /// There is none when no Stub matched, or when the Stub has no clause.
  scenario : ScenarioMove?
  /// Why the Stub that matched could not serve its own content, when it
  /// could not: the response is then the 500 `template failed` or
  /// `data write failed`. There is none for a request answered as planned,
  /// so that it pays nothing for it.
  content_error : ContentError?
}

///|
/// Why the Stub that matched a request could not serve its own content,
/// with the Stub, as the Mockoon-equivalent error line names it.
#derive(Debug)
pub(all) struct ContentError {
  /// The ID of the Stub that matched.
  stub : String
  /// The path of the Stub as written: its exact path, the text of its path
  /// pattern, or a CRUD Stub's list path. There is none for a Stub with no
  /// path condition.
  path : String?
  /// What failed. The Journal entry, when there is one, holds the same.
  failure : ContentFailure
}

///|
/// What kept the Stub that matched a request from serving its content.
#derive(Debug)
pub(all) enum ContentFailure {
  /// A template could not be rendered, a value of the Stub's `variables` or
  /// `dataWrites` included: the response is the 500 `template failed`.
  Template(TemplateError)
  /// A write of the Stub's `dataWrites` could not be applied: the response
  /// is the 500 `data write failed`.
  Data(DataError)
}

///|
/// The message of `failure`, as the 500's body gives it.
pub fn ContentFailure::message(self : ContentFailure) -> String {
  match self {
    Template(error) => error.message
    Data(error) => error.message
  }
}

///|
/// The content error of `stub`, which failed with `failure`.
fn ContentError::new(
  stub : @definitions.Stub,
  failure : ContentFailure,
) -> ContentError {
  { stub: stub.id, path: written_path(stub), failure, }
}

///|
/// The Stub that matched a request, by its ID, and where it comes from. A
/// Stub from a Definition file may have an ID that looks like one smock
/// assigns, so only this tells the two apart.
#derive(Debug, Eq)
pub(all) enum MatchedStub {
  /// A Stub from a Definition file.
  FromFile(String)
  /// An Ephemeral Stub, added through the Admin API.
  Ephemeral(String)
}

///|
/// Where the Stub comes from.
pub fn MatchedStub::source(self : MatchedStub) -> StubSource {
  match self {
    FromFile(_) => File
    Ephemeral(_) => Ephemeral
  }
}

///|
/// Where a Stub comes from: a Definition file, or the Admin API as an
/// Ephemeral Stub. The Journal and the Near miss record it, since a Stub
/// from a Definition file may have an ID that looks like one smock assigns.
#derive(Debug, Eq)
pub(all) enum StubSource {
  File
  Ephemeral
}

///|
/// The source's name, as the Admin API gives it: `file` or `ephemeral`.
pub fn StubSource::name(self : StubSource) -> String {
  match self {
    File => "file"
    Ephemeral => "ephemeral"
  }
}

///|
/// Which Mock answered a request, and how the engine chose it.
#derive(Debug, Eq)
pub(all) enum Resolution {
  /// The Mock whose Hosts include the request's Host.
  ByHost(String)
  /// The Default Mock, because no Mock lists the request's Host.
  ViaDefault(String)
  /// None: no Mock lists the request's Host and there is no Default Mock.
  NoMock
}

///|
/// The response to send, and how to send it.
#derive(Debug)
pub(all) struct ResponsePlan {
  status : Int32
  headers : Array[(String, String)]
  body : Body
  /// How long to wait, in milliseconds, before writing the status line.
  delay_ms : Int32
  /// A connection Fault to inject instead of a normal response.
  fault : @definitions.ConnectionKind?
  /// The gRPC part of the plan of a gRPC call: how its answer ends, a gRPC
  /// Stub's reply or the UNIMPLEMENTED of a call that no Stub matched. The
  /// server sends the reply's message only when its status is `OK`. `None`
  /// for an HTTP request, and for smock's own answers to a gRPC Stub that
  /// could not serve its content.
  grpc : GrpcPart?
}

///|
/// The gRPC part of a plan: what a gRPC call's reply carries beside its
/// message, which is the plan's body.
#derive(Debug)
pub(all) struct GrpcPart {
  /// The gRPC status the reply ends with.
  status : @grpc.Status
  /// The text of its `grpc-message`, if it has one.
  message : String?
  /// Its trailing metadata, after the status and the message, such as the
  /// `smock-near-miss` field of a call that no Stub matched.
  trailers : ReadOnlyArray[(String, String)]
}

///|
/// The gRPC part of every reply that a gRPC Stub serves: the status `OK`,
/// with no message and no trailing metadata.
let grpc_ok : GrpcPart = { status: Ok, message: None, trailers: [], }

///|
/// A response body: bytes sent at once, or a stream of Server-Sent Events,
/// each written after waiting its `delay_ms` milliseconds. The bytes may be
/// a view of a body file's bytes, such as the byte range a 206 sends.
#derive(Debug)
pub(all) enum Body {
  Bytes(BytesView)
  Events(ReadOnlyArray[@definitions.SseEvent])
}

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
///
/// `env` holds the environment variables templates may read, with the
/// values `snapshot` was loaded with: by default, none. Each reload and
/// each Ephemeral Stub is read with them, so they are read only once.
///
/// `state_max_bytes` bounds the per-Session state of the whole process, as
/// it counts it: by default, `default_state_max_bytes` (64 MiB).
pub fn Engine::Engine(
  snapshot : @definitions.Snapshot,
  match_index~ : Bool = true,
  journal~ : JournalSettings = JournalSettings(),
  env~ : @template.Env = @template.no_env,
  state_max_bytes~ : Int32 = default_state_max_bytes,
) -> Engine {
  let state = StateBound::new(state_max_bytes)
  {
    snapshot,
    generators: seeded_generators(snapshot),
    match_index,
    last_reload: None,
    ephemeral: EphemeralStubs::new(),
    scenarios: ScenarioStates::new(),
    store: SessionStore::new(state),
    state,
    journal: Journal::new(journal),
    env,
  }
}

///|
/// The engine's side of the Admin API status: what it serves.
#derive(Debug)
pub(all) struct Status {
  /// The Mocks, in declaration order.
  mocks : Array[MockStatus]
  /// The definition set digest of the definition set served.
  digest : String
  /// The result of the last reload, or `None` before the first one.
  last_reload : ReloadResult?
}

///|
/// A Mock as the Admin API status shows it.
#derive(Debug)
pub(all) struct MockStatus {
  name : String
  /// The Hosts the Mock answers to, as declared.
  hosts : Array[String]
  /// Whether the Mock is the Default Mock.
  is_default : Bool
}

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
/// The names of the Mocks served, in the order the status lists them,
/// without the rest of the status.
pub fn Engine::mock_names(self : Engine) -> Array[String] {
  let names = []
  for mock in self.snapshot.mocks {
    names.push(mock.name)
  }
  names
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
/// The Mock that answers a gRPC call to `request`, from the snapshot
/// served, chosen as `handle` chooses it: the Mock whose Hosts include the
/// request's Host, given by `authority` when given, else the Default Mock.
/// `None` when neither answers. Its Descriptor set, if it has one, is its
/// `descriptor_set`. Unlike `mock_for_host`, it answers with the Default
/// Mock, since a call that it answers is served.
pub fn Engine::mock_for_call(
  self : Engine,
  request : Request,
  authority? : String,
) -> @definitions.Mock? {
  let found = match host_of(request, authority) {
    Some(host) => self.snapshot.mock_for_host(host)
    None => None
  }
  match found {
    Some(_) => found
    None => self.snapshot.default_mock()
  }
}

///|
/// What a reload did.
#derive(Debug)
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
  /// How many Scenario states the reload sent back to `Started`: the stored
  /// states that are no longer known states of their Mock, Session and
  /// Scenario once the new set is swapped in. The states of a Mock that is
  /// gone are dropped with it, and are not counted. It is 0 when nothing
  /// was swapped.
  scenario_states_reset : Int32
  /// How many copies of Data buckets the reload dropped, so that their
  /// buckets read their initial values again: those of a Mock that is
  /// gone, and those of a bucket that the new set no longer declares, or
  /// whose initial value or `key` it changed. It is 0 when nothing was
  /// swapped.
  data_buckets_reset : Int32
}

///|
/// How a reload ended.
#derive(Debug, Eq)
pub(all) enum ReloadOutcome {
  /// The new set was valid and is served now.
  Swapped
  /// The new set has the digest of the one served, so nothing was swapped.
  Unchanged
  /// The new set was invalid, and the one served before still is.
  Failed
}

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
/// `digest` is the set's digest when the caller has computed it already,
/// as `@definitions.load` takes it. Templates read the environment
/// variables the engine was created with. Every file is validated and a
/// whole new snapshot is built:
///
/// - When it is valid and its digest differs from the served one, it
///   replaces the served snapshot at once, and each Stub with a seed gets a
///   new generator, created from its seed. Plans the engine returned before
///   stay as they were: they hold their own bytes. Ephemeral Stubs stay,
///   generators included, except those of a Mock the new set does not
///   declare, which are dropped. Then each Scenario state stays while its
///   name is one of the known states of its Mock, Session and Scenario;
///   any other goes back to `Started`, and the states of a Mock that is
///   gone are dropped. Variables and the copies of Data buckets stay,
///   except those of a Mock that is gone, which are dropped. So are the
///   copies of a bucket that the new set no longer declares, or whose
///   initial value or `key` it changed (`bucket_changed`).
/// - When it is valid with the digest served, nothing is swapped.
/// - When it is invalid, the served snapshot stays.
///
/// Status shows the result as the last reload.
pub fn Engine::reload(
  self : Engine,
  set : @definitions.DefinitionSet,
  read_problems~ : Array[@definitions.Diagnostic] = [],
  digest? : String,
  at~ : Int64,
) -> ReloadResult {
  let old_snapshot = self.snapshot
  let old_digest = old_snapshot.digest
  let mut scenario_states_reset = 0
  let mut data_buckets_reset = 0
  let (result, errors) : (ReloadOutcome, Array[@definitions.Diagnostic]) = match
    @definitions.load(set, read_problems~, env=self.env, digest?) {
    Ok(snapshot) if snapshot.digest == old_digest => (Unchanged, [])
    Ok(snapshot) => {
      self.snapshot = snapshot
      self.generators = seeded_generators(snapshot)
      // Ephemeral Stubs stay, except those of the Mocks that are gone.
      let mocks = Map::from_iter(
        snapshot.mocks.iter().map(mock => (mock.name, mock)),
      )
      self.ephemeral.remove_where((mock, _) => !mocks.contains(mock)) |> ignore
      // Only then are Scenario states checked, since the known states
      // include those of the Ephemeral Stubs that stay.
      scenario_states_reset = self.prune_scenario_states(mocks)
      // Variables and copies stay, except those of the Mocks that are gone.
      let cleared = self.store.remove_where((mock, _) => !mocks.contains(mock))
      // Then the copies of the buckets the new set changed are dropped.
      let old_mocks = Map::from_iter(
        old_snapshot.mocks.iter().map(mock => (mock.name, mock)),
      )
      data_buckets_reset = cleared.copies +
        self.store.drop_copies_where((mock, bucket) => {
          bucket_changed(old_mocks.get(mock), mocks.get(mock), bucket)
        })
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
    scenario_states_reset,
    data_buckets_reset,
  }
  self.last_reload = Some(reload)
  reload
}

///|
/// Decides the response to `request`.
///
/// - `authority`, when given, is the request's Host, ahead of the authority
///   of an absolute-form target and of any `host` field, normalised as they
///   are; an empty one names no Host. HTTP/2 gives its `:authority` this
///   way, so that no `host` field is added to the request: the Journal
///   lists only the fields the client sent, and header conditions see only
///   a `host` field it sent. HTTP/1.1 never gives it.
/// - `grpc`, when given, marks the request as a gRPC call, made with the
///   method it names. A gRPC call is matched only against the Mock's gRPC
///   Stubs on that method, in matching order, and its Near miss is chosen
///   among every gRPC Stub of the Mock; the Ephemeral Stubs, which are
///   never gRPC Stubs, are not tried. A call that none matches is planned
///   UNIMPLEMENTED, with a fixed message that says why and its Near miss in
///   a trailer, never with the Mock's `noMatch`, and so is a call whose
///   Host reaches no Mock. Its Journal entry records the call's octets as
///   the body's size. HTTP never gives it.
/// - `session` is the request's Session key, or `None` without a Session.
/// - `now` is the time the request was received, in milliseconds since the
///   Unix epoch.
/// - `rand` is the process generator. Fault decisions for Stubs without a
///   seed draw from it.
pub fn Engine::handle(
  self : Engine,
  request : Request,
  authority? : String,
  grpc? : GrpcCall,
  session~ : String?,
  now~ : Int64,
  rand~ : @prng.Generator,
) -> Outcome {
  // Every request comes here, so it is written with plain matches and
  // loops, which allocate no closures, iterators or tuples.
  let host = host_of(request, authority)
  let by_host = match host {
    Some(host) => self.snapshot.mock_for_host(host)
    None => None
  }
  let mut resolution : Resolution = NoMock
  let mut mock : @definitions.Mock? = None
  match by_host {
    Some(found) => {
      resolution = ByHost(found.name)
      mock = Some(found)
    }
    None =>
      if self.snapshot.default_mock() is Some(found) {
        resolution = ViaDefault(found.name)
        mock = Some(found)
      }
  }
  let incoming = Incoming::new(request)
  // The Ephemeral Stubs of the Mock and the Session come first, in their
  // own order, then the Stubs from Definition files: their HTTP Stubs, as
  // the files load them, since a request never matches a gRPC Stub. The
  // match index only narrows the search among the latter. The Near miss of
  // a request that matched nothing is chosen among every candidate, in
  // that order.
  let ephemeral = match mock {
    Some(mock) if grpc is None => self.ephemeral.of(mock.name, session)
    _ => None
  }
  // A Stub with a Scenario clause matches only in the state it requires,
  // checked once its request conditions hold. The Session's states for the
  // Mock are looked up at most once, and only when a Stub has a clause.
  let mut states : Map[String, String]? = None
  let mut states_known = false
  let mut matched : Match? = None
  if ephemeral is Some(list) {
    for i in 0..<list.length() {
      let e = list[i]
      match e.stub.serves {
        Ordinary(ordinary) =>
          if incoming.meets(ordinary.request) {
            if ordinary.scenario is Some(_) && !states_known {
              states = self.scenarios.of(e.mock, session)
              states_known = true
            }
            if scenario_allows(ordinary.scenario, states) {
              matched = Some({
                stub: e.stub,
                generator: e.generator,
                source: Ephemeral(e.id),
              })
              break
            }
          }
        Crud(crud) =>
          if crud.operation(request.meth, incoming.path) is Some(_) {
            matched = Some({
              stub: e.stub,
              generator: e.generator,
              source: Ephemeral(e.id),
            })
            break
          }
      }
    }
  }
  if matched is None && mock is Some(mock) {
    // A Mock without a Stub with a clause pays only this test.
    let gated = mock.has_scenarios()
    if gated && !states_known {
      states = self.scenarios.of(mock.name, session)
      states_known = true
    }
    let current = states
    let found = if grpc is Some(call) {
      // A gRPC call is matched against the gRPC Stubs on its method alone,
      // which the snapshot lists by path, with or without the match index.
      let stubs = mock.grpc_candidates(call.path)
      let mut found = None
      for i in 0..<stubs.length() {
        if incoming.matches(stubs[i], current) {
          found = Some(stubs[i])
          break
        }
      }
      found
    } else if self.match_index {
      if gated {
        mock.first_candidate(request.meth, incoming.path, stub => {
          incoming.matches(stub, current)
        })
      } else {
        mock.first_candidate(request.meth, incoming.path, stub => {
          incoming.matches_ungated(stub)
        })
      }
    } else {
      let stubs = mock.http_stubs
      let mut found = None
      for i in 0..<stubs.length() {
        if incoming.matches(stubs[i], current) {
          found = Some(stubs[i])
          break
        }
      }
      found
    }
    if found is Some(stub) {
      matched = Some({
        stub,
        // Only Stubs with a seed have a generator of their own.
        generator: if self.generators.is_empty() {
          None
        } else {
          self.generators.get(stub.id)
        },
        source: FromFile(stub.id),
      })
    }
  }
  let mut scenario : ScenarioMove? = None
  let mut response_index = None
  let mut variables_written = none_written
  let mut data_written = no_buckets_written
  let mut crud_called = None
  let mut content_error = None
  let mut near_miss = None
  let plan : ResponsePlan = match matched {
    // The match decision: one sequence of steps, each taken in turn, which
    // depend on what the Stub serves. A step that a Stub does not use costs
    // it one test at most.
    Some({ stub, generator, .. }) => {
      guard mock is Some(mock) else {
        abort("a matched Stub has the Mock that answered")
      }
      match stub.serves {
        Ordinary(ordinary) => {
          // 1. The Scenario moves, before the response is built: whatever
          //    happens to the response, a delay, a connection Fault or a
          //    template error, the state has moved, and the next request
          //    sees it. It is the state of the Mock that answered.
          if ordinary.scenario is Some(clause) {
            if !states_known {
              states = self.scenarios.of(stub.mock, session)
            }
            let from = current_state(states, clause.name)
            let to = match clause.move_to {
              Some(to) => to
              None => from
            }
            if to != from {
              self.scenarios.set(stub.mock, session, clause.name, to)
            }
            scenario = Some({ name: clause.name, from, to, })
          }
          // 2. The one draw. Every matched request takes exactly one output
          //    from its Stub's source, whatever it then draws: the Fault
          //    decisions draw from a generator seeded with it, the pick from
          //    one of its own, and the helpers from the request's helper
          //    generator, made from it once something is rendered.
          let draw = generator.unwrap_or(rand).uint64()
          // Templates read the Data buckets of the Mock that answered: the
          // copy of each that the Session holds, or else its initial value.
          // The values of `variables` and `dataWrites` look the copies up,
          // and a response only when one of its templates reads `data`.
          let data = mock.initial_data
          // 3. The writes: each data write's bucket is checked first, as a
          //    reload may have removed or changed an Ephemeral Stub's, and
          //    this draws nothing; the value of each Variable is rendered,
          //    in the order written, then the value of each data write, all
          //    against the state from before the request, drawing from the
          //    helper generator first; the data writes are applied in
          //    order to working copies; and all is stored at once, if it
          //    fits within the bound on per-Session state. The response
          //    renders on from there, and sees the state after the writes.
          //    A value that fails to render, a data write that cannot be
          //    applied, or writes that do not fit, write nothing, and no
          //    response is picked: the request gets the template failure,
          //    the data write failure, or 507.
          let mut context : @template.Context? = None
          let mut failed : ResponsePlan? = None
          if ordinary.writes_variables() || ordinary.writes_data() {
            let first = first_context(
              incoming,
              now~,
              draw~,
              vars=self.store.variables_of(stub.mock, session),
              data~,
              copies=self.store.copy_values(stub.mock, session),
            )
            try
              self.write_state(
                stub.mock,
                mock.buckets,
                ordinary,
                session,
                first,
              )
            catch {
              ValueFailed(error) => {
                content_error = Some(ContentError::new(stub, Template(error)))
                failed = Some(template_failed(stub.id, error))
              }
              ApplyFailed(error) => {
                content_error = Some(ContentError::new(stub, Data(error)))
                failed = Some(data_write_failed(stub.id, error))
              }
              StateLimitReached(message) =>
                failed = Some(state_limit_reached(stub.id, message))
            } noraise {
              written => {
                context = Some(written.context)
                variables_written = ordinary.variables.names
                data_written = written.buckets
              }
            }
          }
          let plan = match failed {
            Some(plan) => plan
            None => {
              // 4. The pick: the response the request gets. A Stub with
              //    `response` has one, and draws nothing more.
              response_index = pick_response(ordinary, draw)
              let response = ordinary.responses[response_index.unwrap_or(0)].response
              // 5. Rendering and planning: the response as written, or
              //    rendered from its templates. One that serves byte ranges
              //    answers the request's Range field. Only a response that
              //    reads Variables, and does not continue from their values,
              //    looks them up. The reply to a gRPC call, which only a
              //    gRPC Stub matches, gets its gRPC part.
              try
                plan_response(
                  response,
                  incoming,
                  context,
                  now~,
                  draw~,
                  vars=if context is None && response.reads_variables {
                    self.store.variables_of(stub.mock, session)
                  } else {
                    None
                  },
                  data~,
                  copies=if context is None && response.reads_data {
                    self.store.copy_values(stub.mock, session)
                  } else {
                    None
                  },
                )
              catch {
                RenderError(at~, message~) => {
                  let error = TemplateError::{ at, message, }
                  content_error = Some(ContentError::new(stub, Template(error)))
                  template_failed(stub.id, error)
                }
              } noraise {
                plan =>
                  if grpc is Some(_) {
                    { ..plan, grpc: Some(grpc_ok), }
                  } else {
                    plan
                  }
              }
            }
          }
          // 6. Faults: a plan comes without a delay or a Fault, and gets the
          //    Stub's.
          with_faults(plan, stub, draw)
        }
        // A CRUD Stub has no Scenario clause. It takes its one draw, then
        // answers: a list or a read from the Session's copy of its
        // bucket, or else from the initial value; a create, replace,
        // update or delete with its one write, made here, all or nothing,
        // within the bound on per-Session state, before any delay. It
        // gets its Faults, whatever its answer, and they do not undo the
        // write.
        Crud(crud) => {
          let draw = generator.unwrap_or(rand).uint64()
          let answer = self.crud_answer(
            mock,
            stub.id,
            crud,
            incoming,
            session,
            draw,
          )
          crud_called = Some(answer.call)
          data_written = answer.written
          with_faults(answer.plan, stub, draw)
        }
      }
    }
    None =>
      match mock {
        // A gRPC call gets UNIMPLEMENTED in gRPC's form, never the 404 of
        // an HTTP request.
        None if grpc is Some(_) =>
          grpc_unimplemented("no Mock for this Host", None)
        None => no_mock(host, self.snapshot.hosts())
        Some(mock) => {
          // Only now, when every candidate has failed, are conditions
          // counted. A state that a Stub requires counts too. The states
          // are already known when the Mock's file Stubs have a clause, or
          // when an Ephemeral Stub with one met the request; otherwise they
          // are looked up only if an Ephemeral Stub has a clause.
          if !states_known && ephemeral is Some(list) {
            for i in 0..<list.length() {
              if list[i].stub.scenario() is Some(_) {
                states = self.scenarios.of(mock.name, session)
                break
              }
            }
          }
          let ephemeral = match ephemeral {
            Some(list) => list.iter().map(e => (e.stub, StubSource::Ephemeral))
            None => Iter::empty()
          }
          // A gRPC call's Near miss is chosen among every gRPC Stub of its
          // Mock, as an HTTP request's is among every HTTP Stub, so a call
          // to a method that no Stub is on has one too.
          let stubs = match grpc {
            Some(_) => mock.stubs.iter().filter(stub => stub.is_grpc())
            None => mock.http_stubs.iter()
          }
          near_miss = incoming.near_miss(
            ephemeral.concat(stubs.map(stub => (stub, StubSource::File))),
            states,
          )
          if grpc is Some(call) {
            grpc_unimplemented(unmatched_call(mock, call.path), near_miss)
          } else {
            no_match(mock, near_miss)
          }
        }
      }
  }
  // A mistyped Host must not silently succeed.
  if resolution is ViaDefault(name) {
    plan.headers.push(("Smock-Mock", "\{header_safe(name)}; via=default"))
  }
  let source = match matched {
    Some(matched) => Some(matched.source)
    None => None
  }
  let journal = if self.journal.records(mock) {
    Some(
      self.journal.entry(
        request,
        session~,
        host~,
        resolution~,
        matched=source,
        scenario~,
        response_index~,
        variables_written~,
        data_written~,
        content_error~,
        crud=crud_called,
        near_miss~,
        body_size=match grpc {
          Some(call) => call.octets
          None => request.body.length()
        },
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
    matched: source,
    scenario,
    content_error,
  }
}

///|
/// The path of `stub` as written: an ordinary Stub's exact path or the text
/// of its path pattern, or a CRUD Stub's list path. There is none for an
/// ordinary Stub with no path condition.
fn written_path(stub : @definitions.Stub) -> String? {
  match stub.serves {
    Ordinary(ordinary) =>
      match ordinary.request.path {
        Some(Has(Exact(path))) => Some(path)
        Some(Has(Pattern(pattern))) => Some(pattern.source)
        // A path condition is an exact path or a pattern, never an
        // operator.
        Some(Has(Any) | Not(_) | Exists(_)) | None => None
      }
    Crud(crud) => Some(crud.path)
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
/// Whether the request matches `stub` in the current states, `states`: it
/// meets the Stub's request conditions, and the Stub's Scenario clause, if
/// any, allows those states. A CRUD Stub matches the requests it serves, by
/// their method and path (`@definitions.Crud::operation`).
fn Incoming::matches(
  self : Incoming,
  stub : @definitions.Stub,
  states : Map[String, String]?,
) -> Bool {
  match stub.serves {
    Ordinary(ordinary) =>
      self.meets(ordinary.request) && scenario_allows(ordinary.scenario, states)
    Crud(crud) => crud.operation(self.request.meth, self.path) is Some(_)
  }
}

///|
/// Whether the request matches `stub`, a file Stub of a Mock whose file
/// Stubs have no Scenario clause: as `matches` says, without the test of
/// a clause.
fn Incoming::matches_ungated(self : Incoming, stub : @definitions.Stub) -> Bool {
  match stub.serves {
    Ordinary(ordinary) => self.meets(ordinary.request)
    Crud(crud) => crud.operation(self.request.meth, self.path) is Some(_)
  }
}

///|
/// The response of `mock` when no Stub matches: its `noMatch.headers` after
/// smock's Content-Type, and the Near miss, if any, in the
/// `Smock-Near-Miss` header.
fn no_match(mock : @definitions.Mock, near_miss : NearMiss?) -> ResponsePlan {
  let given = mock.no_match_headers
  // Room for the Near miss and the Smock-Mock field the Default Mock adds.
  let headers = Array(capacity=given.length() + 3)
  headers.push(("Content-Type", "application/json"))
  for i in 0..<given.length() {
    headers.push(given[i])
  }
  if near_miss is Some(near_miss) {
    headers.push(("Smock-Near-Miss", near_miss.header_value()))
  }
  {
    status: mock.no_match_status,
    headers,
    body: Bytes(b"{\"error\":\"no Stub matched\"}"),
    delay_ms: 0,
    fault: None,
    grpc: None,
  }
}

///|
/// The fixed message of the UNIMPLEMENTED answer to a gRPC call to `path`
/// that `mock` answers and that no gRPC Stub matched: why the call can
/// reach no gRPC Stub, when the Mock has no Descriptor set, or the set no
/// method at `path`, or the method streams, and `no Stub matched`
/// otherwise. The server answers the first three as soon as the call's
/// HEADERS arrive.
fn unmatched_call(mock : @definitions.Mock, path : String) -> String {
  guard mock.descriptor_set is Some(set) else {
    return "the Mock has no Descriptor set"
  }
  guard set.find_method(path) is Some(rpc) else { return "unknown method" }
  if rpc.client_streaming || rpc.server_streaming {
    "streaming methods are not served yet"
  } else {
    "no Stub matched"
  }
}

///|
/// The response to a gRPC call that no gRPC Stub matches: Trailers-Only
/// UNIMPLEMENTED with the fixed message `message`, such as `no Stub
/// matched`, and the Near miss, if any, in the `smock-near-miss` trailer,
/// in the form of the `Smock-Near-Miss` header. Its HTTP status is 200, as
/// gRPC sends every answer. The Mock's `noMatch` applies to HTTP requests
/// only, so neither its status nor its headers reach the call.
fn grpc_unimplemented(message : String, near_miss : NearMiss?) -> ResponsePlan {
  {
    status: 200,
    // Room for the Smock-Mock field the Default Mock adds.
    headers: Array(capacity=1),
    body: Bytes(b""),
    delay_ms: 0,
    fault: None,
    grpc: Some({
      status: Unimplemented,
      message: Some(message),
      trailers: match near_miss {
        Some(near_miss) => [("smock-near-miss", near_miss.header_value())]
        None => []
      },
    }),
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
    grpc: None,
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
/// The request's Host, normalised: `authority` when given, else the
/// authority of an absolute-form target, or else the `Host` header field.
/// A request has none without any of them, or when the one that gives it
/// is empty.
fn host_of(request : Request, authority : String?) -> String? {
  let raw = match authority {
    Some(authority) => authority
    None =>
      match authority_of(request.target) {
        Some(authority) => authority
        None => {
          let headers = request.headers
          let mut host = ""
          for i in 0..<headers.length() {
            if is_name(headers[i].0, "host") {
              host = headers[i].1
              break
            }
          }
          host
        }
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
  let parts = @log.target_parts(target)
  guard parts.authority >= 0 else { return None }
  let authority = target.exact_view(start=parts.authority, end=parts.path)
  let authority = match authority.rev_find("@") {
    Some(i) => authority[i + 1:]
    None => authority
  }
  Some(authority.to_owned())
}

///|
/// The path of a request target: everything before the query, after the
/// scheme and authority of an absolute-form target, where an empty path is
/// `/` (`@log.target_parts`).
fn path_of(target : String) -> String {
  let parts = @log.target_parts(target)
  if parts.path == parts.query {
    "/"
  } else {
    target.exact_view(start=parts.path, end=parts.query).to_owned()
  }
}
