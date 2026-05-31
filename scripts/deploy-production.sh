#!/bin/bash

################################################################################
# One-shot production deployment for the Image Reconstruction App.
# Runs frontend (Nginx) + backend (FastAPI) via Docker Compose, auto-downloads
# the model weights, and provisions a Let's Encrypt SSL certificate for the domain.
#
# Usage: scripts/deploy-production.sh [your-domain.com] [your-email@example.com]
# Run from the repository root.
################################################################################

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
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

# Detect available Docker Compose command. The v2 plugin ("docker compose") is
# preferred; fall back to the legacy v1 standalone binary ("docker-compose").
# Sets the global COMPOSE variable (empty if neither is available yet).
COMPOSE=""
detect_compose() {
    if docker compose version &> /dev/null; then
        COMPOSE="docker compose"
    elif command -v docker-compose &> /dev/null; then
        COMPOSE="docker-compose"
    else
        COMPOSE=""
    fi
}

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    print_error "Please do not run as root. Use a regular user with sudo privileges."
    exit 1
fi

# Parse arguments
DOMAIN=${1:-}
EMAIL=${2:-}

if [ -z "$DOMAIN" ]; then
    print_error "Usage: scripts/deploy-production.sh [your-domain.com] [your-email@example.com]"
    echo ""
    echo "Example: scripts/deploy.sh example.com admin@example.com"
    exit 1
fi

if [ -z "$EMAIL" ]; then
    print_error "Email is required for SSL certificate"
    print_error "Usage: scripts/deploy-production.sh [your-domain.com] [your-email@example.com]"
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Image Reconstruction App - Automated VPS Deployment"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
print_info "Domain: $DOMAIN"
print_info "Email: $EMAIL"
echo ""

################################################################################
# Check if application is already running
################################################################################
print_info "Checking if application is already running..."

detect_compose
if [ -n "$COMPOSE" ] && [ -f "docker-compose.yml" ]; then
    if $COMPOSE ps 2>/dev/null | grep -q "Up"; then
        print_error "Application is already running!"
        echo ""
        print_info "Current status:"
        $COMPOSE ps
        echo ""
        print_warning "Please stop the application first using: scripts/stop.sh"
        print_warning "Or use restart script to update: scripts/restart.sh"
        exit 1
    fi
fi

print_success "No running application detected, proceeding with deployment..."
echo ""

################################################################################
# Step 1: Update system
################################################################################
print_info "[1/11] Updating system packages..."
sudo apt update -qq && sudo apt upgrade -y -qq
print_success "System updated"
echo ""

################################################################################
# Step 2: Install Docker
################################################################################
print_info "[2/11] Installing Docker..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh > /dev/null
    sudo usermod -aG docker $USER
    rm get-docker.sh
    print_success "Docker installed"
else
    print_success "Docker already installed ($(docker --version))"
fi
echo ""

################################################################################
# Step 3: Install Docker Compose
################################################################################
print_info "[3/11] Setting up Docker Compose..."
detect_compose
if [ "$COMPOSE" = "docker compose" ]; then
    print_success "Using Docker Compose v2 plugin ($(docker compose version --short 2>/dev/null))"
elif [ "$COMPOSE" = "docker-compose" ]; then
    print_success "Using Docker Compose v1 ($(docker-compose --version))"
else
    print_info "Docker Compose not found, installing v1 standalone binary..."
    sudo curl -sL "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
    detect_compose
    if [ -n "$COMPOSE" ]; then
        print_success "Docker Compose installed ($COMPOSE)"
    else
        print_error "Failed to set up Docker Compose"
        exit 1
    fi
fi
echo ""

################################################################################
# Step 4: Create data directories
################################################################################
print_info "[4/11] Creating data directories..."
mkdir -p backend/data/uploads
mkdir -p backend/data/outputs
chmod 755 backend/data/uploads backend/data/outputs
print_success "Data directories created"
echo ""

################################################################################
# Step 5: Check model files
################################################################################
print_info "[5/11] Checking model files..."
MODEL_FOUND=false
if [ -f "backend/model/REAL-ESRGAN.pth" ] && [ -f "backend/model/ConvNext_REAL-ESRGAN.pth" ]; then
    MODEL_FOUND=true
    print_success "Model files already present"
else
    print_info "Model files missing — downloading from GitHub Release (models-v1)..."
    if bash "$(dirname "$0")/download-models.sh"; then
        MODEL_FOUND=true
        print_success "Model files downloaded"
    else
        print_warning "Automatic model download failed"
        read -p "Continue without model files? (y/N) " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_error "Deployment cancelled. Run scripts/download-models.sh manually, then retry."
            exit 1
        fi
    fi
fi
echo ""

################################################################################
# Step 6: Configure firewall
################################################################################
print_info "[6/11] Configuring firewall..."
sudo ufw --force enable > /dev/null 2>&1
sudo ufw allow 22/tcp > /dev/null 2>&1
sudo ufw allow 80/tcp > /dev/null 2>&1
sudo ufw allow 443/tcp > /dev/null 2>&1
print_success "Firewall configured (ports 22, 80, 443 open)"
echo ""

