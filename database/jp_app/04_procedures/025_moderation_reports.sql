/*==============================================================================
  jp_app — 04_procedures / 025_moderation_reports.sql

  PHASE 7B — pulling jobs, and the reports queue.

    USP_PullJob               a job leaves the public site, with a reason
    USP_RestoreJob            and comes back to the status it had
    USP_GetJobModerationHistory  what happened, for the school and the admin
    USP_SubmitReport          somebody reports a job, school or teacher
    USP_SearchReports         the admin queue
    USP_UpdateReportStatus    the state machine

  ⚠️ There is no USP_GetReport. USP_SearchReports already returns everything an
  admin needs per row, so a single-report read would be a second place that
  decides what a report looks like. Its name stays in the reporter-uid guard's
  allowed list below, so adding one later does not trip a guard for the wrong
  reason.

  ---------------------------------------------------------------------------
  🔴 PULLING A JOB DOES NOT TOUCH ITS APPLICATIONS. NOT ONE ROW.
  ---------------------------------------------------------------------------
  The candidates did nothing wrong. Somebody who applied last week has a live
  application, a stage, and a school that has read their profile — and a
  moderation decision about the ADVERT is not a decision about them.

  So USP_PullJob writes to exactly two tables: t_app_jobs (the status) and
  t_app_job_moderation_log (the row). It does not delete, withdraw, reject or
  re-stage a single application, and the build guard at the foot of this file
  fails if this file ever gains a statement that writes to t_app_applications.

  ⚠️ What a teacher sees is honest without being punitive: their application
  stays in their list with the stage it had. The job's own page is gone from
  the public site, which is what pulling means.

  ---------------------------------------------------------------------------
  🔴 RESTORE PUTS BACK WHAT WAS THERE, AND THE LOG IS HOW IT KNOWS
  ---------------------------------------------------------------------------
  Status is one column, so pulling overwrites what the job was. The PULL row
  records it, and restore reads the most recent one. A job that was CLOSED when
  an admin pulled it comes back CLOSED — not republished by a moderation
  decision, which is what a hardcoded `SET JobStatusId = 2` would have done.

  ---------------------------------------------------------------------------
  🔒 THE REPORTER'S IDENTITY NEVER REACHES THE REPORTED PARTY
  ---------------------------------------------------------------------------
  t_app_reports.ReportedByUserUid exists so an admin can see that one account
  filed forty reports. It appears in exactly two result sets — the admin queue
  and the admin's single-report read — and in nothing a school or teacher can
  call. The guard at the foot of this file asserts that by DEPENDENCY and by
  projection, because a comment cannot.

  ⚠️ And the school's moderation history deliberately carries no hint of a
  report at all. "Pulled after a complaint" tells a school there is a
  complainant; the remarks say what is wrong with the advert, which is what
  they can act on.
==============================================================================*/

USE jp_app;
GO

SET NOCOUNT ON;
GO

/*==============================================================================
  USP_PullJob — the job leaves the public site.

  🔴 Writes t_app_jobs.JobStatusId and ONE log row. Nothing else. Ever.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_PullJob
    @JobUid      uniqueidentifier,
    @Remarks     nvarchar(1000),
    @ActorUserId bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  tinyint       = 0,
            @Code    varchar(50)   = NULL,
            @Message nvarchar(400) = NULL,
            @JobId   bigint        = NULL,
            @Current int           = NULL;

    SELECT @JobId = j.JobId, @Current = j.JobStatusId
      FROM dbo.t_app_jobs j
     WHERE j.JobUid = @JobUid
       AND j.Is_Deleted = 0;

    /*
      ⚠️ A deleted or unknown job is NOT_FOUND, never FORBIDDEN (2.6). The
      caller already holds MODERATION.JOB — there is nothing to protect by
      being vague, and "not found" is simply true.
    */
    IF @JobId IS NULL
    BEGIN
        SELECT Status = 0, Code = 'NOT_FOUND', [Message] = N'That job was not found.';
        RETURN;
    END

    /*
      🔴 REMARKS ARE REQUIRED. The school is shown this text, and a moderation
      action nobody can explain is the one that becomes an argument later. The
      column has a CHECK too; this is the half that produces a clean refusal
      rather than a constraint violation.
    */
    IF LEN(LTRIM(RTRIM(ISNULL(@Remarks, N'')))) = 0
    BEGIN
        SELECT Status = 0, Code = 'REMARKS_REQUIRED',
               [Message] = N'Say why this job is being pulled — the school is shown this.';
        RETURN;
    END

    /*
      ⚠️ Pulling an already-pulled job is refused rather than ignored. It would
      write a second log row claiming a PreviousStatusId of 5, and restore
      would then put the job back to "pulled" — the log must not be able to
      describe a state the job was never in.
    */
    IF @Current = 5
    BEGIN
        SELECT Status = 0, Code = 'ALREADY_PULLED',
               [Message] = N'That job is already pulled.';
        RETURN;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        /*
          ⚠️ The log row FIRST, so the previous status is recorded before it is
          overwritten. The other order works too and reads as though the status
          were the source of truth for what it used to be.
        */
        INSERT INTO dbo.t_app_job_moderation_log
            (JobId, ActionType, PreviousStatusId, Remarks, ActionByUserId)
        VALUES (@JobId, 'PULL', @Current, LTRIM(RTRIM(@Remarks)), @ActorUserId);

        UPDATE dbo.t_app_jobs
           SET JobStatusId = 5,
               ModifiedOn  = SYSUTCDATETIME(),
               ModifiedBy  = @ActorUserId,
               RowVersion  = RowVersion + 1
         WHERE JobId = @JobId;

        /*
          🔴 AND THAT IS ALL. No application is touched — see this file's
          header and the guard at its foot.
        */

        COMMIT TRANSACTION;

        SELECT Status = 1, Code = NULL, [Message] = N'The job has been pulled from the public site.';
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        SET @Message = ERROR_MESSAGE();

        SELECT Status = 0, Code = 'PULL_FAILED', [Message] = @Message;
    END CATCH
