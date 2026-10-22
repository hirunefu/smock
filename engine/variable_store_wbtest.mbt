// How the engine stores Variables: by Mock, Session and name, with no map
// left empty. Nothing outside the engine can see an empty map, since a
// Mock or Session without one has no Variables either way, so these tests
// look at the store itself after requests through `Engine::handle`, resets
// and reloads.

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

///|
test "clearing Variables with a reset and dropping them with a reload leave no empty map behind" {
  let mocks =
    #|{ "mocks": [{ "name": "shop", "default": true }, { "name": "bank", "hosts": ["bank.svc"] }],
  let stubs =
    #|  "stubs": [
    #|    { "id": "shop", "mock": "shop", "request": { "path": "/count" },
    #|      "variables": { "count": "${query.n}" }, "response": { "status": 200 } },
    #|    { "id": "bank", "mock": "bank", "request": { "path": "/deposit" },
    #|      "variables": { "balance": "${query.n}" }, "response": { "status": 200 } } ] }
  let set = (files : String) => @definitions.DefinitionSet::{
    files: [("shop.json", @utf8.encode(files))],
    body_files: [],
  }
  guard @definitions.load(set(mocks + stubs)) is Ok(snapshot) else {
    fail("not loaded")
  }
  let engine = Engine(snapshot)
  let rand = @prng.Generator(1)
  let write = (target : String, session : String?) => {
    let request : Request = {
      meth: "POST",
      target,
      version: "HTTP/1.1",
      headers: [],
      body: b"",
    }
    ignore(engine.handle(request, session~, now=0, rand~))
  }
  let out = []
  let show = (label : String) => {
    out.push("\{label}: \{@debug.to_string(engine.variables.by_mock)}")
  }
  write("/count?n=1", Some("test-a"))
  write("http://bank.svc/deposit?n=2", Some("test-a"))
  write("/count?n=3", None)
  show("written")
  ignore(engine.reset(Session(Some("test-a"))))
  show("reset Session test-a")
  ignore(engine.reset(Mock("shop")))
  show("reset Mock shop")
  write("http://bank.svc/deposit?n=4", Some("test-b"))
  write("/count?n=5", Some("test-b"))
  show("test-b writes")
  let without_bank =
    #|{ "mocks": [{ "name": "shop", "default": true }],
    #|  "stubs": [] }
  ignore(engine.reload(set(without_bank), at=0))
  show("reload, bank removed")
  ignore(engine.reset(All))
  show("reset all")
  inspect(
    out.join("\n"),
    content=(
      #|written: {
      #|  "shop": {
      #|    Some("test-a"): { "count": String("1") },
      #|    None: { "count": String("3") },
      #|  },
      #|  "bank": { Some("test-a"): { "balance": String("2") } },
      #|}
      #|reset Session test-a: { "shop": { None: { "count": String("3") } } }
      #|reset Mock shop: {}
      #|test-b writes: {
      #|  "bank": { Some("test-b"): { "balance": String("4") } },
      #|  "shop": { Some("test-b"): { "count": String("5") } },
      #|}
      #|reload, bank removed: { "shop": { Some("test-b"): { "count": String("5") } } }
      #|reset all: {}
    ),
  )
}

///|
test "setting and deleting Variables through the Admin API leaves no empty map behind" {
  let files =
    #|{ "mocks": [{ "name": "shop", "default": true }, { "name": "bank", "hosts": ["bank.svc"] }],
    #|  "stubs": [] }
  let set : @definitions.DefinitionSet = {
    files: [("shop.json", @utf8.encode(files))],
    body_files: [],
  }
  guard @definitions.load(set) is Ok(snapshot) else { fail("not loaded") }
  let engine = Engine(snapshot)
  let out = []
  let show = (label : String) => {
    out.push("\{label}: \{@debug.to_string(engine.variables.by_mock)}")
  }
  engine.set_variable(mock="shop", session=Some("test-a"), name="a", 1)
  engine.set_variable(mock="shop", session=Some("test-a"), name="b", 2)
  engine.set_variable(mock="shop", session=None, name="a", 3)
  engine.set_variable(mock="bank", session=Some("test-a"), name="a", 4)
  show("set")
  engine.delete_variable(mock="shop", session=Some("test-a"), name="a")
  show("delete a of shop, test-a")
  engine.delete_variable(mock="shop", session=Some("test-a"), name="b")
  show("delete b of shop, test-a")
  engine.delete_variable(mock="shop", session=Some("test-b"), name="a") catch {
    _ => ()
  }
  engine.set_variable(mock="shop", session=Some("test-b"), name="a.b", 5) catch {
    _ => ()
  }
  show("an unknown Variable and a bad name, test-b")
  engine.delete_variable(mock="shop", session=None, name="a")
  show("delete a of shop, no Session")
  engine.delete_variable(mock="bank", session=Some("test-a"), name="a")
  show("delete a of bank, test-a")
  inspect(
    out.join("\n"),
    content=(
      #|set: {
      #|  "shop": {
      #|    Some("test-a"): { "a": Number(1), "b": Number(2) },
      #|    None: { "a": Number(3) },
      #|  },
      #|  "bank": { Some("test-a"): { "a": Number(4) } },
      #|}
      #|delete a of shop, test-a: {
      #|  "shop": { Some("test-a"): { "b": Number(2) }, None: { "a": Number(3) } },
      #|  "bank": { Some("test-a"): { "a": Number(4) } },
      #|}
      #|delete b of shop, test-a: {
      #|  "shop": { None: { "a": Number(3) } },
      #|  "bank": { Some("test-a"): { "a": Number(4) } },
      #|}
      #|an unknown Variable and a bad name, test-b: {
      #|  "shop": { None: { "a": Number(3) } },
      #|  "bank": { Some("test-a"): { "a": Number(4) } },
      #|}
      #|delete a of shop, no Session: { "bank": { Some("test-a"): { "a": Number(4) } } }
      #|delete a of bank, test-a: {}
    ),
  )
}
