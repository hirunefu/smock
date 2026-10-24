///|
/// What a smock binary was built from: its version, its commit and the
/// MoonBit toolchain that compiled it.
pub(all) struct BuildInfo {
  version : String
  commit : String
  toolchain : String
}

///|
/// The build information of this binary, recorded when it was built.
pub fn current() -> BuildInfo {
  { version: build_version, commit: build_commit, toolchain: build_toolchain, }
}

///|
/// The line `smock --version` prints, such as
/// `smock 1.2.3 (commit 0123456789ab, moonc v0.10.17+d971670cd)`.
pub fn BuildInfo::version_line(self : BuildInfo) -> String {
  "smock \{self.version} (commit \{self.commit}, \{self.toolchain})"
}

///|
/// Writes the startup entry, the first entry `smock serve` logs: the
/// version, the commit and the toolchain, then `fields`.
pub fn BuildInfo::log_startup(
  self : BuildInfo,
  logger : @log.Logger,
  fields~ : Map[String, Json] = {},
) -> Unit {
  let entry : Map[String, Json] = {
    "version": Json::string(self.version),
    "commit": Json::string(self.commit),
    "toolchain": Json::string(self.toolchain),
  }
  for key, value in fields {
    entry[key] = value
  }
  logger.info("smock starting", fields=entry)
}

///|
/// Registers the build-info metric, `smock_build_info`, in `registry`: a
/// gauge that is always 1 and carries the version, the commit and the
/// toolchain as labels.
pub fn BuildInfo::register_metric(
  self : BuildInfo,
  registry : @metrics.Registry,
) -> Unit {
  registry
  .gauge(
    "smock_build_info",
    help="The smock build: its version, commit and MoonBit toolchain, as labels. Always 1.",
    labels=["version", "commit", "toolchain"],
  )
  .labels([self.version, self.commit, self.toolchain])
  .set(1)
}
