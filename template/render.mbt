// Rendering: the values of expressions for one request, and the output of
// structured templates.

///|
/// A template could not be rendered for a request: a JSON Pointer to the
/// field, within the Stub, and what went wrong.
pub suberror RenderError {
  RenderError(at~ : String, message~ : String)
} derive(Debug)

///|
/// The request a response is rendered for, as templates see it.
pub(all) struct Input {
  meth : String
  /// The percent-decoded path without the query, as conditions compare it.
  path : String
  /// The decoded query parameters as (name, value) pairs, in order.
  query : Array[(String, String)]
  /// The header fields as (name, value) pairs, in order: one per field
  /// line.
  headers : Array[(String, String)]
  body : Bytes
}

///|
/// The body parsed as JSON: not parsed yet, parsed, or not JSON.
priv enum ParsedBody {
  NotParsed
  Parsed(Json)
  NotJson
}

///|
/// One rendering for a request, such as its response: the request, the
/// time, the random source of the helpers, and what the rendering has used
/// of its bounds so far.
pub struct Context {
  priv input : Input
  /// The time of the request, in milliseconds since the Unix epoch.
  priv now : Int64
  /// The delays of the events rendered so far, in milliseconds.
  priv mut elapsed : Int64
  /// What the helpers draw from: the request's helper generator, which
  /// every rendering for the request shares.
  priv rand : @prng.Generator
  /// The loop iterations run so far.
  priv mut iterations : Int
  /// The bytes of body or events rendered so far.
  priv mut output : Int
  priv mut body : ParsedBody
  /// The request's cookies, by name, once a template has read one.
  priv mut cookies : Map[String, Array[String]]?
}

///|
/// What the seed of the helpers' generator is XORed with: a fixed constant,
/// so that the helpers draw from another sequence than the Fault decisions
/// made from the same output.
let helper_mask : UInt64 = 0xA0761D6478BD642FUL

///|
/// The helper generator of a matched request: what the helpers of every
/// rendering for the request draw from. `draw` is the 64-bit output the
/// request took from its Stub's random source; the generator is seeded with
/// it XOR a fixed constant. It is made once per request, and only when
/// something is rendered. Each rendering then draws from it in turn, on
/// from where the one before stopped, so the helpers give what one
/// rendering of them all, in that order, would give.
pub fn helper_generator(draw : UInt64) -> @prng.Generator {
  @prng.Generator(draw ^ helper_mask)
}

///|
/// Starts one rendering for the request `input`, received at `now`
/// (milliseconds since the Unix epoch). The helpers draw from `rand`, the
/// request's `helper_generator`, in the order the template is rendered.
/// The bounds on loop iterations and on output count for this rendering
/// alone.
pub fn Context::new(
  input : Input,
  now~ : Int64,
  rand~ : @prng.Generator,
) -> Context {
  {
    input,
    now,
    elapsed: 0L,
    rand,
    iterations: 0,
    output: 0,
    body: NotParsed,
    cookies: None,
  }
}

///|
/// Moves the clock of `now()` and `nowMillis()` on by `ms` milliseconds:
/// the delay of the next event, whose templates then read the time of the
/// request plus the delays of the events up to and including it.
pub fn Context::advance(self : Context, ms : Int) -> Unit {
  self.elapsed += ms.to_int64()
}

///|
/// The most bytes a rendered body, or all the events of a response
/// together, take: 1 MiB.
let max_output : Int = 1024 * 1024

///|
/// Counts `bytes` more of output, from the field at `at`.
fn Context::count(
  self : Context,
  bytes : Int,
  at : String,
) -> Unit raise RenderError {
  self.output += bytes
  check_output(self.output, at)
}

///|
/// Raises a render error at `at` when `total` bytes of output are more than
/// the bound.
fn check_output(total : Int, at : String) -> Unit raise RenderError {
  if total > max_output {
    raise RenderError(
      at~,
      message="the rendered body or events take more than 1 MiB",
    )
  }
}

///|
/// How a value is written into a text template.
priv enum Form {
  /// Escaped as the text's kind says.
  Ordinary
  /// Never escaped: `raw(x)`.
  RawText
  /// JSON text, `json(x)`: not escaped again as the content of a JSON
  /// string.
  JsonOutput
}

///|
/// A value, and how a text template writes it.
priv struct Value {
  json : Json
  form : Form
}

///|
/// What an expression gives: a value, or nothing, with the source text of
/// the reference that named nothing.
priv enum Got {
  Present(Value)
  Missing(String)
}

