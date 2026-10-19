///|
/// The values of the nodes that `path` selects in the document, in
/// document order. There are none when the path selects nothing.
///
/// The path's first step selects the root element, when it has that local
/// name. Each further step selects the children of the elements selected
/// so far that have that local name. A final attribute step selects the
/// attributes of those elements that have that local name. Namespace
/// declarations (`xmlns` and `xmlns:*`) are not attributes here.
///
/// An element's value is its XPath string-value, all the text in it and in
/// its descendants (CDATA included), trimmed of XML whitespace (space, tab,
/// line feed and carriage return). An attribute's value is its value after
/// XML's attribute-value normalisation (XML 1.0 §3.3.3): each literal
/// whitespace character in it is a space.
///
/// Selecting takes time linear in the size of the document.
pub fn Document::select(self : Document, path : Path) -> Array[String] {
  // Plain loops, with no closure or iterator, since a request may be
  // matched against many paths.
  let values = []
  if self.root.name != path.elements[0] {
    return values
  }
  let mut selected = [self.root]
  for i in 1..<path.elements.length() {
    let name = path.elements[i]
    let next = []
    for j in 0..<selected.length() {
      let children = selected[j].children
      for k in 0..<children.length() {
        if children[k] is Child(child) && child.name == name {
          next.push(child)
        }
      }
    }
    selected = next
  }
  match path.attribute {
    Some(name) =>
      for i in 0..<selected.length() {
        let attributes = selected[i].attributes
        for j in 0..<attributes.length() {
          if attributes[j].name == name {
            values.push(attributes[j].value)
          }
        }
      }
    None =>
      for i in 0..<selected.length() {
        values.push(selected[i].value())
      }
  }
  values
}

///|
/// The element's value: its XPath string-value (its text and the text of
/// every descendant, in document order), trimmed of XML whitespace.
fn Element::value(self : Element) -> String {
  let text = if self.children is [Text(text)] {
    text
  } else {
    let out = StringBuilder()
    self.write_text(out)
    out.to_string()
  }
  text.trim(chars=" \t\n\r").to_owned()
}

///|
/// Writes the element's text and the text of every descendant to `out`.
/// It recurses as deep as elements nest, which parsing bounds.
fn Element::write_text(self : Element, out : StringBuilder) -> Unit {
  for i in 0..<self.children.length() {
    match self.children[i] {
      Text(text) => out.write_string(text)
      Child(element) => element.write_text(out)
    }
  }
}
