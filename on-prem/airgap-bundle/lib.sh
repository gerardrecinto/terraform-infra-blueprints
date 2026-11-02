#!/usr/bin/env bash
# Shared helpers for the air-gap bundle scripts.
set -euo pipefail

need() {
  command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1 (see README for install)" >&2; exit 2; }
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# image ref -> directory-safe name
safe_name() {
  echo "$1" | tr '/:@' '___'
}

# Strip a leading registry host and make sure single-name images live under library/.
repo_and_tag() {
  local ref="$1" first rest
  first="${ref%%/*}"
  case "$ref" in
    */*)
      case "$first" in
        *.*|*:*|localhost) rest="${ref#*/}" ;;
        *) rest="$ref" ;;
      esac
      ;;
    *) rest="library/$ref" ;;
  esac
  echo "$rest"
}