END
GO

/*==============================================================================
  USP_RestoreJob — back to the status it had.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_RestoreJob
    @JobUid      uniqueidentifier,
    @Remarks     nvarchar(1000),
    @ActorUserId bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @JobId    bigint = NULL,
            @Current  int    = NULL,
            @Previous int    = NULL;

    SELECT @JobId = j.JobId, @Current = j.JobStatusId
      FROM dbo.t_app_jobs j
     WHERE j.JobUid = @JobUid
       AND j.Is_Deleted = 0;

    IF @JobId IS NULL
    BEGIN
        SELECT Status = 0, Code = 'NOT_FOUND', [Message] = N'That job was not found.';
        RETURN;
    END

    IF @Current <> 5
    BEGIN
        SELECT Status = 0, Code = 'NOT_PULLED',
               [Message] = N'That job is not pulled, so there is nothing to restore.';
        RETURN;
    END

    IF LEN(LTRIM(RTRIM(ISNULL(@Remarks, N'')))) = 0
    BEGIN
        SELECT Status = 0, Code = 'REMARKS_REQUIRED',
               [Message] = N'Say why this job is being restored — it goes in the same log.';
        RETURN;
    END

    /*
      🔴 THE STATUS THE JOB HAD, READ FROM THE MOST RECENT PULL.

      Not a hardcoded 2. A job that was CLOSED when it was pulled comes back
      CLOSED; republishing it would be a moderation decision making a
      publishing decision.

      ⚠️ If no PULL row exists the job was pulled by something that did not log
      it, which should be impossible — and the honest answer is to refuse
      rather than guess at 2.
    */
    SELECT TOP (1) @Previous = l.PreviousStatusId
      FROM dbo.t_app_job_moderation_log l
     WHERE l.JobId = @JobId
       AND l.ActionType = 'PULL'
     ORDER BY l.LogId DESC;

    IF @Previous IS NULL
    BEGIN
        SELECT Status = 0, Code = 'NO_PULL_RECORD',
               [Message] = N'This job is pulled but has no pull record, so the status to restore is unknown.';
        RETURN;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO dbo.t_app_job_moderation_log
            (JobId, ActionType, PreviousStatusId, Remarks, ActionByUserId)
        VALUES (@JobId, 'RESTORE', @Current, LTRIM(RTRIM(@Remarks)), @ActorUserId);

        UPDATE dbo.t_app_jobs
           SET JobStatusId = @Previous,
               ModifiedOn  = SYSUTCDATETIME(),
               ModifiedBy  = @ActorUserId,
               RowVersion  = RowVersion + 1
         WHERE JobId = @JobId;

        COMMIT TRANSACTION;

        /*
          ⚠️ The message names the status it went back to. "Restored" alone
          invites the assumption that the job is live again, which is false for
          one that was closed or expired when it was pulled.
        */
        DECLARE @Name nvarchar(40) = (SELECT Name FROM dbo.m_app_job_status WHERE JobStatusId = @Previous);

        SELECT Status = 1, Code = NULL,
               [Message] = N'The job has been restored to ' + LOWER(@Name) + N'.';
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        DECLARE @Err nvarchar(400) = ERROR_MESSAGE();

        SELECT Status = 0, Code = 'RESTORE_FAILED', [Message] = @Err;
    END CATCH
END
GO

