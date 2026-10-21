// Tests of the `vars` root and of the values of Variables: `vars.NAME`
// reads the Variables a rendering is given, and `render_value` renders a
// Variable's value as JSON. They run on native and on wasm-gc, and give
// the same output on both.

///|
/// The Variables the tests below read.
let stored : Map[String, Json] = {
  "user": "ann",
  "cart": { "items": [{ "sku": "a-1", "qty": 2 }], "total": 12.5 },
  "nothing": null,
  "tags": ["x", "y"],
}

///|
/// A request with the body `{"user":"bob"}` and the cookie `id=7`.
let with_body : @template.Input = {
  meth: "POST",
  path: "/",
  query: [],
  headers: [("Cookie", "id=7")],
  body: b"{\"user\":\"bob\"}",
}

///|
/// Parses `source` as a structured template at `/variables/v`, as the value
/// of a Variable when `variable`, or gives its problems, one per line.
fn parsed(
  source : String,
  variable? : Bool = true,
) -> Result[@template.Structured, String] {
  let json = @json.parse(source) catch { _ => panic() }
  match @template.Structured::parse(json, pointer="/variables/v", variable~) {
    Ok(template) => Ok(template)
    Err(problems) =>
      Err(problems.map(p => "\{p.pointer}: \{p.message}").join("\n"))
  }
}

///|
/// Renders the structured template `source` reading `vars`, as a response's
/// `json`, or gives its problems or the render error.
fn with_vars(source : String, vars? : Map[String, Json]) -> String {
  match parsed(source, variable=false) {
    Ok(template) => {
      let context = @template.Context::new(
        with_body,
        now=0,
        rand=@template.helper_generator(1),
        vars?,
      )
      @utf8.decode_lossy(template.render(context)) catch {
        RenderError(at~, message~) => "error at \{at}: \{message}"
      }
    }
    Err(problems) => problems
  }
}

///|
test "vars.NAME reads a Variable, and steps go into its value; an unset name, or a step that leads nowhere, is missing" {
  let template =
    #|{ "user": "${vars.user}", "sku": "${vars.cart.items[0].sku}",
    #|  "total": "${vars['cart'].total}", "nothing": "${vars.nothing ?? 'unset'}",
    #|  "tags": { "$each": "vars.tags", "as": "t", "do": "${t}" },
    #|  "unset": "${vars.unset ?? 'unset'}", "nowhere": "${vars.user.x ?? 'nowhere'}",
    #|  "known": { "$if": "vars.user == 'ann'", "then": true, "else": false } }
  inspect(
    [
      with_vars(template, vars=stored),
      with_vars(template),
      with_vars("\"${vars.unset}\"", vars=stored),
    ].join("\n"),
    content=(
      #|{"user":"ann","sku":"a-1","total":12.5,"nothing":null,"tags":["x","y"],"unset":"unset","nowhere":"nowhere","known":true}
      #|error at /variables/v/user: vars.user is missing
      #|error at /variables/v: vars.unset is missing
    ),
  )
}

///|
test "vars takes the name of a Variable first, and cannot be a loop variable" {
  let problems = (source : String) => {
    match parsed(source) {
      Ok(_) => "parses"
      Err(problems) => problems
    }
  }
  inspect(
    [
      problems("\"${vars}\""),
      problems("\"${vars[0]}\""),
      problems("\"${vars ?? 1}\""),
      problems("{ \"$each\": \"range(1, 2)\", \"as\": \"vars\", \"do\": 1 }"),
      problems("\"${vars['any name'] ?? vars.x-1.y[2] ?? 0}\""),
    ].join("\n"),
    content=(
      #|/variables/v: template: column 3: vars: vars takes the name of a Variable first, such as vars.count or vars.cart.items[0]
      #|/variables/v: template: column 3: vars[0]: vars takes the name of a Variable first, such as vars.count or vars.cart.items[0]
      #|/variables/v: template: column 3: vars: vars takes the name of a Variable first, such as vars.count or vars.cart.items[0]
      #|/variables/v/as: template: "vars" cannot be a loop variable: it is a request field, env, vars, loop or a reserved word
      #|parses
    ),
  )
}

///|
test "the value of a Variable is rendered as JSON, its numbers keeping their text, and its root $if needs else" {
  let value = (source : String) => {
    match parsed(source) {
      Ok(template) => {
        let context = @template.Context::new(
          with_body,
          now=0,
          rand=@template.helper_generator(1),
          vars=stored,
        )
        let json = template.render_value(context) catch {
          RenderError(at~, message~) => return "error at \{at}: \{message}"
        }
        @template.compact_json(json) + " (" + @debug.to_string(json) + ")"
      }
      Err(problems) => problems
    }
  }
  inspect(
    [
      value("\"${fake.decimal(1, 1, 2)}\""),
      value("12345678901234567890"),
      value("\"$${not a template} ${body.user}\""),
      value(
        "{ \"was\": \"${vars.user}\", \"now\": \"${body.user}\", \"quote\": \"\\\"\\t\\u0001é\" }",
      ),
      value("{ \"$if\": \"body.user\", \"then\": [1, true, null] }"),
      value(
        "{ \"$if\": \"body.user\", \"then\": [1, true, null], \"else\": [] }",
      ),
    ].join("\n"),
    content=(
      #|1.00 (Number(1, repr=Some("1.00")))
      #|12345678901234567890 (Number(12345678901234567000, repr=Some("12345678901234567890")))
      #|"${not a template} bob" (String("${not a template} bob"))
      #|{"was":"ann","now":"bob","quote":"\"\t\u0001é"} (Object(
      #|  {
      #|    "was": String("ann"),
      #|    "now": String("bob"),
      #|    "quote": String("\"\t\u{01}é"),
      #|  },
      #|))
      #|/variables/v: template: a $if at the root of a Variable's value needs "else", so that it always gives a value
      #|[1,true,null] (Array([Number(1), True, Null]))
    ),
  )
}

