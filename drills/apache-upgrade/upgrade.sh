#!/usr/bin/env bash
# Upgrade Apache httpd with a gate: config test, side-by-side start, parity check, then cut over.
# Usage: ./upgrade.sh [old_tag] [new_tag] [config_file]
# Needs Docker. Takes about 20 seconds. Nothing leaves your machine.
set -euo pipefail
cd "$(dirname "$0")"

OLD="${1:-2.4.58-alpine}"
NEW="${2:-2.4-alpine}"
CONF="${3:-conf/httpd.conf}"
PORT=18081
CANDIDATE_PORT=18082

cleanup() { docker rm -f apache-live apache-candidate >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

run() {  # name tag port conf
  docker run -d --name "$1" -p "127.0.0.1:$3:80" \
    -v "$PWD/conf:/usr/local/apache2/conf-extra:ro" \
    "httpd:$2" httpd -DFOREGROUND -f "/usr/local/apache2/conf-extra/$(basename "$4")" >/dev/null
}
wait_for() {  # port
  for _ in $(seq 1 20); do
    curl -fs --max-time 1 "http://127.0.0.1:$1/healthz" -o /dev/null && return 0
    sleep 0.5
  done
  return 1
}
version() { curl -sI "http://127.0.0.1:$1/" | tr -d '\r' | awk -F': ' 'tolower($1)=="server"{print $2}'; }

echo "1. start the live server on httpd:$OLD"
run apache-live "$OLD" "$PORT" conf/httpd.conf
wait_for "$PORT" || { echo "live server did not start"; exit 1; }
echo "   live:      $(version "$PORT")"

echo "2. config test on httpd:$NEW with $CONF"
if ! OUT=$(docker run --rm -v "$PWD/conf:/usr/local/apache2/conf-extra:ro" "httpd:$NEW" \
     httpd -t -f "/usr/local/apache2/conf-extra/$(basename "$CONF")" 2>&1); then
  echo "$OUT" | sed 's/^/   /'
  echo "   GATE FAILED: config test rejected. Live server untouched, still $(version "$PORT")"
  exit 2
fi
echo "$OUT" | sed 's/^/   /'

echo "3. start the candidate on httpd:$NEW beside it"
run apache-candidate "$NEW" "$CANDIDATE_PORT" "$CONF"
wait_for "$CANDIDATE_PORT" || { echo "   GATE FAILED: candidate never became healthy"; exit 3; }
echo "   candidate: $(version "$CANDIDATE_PORT")"

echo "4. parity check: same status and headers for / and /healthz"
for path in / /healthz; do
  a=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT$path")
  b=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$CANDIDATE_PORT$path")
  [ "$a" = "$b" ] || { echo "   GATE FAILED: $path returned $a live and $b on candidate"; exit 4; }
  echo "   $path: $a on both"
done
hdr() { curl -sI "http://127.0.0.1:$1/" | tr -d '\r' | grep -i '^x-content-type-options' ; }
[ "$(hdr "$PORT")" = "$(hdr "$CANDIDATE_PORT")" ] || { echo "   GATE FAILED: security header differs"; exit 4; }
echo "   X-Content-Type-Options: present on both"

echo "5. cut over: stop live, start the new version on the live port"
docker rm -f apache-live apache-candidate >/dev/null
run apache-live "$NEW" "$PORT" "$CONF"
wait_for "$PORT" || { echo "   cutover failed; roll back with: docker run httpd:$OLD"; exit 5; }
echo "   live now:  $(version "$PORT")"
echo "UPGRADE OK: $OLD to $NEW"
