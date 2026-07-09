GO ?= gotip
REPO ?= https://github.com/meacer/cactus.git
CACTUS_SRC ?= .cactus-src

.PHONY: build deploy setup clean

build:
	@if [ "$(CACTUS_SRC)" = ".cactus-src" ] || [ "$(CACTUS_SRC)" = "$(CURDIR)/.cactus-src" ]; then \
		if [ ! -d "$(CACTUS_SRC)" ]; then git clone --depth 1 $(REPO) "$(CACTUS_SRC)"; fi; \
		cd "$(CACTUS_SRC)" && git pull; \
	elif [ ! -d "$(CACTUS_SRC)" ]; then \
		echo "Error: CACTUS_SRC directory ($(CACTUS_SRC)) does not exist." >&2; \
		exit 1; \
	fi
	cd "$(CACTUS_SRC)" && GOOS=linux GOARCH=amd64 $(GO) build -o "$(CURDIR)/bin/cactus" ./cmd/cactus

deploy: build
	./deploy.sh

setup: build
	./deploy.sh --setup

clean:
	rm -rf .cactus-src bin
