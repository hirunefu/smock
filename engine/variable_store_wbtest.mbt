// How the engine stores Variables: by Mock, Session and name, with no map
// left empty. Nothing outside the engine can see an empty map, since a
// Mock or Session without one has no Variables either way, so this test
// looks at the store itself after requests through `Engine::handle`.

///|
test "a request that writes nothing, because its Stub writes none, a value fails or no Stub matches, leaves no empty map behind" {
  let files =
    #|{ "mocks": [{ "name": "shop", "default": true }, { "name": "other", "hosts": ["other.svc"] }],
    #|  "stubs": [
    #|    { "id": "none", "mock": "shop", "request": { "path": "/none" },
    #|      "variables": {}, "response": { "status": 200 } },
    #|    { "id": "fails", "mock": "shop", "request": { "path": "/fails" },
    #|      "variables": { "a": 1, "b": "${body.missing}" },
    #|      "response": { "status": 200 } },
    #|    { "id": "writes", "mock": "shop", "request": { "path": "/writes" },
    #|      "variables": { "count": "${query.n}" },
    #|      "response": { "status": 200 } } ] }
  let set : @definitions.DefinitionSet = {
    files: [("shop.json", @utf8.encode(files))],
    body_files: [],
  }
  guard @definitions.load(set) is Ok(snapshot) else { fail("not loaded") }
  let engine = Engine(snapshot)
  let rand = @prng.Generator(1)
  let out = []
  let step = (label : String, target : String, session : String?) => {
    let request : Request = {
      meth: "POST",
      target,
      version: "HTTP/1.1",
      headers: [],
      body: b"{}",
    }
    ignore(engine.handle(request, session~, now=0, rand~))
    out.push("\{label}: \{@debug.to_string(engine.variables.by_mock)}")
  }
  step("test-a, a Stub with variables: {}", "/none", Some("test-a"))
  step("test-a, a value that fails", "/fails", Some("test-a"))
  step("test-a, no Stub", "/nothing", Some("test-a"))
  step("test-a, another Mock's Host", "http://other.svc/none", Some("test-a"))
  step("test-a writes", "/writes?n=1", Some("test-a"))
  step("test-b, a value that fails", "/fails", Some("test-b"))
  step("no Session writes", "/writes?n=2", None)
  step("test-a writes again", "/writes?n=3", Some("test-a"))
  inspect(
    out.join("\n"),
    content=(
      #|test-a, a Stub with variables: {}: {}
      #|test-a, a value that fails: {}
      #|test-a, no Stub: {}
      #|test-a, another Mock's Host: {}
      #|test-a writes: { "shop": { Some("test-a"): { "count": String("1") } } }
      #|test-b, a value that fails: { "shop": { Some("test-a"): { "count": String("1") } } }
      #|no Session writes: {
      #|  "shop": {
      #|    Some("test-a"): { "count": String("1") },
      #|    None: { "count": String("2") },
      #|  },
      #|}
      #|test-a writes again: {
      #|  "shop": {
      #|    Some("test-a"): { "count": String("3") },
      #|    None: { "count": String("2") },
      #|  },
      #|}
    ),
  )
}
