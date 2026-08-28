/*==============================================================================
  jp_app — 04_procedures / 014_jobs.sql

  School-side job management, and the entitlement engine's first real consumer.
  Phase 4.

  ---------------------------------------------------------------------------
  🔴 BRANCH SCOPE IS THIS FILE'S SECURITY SURFACE (2.39)
  ---------------------------------------------------------------------------
  Every read and every write joins through dbo.fn_VisibleBranches. Nothing here
  accepts a SchoolId from a caller — the API resolves it from the token's
  OrganizationUid and passes it in.

  ⚠️ BranchId DOES arrive from the caller, legitimately, as data: "which campus
  is this job for". That is precisely why it is dangerous. It is validated
  against the caller's resolved branch set before it is used, on create AND on
  edit, and a branch outside that set answers NOT_FOUND — never FORBIDDEN,
  which would confirm the branch exists (2.6).

  ---------------------------------------------------------------------------
  🔴 PUBLISH CONSUMES THE ENTITLEMENT, AND BOTH HAPPEN IN ONE TRANSACTION
  ---------------------------------------------------------------------------
  Creating a draft is free. PUBLISHING is what costs, because publishing is what
  puts the job in front of teachers — that is the reach being sold
  (MONETIZATION_DESIGN.md).

  USP_PublishJob opens one transaction and does both inside it:

      consume refused  ->  no status change, the refusal Code goes back
      publish fails    ->  the whole thing rolls back, no ledger row

  There is never a window where a school has been charged for a job that is
  still a draft, or has a live job nobody was charged for. Two API calls with a
  gap between them could not promise that.

  ---------------------------------------------------------------------------
  ⚠️ THE IDEMPOTENCY REFERENCE IS THE JOB'S OWN Uid — AND ITS CONSEQUENCE
  ---------------------------------------------------------------------------
  (JOB, JobUid). So re-publishing a job that was closed resolves as
  ALREADY_CONSUMED and costs nothing.

  That is deliberate for MVP: it is genuinely the same job, and charging twice
  for reopening one posting would be the wrong answer far more often than the
  right one.

  🔴 The edge, stated plainly: a school could close and reopen a listing
  repeatedly and never pay again. Nothing stops that today. It is tolerable
  while listings are ordered by PublishedOn and reopening does not refresh it —
  the gaming buys nothing. Phase 6.5 revisits this the moment listings are
  ranked on freshness, because then reopening WOULD buy something.

  ---------------------------------------------------------------------------
  ⚠️ EXPIRED IS DERIVED IN ONE PLACE
  ---------------------------------------------------------------------------
  dbo.fn_EffectiveJobStatusId. No procedure writes the date comparison by hand.
  There is no nightly sweep — see 021's header for why.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  fn_EffectiveJobStatusId — the ONE definition of "expired".

  An ACTIVE job whose LastDateToApply is in the past (IST) reads as EXPIRED.
  Everything else reads as whatever is stored.

  ---------------------------------------------------------------------------
  🔴 WHY A FUNCTION AND NOT A PREDICATE COPIED INTO EACH PROCEDURE
  ---------------------------------------------------------------------------
  Because there will be five or six readers — the school list, the job detail,
  the dashboard, the public search in Phase 6, the teacher's applied-jobs list
  in Phase 5 — and the day one of them writes `<=` where the others wrote `<`,
  a job is closed to applicants on one screen and open on another. Nobody would
  find that from an error.

  ⚠️ The comparison is against fn_IstToday(), not CAST(SYSUTCDATETIME() AS date).
  A UTC day boundary falls at 05:30 IST, so between 18:30 and 24:00 IST the UTC
  date is already tomorrow — and jobs would expire five and a half hours early,
  every evening (2.28).

  ⚠️ Scalar, and used in both SELECT and WHERE. SQL Server 2019 at compat 150
  inlines it, so it costs nothing in a projection. In a WHERE it is not
  sargable — accepted: a school's own job list is tens of rows, and the
  alternative is the copied predicate this function exists to prevent. The
  public search in Phase 6 filters on the indexed JobStatusId = 2 FIRST and
  applies the date narrowing after, which keeps the seek.
==============================================================================*/
CREATE OR ALTER FUNCTION dbo.fn_EffectiveJobStatusId
(
    @JobStatusId      int,
    @LastDateToApply  date
)
RETURNS int
AS
BEGIN
    RETURN CASE
        WHEN @JobStatusId = 2
             AND @LastDateToApply IS NOT NULL
             AND @LastDateToApply < CAST(DATEADD(MINUTE, 330, SYSUTCDATETIME()) AS date)
        THEN 3                       -- Expired: derived, never stored
        ELSE @JobStatusId
    END;
END
GO


