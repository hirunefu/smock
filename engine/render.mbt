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
  /// The Variables that templates read as `vars.NAME`, by name: those the
  /// request finds before the Stub writes its own. A rendering reads
  /// these, never the live Variables.
  vars : Map[String, Json]
  /// The values of Data buckets of the Stub's Mock that templates read as
  /// `data.NAME`, by the bucket's name, in place of their initial values:
  /// the data the request finds before the Stub writes. A rendering reads
  /// these, never a Session's copies.
  data : Map[String, Json]
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
/// the path to `/`, the body to empty, and there is no Session, no
/// Variable and no data by default. Query parameters and header fields map
/// a name to a value, or to the values of a repeated one, in order, `vars`
/// the name of each Variable to its value, and `data` the name of each
/// Data bucket to its value. Whether the Stub's Mock declares those buckets
/// is for the rendering to check.
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
  let mut vars = Map([])
  let mut data = Map([])
  for name, value in members {
    let at = @definitions.child_pointer("", name)
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
      "vars" => vars = sample_vars(value, at)
      "data" =>
        match value {
          Object(buckets) => data = buckets
          _ => raise InvalidSample(pointer=at, message="must be an object")
        }
      _ => raise InvalidSample(pointer=at, message="is not a known field")
    }
  }
  { meth, path, query, headers, body, session, vars, data, }
}

///|
/// The Variables of a `vars` member at `at`: an object that maps the name
/// of each Variable to its value, any JSON.
fn sample_vars(
  json : Json,
  at : String,
) -> Map[String, Json] raise InvalidSample {
  guard json is Object(members) else {
    raise InvalidSample(pointer=at, message="must be an object")
  }
  for name, _ in members {
    if !@definitions.is_variable_name(name) {
      raise InvalidSample(
        pointer=@definitions.child_pointer(at, name),
        message="is not a Variable name: 1 to \{@definitions.max_variable_name} ASCII letters, digits, _ and -",
      )
    }
  }
  members
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
    let at = @definitions.child_pointer(at, name)
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
    version: "HTTP/1.1",
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
  /// The time the sample was received at, in milliseconds since the Unix
  /// epoch.
  time : Int64
  /// The seed the rendering used: the one given, or else the Stub's
  /// `fault.seed`, or else a fresh one. Given again, it repeats the
  /// rendering.
  seed : UInt64
  /// The index of the response rendered among the Stub's `responses`,
  /// counted from 0: the one asked for, or else the one the seed picks.
  /// `None` for a Stub with `response`, and when no response was picked
  /// because the Stub's writes failed.
  response_index : Int?
  /// The values the Stub's `variables` would write, by name, in the order
  /// written: none when it has none, or when its writes failed. Rendering
  /// writes none of them.
  variables : Map[String, Json]
  /// The writes the Stub's `dataWrites` would make, in order: none when it
  /// has none, or when its writes failed. Rendering writes none of them.
  data_writes : Array[RenderedWrite]
  status : Int
  /// The header fields smock sends, in order, without those that depend on
  /// the connection, such as Content-Length.
  headers : Array[(String, String)]
  body : Body
  /// Why the Stub's template, or a value or key of its writes, could not be
  /// rendered, when it could not: the response is then the 500 a request
  /// would get.
  template_error : TemplateError?
  /// The conditions the sample fails, as in a Near miss, in the order
  /// method, path, query parameters, headers, cookies, body, form fields
  /// or XML paths. Empty when it meets them all.
  failed : Array[FailedCondition]
} derive(Debug)

///|
/// A write that a Stub's `dataWrites` would make, as a rendering shows it.
pub(all) struct RenderedWrite {
  op : @definitions.DataOp
  /// The name of the Data bucket written to.
  bucket : String
  /// The rendered key, when the write has `key`.
  key : String?
  /// The rendered value, with the new key filled in for an `append` to a
  /// keyed bucket; `None` for a `remove`, which has no value.
  value : Json?
} derive(Debug)

///|
/// The `RenderedWrite` schema of the Admin API document.
pub impl ToJson for RenderedWrite with fn to_json(self) {
  {
    "op": Json::string(self.op.name()),
    "bucket": Json::string(self.bucket),
    "key": self.key.map_or(Json::null(), key => Json::string(key)),
    "value": self.value.unwrap_or(Json::null()),
  }
}

