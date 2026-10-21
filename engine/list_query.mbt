// List queries: the query of a request to a CRUD Stub's list, in smock's
// own syntax. It keeps the items whose members meet its filters, sorts them
// by `$sort`, then skips `$offset` of them and keeps at most `$limit`.

///|
/// The answer of the CRUD Stub `stub`, which serves `crud`, to a request
/// for its list, whose decoded query parameters are `parameters`, when its
/// bucket holds `value`, the array `items`. It answers 200 with the items
/// the list query keeps, as a plain array, with the number of items in the
/// bucket in `X-Total-Count`, and the number that pass the filters, before
/// paging, in `X-Filtered-Count`. A query that smock cannot read answers
/// 400 `invalid query parameter`, with the parameter's name.
fn crud_list(
  crud : @definitions.Crud,
  stub : String,
  value : Json,
  items : Array[Json],
  parameters : Array[(String, String)],
) -> ResponsePlan {
  let total = items.length().to_string()
  // Without a query, the bucket's value is the answer as it is.
  if parameters.is_empty() {
    return crud_plan(crud, 200, @template.compact_json_bytes(value), [
      ("X-Total-Count", total),
      ("X-Filtered-Count", total),
    ])
  }
  let query = ListQuery::parse(parameters) catch {
    InvalidQueryParameter(name) =>
      return crud_failed(crud, 400, {
        "error": "invalid query parameter",
        "stub": Json::string(stub),
        "parameter": Json::string(name),
      })
  }
  let passed = query.filter(items)
  let filtered = passed.length().to_string()
  query.sort(passed)
  let page = query.page(passed)
  crud_plan(crud, 200, @template.compact_json_bytes(Json::array(page)), [
    ("X-Total-Count", total),
    ("X-Filtered-Count", filtered),
  ])
}

///|
/// What a list keeps of its bucket's items: the items whose members meet
/// every filter, sorted by the sort keys, from the `offset`th on, at most
/// `limit` of them.
priv struct ListQuery {
  /// The filters, one per member name, in the order the names first come
  /// in the query.
  filters : Array[Filter]
  /// The sort keys of `$sort`, in order; none keeps the bucket's order.
  sort : Array[SortKey]
  /// The number of items that pass the filters to skip, 0 by default.
  offset : Int
  /// The most items to keep after the offset, if any.
  limit : Int?
}

///|
/// A filter on a member: it holds for an item whose member meets any of
/// the values, as `@template.FilterValue::matches` compares them.
priv struct Filter {
  /// The member's name: a top-level member, named literally.
  name : String
  /// The values of every parameter that names the member, in query order.
  values : Array[@template.FilterValue]
}

///|
/// A sort key of `$sort`: a member, by whose value items are ordered,
/// ascending or descending.
priv struct SortKey {
  /// The member's name: a top-level member, named literally.
  name : String
  /// Whether the order is descending, as `-` before the name asks.
  descending : Bool
}

///|
/// Why a list query is refused: the parameter of this name, as decoded, is
/// not one smock reads. The list then answers 400.
priv suberror InvalidQueryParameter {
  InvalidQueryParameter(String)
}

