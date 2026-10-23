// last(array): the last element of an array. It is a helper rather than an
// index from the end, so the grammar of references does not change.

///|
/// `last`, when `site` calls it, checked. `None` when it calls a helper of
/// another family.
fn last_helper(site : CallSite) -> Helper? raise Syntax {
  guard site.name == "last" else { return None }
  site.takes([Array], least=1, most=1)
  Some(Last)
}

///|
/// What `last` gives for the value of its argument, `values[0]`, inserted
/// at `at`: the last element of the array, or `None` when it is empty. It
/// returns an element and builds nothing, so the bound on a helper's result
/// does not apply.
fn last_value(values : Array[Json], at : String) -> Json? raise RenderError {
  guard values[0] is Array(items) else {
    raise RenderError(
      at~,
      message=argument_problem("last", 0, Array, values[0]),
    )
  }
  items.last()
}
