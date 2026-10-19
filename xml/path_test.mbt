///|
/// Compiles each path and shows `path => error`, or `path => compiled`,
/// one per line.
fn path_errors(paths : Array[String]) -> String {
  paths
  .map(path => {
    let result = try @xml.compile_path(path) catch {
      error => error.to_string()
    } noraise {
      _ => "compiled"
    }
    "\{path} => \{result}"
  })
  .join("\n")
}

///|
test "a path is / and element names separated by /, optionally ending in /@name" {
  inspect(
    path_errors([
      "/a", "/Envelope/Body/GetUser/id", "/order/@status", "/a-b/c.d/_e/f1/@g-h",
      "/名前/@属性",
    ]),
    content=(
      #|/a => compiled
      #|/Envelope/Body/GetUser/id => compiled
      #|/order/@status => compiled
      #|/a-b/c.d/_e/f1/@g-h => compiled
      #|/名前/@属性 => compiled
    ),
  )
}

///|
test "XPath beyond child steps and a final attribute is a compile error" {
  inspect(
    path_errors([
      "//a", "/a//b", "/*", "/a/*", "/a/@*", "/a[1]", "/a[@id='1']/b", "/a/@b[1]",
      "/a/text()", "/a/count(b)", "/a/.", "/a/..", "/child::a", "/a/attribute::b",
      "/a | /b",
    ]),
    content=(
      #|//a => position 0: // (descendants) is not supported in smock's XML paths
      #|/a//b => position 2: // (descendants) is not supported in smock's XML paths
      #|/* => position 1: wildcard * is not supported in smock's XML paths
      #|/a/* => position 3: wildcard * is not supported in smock's XML paths
      #|/a/@* => position 4: wildcard * is not supported in smock's XML paths
      #|/a[1] => position 2: predicate or index [...] is not supported in smock's XML paths
      #|/a[@id='1']/b => position 2: predicate or index [...] is not supported in smock's XML paths
      #|/a/@b[1] => position 5: predicate or index [...] is not supported in smock's XML paths
      #|/a/text() => position 3: function text() is not supported in smock's XML paths
      #|/a/count(b) => position 3: function count() is not supported in smock's XML paths
      #|/a/. => position 3: step . is not supported in smock's XML paths
      #|/a/.. => position 3: step .. is not supported in smock's XML paths
      #|/child::a => position 1: axis child:: is not supported in smock's XML paths
      #|/a/attribute::b => position 3: axis attribute:: is not supported in smock's XML paths
      #|/a | /b => position 2: expected / or the end of the path
    ),
  )
}

///|
test "a malformed path is a compile error that says where the problem is" {
  inspect(
    path_errors([
      "", "a/b", "/", "/a/", "/@b", "/a/@", "/a/@b/c", "/a/@b/@c", "/1a", "/a/$x",
      "/p:a", "/a/@p:b", "/a/b:", "/a b",
    ]),
    content=(
      #| => position 0: a path starts with /
      #|a/b => position 0: a path starts with /
      #|/ => position 1: expected an element name
      #|/a/ => position 3: expected an element name
      #|/@b => position 1: a path names the root element first
      #|/a/@ => position 4: expected an attribute name
      #|/a/@b/c => position 5: an attribute step must come last
      #|/a/@b/@c => position 5: an attribute step must come last
      #|/1a => position 1: expected an element name
      #|/a/$x => position 3: expected an element name
      #|/p:a => position 1: prefix p: is not supported in smock's XML paths; name the local name only
      #|/a/@p:b => position 4: prefix p: is not supported in smock's XML paths; name the local name only
      #|/a/b: => position 3: prefix b: is not supported in smock's XML paths; name the local name only
      #|/a b => position 2: expected / or the end of the path
    ),
  )
}

///|
test "a compile error position counts characters, not bytes" {
  // 名 is three bytes in UTF-8, and 😀 is four bytes and two UTF-16 code
  // units.
  inspect(
    path_errors(["/名😀/*", "/名😀/@😀[1]"]),
    content=(
      #|/名😀/* => position 4: wildcard * is not supported in smock's XML paths
      #|/名😀/@😀[1] => position 6: predicate or index [...] is not supported in smock's XML paths
    ),
  )
}

///|
test "a compiled path shows as written, and paths written the same are equal" {
  let path = @xml.compile_path("/order/item/@sku")
  inspect(path, content="/order/item/@sku")
  debug_inspect(
    path,
    content=(
      #|Path("/order/item/@sku")
    ),
  )
  assert_eq(path, @xml.compile_path("/order/item/@sku"))
  assert_not_eq(path, @xml.compile_path("/order/item"))
}