/*==============================================================================
  USP_GetJobModerationHistory — what happened to this job.

  🔴 THE SAME ROWS FOR THE SCHOOL AND FOR THE ADMIN, and that is deliberate:
  the remarks are written to be shown. What differs is who may call it, which
  is the API's business.

  🔒 NO REPORTER, NO REPORT, NO COMPLAINT. A school seeing "pulled after a
  complaint" learns that somebody complained; the remarks tell them what is
  wrong with the advert, which is the part they can act on. This procedure does
  not read t_app_reports at all.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetJobModerationHistory
    @JobUid          uniqueidentifier,

    /*
      🔒 THE SCHOOL'S OWN COPY IS SCOPED HERE, NOT IN C#.

      An admin calls this with NULL and sees any job's history. A school calls
      it with its own organisation uid, and a job that is not theirs returns
      ZERO ROWS — which the API turns into the same 404 a job that never
      existed gives (2.6).

      ⚠️ The scoping lives in the procedure because that is where the rule can
      only be written once. A C# ownership check beside an unscoped procedure
      is a second answer to the same question, and the day they disagree the
      lenient one wins — which here would mean one school reading another's
      moderation remarks.
    */
    @OrganizationUid uniqueidentifier = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        l.LogId,
        l.ActionType,
        l.Remarks,
        l.ActionOn,

        /* The status the job went back to, in words, for a RESTORE row. */
        prev.Name AS PreviousStatusName,

        /*
          ⚠️ The actor's NAME is not here and nor is their id. A school does not
          need to know which administrator pulled their advert, and naming one
          invites them to contact that person directly. The admin's own screen
          joins the user table itself.
        */
        CAST(0 AS tinyint) AS Reserved
      FROM dbo.t_app_job_moderation_log l
      INNER JOIN dbo.m_app_job_status prev ON prev.JobStatusId = l.PreviousStatusId
      INNER JOIN dbo.t_app_jobs j          ON j.JobId = l.JobId
      INNER JOIN dbo.t_app_schools sc      ON sc.SchoolId = j.SchoolId
     WHERE j.JobUid = @JobUid
       AND j.Is_Deleted = 0
       AND (@OrganizationUid IS NULL OR sc.OrganizationUid = @OrganizationUid)
     ORDER BY l.LogId DESC;
END
GO

/*==============================================================================
  USP_SubmitReport — somebody reports a job, a school or a teacher.

  🔴 IDEMPOTENT BY DESIGN (2.48). A second open report by the same person about
  the same thing returns the FIRST one's uid and succeeds. It is not an error:
  somebody pressing a report button twice has not done anything wrong, and an
  error would invite them to try again with a different reason to get it
  through.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SubmitReport
    @ReasonId        int,
    @EntityType      varchar(10),
    @EntityUid       uniqueidentifier,
    @Description     nvarchar(2000) = NULL,
    @ReporterUserUid uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @EntityId  bigint = NULL,
            @ReportUid uniqueidentifier = NULL,
            @AppliesTo varchar(40) = NULL;

    IF @EntityType NOT IN ('JOB', 'TEACHER', 'SCHOOL')
    BEGIN
        SELECT Status = 0, Code = 'BAD_ENTITY_TYPE',
               [Message] = N'That is not something that can be reported.';
        RETURN;
    END

    SELECT @AppliesTo = r.AppliesTo
      FROM dbo.m_app_report_reasons r
     WHERE r.ReportReasonId = @ReasonId
       AND r.Is_Active = 1
       AND r.Is_Deleted = 0;

    IF @AppliesTo IS NULL
    BEGIN
        SELECT Status = 0, Code = 'BAD_REASON', [Message] = N'That reason is not available.';
        RETURN;
    END

    /*
      ⚠️ THE REASON MUST APPLY TO THE THING. "The profile is not real" against a
      job is a report an admin cannot act on, and a queue full of impossible
      combinations is a queue nobody trusts. The master's AppliesTo column says
      which pairings exist.
    */
    IF ',' + @AppliesTo + ',' NOT LIKE '%,' + @EntityType + ',%'
    BEGIN
        SELECT Status = 0, Code = 'REASON_NOT_FOR_ENTITY',
               [Message] = N'That reason does not apply to this kind of listing.';
        RETURN;
    END

    /*
      🔴 THE UID BECOMES AN ID HERE. The wire carries uids (2.47) and the table
      stores a polymorphic id, so exactly one place translates — and it is the
      same place that decides the entity exists.
    */
    IF @EntityType = 'JOB'
        SELECT @EntityId = JobId FROM dbo.t_app_jobs WHERE JobUid = @EntityUid AND Is_Deleted = 0;
    ELSE IF @EntityType = 'SCHOOL'
        SELECT @EntityId = SchoolId FROM dbo.t_app_schools WHERE SchoolUid = @EntityUid AND Is_Deleted = 0;
    ELSE
        SELECT @EntityId = TeacherId FROM dbo.t_app_teachers WHERE TeacherUid = @EntityUid AND Is_Deleted = 0;

    IF @EntityId IS NULL
    BEGIN
        SELECT Status = 0, Code = 'NOT_FOUND', [Message] = N'That listing was not found.';
        RETURN;
    END

    /*
      🔴 IDEMPOTENCE, CHECKED BEFORE INSERTING AND BACKED BY A UNIQUE INDEX.

      The check makes the common case a clean success; the index makes the race
      safe. Two presses of a button a second apart would otherwise both pass
      the check, and the second would hit the index — which this treats as the
      same outcome rather than an error.
    */
    SELECT @ReportUid = rp.ReportUid
      FROM dbo.t_app_reports rp
     WHERE rp.ReportedByUserUid = @ReporterUserUid
       AND rp.ReportedEntityType = @EntityType
       AND rp.ReportedEntityId = @EntityId
       AND rp.Is_Deleted = 0
       AND rp.ReportStatusId IN (1, 2);

    IF @ReportUid IS NOT NULL
    BEGIN
        SELECT Status = 1, Code = 'ALREADY_REPORTED',
               [Message] = N'You have already reported this. We are looking at it.',
               ReportUid = @ReportUid;
        RETURN;
    END

    BEGIN TRY
        INSERT INTO dbo.t_app_reports
            (ReportReasonId, ReportedEntityType, ReportedEntityId, ReportedByUserUid, Description)
        VALUES (@ReasonId, @EntityType, @EntityId, @ReporterUserUid,
                NULLIF(LTRIM(RTRIM(ISNULL(@Description, N''))), N''));

        SELECT @ReportUid = ReportUid FROM dbo.t_app_reports WHERE ReportId = SCOPE_IDENTITY();

        SELECT Status = 1, Code = NULL,
               [Message] = N'Thank you. We will look at this.',
               ReportUid = @ReportUid;
    END TRY
    BEGIN CATCH
        /*
          ⚠️ 2601/2627 IS THE RACE, NOT A FAILURE. The other press won; the
          outcome the reporter wanted has happened. Reporting an error here
          would tell somebody their report did not land when it did.
        */
        IF ERROR_NUMBER() IN (2601, 2627)
        BEGIN
            SELECT @ReportUid = rp.ReportUid
              FROM dbo.t_app_reports rp
             WHERE rp.ReportedByUserUid = @ReporterUserUid
               AND rp.ReportedEntityType = @EntityType
               AND rp.ReportedEntityId = @EntityId
               AND rp.Is_Deleted = 0
               AND rp.ReportStatusId IN (1, 2);

            SELECT Status = 1, Code = 'ALREADY_REPORTED',
                   [Message] = N'You have already reported this. We are looking at it.',
                   ReportUid = @ReportUid;

            RETURN;
        END

        DECLARE @Err nvarchar(400) = ERROR_MESSAGE();

        SELECT Status = 0, Code = 'REPORT_FAILED', [Message] = @Err, ReportUid = NULL;
    END CATCH
