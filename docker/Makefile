VERSION = 0.0.1
TAG1 = claude-sandbox:$(VERSION)
TAG2 = claude-sandbox:latest

all: build

build:
	docker build -t $(TAG1) -t $(TAG2) .
