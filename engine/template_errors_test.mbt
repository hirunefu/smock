// Seam 1 tests of template errors found when a definition set is loaded or
// an Ephemeral Stub is added: what `smock check` prints, what stops
// `smock serve` at startup, and what keeps a reload from swapping.

///|
/// The problems in a definition set of one file `m.yaml`, holding Mock `m`
/// and the Stubs `stubs` (YAML, each indented as an element of `stubs`),
/// with the body files `body_files`, one per line as `smock check` prints
/// them; or `valid`.
fn template_problems(
  stubs : String,
  body_files? : Array[(String, Bytes)] = [],
) -> String {
  let set : @definitions.DefinitionSet = {
    files: [("m.yaml", @utf8.encode("mocks:\n  - name: m\nstubs:\n\{stubs}"))],
    body_files,
  }
  match @definitions.load(set) {
    Ok(_) => "valid"
    Err(problems) => problems.map(problem => problem.to_string()).join("\n")
  }
}

///|
/// A Stub `s<i>` with `template` on and the response members `members`,
/// given in YAML flow style.
fn templated(i : Int, members : String) -> String {
  "  - { id: s\{i}, mock: m, response: { status: 200, template: true, \{members} } }\n"
}

///|
test "a text template that does not parse is reported with the file, the JSON Pointer of the field and the column of the problem" {
  let bodies = [
    "abc ${query.x", "${}", "${ }", "${query.}", "${query.x query.y}", "${user.id}",
    "${item.sku}", "${fake.phone()}", "${fake.int(1)}", "${now(1, 2)}", "${fake.int('a', 2)}",
    "${fake.int(5, 1)}", "${fake.int(1.5, 2)}", "${fake.int(query.a, 2)}", "${fake.hex(65)}",
    "${fake.decimal(1, 2, 7)}", "${fake.decimal(-1000000001, 0, 2)}", "${fake.pick()}",
    "${fake.pick(query.a)}", "${fake.words(0)}", "${for x in body.items}", "${if body.a}",
    "${params.id}", "${loop.index}", "${path.x}", "${path[1].x}", "${query}", "${query.a.b}",
    "${header[0]}", "${method.x}", "${bodyText[0]}", "${'open}", "${'a\\nb'}", "${007}",
    "${1.}", "${body.a == 1}", "${!body.a}", "${range(query.a, 3)}", "${range(1, 1001)}",
    "${number()}", "${json(body, 1)}", "${body[01]}", "${body[}", "${query['a'}",
  ]
  inspect(
    template_problems(
      bodies
      .mapi((i, body) => templated(i, "body: \{Json::string(body).stringify()}"))
      .join(""),
    ),
    content=(
      #|m.yaml: /stubs/0/response/body: template: column 5: the ${ is not closed
      #|m.yaml: /stubs/1/response/body: template: column 1: the ${ } is empty
      #|m.yaml: /stubs/2/response/body: template: column 1: the ${ } is empty
      #|m.yaml: /stubs/3/response/body: template: column 9: expected a name after .
      #|m.yaml: /stubs/4/response/body: template: column 11: expected } to end the ${, found "q"
      #|m.yaml: /stubs/5/response/body: template: column 3: unknown name "user": not a request field, a loop variable or a helper
      #|m.yaml: /stubs/6/response/body: template: column 3: unknown name "item": not a request field, a loop variable or a helper
      #|m.yaml: /stubs/7/response/body: template: column 3: unknown helper "fake.phone": not one of the helpers smock has
      #|m.yaml: /stubs/8/response/body: template: column 3: fake.int() takes 2 arguments, not 1
      #|m.yaml: /stubs/9/response/body: template: column 3: now() takes 0 or 1 argument, not 2
      #|m.yaml: /stubs/10/response/body: template: column 12: fake.int(): argument 1 must be an integer literal from -9007199254740991 to 9007199254740991
      #|m.yaml: /stubs/11/response/body: template: column 3: fake.int(): the minimum 5 exceeds the maximum 1
      #|m.yaml: /stubs/12/response/body: template: column 12: fake.int(): argument 1 must be an integer literal from -9007199254740991 to 9007199254740991
      #|m.yaml: /stubs/13/response/body: template: column 12: fake.int(): argument 1 must be an integer literal from -9007199254740991 to 9007199254740991
      #|m.yaml: /stubs/14/response/body: template: column 12: fake.hex(): argument 1 must be an integer literal from 1 to 64
      #|m.yaml: /stubs/15/response/body: template: column 22: fake.decimal(): argument 3 must be an integer literal from 1 to 6
      #|m.yaml: /stubs/16/response/body: template: column 16: fake.decimal(): argument 1 must be an integer literal from -1000000000 to 1000000000
      #|m.yaml: /stubs/17/response/body: template: column 3: fake.pick() takes 1 to 100 literals, not 0
      #|m.yaml: /stubs/18/response/body: template: column 13: fake.pick() takes literals: strings, numbers, true, false or null
      #|m.yaml: /stubs/19/response/body: template: column 14: fake.words(): argument 1 must be an integer literal from 1 to 100
      #|m.yaml: /stubs/20/response/body: template: column 3: for is reserved
      #|m.yaml: /stubs/21/response/body: template: column 3: if is reserved
      #|m.yaml: /stubs/22/response/body: template: column 3: params is reserved
      #|m.yaml: /stubs/23/response/body: template: column 3: loop.index is only inside $each
      #|m.yaml: /stubs/24/response/body: template: column 3: path.x: path takes a segment number only, such as path[1]
      #|m.yaml: /stubs/25/response/body: template: column 3: path[1].x: path takes a segment number only, such as path[1]
      #|m.yaml: /stubs/26/response/body: template: column 3: query: query takes exactly one name, such as query.x or query['x y']
      #|m.yaml: /stubs/27/response/body: template: column 3: query.a.b: query takes exactly one name, such as query.x or query['x y']
      #|m.yaml: /stubs/28/response/body: template: column 3: header[0]: header takes exactly one name, such as header.x or header['x y']
      #|m.yaml: /stubs/29/response/body: template: column 3: method.x: method has no parts to name
      #|m.yaml: /stubs/30/response/body: template: column 3: bodyText[0]: bodyText has no parts to name
      #|m.yaml: /stubs/31/response/body: template: column 3: the string is not closed
      #|m.yaml: /stubs/32/response/body: template: column 5: a string has only the escapes \', \" and \\
      #|m.yaml: /stubs/33/response/body: template: column 3: a number has no leading zeros
      #|m.yaml: /stubs/34/response/body: template: column 3: expected digits after the decimal point
      #|m.yaml: /stubs/35/response/body: template: column 10: == and != are allowed only in the condition of $if
      #|m.yaml: /stubs/36/response/body: template: column 3: !, == and != are allowed only in the condition of $if
      #|m.yaml: /stubs/37/response/body: template: column 9: range() takes integers: integer literals, or number(…) of a request value
      #|m.yaml: /stubs/38/response/body: template: column 3: range(1, 1001) gives 1001 values; range gives at most 1000
      #|m.yaml: /stubs/39/response/body: template: column 3: number() takes 1 argument, not 0
      #|m.yaml: /stubs/40/response/body: template: column 3: json() takes 1 argument, not 2
      #|m.yaml: /stubs/41/response/body: template: column 8: an index is an integer from 0 to 999999999
      #|m.yaml: /stubs/42/response/body: template: column 8: expected an index or a quoted name in [ ], found "}"
      #|m.yaml: /stubs/43/response/body: template: column 12: expected ], found "}"
    ),
  )
}