END
GO

/*==============================================================================
  USP_SearchReports — the admin queue.

  🔒 THIS IS ONE OF EXACTLY TWO PLACES ReportedByUserUid IS PROJECTED, and both
  are admin-only. See the guard at the foot of this file.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SearchReports
    @StatusId   int = NULL,
    @EntityType varchar(10) = NULL,
    @PageNumber int = 1,
    @PageSize   int = 20
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Skip int = (CASE WHEN @PageNumber < 1 THEN 0 ELSE @PageNumber - 1 END)
                        * (CASE WHEN @PageSize BETWEEN 1 AND 100 THEN @PageSize ELSE 20 END),
            @Take int = CASE WHEN @PageSize BETWEEN 1 AND 100 THEN @PageSize ELSE 20 END;

    SELECT
        rp.ReportUid,
        rp.ReportedEntityType,
        rp.Description,
        rp.CreatedOn,

        rs.Code AS StatusCode,
        rs.Name AS StatusName,
        rr.Name AS ReasonName,

        /*
          ⚠️ The entity's own uid and name, resolved per type. The admin screen
          needs to open the thing being reported, and it addresses everything by
          uid (2.47).
        */
        CASE rp.ReportedEntityType
            WHEN 'JOB'     THEN (SELECT j.JobUid FROM dbo.t_app_jobs j WHERE j.JobId = rp.ReportedEntityId)
            WHEN 'SCHOOL'  THEN (SELECT s.SchoolUid FROM dbo.t_app_schools s WHERE s.SchoolId = rp.ReportedEntityId)
            ELSE                (SELECT t.TeacherUid FROM dbo.t_app_teachers t WHERE t.TeacherId = rp.ReportedEntityId)
        END AS EntityUid,

        CASE rp.ReportedEntityType
            WHEN 'JOB'     THEN (SELECT j.JobTitle FROM dbo.t_app_jobs j WHERE j.JobId = rp.ReportedEntityId)
            WHEN 'SCHOOL'  THEN (SELECT s.SchoolName FROM dbo.t_app_schools s WHERE s.SchoolId = rp.ReportedEntityId)
            ELSE                (SELECT t.FullName FROM dbo.t_app_teachers t WHERE t.TeacherId = rp.ReportedEntityId)
        END AS EntityName,

        /*
          🔒 THE REPORTER, FOR THE ADMIN ONLY. Not a name — the uid and a count
          of how many reports this account has filed, which is what tells an
          admin whether they are looking at a pattern.
        */
        rp.ReportedByUserUid,

        (SELECT COUNT(*) FROM dbo.t_app_reports other
          WHERE other.ReportedByUserUid = rp.ReportedByUserUid
            AND other.Is_Deleted = 0) AS ReportsByThisAccount,

        rp.AdminRemarks,
        rp.ReviewedOn
      FROM dbo.t_app_reports rp
      INNER JOIN dbo.m_app_report_status  rs ON rs.ReportStatusId = rp.ReportStatusId
      INNER JOIN dbo.m_app_report_reasons rr ON rr.ReportReasonId = rp.ReportReasonId
     WHERE rp.Is_Deleted = 0
       AND (@StatusId IS NULL OR rp.ReportStatusId = @StatusId)
       AND (@EntityType IS NULL OR rp.ReportedEntityType = @EntityType)
     ORDER BY
        /* Open first, then oldest — a queue, not a list. */
        CASE WHEN rp.ReportStatusId IN (1, 2) THEN 0 ELSE 1 END,
        rp.CreatedOn
     OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

    SELECT COUNT(*) AS TotalRecords
      FROM dbo.t_app_reports rp
     WHERE rp.Is_Deleted = 0
       AND (@StatusId IS NULL OR rp.ReportStatusId = @StatusId)
       AND (@EntityType IS NULL OR rp.ReportedEntityType = @EntityType);
