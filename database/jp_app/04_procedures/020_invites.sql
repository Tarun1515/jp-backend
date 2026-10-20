/*==============================================================================
  jp_app — 04_procedures / 020_invites.sql

  Teacher invites — send, view, answer. 🔒 CONSENT PATH 2.

  Phase 6B.

  ---------------------------------------------------------------------------
  🔒 ACCEPTING ONE OF THESE IS CONSENT (2.56, LOCKED). SENDING ONE IS NOT.
  ---------------------------------------------------------------------------
  `fn_TeacherContactUnlocked` reads this table and matches InviteStatusId = 3
  ACCEPTED, and nothing else. Every other state here — Sent, Viewed, Applied,
  Ignored — leaves contact exactly as locked as it was.

  ⚠️ That asymmetry is the ONLY thing standing between "a school paid for
  invites" and "a school bought a phone number", which 2.56 forbids in those
  words. A school may send an invite to every teacher on the platform and learn
  nothing about any of them.

  ---------------------------------------------------------------------------
  🔴 THE CONSUME IS INSIDE THE TRANSACTION, AND THE INSERT COMES FIRST
  ---------------------------------------------------------------------------
  TEACHER_INVITE is METERED, so sending costs. Two things follow, and the
  ORDER of them is the design:

    1. the INSERT runs first, so the filtered unique index decides whether
       this is a real invite before anybody is charged. A double-click's
       second attempt dies on the index and never reaches the meter.
    2. the consume uses the row's own InviteUid as its reference, so a retry
       of the SAME invite resolves to ALREADY_CONSUMED rather than charging
       twice (2.5).

  ⚠️ Had the consume run first it would have needed a Uid minted before the
  row existed — and a refused insert would then leave a charge for an invite
  nobody received. Phase 4 hit the mirror image of this on publish and solved
  it the same way: one transaction, and the cheap guard first.

  🔴 USP_ConsumeFeatureCore is CALLED, not copied — it carries the per-owner
  lock, the quota-then-credits order, the idempotency index and every refusal
  Code (014's header has the full argument, including why OUTPUT parameters
  rather than INSERT ... EXEC).

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  USP_SendInvite — a school invites a teacher. Costs one TEACHER_INVITE.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SendInvite
    @SchoolId         bigint,
    @UserUid          uniqueidentifier,
    @TeacherUid       uniqueidentifier,
    @BranchId         bigint,
    @JobId            bigint         = NULL,
    @Message          nvarchar(2000) = NULL,

    -- The gating read, resolved by the API through IEntitlementRepository (2.64).
    @OwnerUid         uniqueidentifier,
    @FeatureId        int,
    @GatingModeId     tinyint,
    @HasMapping       tinyint,
    @IsIncluded       tinyint = 0,
    @QuotaPerPeriod   int     = NULL,
    @ExpectedPlanId   int     = NULL,

    /*
      🔴 THE FALLBACK, THREADED THROUGH — G38, CLOSED IN PHASE 8-0.

      Identical to 014's: this procedure called USP_ConsumeFeatureCore without
      these four, so the core saw @FallbackPlanId = NULL and a school whose
      paid plan had lapsed was refused SUBSCRIPTION_INACTIVE instead of
      dropping to the free plan's allowance. Measured on a lapsed owner before
      the change: Status 0 SUBSCRIPTION_INACTIVE without them, Status 1 with.

      ⚠️ The invite path is the SECOND consuming action (2.64) and it had the
      same hole as publishing — which is the useful part of the finding. One
      forgotten parameter in one procedure is a slip; the same omission in both
      procedures that consume is a shape the next one would have copied.
    */
    @FallbackPlanId         int     = NULL,
    @FallbackHasMapping     tinyint = 0,
    @FallbackIsIncluded     tinyint = 0,
    @FallbackQuotaPerPeriod int     = NULL,

    @ActorUserId      bigint  = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL, @Message400 nvarchar(400) = NULL,
            @TeacherId bigint = NULL, @InviteId bigint = NULL,
            @InviteUid uniqueidentifier = NULL, @ExistingInviteId bigint = NULL,
            @Consumed tinyint = 0, @EntryId bigint = NULL, @SourceId tinyint = NULL,
            @QuotaUsed int, @QuotaRemaining int, @CreditBalance int,
            @PeriodFromUtc datetime2, @PeriodToUtc datetime2,
            @Now datetime2 = SYSUTCDATETIME();

    /*
      Everything that can refuse is checked OUTSIDE the transaction — a refusal
      should not have opened one, and nothing is charged until all of it passes.
    */

    /*
      🔴 THE TEACHER IS RESOLVED FROM A Uid, and suspended/inactive teachers
      resolve to nothing. A school must not be able to invite — or be charged
      for inviting — somebody the platform has suspended. Same exclusion the
      search applies, in the same words, because the two have to agree.
    */
    SELECT @TeacherId = t.TeacherId
    FROM dbo.t_app_teachers t
    WHERE t.TeacherUid  = @TeacherUid
      AND t.Is_Deleted  = 0
      AND t.Is_Active   = 1
      AND t.IsSuspended = 0;

    IF @TeacherId IS NULL
    BEGIN
        SELECT 0 AS [Status], 'NOT_FOUND' AS Code,
               N'That teacher was not found.' AS [Message],
               NULL AS Id, CAST(0 AS tinyint) AS Consumed, NULL AS SourceId;
        RETURN;
    END

    /*
      ⚠️ The campus must be one this user actually holds. BranchId is
      legitimate data AND an authorization input, and only this check tells
      them apart (2.39) — a branch the caller does not hold answers NOT_FOUND.
    */
    IF NOT EXISTS (SELECT 1 FROM dbo.fn_VisibleBranches(@SchoolId, @UserUid) v
                   WHERE v.BranchId = @BranchId)
    BEGIN
        SELECT 0 AS [Status], 'NOT_FOUND' AS Code,
               N'That campus was not found.' AS [Message],
               NULL AS Id, CAST(0 AS tinyint) AS Consumed, NULL AS SourceId;
        RETURN;
    END

    /*
      ⚠️ A JobId, when given, must be this school's own and still open. An
      invite pointing at somebody else's posting — or at one that has closed —
      would send the teacher to a page that answers 404.
    */
    IF @JobId IS NOT NULL
       AND NOT EXISTS (
            SELECT 1 FROM dbo.t_app_jobs j
            WHERE j.JobId = @JobId
              AND j.SchoolId = @SchoolId
              AND j.Is_Deleted = 0
              AND dbo.fn_EffectiveJobStatusId(j.JobStatusId, j.LastDateToApply) = 2)
    BEGIN
        SELECT 0 AS [Status], 'NOT_FOUND' AS Code,
               N'That job was not found, or it is no longer open.' AS [Message],
               NULL AS Id, CAST(0 AS tinyint) AS Consumed, NULL AS SourceId;
        RETURN;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        /*
          🔴 THE INSERT FIRST. The index is the cheap guard and it runs before
          the meter — see the file header.
        */
        INSERT INTO dbo.t_app_teacher_invites
            (SchoolId, BranchId, TeacherId, JobId, InvitedByUserId, Message,
             InviteStatusId, SentOn, CreatedBy)
        VALUES
            (@SchoolId, @BranchId, @TeacherId, @JobId, @ActorUserId, @Message,
             1, @Now, @ActorUserId);

        SET @InviteId = SCOPE_IDENTITY();

        SELECT @InviteUid = i.InviteUid FROM dbo.t_app_teacher_invites i WHERE i.InviteId = @InviteId;

        /*
          🔴 THE CONSUME, INSIDE THIS TRANSACTION, referenced by the row's own
          InviteUid. A retry of the same invite is ALREADY_CONSUMED, not a
          second charge (2.5).
        */
        EXEC dbo.USP_ConsumeFeatureCore
            @OwnerUid        = @OwnerUid,
            @FeatureId       = @FeatureId,
            @GatingModeId    = @GatingModeId,
            @HasMapping      = @HasMapping,
            @IsIncluded      = @IsIncluded,
            @QuotaPerPeriod  = @QuotaPerPeriod,
            @ExpectedPlanId  = @ExpectedPlanId,
            @FallbackPlanId         = @FallbackPlanId,
            @FallbackHasMapping     = @FallbackHasMapping,
            @FallbackIsIncluded     = @FallbackIsIncluded,
            @FallbackQuotaPerPeriod = @FallbackQuotaPerPeriod,
            @Units           = 1,
            @RefEntityTypeId = 2,                 -- INVITE
            @RefEntityUid    = @InviteUid,
            @Notes           = N'Teacher invite',
            @ActorUserId     = @ActorUserId,
            @Status          = @Status         OUTPUT,
            @Code            = @Code           OUTPUT,
            @Message         = @Message400     OUTPUT,
            @EntryId         = @EntryId        OUTPUT,
            @Consumed        = @Consumed       OUTPUT,
            @SourceId        = @SourceId       OUTPUT,
            @QuotaUsed       = @QuotaUsed      OUTPUT,
            @QuotaRemaining  = @QuotaRemaining OUTPUT,
            @CreditBalance   = @CreditBalance  OUTPUT,
            @PeriodFromUtc   = @PeriodFromUtc  OUTPUT,
            @PeriodToUtc     = @PeriodToUtc    OUTPUT;

        /*
          🔴 REFUSED -> NOTHING HAPPENS. The rollback takes the invite with it,
          so a school that has run out of invites has not silently sent one.
        */
        IF @Status = 0
        BEGIN
            ROLLBACK TRANSACTION;

            SELECT 0 AS [Status], @Code AS Code, @Message400 AS [Message],
                   NULL AS Id, CAST(0 AS tinyint) AS Consumed, NULL AS SourceId;
            RETURN;
        END

        /*
          ---- 🔴 PHASE 6C: THE TEACHER IS TOLD, AFTER THE METER AGREED ------

          Position matters here. This sits BELOW the refusal above, so a school
          that has run out of invitations has not notified anybody — the
          rollback would have taken the invite row and the notification
          together, but writing it earlier would have meant composing a
          notification for an invitation that was about to disappear.

          🔒 The notification carries the school's name and the school's own
          message, and nothing about the school's contact details or the
          teacher's. An invitation reaching somebody is not consent in either
          direction (2.56) — consent is the ACCEPTED row and nothing else.
        */
        EXEC dbo.USP_NotifyInvite @InviteId = @InviteId, @Event = 'RECEIVED';

        COMMIT TRANSACTION;

        SELECT 1 AS [Status], @Code AS Code,
               N'Invitation sent.' AS [Message], @InviteId AS Id,
               @Consumed AS Consumed, @SourceId AS SourceId;
        RETURN;
    END TRY
    BEGIN CATCH
        DECLARE @E int = ERROR_NUMBER(), @S int = ERROR_SEVERITY(), @T int = ERROR_STATE(),
                @P sysname = ERROR_PROCEDURE(), @L int = ERROR_LINE(),
                @M nvarchar(4000) = ERROR_MESSAGE();

        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        /*
          🔴 THE 3C CHECK. A 2601 is "already invited" ONLY when the collision
          is on THIS index. Any other unique index that ever lands on this
          table must surface as itself — logged, re-thrown, never wearing this
          one's clothes.
        */
        IF @E IN (2601, 2627) AND @M LIKE '%UQ_t_app_teacher_invites_Open%'
        BEGIN
            /*
              ⚠️ 2.48: RE-READ BEFORE REPORTING. "Already done" is a claim about
              a row, and the row is what proves it.

              🔴 AND NOTHING WAS CHARGED, because the insert ran before the
              meter. That is the whole reason for the order.
            */
            SELECT TOP (1) @ExistingInviteId = i.InviteId
            FROM dbo.t_app_teacher_invites i
            WHERE i.SchoolId = @SchoolId
              AND i.TeacherId = @TeacherId
              AND i.InviteStatusId IN (1, 2)
              AND i.Is_Deleted = 0
            ORDER BY i.InviteId;

            IF @ExistingInviteId IS NOT NULL
            BEGIN
                SELECT 1 AS [Status], 'ALREADY_INVITED' AS Code,
                       N'You already have an invitation waiting with this teacher.' AS [Message],
                       @ExistingInviteId AS Id, CAST(0 AS tinyint) AS Consumed, NULL AS SourceId;
                RETURN;
            END
        END

        EXEC dbo.USP_LogError @ErrorNumber = @E, @ErrorSeverity = @S, @ErrorState = @T,
             @ErrorProcedure = @P, @ErrorLine = @L, @ErrorMessage = @M,
             @ContextInfo = N'USP_SendInvite', @CreatedBy = @ActorUserId;

        THROW;
    END CATCH
