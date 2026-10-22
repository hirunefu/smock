///|
/// The environment variables `names` lists, each with its value in smock's
/// environment now, or `None` when it is unset: what templates may read as
/// `env.NAME`. `smock serve` reads them once, at startup, and loads every
/// definition set and Ephemeral Stub with them; `smock check` and
/// `smock render` read their own. The values are never logged.
pub fn template_env(names : Array[String]) -> @template.Env {
  @template.Env(names.map(name => (name, @env.get_env_var(name))))
}
