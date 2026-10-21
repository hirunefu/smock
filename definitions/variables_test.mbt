// Reading a Stub's `variables`: an object that maps the names of
// Variables to their values, each a structured template, parsed whether or
// not a response has `template` on.

///|
/// Loads the Definition file `a.yaml`, holding Mock `m` and the Stubs
/// `stubs`, given as YAML list items, and renders every diagnostic, one
/// per line, or `valid`.
fn variable_problems(stubs : String) -> String {
  let file = "mocks:\n  - name: m\nstubs:\n\{stubs}"
  let set : @definitions.DefinitionSet = {
    files: [("a.yaml", @utf8.encode(file))],
    body_files: [],
  }
  match @definitions.load(set) {
    Ok(_) => "valid"
    Err(diagnostics) => diagnostics.map(d => d.to_string()).join("\n")
  }
}

///|
test "variables beside response or responses take any JSON value, a template or not, and names of 1 to 128 name characters" {
  let long = "v".repeat(128)
  inspect(
    variable_problems(
      (
        $|  - id: a
        $|    mock: m
        $|    variables:
        $|      plain: text
        $|      number: 1.5
        $|      boolean: false
        $|      nothing: null
        $|      object: { a: [1, "${query.a}"] }
        $|      Name_with-9: ${vars.Name_with-9 ?? 0}
        $|      "9": $${not a template}
        $|      \{long}: ${body ?? null}
        $|    response: { status: 200 }
        $|  - id: b
        $|    mock: m
        $|    variables: {}
        $|    responses: [{ status: 200 }, { status: 503 }]
      ),
    ),
    content="valid",
  )
}

///|
test "a name that is empty, too long or has other characters, variables that are not an object, and a value that does not parse are load errors at their JSON Pointer" {
  let long = "v".repeat(129)
  inspect(
    variable_problems(
      (
        $|  - id: names
        $|    mock: m
        $|    variables:
        $|      "": 1
        $|      \{long}: 2
        $|      a.b: 3
        $|      a b: 4
        $|      é: 5
        $|      ok: 6
        $|    response: { status: 200 }
        $|  - id: not-an-object
        $|    mock: m
        $|    variables: [a, b]
        $|    response: { status: 200 }
        $|  - id: templates
        $|    mock: m
        $|    variables:
        $|      syntax: ${query.a
        $|      helper: { at: "${fake.nope()}" }
        $|      root-if: { $if: query.a, then: 1 }
        $|      vars: ${vars}
        $|      vars-index: ${vars[0]}
        $|      loop: { $each: "range(1, 2)", as: vars, do: 1 }
        $|      loops: { $each: "range(1, 1000)", as: i, do: { $each: "range(1, 10)", as: j, do: 1 } }
        $|    response: { status: 200 }
      ),
    ),
    content=(
      #|a.yaml: /stubs/0/variables/: is not a Variable name: 1 to 128 ASCII letters, digits, _ and -
      #|a.yaml: /stubs/0/variables/vvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvvv: is not a Variable name: 1 to 128 ASCII letters, digits, _ and -
      #|a.yaml: /stubs/0/variables/a.b: is not a Variable name: 1 to 128 ASCII letters, digits, _ and -
      #|a.yaml: /stubs/0/variables/a b: is not a Variable name: 1 to 128 ASCII letters, digits, _ and -
      #|a.yaml: /stubs/0/variables/é: is not a Variable name: 1 to 128 ASCII letters, digits, _ and -
      #|a.yaml: /stubs/1/variables: must be an object
      #|a.yaml: /stubs/2/variables/syntax: template: column 1: the ${ is not closed
      #|a.yaml: /stubs/2/variables/helper/at: template: column 3: unknown helper "fake.nope": not one of the helpers smock has
      #|a.yaml: /stubs/2/variables/root-if: template: a $if at the root of a Variable's value needs "else", so that it always gives a value
      #|a.yaml: /stubs/2/variables/vars: template: column 3: vars: vars takes the name of a Variable first, such as vars.count or vars.cart.items[0]
      #|a.yaml: /stubs/2/variables/vars-index: template: column 3: vars[0]: vars takes the name of a Variable first, such as vars.count or vars.cart.items[0]
      #|a.yaml: /stubs/2/variables/loop/as: template: "vars" cannot be a loop variable: it is a request field, env, vars, loop or a reserved word
      #|a.yaml: /stubs/2/variables/loops: template: its loops run at least 11000 times; one value runs at most 10000 loop iterations
    ),
  )
}

///|
test "a response reads Variables when one of its templates reads vars: a header, the body, its json or an event" {
  let file =
    #|mocks:
    #|  - name: m
    #|stubs:
    #|  - id: static
    #|    mock: m
    #|    response: { status: 200, body: "${vars.x}" }
    #|  - id: plain
    #|    mock: m
    #|    variables: { x: "${vars.x ?? 0}" }
    #|    response:
    #|      status: 200
    #|      template: true
    #|      headers: { A: "${query.a ?? ''}" }
    #|      json: { a: "${path}", b: "$${vars.x}" }
    #|  - id: reads
    #|    mock: m
    #|    responses:
    #|      - { status: 200, template: true, headers: { A: "${vars.x ?? ''}" } }
    #|      - { status: 200, template: true, body: "${vars.x ?? ''}" }
    #|      - status: 200
    #|        template: true
    #|        json: { $each: "range(1, 2)", as: i, do: "${vars.x ?? i}" }
    #|      - status: 200
    #|        template: true
    #|        events: [{ data: "a" }, { id: "${vars.x ?? 1}", data: "b" }]
    #|      - status: 200
    #|        template: true
    #|        events: [{ json: { x: "${vars.x ?? 1}" } }]
    #|      - status: 200
    #|        template: true
    #|        events: [{ event: "${path}", data: "a" }]
  let set : @definitions.DefinitionSet = {
    files: [("a.yaml", @utf8.encode(file))],
    body_files: [],
  }
  let snapshot = match @definitions.load(set) {
    Ok(snapshot) => snapshot
    Err(diagnostics) => fail(diagnostics.map(d => d.to_string()).join("\n"))
  }
  let out = []
  for stub in snapshot.mocks[0].stubs {
    let Ordinary(ordinary) = stub.serves
    for i, weighted in ordinary.responses {
      out.push("\{stub.id} \{i}: \{weighted.response.reads_variables}")
    }
  }
  inspect(
    out.join("\n"),
    content=(
      #|static 0: false
      #|plain 0: false
      #|reads 0: true
      #|reads 1: true
      #|reads 2: true
      #|reads 3: true
      #|reads 4: true
      #|reads 5: false
    ),
  )
}