END
GO


/*==============================================================================
  USP_MarkInviteViewed — the teacher opened it.

  🔴 IDEMPOTENT BY CONSTRUCTION. Only an invite still at Sent moves, so opening
  it twenty times stamps one timestamp and changes nothing else (2.48).

  ⚠️ AND IT UNLOCKS NOTHING. Reading a message is not answering it — 027's
  header and `fn_TeacherContactUnlocked` both say so, and this procedure
  touching only the status and a timestamp is what makes that true.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_MarkInviteViewed
    @UserUid   uniqueidentifier,
    @InviteId  bigint
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now datetime2 = SYSUTCDATETIME();

    UPDATE i
       SET i.InviteStatusId = 2,
           i.ViewedOn       = @Now,
           i.RowVersion     = i.RowVersion + 1,
           i.ModifiedOn     = @Now
    FROM dbo.t_app_teacher_invites i
        INNER JOIN dbo.t_app_teachers t ON t.TeacherId = i.TeacherId
    WHERE i.InviteId       = @InviteId
      AND t.UserUid        = @UserUid          -- 🔴 the teacher's own, or nothing
      AND i.InviteStatusId = 1
      AND i.Is_Deleted     = 0;

    SELECT 1 AS [Status], NULL AS Code, N'Seen.' AS [Message], @InviteId AS Id;
END
GO


/*==============================================================================
  USP_RespondToInvite — 🔒 the teacher ACCEPTS or IGNORES.

  🔒 ACCEPT IS CONSENT PATH 2. This is the procedure that makes 2.56's second
  path real: one UPDATE, and `fn_TeacherContactUnlocked` starts answering 1 for
  this school.

  ⚠️ IGNORE IS A REAL ANSWER, and it is recorded rather than left as silence —
  a school that can see "passed" stops following up, and the teacher is not
  pestered. It unlocks nothing, forever.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_RespondToInvite
    @UserUid         uniqueidentifier,
    @InviteId        bigint,
    @Accept          bit,
    @TeacherRemarks  nvarchar(1000) = NULL,
    @ActorUserId     bigint         = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now datetime2 = SYSUTCDATETIME(),
            @CurrentStatus int = NULL,
            @NewStatus int = CASE WHEN @Accept = 1 THEN 3 ELSE 5 END;

    /*
      🔴 MATCHED ON THE TEACHER'S OWN UserUid. Another teacher's invite resolves
      to nothing and answers NOT_FOUND — never "not yours", which would confirm
      it exists (2.6).
    */
    SELECT @CurrentStatus = i.InviteStatusId
    FROM dbo.t_app_teacher_invites i
        INNER JOIN dbo.t_app_teachers t ON t.TeacherId = i.TeacherId
    WHERE i.InviteId   = @InviteId
      AND t.UserUid    = @UserUid
      AND i.Is_Deleted = 0;

    IF @CurrentStatus IS NULL
    BEGIN
        SELECT 0 AS [Status], 'NOT_FOUND' AS Code,
               N'That invitation was not found.' AS [Message], NULL AS Id;
        RETURN;
    END

    /*
      ⚠️ Only an OPEN invite can be answered. An already-answered one is almost
      always a second tab, so the message names which answer was given rather
      than saying "invalid".
    */
    IF @CurrentStatus NOT IN (1, 2)
    BEGIN
        SELECT 0 AS [Status], 'INVITE_NOT_OPEN' AS Code,
               CASE @CurrentStatus
                 WHEN 3 THEN N'You have already accepted this invitation.'
                 WHEN 4 THEN N'You applied to this school instead.'
                 WHEN 5 THEN N'You have already passed on this invitation.'
                 ELSE N'This invitation can no longer be answered.'
               END AS [Message], NULL AS Id;
        RETURN;
    END

    UPDATE dbo.t_app_teacher_invites
       SET InviteStatusId = @NewStatus,
           RespondedOn    = @Now,
           TeacherRemarks = @TeacherRemarks,
           RowVersion     = RowVersion + 1,
           ModifiedOn     = @Now,
           ModifiedBy     = @ActorUserId
    WHERE InviteId       = @InviteId
      AND InviteStatusId IN (1, 2)             -- the atomic half of the check
      AND Is_Deleted     = 0;

    IF @@ROWCOUNT = 0
    BEGIN
        SELECT 0 AS [Status], 'CONCURRENCY_CONFLICT' AS Code,
               N'This invitation changed a moment ago. Reload to see where it stands.' AS [Message],
               NULL AS Id;
        RETURN;
    END

    /*
      ---- 🔴 PHASE 6C: THE SCHOOL'S TEAM IS TOLD ---------------------------

      ⚠️ This procedure has no explicit transaction — the UPDATE above is a
      single statement and is atomic on its own. So this call is placed after
      the @@ROWCOUNT guard, where the answer is known to have been recorded: a
      CONCURRENCY_CONFLICT returns before reaching here, and nobody is told
      about an answer that was not written.

      🔒 ACCEPTING IS CONSENT (2.56, path 2) and the school is about to be able
      to see this teacher's contact — but not because of this notification.
      `fn_TeacherContactUnlocked` reads the ACCEPTED row itself; this line
      only says it happened. Deleting every notification in the table would
      change nothing about who can see whose number.

      ⚠️ @TeacherRemarks is not passed on, for the same reason the offer's is
      not: it is stored on the invitation the school reads deliberately.
    */
    DECLARE @InviteEvent varchar(20) = CASE WHEN @Accept = 1 THEN 'ACCEPTED' ELSE 'IGNORED' END;

    EXEC dbo.USP_NotifyInvite @InviteId = @InviteId, @Event = @InviteEvent;

    SELECT 1 AS [Status], NULL AS Code,
           CASE WHEN @Accept = 1 THEN N'Invitation accepted.' ELSE N'Invitation declined.' END AS [Message],
           @InviteId AS Id;
