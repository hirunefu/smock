// Variables: named JSON values, kept per Mock and per Session. A Stub's
// `variables` write them at the match decision, in `Engine::handle`, which
// is synchronous and single-threaded, so reading them and writing them
// needs no lock (ADR 0003). Templates read them as `vars.NAME`.

///|
/// The Variables of each Mock and Session: by Mock, then by Session (`None`
/// for the no-Session space), then by name. No map is empty, and no Mock
/// or Session is without one, so that Sessions that come and go leave
/// nothing behind.
priv struct VariableStore {
  by_mock : Map[String, Map[String?, Map[String, Json]]]
}

///|
/// No Variable stored.
fn VariableStore::new() -> VariableStore {
  { by_mock: Map([]), }
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
/// Writes the Variables `names` of `mock` for `session`, each to the value
/// at the same index of `values`, at once. Writing nothing creates no map.
fn VariableStore::write(
  self : VariableStore,
  mock : String,
  session : String?,
  names : ReadOnlyArray[String],
  values : Array[Json],
) -> Unit {
  if names.length() == 0 {
    return
  }
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
/// holds, and returns how many it cleared. It leaves no map empty.
fn VariableStore::remove_where(
  self : VariableStore,
  remove : (String, String?) -> Bool,
) -> Int {
  let mut count = 0
  for mock in self.by_mock.keys().collect() {
    let by_session = self.by_mock[mock]
    for session in by_session.keys().collect() {
      if remove(mock, session) {
        count += by_session[session].length()
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
/// Step 3 of the match decision, for a Stub that writes Variables: renders
/// the value of each of `stub`'s Variables, in the order written, against
/// the Variables of its Mock and `session` as they were before the request,
/// then writes them all at once. `first` is the first rendering for the
/// request, which reads those Variables; each value has a rendering of its
/// own, with its own bounds, and they draw from the request's helper
/// generator in turn.
///
/// Returns the rendering the response continues with, which reads the
/// Variables as they are after the writes. When a value fails to render,
/// it raises the error and writes none of them.
fn Engine::write_variables(
  self : Engine,
  stub : @definitions.Stub,
  session : String?,
  first : @template.Context,
) -> @template.Context raise @template.RenderError {
  let writes = stub.variables
  let before = self.variables.of(stub.mock, session)
  let values = Array(capacity=writes.values.length())
  let mut context = first
  for i in 0..<writes.values.length() {
    if i > 0 {
      context = context.next(vars?=before)
    }
    values.push(writes.values[i].render_value(context))
  }
  self.variables.write(stub.mock, session, writes.names, values)
  context.next(vars?=self.variables.of(stub.mock, session))
}

///|
/// The names of the Variables a request wrote, when it wrote none.
let none_written : ReadOnlyArray[String] = ReadOnlyArray::from_array([])