///|
/// The list query that the decoded query parameters `parameters` give. A
/// name that does not start with `$` filters on the member of that name,
/// and `$$` stands for a name's leading `$`. `$sort` is a comma-separated
/// list of sort keys (see `sort_keys`). `$offset` and `$limit` are decimal
/// digits, `$offset` from 0 and `$limit` from 1; a number too large to
/// hold counts as the largest. Each of the three is given once. Any other
/// name that starts with `$`, or one of these with a value it cannot take
/// or given again, is refused, so that a client never gets a wrong list
/// from a parameter smock does not read. The first such parameter, in
/// query order, is named.
fn ListQuery::parse(
  parameters : Array[(String, String)],
) -> ListQuery raise InvalidQueryParameter {
  let filters : Array[Filter] = []
  let mut sort = None
  let mut offset = None
  let mut limit = None
  for parameter in parameters {
    let (name, value) = parameter
    match name {
      "$sort" if sort is None && sort_keys(value) is Some(keys) =>
        sort = Some(keys)
      "$offset" if offset is None && is_digits(value) =>
        offset = Some(position(value, @int.MAX_VALUE))
      "$limit" if limit is None && is_digits(value) && significant(value) != "" =>
        limit = Some(position(value, @int.MAX_VALUE))
      _ if name.has_prefix("$$") =>
        filter_on(filters, name[1:].to_owned()).values.push(
          @template.FilterValue(value),
        )
      _ if name.has_prefix("$") => raise InvalidQueryParameter(name)
      _ => filter_on(filters, name).values.push(@template.FilterValue(value))
    }
  }
  { filters, sort: sort.unwrap_or([]), offset: offset.unwrap_or(0), limit, }
}

///|
/// The sort keys that `value`, the value of `$sort`, lists: member names
/// separated by commas, each after an optional `-` that makes its order
/// descending. Names are literal. `None` when a name is empty, as in
/// `$sort=`, `$sort=a,,b` or `$sort=-`, or starts with `-`, as in
/// `$sort=--a`: a member whose name starts with `-` or holds `,` cannot be
/// a sort key.
fn sort_keys(value : String) -> Array[SortKey]? {
  let keys = []
  let mut start = 0
  for i in 0..<=value.length() {
    if i < value.length() && value[i] != ',' {
      continue
    }
    let descending = i > start && value[start] == '-'
    let from = if descending { start + 1 } else { start }
    if from == i || value[from] == '-' {
      return None
    }
    keys.push({ name: value[from:i].to_owned(), descending, })
    start = i + 1
  }
  Some(keys)
}

///|
/// The filter of `filters` on the member named `name`, added when there
/// is none yet.
fn filter_on(filters : Array[Filter], name : String) -> Filter {
  for filter in filters {
    if filter.name == name {
      return filter
    }
  }
  let filter = { name, values: [], }
  filters.push(filter)
  filter
}

///|
/// The items of `items` that meet every filter, in their order.
fn ListQuery::filter(self : ListQuery, items : Array[Json]) -> Array[Json] {
  let passed = []
  for item in items {
    if self.passes(item) {
      passed.push(item)
    }
  }
  passed
}

///|
/// Whether `item` meets every filter: each named member is present and
/// meets one of its filter's values.
fn ListQuery::passes(self : ListQuery, item : Json) -> Bool {
  guard item is Object(members) else { return false }
  for filter in self.filters {
    guard members.get(filter.name) is Some(held) else { return false }
    let mut met = false
    for value in filter.values {
      if value.matches(held) {
        met = true
        break
      }
    }
    if !met {
      return false
    }
  }
  true
}

///|
/// Sorts `passed`, the items that passed the filters, by the sort keys, in
/// place: by the first key, then by the next for items that tie, and so
/// on. The sort is stable, so items that tie on every key keep their
/// order. It is a merge sort, with plain loops and one buffer.
fn ListQuery::sort(self : ListQuery, passed : Array[Json]) -> Unit {
  let n = passed.length()
  if self.sort.is_empty() || n < 2 {
    return
  }
  let mut from = FixedArray::make(n, Json::null())
  let mut to = FixedArray::make(n, Json::null())
  for i in 0..<n {
    from[i] = passed[i]
  }
  let mut width = 1
  while width < n {
    let mut low = 0
    while low < n {
      let middle = (low + width).min(n)
      let high = (low + 2 * width).min(n)
      let mut i = low
      let mut j = middle
      for k in low..<high {
        // On a tie, the item from the left run goes first.
        if j == high ||
          (i < middle && compare_items(from[i], from[j], self.sort) <= 0) {
          to[k] = from[i]
          i += 1
        } else {
          to[k] = from[j]
          j += 1
        }
      }
      low = high
    }
    let runs = from
    from = to
    to = runs
    width *= 2
  }
  for i in 0..<n {
    passed[i] = from[i]
  }
}

