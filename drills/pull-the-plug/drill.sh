#!/usr/bin/env bash
# Pull the plug on the primary site, watch traffic move to the backup, then fail back.
# Needs Docker and Python 3. Takes about 40 seconds. Nothing leaves your machine.
set -euo pipefail
cd "$(dirname "$0")"

URL="http://127.0.0.1:18080/"
LOG="$(mktemp -t ptp-probe.XXXXXX)"
trap 'docker compose down -v >/dev/null 2>&1 || true; rm -f "$LOG"' EXIT

docker compose up -d >/dev/null
echo "waiting for the primary site to pass its health check..."
for _ in $(seq 1 30); do
  [ "$(curl -s --max-time 1 "$URL" || true)" = "dc-east" ] && break
  sleep 1
done
[ "$(curl -s --max-time 1 "$URL")" = "dc-east" ] || { echo "dc-east never became healthy; run: docker compose logs"; exit 1; }

python3 probe.py "$URL" 36 "$LOG" &
PROBE=$!

sleep 6
STOP=$(python3 -c 'import time; print(time.time())')
echo "t+6s   pulling the plug on dc-east"
docker stop ptp-dc-east >/dev/null

sleep 14
START=$(python3 -c 'import time; print(time.time())')
echo "t+20s  bringing dc-east back"
docker start ptp-dc-east >/dev/null

wait "$PROBE"
python3 analyze.py "$LOG" "$STOP" "$START"
