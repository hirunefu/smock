///|
/// The values of the nodes that `path` selects in `xml`, given as text and
/// encoded as UTF-8, walked one node at a time with `first_node` and
/// `next_node`, and each read with `utf8_value`.
fn walked(xml : String, path : String) -> Array[String] raise {
  let document = @xml.parse(@utf8.encode(xml))
  let path = @xml.compile_path(path)
  let values = []
  let mut node = document.first_node(path)
  while node >= 0 {
    values.push(@utf8.decode(document.utf8_value(path, node)))
    node = document.next_node(path, node)
  }
  values
}

///|
test "walking a path visits the elements it selects, in document order" {
  let order = "<order><item>a</item><note>n</note><item> b </item><box><item>c</item></box><item/></order>"
  debug_inspect(
    walked(order, "/order/item"),
    content=(
      #|["a", "b", ""]
    ),
  )
  debug_inspect(
    walked(order, "/order/box/item"),
    content=(
      #|["c"]
    ),
  )
  debug_inspect(
    walked(order, "/order/missing"),
    content=(
      #|[]
    ),
  )
}

///|
test "walking an attribute path visits each attribute of that local name" {
  let order =
    #|<order p:id="1" q:id='2' xmlns:id="urn:x">
    #|  <item sku="a-1"/><item/><item sku="c-3" p:sku="c-4"></item>
    #|</order>
  debug_inspect(
    walked(order, "/order/@id"),
    content=(
      #|["1", "2"]
    ),
  )
  debug_inspect(
    walked(order, "/order/item/@sku"),
    content=(
      #|["a-1", "c-3", "c-4"]
    ),
  )
  debug_inspect(
    walked(order, "/order/item/@missing"),
    content=(
      #|[]
    ),
  )
}

///|
/// Whether the value of each node that `path` selects in `xml` is `text`,
/// as `value_is` compares it, in document order.
fn values_are(xml : String, path : String, text : String) -> Array[Bool] raise {
  let document = @xml.parse(@utf8.encode(xml))
  let path = @xml.compile_path(path)
  let out = []
  let mut node = document.first_node(path)
  while node >= 0 {
    out.push(document.value_is(path, node, text))
    node = document.next_node(path, node)
  }
  out
}

///|
test "value_is compares an element's trimmed value, whatever it is written with" {
  let user = "<user>\n  <name>\n    Alice\n  </name><name>Alice </name><name>Alic</name><name>Alicex</name></user>"
  debug_inspect(
    values_are(user, "/user/name", "Alice"),
    content="[true, true, false, false]",
  )
  // A value is trimmed, so no text with whitespace at either end is one.
  debug_inspect(
    values_are(user, "/user/name", " Alice"),
    content="[false, false, false, false]",
  )
  debug_inspect(
    values_are(user, "/user/name", "Alice\n"),
    content="[false, false, false, false]",
  )
  let written = [
    "<a>x&lt;y</a>", "<a>&#120;&#x3C;y</a>", "<a><![CDATA[x<]]>y</a>", "<a> x<!-- c --><?p?>&lt;<b>y</b> </a>",
    "<a><![CDATA[ ]]>x<![CDATA[<y]]>&#32;</a>",
  ]
  debug_inspect(
    written.map(xml => values_are(xml, "/a", "x<y")),
    content="[[true], [true], [true], [true], [true]]",
  )
  debug_inspect(
    written.map(xml => values_are(xml, "/a", "x<")),
    content="[[false], [false], [false], [false], [false]]",
  )
}

///|
test "value_is reads line ends as line feeds, and inner whitespace as it is" {
  debug_inspect(
    values_are("<a>x\r\ny\rz&#13;w</a>", "/a", "x\ny\nz\rw"),
    content="[true]",
  )
  debug_inspect(
    values_are("<a><![CDATA[x\r\ny]]></a>", "/a", "x\ny"),
    content="[true]",
  )
  debug_inspect(values_are("<a>x\r\ny</a>", "/a", "x\r\ny"), content="[false]")
  debug_inspect(values_are("<a>x <b/> y</a>", "/a", "x  y"), content="[true]")
}

///|
test "value_is compares an empty value" {
  debug_inspect(
    values_are(
      "<r><a/><a></a><a> \n </a><a><!-- c --></a><a>x</a></r>", "/r/a", "",
    ),
    content="[true, true, true, true, false]",
  )
  debug_inspect(values_are("<a v='' w='x'/>", "/a/@v", ""), content="[true]")
  debug_inspect(values_are("<a v='' w='x'/>", "/a/@w", ""), content="[false]")
}

