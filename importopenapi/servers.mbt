///|
/// The prefix that the `servers` of `object`, a document, a Path Item or an
/// operation written at `pointer`, put in front of the paths of its
/// operations: the path of its first server. Without `servers`, or with an
/// empty list, it is `outer`, the prefix of the level around it, and so it
/// is when a server has an error, after reporting it. Every server of the
/// list is read, and when their paths differ, a warning names the first.
/// With a base path, `servers` are not read, and the prefix is `outer`.
fn Report::prefix(
  self : Report,
  pointer : String,
  object : Map[String, Json],
  outer~ : String,
) -> String {
  // A base path replaces the servers, which are then not read.
  if self.options.base_path is Some(_) {
    return outer
  }
  let servers_pointer = @definitions.child_pointer(pointer, "servers")
  let servers = match object.get("servers") {
    None => return outer
    Some(Array(servers)) => servers
    Some(_) => {
      self.root_error(servers_pointer, "must be an array")
      return outer
    }
  }
  if servers.is_empty() {
    return outer
  }
  let paths = []
  for i, server in servers {
    paths.push(
      self.server(
        @definitions.child_pointer(servers_pointer, i.to_string()),
        server,
      ),
    )
  }
  guard paths[0] is Some(prefix) else { return outer }
  if paths.iter().any(path => path is Some(other) && other != prefix) &&
    servers[0] is Object({ "url": String(url), .. }) {
    let puts = if prefix == "" { "nothing" } else { prefix.escape() }
    self.root_warning(
      servers_pointer,
      "left out: the servers have different paths, so only the first is used: \{url.escape()} puts \{puts} in front of the paths",
    )
  }
  prefix
}

///|
/// The prefix that the Server Object `json`, written at `pointer`, gives,
/// or `None` after reporting why it gives none.
fn Report::server(self : Report, pointer : String, json : Json) -> String? {
  guard json is Object(server) else {
    self.root_error(pointer, "must be an object")
    return None
  }
  let url_pointer = @definitions.child_pointer(pointer, "url")
  let url = match server.get("url") {
    Some(String(url)) => url
    None => {
      self.root_error(pointer, "needs \"url\", the server's URL")
      return None
    }
    Some(_) => {
      self.root_error(url_pointer, "must be a string")
      return None
    }
  }
  guard self.expanded(pointer, server, url) is Some(url) else { return None }
  if url.contains_char('?') || url.contains_char('#') {
    self.root_error(
      url_pointer, "a server URL must not hold ? or #: a query or a fragment is not part of it",
    )
    return None
  }
  Some(server_path(url))
}

///|
/// The URL `url` of `server`, written at `pointer`, with each variable,
/// such as `{version}`, replaced by its `default`. Or `None` after
/// reporting each variable that has no default, or why `url` is not a URL
/// template: a brace that does not pair, or an empty `{}`.
fn Report::expanded(
  self : Report,
  pointer : String,
  server : Map[String, Json],
  url : String,
) -> String? {
  if !url.contains_char('{') && !url.contains_char('}') {
    return Some(url)
  }
  let url_pointer = @definitions.child_pointer(pointer, "url")
  let variables_pointer = @definitions.child_pointer(pointer, "variables")
  let variables = match server.get("variables") {
    None => Map([])
    Some(Object(variables)) => variables
    Some(_) => {
      self.root_error(variables_pointer, "must be an object")
      return None
    }
  }
  let expanded = StringBuilder()
  let name = StringBuilder()
  let mut in_name = false
  let mut known = true
  for c in url {
    if !in_name {
      match c {
        '{' => {
          in_name = true
          name.reset()
        }
        '}' => {
          self.root_error(url_pointer, "a server URL has an unbalanced { or }")
          return None
        }
        _ => expanded.write_char(c)
      }
      continue
    }
    match c {
      '{' => {
        self.root_error(url_pointer, "a server URL has an unbalanced { or }")
        return None
      }
      '}' => {
        in_name = false
        let variable = name.to_string()
        if variable == "" {
          self.root_error(
            url_pointer, "a server URL has an empty {}: a variable needs a name",
          )
          return None
        }
        match
          self.variable_default(
            url_pointer, variables_pointer, variables, variable,
          ) {
          Some(value) => expanded.write_string(value)
          None => known = false
        }
      }
      _ => name.write_char(c)
    }
  }
  if in_name {
    self.root_error(url_pointer, "a server URL has an unbalanced { or }")
    return None
  }
  if known {
    Some(expanded.to_string())
  } else {
    None
  }
}

