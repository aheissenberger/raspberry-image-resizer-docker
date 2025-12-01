FROM ubuntu:24.04

# Metadata
LABEL maintainer="Raspberry Pi Image Resizer"
LABEL description="Docker image for resizing Raspberry Pi disk images"
LABEL version="1.0"

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install all required tools for partition manipulation and filesystem operations
# In Ubuntu 24.04, fdisk is in the fdisk package (separate from util-linux)
# Compression tools: zstd, xz-utils (gzip is pre-installed)
# curl and ca-certificates are needed for Bun installation
# bash is required for test helpers
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    unzip \
    bash \
    fdisk \
    util-linux \
    kpartx \
    e2fsprogs \
    dosfstools \
    rsync \
    zstd \
    xz-utils \
    parted \
    && rm -rf /var/lib/apt/lists/*

# Install Bun runtime for TS worker
RUN curl -fsSL https://bun.sh/install | bash

# Add Bun to PATH
ENV PATH="/root/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Create working directory inside container
WORKDIR /work

# Copy TypeScript worker and test helper (built on host into dist)
COPY dist/worker/worker.js /usr/local/bin/resize-worker.js
COPY dist/test/test-helper.js /usr/local/bin/test-helper.js

# Default command: run TS worker with Bun
ENTRYPOINT ["/root/.bun/bin/bun", "/usr/local/bin/resize-worker.js"]