///|
/// Why a Stub cannot be rendered.
pub suberror RenderFailure {
  /// No Stub from the Definition files has this ID.
  UnknownStub(String)
  /// The Stub `stub` has no response at `index`: it has `count`, with the
  /// indexes 0 to `count - 1`.
  UnknownResponse(stub~ : String, index~ : Int, count~ : Int)
  /// The sample's `data` gives a value for the Data bucket `bucket`, which
  /// the Stub's Mock `mock` does not declare.
  UnknownSampleBucket(mock~ : String, bucket~ : String)
  /// The sample's `data` gives a value for the Data bucket `bucket`, keyed
  /// by the member `key`, that breaks the rules of keyed buckets in each of
  /// the ways `problems` gives, with JSON Pointers into that value.
  InvalidSampleData(
    bucket~ : String,
    key~ : String,
    problems~ : Array[@definitions.KeyedProblem]
  )
  /// The Stub with this ID is a CRUD Stub, which smock does not render
  /// yet.
  CrudStub(String)
} derive(Debug)

///|
/// Why the Stub cannot be rendered, as smock render and the Admin render
/// operation say it.
pub fn RenderFailure::message(self : RenderFailure) -> String {
  match self {
    UnknownStub(id) =>
      "no Stub from the Definition files has the ID \{id.escape()}"
    UnknownResponse(stub~, index~, count~) => {
      let indexes = if count == 1 {
        "it has one response, whose index is 0"
      } else {
        "its responses run from 0 to \{count - 1}"
      }
      "the Stub \{stub.escape()} has no response \{index}: \{indexes}"
    }
    UnknownSampleBucket(mock~, bucket~) =>
      "the sample request's data names the Data bucket \{bucket.escape()}, which the Mock \{mock.escape()} does not declare"
    InvalidSampleData(bucket~, key~, problems~) => {
      let at = @definitions.child_pointer("/data", bucket)
      let each = problems.map(problem => {
        "\{at}\{problem.pointer} \{problem.message}"
      })
      "the sample request's data breaks the rules of the Data bucket \{bucket.escape()}, keyed by \{key.escape()}: \{each.join("; ")}"
    }
    CrudStub(id) =>
      "the Stub \{id.escape()} is a CRUD Stub, and smock cannot render CRUD Stubs yet"
  }
}

