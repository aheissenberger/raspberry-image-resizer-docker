FROM ubuntu:24.04

# Metadata
LABEL maintainer="Raspberry Pi Image Resizer"
LABEL description="Docker image for resizing Raspberry Pi disk images"
LABEL version="1.0"

# Avoid interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install all required tools for partition manipulation and filesystem operations
# In Ubuntu 24.04, fdisk is in the fdisk package (separate from util-linux)
RUN apt-get update && apt-get install -y \
    parted \
    fdisk \
    util-linux \
    kpartx \
    e2fsprogs \
    dosfstools \
    file \
    rsync \
    && rm -rf /var/lib/apt/lists/*

# Add common binary paths to PATH
ENV PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Create working directory inside container
WORKDIR /work

# Copy the internal worker script
COPY src/resize-worker.sh /usr/local/bin/resize-worker.sh
RUN chmod +x /usr/local/bin/resize-worker.sh

# Default command
ENTRYPOINT ["/usr/local/bin/resize-worker.sh"]