///|
/// The `default` of the server variable `name`, among `variables`, written
/// at `variables_pointer`, which the URL at `url_pointer` uses. Or `None`
/// after reporting why it has no string `default`.
fn Report::variable_default(
  self : Report,
  url_pointer : String,
  variables_pointer : String,
  variables : Map[String, Json],
  name : String,
) -> String? {
  let pointer = @definitions.child_pointer(variables_pointer, name)
  match variables.get(name) {
    None => {
      self.root_error(
        url_pointer,
        "the variable {\{name}} has no default: declare it under \"variables\", with a \"default\"",
      )
      None
    }
    Some(Object(variable)) =>
      match variable.get("default") {
        Some(String(value)) => Some(value)
        None => {
          self.root_error(
            pointer,
            "needs \"default\", a string that replaces {\{name}} in the URL",
          )
          None
        }
        Some(_) => {
          self.root_error(
            @definitions.child_pointer(pointer, "default"),
            "must be a string",
          )
          None
        }
      }
    Some(_) => {
      self.root_error(pointer, "must be an object")
      None
    }
  }
}

///|
/// The prefix that the server URL `url`, which holds no `?` or `#`, gives:
/// its path, resolved against `/` as RFC 3986 resolves a reference, so
/// that an absolute URL gives its own path and a relative one is read
/// from `/`. The scheme and the host never matter. Dot segments are
/// removed. Then the path is percent-decoded as smock decodes request
/// paths, and a trailing `/` is dropped.
fn server_path(url : String) -> String {
  let mut rest = url[:]
  if has_scheme(url) && url.find(":") is Some(colon) {
    rest = url[colon + 1:]
  }
  if rest.has_prefix("//") {
    rest = match rest[2:].find("/") {
      Some(i) => rest[i + 2:]
      None => ""
    }
  }
  let path = if rest.has_prefix("/") {
    rest.to_owned()
  } else {
    "/" + rest.to_owned()
  }
  trimmed_prefix(without_dot_segments(path))
}

///|
/// `path`, which starts with `/`, without its dot segments, as RFC 3986
/// removes them: `.` stands for the segment it is in, and `..` for the one
/// before it. So `/a/./b/../c` is `/a/c`, and `/..` is `/`.
fn without_dot_segments(path : String) -> String {
  if !path.contains_char('.') {
    return path
  }
  let segments = path[1:].split("/").collect()
  let kept : Array[StringView] = []
  for i, segment in segments {
    let last = i == segments.length() - 1
    if segment == "." || segment == ".." {
      if segment == ".." {
        kept.pop() |> ignore
      }
      // A dot segment at the end leaves the path ending in `/`.
      if last {
        kept.push("")
      }
    } else {
      kept.push(segment)
    }
  }
  let out = StringBuilder()
  for segment in kept {
    out.write_char('/')
    out.write_string(segment.to_owned())
  }
  out.to_string()
}

///|
/// `path`, percent-decoded as smock decodes request paths, without a
/// trailing `/`. So `/` gives no prefix.
fn trimmed_prefix(path : String) -> String {
  let decoded = decoded_path(path)
  if decoded.has_suffix("/") {
    decoded[:decoded.length() - 1].to_owned()
  } else {
    decoded
  }
}
