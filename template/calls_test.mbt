// Tests of calls through the template package's public interface: steps
// after a call, the bounds of range, the rules of the new helpers'
// arguments, and the bound on what a helper gives. They run on native and
// on wasm-gc, and give the same output on both.

///|
/// What the body template `source` renders for `input`, or its problem or
/// render error, on one line.
fn rendered(source : String, input? : @template.Input = request) -> String {
  match
    @template.Text::parse(source, pointer="/response/body", kind=Body(Plain)) {
    Ok(text) =>
      text.render(
        @template.Context::new(
          input,
          now=nine,
          rand=@template.helper_generator(1),
        ),
      ) catch {
        RenderError(at~, message~) => "error at \{at}: \{message}"
      }
    Err(problem) => "problem at \{problem.pointer}: \{problem.message}"
  }
}

///|
/// What the `json` template `source`, given as JSON, renders for `input`,
/// or its problems or render error, on one line.
fn rendered_json(source : String, input? : @template.Input = request) -> String {
  let source = @json.parse(source) catch { _ => abort("not JSON: \{source}") }
  match @template.Structured::parse(source, pointer="/response/json") {
    Ok(structured) => {
      let context = @template.Context::new(
        input,
        now=nine,
        rand=@template.helper_generator(1),
      )
      @utf8.decode_lossy(structured.render(context)) catch {
        RenderError(at~, message~) => "error at \{at}: \{message}"
      }
    }
    Err(problems) =>
      problems
      .map(problem => "problem at \{problem.pointer}: \{problem.message}")
      .join("; ")
  }
}

///|
test "a call may be followed by steps, as a reference may; a step into what is not an object or an array, or past its end, gives a missing value" {
  inspect(
    [
      rendered("${range(1, 3)[1]}"),
      rendered("${range(1, 3)[1] } ${ range (1, 3)[2] }"),
      rendered("${range(1, 3)[5] ?? 'past the end'}"),
      rendered("${range(1, 3).size ?? 'not an object'}"),
      rendered("${range(1, 3)['0'] ?? 'not an object'}"),
      rendered("${number(body.price).x ?? 'not an object'}"),
      rendered("${range(1, 3)[5]}"),
      rendered("${number(query.missing)[0]}"),
      rendered("${range(1, 3)[}"),
      rendered("${range(1, 3).}"),
      rendered_json("{ \"second\": \"${range(1, 3)[1]}\" }"),
      rendered_json(
        "{ \"$each\": \"range(1, 3)[0]\", \"as\": \"n\", \"do\": \"${n}\" }",
      ),
    ].join("\n"),
    content=(
      #|2
      #|2 3
      #|past the end
      #|not an object
      #|not an object
      #|not an object
      #|error at /response/body: range(1, 3)[5] is missing
      #|error at /response/body: query.missing is missing
      #|problem at /response/body: template: column 15: expected an index or a quoted name in [ ], found "}"
      #|problem at /response/body: template: column 15: expected a name after .
      #|{"second":2}
      #|error at /response/json/$each: $each walks an array, not a number
    ),
  )
}

///|
test "a bound of range may be any expression giving an integer, checked when rendering; literal bounds and the limit of 1000 values are checked when loading" {
  let each = (expr : String) => {
    rendered_json(
      "{ \"$each\": \{Json::string(expr).stringify()}, \"as\": \"n\", \"do\": \"${n}\" }",
    )
  }
  inspect(
    [
      each("range(body.items[0].qty, 3)"),
      each("range(body.items[1].qty ?? 5, body.items[0].qty)"),
      each("range(range(4, 6)[1], 6)"),
      each("range(number(query.n) ?? 1, 2)"),
      each("range(body.missing, 3)"),
      each("range(query.lang, 3)"),
      each("range(body.price, 10)"),
      each("range(1, body)"),
      each("range(1, number('9007199254740992'))"),
      each("range(body.items[0].qty, 1002)"),
      each("range('1', 3)"),
      each("range(1.5, 3)"),
      each("range(true, 3)"),
      each("range(1, -9007199254740992)"),
      each("range(body.x ?? null, 3)"),
      each("range(1, 1001)"),
    ].join("\n"),
    content=(
      #|[2,3]
      #|[0,1,2]
      #|[5,6]
      #|[1,2]
      #|error at /response/json/$each: body.missing is missing
      #|error at /response/json/$each: range() takes integers from -9007199254740991 to 9007199254740991, not "ja"
      #|error at /response/json/$each: range() takes integers from -9007199254740991 to 9007199254740991, not 9.9
      #|error at /response/json/$each: range() takes integers from -9007199254740991 to 9007199254740991, not an object
      #|error at /response/json/$each: range() takes integers from -9007199254740991 to 9007199254740991, not 9007199254740992
      #|error at /response/json/$each: range(2, 1002) gives 1001 values; range gives at most 1000
      #|problem at /response/json/$each: template: column 7: range() takes integers from -9007199254740991 to 9007199254740991, not "1"
      #|problem at /response/json/$each: template: column 7: range() takes integers from -9007199254740991 to 9007199254740991, not 1.5
      #|problem at /response/json/$each: template: column 7: range() takes integers from -9007199254740991 to 9007199254740991, not true
      #|problem at /response/json/$each: template: column 10: range() takes integers from -9007199254740991 to 9007199254740991, not -9007199254740992
      #|problem at /response/json/$each: template: column 7: range() takes integers from -9007199254740991 to 9007199254740991, not null
      #|problem at /response/json/$each: template: column 1: range(1, 1001) gives 1001 values; range gives at most 1000
    ),
  )
}

///|
/// A request whose body is `n` bytes of `x`.
fn of_size(n : Int) -> @template.Input {
  { ..request, body: @utf8.encode("x".repeat(n)), }
}

///|
test "a helper whose result takes more than 1 MiB of UTF-8 is a render error" {
  let half = 512 * 1024
  let length = (source : String, input : @template.Input) => {
    let out = rendered(source, input~)
    if out.has_prefix("error") {
      out
    } else {
      "\{out.length()} characters"
    }
  }
  inspect(
    [
      length("${concat(bodyText, bodyText)}", of_size(half)),
      length("${concat(bodyText, bodyText, 'x')}", of_size(half)),
      length("${len(concat(bodyText, bodyText, 'x'))}", of_size(half)),
      length("${padStart('x', 1048576)}", request),
      length("${padEnd('x', 1048577)}", request),
      length("${padStart('', 1048576, 'ab')}", request),
      length("${padEnd('x', 349526, '日')}", request),
      length("${padStart('x', 349527, '日')}", request),
      length("${padEnd(bodyText, 1)}", of_size(1024 * 1024)),
      length("${padEnd(bodyText, 1)}", of_size(1024 * 1024 + 1)),
    ].join("\n"),
    content=(
      #|1048576 characters
      #|error at /response/body: concat(): the result takes more than 1 MiB
      #|error at /response/body: concat(): the result takes more than 1 MiB
      #|1048576 characters
      #|error at /response/body: padEnd(): the result takes more than 1 MiB
      #|1048576 characters
      #|349526 characters
      #|error at /response/body: padStart(): the result takes more than 1 MiB
      #|1048576 characters
      #|error at /response/body: padEnd(): the result takes more than 1 MiB
    ),
  )
}