///|
/// Renders the response of the Stub with the ID `id`, a Stub from the
/// Definition files, for the sample request `sample`. The Stub is rendered
/// even when the sample fails its conditions; the rendering lists those it
/// fails, with what each expects and what the sample carries.
///
/// - `now` is the time the sample is received at, in milliseconds since the
///   Unix epoch.
/// - `seed` seeds the random source of the rendering: the output a matched
///   request takes from its Stub's source is the first output of a
///   generator seeded with it. So the rendering shows what the first
///   matched request of a Stub with `fault.seed` set to `seed` gets.
///   Without it, the rendering uses the Stub's `fault.seed`, or, when it
///   has none, `fresh_seed()`.
/// - `response_index` is the index of the response to render, counted from
///   0. Without it, the rendering shows the one the seed picks. A Stub with
///   `response` takes 0 only.
///
/// The values of the Stub's `variables`, then the keys and values of its
/// `dataWrites`, are rendered against the sample's `vars` and `data`, and
/// the writes are applied to the sample's data. The response reads the
/// sample's `vars` with the Stub's values written over them, and the
/// sample's data after the writes, as the response to a request sees its
/// writes. A Data bucket that the sample's `data` does not name has its
/// initial value; a Session's copy is never read, also when the sample
/// names a Session. A value or a key that fails to render, or a write that
/// cannot be applied to the sample's data, gives the 500 a request would
/// get, shows no write, and picks no response. No bound on per-Session
/// state applies. A response that serves byte ranges answers the sample's
/// `Range` field, as it answers a request's: with 206, 416 or the whole
/// body.
///
/// Raises `UnknownSampleBucket` or `InvalidSampleData` when the sample's
/// `data` names a bucket that the Stub's Mock does not declare, or gives a
/// keyed bucket a value that breaks its rules.
///
/// Rendering decides no Fault, and changes nothing in the engine or in the
/// sample: no generator advances, and no Variable or copy of a Data bucket
/// is written or read.
///
/// A CRUD Stub cannot be rendered yet: it raises `CrudStub`.
pub fn Engine::render(
  self : Engine,
  id : String,
  sample : SampleRequest,
  now~ : Int64,
  seed? : UInt64,
  response_index? : Int,
  fresh_seed~ : () -> UInt64,
) -> Rendering raise RenderFailure {
  guard self.file_stub(id) is Some((stub, mock)) else { raise UnknownStub(id) }
  check_sample_data(sample.data, mock)
  match stub.serves {
    Ordinary(ordinary) => {
      let count = ordinary.responses.length()
      if response_index is Some(index) && (index < 0 || index >= count) {
        raise UnknownResponse(stub=stub.id, index~, count~)
      }
      let seed = match (seed, stub.fault) {
        (Some(seed), _) => seed
        (None, Some({ seed: Some(seed), .. })) => seed
        (None, _) => fresh_seed()
      }
      let incoming = Incoming::new(sample.to_request())
      // The sample's data stands for the copies of a Session.
      let copies = if sample.data.is_empty() { None } else { Some(sample.data) }
      // The steps of the match decision that build the response, as for a
      // request: the one draw, the writes, the pick, then rendering and
      // planning, which answers the sample's Range field. No Scenario moves,
      // nothing is written, and no Fault is decided.
      let draw = @prng.Generator(seed).uint64()
      // The writes render against the sample's `vars` and data, drawing from
      // the helper generator first, and apply to the sample's data; the
      // response renders on from there, and reads the state they leave.
      let mut variables = Map([])
      let mut data_writes = []
      let mut context = None
      let mut failed = None
      if ordinary.writes_variables() || ordinary.writes_data() {
        let first = first_context(
          incoming,
          now~,
          draw~,
          vars=Some(sample.vars),
          data=mock.initial_data,
          copies~,
        )
        try
          preview_writes(
            ordinary,
            mock.buckets,
            first,
            sample.vars,
            sample.data,
          )
        catch {
          ValueFailed(error) =>
            failed = Some((template_failed(stub.id, error), Some(error)))
          ApplyFailed(error) =>
            failed = Some((data_write_failed(stub.id, error), None))
          // Never raised: a rendering applies no bound.
          StateLimitReached(message) =>
            failed = Some((state_limit_reached(stub.id, message), None))
        } noraise {
          preview => {
            variables = preview.variables
            data_writes = preview.writes
            context = Some(preview.context)
          }
        }
      }
      let (response_index, plan, template_error) = match failed {
        // Writes that failed pick no response, whichever was asked for.
        Some((plan, error)) => (None, plan, error)
        None => {
          let response_index = match (response_index, ordinary.total_weight) {
            // A Stub with `response` shows no index, whichever it was asked
            // for.
            (_, None) => None
            (Some(index), Some(_)) => Some(index)
            (None, Some(_)) => pick_response(ordinary, draw)
          }
          let response = ordinary.responses[response_index.unwrap_or(0)].response
          try
            plan_response(
              response,
              incoming,
              context,
              now~,
              draw~,
              vars=Some(sample.vars),
              data=mock.initial_data,
              copies~,
            )
          catch {
            RenderError(at~, message~) => {
              let error = TemplateError::{ at, message, }
              (response_index, template_failed(stub.id, error), Some(error))
            }
          } noraise {
            plan => (response_index, plan, None)
          }
        }
      }
      {
        stub: stub.id,
        mock: stub.mock,
        time: now,
        seed,
        response_index,
        variables,
        data_writes,
        status: plan.status,
        headers: plan.headers,
        body: plan.body,
        template_error,
        failed: incoming
        .failed(ordinary.request)
        .map(failed => incoming.explain(failed)),
      }
    }
    Crud(_) => raise CrudStub(stub.id)
  }
}

///|
/// What a Stub's writes would leave, as a rendering shows them: the values
/// of its `variables`, the writes of its `dataWrites`, and the rendering
/// the response continues with.
priv struct Preview {
  variables : Map[String, Json]
  writes : Array[RenderedWrite]
  context : @template.Context
}

///|
/// The writes of `ordinary`, a Stub that writes Variables or Data buckets,
/// whose Mock declares the buckets `buckets`, as a rendering for a sample
/// request with the Variables `vars` and the data `data` shows them. The
/// values and keys render as at the match decision, from `first`, the
/// first rendering for the sample; the writes apply in order to the
/// sample's data, or else to a bucket's initial value, with new `uuid` keys
/// drawn from the helper generator then. No bound applies, and nothing is
/// written: neither `vars` nor `data` changes.
///
/// Returns the values and the writes, with the rendering the response
/// continues with, which reads `vars` with the values written over them and
/// the data after the writes. Raises `ValueFailed` when a value or a key
/// fails to render, and `ApplyFailed` when a write cannot be applied.
fn preview_writes(
  ordinary : @definitions.Ordinary,
  buckets : ReadOnlyArray[@definitions.DataBucket],
  first : @template.Context,
  vars : Map[String, Json],
  data : Map[String, Json],
) -> Preview raise WriteFailure {
  let writes = ordinary.data_writes
  let values = Array(capacity=ordinary.variables.values.length())
  let keys = Array(capacity=writes.length())
  let write_values = Array(capacity=writes.length())
  let last = render_writes(
    ordinary,
    first,
    Some(vars),
    values,
    keys,
    write_values,
  ) catch {
    RenderError(at~, message~) => raise ValueFailed({ at, message, })
  }
  // The sample's data stands for the Session's copies. Writes change those
  // in place, so they change copies of them, and the sample stays as it is.
  let copies = Map([])
  for name, value in data {
    copies[name] = deep_copy(value)
  }
  let working = WorkingCopies::new(Some({ values: copies, bytes: Map([]), }))
  let rand = last.generator()
  let shown = []
  for i in 0..<writes.length() {
    let write = writes[i]
    let value = write_values[i]
    // Each value is shown as it rendered, before later writes can change
    // it in place. Only an `append` is shown after it applies, with the new
    // key it got; a `set` with a key is shown without the key it gets.
    let rendered = match write.op {
      Append | Remove => None
      Replace | Merge => Some(deep_copy(value))
    }
    working.apply(i, write, keys[i], value, buckets, rand)
    shown.push({
      op: write.op,
      bucket: write.bucket,
      key: keys[i],
      value: match write.op {
        Append => Some(deep_copy(value))
        Remove => None
        Replace | Merge => rendered
      },
    })
  }
  for i in 0..<working.names.length() {
    copies[working.names[i]] = working.values[i]
  }
  let variables = Map([])
  let after = vars.copy()
  for i, name in ordinary.variables.names {
    variables[name] = values[i]
    after[name] = values[i]
  }
  {
    variables,
    writes: shown,
    context: if writes.length() == 0 {
      last.next(vars=after)
    } else {
      last.next(vars=after, copies~)
    },
  }
}

