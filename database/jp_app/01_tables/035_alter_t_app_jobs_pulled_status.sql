/*==============================================================================
  jp_app — 035_alter_t_app_jobs_pulled_status.sql

  PHASE 7B — CK_t_app_jobs_StoredStatus learns about PULLED.

  ---------------------------------------------------------------------------
  🔴 THIS CONSTRAINT CAUGHT 7B, WHICH IS WHAT IT IS FOR
  ---------------------------------------------------------------------------
  022 wrote:

      CONSTRAINT CK_t_app_jobs_StoredStatus CHECK (JobStatusId IN (1, 2, 4))

      "🔴 Expired is derived and must never be stored. Without this CHECK the
       rule is a comment, and one UPDATE somewhere makes the derived status and
       the stored status disagree — with no way to tell which is right."

  034 added JobStatusId 5 = PULLED and 025's USP_PullJob set it. The pull
  failed, loudly, on the first run:

      PULL_FAILED  The UPDATE statement conflicted with the CHECK constraint
                   "CK_t_app_jobs_StoredStatus"

  ⚠️ THE PROCEDURE COMPILED AND DEPLOYED CLEANLY. Only running it showed this —
  the same lesson as deferred name resolution, from a different direction: a
  constraint violation is a runtime event, and a procedure that deploys has not
  been run.

  ---------------------------------------------------------------------------
  🔴 WHY 5 IS ADDED AND 3 IS STILL REFUSED
  ---------------------------------------------------------------------------
  The constraint is not "these are the valid statuses" — it is "these are the
  statuses a ROW may hold". Expired stays out because it is derived from
  LastDateToApply and storing it would create a second source of truth that
  drifts silently (021, 2.65).

  PULLED is the opposite kind of thing: it is a decision somebody made, at a
  time, with a reason, recorded in t_app_job_moderation_log. There is nothing
  to derive it from, so it must be stored — exactly like Draft, Active and
  Closed.

  ⚠️ The set is still CLOSED. If a later phase wants another status, this file
  is where the argument for storing it belongs.

  Re-runnable: the constraint is only rebuilt when its definition is out of date.
==============================================================================*/

USE jp_app;
GO

SET NOCOUNT ON;
GO

/*
  ⚠️ Matched on the DEFINITION rather than on the name, because the name is
  already correct — what changed is what it allows. A name check would make
  this file a no-op forever.
*/
IF EXISTS (SELECT 1
             FROM sys.check_constraints
            WHERE name = 'CK_t_app_jobs_StoredStatus'
              AND parent_object_id = OBJECT_ID('dbo.t_app_jobs')
              AND definition NOT LIKE '%(5)%')
BEGIN
    PRINT '    Rebuilding [CK_t_app_jobs_StoredStatus] to allow 5 PULLED ...';

    ALTER TABLE dbo.t_app_jobs DROP CONSTRAINT CK_t_app_jobs_StoredStatus;

    ALTER TABLE dbo.t_app_jobs
        ADD CONSTRAINT CK_t_app_jobs_StoredStatus CHECK (JobStatusId IN (1, 2, 4, 5));

    PRINT '      Done — 1 Draft, 2 Active, 4 Closed, 5 Pulled. 3 Expired stays DERIVED.';
END
ELSE
    PRINT '    [CK_t_app_jobs_StoredStatus] already allows PULLED - skipped.';
GO

/*
  🔒 GUARD — EXPIRED MUST STILL BE UNSTORABLE.

  The point of this file is to widen the set by exactly one. If a later edit
  lets 3 in, the derived status and the stored status can disagree with no way
  to tell which is right — which is the thing 022's constraint exists to
  prevent, and the thing this file must not undo on its way past.

  Proven to fire: rebuilding the constraint as IN (1,2,3,4,5) fails this.
*/
IF EXISTS (SELECT 1
             FROM sys.check_constraints
            WHERE name = 'CK_t_app_jobs_StoredStatus'
              AND parent_object_id = OBJECT_ID('dbo.t_app_jobs')
              AND definition LIKE '%(3)%')
    RAISERROR('035: CK_t_app_jobs_StoredStatus now allows JobStatusId 3. Expired is DERIVED from LastDateToApply (021, 2.65) — storing it creates a second source of truth that drifts silently, and nothing can then say which is right.', 16, 1);
GO

/*
  ⚠️ And the row has to exist, or the constraint allows a value no master
  explains. 034 seeds it; this asserts the two files agree.
*/
IF NOT EXISTS (SELECT 1 FROM dbo.m_app_job_status WHERE JobStatusId = 5 AND Code = 'PULLED')
    RAISERROR('035: the constraint allows JobStatusId 5 but m_app_job_status has no PULLED row. Run 034 first.', 16, 1);
GO

PRINT '    t_app_jobs accepts PULLED.';
GO
