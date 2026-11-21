///|
/// Parses `xml`, given as text and encoded as UTF-8, and selects `path` in
/// it. Fails the test when either does not compile or parse.
fn values(xml : String, path : String) -> Array[String] raise {
  @xml.parse(@utf8.encode(xml)).select(@xml.compile_path(path))
}

///|
test "a path of one step selects the root element's text" {
  debug_inspect(values("<id>42</id>", "/id"), content="[\"42\"]")
}

///|
test "child steps select every element of that name, in document order" {
  let order = "<order><item>a</item><note>n</note><item>b</item><box><item>c</item></box></order>"
  debug_inspect(
    values(order, "/order/item"),
    content=(
      #|["a", "b"]
    ),
  )
  debug_inspect(
    values(order, "/order/box/item"),
    content=(
      #|["c"]
    ),
  )
  debug_inspect(
    values(order, "/order/missing"),
    content=(
      #|[]
    ),
  )
  debug_inspect(
    values(order, "/item"),
    content=(
      #|[]
    ),
  )
  // Only the children of the elements selected so far: the item in the bag,
  // which follows a box, is no item of a box (the README's "Paths";
  // matching.md, "XML bodies": each further name selects the children with
  // that name of the elements selected so far).
  debug_inspect(
    values(
      "<order><box/><bag><item>b</item></bag><box><item>c</item></box></order>",
      "/order/box/item",
    ),
    content=(
      #|["c"]
    ),
  )
}

///|
test "an element's value is all its descendant text, trimmed of XML whitespace" {
  let user =
    #|<user>
    #|  <name>
    #|    Alice
    #|  </name>
    #|  <address><city>Kyoto</city> <zip>600-8001</zip></address>
    #|</user>
  debug_inspect(
    values(user, "/user/name"),
    content=(
      #|["Alice"]
    ),
  )
  debug_inspect(
    values(user, "/user/address"),
    content=(
      #|["Kyoto 600-8001"]
    ),
  )
  debug_inspect(
    values(user, "/user"),
    content=(
      #|["Alice\n  \n  Kyoto 600-8001"]
    ),
  )
  // Only space, tab, line feed and carriage return are XML whitespace.
  assert_eq(values("<a> \t\n\u{A0}x y\u{3000}\n</a>", "/a"), [
    "\u{A0}x y\u{3000}",
  ])
  debug_inspect(
    values("<a><b></b>  </a>", "/a"),
    content=(
      #|[""]
    ),
  )
}

///|
test "a final @name step selects that attribute of each selected element" {
  let order =
    #|<order status="paid" id='7'>
    #|  <item sku="a-1" qty="2"/>
    #|  <item qty="1"></item>
    #|  <item sku = "c-3" />
    #|</order>
  debug_inspect(
    values(order, "/order/@status"),
    content=(
      #|["paid"]
    ),
  )
  debug_inspect(
    values(order, "/order/@id"),
    content=(
      #|["7"]
    ),
  )
  debug_inspect(
    values(order, "/order/item/@sku"),
    content=(
      #|["a-1", "c-3"]
    ),
  )
  debug_inspect(
    values(order, "/order/item/@missing"),
    content=(
      #|[]
    ),
  )
  debug_inspect(
    values(order, "/order/item"),
    content=(
      #|["", "", ""]
    ),
  )
}

///|
test "an attribute's value is normalised: each whitespace character becomes a space" {
  debug_inspect(
    values("<a v=\"  one\ttwo\nthree\r\nfour\rfive  \"/>", "/a/@v"),
    content=(
      #|["  one two three four five  "]
    ),
  )
}

///|
/// For each node that `path` selects in `xml`, given as text and encoded as
/// UTF-8, in document order: its value from `utf8_value`, and whether that
/// value is a view of the input's own bytes rather than new bytes.
fn utf8_values(xml : String, path : String) -> Array[(String, Bool)] raise {
  let input = @utf8.encode(xml)
  let document = @xml.parse(input)
  let path = @xml.compile_path(path)
  let out = []
  let mut node = document.first_node(path)
  while node >= 0 {
    let value = document.utf8_value(path, node)
    out.push((@utf8.decode(value), physical_equal(value.data(), input)))
    node = document.next_node(path, node)
  }
  out
}

