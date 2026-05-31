#!/bin/bash

################################################################################
# Update & Restart Script - Pull latest code from GitHub and restart services
# Usage: scripts/restart.sh
#
# This pulls the latest commits, rebuilds the Docker images if code or
# dependencies changed, and restarts the stack.
################################################################################

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${BLUE}→ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

# Run from the repo root regardless of where this script is invoked from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Restart & Update - Pull Latest Changes from GitHub"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check if git is installed
if ! command -v git &> /dev/null; then
    print_error "Git is not installed"
    exit 1
fi

# Check if we're in a git repository
if [ ! -d ".git" ]; then
    print_error "Not a git repository. Please run this from the project root."
    exit 1
fi

# Detect Docker Compose command (v2 plugin preferred, fall back to v1)
COMPOSE=""
if docker compose version &> /dev/null; then
    COMPOSE="docker compose"
elif command -v docker-compose &> /dev/null; then
    COMPOSE="docker-compose"
else
    print_error "Docker Compose not found (need 'docker compose' v2 or 'docker-compose' v1)"
    exit 1
fi

# Check if docker-compose.yml exists
if [ ! -f "docker-compose.yml" ]; then
    print_error "docker-compose.yml not found. Please run deployment first: scripts/deploy-production.sh"
    exit 1
fi

################################################################################
# Check if application is running
################################################################################
print_info "Checking if application is running..."

if ! $COMPOSE ps 2>/dev/null | grep -q "Up"; then
    print_error "Application is not running!"
    echo ""
    print_info "Current status:"
    $COMPOSE ps
    echo ""
    print_warning "Please deploy the application first: scripts/deploy-production.sh [domain] [email]"
    exit 1
fi

print_success "Application is running, proceeding with restart..."
echo ""

################################################################################
# Step 1: Check current status
################################################################################
print_info "[1/6] Checking current branch and status..."
CURRENT_BRANCH=$(git branch --show-current)
print_info "Current branch: $CURRENT_BRANCH"

# Check if there are uncommitted changes
if ! git diff-index --quiet HEAD --; then
    print_warning "You have uncommitted local changes!"
    echo ""
    git status --short
    echo ""
    read -p "Continue anyway? Local changes may be overwritten. (y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_error "Update cancelled"
        exit 1
    fi

    # Stash local changes
    print_info "Stashing local changes..."
    git stash
    print_success "Local changes stashed"
fi

echo ""

################################################################################
# Step 2: Fetch latest changes
################################################################################
print_info "[2/6] Fetching latest changes from GitHub..."
git fetch origin

# Check if there are updates
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/$CURRENT_BRANCH)

if [ "$LOCAL" = "$REMOTE" ]; then
    print_success "Already up to date — no new commits."
    echo ""
    # Rebuild + recreate so BOTH baked-in code changes (app.py is copied into the
    # image) and mounted config.json changes are applied, even when there is
    # nothing new to pull (e.g. after a manual git pull).
    print_info "Rebuilding & recreating services to apply current code/config..."
    $COMPOSE up -d --build --force-recreate
    print_success "Services rebuilt & restarted"
    echo ""
    print_info "Current services status:"
    $COMPOSE ps
    exit 0
fi

print_info "New commits available:"
git log --oneline HEAD..origin/$CURRENT_BRANCH | head -5
echo ""

################################################################################
# Step 3: Pull changes
################################################################################
print_info "[3/6] Pulling latest changes..."
git pull origin $CURRENT_BRANCH
print_success "Code updated successfully"
echo ""

################################################################################
# Step 4: Check if rebuild is needed
################################################################################
print_info "[4/6] Checking if Docker rebuild is needed..."
REBUILD_NEEDED=false

# Check if Dockerfile or requirements changed
if git diff HEAD@{1} HEAD --name-only | grep -qE "Dockerfile|requirements.txt|package.json|docker-compose.yml"; then
    print_warning "Docker configuration or dependencies changed"
    REBUILD_NEEDED=true
fi

# Check if backend code changed
if git diff HEAD@{1} HEAD --name-only | grep -qE "backend/.*\.py"; then
    print_info "Backend code changed"
    REBUILD_NEEDED=true
fi

# Check if frontend code changed
if git diff HEAD@{1} HEAD --name-only | grep -qE "frontend/.*\.(html|js|css)"; then
    print_info "Frontend code changed"
    REBUILD_NEEDED=true
fi

echo ""

################################################################################
# Step 5: Rebuild and restart
################################################################################
if [ "$REBUILD_NEEDED" = true ]; then
    print_info "[5/6] Rebuilding and restarting services..."

    # Show current containers before stopping
    print_info "Current containers:"
    $COMPOSE ps
    echo ""

    print_info "Building new images..."
    $COMPOSE build --quiet

    print_info "Restarting services with new build..."
    $COMPOSE up -d --build

    print_success "Services rebuilt and restarted"
else
    print_info "[5/6] Restarting services (no rebuild needed)..."
    $COMPOSE restart
    print_success "Services restarted"
fi

echo ""

################################################################################
# Step 6: Verify deployment
################################################################################
print_info "[6/6] Verifying deployment..."

# Wait for the backend to report healthy
printf "${BLUE}→ Waiting for backend"
BACKEND_READY=false
for i in $(seq 1 30); do
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
    print_warning "Backend health check timed out — check: scripts/logs.sh backend"
fi

# Confirm containers are up
if $COMPOSE ps | grep -q "Up"; then
    print_success "Containers are running"
else
    print_error "Some containers failed to start"
    print_info "Check logs with: scripts/logs.sh"
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
print_success "UPDATE COMPLETED SUCCESSFULLY!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Get domain from nginx config if available
DOMAIN=""
if [ -f "docker/nginx.conf" ]; then
    DOMAIN=$(grep -m1 "server_name" docker/nginx.conf | awk '{print $2}' | tr -d ';' | grep -v "_")
fi

# Display URLs
if [ -n "$DOMAIN" ] && [ "$DOMAIN" != "_" ]; then
    echo "Application accessible at:"
    echo ""
    echo -e "  🌐 Website:     \033]8;;https://$DOMAIN\033\\https://$DOMAIN\033]8;;\033\\"
    echo -e "  🔧 Backend API: \033]8;;https://$DOMAIN/api/\033\\https://$DOMAIN/api/\033]8;;\033\\"
    echo -e "  ❤️  Health:      \033]8;;https://$DOMAIN/api/health\033\\https://$DOMAIN/api/health\033]8;;\033\\"
else
    echo "Application accessible at:"
    echo ""
    echo -e "  🌐 Website:     \033]8;;http://localhost\033\\http://localhost\033]8;;\033\\"
    echo -e "  🔧 Backend API: \033]8;;http://localhost:8000/api/\033\\http://localhost:8000/api/\033]8;;\033\\"
    echo -e "  ❤️  Health:      \033]8;;http://localhost:8000/api/health\033\\http://localhost:8000/api/health\033]8;;\033\\"
fi

echo ""
echo -e "${GREEN}(Click links above to open in browser)${NC}"
echo ""

echo "Current status:"
$COMPOSE ps
echo ""
echo "Useful commands:"
echo "  • View logs:        scripts/logs.sh"
echo "  • Check status:     scripts/info.sh"
echo "  • Stop:             scripts/stop.sh"
echo ""
