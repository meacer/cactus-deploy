GO ?= gotip
REPO := https://github.com/meacer/cactus.git
CLONE_DIR := .cactus-src

.PHONY: build deploy setup clean

build:
	@if [ ! -d $(CLONE_DIR) ]; then git clone --depth 1 $(REPO) $(CLONE_DIR); fi
	cd $(CLONE_DIR) && git pull && GOOS=linux GOARCH=amd64 $(GO) build -o $(CURDIR)/bin/cactus ./cmd/cactus

deploy: build
	./deploy.sh

setup: build
	./deploy.sh --setup

clean:
	rm -rf $(CLONE_DIR) bin