///|
/// How the items `a` and `b` order by the sort keys `keys`: by the first
/// key, then by the next while they tie.
fn compare_items(a : Json, b : Json, keys : Array[SortKey]) -> Int {
  for key in keys {
    let order = compare_members(a, b, key)
    if order != 0 {
      return order
    }
  }
  0
}

///|
/// How the items `a` and `b` order by the member `key` names. Ascending,
/// values order by type first: null, false, true, numbers, strings.
/// Numbers order by value (see `@template.compare_numbers`), and strings by
/// code point (see `compare_code_points`). Descending reverses that order.
/// An item whose member is absent, an object or an array goes after the
/// others either way, and ties with every such item.
fn compare_members(a : Json, b : Json, key : SortKey) -> Int {
  let a = member_value(a, key.name)
  let b = member_value(b, key.name)
  let a_rank = type_rank(a)
  let b_rank = type_rank(b)
  if a_rank == unordered || b_rank == unordered {
    return a_rank.compare(b_rank)
  }
  let order = if a_rank != b_rank {
    a_rank.compare(b_rank)
  } else if a is Some(Number(x, repr=x_text)) &&
    b is Some(Number(y, repr=y_text)) {
    @template.compare_numbers(x, x_text, y, y_text)
  } else if a is Some(String(x)) && b is Some(String(y)) {
    compare_code_points(x, y)
  } else {
    0
  }
  if key.descending {
    -order
  } else {
    order
  }
}

///|
/// The value of the member `name` of `item`, if it has one.
fn member_value(item : Json, name : String) -> Json? {
  guard item is Object(members) else { return None }
  members.get(name)
}

///|
/// The rank of the members that sort after every other, either way:
/// absent members, objects and arrays.
let unordered : Int = 5

///|
/// Where a member's value, by its type, places an item in ascending
/// order: null, false, true, numbers, strings, then `unordered` for an
/// object, an array or no value.
fn type_rank(value : Json?) -> Int {
  match value {
    Some(Null) => 0
    Some(False) => 1
    Some(True) => 2
    Some(Number(_)) => 3
    Some(String(_)) => 4
    Some(Object(_)) | Some(Array(_)) | None => unordered
  }
}

///|
/// How the strings `a` and `b` order by Unicode code point, case-sensitive,
/// rather than by UTF-16 code unit: a character beyond the Basic
/// Multilingual Plane, written as a surrogate pair, goes after every
/// character within it, U+E000 to U+FFFF included.
fn compare_code_points(a : String, b : String) -> Int {
  let n = a.length().min(b.length())
  for i in 0..<n {
    if a[i] != b[i] {
      return code_point_order(a[i]).compare(code_point_order(b[i]))
    }
  }
  a.length().compare(b.length())
}

///|
/// Where the UTF-16 code unit `unit` places a string in code point order,
/// at the first unit where two strings differ: surrogates move above
/// U+E000 to U+FFFF, which move down to make room.
fn code_point_order(unit : UInt16) -> Int {
  let unit = unit.to_int()
  if unit >= 0xD800 && unit <= 0xDFFF {
    unit + 0x2000
  } else if unit >= 0xE000 {
    unit - 0x800
  } else {
    unit
  }
}

///|
/// The page of `passed`, the items that passed the filters, in order:
/// from the `offset`th on, at most `limit` of them; none when the offset
/// is past the end. It is `passed` itself when the page holds every item.
fn ListQuery::page(self : ListQuery, passed : Array[Json]) -> Array[Json] {
  let start = self.offset.min(passed.length())
  let end = match self.limit {
    Some(limit) if limit < passed.length() - start => start + limit
    _ => passed.length()
  }
  if start == 0 && end == passed.length() {
    passed
  } else {
    passed[start:end].to_owned()
  }
}