///|
test "value_is compares characters outside the BMP" {
  debug_inspect(
    values_are("<a>😀&#x1F600;</a>", "/a", "😀😀"),
    content="[true]",
  )
  debug_inspect(values_are("<a>😀</a>", "/a", "😁"), content="[false]")
  debug_inspect(
    values_are("<a v='é&#x1F600;'/>", "/a/@v", "é😀"),
    content="[true]",
  )
}

///|
test "value_is compares an attribute's normalised value, which is not trimmed" {
  let xml = "<a v=\"  one\ttwo\nthree\r\nfour\rfive  \" w='&lt;&amp;&#9;'/>"
  debug_inspect(
    values_are(xml, "/a/@v", "  one two three four five  "),
    content="[true]",
  )
  debug_inspect(
    values_are(xml, "/a/@v", "one two three four five"),
    content="[false]",
  )
  debug_inspect(values_are(xml, "/a/@w", "<&\t"), content="[true]")
}

///|
/// A small deterministic random number generator for the property test:
/// xorshift32, from a non-zero seed.
struct Random {
  mut state : UInt
}

///|
/// A number from 0 to `limit` - 1.
fn Random::below(self : Random, limit : Int) -> Int {
  let mut x = self.state
  x = x ^ (x << 13)
  x = x ^ (x >> 17)
  x = x ^ (x << 5)
  self.state = x
  (x % limit.reinterpret_as_uint()).reinterpret_as_int()
}

///|
/// Text and markup that may appear in an element's content, each
/// well-formed on its own.
let content_pieces : Array[String] = [
  "x", "y", " ", "\t", "\n", "\r\n", "\r", "é", "😀", "&amp;", "&lt;", "&#32;",
  "&#x1F600;", "&#13;", "<![CDATA[ c<&]]>", "<![CDATA[]]>", "<!-- note -->", "<?pi data?>",
]

///|
/// Attributes that a start tag may hold, each at most once.
let attribute_pieces : Array[String] = [
  " v='x'", " p:v=' y\tz '", " w='&lt;&#10;'", " q:w=\"\"", " u='\r\nx😀'", " xmlns:v='urn:v'",
]

///|
/// A random element named `a`, `b` or `p:a`, `depth` levels deep at most.
fn random_element(random : Random, depth : Int, out : StringBuilder) -> Unit {
  let name = ["a", "b", "p:a"][random.below(3)]
  out.write_string("<\{name}")
  for attribute in attribute_pieces {
    if random.below(3) == 0 {
      out.write_string(attribute)
    }
  }
  if random.below(4) == 0 {
    out.write_string("/>")
    return
  }
  out.write_string(">")
  for _ in 0..<random.below(5) {
    if depth > 1 && random.below(3) == 0 {
      random_element(random, depth - 1, out)
    } else {
      out.write_string(content_pieces[random.below(content_pieces.length())])
    }
  }
  out.write_string("</\{name}>")
}

///|
test "value_is agrees with utf8_value on random documents" {
  let random = Random::{ state: 2463534242, }
  let paths = [
    "/a", "/a/a", "/a/b", "/a/a/a", "/a/b/a", "/a/@v", "/a/a/@v", "/a/b/@w", "/a/a/@u",
  ].map(@xml.compile_path)
  let mut nodes = 0
  for _ in 0..<2000 {
    let out = StringBuilder()
    random_element(random, 4, out)
    let document = @xml.parse(@utf8.encode(out.to_string()))
    for path in paths {
      let values = []
      let mut node = document.first_node(path)
      while node >= 0 {
        let value = @utf8.decode(document.utf8_value(path, node))
        assert_true(document.value_is(path, node, value))
        assert_false(document.value_is(path, node, value + "x"))
        assert_false(document.value_is(path, node, "x" + value))
        if value != "" {
          assert_false(
            document.value_is(
              path,
              node,
              value.view(end_offset=value.length() - 1),
            ),
          )
        }
        values.push((node, value))
        node = document.next_node(path, node)
      }
      // Each node's value is compared with every other node's value.
      for first in values {
        for second in values {
          assert_eq(
            document.value_is(path, first.0, second.1),
            first.1 == second.1,
          )
        }
      }
      nodes += values.length()
    }
  }
  // Enough nodes are selected for the test to say something.
  assert_true(nodes > 3000)
}
