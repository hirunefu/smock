// Tests of the `env` root: the environment variables that `--template-env`
// lists, with the values the caller read once. They run on native and on
// wasm-gc, and give the same output on both.

///|
/// `REGION` set, `ZONE` listed but unset, and `EMPTY` set to the empty
/// string.
let env : @template.Env = @template.Env([
  ("REGION", Some("eu-west-1")),
  ("ZONE", None),
  ("EMPTY", Some("")),
])

///|
/// A request with no fields that the tests below read.
let plain_request : @template.Input = {
  meth: "GET",
  path: "/",
  query: [],
  headers: [],
  body: b"",
}

///|
/// Parses `source` as a text body template with the variables `env`, and
/// renders it, or gives the problem or the render error.
fn render_text(source : String, env~ : @template.Env = env) -> String {
  match
    @template.Text::parse(
      source,
      pointer="/response/body",
      kind=Body(Plain),
      env~,
    ) {
    Ok(text) =>
      text.render(
        @template.Context::new(
          plain_request,
          now=0,
          rand=@template.helper_generator(1),
        ),
      ) catch {
        RenderError(at~, message~) => "error at \{at}: \{message}"
      }
    Err(problem) => "problem at \{problem.pointer}: \{problem.message}"
  }
}

///|
test "env.NAME gives a listed variable's value as a string; unset is missing, so ?? applies, and empty is present" {
  inspect(
    [
      render_text("${env.REGION}"),
      render_text("${env['REGION']}"),
      render_text("${env.ZONE ?? 'local'}"),
      render_text("[${env.EMPTY ?? 'unset'}]"),
      render_text("${env.ZONE}"),
    ].join("\n"),
    content=(
      #|eu-west-1
      #|eu-west-1
      #|local
      #|[]
      #|error at /response/body: env.ZONE is missing
    ),
  )
}

///|
/// The problems of the structured template `source`, parsed with the
/// variables `env`, one per line, or `parses` when it has none.
fn structured_problems(source : String) -> String {
  match
    @template.Structured::parse(
      @json.parse(source) catch {
        _ => panic()
      },
      pointer="/response/json",
      env~,
    ) {
    Ok(_) => "parses"
    Err(problems) => problems.map(p => "\{p.pointer}: \{p.message}").join("\n")
  }
}

///|
test "env reads only listed names, takes exactly one name step, and cannot be a loop variable" {
  inspect(
    [
      render_text("${env.HOME}"),
      render_text("${env.REGION}", env=@template.Env([])),
      render_text("${env}"),
      render_text("${env.REGION.x}"),
      render_text("${env[0]}"),
      structured_problems(
        (
          #|{ "a": "${env.SECRET ?? 'x'}",
          #|  "b": { "$each": "range(1, 2)", "as": "env", "do": "${env}" },
          #|  "c": { "$if": "env.REGION == 'eu-west-1'", "then": "${env.REGION}" } }
        ),
      ),
    ].join("\n"),
    content=(
      #|problem at /response/body: template: column 3: env.HOME: the environment variable "HOME" is not listed in --template-env
      #|problem at /response/body: template: column 3: env.REGION: the environment variable "REGION" is not listed in --template-env
      #|problem at /response/body: template: column 3: env: env takes exactly one name, such as env.REGION
      #|problem at /response/body: template: column 3: env.REGION.x: env takes exactly one name, such as env.REGION
      #|problem at /response/body: template: column 3: env[0]: env takes exactly one name, such as env.REGION
      #|/response/json/a: template: column 3: env.SECRET: the environment variable "SECRET" is not listed in --template-env
      #|/response/json/b/as: template: "env" cannot be a loop variable: it is a request field, env, vars, data, loop or a reserved word
    ),
  )
}

///|
test "a structured template keeps env values as strings, in $if conditions and fallbacks too" {
  guard @template.Structured::parse(
      @json.parse(
        (
          #|{ "region": "${env.REGION}", "zone": "${env.ZONE ?? null}",
          #|  "eu": { "$if": "env.REGION == 'eu-west-1'", "then": true, "else": false },
          #|  "empty": "${env.EMPTY}" }
        ),
      ),
      pointer="/response/json",
      env~,
    )
    is Ok(structured) else {
    fail("the template does not parse")
  }
  inspect(
    @utf8.decode(
      structured.render(
        @template.Context::new(
          plain_request,
          now=0,
          rand=@template.helper_generator(1),
        ),
      ),
    ),
    content=(
      #|{"region":"eu-west-1","zone":null,"eu":true,"empty":""}
    ),
  )
}