END
GO

/*==============================================================================
  USP_UpdateReportStatus — the state machine.

  🔴 Open -> UnderReview -> ActionTaken | Dismissed, and Open -> either
  terminal directly.

  ⚠️ THE DIRECT JUMP IS DELIBERATE. An admin looking at obvious spam should not
  have to click twice to say so, and a two-step machine with no second decision
  in it is ceremony. What is NOT allowed is leaving a terminal state: the
  master's IsTerminal column says which those are, so the rule lives in one
  place rather than in a CASE here.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_UpdateReportStatus
    @ReportUid    uniqueidentifier,
    @NewStatusId  int,
    @AdminRemarks nvarchar(1000) = NULL,
    @ActorUserId  bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @ReportId   bigint = NULL,
            @Current    int    = NULL,
            @IsTerminal tinyint = 0,
            @NewTerminal tinyint = 0;

    SELECT @ReportId = rp.ReportId, @Current = rp.ReportStatusId
      FROM dbo.t_app_reports rp
     WHERE rp.ReportUid = @ReportUid
       AND rp.Is_Deleted = 0;

    IF @ReportId IS NULL
    BEGIN
        SELECT Status = 0, Code = 'NOT_FOUND', [Message] = N'That report was not found.';
        RETURN;
    END

    SELECT @IsTerminal = IsTerminal FROM dbo.m_app_report_status WHERE ReportStatusId = @Current;
    SELECT @NewTerminal = IsTerminal FROM dbo.m_app_report_status WHERE ReportStatusId = @NewStatusId;

    IF @NewTerminal IS NULL
    BEGIN
        SELECT Status = 0, Code = 'BAD_STATUS', [Message] = N'That is not a report status.';
        RETURN;
    END

    /* 🔴 A decided report stays decided. */
    IF @IsTerminal = 1
    BEGIN
        SELECT Status = 0, Code = 'ALREADY_DECIDED',
               [Message] = N'That report has already been decided.';
        RETURN;
    END

    IF @NewStatusId = @Current
    BEGIN
        SELECT Status = 0, Code = 'NO_CHANGE', [Message] = N'The report is already in that state.';
        RETURN;
    END

    /*
      ⚠️ A TERMINAL DECISION NEEDS A REASON. "Dismissed" with no remark is a
      decision nobody can review, and the review-trail CHECK on the table
      already demands a reviewer and a timestamp — this adds the why.

      ⚠️ Moving to UnderReview does NOT need one: it means "I am looking at
      this", and demanding prose for that would make admins skip the step.
    */
    IF @NewTerminal = 1 AND LEN(LTRIM(RTRIM(ISNULL(@AdminRemarks, N'')))) = 0
    BEGIN
        SELECT Status = 0, Code = 'REMARKS_REQUIRED',
               [Message] = N'Say what you decided and why — this is the record of the decision.';
        RETURN;
    END

    BEGIN TRY
        UPDATE dbo.t_app_reports
           SET ReportStatusId   = @NewStatusId,
               AdminRemarks     = NULLIF(LTRIM(RTRIM(ISNULL(@AdminRemarks, N''))), N''),

               /*
                 ⚠️ The reviewer and the timestamp are set only for a terminal
                 state, and cleared otherwise — the table's CK_ReviewTrail
                 demands exactly that pairing, so the two cannot drift.
               */
               ReviewedByUserId = CASE WHEN @NewTerminal = 1 THEN @ActorUserId ELSE NULL END,
               ReviewedOn       = CASE WHEN @NewTerminal = 1 THEN SYSUTCDATETIME() ELSE NULL END,

               ModifiedOn       = SYSUTCDATETIME(),
               ModifiedBy       = @ActorUserId
         WHERE ReportId = @ReportId;

        SELECT Status = 1, Code = NULL, [Message] = N'The report has been updated.';
    END TRY
    BEGIN CATCH
        DECLARE @Err nvarchar(400) = ERROR_MESSAGE();

        SELECT Status = 0, Code = 'UPDATE_FAILED', [Message] = @Err;
    END CATCH
