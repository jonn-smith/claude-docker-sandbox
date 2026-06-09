FROM eclipse-temurin:17-jdk AS temurin

FROM node:22-slim

################################################################################

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      git ca-certificates curl ripgrep vim sudo gosu jq wget \
      openssh-client \
      python3 python3-pip python3-venv \
      build-essential

# For email notifications, docker-in-a-docker and other utils:
RUN DEBIAN_FRONTEND=noninteractive apt-get install -y postfix mailutils shellcheck docker.io procps

# Clean up APT stuff:
RUN rm -rf /var/lib/apt/lists/*

# Install claude code. Pinned — bumping CLAUDE_CODE_VERSION + `make
# rebuild` lands a newer release deterministically. Tracking "latest"
# silently here would make every rebuild non-reproducible, and a
# write-semantics change between unpinned builds is exactly the kind of
# thing that produced the bind-mounted-credentials persistence bug
# (see commit ee421d5).
ENV CLAUDE_CODE_VERSION=2.1.165
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && claude --version

COPY --from=temurin /opt/java/openjdk /opt/java/openjdk

ENV CARGO_HOME=/usr/local/cargo \
    RUSTUP_HOME=/usr/local/rustup
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
      sh -s -- -y --no-modify-path --default-toolchain stable

# CodeGraph: pre-indexed code knowledge graph exposed as an MCP stdio server.
# Bundle ships its own Node runtime — no compile, no extra deps. Claude Code
# spawns `codegraph serve --mcp` as a subprocess when shared settings.json
# declares the mcpServers.codegraph entry (configured in
# claude-sandbox-shared/.claude/settings.json).
#
# Version pinned. Bump CODEGRAPH_VERSION and `make rebuild` (forces --no-cache
# --pull) when a newer release is wanted; tracking "latest" silently in the
# image would make builds non-reproducible.
ENV CODEGRAPH_VERSION=v0.9.9
RUN curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh \
    | CODEGRAPH_INSTALL_DIR=/opt/codegraph CODEGRAPH_BIN_DIR=/usr/local/bin sh \
    && /usr/local/bin/codegraph --version

# Default UID/GID baked at build. The runtime entrypoint
# (uid-fixup-entrypoint.sh) remaps these to match the host invoker via
# HOST_UID / HOST_GID env vars, so a single image is portable across hosts.
#
# The base node:22-slim image ships a "node" user at UID 1000. If the host
# invoker is also UID 1000 (typical first user on Ubuntu/Debian), usermod
# would leave two passwd entries fighting for UID 1000 — getpwuid() then
# returns "node" first, sudo sees the effective user as "node" instead of
# "claude", and demands a password (NOPASSWD applies to claude only).
# Delete the node user up front so the remap is unambiguous.
RUN userdel -r node 2>/dev/null || true && \
    groupdel node 2>/dev/null || true && \
    groupadd -g 1015 claude && \
    useradd -m -u 1015 -g 1015 -s /bin/bash claude && \
    echo "claude ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/claude && \
    chmod 440 /etc/sudoers.d/claude && \
    chown -R claude:claude /usr/local/cargo /usr/local/rustup

RUN python3 -m venv /opt/claude-venv && \
    /opt/claude-venv/bin/pip install --no-cache-dir --upgrade pip && \
    /opt/claude-venv/bin/pip install --no-cache-dir \
      numpy pandas matplotlib scipy scikit-learn seaborn \
      ipython jupyter requests \
      "headroom-ai[proxy]==0.6.1" && \
    chown -R claude:claude /opt/claude-venv

# fiss-mcp lives on the HOST, not in the container. The launcher
# (run_claude_docker.sh) spawns it before docker run, passes the URL in via
# FISS_MCP_URL, and traps SIGEXIT to kill it after the container exits.
# This keeps gcloud, gsutil, google-cloud-* libs, and ~/.config/gcloud out
# of the container entirely, so the only reachable path from inside the
# sandbox to Terra/GCP is the MCP tools — read-only by default.

# Make the bulk dirs writable by any UID. The runtime entrypoint remaps the
# claude user to match the host invoker, but chown -R on hundreds of MB of
# wheels and toolchain files takes 10+ seconds on every container start. With
# world-writable perms baked at build time, the entrypoint can skip the chown
# entirely. Container is single-user (claude) so loosening perms here doesn't
# expand attack surface.
RUN chmod -R a+rwX /opt/claude-venv /usr/local/cargo /usr/local/rustup

ENV JAVA_HOME=/opt/java/openjdk \
    PATH=/opt/claude-venv/bin:/usr/local/cargo/bin:/opt/java/openjdk/bin:$PATH

################################################################################

# Files baked into the claude home dir. Container starts as root so the uid
# fixup entrypoint can usermod the claude user before dropping privileges.
COPY --chown=claude:claude msmtprc /home/claude/.msmtprc
RUN chmod 600 /home/claude/.msmtprc

COPY --chown=claude:claude start_dockerd.sh /home/claude/start_dockerd.sh
RUN chmod +x /home/claude/start_dockerd.sh

COPY --chown=claude:claude start_script.sh /home/claude/start_script.sh
RUN chmod +x /home/claude/start_script.sh

COPY uid-fixup-entrypoint.sh /usr/local/bin/uid-fixup-entrypoint.sh
RUN chmod +x /usr/local/bin/uid-fixup-entrypoint.sh

# Set up some helpful aliases:
RUN echo "alias ll='ls -l'" >> /home/claude/.bash_aliases

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/uid-fixup-entrypoint.sh"]
CMD ["/home/claude/start_script.sh"]

