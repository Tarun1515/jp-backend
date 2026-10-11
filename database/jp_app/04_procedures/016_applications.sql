/*==============================================================================
  jp_app — 04_procedures / 016_applications.sql

  Applying, the status machine, and saved jobs. Phase 5.

  ---------------------------------------------------------------------------
  🔴 AN APPLICATION IS CONSENT (2.56 — LOCKED)
  ---------------------------------------------------------------------------
  Writing a row in t_app_applications is what opens a teacher's phone number
  and email to ONE school. Until this phase there was no way to do that:
  fn_TeacherContactUnlocked returned a hard 0.

  Nothing in this file may unlock contact by any other route, and nothing here
  may consult a plan, a subscription or a quota. Applying is FREE — the
  consuming action is the school's PUBLISH (2.64), never the teacher's
  application. There is no ConsumeFeature call anywhere in this file, and there
  must never be one.

  ---------------------------------------------------------------------------
  🔴 ApplicationCount ON t_app_jobs IS NEVER WRITTEN HERE
  ---------------------------------------------------------------------------
  It is derived, everywhere, the same way quota use and job expiry are. Adding
  an UPDATE here would create a second source of truth that drifts silently —
  a number on a screen that stops matching the list under it, with nothing
  erroring. See 024's header.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  fn_ApplicationTransitionAllowed — the whole status machine, in one place.

  ---------------------------------------------------------------------------
  🔴 AN EXPLICIT MAP, NOT A SET OF IFS SCATTERED THROUGH A PROCEDURE
  ---------------------------------------------------------------------------
  Six reachable states and one function that answers every question about
  movement between them. A screen may draw whatever buttons it likes; this
  decides.

      1 Applied        -> 2 Viewed · 3 Shortlisted · 6 Rejected
      2 Viewed         -> 3 Shortlisted · 4 Interview · 6 Rejected
      3 Shortlisted    -> 4 Interview · 5 Selected · 6 Rejected
      4 Interview      -> 5 Selected · 6 Rejected
      5 Selected       -> 6 Rejected · 7 OfferSent
      6 Rejected       -> (nothing)

      --- Phase 6A, the offer chain ---
      7 OfferSent      -> 8 OfferAccepted · 9 OfferDeclined · 5 Selected
      8 OfferAccepted  -> 10 Hired
      9 OfferDeclined  -> 7 OfferSent · 6 Rejected
     10 Hired          -> (nothing)

  ⚠️ 🔴 REJECTED IS TERMINAL, AND THAT IS A DECISION, NOT AN OVERSIGHT.
  A rejected teacher has been told "not selected". Moving them back to
  Shortlisted would mean the product had told somebody something untrue, and
  the teacher-facing list would flicker between states with no explanation. A
  school that rejected somebody by mistake re-opens the conversation outside
  the product, or the teacher applies again to a new posting.

  ---------------------------------------------------------------------------
  🔴 PHASE 6A — 7..10 ARE IN THE MAP NOW, AND THE EDGES ARE DECISIONS
  ---------------------------------------------------------------------------
  Until 6A this function refused 7..10 outright: the ids were a contract but
  t_app_offers did not exist, so no action could legitimately produce them.
  It exists, and each new edge below was chosen rather than fallen into.

  **5 Selected -> 7 OfferSent, and nothing else reaches 7 from the interview
  side.** An offer follows a decision. Allowing 3 or 4 -> 7 would let a school
  offer somebody it has not recorded selecting, and the application history
  would skip the step the school actually took.

  **7 -> 5 is how a WITHDRAWAL lands.** The school pulled its own offer; the
  candidate is still selected, and the next offer uses the ordinary 5 -> 7
  edge. The alternative — inventing a "withdrawn" application status — would
  have put the OFFER's state into the APPLICATION's machine, which is the
  confusion 025's header exists to prevent.

  **9 OfferDeclined -> 7 OfferSent: a SECOND offer after a decline IS allowed.**
  The filtered unique index is on LIVE offers only, so a declined offer does
  not block a new one, and the question is whether the product should. It
  should: a teacher declining ₹40,000 and accepting ₹45,000 is an ordinary
  negotiation, and refusing it would push that conversation outside the
  product where nothing is recorded. ⚠️ The application's history carries the
  whole trail — OfferSent, OfferDeclined, OfferSent — so "how many times did we
  go back to this person" is answerable. Nothing is overwritten.

  **Withdrawn is the same answer for the same reason**, and arrives at it by a
  different route: withdrawal returns the application to 5, so a re-offer is
  not a special case at all — it is the first case again.

  **9 -> 6 Rejected**, because a school whose offer was declined must be able
  to close the application rather than leave it open forever.

  **8 OfferAccepted -> 10 Hired, and 10 is terminal.** Acceptance and hiring are
  separate on purpose: a teacher accepts, and the school confirms they actually
  started. Collapsing them would record people as hired who never arrived.

  ⚠️ 🔴 AND THE GENERIC STATUS ENDPOINT STILL REFUSES ALL FOUR. The map says
  what is legal; USP_SetApplicationStatus additionally refuses 7..10 because
  they are driven by the OFFER actions, which write the offer row and move the
  application in one transaction. Without that, a school could set an
  application to OfferSent with no offer behind it, or to Hired with nobody
  having accepted anything. One map, one narrower caller — see that procedure.
==============================================================================*/
CREATE OR ALTER FUNCTION dbo.fn_ApplicationTransitionAllowed
(
    @FromStatusId int,
    @ToStatusId   int
)
RETURNS bit
AS
BEGIN
    -- Moving to where it already is is not a transition; the caller answers
    -- that case separately so it can report it as "no change" rather than
    -- as a refusal.
    IF @FromStatusId = @ToStatusId RETURN 0;

    -- Nothing outside the master's ten is a status at all.
    IF @ToStatusId NOT IN (1, 2, 3, 4, 5, 6, 7, 8, 9, 10) RETURN 0;

    -- Nothing returns TO Applied. It is where an application begins, and
    -- putting one back would erase the fact that a school had seen it.
    IF @ToStatusId = 1 RETURN 0;

    RETURN CASE
        WHEN @FromStatusId = 1 AND @ToStatusId IN (2, 3, 6)    THEN 1
        WHEN @FromStatusId = 2 AND @ToStatusId IN (3, 4, 6)    THEN 1
        WHEN @FromStatusId = 3 AND @ToStatusId IN (4, 5, 6)    THEN 1
        WHEN @FromStatusId = 4 AND @ToStatusId IN (5, 6)       THEN 1
        WHEN @FromStatusId = 5 AND @ToStatusId IN (6, 7)       THEN 1

        -- Phase 6A. See the header for why each of these edges exists.
        WHEN @FromStatusId = 7 AND @ToStatusId IN (5, 8, 9)    THEN 1
        WHEN @FromStatusId = 8 AND @ToStatusId = 10            THEN 1
        WHEN @FromStatusId = 9 AND @ToStatusId IN (6, 7)       THEN 1

        ELSE 0                       -- 6 Rejected and 10 Hired are terminal
    END;
