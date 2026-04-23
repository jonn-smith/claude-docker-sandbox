FROM eclipse-temurin:17-jdk AS temurin

FROM node:22-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      git ca-certificates curl ripgrep vim sudo \
      python3 python3-pip python3-venv \
      build-essential && \
    rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

COPY --from=temurin /opt/java/openjdk /opt/java/openjdk

ENV CARGO_HOME=/usr/local/cargo \
    RUSTUP_HOME=/usr/local/rustup
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | \
      sh -s -- -y --no-modify-path --default-toolchain stable

RUN groupadd -g 1016 claude && \
    useradd -m -u 1015 -g 1016 -s /bin/bash claude && \
    echo "claude ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/claude && \
    chmod 440 /etc/sudoers.d/claude && \
    chown -R claude:claude /usr/local/cargo /usr/local/rustup

RUN python3 -m venv /opt/claude-venv && \
    /opt/claude-venv/bin/pip install --no-cache-dir --upgrade pip && \
    /opt/claude-venv/bin/pip install --no-cache-dir \
      numpy pandas matplotlib scipy scikit-learn seaborn \
      ipython jupyter requests && \
    chown -R claude:claude /opt/claude-venv

ENV JAVA_HOME=/opt/java/openjdk \
    PATH=/opt/claude-venv/bin:/usr/local/cargo/bin:/opt/java/openjdk/bin:$PATH

USER claude
WORKDIR /workspace
CMD ["claude"]
