-- An audit history is important on most tables. Provide an audit trigger that logs to
-- a dedicated audit table for the major relations.
--
-- This file should be generic and not depend on application roles or structures,
-- as it's being listed here:
--
--    https://wiki.postgresql.org/wiki/Audit_trigger_91plus    
--
-- This trigger was originally based on
--   http://wiki.postgresql.org/wiki/Audit_trigger
-- but has been completely rewritten.
--
-- Should really be converted into a relocatable EXTENSION, with control and upgrade files.

CREATE EXTENSION IF NOT EXISTS hstore;

CREATE SCHEMA audit;
REVOKE ALL ON SCHEMA audit FROM PUBLIC;

COMMENT ON SCHEMA audit IS 'Out-of-table audit/history logging tables and trigger functions';

--
-- Audited data. Lots of information is available, it's just a matter of how much
-- you really want to record. See:
--
--   http://www.postgresql.org/docs/9.1/static/functions-info.html
--
-- Remember, every column you add takes up more audit table space and slows audit
-- inserts.
--
-- Every index you add has a big impact too, so avoid adding indexes to the
-- audit table unless you REALLY need them. The hstore GIST indexes are
-- particularly expensive.
--
-- It is sometimes worth copying the audit table, or a coarse subset of it that
-- you're interested in, into a temporary table where you CREATE any useful
-- indexes and do your analysis.
--
DROP TABLE IF EXISTS audit.logged_actions;

CREATE TABLE audit.logged_actions (
    event_id          BIGSERIAL PRIMARY KEY,
    schema_name       TEXT                     NOT NULL,
    table_name        TEXT                     NOT NULL,
    row_id            INT,
    relid             OID                      NOT NULL,
    --     session_user_name text,
    --     action_tstamp_tx TIMESTAMP WITH TIME ZONE NOT NULL,
    action_tstamp_stm TIMESTAMP WITH TIME ZONE NOT NULL,
    --     action_tstamp_clk TIMESTAMP WITH TIME ZONE NOT NULL,
    --     transaction_id bigint,
    --     application_name text,
    --     client_addr inet,
    --     client_port integer,
    client_query      TEXT                     NOT NULL,
    action            TEXT                     NOT NULL CHECK (action IN ('I', 'D', 'U', 'T')),
    row_data          HSTORE,
    changed_fields    HSTORE,
    statement_only    BOOLEAN                  NOT NULL
);

REVOKE ALL ON audit.logged_actions FROM PUBLIC;