///|
/// A loop in progress: its variable, the current element, and its position.
priv struct Frame {
  name : String
  element : Json
  index : Int
}

///|
/// The value of `expr`, which a template inserts at `at`: a missing value
/// is a render error here.
fn Context::value(
  self : Context,
  expr : Expr,
  frames : Array[Frame],
  at : String,
) -> Value raise RenderError {
  match self.eval(expr, frames, at) {
    Present(value) => value
    Missing(text) => raise RenderError(at~, message="\{text} is missing")
  }
}

///|
/// What `expr` gives.
fn Context::eval(
  self : Context,
  expr : Expr,
  frames : Array[Frame],
  at : String,
) -> Got raise RenderError {
  let present = (json : Json) => Present({ json, form: Ordinary, })
  match expr {
    Literal(json) => present(json)
    Fallback(alternatives) => {
      let mut last = ""
      for alternative in alternatives {
        match self.eval(alternative, frames, at) {
          Present(value) => return Present(value)
          Missing(text) => last = text
        }
      }
      Missing(last)
    }
    Ref(root, steps, text) =>
      match self.reference(root, steps, frames) {
        Some(json) => present(json)
        None => Missing(text)
      }
    Call(helper, args) => {
      // The arguments, evaluated in order; a missing one makes the call's
      // value missing too.
      let values = []
      for arg in args {
        match self.eval(arg, frames, at) {
          Present(value) => values.push(value.json)
          Missing(text) => return Missing(text)
        }
      }
      match helper {
        Number =>
          match values[0] {
            Number(_) as n => present(n)
            String(text) =>
              match number_of(text) {
                Some(n) => present(n)
                None =>
                  raise RenderError(
                    at~,
                    message="number(): \{text.escape()} is not a JSON number",
                  )
              }
            other =>
              raise RenderError(
                at~,
                message="number() takes a string or a number, not \{kind_of(other)}",
              )
          }
        Range => {
          let bound = (json : Json) => {
            match json {
              Number(n, ..) if n == n.floor() &&
                n.abs() <= max_integer.to_double() => n.to_int64()
              _ =>
                raise RenderError(
                  at~,
                  message="range() takes integers from -\{max_integer} to \{max_integer}, not \{compact_json(json)}",
                )
            }
          }
          let a = bound(values[0])
          let b = bound(values[1])
          let count = b - a + 1L
          if count > max_range.to_int64() {
            raise RenderError(
              at~,
              message="range(\{a}, \{b}) gives \{count} values; range gives at most \{max_range}",
            )
          }
          let items = []
          let mut n = a
          while n <= b {
            items.push(Json::number(n.to_double()))
            n += 1L
          }
          present(Json::array(items))
        }
        JsonText =>
          Present({
            json: Json::string(compact_json(values[0])),
            form: JsonOutput,
          })
        Raw =>
          match values[0] {
            Object(_) | Array(_) =>
              raise RenderError(
                at~,
                message="raw() takes a string, a number, true, false or null, not an object or an array",
              )
            json => Present({ json, form: RawText, })
          }
        Now(seconds) => {
          let ms = self.now + self.elapsed + seconds * 1000L
          // From 0000-01-01 to 9999-12-31, which RFC 3339 can write.
          if ms < -62_167_219_200_000L || ms > 253_402_300_799_999L {
            raise RenderError(
              at~,
              message="now(): the time is outside the years 0 to 9999",
            )
          }
          present(Json::string(@log.format_time(ms)))
        }
        NowMillis(seconds) =>
          present(
            Json::number(
              (self.now + self.elapsed + seconds * 1000L).to_double(),
            ),
          )
        fake => present(draw(fake, self.rand))
      }
    }
  }
}

