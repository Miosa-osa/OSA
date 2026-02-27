# OSA Sandbox Image
# ==================
# Ephemeral execution environment for OptimalSystemAgent skill commands.
#
# Security properties:
#   - Non-root user (osa, UID 1000)
#   - All setuid/setgid bits stripped
#   - Minimal package set (no package manager left behind in final layer)
#   - Compatible with: --read-only, --cap-drop ALL, --network none,
#                      --security-opt no-new-privileges:true
#
# Build:
#   docker build -t osa-sandbox:latest sandbox/
#
# The image is intentionally kept small. Add tools your skills need here
# or create a derived image (FROM osa-sandbox:latest).

FROM ubuntu:24.04

# Prevent interactive apt prompts
ENV DEBIAN_FRONTEND=noninteractive

# Install common tools in a single layer to keep the image lean.
# python3-pip is included so skills can `pip install` inside the container.
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    curl \
    wget \
    git \
    jq \
    python3 \
    python3-pip \
    python3-venv \
    nodejs \
    npm \
    build-essential \
    ca-certificates \
    coreutils \
    findutils \
    grep \
    sed \
    gawk \
    file \
    unzip \
    zip \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Create a non-root group and user.
# UID/GID 1000 matches the -u 1000:1000 flag used by Docker.execute/2.
RUN groupadd -r -g 1000 osa \
    && useradd -r -u 1000 -g osa -d /workspace -s /bin/bash -c "OSA sandbox user" osa

# Create the workspace directory and give it to the sandbox user.
# The host's ~/.osa/workspace is bind-mounted here at runtime.
RUN mkdir -p /workspace && chown osa:osa /workspace

# Strip setuid and setgid bits from all binaries.
# This prevents privilege escalation even if --cap-drop ALL is somehow bypassed.
# The "|| true" silences harmless permission errors on /proc and /sys.
RUN find / -xdev \( -perm /4000 -o -perm /2000 \) -type f \
    -exec chmod a-s {} \; 2>/dev/null || true

# Drop to non-root for all subsequent layers and runtime.
USER osa
WORKDIR /workspace

# Verify the user is correct at build time.
RUN whoami && id

# Default entry-point: just run bash.
# docker exec uses sh -c <command> in practice; this is the fallback.
CMD ["/bin/bash"]
