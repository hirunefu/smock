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
    values(xml, "/a/@xmlns"),
    content=(
      #|[]
    ),
  )
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
