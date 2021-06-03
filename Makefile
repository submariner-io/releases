BASE_BRANCH ?= devel

ifneq (,$(DAPPER_SOURCE))

# Running in Dapper

include $(SHIPYARD_DIR)/Makefile.inc

CLUSTER_SETTINGS_FLAG = --cluster_settings $(DAPPER_SOURCE)/scripts/cluster_settings
override CLUSTERS_ARGS += $(CLUSTER_SETTINGS_FLAG)
override DEPLOY_ARGS += $(CLUSTER_SETTINGS_FLAG) --deploytool_broker_args '--service-discovery'

ifneq (,$(filter dryrun,$(_using)))
override CREATE_RELEASE_ARGS += --dryrun
endif

TARGET_RELEASE = $(shell . scripts/lib/utils && determine_target_release 2&> /dev/null && echo $${file})

config-git:
	git config --global user.email "release@submariner.io";\
	git config --global user.name "Automated Release"

subctl: config-git
	./scripts/subctl.sh $(SUBCTL_ARGS)

e2e: $(if $(TARGET_RELEASE),deploy)
	./scripts/e2e.sh

clusters: images subctl

deploy: import-images

# [do-release] will run the release process for the current stage, creating tags and releasing images as needed
do-release: config-git images
	./scripts/do-release.sh $(DO_RELEASE_ARGS)

images:
	./scripts/images.sh

import-images: images
	./scripts/import-images.sh

release:
	./scripts/release.sh $(RELEASE_ARGS)

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
	git fetch --all --tags || :

release: git-sync

endif

# Disable rebuilding Makefile
Makefile: ;
