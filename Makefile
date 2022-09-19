BASE_BRANCH ?= devel
GIT_EMAIL ?= release@submariner.io
GIT_NAME ?= Automated Release
SHELLCHECK_ARGS := scripts/*.sh scripts/lib/* scripts/test/*
export BASE_BRANCH
export GIT_EMAIL
export GIT_NAME

ifneq (,$(DAPPER_SOURCE))

# Running in Dapper

include $(SHIPYARD_DIR)/Makefile.inc

export SETTINGS = $(DAPPER_SOURCE)/.shipyard.e2e.yml

_E2E_CANARY = E2E CANARY
E2E_NEEDED = $(shell . scripts/lib/utils && \
    determine_target_release 2&> /dev/null && \
    read_release_file && \
    exit_on_branching && echo $(_E2E_CANARY))

config-git:
	git config --global user.email "$(GIT_EMAIL)";\
	git config --global user.name "$(GIT_NAME)"

subctl: config-git
	./scripts/subctl.sh $(SUBCTL_ARGS)

ifneq (, $(findstring $(_E2E_CANARY),$(E2E_NEEDED)))

# TODO: Figure out how to dynamically load correct images
override PRELOAD_IMAGES=submariner-gateway submariner-route-agent submariner-globalnet submariner-operator

# Make sure that for E2E subctl gets compiled with the base branch, or it'll try to deploy images that werent published yet.
e2e: export DEFAULT_IMAGE_VERSION=$(BASE_BRANCH)
e2e: deploy
else
e2e:
	@echo No release detected, not running E2E
endif

clusters: images subctl

images:
	./scripts/images.sh

# [do-release] will run the release process for the current stage, creating tags and releasing images as needed
do-release: config-git
	./scripts/do-release.sh

release: config-git
	./scripts/release.sh

test-%:
	./scripts/test/$*.sh

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