################################################################################
# Step 7: Update config.json
################################################################################
print_info "[7/11] Updating config.json..."
if [ -f "config.json" ]; then
    # Backup original config
    cp config.json config.json.backup

    # Update backend_url using sed (cross-platform compatible)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        sed -i '' "s|\"backend_url\": \".*\"|\"backend_url\": \"https://$DOMAIN\"|g" config.json
    else
        # Linux
        sed -i "s|\"backend_url\": \".*\"|\"backend_url\": \"https://$DOMAIN\"|g" config.json
    fi
    print_success "config.json updated (backup: config.json.backup)"
else
    print_error "config.json not found"
    exit 1
fi
echo ""

################################################################################
# Step 8: Install Certbot and generate SSL certificate
################################################################################
print_info "[8/11] Setting up SSL certificate..."

# Stop any running containers to free up port 80
$COMPOSE down 2>/dev/null || true

# Install Certbot
if ! command -v certbot &> /dev/null; then
    print_info "Installing Certbot..."
    sudo apt install certbot -y -qq
fi

# Generate certificate
print_info "Generating SSL certificate (this may take a minute)..."
sudo certbot certonly --standalone \
    -d "$DOMAIN" \
    -d "www.$DOMAIN" \
    --email "$EMAIL" \
    --agree-tos \
    --non-interactive \
    --keep-until-expiring \
    2>&1 | grep -v "Saving debug log"

if [ $? -eq 0 ]; then
    print_success "SSL certificate generated successfully"
else
    print_error "Failed to generate SSL certificate"
    print_warning "Make sure your domain DNS is pointing to this server"
    exit 1
fi
echo ""

################################################################################
# Step 9: Configure Nginx with SSL
################################################################################
print_info "[9/11] Configuring Nginx with SSL for $DOMAIN..."

# Use the committed docker/nginx.conf as the source of truth and only template
# the domain into it in place. We intentionally do NOT overwrite the whole file,
# so any committed hardening (security headers, rate limiting, etc.) is preserved
# across deploys instead of being discarded.
if [ ! -f "docker/nginx.conf" ]; then
    print_error "docker/nginx.conf not found in repository"
    exit 1
fi

if [ "$DOMAIN" != "pixup.id" ]; then
    sed -i "s/pixup\.id/$DOMAIN/g" docker/nginx.conf
fi

print_success "Nginx configuration templated for $DOMAIN"
echo ""

################################################################################
# Step 10: Update docker-compose.yml and start services
################################################################################
print_info "[10/11] Building and starting Docker services..."

# Use the committed docker-compose.yml as-is rather than regenerating it, so
# fixes committed to the repo (e.g. the healthcheck) are not silently reverted.
if [ ! -f "docker-compose.yml" ]; then
    print_error "docker-compose.yml not found in repository"
    exit 1
fi

# Build and start services
print_info "Cleaning Docker cache..."
docker builder prune -f > /dev/null 2>&1

print_info "Building Docker images (this may take several minutes)..."
$COMPOSE build --no-cache --quiet

print_info "Starting services..."
$COMPOSE up -d

print_success "Services started"
echo ""

################################################################################
# Step 11: Setup SSL auto-renewal
################################################################################
print_info "[11/11] Setting up SSL auto-renewal..."

# Get the current working directory
CURRENT_DIR=$(pwd)

# Create renewal hook script
sudo mkdir -p /etc/letsencrypt/renewal-hooks/post
sudo tee /etc/letsencrypt/renewal-hooks/post/restart-nginx.sh > /dev/null << EOF
#!/bin/bash
cd $CURRENT_DIR
$COMPOSE restart frontend
EOF

sudo chmod +x /etc/letsencrypt/renewal-hooks/post/restart-nginx.sh

print_success "SSL auto-renewal configured"
echo ""

################################################################################
# Wait for services to be fully ready
################################################################################
print_info "Waiting for frontend & backend to become ready (this can take a minute)..."

# Wait for the backend to report healthy
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

# Wait for the frontend (Nginx). Port 80 returns a 301 redirect to HTTPS, which
# still proves Nginx is up and serving.
printf "${BLUE}→ Waiting for frontend"
FRONTEND_READY=false
for i in $(seq 1 20); do
    if curl -fsI http://localhost > /dev/null 2>&1 || curl -fskI https://localhost > /dev/null 2>&1; then
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

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
print_success "DEPLOYMENT COMPLETE — frontend & backend are live!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Your website is now live at:"
echo ""
echo -e "  🌐 Website:     \033]8;;https://$DOMAIN\033\\https://$DOMAIN\033]8;;\033\\"
echo -e "  🔧 Backend API: \033]8;;https://$DOMAIN/api/\033\\https://$DOMAIN/api/\033]8;;\033\\"
echo -e "  ❤️  Health:      \033]8;;https://$DOMAIN/api/health\033\\https://$DOMAIN/api/health\033]8;;\033\\"
echo ""
echo -e "${GREEN}(Click links above to open in browser)${NC}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Manage the application:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  • Status / info:    scripts/info.sh"
echo "  • Live logs:        scripts/logs.sh        (or: scripts/logs.sh backend|frontend)"
echo "  • Restart / update: scripts/restart.sh"
echo "  • Stop:             scripts/stop.sh"
echo "  • Test SSL renewal: sudo certbot renew --dry-run"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
print_success "SSL certificate will auto-renew automatically"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ "$MODEL_FOUND" = false ]; then
    print_warning "REMINDER: Model files were not found during deployment"
    print_warning "Upload them to backend/model/ and restart: $COMPOSE restart backend"
    echo ""
fi