///|
test "a template of several lines is reported with the line and the column of the problem, and a body file with the pointer of bodyFile" {
  inspect(
    template_problems(
      (
        #|  - id: inline
        #|    mock: m
        #|    response:
        #|      status: 200
        #|      template: true
        #|      body: |
        #|        Hello,
        #|          ${query.name ?? 'guest}
        #|  - id: from-file
        #|    mock: m
        #|    response: { status: 200, template: true, bodyFile: pages/hello.html }
        #|  - id: binary
        #|    mock: m
        #|    response: { status: 200, template: true, bodyFile: logo.png }
        #|  - id: binary-static
        #|    mock: m
        #|    response: { status: 200, bodyFile: logo.png }
      ),
      body_files=[
        (
          "pages/hello.html", b"<h1>\n  ${fake.name()}\n  ${fake.nickname()}\n</h1>\n",
        ),
        ("logo.png", b"\x89PNG\r\n\x1a\n${x}"),
      ],
    ),
    content=(
      #|m.yaml: /stubs/0/response/body: template: line 2, column 19: the string is not closed
      #|m.yaml: /stubs/1/response/bodyFile: template: line 3, column 5: unknown helper "fake.nickname": not one of the helpers smock has
      #|m.yaml: /stubs/2/response/bodyFile: template: the body file is not UTF-8, so it cannot be a template
    ),
  )
}

