/**
 * Embedded resources for self-contained CLI binary
 * These are read at build time and bundled into the compiled binary
 */

// Import worker.js as a text asset using Bun's built-in asset loading
// The `with { type: "text" }` tells Bun to inline the file content
import WORKER_JS_CONTENT from "../../dist/worker/worker.js" with { type: "text" };
export const WORKER_JS = WORKER_JS_CONTENT;

// Embedded Dockerfile (without test-helper)
export const DOCKERFILE = `FROM ubuntu:24.04

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
RUN apt-get update && apt-get install -y --no-install-recommends \\
    ca-certificates \\
    curl \\
    unzip \\
    fdisk \\
    util-linux \\
    kpartx \\
    e2fsprogs \\
    dosfstools \\
    nbd-client \\
    rsync \\
    zstd \\
    xz-utils \\
    parted \\
    && rm -rf /var/lib/apt/lists/*

# Install Bun runtime for TS worker
RUN curl -fsSL https://bun.sh/install | bash

# Add Bun to PATH
ENV PATH="/root/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Create working directory inside container
WORKDIR /work

# Copy TypeScript worker (built on host into dist)
COPY worker.js /usr/local/bin/resize-worker.js

# Default command: run TS worker with Bun
ENTRYPOINT ["/root/.bun/bin/bun", "/usr/local/bin/resize-worker.js"]
`;