///|
test "utf8_value is a view of the input when the input holds the value as it is, and new bytes otherwise" {
  // utf8_value's documentation: the value is a view of the input when the
  // input holds it as it is, as it does for an element that holds only
  // text without references or carriage returns, and for an attribute
  // without references or whitespace other than spaces; otherwise it is
  // decoded into new bytes. The README: none of the walking functions
  // allocates, except utf8_value for a value that needs decoding, such as
  // text with a reference or CDATA. In an element, a line feed and a tab
  // are text as written, and a carriage return is not: it is a line end.
  let elements = "<r><a> x y </a><a>x\ny\tz</a><a>é😀</a><a>x&amp;y</a><a><![CDATA[x]]></a><a>x\r\ny</a><a>x<!---->y</a></r>"
  debug_inspect(
    utf8_values(elements, "/r/a"),
    content=(
      #|[
      #|  ("x y", true),
      #|  ("x\ny\tz", true),
      #|  ("é😀", true),
      #|  ("x&y", false),
      #|  ("x", false),
      #|  ("x\ny", false),
      #|  ("xy", false),
      #|]
    ),
  )
  let attributes = "<a v='x y' w='x&amp;y' u='x\ty' t='x\ny'/>"
  debug_inspect(
    ["/a/@v", "/a/@w", "/a/@u", "/a/@t"].map(path => {
      utf8_values(attributes, path)
    }),
    content=(
      #|[
      #|  [("x y", true)],
      #|  [("x&y", false)],
      #|  [("x y", false)],
      #|  [("x y", false)],
      #|]
    ),
  )
}

///|
test "the five predefined entities and character references are decoded" {
  debug_inspect(
    values("<a>&lt;b&gt; &amp; &apos;c&apos; &quot;d&quot;</a>", "/a"),
    content=(
      #|["<b> & 'c' \"d\""]
    ),
  )
  debug_inspect(
    values("<a>&#65;&#x42;&#x0043;&#233;&#x1F600;</a>", "/a"),
    content=(
      #|["ABCé😀"]
    ),
  )
  debug_inspect(
    values("<a v='&lt;&amp;&gt;&apos;&quot; &#65;&#x42;'/>", "/a/@v"),
    content=(
      #|["<&>'\" AB"]
    ),
  )
  // A hexadecimal reference's letters are in either case (XML 1.0 §4.1 [66]
  // CharRef: '&#x' [0-9a-fA-F]+ ';'): the first and the last letter, a and
  // f, in both. &#xfa; and &#xFA; are U+00FA, ú.
  debug_inspect(
    [
      values("<a>&#xfa;&#xFA;&#x1f600;</a>", "/a"),
      values("<a v='&#xfa;&#xFA;'/>", "/a/@v"),
    ],
    content=(
      #|[["úú😀"], ["úú"]]
    ),
  )
}

///|
test "in an attribute, a character reference to whitespace keeps its character" {
  assert_eq(values("<a v='x&#9;y&#10;z&#13;&#32;'/>", "/a/@v"), ["x\ty\nz\r "])
}

///|
test "in text, a line end is a line feed, and a character reference to CR stays CR" {
  assert_eq(values("<a>x\r\ny\rz&#13;w</a>", "/a"), ["x\ny\nz\rw"])
}

///|
test "CDATA is text, and comments and processing instructions are skipped" {
  let xml = "<a><!-- note -->x<?pi data?><![CDATA[<b>&amp;]]]]>y<b><![CDATA[]]></b><!---->z</a>"
  debug_inspect(
    values(xml, "/a"),
    content=(
      #|["x<b>&amp;]]yz"]
    ),
  )
  assert_eq(values("<a><![CDATA[x\r\ny\rz]]></a>", "/a"), ["x\ny\nz"])
}

