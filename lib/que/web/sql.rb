lock_job_sql = <<-SQL.freeze
    SELECT job_id, pg_try_advisory_lock(job_id) AS locked
    FROM gue_jobs
    WHERE job_id = $1::bigint
SQL

lock_all_failing_jobs_sql = <<-SQL.freeze
    SELECT job_id, pg_try_advisory_lock(job_id) AS locked
    FROM gue_jobs
    WHERE error_count > 0
SQL

lock_all_scheduled_jobs_sql = <<-SQL.freeze
    SELECT job_id, pg_try_advisory_lock(job_id) AS locked
    FROM gue_jobs
    WHERE error_count = 0
SQL

def reschedule_all_jobs_query(scope)
  <<-SQL.freeze
    WITH target AS (#{scope})
    UPDATE gue_jobs
    SET run_at = $1::timestamptz,
        expired_at = NULL
    FROM target
    WHERE target.locked
    AND target.job_id = gue_jobs.job_id
    RETURNING pg_advisory_unlock(target.job_id)
  SQL
end

def delete_jobs_query(scope)
  <<-SQL.freeze
    WITH target AS (#{scope})
    DELETE FROM gue_jobs
    USING target
    WHERE target.locked
    AND target.job_id = gue_jobs.job_id
    RETURNING pg_advisory_unlock(target.job_id)
  SQL
end

Que::Web::SQL = {
  dashboard_stats: <<-SQL.freeze,
    SELECT count(*)                    AS total,
           count(locks.job_id)         AS running,
           coalesce(sum((error_count > 0 AND locks.job_id IS NULL)::int), 0) AS failing,
           coalesce(sum((error_count = 0 AND locks.job_id IS NULL)::int), 0) AS scheduled
    FROM gue_jobs
    LEFT JOIN (
      SELECT (classid::bigint << 32) + objid::bigint AS job_id
      FROM pg_locks
      WHERE locktype = 'advisory'
    ) locks ON (gue_jobs.job_id=locks.job_id)
    WHERE
      gue_jobs.args #>> '{0, job_class}' ILIKE ($1)
  SQL
  running_jobs: <<-SQL.freeze,
    SELECT gue_jobs.*
    FROM gue_jobs
    LEFT JOIN (
      SELECT (classid::bigint << 32) + objid::bigint AS job_id
      FROM pg_locks
      WHERE locktype = 'advisory'
    ) locks ON (gue_jobs.job_id=locks.job_id)
    WHERE locks.job_id IS NOT NULL
    AND (
      gue_jobs.args #>> '{0, job_class}' ILIKE ($3)
    )
    ORDER BY run_at, job_id
    LIMIT $1::int
    OFFSET $2::int
  SQL
  failing_jobs: <<-SQL.freeze,
    SELECT gue_jobs.*
    FROM gue_jobs
    LEFT JOIN (
      SELECT (classid::bigint << 32) + objid::bigint AS job_id
      FROM pg_locks
      WHERE locktype = 'advisory'
    ) locks ON (gue_jobs.job_id=locks.job_id)
    WHERE locks.job_id IS NULL
      AND error_count > 0
      AND (
        gue_jobs.args #>> '{0, job_class}' ILIKE ($3)
      )
    ORDER BY run_at, job_id
    LIMIT $1::int
    OFFSET $2::int
  SQL
  scheduled_jobs: <<-SQL.freeze,
    SELECT gue_jobs.*
    FROM gue_jobs
    LEFT JOIN (
      SELECT (classid::bigint << 32) + objid::bigint AS job_id
      FROM pg_locks
      WHERE locktype = 'advisory'
    ) locks ON (gue_jobs.job_id=locks.job_id)
    WHERE locks.job_id IS NULL
      AND error_count = 0
      AND (
        gue_jobs.args #>> '{0, job_class}' ILIKE ($3)
      )
    ORDER BY run_at, job_id
    LIMIT $1::int
    OFFSET $2::int
  SQL
  delete_job: delete_jobs_query(lock_job_sql),
  delete_all_scheduled_jobs: delete_jobs_query(lock_all_scheduled_jobs_sql),
  delete_all_failing_jobs: delete_jobs_query(lock_all_failing_jobs_sql),
  reschedule_job: <<-SQL.freeze,
    WITH target AS (#{lock_job_sql})
    UPDATE gue_jobs
    SET run_at = $2::timestamptz,
        expired_at = NULL
    FROM target
    WHERE target.locked
    AND target.job_id = gue_jobs.job_id
    RETURNING pg_advisory_unlock(target.job_id)
  SQL
  reschedule_all_scheduled_jobs: reschedule_all_jobs_query(lock_all_scheduled_jobs_sql),
  reschedule_all_failing_jobs: reschedule_all_jobs_query(lock_all_failing_jobs_sql),
  fetch_job: <<-SQL.freeze,
    SELECT *
    FROM gue_jobs
    WHERE job_id = $1::bigint
    LIMIT 1
  SQL
}.freeze
