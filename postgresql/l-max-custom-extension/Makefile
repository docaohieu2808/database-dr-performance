# PGXS build: make && make install, then CREATE EXTENSION my_extension;
MODULES   = my_extension
EXTENSION = my_extension
DATA      = my_extension--1.0.sql
PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
