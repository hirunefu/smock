// The environment variables templates may read, as `env.NAME`. The caller
// reads them once and passes them in when templates are parsed: the
// template package reads nothing from the environment.

///|
/// The environment variables templates may read: the names that
/// `--template-env` lists, each with its value, or `None` when it is unset.
/// A template that reads any other name does not parse.
pub struct Env {
  priv values : Map[String, String?]
}

///|
/// The variables `listed`, each name with its value, or `None` when it is
/// unset. With none listed, templates read no variable.
pub fn Env::Env(listed : Array[(String, String?)]) -> Env {
  { values: Map::from_array(listed), }
}

///|
/// No variables listed: what templates read without `--template-env`.
pub let no_env : Env = Env([])