///|
test "the value of a Variable is bounded as a rendered body is, and says so" {
  let value = (source : String) => {
    match parsed(source) {
      Ok(template) => {
        let context = @template.Context::new(
          { ..with_body, query: [("n", "11"), ("text", "x".repeat(1100))], },
          now=0,
          rand=@template.helper_generator(1),
        )
        ignore(
          template.render_value(context) catch {
            RenderError(at~, message~) => return "error at \{at}: \{message}"
          },
        )
        "rendered"
      }
      Err(problems) => problems
    }
  }
  inspect(
    [
      value(
        "{ \"$each\": \"range(1, 1000)\", \"as\": \"i\", \"do\": \"${query.text}\" }",
      ),
      value(
        "{ \"$each\": \"range(1, number(query.n))\", \"as\": \"i\", \"do\": { \"$each\": \"range(1, 1000)\", \"as\": \"j\", \"do\": 1 } }",
      ),
      value(
        "{ \"$each\": \"range(1, 1000)\", \"as\": \"i\", \"do\": { \"$each\": \"range(1, 11)\", \"as\": \"j\", \"do\": 1 } }",
      ),
    ].join("\n"),
    content=(
      #|error at /variables/v/do: the rendered value takes more than 1 MiB
      #|error at /variables/v/do/$each: the loops of one value run at most 10000 iterations
      #|/variables/v: template: its loops run at least 12000 times; one value runs at most 10000 loop iterations
    ),
  )
}

///|
test "the next rendering for a request reads its own Variables, draws on from the helper generator and reads the same request" {
  let first = @template.Context::new(
    with_body,
    now=0,
    rand=@template.helper_generator(1),
    vars=stored,
  )
  let render = (source : String, context : @template.Context) => {
    let template = parsed(source, variable=false).unwrap()
    @utf8.decode_lossy(template.render(context)) catch {
      RenderError(at~, message~) => "error at \{at}: \{message}"
    }
  }
  let uuid = "\"${fake.uuid()} ${vars.user ?? 'none'} ${cookie.id}\""
  let both = render("[\{uuid}, \{uuid}]", first)
  let one = render(uuid, first.next(vars=stored))
  let fresh = @template.Context::new(
    with_body,
    now=0,
    rand=@template.helper_generator(1),
    vars=stored,
  )
  let a = render(uuid, fresh)
  let b = render(uuid, fresh.next())
  inspect(
    [both, one, "[\{a},\{b}]"].join("\n"),
    content=(
      #|["55c4f5c9-13b3-4f99-8767-9344f82c6c97 ann 7","487e8d42-6941-41db-9afa-a56527c48a1f ann 7"]
      #|"5794799f-26b1-4a04-be6e-abe069f6d1c0 ann 7"
      #|["55c4f5c9-13b3-4f99-8767-9344f82c6c97 ann 7","487e8d42-6941-41db-9afa-a56527c48a1f none 7"]
    ),
  )
}

///|
test "a template knows whether it reads vars, wherever it does" {
  let structured = (source : String) => {
    match parsed(source, variable=false) {
      Ok(template) => "\{template.reads_vars()} \{source}"
      Err(problems) => problems
    }
  }
  let text = (source : String) => {
    match @template.Text::parse(source, pointer="/h", kind=HeaderValue) {
      Ok(template) => "\{template.reads_vars()} \{source}"
      Err(problem) => problem.message
    }
  }
  inspect(
    [
      text("plain"),
      text("${query.a ?? 'none'} $${vars.x}"),
      text("${vars.x}"),
      text("${query.a ?? vars.x ?? 0}"),
      text("${len(concat('a', vars.x ?? ''))}"),
      structured("{ \"a\": \"${body.x}\", \"b\": [1, \"${len('x')}\"] }"),
      structured("{ \"a\": [1, { \"b\": \"${vars.x ?? 0}\" }] }"),
      structured(
        "{ \"$each\": \"vars.tags\", \"as\": \"t\", \"do\": \"${t}\" }",
      ),
      structured(
        "{ \"$each\": \"range(1, 2)\", \"as\": \"t\", \"do\": \"${vars.x}\" }",
      ),
      structured("{ \"$if\": \"vars.x == 1\", \"then\": 1, \"else\": 2 }"),
      structured(
        "{ \"$if\": \"query.x\", \"then\": 1, \"else\": \"${vars.x}\" }",
      ),
    ].join("\n"),
    content=(
      #|false plain
      #|false ${query.a ?? 'none'} $${vars.x}
      #|true ${vars.x}
      #|true ${query.a ?? vars.x ?? 0}
      #|true ${len(concat('a', vars.x ?? ''))}
      #|false { "a": "${body.x}", "b": [1, "${len('x')}"] }
      #|true { "a": [1, { "b": "${vars.x ?? 0}" }] }
      #|true { "$each": "vars.tags", "as": "t", "do": "${t}" }
      #|true { "$each": "range(1, 2)", "as": "t", "do": "${vars.x}" }
      #|true { "$if": "vars.x == 1", "then": 1, "else": 2 }
      #|true { "$if": "query.x", "then": 1, "else": "${vars.x}" }
    ),
  )
}