END
GO

/*==============================================================================
  USP_SearchJobsForModeration — THE QUEUE THE MODERATION SCREEN OPENS ON.

  ----------------------------------------------------------------------------
  WHY THIS EXISTS AT ALL
  ----------------------------------------------------------------------------
  Pull and restore address a job by uid, which is correct and was enough to
  prove the behaviour — but a desk you can only use if you already know the uid
  is not a desk. The first question a moderator asks on Monday morning is
  "what has been reported, and what is currently pulled?", and until this
  procedure existed the product had no answer to it.

  ⚠️ IT IS A MODERATION READ, SO IT LIVES IN THIS FILE and is named in the
  dependency guard at the foot: it must no more touch applications than
  USP_PullJob may.

  🔴 THE APPLICATION COUNT IS DERIVED, AND THAT CORRECTION IS THE WHOLE STORY.

  The first version of this procedure projected t_app_jobs.ApplicationCount,
  and a comment here claimed the column was maintained on the job row. It is
  not. 016 says in writing that it IS NEVER WRITTEN; 017 says it is never read
  either, so that a stale value cannot leak through a projection — and this
  procedure was exactly that leak. Every advert would have read 0 applied for
  ever, which is the worst possible lie to tell a moderator deciding whether to
  take an advert down.

  ⚠️ FOUND BY THE SCREENS SUITE, NOT BY REVIEW. Two applications existed and
  the queue cell said 0. A procedure that compiles says nothing about a number
  being right.

  So it is COUNT(*) over live application rows, the way every other screen in
  the product derives it — and the guard at the foot of this file was rewritten
  to allow this procedure to COUNT applications while still forbidding it, and
  the three acting procedures, from writing one.

  ----------------------------------------------------------------------------
  EFFECTIVE STATUS, NOT STORED STATUS (2.65)
  ----------------------------------------------------------------------------
  @StatusId filters on fn_EffectiveJobStatusId, so asking for EXPIRED (3)
  returns the jobs whose last date has passed even though no row anywhere says
  3. A moderator filtering by what they can see on the site would otherwise get
  a list that disagrees with the site.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SearchJobsForModeration
    @StatusId     int = NULL,
    @SearchText   nvarchar(200) = NULL,
    @JobUid       uniqueidentifier = NULL,
    @ReportedOnly bit = 0,
    @PageNumber   int = 1,
    @PageSize     int = 20
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Skip int = (CASE WHEN @PageNumber < 1 THEN 0 ELSE @PageNumber - 1 END)
                        * (CASE WHEN @PageSize BETWEEN 1 AND 100 THEN @PageSize ELSE 20 END),
            @Take int = CASE WHEN @PageSize BETWEEN 1 AND 100 THEN @PageSize ELSE 20 END;

    /*
      ⚠️ Built once into a variable rather than written as '%' + @SearchText +
      '%' three times. The same text has to drive the rows and the count, and
      two copies of a LIKE pattern is two chances for the page and its total to
      disagree.
    */
    DECLARE @Like nvarchar(210) =
        CASE WHEN @SearchText IS NULL OR LTRIM(RTRIM(@SearchText)) = N''
             THEN NULL ELSE N'%' + LTRIM(RTRIM(@SearchText)) + N'%' END;

    SELECT
        j.JobUid,
        j.JobTitle,
        s.SchoolUid,
        s.SchoolName,
        c.Name AS CityName,

        dbo.fn_EffectiveJobStatusId(j.JobStatusId, j.LastDateToApply) AS EffectiveStatusId,
        st.Name AS StatusName,

        /*
          🔴 DERIVED, every time it is shown — never t_app_jobs.ApplicationCount,
          which 016 forbids writing and 017 forbids reading. See the header.
        */
        (SELECT COUNT(*)
           FROM dbo.t_app_applications ap
          WHERE ap.JobId = j.JobId
            AND ap.Is_Deleted = 0) AS ApplicationCount,
        j.ViewCount,
        j.PublishedOn,
        j.LastDateToApply,

        /*
          How many people complained and have not been answered. Terminal
          statuses (3 resolved, 4 dismissed) are excluded: a job whose report
          was dismissed last month is not waiting for anyone.
        */
        (SELECT COUNT(*)
           FROM dbo.t_app_reports rp
          WHERE rp.Is_Deleted = 0
            AND rp.ReportedEntityType = 'JOB'
            AND rp.ReportedEntityId = j.JobId
            AND rp.ReportStatusId IN (1, 2)) AS OpenReportCount,

        /*
          The last thing moderation did to it, so the queue reads as a history
          and not a snapshot. NULL for the overwhelming majority of jobs, which
          have never been touched.
        */
        (SELECT TOP 1 lg.ActionType
           FROM dbo.t_app_job_moderation_log lg
          WHERE lg.JobId = j.JobId
          ORDER BY lg.LogId DESC) AS LastActionType,

        (SELECT TOP 1 lg.ActionOn
           FROM dbo.t_app_job_moderation_log lg
          WHERE lg.JobId = j.JobId
          ORDER BY lg.LogId DESC) AS LastActionOn
    FROM dbo.t_app_jobs j
    INNER JOIN dbo.t_app_schools s ON s.SchoolId = j.SchoolId
    LEFT  JOIN jp_mdm.dbo.m_mdm_city c ON c.CityId = j.CityId
    LEFT  JOIN dbo.m_app_job_status st
           ON st.JobStatusId = dbo.fn_EffectiveJobStatusId(j.JobStatusId, j.LastDateToApply)
    WHERE j.Is_Deleted = 0
      AND (@JobUid IS NULL OR j.JobUid = @JobUid)
      AND (@StatusId IS NULL
           OR dbo.fn_EffectiveJobStatusId(j.JobStatusId, j.LastDateToApply) = @StatusId)
      AND (@Like IS NULL OR j.JobTitle LIKE @Like OR s.SchoolName LIKE @Like)
      AND (@ReportedOnly = 0
           OR EXISTS (SELECT 1 FROM dbo.t_app_reports rp
                       WHERE rp.Is_Deleted = 0
                         AND rp.ReportedEntityType = 'JOB'
                         AND rp.ReportedEntityId = j.JobId
                         AND rp.ReportStatusId IN (1, 2)))
    ORDER BY
        /*
          🔴 A QUEUE, NOT A LIST — the same ordering principle USP_SearchReports
          uses. Complained-about first, then pulled (because a pulled job is a
          decision somebody may need to revisit), then newest.
        */
        CASE WHEN EXISTS (SELECT 1 FROM dbo.t_app_reports rp
                           WHERE rp.Is_Deleted = 0
                             AND rp.ReportedEntityType = 'JOB'
                             AND rp.ReportedEntityId = j.JobId
                             AND rp.ReportStatusId IN (1, 2)) THEN 0 ELSE 1 END,
        CASE WHEN j.JobStatusId = 5 THEN 0 ELSE 1 END,
        COALESCE(j.PublishedOn, j.CreatedOn) DESC,
        j.JobId DESC
    OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

    SELECT COUNT(*) AS TotalRecords
      FROM dbo.t_app_jobs j
      INNER JOIN dbo.t_app_schools s ON s.SchoolId = j.SchoolId
     WHERE j.Is_Deleted = 0
       AND (@JobUid IS NULL OR j.JobUid = @JobUid)
       AND (@StatusId IS NULL
            OR dbo.fn_EffectiveJobStatusId(j.JobStatusId, j.LastDateToApply) = @StatusId)
       AND (@Like IS NULL OR j.JobTitle LIKE @Like OR s.SchoolName LIKE @Like)
       AND (@ReportedOnly = 0
            OR EXISTS (SELECT 1 FROM dbo.t_app_reports rp
                        WHERE rp.Is_Deleted = 0
                          AND rp.ReportedEntityType = 'JOB'
                          AND rp.ReportedEntityId = j.JobId
                          AND rp.ReportStatusId IN (1, 2)));
