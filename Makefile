BASE_BRANCH ?= devel
GIT_EMAIL ?= release@submariner.io
GIT_NAME ?= Automated Release
SHELLCHECK_ARGS := scripts/lib/* scripts/*.sh
export BASE_BRANCH
export GIT_EMAIL
export GIT_NAME

ifneq (,$(DAPPER_SOURCE))

# Running in Dapper

include $(SHIPYARD_DIR)/Makefile.inc

CLUSTER_SETTINGS_FLAG = --cluster_settings $(DAPPER_SOURCE)/.shipyard.e2e.yml
override CLUSTERS_ARGS += $(CLUSTER_SETTINGS_FLAG)
override DEPLOY_ARGS += $(CLUSTER_SETTINGS_FLAG) --deploytool_broker_args '--service-discovery'

E2E_NEEDED = $(shell . scripts/lib/utils && \
    determine_target_release 2&> /dev/null && \
    read_release_file && \
    exit_on_branching && echo true)

config-git:
	git config --global user.email "$(GIT_EMAIL)";\
	git config --global user.name "$(GIT_NAME)"

subctl: config-git
	./scripts/subctl.sh $(SUBCTL_ARGS)

ifeq (true, $(E2E_NEEDED))
e2e: deploy
	./scripts/e2e.sh
else
e2e: ;
endif

clusters: images subctl

deploy: import-images

# [do-release] will run the release process for the current stage, creating tags and releasing images as needed
do-release: config-git images
	./scripts/do-release.sh

images:
	./scripts/images.sh

import-images: images
	./scripts/import-images.sh

release: config-git
	./scripts/release.sh

test-release:
	./scripts/test/release.sh

validate:
	./scripts/validate.sh

# This is requested by Shipyard but not needed
vendor/modules.txt: ;

else

# Not running in Dapper

Makefile.dapper:
	@echo Downloading $@
	@curl -sfLO https://raw.githubusercontent.com/submariner-io/shipyard/$(BASE_BRANCH)/$@

include Makefile.dapper

git-sync:
	-git fetch --all --tags

release: git-sync
release: GIT_NAME = $(shell git config --get user.name)
release: GIT_EMAIL = $(shell git config --get user.email)

endif

# Disable rebuilding Makefile
Makefile: ;
