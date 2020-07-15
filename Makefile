ifneq (,$(DAPPER_SOURCE))

# Running in Dapper

validate:
	$(DAPPER) ./scripts/validate.sh

else

# Not running in Dapper

include Makefile.dapper

endif

# Disable rebuilding Makefile
Makefile Makefile.dapper: ;
