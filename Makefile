
include Makefile.dapper

shell:
	./.dapper -m bind

# Disable rebuilding Makefile
Makefile Makefile.dapper: ;