END
GO


/*==============================================================================
  USP_GetInvitesForSchool — the school's outbox.

  🔒 NO CONTACT COLUMNS, even for an ACCEPTED invite — and that is not an
  oversight.

  An accepted invite DOES unlock contact. But this is a LIST, and the shape
  rule 3D set and 5A restated applies: a browse surface carries no contact,
  because it ends up in a screenshot, a log or an export. The school opens the
  teacher — USP_GetTeacherContactForSchool — which asks
  fn_TeacherContactUnlocked and is the one read designed to answer it.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetInvitesForSchool
    @SchoolId        bigint,
    @UserUid         uniqueidentifier,
    @InviteStatusId  int = NULL,
    @Top             int = 200
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP (@Top)
        i.InviteId,
        i.InviteUid,
        i.BranchId,
        b.BranchName,
        i.JobId,
        j.JobTitle,

        t.TeacherUid,
        t.FullName            AS TeacherName,
        t.PhotoPath,
        t.DesignationId       AS TeacherDesignationId,
        t.QualificationId     AS TeacherQualificationId,
        t.TotalExperienceMonths,
        t.CurrentCityId,
        t.CurrentStateId,
        t.IsVerified,
        t.ProfileCompletionPercent,

        i.Message,
        i.InviteStatusId,
        st.Name               AS InviteStatusName,    -- 🔴 the SCHOOL's wording
        st.IsOpen,
        st.IsConsent,
        i.SentOn,
        i.ViewedOn,
        i.RespondedOn,
        i.TeacherRemarks,
        i.RowVersion,
        i.Is_Active           AS IsActive             -- 🔴 2.61
    FROM dbo.t_app_teacher_invites i
        INNER JOIN dbo.fn_VisibleBranches(@SchoolId, @UserUid) v ON v.BranchId = i.BranchId
        INNER JOIN dbo.m_app_invite_status st   ON st.InviteStatusId = i.InviteStatusId
        INNER JOIN dbo.t_app_school_branches b  ON b.BranchId = i.BranchId
        INNER JOIN dbo.t_app_teachers t         ON t.TeacherId = i.TeacherId
        LEFT  JOIN dbo.t_app_jobs j             ON j.JobId = i.JobId
    WHERE i.SchoolId   = @SchoolId
      AND i.Is_Deleted = 0
      AND (@InviteStatusId IS NULL OR i.InviteStatusId = @InviteStatusId)
    ORDER BY i.SentOn DESC, i.InviteId DESC;
END
GO


/*==============================================================================
  USP_GetMyInvites — the teacher's inbox.

  🔴 TeacherFacingName throughout. And the school IS named, with its logo —
  which is the one place this product deliberately shows a school to a teacher
  before any consent exists, because "somebody wants to talk to you" is useless
  without knowing who.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetMyInvites
    @UserUid   uniqueidentifier,
    @OpenOnly  bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TeacherId bigint;

    SELECT @TeacherId = t.TeacherId
    FROM dbo.t_app_teachers t
    WHERE t.UserUid = @UserUid AND t.Is_Deleted = 0 AND t.Is_Active = 1 AND t.IsSuspended = 0;

    SELECT
        i.InviteId,
        i.InviteUid,
        i.JobId,
        j.JobTitle,
        j.SubjectId,
        j.DesignationId,
        j.SalaryMin,
        j.SalaryMax,
        j.IsSalaryNegotiable,
        j.LastDateToApply,

        s.SchoolUid,
        s.SchoolName,
        s.LogoPath            AS SchoolLogoPath,
        s.IsVerified          AS IsSchoolVerified,
        b.BranchName,
        b.CityId              AS BranchCityId,
        b.StateId             AS BranchStateId,

        i.Message,
        i.InviteStatusId,
        st.TeacherFacingName  AS InviteStatusName,    -- 🔴 never st.Name
        st.IsOpen,
        i.SentOn,
        i.ViewedOn,
        i.RespondedOn,
        i.TeacherRemarks,
        i.RowVersion,
        i.Is_Active           AS IsActive             -- 🔴 2.61
    FROM dbo.t_app_teacher_invites i
        INNER JOIN dbo.m_app_invite_status st   ON st.InviteStatusId = i.InviteStatusId
        INNER JOIN dbo.t_app_schools s          ON s.SchoolId = i.SchoolId
        INNER JOIN dbo.t_app_school_branches b  ON b.BranchId = i.BranchId
        LEFT  JOIN dbo.t_app_jobs j             ON j.JobId = i.JobId
    WHERE i.TeacherId  = @TeacherId
      AND i.Is_Deleted = 0
      AND (@OpenOnly = 0 OR i.InviteStatusId IN (1, 2))
    ORDER BY i.SentOn DESC, i.InviteId DESC;
END
GO


PRINT '    Invite procedures ready.';
GO