END
GO


/*==============================================================================
  USP_ApplyToJob — a teacher applies. This is consent path 1.

  ---------------------------------------------------------------------------
  🔴 THE DUPLICATE GUARD IS THE INDEX, AND THE CATCH CHECKS *WHICH* INDEX
  ---------------------------------------------------------------------------
  UQ_t_app_applications_JobTeacher refuses the second row. A SELECT-then-INSERT
  would let two parallel applies both pass their check.

  ⚠️ 3C'S LESSON, LITERALLY. That phase shipped a CATCH which claimed
  ALREADY_PROVISIONED on any 2601 without looking, and it hid a real bug. So
  this one compares the error message against the index NAME: a 2601 from any
  other index surfaces as itself. A CATCH that swallows every duplicate is a
  CATCH that will one day report success for something that did not happen.

  And 2.48's rule on top: 2601 means "already done" only AFTER re-reading the
  row. "The index says it is there" is not the same as having seen it.

  ---------------------------------------------------------------------------
  ⚠️ WHAT IS CHECKED BEFORE ANY OF THAT
  ---------------------------------------------------------------------------
    - the job is ACTIVE by its EFFECTIVE status (fn_EffectiveJobStatusId), so
      an expired job refuses server-side rather than by a hidden button;
    - the teacher has a resume, because the school will be reading a SNAPSHOT
      of it and an application with nothing to read wastes everybody's time;
    - 🔴 verification is NOT checked. An UNVERIFIED teacher may apply. Soft
      verification is a locked stance (2.9): the badge is a signal to schools,
      never a gate on the teacher.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_ApplyToJob
    @TeacherId    bigint,
    @JobId        bigint,
    @CoverNote    nvarchar(2000) = NULL,
    @ActorUserId  bigint         = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL, @Message nvarchar(400) = NULL,
            @Id bigint = NULL,
            @SchoolId bigint, @BranchId bigint, @EffectiveStatus int,
            @Resume nvarchar(500), @Now datetime2 = SYSUTCDATETIME();

    /*
      The job, by EFFECTIVE status. An Active row whose LastDateToApply has
      passed reads 3 (Expired) and is refused here — the same single definition
      the school's own list uses (Phase 4).
    */
    SELECT @SchoolId        = j.SchoolId,
           @BranchId        = j.BranchId,
           @EffectiveStatus = dbo.fn_EffectiveJobStatusId(j.JobStatusId, j.LastDateToApply)
    FROM dbo.t_app_jobs j
    WHERE j.JobId = @JobId AND j.Is_Deleted = 0;

    IF @SchoolId IS NULL
    BEGIN
        SELECT 0 AS [Status], 'NOT_FOUND' AS Code, N'That job was not found.' AS [Message], NULL AS Id;
        RETURN;
    END

    IF @EffectiveStatus = 3
    BEGIN
        SELECT 0 AS [Status], 'JOB_EXPIRED' AS Code,
               N'Applications for this job have closed.' AS [Message], NULL AS Id;
        RETURN;
    END

    IF @EffectiveStatus <> 2
    BEGIN
        -- Draft or Closed. Neither is visible to a teacher, so reaching this
        -- means a hand-built request; NOT_FOUND rather than a status leak.
        SELECT 0 AS [Status], 'NOT_FOUND' AS Code, N'That job was not found.' AS [Message], NULL AS Id;
        RETURN;
    END

    /*
      🔴 THE RESUME IS REQUIRED, AND ITS OWN CODE.

      The screen turns this into "add your resume, then apply" with a link
      straight to that section — which it can only do because the refusal names
      the missing piece instead of saying the request was invalid (2.12).
    */
    SELECT @Resume = t.ResumePath
    FROM dbo.t_app_teachers t
    WHERE t.TeacherId = @TeacherId AND t.Is_Deleted = 0;

    IF @Resume IS NULL OR LTRIM(RTRIM(@Resume)) = ''
    BEGIN
        SELECT 0 AS [Status], 'RESUME_REQUIRED' AS Code,
               N'Add your resume before applying — schools read it first.' AS [Message], NULL AS Id;
        RETURN;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        /*
          🔴 ResumePathSnapshot — COPIED, not referenced.

          The teacher may replace this file tomorrow. The school must go on
          seeing what it was given, and a school that shortlisted somebody must
          be able to re-read what it shortlisted.
        */
        INSERT INTO dbo.t_app_applications
            (JobId, TeacherId, SchoolId, BranchId, ApplicationStatusId,
             AppliedOn, ResumePathSnapshot, CoverNote, CreatedBy)
        VALUES
            (@JobId, @TeacherId, @SchoolId, @BranchId, 1,
             @Now, @Resume, @CoverNote, @ActorUserId);

        SET @Id = CAST(SCOPE_IDENTITY() AS bigint);

        /*
          The first history row. FromStatusId is NULL — "from nothing to
          Applied" is the honest shape; writing 1 -> 1 would claim a
          transition that never happened, and the CHECK constraint forbids it.
        */
        INSERT INTO dbo.t_app_application_status_history
            (ApplicationId, FromStatusId, ToStatusId, ChangedByUserId, ChangedOn, CreatedBy)
        VALUES (@Id, NULL, 1, @ActorUserId, @Now, @ActorUserId);

        /*
          ---- 🔴 PHASE 6B: AN OPEN INVITE FROM THIS SCHOOL IS NOW ANSWERED ----

          A school may invite a teacher and the teacher may apply INSTEAD of
          answering. That is a real answer, and leaving the invite sitting at
          Sent would show the school an outstanding invitation to somebody who
          has already applied to them.

          ⚠️ IN THIS TRANSACTION, deliberately. The application and the
          invite's state are one act; split apart there is a window where the
          teacher has applied and the school's outbox still says "waiting".

          🔒 AND IT CHANGES NOTHING ABOUT CONSENT. APPLIED is not an IsConsent
          row (027) and `fn_TeacherContactUnlocked` does not match it — the
          unlock comes from the APPLICATION, through path 1. One fact, one row:
          delete the application and the consent goes with it, which would not
          be true if this status granted anything.

          ⚠️ WHICH INVITES COUNT. An open invite naming THIS job, or one naming
          no job at all ("we would like to talk to you"). An invite about a
          DIFFERENT posting stays open, because applying to job A does not
          answer an invitation about job B.
        */
        UPDATE dbo.t_app_teacher_invites
           SET InviteStatusId = 4,                -- APPLIED
               RespondedOn    = @Now,
               RowVersion     = RowVersion + 1,
               ModifiedOn     = @Now,
               ModifiedBy     = @ActorUserId
        WHERE TeacherId      = @TeacherId
          AND SchoolId       = @SchoolId
          AND InviteStatusId IN (1, 2)
          AND Is_Deleted     = 0
          AND (JobId IS NULL OR JobId = @JobId);

        /*
          ---- 🔴 PHASE 6C: THE SCHOOL IS TOLD, IN THIS TRANSACTION ----------

          Same database, so the atomic guarantee costs nothing: an application
          that exists has its notification, and a rolled-back one has none.
          021's header argues this against 2.48 — that decision is about
          CROSS-database orchestration, which this is not.

          ⚠️ Fan-out is branch-scoped (021), so a viewer bound to another campus
          is not told about an applicant they would get a 404 for.

          ⚠️ The teacher's NAME is in the body, and that is not a 2.56 question
          — the browse profile returns the name to any school, and this school
          now has an application from them anyway. No email, no mobile, no
          resume path: those are only ever served by
          USP_GetTeacherContactForSchool.

          🔴 The title is stored, not rendered later (030's header): if the job
          is renamed tomorrow, this notification still says what the school was
          actually told today.
        */
        DECLARE @NotifJobTitle nvarchar(200) =
            (SELECT JobTitle FROM dbo.t_app_jobs WHERE JobId = @JobId);
        DECLARE @NotifTeacherName nvarchar(150) =
            (SELECT FullName FROM dbo.t_app_teachers WHERE TeacherId = @TeacherId);
        DECLARE @NotifAppUid uniqueidentifier =
            (SELECT ApplicationUid FROM dbo.t_app_applications WHERE ApplicationId = @Id);

        DECLARE @NotifBody nvarchar(1000) =
            @NotifTeacherName + N' applied to ' + @NotifJobTitle + N'.';

        /* Relative, inside jp-school — 030's header on why it is not absolute. */
        DECLARE @NotifUrl nvarchar(300) = N'/applicants/' + CAST(@Id AS nvarchar(20));

        EXEC dbo.USP_CreateSchoolNotifications
             @SchoolId           = @SchoolId,
             @BranchId           = @BranchId,
             @NotificationTypeId = 1,                 -- APPLICATION_RECEIVED
             @Title              = N'New application',
             @Body               = @NotifBody,
             @ActionUrl          = @NotifUrl,
             @RefEntityTypeId    = 1,
             @RefEntityUid       = @NotifAppUid;

        SET @Status = 1;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        DECLARE @E int = ERROR_NUMBER(), @S int = ERROR_SEVERITY(), @T int = ERROR_STATE(),
                @P sysname = ERROR_PROCEDURE(), @L int = ERROR_LINE(),
                @M nvarchar(4000) = ERROR_MESSAGE();

        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        /*
          🔴 2601 ON *THIS* INDEX ONLY — the 3C lesson.

          A duplicate key is only "already applied" when the duplicate is on
          UQ_t_app_applications_JobTeacher. Any other 2601 — a new index added
          later, a history collision — is a different bug and must surface as
          itself rather than wearing this one's clothes.

          ⚠️ And then the row is RE-READ (2.48). The index having complained is
          not the same as having seen what it complained about.
        */
        IF @E IN (2601, 2627) AND @M LIKE '%UQ_t_app_applications_JobTeacher%'
        BEGIN
            SELECT @Id = a.ApplicationId
            FROM dbo.t_app_applications a
            WHERE a.JobId = @JobId AND a.TeacherId = @TeacherId AND a.Is_Deleted = 0;

            IF @Id IS NOT NULL
            BEGIN
                /*
                  Status 1 — a success. The teacher wanted to have applied, and
                  they have. Treating a double-tap as an error would send
                  somebody to support over a working application.
                */
                SELECT @Status = 1, @Code = 'ALREADY_APPLIED',
                       @Message = N'You have already applied to this job.';
            END
            ELSE
            BEGIN
                SELECT @Status = 0, @Code = 'APPLY_CONFLICT',
                       @Message = N'That clashed with another change. Please try again.';
            END
        END

        IF @Status = 0 AND @Code IS NULL
        BEGIN
            DECLARE @Params nvarchar(max) = (
                SELECT @TeacherId AS teacherId, @JobId AS jobId
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @E, @ErrorSeverity = @S, @ErrorState = @T,
                 @ErrorProcedure = @P, @ErrorLine = @L, @ErrorMessage = @M,
                 @ParametersJson = @Params, @ContextInfo = N'USP_ApplyToJob',
                 @CreatedBy = @ActorUserId;

            THROW;
        END
    END CATCH

    SELECT @Status AS [Status], @Code AS Code, @Message AS [Message], @Id AS Id;
END
GO


/*==============================================================================
  USP_SetApplicationStatus — the school moves an application along.

  Every accepted move appends to t_app_application_status_history. The history
  is append-only: nothing here updates or deletes a row in it.

  ⚠️ Scoped through fn_VisibleBranches, so a branch-bound HR can only act on
  applications at campuses they hold — and an application outside their scope
  answers NOT_FOUND, never FORBIDDEN (2.6).

  ⚠️ @Remarks on a rejection is the school's OWN note. It is stored and it is
  never shown to the teacher in this phase; the teacher sees "Not selected".
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SetApplicationStatus
    @SchoolId       bigint,
    @UserUid        uniqueidentifier,
    @ApplicationId  bigint,
    @ToStatusId     int,
    @Remarks        nvarchar(1000) = NULL,
    @ActorUserId    bigint         = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL, @Message nvarchar(400) = NULL,
            @FromStatusId int, @Now datetime2 = SYSUTCDATETIME();

    SELECT @FromStatusId = a.ApplicationStatusId
    FROM dbo.t_app_applications a
        INNER JOIN dbo.fn_VisibleBranches(@SchoolId, @UserUid) v ON v.BranchId = a.BranchId
    WHERE a.ApplicationId = @ApplicationId
      AND a.SchoolId = @SchoolId
      AND a.Is_Deleted = 0;

    IF @FromStatusId IS NULL
    BEGIN
        SELECT 0 AS [Status], 'NOT_FOUND' AS Code,
               N'That application was not found.' AS [Message], NULL AS Id;
        RETURN;
    END

    IF @FromStatusId = @ToStatusId
    BEGIN
        -- Asking for the state it is already in is not an error (2.48).
        SELECT 1 AS [Status], 'NO_CHANGE' AS Code,
               N'That application is already in this state.' AS [Message], @ApplicationId AS Id;
        RETURN;
    END

    /*
      🔴 THE MAP DECIDES WHAT IS LEGAL. THIS ENDPOINT IS NARROWER THAN THE MAP.

      Two distinct codes, because the screen and the person need different
      things from them:

        OFFER_ACTION_REQUIRED  — "that stage is reached by sending, accepting,
                                 declining or withdrawing an OFFER, not by
                                 picking a stage here"
        INVALID_TRANSITION     — "you cannot go from here to there", which is
                                 about this application's history

      ⚠️ 6A RETIRED OFFER_STAGE_UNAVAILABLE FROM THIS PATH. That code meant
      "the product does not have offers yet" — 2.62's not-yet — and it stopped
      being true the day t_app_offers shipped. Leaving it would have told a
      school to wait for a release that had already happened.

      🔴 AND THE REFUSAL ITSELF STAYS, which is the part worth reading twice.
      fn_ApplicationTransitionAllowed now permits 5 -> 7, 7 -> 8, 8 -> 10 and
      the rest — but every one of those is produced by an OFFER action that
      writes the offer row and moves the application in ONE transaction. If
      this endpoint also accepted them, a school could set an application to
      OfferSent with no offer behind it, or to Hired with nobody having
      accepted anything, and the two tables would disagree with nothing
      erroring.
    */
    IF @ToStatusId IN (7, 8, 9, 10)
    BEGIN
        SELECT 0 AS [Status], 'OFFER_ACTION_REQUIRED' AS Code,
               N'Offer stages are set by sending, accepting, declining or withdrawing an offer.' AS [Message],
               NULL AS Id;
        RETURN;
    END

    IF @ToStatusId NOT IN (1, 2, 3, 4, 5, 6)
    BEGIN
        SELECT 0 AS [Status], 'VALIDATION_FAILED' AS Code,
               N'That is not a stage an application can be in.' AS [Message],
               NULL AS Id;
        RETURN;
    END

    IF dbo.fn_ApplicationTransitionAllowed(@FromStatusId, @ToStatusId) = 0
    BEGIN
        SELECT 0 AS [Status], 'INVALID_TRANSITION' AS Code,
               N'That is not a move this application can make from where it is.' AS [Message],
               NULL AS Id;
        RETURN;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE dbo.t_app_applications
        SET ApplicationStatusId = @ToStatusId,
            -- Only a rejection carries a reason; moving on from a rejection
            -- would otherwise leave a stale one attached.
            RejectionReason = CASE WHEN @ToStatusId = 6 THEN @Remarks ELSE NULL END,
            -- The first look stamps ViewedOn and never moves again.
            ViewedOn = CASE WHEN ViewedOn IS NULL AND @ToStatusId >= 2 THEN @Now ELSE ViewedOn END,
            ModifiedOn = @Now,
            ModifiedBy = @ActorUserId,
            RowVersion = RowVersion + 1
        WHERE ApplicationId = @ApplicationId;

        INSERT INTO dbo.t_app_application_status_history
            (ApplicationId, FromStatusId, ToStatusId, ChangedByUserId, Remarks, ChangedOn, CreatedBy)
        VALUES (@ApplicationId, @FromStatusId, @ToStatusId, @ActorUserId, @Remarks, @Now, @ActorUserId);

        /*
          ---- 🔴 PHASE 6C: THE TEACHER IS TOLD, IN THIS TRANSACTION ----------

          Which stages notify, and the wording, live in
          USP_NotifyApplicationStatus — because this is not the only path that
          produces these moves. USP_MarkApplicationViewed takes an application
          from Applied to Seen whenever a school OPENS it, which is how stage 2
          actually happens, and that procedure calls the same one.

          ⚠️ Two call sites, one decision. Had each written its own, the teacher
          would be told different things depending on which path the school
          happened to take, and the difference would never show up in a test
          that only exercised one of them.

          🔴 THE SILENCES ARE THE DESIGN, and 5 is the one to read twice:
            1 Applied     — the teacher just did this; telling them is noise.
            4 Interviewed — recorded after the fact; they were there.
            5 Selected    — the school's INTERNAL decision. What reaches the
                            teacher is the OFFER (2.73's two machines). Telling
                            them here would have them expecting an offer the
                            school has not sent, and may never send.
        */
        EXEC dbo.USP_NotifyApplicationStatus
             @ApplicationId = @ApplicationId,
             @ToStatusId    = @ToStatusId;

        SET @Status = 1;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        DECLARE @E int = ERROR_NUMBER(), @S int = ERROR_SEVERITY(), @T int = ERROR_STATE(),
                @P sysname = ERROR_PROCEDURE(), @L int = ERROR_LINE(),
                @M nvarchar(4000) = ERROR_MESSAGE();

        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        DECLARE @Params nvarchar(max) = (
            SELECT @ApplicationId AS applicationId, @ToStatusId AS toStatusId
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC dbo.USP_LogError @ErrorNumber = @E, @ErrorSeverity = @S, @ErrorState = @T,
             @ErrorProcedure = @P, @ErrorLine = @L, @ErrorMessage = @M,
             @ParametersJson = @Params, @ContextInfo = N'USP_SetApplicationStatus',
             @CreatedBy = @ActorUserId;

        THROW;
    END CATCH

    SELECT @Status AS [Status], @Code AS Code, @Message AS [Message], @ApplicationId AS Id;
END
GO


/*==============================================================================
  USP_MarkApplicationViewed — the automatic Applied -> Viewed on first open.

  ⚠️ Separate from USP_SetApplicationStatus because it is not a decision. A
  school opening an application is not choosing anything, and routing it
  through the deliberate-action procedure would write "somebody moved this to
  Viewed" into the history as though they had.

  It is idempotent by construction: only an application still at Applied moves,
  so opening it twenty times writes one history row.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_MarkApplicationViewed
    @SchoolId       bigint,
    @UserUid        uniqueidentifier,
    @ApplicationId  bigint,
    @ActorUserId    bigint = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now datetime2 = SYSUTCDATETIME(), @Current int;

    SELECT @Current = a.ApplicationStatusId
    FROM dbo.t_app_applications a
        INNER JOIN dbo.fn_VisibleBranches(@SchoolId, @UserUid) v ON v.BranchId = a.BranchId
    WHERE a.ApplicationId = @ApplicationId AND a.SchoolId = @SchoolId AND a.Is_Deleted = 0;

    IF @Current IS NULL
    BEGIN
        SELECT 0 AS [Status], 'NOT_FOUND' AS Code,
               N'That application was not found.' AS [Message], NULL AS Id;
        RETURN;
    END

    IF @Current <> 1
    BEGIN
        -- Already past Applied. Nothing to do, and nothing to record.
        SELECT 1 AS [Status], NULL AS Code, NULL AS [Message], @ApplicationId AS Id;
        RETURN;
    END

    BEGIN TRANSACTION;

    UPDATE dbo.t_app_applications
    SET ApplicationStatusId = 2,
        ViewedOn   = ISNULL(ViewedOn, @Now),
        ModifiedOn = @Now,
        ModifiedBy = @ActorUserId,
        RowVersion = RowVersion + 1
    WHERE ApplicationId = @ApplicationId AND ApplicationStatusId = 1;

    INSERT INTO dbo.t_app_application_status_history
        (ApplicationId, FromStatusId, ToStatusId, ChangedByUserId, Remarks, ChangedOn, CreatedBy)
    VALUES (@ApplicationId, 1, 2, @ActorUserId, N'Opened by the school', @Now, @ActorUserId);

    /*
      ---- 🔴 PHASE 6C: AND THIS IS THE PATH THAT ACTUALLY FIRES IT ----------

      A school reaching stage 2 by picking it from a dropdown is rare; a school
      reaching it by OPENING the application is what happens all day. Hooking
      only USP_SetApplicationStatus would have left "Seen by the school" as a
      notification the product could technically send and never did.

      ⚠️ Same procedure, so the two paths cannot drift apart.
    */
    EXEC dbo.USP_NotifyApplicationStatus
         @ApplicationId = @ApplicationId,
         @ToStatusId    = 2;

    COMMIT TRANSACTION;

    SELECT 1 AS [Status], NULL AS Code, NULL AS [Message], @ApplicationId AS Id;
END
GO


/*==============================================================================
  USP_ToggleSavedJob — a teacher's private shortlist.

  🔴 Saving is NOT applying and must never unlock contact. The school is told
  nothing by this table; fn_TeacherContactUnlocked does not read it.

  Soft-delete and revive rather than insert/delete, so the filtered unique
  index keeps one row per pair however many times somebody changes their mind.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_ToggleSavedJob
    @TeacherId    bigint,
    @JobId        bigint,
    @ActorUserId  bigint = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Existing bigint, @Saved tinyint = 0;

    IF NOT EXISTS (SELECT 1 FROM dbo.t_app_jobs WHERE JobId = @JobId AND Is_Deleted = 0)
    BEGIN
        SELECT 0 AS [Status], 'NOT_FOUND' AS Code, N'That job was not found.' AS [Message],
               NULL AS Id, CAST(0 AS tinyint) AS IsSaved;
        RETURN;
    END

    SELECT TOP (1) @Existing = Id FROM dbo.t_app_saved_jobs
    WHERE TeacherId = @TeacherId AND JobId = @JobId ORDER BY Id;

    IF @Existing IS NULL
    BEGIN
        INSERT INTO dbo.t_app_saved_jobs (TeacherId, JobId, CreatedBy)
        VALUES (@TeacherId, @JobId, @ActorUserId);

        SET @Existing = CAST(SCOPE_IDENTITY() AS bigint);
        SET @Saved = 1;
    END
    ELSE
    BEGIN
        UPDATE dbo.t_app_saved_jobs
        SET Is_Deleted = CASE WHEN Is_Deleted = 1 THEN 0 ELSE 1 END,
            SavedOn    = CASE WHEN Is_Deleted = 1 THEN SYSUTCDATETIME() ELSE SavedOn END,
            ModifiedOn = SYSUTCDATETIME(),
            ModifiedBy = @ActorUserId
        WHERE Id = @Existing;

        SELECT @Saved = CASE WHEN Is_Deleted = 0 THEN 1 ELSE 0 END
        FROM dbo.t_app_saved_jobs WHERE Id = @Existing;
    END

    SELECT 1 AS [Status], NULL AS Code, NULL AS [Message], @Existing AS Id, @Saved AS IsSaved;
END
GO

PRINT '    Application procedures ready.';
GO