///|
test "a header value is a text template, but Content-Type is never templated" {
  inspect(
    template_problems(
      [
        templated(0, "headers: { X-A: \"${query.}\", X-B: \"${query.b}\" }"),
        templated(1, "headers: { Content-Type: \"text/${query.type}\" }"),
        templated(2, "headers: { content-type: \"text/plain; a=$${b}\" }"),
        templated(
          3, "headers: { Content-Type: text/plain }, body: \"$x ${query.x}\"",
        ),
      ].join(""),
    ),
    content=(
      #|m.yaml: /stubs/0/response/headers/X-A: template: column 9: expected a name after .
      #|m.yaml: /stubs/1/response/headers/Content-Type: template: Content-Type is never templated, so it cannot contain ${
      #|m.yaml: /stubs/2/response/headers/content-type: template: Content-Type is never templated, so it cannot contain ${
    ),
  )
}

///|
test "each value of a header given an array is its own text template, reported at its own JSON Pointer" {
  inspect(
    template_problems(
      templated(
        0, "headers: { Set-Cookie: [\"a=${query.a}\", \"b=${query.}\", \"c=${\"] }",
      ),
    ),
    content=(
      #|m.yaml: /stubs/0/response/headers/Set-Cookie/1: template: column 11: expected a name after .
      #|m.yaml: /stubs/0/response/headers/Set-Cookie/2: template: column 3: the ${ is not closed
    ),
  )
}

