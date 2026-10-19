# Security policy

## Supported versions

Only the latest release of smock gets security fixes. A fix comes in a
new release, and older releases are not patched. The binaries, the
container image `ghcr.io/hirunefu/smock` and the Helm chart
`oci://ghcr.io/hirunefu/charts/smock` of a release share its version.

## Reporting a vulnerability

Report it privately, with GitHub's private vulnerability reporting: on
the repository's **Security** tab, choose **Report a vulnerability**.
Only the repository's maintainers see the report, and it stays private
while a fix is made.

Do not use public issues, pull requests or discussions for a
vulnerability. If you are not sure whether a problem is one, report it
privately all the same.

## What to include

Give what you can of:

- the version, as `smock --version` prints it, and how smock runs: the
  binary, the image or the Helm chart, with its flags or values;
- what an attacker can do, and from where: the plain or TLS port, the
  admin port, or the Definition files;
- the smallest requests, Definition files or steps that show it;
- what you expected, and what happened instead.

Leave real tokens, certificates and private keys out of the report.
