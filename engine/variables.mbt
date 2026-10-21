// Variables: named JSON values, kept per Mock and per Session. A Stub's
// `variables` write them at the match decision, in `Engine::handle`, and
// the Admin API lists, sets and deletes them. Both are synchronous and
// single-threaded, so reading them and writing them needs no lock (ADR
// 0003). Templates read them as `vars.NAME`.

///|
/// The Variables of the Mock `mock` for `session`, or for the no-Session
/// space when it is `None`, by name, in byte-wise order of their names.
/// Another Session's Variables are never among them.
///
/// Raises `UnknownMock` when no Mock has the name `mock`.
pub fn Engine::list_variables(
  self : Engine,
  mock~ : String,
  session~ : String?,
) -> Map[String, Json] raise AdminError {
  self.check_mock(mock)
  let listed = Map([])
  guard self.store.variables_of(mock, session) is Some(variables) else {
    return listed
  }
  let names = variables.keys().collect()
  names.sort_by((a, b) => @utf8.encode(a).lexical_compare(@utf8.encode(b)))
  for name in names {
    listed[name] = variables[name]
  }
  listed
}

///|
/// Sets the Variable `name` of the Mock `mock` to `value` for `session`, or
/// for the no-Session space when it is `None`, as a Stub's `variables`
/// would: the value replaces the one it had, and `null` is stored, not
/// deleted. The write counts against the bound on per-Session state as a
/// Stub's writes do, and is taken only if it fits.
///
/// Raises `UnknownMock` when no Mock has the name `mock`,
/// `InvalidVariableName` when `name` cannot name a Variable, and
/// `StateLimitReached` when the write would take the count above the
/// bound, which counts the refusal; then nothing is written.
pub fn Engine::set_variable(
  self : Engine,
  mock~ : String,
  session~ : String?,
  name~ : String,
  value : Json,
) -> Unit raise AdminError {
  self.check_mock(mock)
  check_variable_name(name)
  let names = ReadOnlyArray::from_array([name])
  let values = [value]
  let growth = self.store.variable_growth(
    mock,
    session,
    self.store.variables_of(mock, session),
    names,
    values,
  )
  if !self.state.fits(growth) {
    raise StateLimitReached(self.state.refuse(growth))
  }
  self.store.write_variables(mock, session, names, values, growth~)
}

///|
/// Deletes the Variable `name` of the Mock `mock` for `session`, or for
/// the no-Session space when it is `None`, so that templates miss it
/// again, and gives back the bytes it counted against the bound on
/// per-Session state. Another Session's Variables are unknown here.
///
/// Raises `UnknownMock` when no Mock has the name `mock`,
/// `InvalidVariableName` when `name` cannot name a Variable, and
/// `UnknownVariable` when `session` has no Variable `name` in the Mock.
pub fn Engine::delete_variable(
  self : Engine,
  mock~ : String,
  session~ : String?,
  name~ : String,
) -> Unit raise AdminError {
  self.check_mock(mock)
  check_variable_name(name)
  if !self.store.remove_variable(mock, session, name) {
    raise UnknownVariable(mock~, name~)
  }
}

///|
/// Raises `InvalidVariableName` unless `name` can name a Variable.
fn check_variable_name(name : String) -> Unit raise AdminError {
  if !@definitions.is_variable_name(name) {
    raise InvalidVariableName(name)
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
/// Step 3 of the match decision, for a Stub of the Mock `mock` that writes
/// Variables, `writes`: renders the value of each, in the order written,
/// against the Variables of `mock` and `session` as they were before the
/// request, then writes them all at once, if they fit within the bound on
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
  mock : String,
  writes : @definitions.VariableWrites,
  session : String?,
  first : @template.Context,
) -> @template.Context raise WriteFailure {
  let before = self.store.variables_of(mock, session)
  let values = Array(capacity=writes.values.length())
  let last = render_values(writes, first, before, values) catch {
    RenderError(at~, message~) => raise ValueFailed({ at, message, })
  }
  let growth = self.store.variable_growth(
    mock,
    session,
    before,
    writes.names,
    values,
  )
  if !self.state.fits(growth) {
    raise StateLimitReached(self.state.refuse(growth))
  }
  self.store.write_variables(mock, session, writes.names, values, growth~)
  last.next(vars?=self.store.variables_of(mock, session))
}

///|
/// Renders the value of each of `writes`, in the order written, against
/// the Variables `before`, and pushes it to `values`. The first value
/// renders in `first`, which reads `before`; each next one has a rendering
/// of its own, with its own bounds, and they draw from the request's helper
/// generator in turn. Returns the last rendering, which the response
/// continues from. When a value fails to render, it raises the error.
fn render_values(
  writes : @definitions.VariableWrites,
  first : @template.Context,
  before : Map[String, Json]?,
  values : Array[Json],
) -> @template.Context raise @template.RenderError {
  let mut context = first
  for i in 0..<writes.values.length() {
    if i > 0 {
      context = context.next(vars?=before)
    }
    values.push(writes.values[i].render_value(context))
  }
  context
}

///|
/// The names of the Variables a request wrote, when it wrote none.
let none_written : ReadOnlyArray[String] = ReadOnlyArray::from_array([])
