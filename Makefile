GO ?= gotip
REPO ?= https://github.com/meacer/cactus.git
CACTUS_SRC ?= .cactus-src
CACTUS_BRANCH ?= mirror-checkpoint-cosignature
CACTUS_VM ?=
CACTUS_ZONE ?=
CACTUS_PROJECT ?=

# Only pass flags for vars actually given on the command line, so deploy.sh's
# own defaults apply when a var is left unset.
DEPLOY_FLAGS = $(if $(CACTUS_VM),--vm=$(CACTUS_VM)) $(if $(CACTUS_ZONE),--zone=$(CACTUS_ZONE)) $(if $(CACTUS_PROJECT),--project=$(CACTUS_PROJECT))

.PHONY: build deploy setup clean

build:
	@if [ "$(CACTUS_SRC)" = ".cactus-src" ] || [ "$(CACTUS_SRC)" = "$(CURDIR)/.cactus-src" ]; then \
		if [ ! -d "$(CACTUS_SRC)" ]; then git clone --no-checkout $(REPO) "$(CACTUS_SRC)"; fi; \
		cd "$(CACTUS_SRC)" && git fetch --depth 1 origin "$(CACTUS_BRANCH)" && git checkout -B "$(CACTUS_BRANCH)" FETCH_HEAD; \
	elif [ ! -d "$(CACTUS_SRC)" ]; then \
		echo "Error: CACTUS_SRC directory ($(CACTUS_SRC)) does not exist." >&2; \
		exit 1; \
	fi
	cd "$(CACTUS_SRC)" && GOOS=linux GOARCH=amd64 $(GO) build -o "$(CURDIR)/bin/cactus" ./cmd/cactus

deploy: build
	./deploy.sh $(DEPLOY_FLAGS)

setup: build
	./deploy.sh --setup $(DEPLOY_FLAGS)

clean:
	rm -rf .cactus-src bin
