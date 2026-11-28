// The testee's answer for one case of yaml-test-suite: what smock's YAML
// parser reads from the case's input in each of its two modes, the safe
// subset that Definition files use and the mode for OpenAPI documents. It
// reads the input as smock reads a file of each kind: definitions/read.mbt
// for a Definition file, importopenapi/document.mbt for an OpenAPI
// document. scripts/yaml-test-suite-verdict.py judges the answers.

///|
/// The answer for the case `name`, whose input, `in.yaml`, is `input`: one
/// line of JSON, `{"case": <name>, "safe": <reading>, "openapi": <reading>}`.
/// A reading is `{"value": <tree>}`, the tree `@yaml.parse` gives;
/// `{"error": {"pointer": <pointer>, "message": <message>}}`, its refusal;
/// or `{"skipped": <why>}` when the input is not text that smock gives the
/// parser, as a file that is not UTF-8.
fn answer(name : String, input : Bytes) -> String {
  let answer : Json = {
    "case": Json::string(name),
    "safe": reading(input, openapi=false),
    "openapi": reading(input, openapi=true),
  }
  answer.stringify()
}

///|
/// What the parser reads from `input` in one mode. A Definition file and an
/// OpenAPI document in YAML are both decoded as UTF-8 as they are, with any
/// byte order mark: the parser drops one that starts the text.
fn reading(input : Bytes, openapi~ : Bool) -> Json {
  let text = @utf8.decode(input) catch {
    _ => return { "skipped": "not valid UTF-8" }
  }
  let value = @yaml.parse(text, openapi~) catch {
    @yaml.ParseError(pointer~, message~) =>
      return {
        "error": {
          "pointer": Json::string(pointer),
          "message": Json::string(message),
        },
      }
  }
  { "value": value }
}