///|
test "a structured template that does not parse is reported at the JSON Pointer of the value, every problem in it" {
  inspect(
    template_problems(
      (
        #|  - id: s
        #|    mock: m
        #|    response:
        #|      status: 200
        #|      template: true
        #|      json:
        #|        a: ${query.}
        #|        b: { $each: body.items, do: 1 }
        #|        c: { $each: body.items, as: i }
        #|        d: { $each: body.items, as: i, do: 1, where: x }
        #|        e: { $if: body.a }
        #|        f: { $if: body.a, then: 1, otherwise: 2 }
        #|        g: { $each: "${body.items}", as: i, do: 1 }
        #|        h: { $each: body.items, as: body, do: 1 }
        #|        i: { $each: body.items, as: loop, do: 1 }
        #|        j: { $each: body.items, as: for, do: 1 }
        #|        k: { $each: body.items, as: "a b", do: 1 }
        #|        l: { $each: 7, as: i, do: 1 }
        #|        m: { $each: body.items, as: i, do: "${i.x} ${j.x}" }
        #|        n1: "${i.x}"
        #|        o: { $foo: 1, $$bar: 2, "a${b}": 3, "$${c}": 4 }
        #|        p: "${json(body)}"
        #|        q: "x ${raw(query.a)}"
        #|        r: { $if: "body.a ==", then: 1 }
        #|        s: { $if: "body.a == body.b", then: 1 }
        #|        t: { $if: "body.a b", then: 1 }
        #|        u: { $each: "range(1, 1001)", as: i, do: 1 }
        #|        v: [ { $if: body.a, then: 1 } ]
        #|        w: { $each: body.items, as: i, do: { $if: "loop.index == 0", then: "${loop.index}" } }
        #|  - id: root-if
        #|    mock: m
        #|    response:
        #|      status: 200
        #|      template: true
        #|      json: { $if: body.a, then: 1 }
        #|  - id: root-if-nested
        #|    mock: m
        #|    response:
        #|      status: 200
        #|      template: true
        #|      json: { $if: body.a, then: { $if: body.b, then: 1 }, else: 2 }
        #|  - id: event
        #|    mock: m
        #|    response:
        #|      status: 200
        #|      template: true
        #|      events:
        #|        - { event: "${query.}", id: "${x}", data: "${y}" }
        #|        - { json: { $if: body.a, then: 1 } }
        #|  - id: too-many-iterations
        #|    mock: m
        #|    response:
        #|      status: 200
        #|      template: true
        #|      json:
        #|        $each: range(1, 101)
        #|        as: i
        #|        do: { $each: "range(1, 100)", as: j, do: "${i}.${j}" }
      ),
    ),
    content=(
      #|m.yaml: /stubs/0/response/json/a: template: column 9: expected a name after .
      #|m.yaml: /stubs/0/response/json/b: template: a $each needs "as" and "do"
      #|m.yaml: /stubs/0/response/json/c: template: a $each needs "as" and "do"
      #|m.yaml: /stubs/0/response/json/d/where: template: an object with "$each" has only "$each", "as", "do"
      #|m.yaml: /stubs/0/response/json/e: template: a $if needs "then"
      #|m.yaml: /stubs/0/response/json/f/otherwise: template: an object with "$if" has only "$if", "then", "else"
      #|m.yaml: /stubs/0/response/json/g/$each: template: column 1: write the expression of $each without ${ }, such as $each: body.items
      #|m.yaml: /stubs/0/response/json/h/as: template: "body" cannot be a loop variable: it is a request field, env, loop or a reserved word
      #|m.yaml: /stubs/0/response/json/i/as: template: "loop" cannot be a loop variable: it is a request field, env, loop or a reserved word
      #|m.yaml: /stubs/0/response/json/j/as: template: "for" cannot be a loop variable: it is a request field, env, loop or a reserved word
      #|m.yaml: /stubs/0/response/json/k/as: template: a loop variable is a name of letters, digits, _ and -, starting with a letter or _
      #|m.yaml: /stubs/0/response/json/l/$each: template: "$each" must be a string
      #|m.yaml: /stubs/0/response/json/m/do: template: column 10: unknown name "j": not a request field, a loop variable or a helper
      #|m.yaml: /stubs/0/response/json/n1: template: column 3: unknown name "i": not a request field, a loop variable or a helper
      #|m.yaml: /stubs/0/response/json/o/$foo: template: "$foo" is reserved; write $$foo for a key that starts with $
      #|m.yaml: /stubs/0/response/json/o/a${b}: template: ${ in a key: keys are never templated
      #|m.yaml: /stubs/0/response/json/o/$${c}: template: ${ in a key: keys are never templated
      #|m.yaml: /stubs/0/response/json/p: template: column 3: json() is for text templates; in json, smock writes and escapes every value itself
      #|m.yaml: /stubs/0/response/json/q: template: column 5: raw() is for text templates; in json, smock writes and escapes every value itself
      #|m.yaml: /stubs/0/response/json/r/$if: template: column 10: expected a value, found the end
      #|m.yaml: /stubs/0/response/json/s/$if: template: column 11: == compares with a literal: a string, a number, true, false or null
      #|m.yaml: /stubs/0/response/json/t/$if: template: column 8: expected the expression to end, found "b"
      #|m.yaml: /stubs/0/response/json/u/$each: template: column 1: range(1, 1001) gives 1001 values; range gives at most 1000
      #|m.yaml: /stubs/1/response/json: template: a $if at the root of json needs "else", so that it always gives a value
      #|m.yaml: /stubs/2/response/json/then: template: a $if at the root of json needs "else", so that it always gives a value
      #|m.yaml: /stubs/3/response/events/0/event: template: column 9: expected a name after .
      #|m.yaml: /stubs/3/response/events/0/id: template: column 3: unknown name "x": not a request field, a loop variable or a helper
      #|m.yaml: /stubs/3/response/events/0/data: template: column 3: unknown name "y": not a request field, a loop variable or a helper
      #|m.yaml: /stubs/3/response/events/1/json: template: a $if at the root of json needs "else", so that it always gives a value
      #|m.yaml: /stubs/4/response/json: template: its loops run at least 10201 times; one response runs at most 10000 loop iterations
    ),
  )
}

///|
test "cookie takes exactly one name, as query does, and a loop variable cannot be named cookie" {
  inspect(
    template_problems(
      (
        #|  - id: s
        #|    mock: m
        #|    response:
        #|      status: 200
        #|      template: true
        #|      headers: { X-Session: "${cookie}" }
        #|      json:
        #|        a: ${cookie.a.b}
        #|        b: ${cookie[0]}
        #|        c: "${cookie['a'] ?? cookie}"
        #|        d: { $each: cookie, as: c, do: "${c}" }
        #|        e: { $each: cookie.theme, as: cookie, do: "${cookie}" }
        #|        f: { $each: body.items, as: Cookie, do: "${Cookie.name}" }
        #|        g: "${cookie.a} ${cookie['a b']} ${cookie.A-b_1}"
      ),
    ),
    content=(
      #|m.yaml: /stubs/0/response/headers/X-Session: template: column 3: cookie: cookie takes exactly one name, such as cookie.x or cookie['x y']
      #|m.yaml: /stubs/0/response/json/a: template: column 3: cookie.a.b: cookie takes exactly one name, such as cookie.x or cookie['x y']
      #|m.yaml: /stubs/0/response/json/b: template: column 3: cookie[0]: cookie takes exactly one name, such as cookie.x or cookie['x y']
      #|m.yaml: /stubs/0/response/json/c: template: column 18: cookie: cookie takes exactly one name, such as cookie.x or cookie['x y']
      #|m.yaml: /stubs/0/response/json/d/$each: template: column 1: cookie: cookie takes exactly one name, such as cookie.x or cookie['x y']
      #|m.yaml: /stubs/0/response/json/e/as: template: "cookie" cannot be a loop variable: it is a request field, env, loop or a reserved word
    ),
  )
}

