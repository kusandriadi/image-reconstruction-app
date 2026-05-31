#!/bin/bash

################################################################################
# Log Collector - stream combined backend + frontend logs into date-rolled files
#
# Writes to logs/app-YYYY-MM-DD.log, one combined file per day, with each line
# tagged [backend] / [frontend]. The target filename is recomputed per line, so
# the file rolls over automatically at midnight.
#
# Usage: scripts/save-logs.sh [-f compose-file]
#   -f FILE   use an alternate compose file (e.g. docker-compose.local.yml)
#
# Runs in the foreground and keeps following until killed (systemd / nohup).
################################################################################

# Run from the repo root regardless of where invoked
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# Optional compose-file flag passthrough
CF=""
while [ $# -gt 0 ]; do
    case "$1" in
        -f) shift; CF="-f $1" ;;
        *)  echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
    shift
done

# Detect Docker Compose command (v2 plugin preferred, fall back to v1)
if docker compose version &> /dev/null; then
    COMPOSE="docker compose"
elif command -v docker-compose &> /dev/null; then
    COMPOSE="docker-compose"
else
    echo "Docker Compose not found (need 'docker compose' v2 or 'docker-compose' v1)" >&2
    exit 1
fi

LOG_DIR="$REPO_ROOT/logs"
mkdir -p "$LOG_DIR"

# Follow logs, reconnecting if the stream drops (e.g. containers recreated).
# --tail 0 means "only new lines", so reconnects don't re-dump history.
while true; do
    # shellcheck disable=SC2086
    $COMPOSE $CF logs -f --no-color --tail 0 2>&1 | \
    while IFS= read -r line; do
        # Compose prefixes each line as "service-1  | message"
        case "$line" in
            *"|"*)
                svc="${line%%|*}"
                msg="${line#*|}"
                msg="${msg# }"
                ;;
            *)
                svc=""
                msg="$line"
                ;;
        esac

        case "$svc" in
            *backend*)  tag="[backend] " ;;
            *frontend*) tag="[frontend]" ;;
            *)          tag="[other]   " ;;
        esac

        printf '%s %s %s\n' "$(date '+%H:%M:%S')" "$tag" "$msg" >> "$LOG_DIR/app-$(date +%F).log"
    done

    # Stream ended (stack down or recreated) — wait briefly and reconnect
    sleep 3
done
