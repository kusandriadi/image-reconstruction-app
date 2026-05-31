#!/bin/bash

################################################################################
# Logs Script - View or tail application logs
#
# Usage: ./logs.sh [service] [options]
#
#   service   backend | frontend   (omit for all services)
#
# Options:
#   -n, --tail N    show the last N lines (default: 100)
#   --no-follow     print the logs once and exit (snapshot) instead of following
#   -h, --help      show this help
#
# Examples:
#   ./logs.sh                              # follow all logs (last 100 lines first)
#   ./logs.sh backend                      # follow backend logs
#   ./logs.sh backend -n 500               # follow backend, starting from last 500 lines
#   ./logs.sh frontend --no-follow -n 200  # last 200 frontend lines, then exit
################################################################################

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_error()  { echo -e "${RED}✗ $1${NC}"; }
print_info()   { echo -e "${BLUE}→ $1${NC}"; }
print_header() { echo -e "${CYAN}$1${NC}"; }

# Run from the repo root regardless of where this script is invoked from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

################################################################################
# Detect Docker Compose command (v2 plugin preferred, fall back to v1)
################################################################################
COMPOSE=""
if docker compose version &> /dev/null; then
    COMPOSE="docker compose"
elif command -v docker-compose &> /dev/null; then
    COMPOSE="docker-compose"
else
    print_error "Docker Compose not found (need 'docker compose' v2 or 'docker-compose' v1)"
    exit 1
fi

if [ ! -f "docker-compose.yml" ]; then
    print_error "docker-compose.yml not found"
    print_info "Run this script from the project root directory"
    exit 1
fi

################################################################################
# Parse arguments
################################################################################
SERVICE=""
TAIL_LINES="100"
FOLLOW=true

while [ $# -gt 0 ]; do
    case "$1" in
        backend|frontend)
            SERVICE="$1"
            ;;
        -n|--tail)
            shift
            TAIL_LINES="$1"
            ;;
        --no-follow)
            FOLLOW=false
            ;;
        -h|--help)
            echo "Usage: $0 [backend|frontend] [-n N] [--no-follow]"
            exit 0
            ;;
        *)
            print_error "Unknown argument: $1"
            echo "Usage: $0 [backend|frontend] [-n N] [--no-follow]"
            exit 1
            ;;
    esac
    shift
done

# Validate the tail value is a number
if ! echo "$TAIL_LINES" | grep -qE '^[0-9]+$'; then
    print_error "--tail expects a number, got: $TAIL_LINES"
    exit 1
fi

# Build the compose logs options
OPTS="--tail=$TAIL_LINES"
[ "$FOLLOW" = true ] && OPTS="$OPTS -f"

################################################################################
# Display logs
################################################################################
FOLLOW_NOTE=""
[ "$FOLLOW" = true ] && FOLLOW_NOTE=", following"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ -n "$SERVICE" ]; then
    print_header "  Logs: $SERVICE (last $TAIL_LINES lines$FOLLOW_NOTE)"
else
    print_header "  Logs: all services (last $TAIL_LINES lines$FOLLOW_NOTE)"
fi
[ "$FOLLOW" = true ] && print_info "Press Ctrl+C to exit"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# shellcheck disable=SC2086
if [ -n "$SERVICE" ]; then
    $COMPOSE logs $OPTS "$SERVICE"
else
    $COMPOSE logs $OPTS
fi
