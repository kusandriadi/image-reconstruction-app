#!/bin/bash

################################################################################
# Local (development) deployment for the Image Reconstruction App.
#
# Runs frontend (Nginx) + backend (FastAPI) via Docker Compose over plain HTTP
# on localhost — no domain or SSL required. Auto-downloads the model weights if
# they are missing. Waits until both services are actually ready before exiting.
#
# Usage: scripts/deploy-local.sh   (runnable from anywhere)
################################################################################

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_error()   { echo -e "${RED}✗ $1${NC}"; }
print_info()    { echo -e "${BLUE}→ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }

# Run from the repo root regardless of where this script is invoked from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

COMPOSE_FILE="docker-compose.local.yml"

# Detect Docker Compose command: v2 plugin ("docker compose") is preferred,
# falling back to the legacy v1 standalone binary ("docker-compose").
COMPOSE=""
detect_compose() {
    if docker compose version &> /dev/null; then
        COMPOSE="docker compose"
    elif command -v docker-compose &> /dev/null; then
        COMPOSE="docker-compose"
    fi
}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Image Reconstruction App - Local Deployment (HTTP)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

################################################################################
# Prerequisites
################################################################################
if ! command -v docker &> /dev/null; then
    print_error "Docker is not installed. Install it first: https://docs.docker.com/engine/install/"
    exit 1
fi

detect_compose
if [ -z "$COMPOSE" ]; then
    print_error "Docker Compose not found (need 'docker compose' v2 or 'docker-compose' v1)"
    exit 1
fi
print_success "Using Docker + $COMPOSE"

if [ ! -f "$COMPOSE_FILE" ]; then
    print_error "$COMPOSE_FILE not found in repository"
    exit 1
fi
echo ""

################################################################################
# Model files
################################################################################
print_info "Checking model files..."
if [ -f "backend/model/REAL-ESRGAN.pth" ] && [ -f "backend/model/ConvNext_REAL-ESRGAN.pth" ]; then
    print_success "Model files already present"
else
    print_info "Model files missing — downloading from GitHub Release (models-v1)..."
    bash "$SCRIPT_DIR/download-models.sh"
fi
echo ""

################################################################################
# Build & start
################################################################################
print_info "Building & starting containers (first run can take several minutes)..."
$COMPOSE -f "$COMPOSE_FILE" up -d --build
print_success "Containers started"
echo ""

################################################################################
# Wait until frontend & backend are fully ready
################################################################################
print_info "Waiting for frontend & backend to become ready..."

printf "${BLUE}→ Waiting for backend"
BACKEND_READY=false
for i in $(seq 1 40); do
    if curl -fs http://localhost:8000/api/health > /dev/null 2>&1; then
        BACKEND_READY=true
        break
    fi
    printf "."
    sleep 3
done
printf "${NC}\n"
if [ "$BACKEND_READY" = true ]; then
    print_success "Backend is healthy"
else
    print_error "Backend did not become healthy in time"
    print_info "Check logs with: scripts/logs.sh backend"
    exit 1
fi

printf "${BLUE}→ Waiting for frontend"
FRONTEND_READY=false
for i in $(seq 1 20); do
    if curl -fsI http://localhost > /dev/null 2>&1; then
        FRONTEND_READY=true
        break
    fi
    printf "."
    sleep 3
done
printf "${NC}\n"
if [ "$FRONTEND_READY" = true ]; then
    print_success "Frontend is serving"
else
    print_warning "Frontend not responding yet — check: scripts/logs.sh frontend"
fi

################################################################################
# Summary
################################################################################
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
print_success "LOCAL DEPLOYMENT COMPLETE — frontend & backend are live!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Open the app at:"
echo ""
echo -e "  🌐 Website:     \033]8;;http://localhost\033\\http://localhost\033]8;;\033\\"
echo -e "  🔧 Backend API: \033]8;;http://localhost:8000/api/\033\\http://localhost:8000/api/\033]8;;\033\\"
echo -e "  ❤️  Health:      \033]8;;http://localhost:8000/api/health\033\\http://localhost:8000/api/health\033]8;;\033\\"
echo ""
echo -e "${GREEN}(Click links above to open in browser)${NC}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Manage the application:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  • Status / info:   scripts/info.sh"
echo "  • Live logs:       scripts/logs.sh        (or: scripts/logs.sh backend|frontend)"
echo "  • Restart:         scripts/deploy-local.sh   (just re-run this script)"
echo "  • Stop:            scripts/stop.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
