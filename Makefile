CACTUS_VM ?=
CACTUS_ZONE ?=
CACTUS_PROJECT ?=

# Only pass flags for vars actually given on the command line, so docker-deploy.sh's
# own defaults apply when a var is left unset.
DEPLOY_FLAGS = $(if $(CACTUS_VM),--vm=$(CACTUS_VM)) $(if $(CACTUS_ZONE),--zone=$(CACTUS_ZONE)) $(if $(CACTUS_PROJECT),--project=$(CACTUS_PROJECT))

.PHONY: deploy setup clean

deploy:
	./docker-deploy.sh $(DEPLOY_FLAGS)

setup:
	./docker-deploy.sh --setup-firewall $(DEPLOY_FLAGS)

clean:
	rm -rf out
