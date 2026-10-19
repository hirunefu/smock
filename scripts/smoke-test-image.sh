#!/bin/sh
# Smoke-tests a smock container image before it is published. The release
# workflow runs it on each architecture's own runner. It checks that:
#
# - the image runs as a numeric UID other than 0;
# - the image is for this machine, so it runs here without emulation;
# - the image is its distroless base (the FROM of Dockerfile) plus the smock
#   binary, LICENSE and NOTICE, and nothing else, and those two files are
#   the repository's;
# - smock links OpenSSL (libssl.so.3, libcrypto.so.3) dynamically;
# - run as the image's own UID, with a read-only root filesystem, no
#   capabilities and no privilege escalation, `smock --version` names the
#   version, the commit and the toolchain, and `smock serve` answers a Stub
#   on the plain port and over HTTPS with a test certificate, which shows
#   that OpenSSL is found at run time, and its Admin API status operation
#   answers on the admin port with the token and names the same build as
#   `smock --version`;
# - without certificate files, `smock serve` answers over HTTPS with the
#   self-signed certificate it generates in memory, on the same read-only
#   root filesystem.
#
# It needs docker, curl, openssl, readelf and jq.
#
# usage: scripts/smoke-test-image.sh <image> <version> <commit> <toolchain>
# example: scripts/smoke-test-image.sh smock:dev 0.0.0-dev 0123456789ab "moonc v0.10.14+7d59c7ec9"
set -eu
cd "$(dirname "$0")/.."

if [ "$#" -ne 4 ]; then
  echo "usage: $0 <image> <version> <commit> <toolchain>" >&2
  exit 2
fi
image=$1 version=$2 commit=$3 toolchain=$4

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "smoke-test-image: $*" >&2
  exit 1
}

# The image's user is a numeric UID other than 0, so that Kubernetes can
# check runAsNonRoot.
user=$(docker image inspect --format '{{.Config.User}}' "$image")
uid=${user%%:*}
case $uid in
'' | *[!0-9]*) fail "the image's user is \"$user\", not a numeric UID" ;;
esac
[ "$uid" -ne 0 ] || fail "the image runs as root"
echo "smoke-test-image: runs as UID $uid"

# The image is built for this machine, so it runs here without emulation.
platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image")
case $(uname -m) in
x86_64) host=linux/amd64 ;;
aarch64 | arm64) host=linux/arm64 ;;
*) fail "unsupported machine $(uname -m)" ;;
esac
[ "$platform" = "$host" ] || fail "the image is for $platform, but this machine is $host"
echo "smoke-test-image: the image is for $platform, this machine"

# The image is its base (the FROM of Dockerfile) plus the smock binary,
# LICENSE and NOTICE, and nothing else.
# files <image>: the paths in the image's filesystem, sorted.
files() {
  id=$(docker create --platform "$platform" "$1" none)
  docker export "$id" | tar -t | sort
  docker rm "$id" >/dev/null
}
base=$(sed -n 's/^FROM //p' Dockerfile)
files "$base" >"$tmp/base-files"
files "$image" >"$tmp/image-files"
added=$(comm -13 "$tmp/base-files" "$tmp/image-files" | grep -v '/$' || true)
expected=$(printf '%s\n' usr/local/bin/smock usr/share/doc/smock/LICENSE usr/share/doc/smock/NOTICE)
[ "$added" = "$expected" ] ||
  fail "the image should add only smock, LICENSE and NOTICE to $base, but adds:" \
    "$(echo "$added" | head -n 10 | tr '\n' ' ')"
echo "smoke-test-image: the image adds only smock, LICENSE and NOTICE to its base"

# The licence files are the repository's, and smock links OpenSSL
# dynamically, from the base.
id=$(docker create "$image")
docker cp --quiet "$id:/usr/local/bin/smock" "$tmp/smock"
for file in LICENSE NOTICE; do
  docker cp --quiet "$id:/usr/share/doc/smock/$file" "$tmp/$file"
done
docker rm "$id" >/dev/null
for file in LICENSE NOTICE; do
  cmp -s "$file" "$tmp/$file" || fail "/usr/share/doc/smock/$file in the image is not $file"
done
echo "smoke-test-image: /usr/share/doc/smock/ holds LICENSE and NOTICE"
for library in libssl.so.3 libcrypto.so.3; do
  readelf --dynamic "$tmp/smock" | grep -q "(NEEDED).*\[$library\]" ||
    fail "smock does not link $library dynamically"
done
echo "smoke-test-image: smock links libssl.so.3 and libcrypto.so.3 dynamically"

# Every container runs as the image's own user, with a read-only root
# filesystem, no capabilities and no privilege escalation.
run_flags="--read-only --cap-drop ALL --security-opt no-new-privileges"

# smock --version, through scripts/check-version.sh, which runs the binary
# it is given.
cat >"$tmp/smock-in-image" <<SH
#!/bin/sh
exec docker run --rm $run_flags "$image" "\$@"
SH
chmod +x "$tmp/smock-in-image"
scripts/check-version.sh "$tmp/smock-in-image" "$version" "$commit" "$toolchain" ||
  fail "smock --version in the image is wrong"

# smock serve, with a definitions directory, a test certificate and an Admin
# API token file mounted read-only, as Kubernetes mounts a ConfigMap and
# Secrets. The container's user owns none of the mounted files, so they are
# made world-readable.
mkdir "$tmp/definitions" "$tmp/tls" "$tmp/admin"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -days 1 -subj /CN=localhost -addext subjectAltName=DNS:localhost,IP:127.0.0.1 \
  -keyout "$tmp/tls/key.pem" -out "$tmp/tls/cert.pem" 2>/dev/null