///|
/// Checks `data`, the data of a sample request, against the Data buckets of
/// `mock`, the Mock of the Stub to render: each must be a bucket it
/// declares, and the value of a keyed bucket must keep the rules of keyed
/// buckets. Raises `UnknownSampleBucket` or `InvalidSampleData` for the
/// first that does not.
fn check_sample_data(
  data : Map[String, Json],
  mock : @definitions.Mock,
) -> Unit raise RenderFailure {
  for name, value in data {
    guard bucket_named(mock, name) is Some(bucket) else {
      raise UnknownSampleBucket(mock=mock.name, bucket=name)
    }
    if bucket.key is Some(key) {
      let problems = @definitions.keyed_problems(value, key~)
      if !problems.is_empty() {
        raise InvalidSampleData(bucket=name, key~, problems~)
      }
    }
  }
}

///|
/// The Stub from the Definition files with the ID `id`, if any, with its
/// Mock.
fn Engine::file_stub(
  self : Engine,
  id : String,
) -> (@definitions.Stub, @definitions.Mock)? {
  for mock in self.snapshot.mocks {
    for stub in mock.stubs {
      if stub.id == id {
        return Some((stub, mock))
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
    Events(events) =>
      (Json::null(), Json::array(events.iter().map(event_json).collect()))
  }
  {
    "stub": Json::string(self.stub),
    "mock": Json::string(self.mock),
    "time": Json::string(@log.format_time(self.time)),
    "seed": Json::number(self.seed.to_double()),
    "responseIndex": self.response_index.map_or(Json::null(), index => {
      Json::number(index.to_double())
    }),
    "variables": Json::object(self.variables),
    "dataWrites": Json::array(
      self.data_writes.map(write => ToJson::to_json(write)),
    ),
    "response": {
      "status": Json::number(self.status.to_double()),
      "headers": Json::array(
        self.headers.map(header => {
          "name": Json::string(header.0),
          "value": Json::string(header.1),
        }),
      ),
      "body": body,
      "events": events,
    },
    "templateError": self.template_error.map_or(Json::null(), error => {
      ToJson::to_json(error)
    }),
    "failed": Json::array(self.failed.map(failed => ToJson::to_json(failed))),
  }
}

///|
/// The `Body` schema of the Admin API document: the bytes as text when they
/// are UTF-8, otherwise in base64. `bytes` are the first bytes of a body of
/// `size` bytes, by default all of them.
fn body_json(bytes : BytesView, size? : Int = bytes.length()) -> Json {
  let (encoding, data) = try @utf8.decode(bytes) catch {
    _ => ("base64", @base64.encode(bytes))
  } noraise {
    text => ("utf-8", text)
  }
  {
    "encoding": Json::string(encoding),
    "data": Json::string(data),
    "size": Json::number(size.to_double()),
    "truncated": Json::boolean(bytes.length() < size),
  }
}

///|
/// A Server-Sent Event as Definition files write it: its delay, its type
/// and ID when it has them, and its data.
fn event_json(event : @definitions.SseEvent) -> Json {
  let out : Map[String, Json] = {
    "delay": Json::number(event.delay_ms.to_double()),
  }
  if event.event is Some(event) {
    out["event"] = Json::string(event)
  }
  if event.id is Some(id) {
    out["id"] = Json::string(id)
  }
  out["data"] = Json::string(event.data)
  Json::object(out)
}