///|
/// A response whose templates have a problem in each kind of field.
let broken_response : String =
  #|{ "status": 200, "template": true,
  #|  "headers": { "X-A": "${query.}", "Content-Type": "text/${x}" },
  #|  "json": { "a": "${fake.nope()}", "b": { "$each": "body.items" } } }

///|
test "an Ephemeral Stub's templates are parsed when it is added, with the messages a Stub in a Definition file gets" {
  let file_problems = template_problems(
    "  - { id: s, mock: m, response: \{broken_response.replace_all(old="\n", new="")} }\n",
  )
  let h = harness([("m.yaml", "mocks:\n  - name: m\n")])
  let ephemeral_problems = try
    h.engine.add_ephemeral_stub(
      mock="m",
      session=None,
      @json.parse("{ \"response\": \{broken_response} }"),
    )
  catch {
    @engine.AdminError::InvalidStub(problems) =>
      problems.map(problem => problem.to_string()).join("\n")
    err => @debug.to_string(err)
  } noraise {
    added => "added \{added.id}"
  }
  inspect(
    "Definition file:\n\{file_problems}\nEphemeral Stub:\n\{ephemeral_problems}",
    content=(
      #|Definition file:
      #|m.yaml: /stubs/0/response/headers/X-A: template: column 9: expected a name after .
      #|m.yaml: /stubs/0/response/headers/Content-Type: template: Content-Type is never templated, so it cannot contain ${
      #|m.yaml: /stubs/0/response/json/a: template: column 3: unknown helper "fake.nope": not one of the helpers smock has
      #|m.yaml: /stubs/0/response/json/b: template: a $each needs "as" and "do"
      #|Ephemeral Stub:
      #|/response/headers/X-A: template: column 9: expected a name after .
      #|/response/headers/Content-Type: template: Content-Type is never templated, so it cannot contain ${
      #|/response/json/a: template: column 3: unknown helper "fake.nope": not one of the helpers smock has
      #|/response/json/b: template: a $each needs "as" and "do"
    ),
  )
}

///|
test "an Ephemeral Stub with templates renders them for each request of its Session" {
  let h = harness([("m.yaml", "mocks:\n  - name: m\n")])
  let added = h.engine.add_ephemeral_stub(
    mock="m",
    session=Some("test-a"),
    @json.parse(
      (
        #|{ "response": { "status": 200, "template": true,
        #|  "json": { "hello": "${query.name ?? 'world'}", "session": "${header.baggage}" } } }
      ),
    ),
  )
  inspect(added.id, content="eph-1")
  inspect(
    response(
      h.send(
        "GET",
        "/?name=Ada",
        headers=[("baggage", "smock-session=test-a")],
        session="test-a",
      ),
    ),
    content=(
      #|200
      #|Content-Type: application/json
      #|Smock-Mock: m; via=default
      #|{"hello":"Ada","session":"smock-session=test-a"}
    ),
  )
}

///|
test "a reload whose new set has a template error keeps the current snapshot and reports the error" {
  let h = harness([get_user_example])
  let served = h.engine.status().digest
  let result = h.engine.reload(
    {
      files: [
        (
          "users.yaml",
          @utf8.encode(
            get_user_example.1.replace(old="${path[1]}", new="${path[}"),
          ),
        ),
      ],
      body_files: [],
    },
    at=1_791_815_460_000L,
  )
  inspect(
    "\{@debug.to_string(result.result)}, serving \{h.engine.status().digest == served}\n\{result.errors.map(e => e.to_string()).join("\n")}",
    content=(
      #|Failed, serving true
      #|users.yaml: /stubs/0/response/json/id: template: column 8: expected an index or a quoted name in [ ], found "}"
    ),
  )
  inspect(
    response(h.send("GET", "/users/7")),
    content=(
      #|200
      #|X-Request-Id: none
      #|Content-Type: application/json
      #|Smock-Mock: users; via=default
      #|{"id":"7","lang":"en","requestId":"none"}
    ),
  )
}
