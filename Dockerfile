# Multi-stage Dockerfile for Image Reconstruction Backend
# Optimized for production deployment with PyTorch

FROM python:3.10-slim as base

# Set environment variables
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy requirements first for better caching
COPY backend/requirements.txt /app/backend/requirements.txt

# Install Python dependencies
RUN pip install --no-cache-dir -r backend/requirements.txt

# Copy application code
COPY backend/ /app/backend/
COPY config.json /app/config.json

# Create necessary directories
RUN mkdir -p /app/backend/data/uploads \
    && mkdir -p /app/backend/data/outputs \
    && mkdir -p /app/backend/model

# Note: Model files will be mounted as volumes at runtime
# No need to copy them during build

# Expose port
EXPOSE 8000

# Health check (uses stdlib urllib; curl/requests are not installed in slim image)
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/api/health')" || exit 1

# Run the application
CMD ["uvicorn", "backend.app:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