/*==============================================================================
  USP_SaveJob — create a draft, or edit an existing job.

  ---------------------------------------------------------------------------
  🔴 WHAT MAY BE EDITED ONCE A JOB IS ACTIVE, AND WHY THAT LINE IS THERE
  ---------------------------------------------------------------------------
  A draft is entirely editable — nobody has seen it.

  Once published, the job is a promise somebody may already have acted on. The
  split is: fields a teacher MATCHED ON are locked; fields describing TERMS are
  not.

  LOCKED once Active:
      BranchId · SubjectId · DesignationId · QualificationId
      EmploymentTypeId · CityId · StateId
      MinExperienceMonths · MaxExperienceMonths
      the subject and class-level sets

  EDITABLE once Active:
      JobTitle · JobDescription · NoOfVacancies
      SalaryMin · SalaryMax · IsSalaryNegotiable
      WorkingDays · TimingFrom · TimingTo
      LastDateToApply · ExpectedJoiningDate

  The reasoning: a teacher decided to apply because the job was for their
  SUBJECT, at their LEVEL, near them, within their experience band. Swapping
  the subject under a live posting retroactively changes what they applied to —
  and from Phase 5 there will be applications hanging off it. Salary, timings
  and the description are terms schools genuinely clarify after posting, and
  locking those would make them close and repost, which loses the applications.

  ⚠️ JobTitle IS editable, and that is the one judgement call here. It is the
  headline a teacher reads, so the argument for locking it is real. It is
  allowed because MATCHING does not use it — subject, designation and
  experience do — and because typos in a title are common and otherwise
  unfixable. 🔴 If Phase 6 ever ranks or searches on title text, this decision
  has to be revisited: it would then be a matching field wearing a label's
  clothes.

  ⚠️ Extending LastDateToApply is deliberately allowed, and it is how an
  EXPIRED job is revived. That is the useful case — a school extends a deadline
  — and it falls out of the derivation rather than needing an "unexpire" action.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SaveJob
    @SchoolId             bigint,
    @UserUid              uniqueidentifier,
    @JobId                bigint            = NULL,       -- NULL = create
    @BranchId             bigint,
    @JobTitle             nvarchar(200),
    @SubjectId            int,
    @DesignationId        int,
    @QualificationId      int               = NULL,
    @EmploymentTypeId     int               = 1,
    @NoOfVacancies        int               = 1,
    @MinExperienceMonths  int               = NULL,
    @MaxExperienceMonths  int               = NULL,
    @SalaryMin            decimal(12,2)     = NULL,
    @SalaryMax            decimal(12,2)     = NULL,
    @IsSalaryNegotiable   tinyint           = 0,
    @CityId               int               = NULL,
    @StateId              int               = NULL,
    @WorkingDays          nvarchar(100)     = NULL,
    @TimingFrom           time(0)           = NULL,
    @TimingTo             time(0)           = NULL,
    @LastDateToApply      date              = NULL,
    @ExpectedJoiningDate  date              = NULL,
    @JobDescription       nvarchar(max)     = NULL,
    @SubjectIds           dbo.IntIdList     READONLY,
    @ClassLevelIds        dbo.IntIdList     READONLY,
    @RowVersion           int               = NULL,
    @ActorUserId          bigint            = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL, @Message nvarchar(400) = NULL,
            @Id bigint = NULL,
            @CurrentStatus int = NULL, @CurrentBranchId bigint = NULL,
            @CurrentRowVersion int = NULL, @Today date = dbo.fn_IstToday();

    /*------------------------------------------------------------------------
      VALIDATION — every refusal gets its own Code so a caller can tell them
      apart without reading message text (2.12).
    ------------------------------------------------------------------------*/
    IF @JobTitle IS NULL OR LTRIM(RTRIM(@JobTitle)) = ''
    BEGIN
        SELECT 0 AS [Status], 'JOB_TITLE_REQUIRED' AS Code,
               N'A job needs a title.' AS [Message], NULL AS Id;
        RETURN;
    END

    IF @NoOfVacancies IS NULL OR @NoOfVacancies < 1
    BEGIN
        SELECT 0 AS [Status], 'INVALID_VACANCIES' AS Code,
               N'A job must have at least one vacancy.' AS [Message], NULL AS Id;
        RETURN;
    END

    IF @SalaryMin IS NOT NULL AND @SalaryMax IS NOT NULL AND @SalaryMin > @SalaryMax
    BEGIN
        SELECT 0 AS [Status], 'INVALID_SALARY_RANGE' AS Code,
               N'The minimum salary is higher than the maximum.' AS [Message], NULL AS Id;
        RETURN;
    END

    IF @MinExperienceMonths IS NOT NULL AND @MaxExperienceMonths IS NOT NULL
       AND @MinExperienceMonths > @MaxExperienceMonths
    BEGIN
        SELECT 0 AS [Status], 'INVALID_EXPERIENCE_RANGE' AS Code,
               N'The minimum experience is higher than the maximum.' AS [Message], NULL AS Id;
        RETURN;
    END

    /*
      ⚠️ A closing date in the past is refused ON CREATE only.

      On edit it must be allowed: the whole point of editing an expired job is
      to move that date, and the value being "in the past" is the state you are
      correcting. Refusing it on edit would make expiry a one-way door.
    */
    IF @JobId IS NULL AND @LastDateToApply IS NOT NULL AND @LastDateToApply < @Today
    BEGIN
        SELECT 0 AS [Status], 'LAST_DATE_IN_PAST' AS Code,
               N'The closing date has already passed.' AS [Message], NULL AS Id;
        RETURN;
    END

    /*------------------------------------------------------------------------
      🔴 BRANCH SCOPE. The whole security surface of this phase, in one EXISTS.

      NOT_FOUND, not FORBIDDEN: "that campus is not yours" tells an attacker the
      campus exists (2.6).
    ------------------------------------------------------------------------*/
    IF NOT EXISTS (SELECT 1 FROM dbo.fn_VisibleBranches(@SchoolId, @UserUid) v
                   WHERE v.BranchId = @BranchId)
    BEGIN
        SELECT 0 AS [Status], 'NOT_FOUND' AS Code,
               N'That campus was not found.' AS [Message], NULL AS Id;
        RETURN;
    END

    IF @JobId IS NOT NULL
    BEGIN
        /*
          The existing job, scoped the same way. A job at a campus the caller
          cannot see does not exist as far as they are concerned.
        */
        SELECT @CurrentStatus     = j.JobStatusId,
               @CurrentBranchId   = j.BranchId,
               @CurrentRowVersion = j.RowVersion
        FROM dbo.t_app_jobs j
            INNER JOIN dbo.fn_VisibleBranches(@SchoolId, @UserUid) v ON v.BranchId = j.BranchId
        WHERE j.JobId = @JobId
          AND j.SchoolId = @SchoolId
          AND j.Is_Deleted = 0;

        IF @CurrentStatus IS NULL
        BEGIN
            SELECT 0 AS [Status], 'NOT_FOUND' AS Code,
                   N'That job was not found.' AS [Message], NULL AS Id;
            RETURN;
        END

        IF @RowVersion IS NOT NULL AND @RowVersion <> @CurrentRowVersion
        BEGIN
            SELECT 0 AS [Status], 'CONCURRENCY_CONFLICT' AS Code,
                   N'Somebody else saved this job while you were editing it.' AS [Message], NULL AS Id;
            RETURN;
        END

        IF @CurrentStatus = 4
        BEGIN
            SELECT 0 AS [Status], 'JOB_CLOSED' AS Code,
                   N'A closed job cannot be edited.' AS [Message], NULL AS Id;
            RETURN;
        END

        /*
          🔴 THE STRUCTURAL LOCK. See the header for the reasoning.

          Checked in the PROCEDURE, not the form. A screen that greys the fields
          out is a courtesy; this is the rule.
        */
        IF @CurrentStatus = 2
        BEGIN
            IF @BranchId <> @CurrentBranchId
                OR EXISTS (SELECT 1 FROM dbo.t_app_jobs j
                           WHERE j.JobId = @JobId
                             AND (j.SubjectId <> @SubjectId
                               OR j.DesignationId <> @DesignationId
                               OR ISNULL(j.QualificationId, -1) <> ISNULL(@QualificationId, -1)
                               OR j.EmploymentTypeId <> @EmploymentTypeId
                               OR ISNULL(j.CityId, -1) <> ISNULL(@CityId, -1)
                               OR ISNULL(j.StateId, -1) <> ISNULL(@StateId, -1)
                               OR ISNULL(j.MinExperienceMonths, -1) <> ISNULL(@MinExperienceMonths, -1)
                               OR ISNULL(j.MaxExperienceMonths, -1) <> ISNULL(@MaxExperienceMonths, -1)))
            BEGIN
                SELECT 0 AS [Status], 'JOB_FIELD_LOCKED' AS Code,
                       N'A published job''s campus, subject, designation, qualification, '
                       + N'employment type, location and experience range cannot be changed. '
                       + N'Close it and post a new one instead.' AS [Message], NULL AS Id;
                RETURN;
            END
        END
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @JobId IS NULL
        BEGIN
            INSERT INTO dbo.t_app_jobs
                (SchoolId, BranchId, JobTitle, SubjectId, DesignationId, QualificationId,
                 EmploymentTypeId, NoOfVacancies, MinExperienceMonths, MaxExperienceMonths,
                 SalaryMin, SalaryMax, IsSalaryNegotiable, CityId, StateId,
                 WorkingDays, TimingFrom, TimingTo, LastDateToApply, ExpectedJoiningDate,
                 JobDescription, JobStatusId, CreatedBy)
            VALUES
                (@SchoolId, @BranchId, @JobTitle, @SubjectId, @DesignationId, @QualificationId,
                 @EmploymentTypeId, @NoOfVacancies, @MinExperienceMonths, @MaxExperienceMonths,
                 @SalaryMin, @SalaryMax, @IsSalaryNegotiable, @CityId, @StateId,
                 @WorkingDays, @TimingFrom, @TimingTo, @LastDateToApply, @ExpectedJoiningDate,
                 @JobDescription, 1, @ActorUserId);      -- always born a Draft

            SET @Id = CAST(SCOPE_IDENTITY() AS bigint);
        END
        ELSE
        BEGIN
            SET @Id = @JobId;

            UPDATE dbo.t_app_jobs
            SET BranchId            = @BranchId,
                JobTitle            = @JobTitle,
                SubjectId           = @SubjectId,
                DesignationId       = @DesignationId,
                QualificationId     = @QualificationId,
                EmploymentTypeId    = @EmploymentTypeId,
                NoOfVacancies       = @NoOfVacancies,
                MinExperienceMonths = @MinExperienceMonths,
                MaxExperienceMonths = @MaxExperienceMonths,
                SalaryMin           = @SalaryMin,
                SalaryMax           = @SalaryMax,
                IsSalaryNegotiable  = @IsSalaryNegotiable,
                CityId              = @CityId,
                StateId             = @StateId,
                WorkingDays         = @WorkingDays,
                TimingFrom          = @TimingFrom,
                TimingTo            = @TimingTo,
                LastDateToApply     = @LastDateToApply,
                ExpectedJoiningDate = @ExpectedJoiningDate,
                JobDescription      = @JobDescription,
                ModifiedOn          = SYSUTCDATETIME(),
                ModifiedBy          = @ActorUserId,
                RowVersion          = RowVersion + 1
            WHERE JobId = @Id;
        END

        /*
          The bridges — full-set sync, the 2.51 pattern: GONE, BACK, NEW.

          ⚠️ Only reachable for a DRAFT. An Active job's structural lock has
          already refused any change to these, and passing the same set through
          again is a no-op by construction.
        */
        IF @CurrentStatus IS NULL OR @CurrentStatus = 1
        BEGIN
            -- GONE
            UPDATE js SET js.Is_Deleted = 1, js.ModifiedOn = SYSUTCDATETIME(), js.ModifiedBy = @ActorUserId
            FROM dbo.t_app_job_subjects js
            WHERE js.JobId = @Id AND js.Is_Deleted = 0
              AND NOT EXISTS (SELECT 1 FROM @SubjectIds i WHERE i.Id = js.SubjectId);

            -- BACK
            UPDATE js SET js.Is_Deleted = 0, js.Is_Active = 1,
                          js.ModifiedOn = SYSUTCDATETIME(), js.ModifiedBy = @ActorUserId
            FROM dbo.t_app_job_subjects js
                INNER JOIN @SubjectIds i ON i.Id = js.SubjectId
            WHERE js.JobId = @Id AND js.Is_Deleted = 1;

            -- NEW
            INSERT INTO dbo.t_app_job_subjects (JobId, SubjectId, CreatedBy)
            SELECT @Id, i.Id, @ActorUserId
            FROM @SubjectIds i
            WHERE NOT EXISTS (SELECT 1 FROM dbo.t_app_job_subjects js
                              WHERE js.JobId = @Id AND js.SubjectId = i.Id);

            UPDATE jc SET jc.Is_Deleted = 1, jc.ModifiedOn = SYSUTCDATETIME(), jc.ModifiedBy = @ActorUserId
            FROM dbo.t_app_job_class_levels jc
            WHERE jc.JobId = @Id AND jc.Is_Deleted = 0
              AND NOT EXISTS (SELECT 1 FROM @ClassLevelIds i WHERE i.Id = jc.ClassLevelId);

            UPDATE jc SET jc.Is_Deleted = 0, jc.Is_Active = 1,
                          jc.ModifiedOn = SYSUTCDATETIME(), jc.ModifiedBy = @ActorUserId
            FROM dbo.t_app_job_class_levels jc
                INNER JOIN @ClassLevelIds i ON i.Id = jc.ClassLevelId
            WHERE jc.JobId = @Id AND jc.Is_Deleted = 1;

            INSERT INTO dbo.t_app_job_class_levels (JobId, ClassLevelId, CreatedBy)
            SELECT @Id, i.Id, @ActorUserId
            FROM @ClassLevelIds i
            WHERE NOT EXISTS (SELECT 1 FROM dbo.t_app_job_class_levels jc
                              WHERE jc.JobId = @Id AND jc.ClassLevelId = i.Id);
        END

        SET @Status = 1;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        DECLARE @E int = ERROR_NUMBER(), @S int = ERROR_SEVERITY(), @T int = ERROR_STATE(),
                @P sysname = ERROR_PROCEDURE(), @L int = ERROR_LINE(),
                @M nvarchar(4000) = ERROR_MESSAGE();

        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        DECLARE @Params nvarchar(max) = (
            SELECT @SchoolId AS schoolId, @JobId AS jobId, @BranchId AS branchId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC dbo.USP_LogError @ErrorNumber = @E, @ErrorSeverity = @S, @ErrorState = @T,
             @ErrorProcedure = @P, @ErrorLine = @L, @ErrorMessage = @M,
             @ParametersJson = @Params, @ContextInfo = N'USP_SaveJob',
             @CreatedBy = @ActorUserId;

        THROW;
    END CATCH

    SELECT @Status AS [Status], @Code AS Code, @Message AS [Message], @Id AS Id;
END
GO


/*==============================================================================
  USP_PublishJob — Draft to Active, and the entitlement consume, atomically.

  ---------------------------------------------------------------------------
  🔴 ONE TRANSACTION. THIS IS THE POINT OF THE PROCEDURE.
  ---------------------------------------------------------------------------
  The consume and the status change are the same act. Split across two API
  calls there is a window in which the school has been charged and the job is
  still a draft — and the only way to notice would be a customer complaining
  about a quota they cannot account for.

  ⚠️ USP_ConsumeFeatureCore is CALLED, not copied. It carries the per-owner
  UPDLOCK/HOLDLOCK, the quota-then-credits order, the idempotency index and
  every refusal Code. A second implementation of any of that is a second set of
  rules.

  It is nesting-aware (@OwnsTran, added for this): inside this transaction it
  does its work and leaves committing and rolling back to this procedure.

  🔴 THE CORE IS CALLED WITH OUTPUT PARAMETERS, NOT INSERT ... EXEC — and that
  is not a style preference. The first version used INSERT ... EXEC and died on
  the first real call with Msg 3915, "cannot use ROLLBACK within an INSERT-EXEC
  statement" — which is precisely what the refusal path below does. INSERT ...
  EXEC also cannot nest, so it would have made this procedure un-wrappable
  forever. Both limits vanish with OUTPUT parameters.

  ---------------------------------------------------------------------------
  ⚠️ WHY PUBLISH AND NOT CREATE
  ---------------------------------------------------------------------------
  A draft is invisible. Charging for it would charge for typing. What a school
  is buying is REACH — the job being in front of teachers — and that begins at
  publish. It also means a school can prepare a month of postings and pay as it
  releases them, which is the behaviour we want.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_PublishJob
    @SchoolId         bigint,
    @UserUid          uniqueidentifier,
    @JobId            bigint,
    @OwnerUid         uniqueidentifier,     -- the subscription's owner (2.51)
    @FeatureId        int,
    @GatingModeId     tinyint,
    @HasMapping       tinyint,
    @IsIncluded       tinyint = 0,
    @QuotaPerPeriod   int     = NULL,
    @ExpectedPlanId   int     = NULL,
    @ActorUserId      bigint  = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL, @Message nvarchar(400) = NULL,
            @JobUid uniqueidentifier = NULL, @CurrentStatus int = NULL,
            @LastDate date = NULL, @Today date = dbo.fn_IstToday(),
            @Consumed tinyint = 0, @EntryId bigint = NULL, @SourceId tinyint = NULL;

    /*
      Scope and state first, OUTSIDE the transaction — a refusal here should not
      have opened one. Nothing is written until every one of these passes.
    */
    SELECT @CurrentStatus = j.JobStatusId,
           @JobUid        = j.JobUid,
           @LastDate      = j.LastDateToApply
    FROM dbo.t_app_jobs j
        INNER JOIN dbo.fn_VisibleBranches(@SchoolId, @UserUid) v ON v.BranchId = j.BranchId
    WHERE j.JobId = @JobId
      AND j.SchoolId = @SchoolId
      AND j.Is_Deleted = 0;

    IF @CurrentStatus IS NULL
    BEGIN
        SELECT 0 AS [Status], 'NOT_FOUND' AS Code, N'That job was not found.' AS [Message],
               NULL AS Id, CAST(0 AS tinyint) AS Consumed, NULL AS SourceId;
        RETURN;
    END

    IF @CurrentStatus = 2
    BEGIN
        SELECT 0 AS [Status], 'JOB_ALREADY_ACTIVE' AS Code,
               N'That job is already published.' AS [Message],
               NULL AS Id, CAST(0 AS tinyint) AS Consumed, NULL AS SourceId;
        RETURN;
    END

    /*
      ⚠️ Publishing something already past its closing date would create a job
      that is Expired the instant it goes live. Refused with its own Code so the
      screen can offer the fix — change the date — rather than a dead end.
    */
    IF @LastDate IS NOT NULL AND @LastDate < @Today
    BEGIN
        SELECT 0 AS [Status], 'LAST_DATE_IN_PAST' AS Code,
               N'The closing date has already passed. Change it before publishing.' AS [Message],
               NULL AS Id, CAST(0 AS tinyint) AS Consumed, NULL AS SourceId;
        RETURN;
    END

    DECLARE @QuotaUsed int, @QuotaRemaining int, @CreditBalance int,
            @PeriodFromUtc datetime2, @PeriodToUtc datetime2;

    BEGIN TRY
        BEGIN TRANSACTION;

        /*
          🔴 THE CONSUME, INSIDE THIS TRANSACTION.

          Reference: (JOB, JobUid). Re-publishing a closed job therefore comes
          back ALREADY_CONSUMED — see the file header for that trade-off and its
          gaming edge.
        */
        EXEC dbo.USP_ConsumeFeatureCore
            @OwnerUid        = @OwnerUid,
            @FeatureId       = @FeatureId,
            @GatingModeId    = @GatingModeId,
            @HasMapping      = @HasMapping,
            @IsIncluded      = @IsIncluded,
            @QuotaPerPeriod  = @QuotaPerPeriod,
            @ExpectedPlanId  = @ExpectedPlanId,
            @Units           = 1,
            @RefEntityTypeId = 1,                 -- JOB
            @RefEntityUid    = @JobUid,
            @Notes           = N'Job publish',
            @ActorUserId     = @ActorUserId,
            @Status          = @Status         OUTPUT,
            @Code            = @Code           OUTPUT,
            @Message         = @Message        OUTPUT,
            @EntryId         = @EntryId        OUTPUT,
            @Consumed        = @Consumed       OUTPUT,
            @SourceId        = @SourceId       OUTPUT,
            @QuotaUsed       = @QuotaUsed      OUTPUT,
            @QuotaRemaining  = @QuotaRemaining OUTPUT,
            @CreditBalance   = @CreditBalance  OUTPUT,
            @PeriodFromUtc   = @PeriodFromUtc  OUTPUT,
            @PeriodToUtc     = @PeriodToUtc    OUTPUT;

        /*
          🔴 REFUSED -> NOTHING HAPPENS.

          The rollback matters even though the consume wrote nothing: it also
          undoes anything the consume DID write on a partial path, and it makes
          "refused" and "failed" reach the caller identically — as a job that is
          still a Draft.
        */
        IF @Status = 0
        BEGIN
            ROLLBACK TRANSACTION;

            SELECT 0 AS [Status], @Code AS Code, @Message AS [Message],
                   NULL AS Id, CAST(0 AS tinyint) AS Consumed, NULL AS SourceId;
            RETURN;
        END

        UPDATE dbo.t_app_jobs
        SET JobStatusId = 2,
            PublishedOn = SYSUTCDATETIME(),
            ClosedOn    = NULL,               -- a reopened job is live again
            ModifiedOn  = SYSUTCDATETIME(),
            ModifiedBy  = @ActorUserId,
            RowVersion  = RowVersion + 1
        WHERE JobId = @JobId;

        /*
          ⚠️ THERE IS NO TEST HOOK IN THIS PROCEDURE, AND THERE WAS ONE BRIEFLY.

          Phase 4's verification has to prove that a failure AFTER the consume
          rolls the ledger row back. The first attempt put a conditional
          RAISERROR here, guarded on a table the verification would create.

          That was wrong twice over. SQL Server resolves the table name when the
          statement RUNS, not when the IF around it is evaluated, so with no
          such table the procedure failed outright with "Invalid object name" —
          and left @@TRANCOUNT mismatched (Msg 266). Worse, the atomicity test
          then PASSED: the job stayed a Draft and the ledger stayed empty,
          because the procedure had blown up before doing anything, not because
          the rollback worked. A test that passes for the wrong reason is the
          one thing worse than a test that fails.

          🔴 The injection belongs OUTSIDE this file. The verification puts a
          temporary AFTER UPDATE trigger on t_app_jobs, which fires exactly
          between the consume above and this commit, and drops it afterwards.
          Production code carries no scaffolding, and the failure being injected
          is a real one.
        */
        SET @Status = 1;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        DECLARE @E int = ERROR_NUMBER(), @S int = ERROR_SEVERITY(), @T int = ERROR_STATE(),
                @P sysname = ERROR_PROCEDURE(), @L int = ERROR_LINE(),
                @M nvarchar(4000) = ERROR_MESSAGE();

        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        DECLARE @Params nvarchar(max) = (
            SELECT @SchoolId AS schoolId, @JobId AS jobId, @OwnerUid AS ownerUid
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC dbo.USP_LogError @ErrorNumber = @E, @ErrorSeverity = @S, @ErrorState = @T,
             @ErrorProcedure = @P, @ErrorLine = @L, @ErrorMessage = @M,
             @ParametersJson = @Params, @ContextInfo = N'USP_PublishJob',
             @CreatedBy = @ActorUserId;

        THROW;
    END CATCH

    SELECT @Status AS [Status], @Code AS Code, @Message AS [Message],
           @EntryId AS Id, @Consumed AS Consumed, @SourceId AS SourceId;
END
GO


/*==============================================================================
  USP_CloseJob — Active (or effectively Expired) to Closed.

  ⚠️ Closing an EXPIRED job is allowed, and is the normal case: the row is still
  Active, the date has simply passed, and closing it is the honest end state.
  Refusing that would leave expired jobs sitting in a list nobody could tidy.

  Closing a DRAFT is refused — a draft was never open, and "closing" it would
  mean something different (discarding it) under the same word.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_CloseJob
    @SchoolId     bigint,
    @UserUid      uniqueidentifier,
    @JobId        bigint,
    @ActorUserId  bigint = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @CurrentStatus int = NULL;

    SELECT @CurrentStatus = j.JobStatusId
    FROM dbo.t_app_jobs j
        INNER JOIN dbo.fn_VisibleBranches(@SchoolId, @UserUid) v ON v.BranchId = j.BranchId
    WHERE j.JobId = @JobId AND j.SchoolId = @SchoolId AND j.Is_Deleted = 0;

    IF @CurrentStatus IS NULL
    BEGIN
        SELECT 0 AS [Status], 'NOT_FOUND' AS Code, N'That job was not found.' AS [Message], NULL AS Id;
        RETURN;
    END

    IF @CurrentStatus = 4
    BEGIN
        -- Asking twice is not an error (2.48).
        SELECT 1 AS [Status], 'ALREADY_CLOSED' AS Code,
               N'That job is already closed.' AS [Message], @JobId AS Id;
        RETURN;
    END

    IF @CurrentStatus = 1
    BEGIN
        SELECT 0 AS [Status], 'JOB_NOT_PUBLISHED' AS Code,
               N'A draft has not been published, so it cannot be closed.' AS [Message], NULL AS Id;
        RETURN;
    END

    UPDATE dbo.t_app_jobs
    SET JobStatusId = 4,
        ClosedOn    = SYSUTCDATETIME(),
        ModifiedOn  = SYSUTCDATETIME(),
        ModifiedBy  = @ActorUserId,
        RowVersion  = RowVersion + 1
    WHERE JobId = @JobId;

    SELECT 1 AS [Status], NULL AS Code, NULL AS [Message], @JobId AS Id;
END
GO


/*==============================================================================
  USP_GetJobList — the school's own jobs, scoped and status-filtered.

  @StatusId filters on the EFFECTIVE status, so asking for Expired returns
  Active rows whose date has passed — which is what the person means.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetJobList
    @SchoolId   bigint,
    @UserUid    uniqueidentifier,
    @StatusId   int = NULL,
    @BranchId   bigint = NULL,
    @Top        int = 200
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP (@Top)
        j.JobId,
        j.JobUid,
        j.BranchId,
        b.BranchName,
        j.JobTitle,
        j.SubjectId,
        j.DesignationId,
        j.EmploymentTypeId,
        j.NoOfVacancies,
        j.SalaryMin,
        j.SalaryMax,
        j.IsSalaryNegotiable,
        j.LastDateToApply,
        j.PublishedOn,
        j.ClosedOn,
        j.ViewCount,
        j.ApplicationCount,
        j.RowVersion,

        -- 🔴 What is STORED …
        j.JobStatusId                                                        AS StoredStatusId,
        -- 🔴 … and what it EFFECTIVELY is. One definition, one function.
        dbo.fn_EffectiveJobStatusId(j.JobStatusId, j.LastDateToApply)         AS JobStatusId,
        st.Name                                                              AS StoredStatusName,
        es.Name                                                              AS StatusName,

        -- 🔴 Aliased. Dapper does not strip underscores (2.61, incident G25).
        j.Is_Active AS IsActive
    FROM dbo.t_app_jobs j
        INNER JOIN dbo.fn_VisibleBranches(@SchoolId, @UserUid) v ON v.BranchId = j.BranchId
        INNER JOIN dbo.t_app_school_branches b ON b.BranchId = j.BranchId
        INNER JOIN dbo.m_app_job_status st ON st.JobStatusId = j.JobStatusId
        INNER JOIN dbo.m_app_job_status es
                ON es.JobStatusId = dbo.fn_EffectiveJobStatusId(j.JobStatusId, j.LastDateToApply)
    WHERE j.SchoolId = @SchoolId
      AND j.Is_Deleted = 0
      AND (@BranchId IS NULL OR j.BranchId = @BranchId)
      AND (@StatusId IS NULL
           OR dbo.fn_EffectiveJobStatusId(j.JobStatusId, j.LastDateToApply) = @StatusId)
    ORDER BY
        -- Drafts first (they need finishing), then newest.
        CASE WHEN j.JobStatusId = 1 THEN 0 ELSE 1 END,
        ISNULL(j.PublishedOn, j.CreatedOn) DESC,
        j.JobId DESC;
END
GO


/*==============================================================================
  USP_GetJobById — one job with its subject and class-level sets.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetJobById
    @SchoolId   bigint,
    @UserUid    uniqueidentifier,
    @JobId      bigint
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        j.JobId, j.JobUid, j.BranchId, b.BranchName, j.JobTitle,
        j.SubjectId, j.DesignationId, j.QualificationId, j.EmploymentTypeId,
        j.NoOfVacancies, j.MinExperienceMonths, j.MaxExperienceMonths,
        j.SalaryMin, j.SalaryMax, j.IsSalaryNegotiable,
        j.CityId, j.StateId, j.WorkingDays, j.TimingFrom, j.TimingTo,
        j.LastDateToApply, j.ExpectedJoiningDate, j.JobDescription,
        j.PublishedOn, j.ClosedOn, j.ViewCount, j.ApplicationCount, j.RowVersion,

        j.JobStatusId                                                 AS StoredStatusId,
        dbo.fn_EffectiveJobStatusId(j.JobStatusId, j.LastDateToApply)  AS JobStatusId,
        es.Name                                                        AS StatusName,

        j.Is_Active AS IsActive        -- 🔴 2.61
    FROM dbo.t_app_jobs j
        INNER JOIN dbo.fn_VisibleBranches(@SchoolId, @UserUid) v ON v.BranchId = j.BranchId
        INNER JOIN dbo.t_app_school_branches b ON b.BranchId = j.BranchId
        INNER JOIN dbo.m_app_job_status es
                ON es.JobStatusId = dbo.fn_EffectiveJobStatusId(j.JobStatusId, j.LastDateToApply)
    WHERE j.JobId = @JobId AND j.SchoolId = @SchoolId AND j.Is_Deleted = 0;

    SELECT js.SubjectId
    FROM dbo.t_app_job_subjects js
        INNER JOIN dbo.t_app_jobs j ON j.JobId = js.JobId
        INNER JOIN dbo.fn_VisibleBranches(@SchoolId, @UserUid) v ON v.BranchId = j.BranchId
    WHERE js.JobId = @JobId AND js.Is_Deleted = 0 AND j.SchoolId = @SchoolId;

    SELECT jc.ClassLevelId
    FROM dbo.t_app_job_class_levels jc
        INNER JOIN dbo.t_app_jobs j ON j.JobId = jc.JobId
        INNER JOIN dbo.fn_VisibleBranches(@SchoolId, @UserUid) v ON v.BranchId = j.BranchId
    WHERE jc.JobId = @JobId AND jc.Is_Deleted = 0 AND j.SchoolId = @SchoolId;
END
GO


/*==============================================================================
  USP_GetSchoolJobStats — the dashboard's jobs area.

  ⚠️ 3I gave the dashboard an HONEST EMPTY state for jobs because there was no
  table to count. There is now, so it shows real counts — and a school with no
  jobs shows a real zero, which is a measurement rather than a placeholder.

  🔴 The APPLICATIONS area stays a not-yet empty state. t_app_applications is
  Phase 5, and a zero there would still be a number with nothing behind it.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetSchoolJobStats
    @SchoolId   bigint,
    @UserUid    uniqueidentifier,
    @RecentTop  int = 5
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        COUNT(*)                                                                        AS TotalJobs,
        SUM(CASE WHEN e.EffectiveStatusId = 1 THEN 1 ELSE 0 END)                        AS DraftCount,
        SUM(CASE WHEN e.EffectiveStatusId = 2 THEN 1 ELSE 0 END)                        AS ActiveCount,
        SUM(CASE WHEN e.EffectiveStatusId = 3 THEN 1 ELSE 0 END)                        AS ExpiredCount,
        SUM(CASE WHEN e.EffectiveStatusId = 4 THEN 1 ELSE 0 END)                        AS ClosedCount
    FROM dbo.t_app_jobs j
        INNER JOIN dbo.fn_VisibleBranches(@SchoolId, @UserUid) v ON v.BranchId = j.BranchId
        CROSS APPLY (SELECT dbo.fn_EffectiveJobStatusId(j.JobStatusId, j.LastDateToApply)
                            AS EffectiveStatusId) e
    WHERE j.SchoolId = @SchoolId AND j.Is_Deleted = 0;

    SELECT TOP (@RecentTop)
        j.JobId, j.JobUid, j.JobTitle, b.BranchName,
        j.LastDateToApply, j.PublishedOn, j.NoOfVacancies,
        dbo.fn_EffectiveJobStatusId(j.JobStatusId, j.LastDateToApply) AS JobStatusId,
        es.Name AS StatusName
    FROM dbo.t_app_jobs j
        INNER JOIN dbo.fn_VisibleBranches(@SchoolId, @UserUid) v ON v.BranchId = j.BranchId
        INNER JOIN dbo.t_app_school_branches b ON b.BranchId = j.BranchId
        INNER JOIN dbo.m_app_job_status es
                ON es.JobStatusId = dbo.fn_EffectiveJobStatusId(j.JobStatusId, j.LastDateToApply)
    WHERE j.SchoolId = @SchoolId AND j.Is_Deleted = 0
    ORDER BY ISNULL(j.PublishedOn, j.CreatedOn) DESC, j.JobId DESC;
END
GO

PRINT '    Job procedures ready.';
GO
