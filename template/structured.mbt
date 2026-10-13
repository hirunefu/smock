// Structured templates: a JSON value whose strings may insert values, with
// `$each` for loops and `$if` for conditionals. smock writes the output
// itself, as compact JSON.

///|
/// A node of a structured template.
priv enum Node {
  /// A value with nothing to render.
  Static(Json)
  /// A string with values inserted, which gives a string. Its pointer.
  Interpolated(Array[Part], String)
  /// A string that is exactly one `${ expr }`, which gives the value with
  /// its own type. Its pointer.
  Single(Expr, String)
  /// An object, its members in the order written.
  Members(Array[(String, Node)])
  /// An array.
  Elements(Array[Node])
  /// `$each`: the expression, the loop variable, the template of each
  /// element, and the pointer of the `$each` member.
  Each(Expr, String, Node, String)
  /// `$if`: the condition, `then`, `else` if given, and the pointer of the
  /// `$if` member.
  If(Cond, Node, Node?, String)
}

///|
/// A structured template, parsed: the `json` of a response or of a
/// Server-Sent Event, with `template` on.
pub struct Structured {
  /// The template as written.
  source : Json
  /// The JSON Pointer to the field, within the Stub.
  pointer : String
  priv root : Node
}

///|
/// Structured templates are equal when they are written the same, for the
/// same field.
pub impl Eq for Structured with fn equal(self, other) {
  self.pointer == other.pointer && self.source == other.source
}

///|
/// Shows the template as it is written.
pub impl Debug for Structured with fn to_repr(self) {
  Repr::ctor("Structured", [(None, Debug::to_repr(self.source))])
}

///|
/// The most loop iterations one response runs, in all.
let max_iterations : Int = 10_000

///|
/// Parses `source` as a structured template, for the field at `pointer`,
/// within the Stub. Returns the template, or every problem found.
pub fn Structured::parse(
  source : Json,
  pointer~ : String,
) -> Result[Structured, Array[Problem]] {
  let problems = []
  let root = parse_node(source, pointer, [], false, true, problems)
  if problems.is_empty() {
    let least = least_iterations(root)
    if least > max_iterations {
      problems.push({
        pointer,
        message: "template: its loops run at least \{least} times; one response runs at most \{max_iterations} loop iterations",
      })
    }
  }
  if problems.is_empty() {
    Ok({ source, pointer, root, })
  } else {
    Err(problems)
  }
}

///|
/// Parses the value `json` at `pointer`. `vars` are the loop variables in
/// scope, `in_loop` says whether it is inside a `$each`, and `required`
/// whether it must give a value: at the root, a `$if` needs `else`.
fn parse_node(
  json : Json,
  pointer : String,
  vars : Array[String],
  in_loop : Bool,
  required : Bool,
  problems : Array[Problem],
) -> Node {
  let problem = (at : String, message : String) => {
    problems.push({ pointer: at, message: "template: \{message}", })
    Static(Json::null())
  }
  match json {
    String(s) => {
      let chars = s.iter().collect()
      let parts = parse_parts(chars, vars, in_loop, text=false) catch {
        Syntax(at, message) =>
          return problem(pointer, "\{position(chars, at)}\{message}")
      }
      match parts {
        [] => Static(Json::string(""))
        [Verbatim(text)] => Static(Json::string(text))
        [Insert(expr)] => Single(expr, pointer)
        _ => Interpolated(parts, pointer)
      }
    }
    Array(items) =>
      Elements(
        items.mapi((i, item) => {
          parse_node(
            item,
            child_pointer(pointer, i.to_string()),
            vars,
            in_loop,
            false,
            problems,
          )
        }),
      )
    Object(members) => {
      if members.contains("$each") || members.contains("$if") {
        return parse_directive(
          members, pointer, vars, in_loop, required, problems,
        )
      }
      let out = []
      for key, value in members {
        let at = child_pointer(pointer, key)
        if key.contains("${") {
          ignore(problem(at, "${ in a key: keys are never templated"))
          continue
        }
        let key = if key.has_prefix("$$") {
          key[1:].to_owned()
        } else if key.has_prefix("$") {
          ignore(
            problem(
              at,
              "\{key.escape()} is reserved; write $\{key} for a key that starts with $",
            ),
          )
          continue
        } else {
          key
        }
        out.push((key, parse_node(value, at, vars, in_loop, false, problems)))
      }
      Members(out)
    }
    other => Static(other)
  }
}