///|
test "values are read past attribute values that hold > or /, and past comments and processing instructions that hold >" {
  let xml = "<a k='>'><b c=\"/>\" d='x/'>1<b>2</b><!-- > --><?p > ?>3</b><b/><e f='/' />4</a>"
  debug_inspect(
    [
      values(xml, "/a"),
      values(xml, "/a/b"),
      values(xml, "/a/b/b"),
      values(xml, "/a/b/@c"),
      values(xml, "/a/e/@f"),
      values(xml, "/a/@k"),
    ],
    content=(
      #|[["1234"], ["123", ""], ["2"], ["/>"], ["/"], [">"]]
    ),
  )
}

///|
test "comments, processing instructions and whitespace may surround the root element" {
  let xml =
    #|<?xml-stylesheet href="style.xsl" type="text/xsl"?>
    #|<!-- before -->
    #|<a>1</a>
    #|<!-- after --><?pi?>
    #|
  debug_inspect(
    values(xml, "/a"),
    content=(
      #|["1"]
    ),
  )
}

///|
test "an XML declaration may name UTF-8, and a byte order mark may come first" {
  let documents = [
    "<?xml version=\"1.0\"?><a>1</a>", "<?xml version='1.0' encoding='UTF-8' standalone='yes'?>\n<a>2</a>",
    "<?xml version = \"1.1\" encoding = \"utf-8\" standalone = \"no\" ?><a>3</a>",
    "\u{FEFF}<?xml version=\"1.0\" encoding=\"Utf-8\"?><a>4</a>", "\u{FEFF}<a>5</a>",
  ]
  debug_inspect(
    documents.map(xml => values(xml, "/a")),
    content=(
      #|[["1"], ["2"], ["3"], ["4"], ["5"]]
    ),
  )
}

///|
test "names match by local name: a prefix in the document is ignored" {
  let soap =
    #|<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">
    #|  <soap:Body>
    #|    <m:GetUser xmlns:m="urn:users" m:lang="en" lang="ja"><m:id>42</m:id></m:GetUser>
    #|  </soap:Body>
    #|</soap:Envelope>
  let other_prefixes =
    #|<S:Envelope xmlns:S="http://schemas.xmlsoap.org/soap/envelope/">
    #|  <S:Body><GetUser xmlns="urn:users"><id>42</id></GetUser></S:Body>
    #|</S:Envelope>
  debug_inspect(
    values(soap, "/Envelope/Body/GetUser/id"),
    content=(
      #|["42"]
    ),
  )
  debug_inspect(
    values(other_prefixes, "/Envelope/Body/GetUser/id"),
    content=(
      #|["42"]
    ),
  )
  debug_inspect(
    values(soap, "/Envelope/Body/GetUser/@lang"),
    content=(
      #|["en", "ja"]
    ),
  )
}

///|
test "namespace declarations are not selectable attributes" {
  let xml = "<a xmlns='urn:a' xmlns:p='urn:p' p='1' p:q='2'/>"
  debug_inspect(
    values(xml, "/a/@p"),
    content=(
      #|["1"]
    ),
  )
  debug_inspect(
    values(xml, "/a/@q"),
    content=(
      #|["2"]
    ),
  )
}

///|
test "names and values may be any characters XML allows" {
  let xml = "<注文 状態=\"支払済\"><品目>茶</品目><品目>😀</品目></注文>"
  debug_inspect(
    values(xml, "/注文/@状態"),
    content=(
      #|["支払済"]
    ),
  )
  debug_inspect(
    values(xml, "/注文/品目"),
    content=(
      #|["茶", "😀"]
    ),
  )
}

///|
test "a document parsed once answers any number of compiled paths" {
  let document = @xml.parse(
    @utf8.encode(
      (
        #|<order id="7">
        #|  <item sku="a-1"><name>Tea</name></item>
        #|  <item sku="b-2"><name><![CDATA[Fish & Chips]]></name></item>
        #|</order>
      ),
    ),
  )
  let paths = [
    "/order/@id", "/order/item/@sku", "/order/item/name", "/order/note",
  ].map(@xml.compile_path)
  debug_inspect(
    paths.map(path => document.select(path)),
    content=(
      #|[["7"], ["a-1", "b-2"], ["Tea", "Fish & Chips"], []]
    ),
  )
}
