\echo Use "CREATE EXTENSION pg_cron" to load this file. \quit

CREATE SCHEMA cron;

CREATE SEQUENCE cron.jobid_seq;

CREATE TABLE cron.job (
    jobid bigint PRIMARY KEY DEFAULT nextval('cron.jobid_seq'),
    schedule text NOT NULL,
    command text NOT NULL,
    database text NOT NULL DEFAULT current_database(),
    username text NOT NULL DEFAULT current_user,
    active boolean NOT NULL DEFAULT true,
    jobname text UNIQUE
);

CREATE SEQUENCE cron.runid_seq;

CREATE TABLE cron.job_run_details (
    jobid bigint,
    runid bigint PRIMARY KEY DEFAULT nextval('cron.runid_seq'),
    job_pid integer,
    database text,
    username text,
    command text,
    status text,
    return_message text,
    start_time timestamptz,
    end_time timestamptz
);

GRANT USAGE ON SCHEMA cron TO public;
GRANT SELECT ON cron.job TO public;
GRANT SELECT ON cron.job_run_details TO public;

-- All six functions below are SECURITY DEFINER with a pinned search_path:
-- a non-owner role is only ever granted SELECT on cron.job/job_run_details
-- (matching real pg_cron), so scheduling/altering/unscheduling a job must
-- run with the extension owner's privileges to reach the underlying
-- INSERT/UPDATE/DELETE at all. Pinning search_path to just pg_catalog and
-- cron (not the caller's own search_path) is required for any SECURITY
-- DEFINER function: without it, a caller could shadow an unqualified name
-- (e.g. a same-named table function) with an object of their own to run
-- code with the owner's elevated privileges.
--
-- They all use `session_user`, never `current_user`, wherever "the role
-- that actually called this" is meant: inside a SECURITY DEFINER function
-- `current_user` (and any column DEFAULT expression evaluated while it
-- runs, e.g. cron.job.username's own `DEFAULT current_user`) resolves to
-- the FUNCTION OWNER, not the caller. Using `current_user` here would
-- silently attribute every non-owner's job to the extension owner instead
-- of themselves, and would make schedule_in_database's cross-user check
-- below compare the target username against the owner and never fire.
-- `session_user` is the one identifier immune to that substitution.
CREATE FUNCTION cron.schedule(schedule text, command text) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, cron AS $$
DECLARE
    new_jobid bigint;
BEGIN
    INSERT INTO cron.job (schedule, command, database, username)
    VALUES (schedule, command, current_database(), session_user)
    RETURNING jobid INTO new_jobid;
    RETURN new_jobid;
END;
$$;

CREATE FUNCTION cron.schedule(job_name text, schedule text, command text) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, cron AS $$
DECLARE
    new_jobid bigint;
BEGIN
    INSERT INTO cron.job (schedule, command, jobname, database, username)
    VALUES (schedule, command, job_name, current_database(), session_user)
    ON CONFLICT (jobname) DO UPDATE
        SET schedule = excluded.schedule, command = excluded.command, active = true
    RETURNING jobid INTO new_jobid;
    RETURN new_jobid;
END;
$$;

-- Matches real pg_cron: scheduling a job that runs as a DIFFERENT user, or
-- against a different database than the caller's own, is a superuser-only
-- operation — without this check any role with EXECUTE on this function
-- could impersonate an arbitrary username via a scheduled job's command.
CREATE FUNCTION cron.schedule_in_database(
    job_name text,
    schedule text,
    command text,
    database text DEFAULT NULL,
    username text DEFAULT NULL,
    active boolean DEFAULT true
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, cron AS $$
DECLARE
    new_jobid bigint;
    caller_is_superuser boolean;
BEGIN
    IF (username IS NOT NULL AND username <> session_user)
       OR (database IS NOT NULL AND database <> current_database())
    THEN
        SELECT rolsuper INTO caller_is_superuser FROM pg_roles WHERE rolname = session_user;
        IF NOT COALESCE(caller_is_superuser, false) THEN
            RAISE EXCEPTION 'must be superuser to schedule a job as a different user or in a different database';
        END IF;
    END IF;

    INSERT INTO cron.job (schedule, command, jobname, database, username, active)
    VALUES (
        schedule,
        command,
        job_name,
        COALESCE(database, current_database()),
        COALESCE(username, session_user),
        active
    )
    ON CONFLICT (jobname) DO UPDATE
        SET schedule = excluded.schedule,
            command = excluded.command,
            database = excluded.database,
            username = excluded.username,
            active = excluded.active
    RETURNING jobid INTO new_jobid;
    RETURN new_jobid;
END;
$$;

-- unschedule/alter_job additionally require the caller to either own the
-- job (its cron.job.username matches session_user) or be superuser: without
-- this, SECURITY DEFINER would let any role with EXECUTE (PUBLIC, by
-- default) delete or repoint any OTHER user's job by guessing its id/name.
CREATE FUNCTION cron.unschedule(job_id bigint) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, cron AS $$
BEGIN
    DELETE FROM cron.job
    WHERE jobid = job_id
      AND (username = session_user OR (SELECT rolsuper FROM pg_roles WHERE rolname = session_user));
    IF NOT FOUND THEN
        RAISE EXCEPTION 'could not find valid entry for job %', job_id;
    END IF;
    RETURN true;
END;
$$;

CREATE FUNCTION cron.unschedule(job_name text) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, cron AS $$
BEGIN
    DELETE FROM cron.job
    WHERE jobname = job_name
      AND (username = session_user OR (SELECT rolsuper FROM pg_roles WHERE rolname = session_user));
    IF NOT FOUND THEN
        RAISE EXCEPTION 'could not find valid entry for job %', job_name;
    END IF;
    RETURN true;
END;
$$;

CREATE FUNCTION cron.alter_job(
    job_id bigint,
    schedule text DEFAULT NULL,
    command text DEFAULT NULL,
    database text DEFAULT NULL,
    username text DEFAULT NULL,
    active boolean DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, cron AS $$
BEGIN
    UPDATE cron.job
    SET schedule = COALESCE(alter_job.schedule, cron.job.schedule),
        command = COALESCE(alter_job.command, cron.job.command),
        database = COALESCE(alter_job.database, cron.job.database),
        username = COALESCE(alter_job.username, cron.job.username),
        active = COALESCE(alter_job.active, cron.job.active)
    WHERE jobid = job_id
      AND (cron.job.username = session_user OR (SELECT rolsuper FROM pg_roles WHERE rolname = session_user));
    IF NOT FOUND THEN
        RAISE EXCEPTION 'could not find valid entry for job %', job_id;
    END IF;
END;
$$;