COMMENT ON TABLE audit.logged_actions IS 'History of auditable actions on audited tables, from audit.if_modified_func()';
COMMENT ON COLUMN audit.logged_actions.event_id IS 'Unique identifier for each auditable event';
COMMENT ON COLUMN audit.logged_actions.schema_name IS 'Database schema audited table for this event is in';
COMMENT ON COLUMN audit.logged_actions.table_name IS 'Non-schema-qualified table name of table event occured in';
COMMENT ON COLUMN audit.logged_actions.row_id IS 'Row id field from table.';
COMMENT ON COLUMN audit.logged_actions.relid IS 'Table OID. Changes with drop/create. Get with ''tablename''::regclass';
-- COMMENT ON COLUMN audit.logged_actions.session_user_name IS 'Login / session user whose statement caused the audited event';
-- COMMENT ON COLUMN audit.logged_actions.action_tstamp_tx IS 'Transaction start timestamp for tx in which audited event occurred';
COMMENT ON COLUMN audit.logged_actions.action_tstamp_stm IS 'Statement start timestamp for tx in which audited event occurred';
-- COMMENT ON COLUMN audit.logged_actions.action_tstamp_clk IS 'Wall clock time at which audited event''s trigger call occurred';
-- COMMENT ON COLUMN audit.logged_actions.transaction_id IS 'Identifier of transaction that made the change. May wrap, but unique paired with action_tstamp_tx.';
-- COMMENT ON COLUMN audit.logged_actions.application_name IS 'Application name set when this audit event occurred. Can be changed in-session by client.';
-- COMMENT ON COLUMN audit.logged_actions.client_addr IS 'IP address of client that issued query. Null for unix domain socket.';
-- COMMENT ON COLUMN audit.logged_actions.client_port IS 'Remote peer IP port address of client that issued query. Undefined for unix socket.';
COMMENT ON COLUMN audit.logged_actions.client_query IS 'Top-level query that caused this auditable event. May be more than one statement.';
COMMENT ON COLUMN audit.logged_actions.action IS 'Action type; I = insert, D = delete, U = update, T = truncate';
COMMENT ON COLUMN audit.logged_actions.row_data IS 'Record value. Null for statement-level trigger. For INSERT this is the new tuple. For DELETE and UPDATE it is the old tuple.';
COMMENT ON COLUMN audit.logged_actions.changed_fields IS 'New values of fields changed by UPDATE. Null except for row-level UPDATE events.';
COMMENT ON COLUMN audit.logged_actions.statement_only IS '''t'' if audit event is from an FOR EACH STATEMENT trigger, ''f'' for FOR EACH ROW';

CREATE INDEX logged_actions_relid_idx
    ON audit.logged_actions (relid);
CREATE INDEX logged_actions_action_tstamp_tx_stm_idx
    ON audit.logged_actions (action_tstamp_stm);
CREATE INDEX logged_actions_action_idx
    ON audit.logged_actions (action);

CREATE INDEX logged_actions_table_row_id_idx
    ON audit.logged_actions (table_name, row_id);
CREATE INDEX logged_actions_table_row_id_upd_idx
    ON audit.logged_actions (table_name, row_id, action_tstamp_stm);

CREATE TABLE audit.logged_relations (
    relation_name TEXT NOT NULL,
    uid_column    TEXT NOT NULL,
    PRIMARY KEY (relation_name, uid_column)
);

COMMENT ON TABLE audit.logged_relations IS 'Table used to store unique identifier columns for table or views, so that events can be replayed';
COMMENT ON COLUMN audit.logged_relations.relation_name IS 'Relation (table or view) name (with schema if needed)';
COMMENT ON COLUMN audit.logged_relations.uid_column IS 'Name of a column that is used to uniquely identify a row in the relation';

CREATE OR REPLACE FUNCTION audit.if_modified_func()
    RETURNS TRIGGER AS $body$
DECLARE
    audit_row      audit.LOGGED_ACTIONS;
    include_values BOOLEAN;
    log_diffs      BOOLEAN;
    h_old          HSTORE;
    h_new          HSTORE;
    excluded_cols  TEXT [] = ARRAY [] :: TEXT [];
BEGIN
--     RAISE WARNING '[audit.if_modified_func] start with TG_ARGV[0]: % ; TG_ARGV[1] : %, TG_OP: %, TG_LEVEL : %, TG_WHEN: % ', TG_ARGV[0], TG_ARGV[1], TG_OP, TG_LEVEL, TG_WHEN;

    IF NOT (TG_WHEN IN ('AFTER', 'INSTEAD OF'))
    THEN
        RAISE EXCEPTION 'audit.if_modified_func() may only run as an AFTER trigger';
    END IF;

    audit_row = ROW (
                nextval('audit.logged_actions_event_id_seq'),
        -- event_id
        TG_TABLE_SCHEMA :: TEXT, -- schema_name
        TG_TABLE_NAME :: TEXT, -- table_name
        NULL, -- row_id !!!
        TG_RELID, -- relation OID for much quicker searches
        --         session_user::text,                           -- session_user_name
        --         current_timestamp,                            -- action_tstamp_tx
        statement_timestamp(), -- action_tstamp_stm
        --         clock_timestamp(),                            -- action_tstamp_clk
        --         txid_current(),                               -- transaction ID
        --         (SELECT setting FROM pg_settings WHERE name = 'application_name'),
        --         inet_client_addr(),                           -- client_addr
        --         inet_client_port(),                           -- client_port
        current_query(), -- top-level query or queries (if multistatement) from client
        substring(TG_OP, 1, 1), -- action
        NULL, -- row_data
        NULL, -- changed_fields
        'f'                                           -- statement_only
    );

    IF NOT TG_ARGV [0] :: BOOLEAN IS DISTINCT FROM 'f' :: BOOLEAN
    THEN
        audit_row.client_query = '';
        -- RAISE WARNING '[audit.if_modified_func] - Trigger func triggered with no client_query tracking';

    END IF;

    IF TG_ARGV [1] IS NOT NULL
    THEN
        excluded_cols = TG_ARGV [1] :: TEXT [];
        -- RAISE WARNING '[audit.if_modified_func] - Trigger func triggered with excluded_cols: %',TG_ARGV[1];
    END IF;

    IF (TG_OP = 'UPDATE' AND TG_LEVEL = 'ROW')
    THEN
        audit_row.row_id = NEW.id;
        h_old = hstore(OLD.*) - excluded_cols;
        audit_row.row_data = h_old;
        h_new = hstore(NEW.*) - excluded_cols;
        audit_row.changed_fields = h_new - h_old;

        IF audit_row.changed_fields = hstore('')
        THEN
            -- All changed fields are ignored. Skip this update.
            -- RAISE WARNING '[audit.if_modified_func] - Trigger detected NULL hstore. ending';
            RETURN NULL;
        END IF;
        INSERT INTO audit.logged_actions VALUES (audit_row.*);
        RETURN NEW;

    ELSIF (TG_OP = 'DELETE' AND TG_LEVEL = 'ROW')
        THEN
            audit_row.row_id = OLD.id;
            audit_row.row_data = hstore(OLD.*) - excluded_cols;
            INSERT INTO audit.logged_actions VALUES (audit_row.*);
            RETURN OLD;

    ELSIF (TG_OP = 'INSERT' AND TG_LEVEL = 'ROW')
        THEN
            audit_row.row_id = NEW.id;
            audit_row.row_data = hstore(NEW.*) - excluded_cols;
            INSERT INTO audit.logged_actions VALUES (audit_row.*);
            RETURN NEW;

    ELSIF (TG_LEVEL = 'STATEMENT' AND TG_OP IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE'))
        THEN
            audit_row.statement_only = 't';
            IF TG_OP IN ('INSERT', 'UPDATE') THEN
                audit_row.row_id = NEW.id;
            END IF;
            INSERT INTO audit.logged_actions VALUES (audit_row.*);
            RETURN NULL;
    ELSE
        RAISE EXCEPTION '[audit.if_modified_func] - Trigger func added as trigger for unhandled case: %, %', TG_OP, TG_LEVEL;
        RETURN NEW;
    END IF;


END;
$body$
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public;


COMMENT ON FUNCTION audit.if_modified_func() IS $body$
Track changes to a table at the statement and/or row level.

Optional parameters to trigger in CREATE TRIGGER call:

param 0: boolean, whether to log the query text. Default 't'.

param 1: text[], columns to ignore in updates. Default [].

         Updates to ignored cols are omitted from changed_fields.

         Updates with only ignored cols changed are not inserted
         into the audit log.

         Almost all the processing work is still done for updates
         that ignored. If you need to save the load, you need to use
         WHEN clause on the trigger instead.

         No warning or error is issued if ignored_cols contains columns
         that do not exist in the target table. This lets you specify
         a standard set of ignored columns.

There is no parameter to disable logging of values. Add this trigger as
a 'FOR EACH STATEMENT' rather than 'FOR EACH ROW' trigger if you do not
want to log row values.

Note that the user name logged is the login role for the session. The audit trigger
cannot obtain the active role because it is reset by the SECURITY DEFINER invocation
of the audit trigger its self.
$body$;


CREATE OR REPLACE FUNCTION audit.audit_table(target_table REGCLASS, audit_rows BOOLEAN, audit_query_text BOOLEAN,
                                             ignored_cols TEXT [])
    RETURNS VOID AS $body$
DECLARE
    stm_targets        TEXT = 'INSERT OR UPDATE OR DELETE OR TRUNCATE';
    _q_txt             TEXT;
    _ignored_cols_snip TEXT = '';
BEGIN

    EXECUTE 'DROP TRIGGER IF EXISTS audit_trigger_row ON ' || target_table :: TEXT;
    EXECUTE 'DROP TRIGGER IF EXISTS audit_trigger_stm ON ' || target_table :: TEXT;

    -- check id column exists in audit table
    IF (SELECT COUNT(column_name) < 1
        FROM information_schema.columns
        WHERE table_name = target_table :: TEXT AND column_name = 'id')
    THEN
        RAISE EXCEPTION 'No column id in table % !!!', target_table :: TEXT;
        RETURN;
    END IF;

    IF audit_rows
    THEN
        IF array_length(ignored_cols, 1) > 0
        THEN
            _ignored_cols_snip = ', ' || quote_literal(ignored_cols);
        END IF;
        _q_txt = 'CREATE TRIGGER audit_trigger_row AFTER INSERT OR UPDATE OR DELETE ON ' ||
                 target_table :: TEXT ||

                 ' FOR EACH ROW EXECUTE PROCEDURE audit.if_modified_func(' ||
                 quote_literal(audit_query_text) || _ignored_cols_snip || ');';
        RAISE NOTICE '%', _q_txt;
        EXECUTE _q_txt;
        stm_targets = 'TRUNCATE';
    ELSE
    END IF;

    _q_txt = 'CREATE TRIGGER audit_trigger_stm AFTER ' || stm_targets || ' ON ' ||
             target_table ||
             ' FOR EACH STATEMENT EXECUTE PROCEDURE audit.if_modified_func(' ||
             quote_literal(audit_query_text) || ');';
    RAISE NOTICE '%', _q_txt;
    EXECUTE _q_txt;

    -- store primary key names
    INSERT INTO audit.logged_relations (relation_name, uid_column)
        SELECT
            target_table,
            a.attname
        FROM pg_index i
            JOIN pg_attribute a ON a.attrelid = i.indrelid
                                   AND a.attnum = ANY (i.indkey)
        WHERE i.indrelid = target_table :: REGCLASS
              AND i.indisprimary;
END;
$body$
LANGUAGE 'plpgsql';

COMMENT ON FUNCTION audit.audit_table(REGCLASS, BOOLEAN, BOOLEAN, TEXT []) IS $body$
Add auditing support to a table.

Arguments:
   target_table:     Table name, schema qualified if not on search_path
   audit_rows:       Record each row change, or only audit at a statement level
   audit_query_text: Record the text of the client query that triggered the audit event?
   ignored_cols:     Columns to exclude from update diffs, ignore updates that change only ignored cols.
$body$;

-- Pg doesn't allow variadic calls with 0 params, so provide a wrapper
CREATE OR REPLACE FUNCTION audit.audit_table(target_table REGCLASS, audit_rows BOOLEAN, audit_query_text BOOLEAN)
    RETURNS VOID AS $body$
SELECT audit.audit_table($1, $2, $3, ARRAY [] :: TEXT []);
$body$ LANGUAGE SQL;

-- And provide a convenience call wrapper for the simplest case
-- of row-level logging with no excluded cols and query logging enabled.
--
CREATE OR REPLACE FUNCTION audit.audit_table(target_table REGCLASS)
    RETURNS VOID AS $body$
SELECT audit.audit_table($1, BOOLEAN 't', BOOLEAN 't');
$body$ LANGUAGE 'sql';

COMMENT ON FUNCTION audit.audit_table(REGCLASS) IS $body$
Add auditing support to the given table. Row-level changes will be logged with full client query text. No cols are ignored.
$body$;


CREATE OR REPLACE FUNCTION audit.replay_event(pevent_id INT)
    RETURNS VOID AS $body$
DECLARE
    query TEXT;
BEGIN
    WITH
            event AS (
            SELECT *
            FROM audit.logged_actions
            WHERE event_id = pevent_id
        )
        -- get primary key names
        , where_pks AS (
        SELECT array_to_string(array_agg(uid_column || '=' || quote_literal(row_data -> uid_column)),
                               ' AND ') AS where_clause
        FROM audit.logged_relations r
            JOIN event ON relation_name = (schema_name || '.' || table_name)
    )
    SELECT INTO query CASE
                      WHEN action = 'I'
                          THEN
                              'INSERT INTO ' || schema_name || '.' || table_name ||
                              ' (' || (SELECT string_agg(key, ',')
                                       FROM each(row_data)) || ') VALUES ' ||
                              '(' || (SELECT string_agg(CASE WHEN value IS NULL
                                  THEN 'null'
                                                        ELSE quote_literal(value) END, ',')
                                      FROM each(row_data)) || ')'
                      WHEN action = 'D'
                          THEN
                              'DELETE FROM ' || schema_name || '.' || table_name ||
                              ' WHERE ' || where_clause
                      WHEN action = 'U'
                          THEN
                              'UPDATE ' || schema_name || '.' || table_name ||
                              ' SET ' || (SELECT string_agg(key || '=' || CASE WHEN value IS NULL
                                  THEN 'null'
                                                                          ELSE quote_literal(value) END, ',')
                                          FROM each(changed_fields)) ||
                              ' WHERE ' || where_clause
                      END
    FROM
        event, where_pks;

    EXECUTE query;
END;
$body$
LANGUAGE plpgsql;

COMMENT ON FUNCTION audit.replay_event(INT) IS $body$
Replay a logged event.
 
Arguments:
   pevent_id:  The event_id of the event in audit.logged_actions to replay
$body$;

CREATE OR REPLACE FUNCTION audit.audit_view(target_view REGCLASS, audit_query_text BOOLEAN, ignored_cols TEXT [],
                                            uid_cols    TEXT [])
    RETURNS VOID AS $body$
DECLARE
    stm_targets        TEXT = 'INSERT OR UPDATE OR DELETE';
    _q_txt             TEXT;
    _ignored_cols_snip TEXT = '';

BEGIN
    EXECUTE 'DROP TRIGGER IF EXISTS audit_trigger_row ON ' || target_view :: TEXT;
    EXECUTE 'DROP TRIGGER IF EXISTS audit_trigger_stm ON ' || target_view :: TEXT;

    IF array_length(ignored_cols, 1) > 0
    THEN
        _ignored_cols_snip = ', ' || quote_literal(ignored_cols);
    END IF;
    _q_txt = 'CREATE TRIGGER audit_trigger_row INSTEAD OF INSERT OR UPDATE OR DELETE ON ' ||
             target_view :: TEXT ||
             ' FOR EACH ROW EXECUTE PROCEDURE audit.if_modified_func(' ||
             quote_literal(audit_query_text) || _ignored_cols_snip || ');';
    RAISE NOTICE '%', _q_txt;
    EXECUTE _q_txt;

    -- store uid columns if not already present
    IF (SELECT count(*)
        FROM audit.logged_relations
        WHERE relation_name = (SELECT target_view) :: TEXT AND uid_column = (SELECT unnest(uid_cols)) :: TEXT) = 0
    THEN
        INSERT INTO audit.logged_relations (relation_name, uid_column)
            SELECT
                target_view,
                unnest(uid_cols);
    END IF;

END;
$body$
LANGUAGE plpgsql;

COMMENT ON FUNCTION audit.audit_view(REGCLASS, BOOLEAN, TEXT [], TEXT []) IS $body$
ADD auditing support TO a VIEW.
 
Arguments:
   target_view:      TABLE name, schema qualified IF NOT ON search_path
   audit_query_text: Record the text of the client query that triggered the audit event?
   ignored_cols:     COLUMNS TO exclude FROM UPDATE diffs, IGNORE updates that CHANGE only ignored cols.
   uid_cols:         COLUMNS to use to uniquely identify a row from the view (in order to replay UPDATE and DELETE)
$body$;

-- Pg doesn't allow variadic calls with 0 params, so provide a wrapper
CREATE OR REPLACE FUNCTION audit.audit_view(target_view REGCLASS, audit_query_text BOOLEAN, uid_cols TEXT [])
    RETURNS VOID AS $body$
SELECT audit.audit_view($1, $2, ARRAY [] :: TEXT [], uid_cols);
$body$ LANGUAGE SQL;

-- And provide a convenience call wrapper for the simplest case
-- of row-level logging with no excluded cols and query logging enabled.
--
CREATE OR REPLACE FUNCTION audit.audit_view(target_view REGCLASS, uid_cols TEXT [])
    RETURNS VOID AS $$
SELECT audit.audit_view($1, BOOLEAN 't', uid_cols);
$$ LANGUAGE 'sql';
