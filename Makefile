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

config-git:
	git config --global user.email "release@submariner.io";\
	git config --global user.name "Automated Release"

subctl: config-git
	./scripts/subctl.sh $(SUBCTL_ARGS)

e2e: deploy
	./scripts/e2e.sh

clusters: images subctl

deploy: import-images

images:
	./scripts/images.sh

import-images: images
	./scripts/import-images.sh

create-release: config-git images
	./scripts/release.sh $(CREATE_RELEASE_ARGS)

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

endif

# Disable rebuilding Makefile
Makefile: ;