END
GO

/*==============================================================================
  BUILD GUARDS
==============================================================================*/

/*
  🔴 PULLING A JOB MUST NOT TOUCH APPLICATIONS.

  Checked by DEPENDENCY rather than by reading the text, because a text search
  cannot tell code from a comment about code — 6.5A learned that when a guard
  naming what it banned matched its own prose. sys.sql_expression_dependencies
  records what the server actually compiled.

  ⚠️ USP_GetJobModerationHistory is in the list too: a school's moderation
  history has no business reading applications either.

  ⚠️ USP_SearchJobsForModeration IS DELIBERATELY NOT IN THIS LIST, and the
  second guard below is why. The queue has to count applications to show a
  moderator how many people a pull affects, and the first version of it read a
  column that is permanently zero instead. Counting is not touching — so the
  ban it is held to is the sharper one: it may reference the table, and it may
  not WRITE to it.

  Proven to fire: adding "DELETE FROM dbo.t_app_applications WHERE JobId =
  @JobId" to USP_PullJob fails this.
*/
DECLARE @touched nvarchar(1000) = N'';

SELECT @touched = STRING_AGG(
           CAST(OBJECT_NAME(d.referencing_id) AS nvarchar(128)) + N' -> ' + CAST(d.referenced_entity_name AS nvarchar(128)), N', ')
  FROM sys.sql_expression_dependencies d
 WHERE d.referencing_id IN (
           OBJECT_ID('dbo.USP_PullJob'),
           OBJECT_ID('dbo.USP_RestoreJob'),
           OBJECT_ID('dbo.USP_GetJobModerationHistory'))
   AND d.referenced_entity_name IN (
           't_app_applications', 't_app_saved_jobs', 't_app_job_offers', 't_app_offers');

