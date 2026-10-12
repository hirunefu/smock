#!/bin/sh
# Smoke-tests a smock container image before it is published. The release
# workflow runs it on each architecture's own runner. It checks that:
#
# - the image runs as a numeric UID other than 0;
# - the image is for this machine, so it runs here without emulation;
# - the image is its distroless base (the FROM of Dockerfile) plus the smock
#   binary and nothing else;
# - smock links OpenSSL (libssl.so.3, libcrypto.so.3) dynamically;
# - run as the image's own UID, with a read-only root filesystem, no
#   capabilities and no privilege escalation, `smock --version` names the
#   version, the commit and the toolchain, and `smock serve` answers a Stub
#   on the plain port and over HTTPS with a test certificate, which shows
#   that OpenSSL is found at run time.
#
# It needs docker, curl, openssl and readelf.
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

# The image is its base (the FROM of Dockerfile) plus the smock binary, and
# nothing else.
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
[ "$added" = usr/local/bin/smock ] ||
  fail "the image should add only usr/local/bin/smock to $base, but adds:" \
    "$(echo "$added" | head -n 10 | tr '\n' ' ')"
echo "smoke-test-image: the image adds only usr/local/bin/smock to its base"

# smock links OpenSSL dynamically, from the base.
id=$(docker create "$image")
docker cp --quiet "$id:/usr/local/bin/smock" "$tmp/smock"
docker rm "$id" >/dev/null
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

# smock serve, with a definitions directory and a test certificate mounted
# read-only. The container's user owns none of the mounted files, so they are
# made world-readable.
mkdir "$tmp/definitions" "$tmp/tls"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -days 1 -subj /CN=localhost -addext subjectAltName=DNS:localhost,IP:127.0.0.1 \
  -keyout "$tmp/tls/key.pem" -out "$tmp/tls/cert.pem" 2>/dev/null
chmod 755 "$tmp/tls"
chmod 644 "$tmp/tls/key.pem" "$tmp/tls/cert.pem"
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
  --publish 127.0.0.1::8080 --publish 127.0.0.1::8443 \
  "$image" serve --dir /definitions \
  --tls-cert-file /tls/cert.pem --tls-key-file /tls/key.pem >/dev/null

serve_fail() {
  echo "smoke-test-image: smock serve logged:" >&2
  docker logs "$container" 2>&1 | sed 's/^/    /' >&2
  fail "$@"
}

# port <container port>: the host port it is published on.
port() {
  docker port "$container" "$1/tcp" | head -n 1 | sed 's/.*://'
}

# get <url> [curl flags...]: the body of a GET, retried while smock starts.
get() {
  url=$1
  shift
  curl --silent --show-error --fail --max-time 5 \
    --retry 20 --retry-delay 1 --retry-all-errors "$@" "$url"
}

body=$(get "http://127.0.0.1:$(port 8080)/smoke") ||
  serve_fail "no answer on the plain port"
[ "$body" = "smoke ok" ] || serve_fail "the plain port answered \"$body\", not \"smoke ok\""
echo "smoke-test-image: the plain port answers"

# HTTPS needs the OpenSSL libraries in the image.
body=$(get "https://127.0.0.1:$(port 8443)/smoke" --cacert "$tmp/tls/cert.pem") ||
  serve_fail "no answer over HTTPS on the TLS port"
[ "$body" = "smoke ok" ] || serve_fail "the TLS port answered \"$body\", not \"smoke ok\""
echo "smoke-test-image: the TLS port answers over HTTPS"

echo "smoke-test-image: $image passed"