///|
/// What the reference `root` with `steps` names, or `None` when it names
/// nothing.
fn Context::reference(
  self : Context,
  root : Root,
  steps : Array[Step],
  frames : Array[Frame],
) -> Json? {
  let request = self.input
  match root {
    Method => Some(Json::string(request.meth))
    BodyText => Some(Json::string(@utf8.decode_lossy(request.body)))
    Env(value) => value
    Path =>
      match steps {
        [Index(n)] => {
          let segments = request.path[1:].split("/").collect()
          if n < segments.length() {
            Some(Json::string(segments[n].to_owned()))
          } else {
            None
          }
        }
        _ => Some(Json::string(request.path))
      }
    Query =>
      match steps {
        [Name(name)] =>
          request.query
          .iter()
          .find_first(parameter => parameter.0 == name)
          .map(parameter => Json::string(parameter.1))
        _ => None
      }
    Header =>
      match steps {
        [Name(name)] =>
          header_values(request.headers, name).iter().head().map(Json::string)
        _ => None
      }
    Cookie =>
      match steps {
        [Name(name)] =>
          match self.cookie_values(name) {
            Some(values) => Some(Json::string(values[0]))
            None => None
          }
        _ => None
      }
    Body =>
      match self.parsed_body() {
        Some(json) => walk(json, steps)
        None => None
      }
    LoopIndex =>
      frames.last().map(frame => Json::number(frame.index.to_double()))
    Var(name) => {
      for i = frames.length() - 1; i >= 0; i = i - 1 {
        if frames[i].name == name {
          return walk(frames[i].element, steps)
        }
      }
      None
    }
  }
}

///|
/// The values of the header fields named `name`, compared
/// case-insensitively, in order.
fn header_values(
  headers : Array[(String, String)],
  name : String,
) -> Array[String] {
  let lower = name.to_lower()
  headers.filter(h => h.0.to_lower() == lower).map(h => h.1)
}

///|
/// The values of the cookie named `name`, in order, or `None` when the
/// request has none. The cookies are read from the request at most once,
/// when a template first reads one.
fn Context::cookie_values(self : Context, name : String) -> Array[String]? {
  match self.cookies {
    Some(cookies) => cookies.get(name)
    None => {
      let cookies = @cookies.parse(self.input.headers)
      self.cookies = Some(cookies)
      cookies.get(name)
    }
  }
}

///|
/// What `steps` lead to from `json`, or `None` when they lead nowhere.
fn walk(json : Json, steps : Array[Step]) -> Json? {
  let mut at = json
  for step in steps {
    match (step, at) {
      (Name(name), Object(members)) =>
        match members.get(name) {
          Some(value) => at = value
          None => return None
        }
      (Index(i), Array(items)) if i < items.length() => at = items[i]
      _ => return None
    }
  }
  Some(at)
}

///|
/// The body parsed as JSON, or `None` when it is not JSON in UTF-8. It is
/// parsed at most once.
fn Context::parsed_body(self : Context) -> Json? {
  match self.body {
    Parsed(json) => return Some(json)
    NotJson => return None
    NotParsed => ()
  }
  self.body = try @json.parse(@utf8.decode(self.input.body)) catch {
    _ => NotJson
  } noraise {
    json => Parsed(json)
  }
  self.parsed_body()
}

///|
/// The JSON number `text`, if it is one: exactly JSON's number syntax, with
/// nothing around it.
fn number_of(text : String) -> Json? {
  let chars = text.iter().collect()
  let parser = {
    chars,
    i: 0,
    vars: [],
    in_loop: false,
    text: false,
    env: no_env,
  }
  let number = parser.number() catch { _ => return None }
  if parser.i == chars.length() {
    Some(number)
  } else {
    None
  }
}

///|
/// What kind of JSON value `json` is, for a message.
fn kind_of(json : Json) -> String {
  match json {
    Object(_) => "an object"
    Array(_) => "an array"
    String(_) => "a string"
    Number(_) => "a number"
    True | False => "a boolean"
    Null => "null"
  }
}

///|
/// The elements a `$each` over `expr` walks: an array, or every value of a
/// query parameter, a header or a cookie, none when it is absent. `Err`
/// gives the source text of the reference that names nothing.
fn Context::elements(
  self : Context,
  expr : Expr,
  frames : Array[Frame],
  at : String,
) -> Result[Array[Json], String] raise RenderError {
  match expr {
    Ref(Query, [Name(name)], _) =>
      Ok(
        self.input.query
        .filter(parameter => parameter.0 == name)
        .map(parameter => Json::string(parameter.1)),
      )
    Ref(Header, [Name(name)], _) =>
      Ok(header_values(self.input.headers, name).map(Json::string))
    Ref(Cookie, [Name(name)], _) =>
      match self.cookie_values(name) {
        Some(values) => Ok(values.map(Json::string))
        None => Ok([])
      }
    Fallback(alternatives) => {
      let mut last = ""
      for alternative in alternatives {
        match self.elements(alternative, frames, at) {
          Ok(elements) => return Ok(elements)
          Err(text) => last = text
        }
      }
      Err(last)
    }
    _ =>
      match self.eval(expr, frames, at) {
        Present({ json: Array(items), .. }) => Ok(items)
        Present({ json, .. }) =>
          raise RenderError(
            at~,
            message="$each walks an array, not \{kind_of(json)}",
          )
        Missing(text) => Err(text)
      }
  }
}