IF ISNULL(@touched, N'') <> N''
BEGIN
    DECLARE @msg1 nvarchar(1200) =
        N'025_moderation_reports: 🔴 A MODERATION PROCEDURE READS OR WRITES APPLICATION DATA: '
        + @touched
        + N'. Pulling a job is a decision about the ADVERT. The candidates did nothing wrong, and their applications keep the stage they had.';

    RAISERROR('%s', 16, 1, @msg1);
END
GO

/*
  🔴 THE QUEUE MAY COUNT APPLICATIONS. IT MAY NOT WRITE ONE.

  sys.dm_sql_referenced_entities carries is_updated, which the dependency VIEW
  does not: it is 1 for an entity the module writes to and 0 for one it only
  reads. So this asserts exactly what the brief promises — a moderator can see
  that nine people applied, and the procedure that shows them cannot change a
  single one of those rows.

  ⚠️ WHY NOT SIMPLY BAN THE REFERENCE, as the three acting procedures do?
  Because then the count has to come from somewhere, and the only other place
  was a column that is permanently zero. A guard that forces a wrong number
  onto a screen is worse than the risk it removes.

  Proven to fire BOTH WAYS before being trusted: a probe procedure selecting
  COUNT(*) from t_app_applications reports is_updated = 0, and one containing
  UPDATE dbo.t_app_applications SET ModifiedOn = SYSUTCDATETIME() WHERE 1 = 0
  reports is_updated = 1 — so this is not a check that can only pass.
*/
IF EXISTS (SELECT 1
             FROM sys.dm_sql_referenced_entities('dbo.USP_SearchJobsForModeration', 'OBJECT')
            WHERE referenced_entity_name IN ('t_app_applications', 't_app_job_offers', 't_app_offers')
              AND is_updated = 1)
BEGIN
    RAISERROR('025_moderation_reports: 🔴 USP_SearchJobsForModeration WRITES to application data. The queue counts applications so a moderator can see who a pull affects; it must never change one. The candidates did nothing wrong.', 16, 1);
END
GO

/*
  🔒 THE REPORTER'S UID IS PROJECTED BY THE ADMIN READS ONLY.

  Any OTHER procedure that selects ReportedByUserUid is a procedure that might
  be school-facing or teacher-facing, and the brief's rule is that the
  reporter's identity never reaches the reported party.

  ⚠️ A text check here, and the reason it is acceptable: the thing being looked
  for is a COLUMN NAME in a SELECT list, which dependencies record at table
  granularity and cannot distinguish. The two allowed procedures are named, so
  a third one appearing is what fails.

  Proven to fire: adding rp.ReportedByUserUid to USP_GetJobModerationHistory
  fails this.
*/
DECLARE @leaks nvarchar(1000) = N'';

SELECT @leaks = STRING_AGG(CAST(OBJECT_NAME(m.object_id) AS nvarchar(128)), N', ')
  FROM sys.sql_modules m
 WHERE m.definition LIKE '%ReportedByUserUid%'
   AND OBJECT_NAME(m.object_id) NOT IN ('USP_SearchReports', 'USP_GetReport', 'USP_SubmitReport', 'USP_UpdateReportStatus');

IF ISNULL(@leaks, N'') <> N''
BEGIN
    DECLARE @msg2 nvarchar(1200) =
        N'025_moderation_reports: 🔒 A PROCEDURE OUTSIDE THE ADMIN READS MENTIONS ReportedByUserUid: '
        + @leaks
        + N'. The reporter''s identity must never reach the reported party. If this procedure is genuinely admin-only, add it to the allowed list here WITH the reason.';

    RAISERROR('%s', 16, 1, @msg2);
END
GO

PRINT '    Moderation and reports procedures ready.';
GO
