VERSION = 0.0.1
TAG1 = claude-sandbox:$(VERSION)
TAG2 = claude-sandbox:latest

# Match the container's "claude" user to the host invoker so bind-mounted
# files end up owned by the right uid/gid on both sides. Override at build
# time if you need a fixed pair: `make CLAUDE_UID=1015 CLAUDE_GID=1016`.
CLAUDE_UID ?= $(shell id -u)
CLAUDE_GID ?= $(shell id -g)

all: build

build:
	docker build \
		--build-arg CLAUDE_UID=$(CLAUDE_UID) \
		--build-arg CLAUDE_GID=$(CLAUDE_GID) \
		-t $(TAG1) -t $(TAG2) .