///|
/// Parses an object with a `$each` or `$if` key.
fn parse_directive(
  members : Map[String, Json],
  pointer : String,
  vars : Array[String],
  in_loop : Bool,
  required : Bool,
  problems : Array[Problem],
) -> Node {
  let problem = (at : String, message : String) => {
    problems.push({ pointer: at, message: "template: \{message}", })
    Static(Json::null())
  }
  let (directive, allowed) = if members.contains("$each") {
    ("$each", ["$each", "as", "do"])
  } else {
    ("$if", ["$if", "then", "else"])
  }
  let listed = allowed.map(key => "\"\{key}\"").join(", ")
  for key, _ in members {
    if !allowed.contains(key) {
      return problem(
        child_pointer(pointer, key),
        "an object with \"\{directive}\" has only \{listed}",
      )
    }
  }
  let directive_at = child_pointer(pointer, directive)
  // The expression of a directive is written without ${ }.
  let expression = (parse : (Parser) -> Unit raise Syntax) => {
    guard members[directive] is String(text) else {
      ignore(problem(directive_at, "\"\{directive}\" must be a string"))
      return false
    }
    let chars = text.iter().collect()
    let parser = { chars, i: 0, vars, in_loop, text: false, }
    try {
      if text.has_prefix("${") {
        raise Syntax(
          0,
          "write the expression of \{directive} without ${ }, such as \{directive}: body.items",
        )
      }
      parse(parser)
      parser.skip_space()
      if parser.i < chars.length() {
        raise Syntax(
          parser.i,
          "expected the expression to end, found \{parser.found()}",
        )
      }
    } catch {
      Syntax(at, message) => {
        ignore(problem(directive_at, "\{position(chars, at)}\{message}"))
        return false
      }
    }
    true
  }
  if directive == "$each" {
    let mut expr = Expr::Literal(Json::null())
    let ok = expression(parser => expr = parser.expr())
    if !members.contains("as") || !members.contains("do") {
      return problem(pointer, "a $each needs \"as\" and \"do\"")
    }
    let as_at = child_pointer(pointer, "as")
    let name = match members["as"] {
      String(name) if !is_identifier(name) =>
        return problem(
          as_at, "a loop variable is a name of letters, digits, _ and -, starting with a letter or _",
        )
      String(name) if root_names.contains(name) || reserved.contains(name) =>
        return problem(
          as_at,
          "\{name.escape()} cannot be a loop variable: it is a request field, loop or a reserved word",
        )
      String(name) => name
      _ => return problem(as_at, "\"as\" must be a string")
    }
    let body = parse_node(
      members["do"],
      child_pointer(pointer, "do"),
      [..vars, name],
      true,
      false,
      problems,
    )
    if !ok {
      return Static(Json::null())
    }
    if literal_range(expr) is Some(count) && count > max_range {
      return problem(directive_at, "range gives at most \{max_range} values")
    }
    Each(expr, name, body, directive_at)
  } else {
    let mut cond = {
      negated: false,
      expr: Expr::Literal(Json::null()),
      compare: None,
    }
    let ok = expression(parser => cond = parser.cond())
    if !members.contains("then") {
      return problem(pointer, "a $if needs \"then\"")
    }
    if required && !members.contains("else") {
      return problem(
        pointer, "a $if at the root of json needs \"else\", so that it always gives a value",
      )
    }
    let then = parse_node(
      members["then"],
      child_pointer(pointer, "then"),
      vars,
      in_loop,
      required,
      problems,
    )
    let otherwise = members
      .get("else")
      .map(value => {
        parse_node(
          value,
          child_pointer(pointer, "else"),
          vars,
          in_loop,
          required,
          problems,
        )
      })
    if !ok {
      return Static(Json::null())
    }
    If(cond, then, otherwise, directive_at)
  }
}

///|
/// The fewest loop iterations `node` runs, whatever the request: those of
/// the loops over literal ranges that always run.
fn least_iterations(node : Node) -> Int {
  match node {
    Static(_) | Interpolated(_, _) | Single(_, _) => 0
    Members(members) =>
      sum_capped(members.map(entry => least_iterations(entry.1)))
    Elements(elements) => sum_capped(elements.map(least_iterations))
    Each(expr, _, body, _) =>
      match literal_range(expr) {
        Some(count) => {
          let each = 1 + least_iterations(body)
          if count > 0 && each > max_iterations / count + 1 {
            max_iterations + 1
          } else {
            count * each
          }
        }
        None => 0
      }
    If(_, then, Some(otherwise), _) => {
      let a = least_iterations(then)
      let b = least_iterations(otherwise)
      if a < b {
        a
      } else {
        b
      }
    }
    If(_, _, None, _) => 0
  }
}

///|
/// The sum of `counts`, capped just above the bound.
fn sum_capped(counts : Array[Int]) -> Int {
  let mut sum = 0
  for count in counts {
    sum += count
    if sum > max_iterations {
      return max_iterations + 1
    }
  }
  sum
}

///|
/// The JSON Pointer (RFC 6901) to member or element `key` of the value at
/// `pointer`.
fn child_pointer(pointer : String, key : String) -> String {
  let escaped = key
    .replace_all(old="~", new="~0")
    .replace_all(old="/", new="~1")
  "\{pointer}/\{escaped}"
}

///|
/// Renders the template for the request of `context`, as compact JSON in
/// UTF-8.
///
/// Raises `RenderError` when a value it needs is missing, a value is of a
/// type it cannot use, or a bound is exceeded.
pub fn Structured::render(
  self : Structured,
  context : Context,
) -> Bytes raise RenderError {
  let out = @buffer.Buffer()
  let start = context.output
  match context.resolve(self.root, []) {
    Some(node) => context.write_node(out, node, [], start)
    None => out.write_string_utf8("null")
  }
  context.output = start + out.length()
  out.to_bytes()
}