chmod 755 "$tmp/tls"
chmod 644 "$tmp/tls/key.pem" "$tmp/tls/cert.pem"
openssl rand -hex 16 >"$tmp/admin/token"
chmod 755 "$tmp/admin"
chmod 644 "$tmp/admin/token"
# The token goes to curl in a header file, not on its command line.
printf 'Authorization: Bearer %s\n' "$(cat "$tmp/admin/token")" >"$tmp/admin-header"
cat >"$tmp/definitions/smoke.json" <<'JSON'
{
  "mocks": [{ "name": "smoke" }],
  "stubs": [
    {
      "id": "smoke",
      "mock": "smoke",
      "request": { "method": "GET", "path": "/smoke" },
      "response": { "status": 200, "body": "smoke ok" }
    }
  ]
}
JSON
chmod 755 "$tmp" "$tmp/definitions"
chmod 644 "$tmp/definitions/smoke.json"

container=smock-smoke-$$
trap 'docker rm --force "$container" >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
# shellcheck disable=SC2086 # $run_flags is a list of flags
docker run --detach --name "$container" $run_flags \
  --volume "$tmp/definitions:/definitions:ro" --volume "$tmp/tls:/tls:ro" \
  --volume "$tmp/admin:/admin:ro" \
  --publish 127.0.0.1::8080 --publish 127.0.0.1::8443 --publish 127.0.0.1::9090 \
  "$image" serve --dir /definitions \
  --tls-cert-file /tls/cert.pem --tls-key-file /tls/key.pem \
  --admin-token-file /admin/token >/dev/null

serve_fail() {
  echo "smoke-test-image: smock serve logged:" >&2
  docker logs "$container" 2>&1 | sed 's/^/    /' >&2
  fail "$@"
}

# port <container port>: the host port it is published on, which exists
# only while the container runs.
port() {
  published=$(docker port "$container" "$1/tcp" 2>/dev/null | head -n 1 | sed 's/.*://')
  [ -n "$published" ] || serve_fail "smock serve stopped"
  echo "$published"
}
plain_port=$(port 8080)
tls_port=$(port 8443)
admin_port=$(port 9090)

# get <url> [curl flags...]: the body of a GET, retried while smock starts.
get() {
  url=$1
  shift
  curl --silent --show-error --fail --max-time 5 \
    --retry 20 --retry-delay 1 --retry-all-errors "$@" "$url"
}

body=$(get "http://127.0.0.1:$plain_port/smoke") ||
  serve_fail "no answer on the plain port"
[ "$body" = "smoke ok" ] || serve_fail "the plain port answered \"$body\", not \"smoke ok\""
echo "smoke-test-image: the plain port answers"

# HTTPS needs the OpenSSL libraries in the image.
body=$(get "https://127.0.0.1:$tls_port/smoke" --cacert "$tmp/tls/cert.pem") ||
  serve_fail "no answer over HTTPS on the TLS port"
[ "$body" = "smoke ok" ] || serve_fail "the TLS port answered \"$body\", not \"smoke ok\""
echo "smoke-test-image: the TLS port answers over HTTPS"

# The Admin API status operation answers with the token and names the build
# that `smock --version` printed above.
status=$(get "http://127.0.0.1:$admin_port/v1/status" --header "@$tmp/admin-header") ||
  serve_fail "no answer from the Admin API status operation on the admin port"
build=$(echo "$status" | jq -r '"\(.version) (commit \(.commit), \(.toolchain))"') ||
  serve_fail "the Admin API status is not JSON: $status"
[ "$build" = "$version (commit $commit, $toolchain)" ] ||
  serve_fail "the Admin API status names the build \"$build\", not \"$version (commit $commit, $toolchain)\""
echo "smoke-test-image: the Admin API status operation answers on the admin port"

# Without certificate files, smock serves HTTPS with a self-signed
# certificate that it generates and keeps in memory, so the read-only root
# filesystem does not stop it. A client that trusts that certificate, read
# from the handshake, verifies it for 127.0.0.1.
docker rm --force "$container" >/dev/null
container=smock-smoke-generated-$$
# shellcheck disable=SC2086 # $run_flags is a list of flags
docker run --detach --name "$container" $run_flags \
  --volume "$tmp/definitions:/definitions:ro" --volume "$tmp/admin:/admin:ro" \
  --publish 127.0.0.1::8080 --publish 127.0.0.1::8443 \
  "$image" serve --dir /definitions --admin-token-file /admin/token >/dev/null
plain_port=$(port 8080)
tls_port=$(port 8443)
get "http://127.0.0.1:$plain_port/smoke" >/dev/null ||
  serve_fail "no answer on the plain port without certificate files"
openssl s_client -connect "127.0.0.1:$tls_port" </dev/null 2>/dev/null |
  sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' >"$tmp/generated.pem"
[ -s "$tmp/generated.pem" ] || serve_fail "the TLS port presented no certificate"
body=$(get "https://127.0.0.1:$tls_port/smoke" --cacert "$tmp/generated.pem") ||
  serve_fail "no answer over HTTPS with the generated certificate"
[ "$body" = "smoke ok" ] || serve_fail "the TLS port answered \"$body\", not \"smoke ok\""
docker logs "$container" 2>&1 | grep -q '"msg":"self-signed certificate in use"' ||
  serve_fail "smock did not log that a self-signed certificate is in use"
echo "smoke-test-image: without certificate files, the TLS port answers over HTTPS with a generated certificate"

echo "smoke-test-image: $image passed"
