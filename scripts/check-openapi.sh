#!/bin/sh
# Checks that the Admin API document (openapi/admin.json) is valid OpenAPI
# 3.1, with the external validator openapi-spec-validator. It also checks the
# JSON Schemas inside the document against their meta-schema.
#
# openapi-spec-validator does not follow the document's references into the
# Definition-file JSON Schema (../schema/v1/definitions.json). The contract
# tests in e2e/ resolve every reference, so a broken one fails `moon test`.
#
# usage: scripts/check-openapi.sh
#   It runs openapi-spec-validator with uvx, or with pipx when uvx is not
#   installed.
set -eu
cd "$(dirname "$0")/.."

validator_version=0.9.0
document=openapi/admin.json

if command -v uvx >/dev/null 2>&1; then
  set -- uvx --from "openapi-spec-validator==$validator_version" openapi-spec-validator
elif command -v pipx >/dev/null 2>&1; then
  set -- pipx run --spec "openapi-spec-validator==$validator_version" openapi-spec-validator
else
  echo "check-openapi: needs uvx or pipx to run openapi-spec-validator" >&2
  exit 2
fi

"$@" --schema 3.1 "$document"
