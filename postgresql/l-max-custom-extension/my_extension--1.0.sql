-- my_extension 1.0 install script
\echo Use "CREATE EXTENSION my_extension" to load this file. \quit

-- Composite type
CREATE TYPE my_point AS (
    x double precision,
    y double precision
);

-- C-backed functions (see my_extension.c)
CREATE FUNCTION my_add(integer, integer)
    RETURNS integer
    AS 'MODULE_PATHNAME', 'my_add'
    LANGUAGE C STRICT IMMUTABLE PARALLEL SAFE;

CREATE FUNCTION my_distance(my_point, my_point)
    RETURNS double precision
    AS 'MODULE_PATHNAME', 'my_distance'
    LANGUAGE C STRICT IMMUTABLE PARALLEL SAFE;

-- PL/pgSQL helper (no C needed)
CREATE FUNCTION my_clamp(val double precision, lo double precision, hi double precision)
    RETURNS double precision
    LANGUAGE plpgsql IMMUTABLE STRICT PARALLEL SAFE
AS $$
BEGIN
    RETURN GREATEST(lo, LEAST(hi, val));
END;
$$;

-- Aggregate with a transition function
CREATE FUNCTION my_running_sum_sfunc(state bigint, val integer)
    RETURNS bigint
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
AS $$ SELECT COALESCE(state, 0) + COALESCE(val, 0) $$;

CREATE AGGREGATE my_running_sum(integer) (
    SFUNC    = my_running_sum_sfunc,
    STYPE    = bigint,
    INITCOND = '0',
    PARALLEL = SAFE
);

-- DDL audit: an event trigger that records every DDL command in a log table
CREATE TABLE my_ddl_log (
    id              bigserial PRIMARY KEY,
    event_time      timestamptz NOT NULL DEFAULT now(),
    command_tag     text,
    object_type     text,
    object_identity text,
    in_extension    boolean
);

CREATE FUNCTION my_ddl_audit_trigger()
    RETURNS event_trigger
    LANGUAGE plpgsql
AS $$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT * FROM pg_event_trigger_ddl_commands() LOOP
        IF r.object_identity <> 'public.my_ddl_log' THEN
            INSERT INTO my_ddl_log (command_tag, object_type, object_identity, in_extension)
            VALUES (r.command_tag, r.object_type, r.object_identity, r.in_extension);
        END IF;
    END LOOP;
END;
$$;

CREATE EVENT TRIGGER my_ddl_audit
    ON ddl_command_end
    EXECUTE FUNCTION my_ddl_audit_trigger();
