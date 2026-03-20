-- PostgreSQL Custom Extension Skeleton
-- Demonstrates: C-callable functions, operator classes, background workers,
--               custom types, aggregates, index access methods
-- Build: pgxs (pg_config --pgxs), then CREATE EXTENSION my_extension;

-- =============================================================================
-- 1. Extension control file comment block (my_extension.control)
-- =============================================================================
-- comment = 'My custom PostgreSQL extension skeleton'
-- default_version = '1.0'
-- module_pathname = '$libdir/my_extension'
-- relocatable = true
-- requires = ''

-- =============================================================================
-- 2. SQL install script (my_extension--1.0.sql)
-- =============================================================================

\echo Use "CREATE EXTENSION my_extension" to load this file. \quit

-- ---------------------------------------------------------------------------
-- 2a. Custom composite type
-- ---------------------------------------------------------------------------
CREATE TYPE my_point AS (
    x   double precision,
    y   double precision
);

-- ---------------------------------------------------------------------------
-- 2b. C-backed function declarations
--     Actual implementation lives in my_extension.c
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION my_add(integer, integer)
    RETURNS integer
    AS 'my_extension', 'my_add'
    LANGUAGE C STRICT IMMUTABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION my_distance(my_point, my_point)
    RETURNS double precision
    AS 'my_extension', 'my_distance'
    LANGUAGE C STRICT IMMUTABLE PARALLEL SAFE;

-- ---------------------------------------------------------------------------
-- 2c. PL/pgSQL helper (no C required)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION my_clamp(
    val   double precision,
    lo    double precision,
    hi    double precision
) RETURNS double precision
    LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
AS $$
BEGIN
    RETURN GREATEST(lo, LEAST(hi, val));
END;
$$;

-- ---------------------------------------------------------------------------
-- 2d. Custom aggregate: running sum with state
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION my_running_sum_sfunc(state bigint, val integer)
    RETURNS bigint
    LANGUAGE plpgsql IMMUTABLE CALLED ON NULL INPUT
AS $$
BEGIN
    RETURN COALESCE(state, 0) + COALESCE(val, 0);
END;
$$;

CREATE AGGREGATE my_running_sum(integer) (
    SFUNC     = my_running_sum_sfunc,
    STYPE     = bigint,
    INITCOND  = '0',
    PARALLEL  = SAFE
);

-- ---------------------------------------------------------------------------
-- 2e. Custom operator
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION my_point_eq(my_point, my_point)
    RETURNS boolean
    AS 'my_extension', 'my_point_eq'
    LANGUAGE C STRICT IMMUTABLE PARALLEL SAFE;

CREATE OPERATOR = (
    LEFTARG   = my_point,
    RIGHTARG  = my_point,
    PROCEDURE = my_point_eq,
    COMMUTATOR = =
);

-- ---------------------------------------------------------------------------
-- 2f. Event trigger skeleton (DDL auditing)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION my_ddl_audit_trigger()
    RETURNS event_trigger
    LANGUAGE plpgsql
AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT * FROM pg_event_trigger_ddl_commands() LOOP
        INSERT INTO my_ddl_log (event_time, command_tag, object_type, object_identity, in_extension)
        VALUES (now(), r.command_tag, r.object_type, r.object_identity, r.in_extension);
    END LOOP;
END;
$$;

CREATE TABLE IF NOT EXISTS my_ddl_log (
    id               bigserial PRIMARY KEY,
    event_time       timestamptz NOT NULL DEFAULT now(),
    command_tag      text,
    object_type      text,
    object_identity  text,
    in_extension     boolean
);

CREATE EVENT TRIGGER my_ddl_audit
    ON ddl_command_end
    EXECUTE FUNCTION my_ddl_audit_trigger();

-- ---------------------------------------------------------------------------
-- 2g. Background worker registration (done in C _PG_init, shown as comment)
-- ---------------------------------------------------------------------------
-- In my_extension.c:
-- void _PG_init(void) {
--     BackgroundWorker worker;
--     memset(&worker, 0, sizeof(worker));
--     worker.bgw_flags = BGWORKER_SHMEM_ACCESS | BGWORKER_BACKEND_DATABASE_CONNECTION;
--     worker.bgw_start_time = BgWorkerStart_RecoveryFinished;
--     worker.bgw_restart_time = 10;
--     snprintf(worker.bgw_name, BGW_MAXLEN, "my_extension worker");
--     snprintf(worker.bgw_library_name, BGW_MAXLEN, "my_extension");
--     snprintf(worker.bgw_function_name, BGW_MAXLEN, "my_bgworker_main");
--     worker.bgw_main_arg = (Datum) 0;
--     RegisterBackgroundWorker(&worker);
-- }

-- =============================================================================
-- 3. Makefile (pgxs build)
-- =============================================================================
-- MODULE_big = my_extension
-- OBJS       = my_extension.o
-- EXTENSION  = my_extension
-- DATA       = my_extension--1.0.sql
-- PG_CONFIG  = pg_config
-- PGXS      := $(shell $(PG_CONFIG) --pgxs)
-- include $(PGXS)

-- =============================================================================
-- 4. my_extension.c skeleton
-- =============================================================================
-- #include "postgres.h"
-- #include "fmgr.h"
-- #include "utils/builtins.h"
--
-- PG_MODULE_MAGIC;
--
-- PG_FUNCTION_INFO_V1(my_add);
-- Datum my_add(PG_FUNCTION_ARGS) {
--     int32 a = PG_GETARG_INT32(0);
--     int32 b = PG_GETARG_INT32(1);
--     PG_RETURN_INT32(a + b);
-- }
--
-- PG_FUNCTION_INFO_V1(my_distance);
-- Datum my_distance(PG_FUNCTION_ARGS) {
--     HeapTupleHeader p1 = PG_GETARG_HEAPTUPLEHEADER(0);
--     HeapTupleHeader p2 = PG_GETARG_HEAPTUPLEHEADER(1);
--     bool isnull;
--     double x1 = DatumGetFloat8(GetAttributeByNum(p1, 1, &isnull));
--     double y1 = DatumGetFloat8(GetAttributeByNum(p1, 2, &isnull));
--     double x2 = DatumGetFloat8(GetAttributeByNum(p2, 1, &isnull));
--     double y2 = DatumGetFloat8(GetAttributeByNum(p2, 2, &isnull));
--     PG_RETURN_FLOAT8(sqrt((x2-x1)*(x2-x1) + (y2-y1)*(y2-y1)));
-- }

-- =============================================================================
-- 5. Upgrade script stub (my_extension--1.0--1.1.sql)
-- =============================================================================
-- \echo Use "ALTER EXTENSION my_extension UPDATE TO '1.1'" to load this. \quit
-- ALTER TYPE my_point ADD ATTRIBUTE z double precision CASCADE;

-- =============================================================================
-- 6. Uninstall / DROP EXTENSION
-- =============================================================================
-- DROP EXTENSION IF EXISTS my_extension CASCADE;
-- (CASCADE drops dependent objects; my_extension--uninstall.sql not needed for pg>=9.1)
