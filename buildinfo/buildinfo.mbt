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
/// `smock 1.2.3 (commit 0123456789ab, moonc v0.10.14+7d59c7ec9)`.
pub fn BuildInfo::version_line(self : BuildInfo) -> String {
  "smock \{self.version} (commit \{self.commit}, \{self.toolchain})"
}

///|
/// Writes the startup entry, the first entry `smock serve` logs.
pub fn BuildInfo::log_startup(self : BuildInfo, logger : @log.Logger) -> Unit {
  logger.info("smock starting", fields={
    "version": Json::string(self.version),
    "commit": Json::string(self.commit),
    "toolchain": Json::string(self.toolchain),
  })
}