///|
/// Whether the condition holds. A missing value is never an error here: it
/// is false, and equals no literal.
fn Context::holds(
  self : Context,
  cond : Cond,
  frames : Array[Frame],
  at : String,
) -> Bool raise RenderError {
  let value = match self.eval(cond.expr, frames, at) {
    Present(value) => Some(value.json)
    Missing(_) => None
  }
  let base = match (cond.compare, value) {
    (None, Some(Null | False)) | (None, None) => false
    (None, Some(_)) => true
    (Some((equal, _)), None) => !equal
    (Some((equal, literal)), Some(json)) => same_scalar(json, literal) == equal
  }
  base != cond.negated
}

///|
/// Whether `json` equals the literal `literal`: strings exactly, numbers by
/// value, and a string never equals a number.
fn same_scalar(json : Json, literal : Json) -> Bool {
  match (json, literal) {
    (String(a), String(b)) => a == b
    (Number(a, repr=a_text), Number(b, repr=b_text)) =>
      match (a_text, b_text) {
        (Some(a_text), Some(b_text)) => a_text == b_text
        _ => a == b
      }
    (True, True) | (False, False) | (Null, Null) => true
    _ => false
  }
}

///|
/// Follows `$if`s from `node`: the node that gives the value, or `None`
/// when a false condition without `else` leaves it out.
fn Context::resolve(
  self : Context,
  node : Node,
  frames : Array[Frame],
) -> Node? raise RenderError {
  let mut node = node
  while node is If(cond, then, otherwise, at) {
    if self.holds(cond, frames, at) {
      node = then
    } else {
      match otherwise {
        Some(otherwise) => node = otherwise
        None => return None
      }
    }
  }
  Some(node)
}

///|
/// Writes `node`, which is not a `$if`, as compact JSON. `start` is the
/// output counted before `out`.
fn Context::write_node(
  self : Context,
  out : @buffer.Buffer,
  node : Node,
  frames : Array[Frame],
  start : Int,
) -> Unit raise RenderError {
  match node {
    Static(json) => write_json(out, json)
    Single(expr, at) => {
      write_json(out, self.value(expr, frames, at).json)
      check_output(start + out.length(), at)
    }
    Interpolated(parts, at) => {
      let text = StringBuilder()
      for part in parts {
        match part {
          Verbatim(literal) => text.write_string(literal)
          Insert(expr) =>
            text.write_string(
              as_text(self.value(expr, frames, at).json, at, text=false),
            )
        }
      }
      write_json(out, Json::string(text.to_string()))
      check_output(start + out.length(), at)
    }
    Members(members) => {
      out.write_byte(b'{')
      let mut first = true
      for entry in members {
        guard self.resolve(entry.1, frames) is Some(value) else { continue }
        if !first {
          out.write_byte(b',')
        }
        first = false
        write_json(out, Json::string(entry.0))
        out.write_byte(b':')
        self.write_node(out, value, frames, start)
      }
      out.write_byte(b'}')
    }
    Elements(elements) => {
      out.write_byte(b'[')
      let mut first = true
      for element in elements {
        guard self.resolve(element, frames) is Some(value) else { continue }
        if !first {
          out.write_byte(b',')
        }
        first = false
        self.write_node(out, value, frames, start)
      }
      out.write_byte(b']')
    }
    Each(expr, name, body, at) => {
      let items = match self.elements(expr, frames, at) {
        Ok(items) => items
        Err(text) => raise RenderError(at~, message="\{text} is missing")
      }
      out.write_byte(b'[')
      let mut first = true
      for index, element in items {
        self.iterations += 1
        if self.iterations > max_iterations {
          raise RenderError(
            at~,
            message="the loops of one response run at most \{max_iterations} iterations",
          )
        }
        let inner = [..frames, { name, element, index, }]
        guard self.resolve(body, inner) is Some(value) else { continue }
        if !first {
          out.write_byte(b',')
        }
        first = false
        self.write_node(out, value, inner, start)
      }
      out.write_byte(b']')
    }
    If(_, _, _, _) =>
      match self.resolve(node, frames) {
        Some(value) => self.write_node(out, value, frames, start)
        None => out.write_string_utf8("null")
      }
  }
}
