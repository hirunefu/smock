// Variables: named JSON values, kept per Mock and per Session. A Stub's
// `variables` write them at the match decision, in `Engine::handle`, which
// is synchronous and single-threaded, so reading them and writing them
// needs no lock (ADR 0003). Templates read them as `vars.NAME`.

///|
/// The Variables of each Mock and Session: by Mock, then by Session (`None`
/// for the no-Session space), then by name. No map is empty, and no Mock
/// or Session is without one, so that Sessions that come and go leave
/// nothing behind. What they take counts against the bound on per-Session
/// state, which the store keeps up to date as it writes and removes them.
priv struct VariableStore {
  by_mock : Map[String, Map[String?, Map[String, Json]]]
  /// The engine's bound on per-Session state.
  state : StateBound
}

///|
/// No Variable stored, counting against `state`.
fn VariableStore::new(state : StateBound) -> VariableStore {
  { by_mock: Map([]), state, }
}

///|
/// The Variables of `mock` for `session`, by name. There are none when the
/// map is absent. While no Variable is stored, as when no Stub writes any,
/// it looks nothing up.
fn VariableStore::of(
  self : VariableStore,
  mock : String,
  session : String?,
) -> Map[String, Json]? {
  if self.by_mock.is_empty() {
    return None
  }
  match self.by_mock.get(mock) {
    Some(by_session) => by_session.get(session)
    None => None
  }
}

///|
/// How many bytes the count of per-Session state would grow by if the
/// Variables `names` of `mock` for `session` were written, each with the
/// value at the same index of `values`: negative when it would shrink.
/// `before` is what the space holds now, as `of` gives it. The space counts
/// when it holds nothing yet, each new Variable counts its name, and each
/// value counts in place of the one it replaces.
fn VariableStore::growth(
  mock : String,
  session : String?,
  before : Map[String, Json]?,
  names : ReadOnlyArray[String],
  values : Array[Json],
) -> Int64 {
  if names.length() == 0 {
    return 0L
  }
  let mut more = 0L
  match before {
    None => {
      more = space_bytes(mock, session)
      for i in 0..<names.length() {
        more += variable_name_bytes(names[i]) + value_bytes(values[i])
      }
    }
    Some(variables) =>
      for i in 0..<names.length() {
        more += value_bytes(values[i])
        match variables.get(names[i]) {
          Some(old) => more -= value_bytes(old)
          None => more += variable_name_bytes(names[i])
        }
      }
  }
  more
}

///|
/// Writes the Variables `names` of `mock` for `session`, each to the value
/// at the same index of `values`, at once, and grows the count of
/// per-Session state by `growth`, what `VariableStore::growth` gives for
/// them, which must fit. Writing nothing creates no map.
fn VariableStore::write(
  self : VariableStore,
  mock : String,
  session : String?,
  names : ReadOnlyArray[String],
  values : Array[Json],
  growth~ : Int64,
) -> Unit {
  if names.length() == 0 {
    return
  }
  self.state.add(growth)
  let by_session = match self.by_mock.get(mock) {
    Some(by_session) => by_session
    None => {
      let by_session = Map([])
      self.by_mock[mock] = by_session
      by_session
    }
  }
  let variables = match by_session.get(session) {
    Some(variables) => variables
    None => {
      let variables = Map([])
      by_session[session] = variables
      variables
    }
  }
  for i in 0..<names.length() {
    variables[names[i]] = values[i]
  }
}

///|
/// Clears the Variables of every Mock and Session for which `remove`
/// holds, gives back the bytes they and their spaces counted, and returns
/// how many it cleared. It leaves no map empty.
fn VariableStore::remove_where(
  self : VariableStore,
  remove : (String, String?) -> Bool,
) -> Int {
  let mut count = 0
  for mock in self.by_mock.keys().collect() {
    let by_session = self.by_mock[mock]
    for session in by_session.keys().collect() {
      if remove(mock, session) {
        let variables = by_session[session]
        let mut bytes = space_bytes(mock, session)
        for name, value in variables {
          bytes += variable_name_bytes(name) + value_bytes(value)
        }
        self.state.add(-bytes)
        count += variables.length()
        by_session.remove(session)
      }
    }
    if by_session.is_empty() {
      self.by_mock.remove(mock)
    }
  }
  count
}

///|
/// The request as templates see it.
fn template_input(incoming : Incoming) -> @template.Input {
  {
    meth: incoming.request.meth,
    path: incoming.path,
    query: incoming.query_parameters(),
    headers: incoming.request.headers,
    body: incoming.request.body,
  }
}

///|
/// Why a request's writes were not taken: nothing was written.
priv suberror WriteFailure {
  /// A value failed to render: the request gets the template failure.
  ValueFailed(TemplateError)
  /// The writes would take the count of per-Session state above its bound,
  /// for the reason given: the request gets 507.
  StateLimitReached(String)
}

///|
/// Step 3 of the match decision, for a Stub that writes Variables: renders
/// the value of each of `stub`'s Variables, in the order written, against
/// the Variables of its Mock and `session` as they were before the request,
/// then writes them all at once, if they fit within the bound on
/// per-Session state. `first` is the first rendering for the request, which
/// reads those Variables; each value has a rendering of its own, with its
/// own bounds, and they draw from the request's helper generator in turn.
///
/// Returns the rendering the response continues with, which reads the
/// Variables as they are after the writes. When a value fails to render,
/// or the writes do not fit, it raises why and writes none of them; the
/// bound counts a refusal.
fn Engine::write_variables(
  self : Engine,
  stub : @definitions.Stub,
  session : String?,
  first : @template.Context,
) -> @template.Context raise WriteFailure {
  let writes = stub.variables
  let before = self.variables.of(stub.mock, session)
  let values = Array(capacity=writes.values.length())
  let mut context = first
  for i in 0..<writes.values.length() {
    if i > 0 {
      context = context.next(vars?=before)
    }
    let value = writes.values[i].render_value(context) catch {
      RenderError(at~, message~) => raise ValueFailed({ at, message, })
    }
    values.push(value)
  }
  let growth = VariableStore::growth(
    stub.mock,
    session,
    before,
    writes.names,
    values,
  )
  if !self.state.fits(growth) {
    raise StateLimitReached(self.state.refuse(growth))
  }
  self.variables.write(stub.mock, session, writes.names, values, growth~)
  context.next(vars?=self.variables.of(stub.mock, session))
}

///|
/// The names of the Variables a request wrote, when it wrote none.
let none_written : ReadOnlyArray[String] = ReadOnlyArray::from_array([])
