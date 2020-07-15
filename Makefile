DAPPER := ./.dapper -m bind

include Makefile.dapper

shell:
	$(DAPPER)

validate:
	$(DAPPER) ./scripts/validate.sh

# Disable rebuilding Makefile
Makefile Makefile.dapper: ;
