// find(array, member, value): the first element of an array that is an
// object whose member meets a value, compared as list filters compare (see
// `FilterValue`). Mockoon has an array helper of this name; the arguments
// follow smock's call syntax.

///|
/// `find`, when `site` calls it, checked. `None` when it calls a helper of
/// another family.
fn find_helper(site : CallSite) -> Helper? raise Syntax {
  guard site.name == "find" else { return None }
  site.takes([Array, Name, Scalar], least=3, most=3)
  Some(Find)
}

///|
/// What `find` gives for the values of its arguments, `values`, inserted
/// at `at`: the first element that is an object whose member meets the
/// value, or `None` when there is none. It returns an element and builds
/// nothing, so the bound on a helper's result does not apply.
fn find_value(values : Array[Json], at : String) -> Json? raise RenderError {
  guard values[0] is Array(items) else {
    raise RenderError(
      at~,
      message=argument_problem("find", 0, Array, values[0]),
    )
  }
  guard values[1] is String(name) else {
    raise RenderError(at~, message=argument_problem("find", 1, Name, values[1]))
  }
  guard scalar_text(values[2]) is Some(text) else {
    raise RenderError(
      at~,
      message=argument_problem("find", 2, Scalar, values[2]),
    )
  }
  let value = FilterValue(text)
  for item in items {
    if item is Object(members) &&
      members.get(name) is Some(actual) &&
      value.matches(actual) {
      return Some(item)
    }
  }
  None
}
