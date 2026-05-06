FROM eclipse-temurin:17-jdk AS temurin

FROM node:22-slim

################################################################################

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      git ca-certificates curl ripgrep vim sudo \
      python3 python3-pip python3-venv \
      build-essential

# For email notifications, docker-in-a-docker and other utils:
RUN DEBIAN_FRONTEND=noninteractive apt-get install -y postfix mailutils shellcheck docker.io procps 

# Clean up APT stuff:
RUN rm -rf /var/lib/apt/lists/*

# Install claude code:                                
RUN npm install -g @anthropic-ai/claude-code

COPY --from=temurin /opt/java/openjdk /opt/java/openjdk

ENV CARGO_HOME=/usr/local/cargo \
    RUSTUP_HOME=/usr/local/rustup
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
      sh -s -- -y --no-modify-path --default-toolchain stable

# UID/GID match the host user that built the image so bind-mounted files
# in /workspace and /home/claude/.claude have the right owner. Pass via
# `make` (CLAUDE_UID / CLAUDE_GID) — it auto-fills from $(id -u) / $(id -g).
ARG CLAUDE_UID=1015
ARG CLAUDE_GID=1016
RUN groupadd -g ${CLAUDE_GID} claude && \
    useradd -m -u ${CLAUDE_UID} -g ${CLAUDE_GID} -s /bin/bash claude && \
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

ENV JAVA_HOME=/opt/java/openjdk \
    PATH=/opt/claude-venv/bin:/usr/local/cargo/bin:/opt/java/openjdk/bin:$PATH

################################################################################

USER claude

# Setup Mail for claude user:
COPY --chown=claude:claude msmtprc /home/claude/.msmtprc
RUN chmod 600 /home/claude/.msmtprc

COPY --chown=claude:claude start_dockerd.sh /home/claude/start_dockerd.sh
RUN chmod +x /home/claude/start_dockerd.sh

COPY --chown=claude:claude start_script.sh /home/claude/start_script.sh 
RUN chmod +x /home/claude/start_script.sh

# Set up some helpful aliases:
RUN echo "alias ll='ls -l'" >> /home/claude/.bash_aliases

WORKDIR /workspace
CMD ["/home/claude/start_script.sh"]

