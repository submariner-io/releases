ifneq (,$(DAPPER_SOURCE))

# Running in Dapper

include $(SHIPYARD_DIR)/Makefile.inc

CLUSTER_SETTINGS_FLAG = --cluster_settings $(DAPPER_SOURCE)/scripts/cluster_settings
override CLUSTERS_ARGS += $(CLUSTER_SETTINGS_FLAG)
override DEPLOY_ARGS += $(CLUSTER_SETTINGS_FLAG) --deploytool_broker_args '--service-discovery'

subctl:
	./scripts/subctl.sh $(SUBCTL_ARGS)

_e2e: deploy
	./scripts/e2e.sh

e2e:
	source $${DAPPER_SOURCE}/scripts/lib/utils; \
	determine_target_release; \
	read_release_file; \
	[ "$${release['status']}" != "released" ] || $(MAKE) _e2e

clusters: subctl

deploy: images

images:
	./scripts/images.sh

create-release:
	./scripts/release.sh

validate:
	./scripts/validate.sh

# This is requested by Shipyard but not needed
vendor/modules.txt: ;

else

# Not running in Dapper

include Makefile.dapper

endif

# Disable rebuilding Makefile
Makefile Makefile.dapper: ;
