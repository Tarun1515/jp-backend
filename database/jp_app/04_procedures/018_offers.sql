/*==============================================================================
  jp_app — 04_procedures / 018_offers.sql

  Offer Lite — send, respond, withdraw, confirm.

  Phase 6A.

  ---------------------------------------------------------------------------
  🔴 EVERY ACTION HERE MOVES TWO TABLES IN ONE TRANSACTION
  ---------------------------------------------------------------------------
  An offer is a row in t_app_offers AND a position in the application's own
  machine, and the two must never disagree. Sending writes the offer and moves
  the application to OfferSent together; accepting writes the response and moves
  it to OfferAccepted together. If either half fails, neither happens.

  ⚠️ That is also why the generic status endpoint refuses 7..10 (016). The map
  permits those transitions; only these procedures may produce them, because
  only these procedures write the offer row alongside.

  ---------------------------------------------------------------------------
  🔴 THE DUPLICATE GUARD IS THE INDEX, AND THE CATCH CHECKS *WHICH* INDEX
  ---------------------------------------------------------------------------
  UQ_t_app_offers_LiveApplication refuses a second live offer. A
  SELECT-then-INSERT would let two sessions both pass their check — the 5A race,
  one table over.

  ⚠️ 3C'S LESSON, AGAIN AND LITERALLY. The CATCH compares the error message
  against the index NAME. A 2601 from any OTHER index must surface as itself,
  be logged, and roll back — never be reported as "already offered".

  And 2.48: a 2601 means "already done" only AFTER the existing row has been
  re-read. The row is read back and returned, so the caller gets the offer that
  actually exists rather than an assumption about it.

  ---------------------------------------------------------------------------
  ⚠️ NOTHING HERE COSTS ANYTHING
  ---------------------------------------------------------------------------
  There is no entitlement call in this file and none may be added. Offers are
  not a metered feature in this phase; the consuming actions are the job
  publish (2.64) and, from 6B, the teacher invite.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  USP_SendOffer — the school makes an offer.

  Application 5 Selected -> 7 OfferSent, or 9 OfferDeclined -> 7 OfferSent when
  this is a second offer after a decline (016's header argues that case).
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SendOffer
    @SchoolId            bigint,
    @UserUid             uniqueidentifier,
    @ApplicationId       bigint,
    @DesignationId       int,
    @OfferedSalary       decimal(12, 2) = NULL,
    @JoiningDate         date           = NULL,
    @ReportingTime       time(0)        = NULL,
    @TermsAndConditions  nvarchar(max)  = NULL,
    @ActorUserId         bigint         = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now datetime2 = SYSUTCDATETIME(),
            @FromStatusId int, @TeacherId bigint, @BranchId bigint,
            @OfferId bigint, @ExistingOfferId bigint;

    /*
      Resolve through the scope FIRST. An application at a campus this user does
      not hold leaves everything null and answers NOT_FOUND — never FORBIDDEN,
      which would confirm the application exists (2.6).
    */
    SELECT @FromStatusId = a.ApplicationStatusId,
           @TeacherId    = a.TeacherId,
           @BranchId     = a.BranchId
    FROM dbo.t_app_applications a
        INNER JOIN dbo.fn_VisibleBranches(@SchoolId, @UserUid) v ON v.BranchId = a.BranchId
    WHERE a.ApplicationId = @ApplicationId
      AND a.SchoolId      = @SchoolId
      AND a.Is_Deleted    = 0;

    IF @FromStatusId IS NULL
    BEGIN
        SELECT 0 AS [Status], 'NOT_FOUND' AS Code,
               N'That application was not found.' AS [Message], NULL AS Id;
        RETURN;
    END

    /*
      🔴 THE MAP DECIDES WHETHER AN OFFER MAY BE MADE FROM HERE.

      Not a hand-written list of statuses: 016 owns the machine, and a second
      copy of it in this file is how the two drift. Today that means 5 and 9;
      whatever 016 says tomorrow is what this accepts.
    */
    IF dbo.fn_ApplicationTransitionAllowed(@FromStatusId, 7) = 0
    BEGIN
        SELECT 0 AS [Status], 'INVALID_TRANSITION' AS Code,
               N'An offer can only be made to a candidate you have selected.' AS [Message],
               NULL AS Id;
        RETURN;
    END

    IF @DesignationId IS NULL
       OR NOT EXISTS (SELECT 1 FROM jp_mdm.dbo.m_mdm_designation d
                      WHERE d.DesignationId = @DesignationId AND d.Is_Deleted = 0 AND d.Is_Active = 1)
    BEGIN
        /*
          ⚠️ A SYNONYM-FREE cross-database READ, which 2.2 permits for masters —
          it is a lookup, not a join in a transaction, and there is no FK.
        */
        SELECT 0 AS [Status], 'VALIDATION_FAILED' AS Code,
               N'Choose the post being offered.' AS [Message], NULL AS Id;
        RETURN;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO dbo.t_app_offers
            (ApplicationId, SchoolId, BranchId, TeacherId, DesignationId,
             OfferedSalary, JoiningDate, ReportingTime, TermsAndConditions,
             OfferStatusId, SentOn, SentByUserId, CreatedBy)
        VALUES
            (@ApplicationId, @SchoolId, @BranchId, @TeacherId, @DesignationId,
             @OfferedSalary, @JoiningDate, @ReportingTime, @TermsAndConditions,
             1, @Now, @ActorUserId, @ActorUserId);

        SET @OfferId = SCOPE_IDENTITY();

        /*
          🔴 THE APPLICATION MOVES IN THE SAME TRANSACTION.

          RowVersion is bumped so a screen holding a stale copy is told, and the
          history row names the acting user — the same trail every other status
          change writes (024).
        */
        UPDATE dbo.t_app_applications
           SET ApplicationStatusId = 7,
               RowVersion          = RowVersion + 1,
               ModifiedOn          = @Now,
               ModifiedBy          = @ActorUserId
        WHERE ApplicationId = @ApplicationId
          AND ApplicationStatusId = @FromStatusId
          AND Is_Deleted = 0;

        IF @@ROWCOUNT = 0
            THROW 50061, 'The application moved while the offer was being sent.', 1;

        INSERT INTO dbo.t_app_application_status_history
            (ApplicationId, FromStatusId, ToStatusId, ChangedByUserId, Remarks, ChangedOn, CreatedBy)
        VALUES (@ApplicationId, @FromStatusId, 7, @ActorUserId, NULL, @Now, @ActorUserId);

        COMMIT TRANSACTION;

        SELECT 1 AS [Status], NULL AS Code, N'Offer sent.' AS [Message], @OfferId AS Id;
        RETURN;
    END TRY
    BEGIN CATCH
        DECLARE @E int = ERROR_NUMBER(), @S int = ERROR_SEVERITY(), @T int = ERROR_STATE(),
                @P sysname = ERROR_PROCEDURE(), @L int = ERROR_LINE(),
                @M nvarchar(4000) = ERROR_MESSAGE();

        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        /*
          🔴 THE 3C CHECK. A 2601 is "already offered" ONLY when the collision is
          on THIS index. Any other unique index that ever lands on this table
          must surface as itself — logged, re-thrown, and not wearing this one's
          clothes.
        */
        IF @E IN (2601, 2627) AND @M LIKE '%UQ_t_app_offers_LiveApplication%'
        BEGIN
            /*
              ⚠️ 2.48: RE-READ BEFORE REPORTING. "Already done" is a claim about
              a row, and the row is what proves it. The caller gets the offer
              that actually exists.
            */
            SELECT TOP (1) @ExistingOfferId = o.OfferId
            FROM dbo.t_app_offers o
            WHERE o.ApplicationId = @ApplicationId
              AND o.OfferStatusId = 1
              AND o.Is_Deleted    = 0
            ORDER BY o.OfferId;

            IF @ExistingOfferId IS NOT NULL
            BEGIN
                SELECT 1 AS [Status], 'ALREADY_OFFERED' AS Code,
                       N'This candidate already has an offer waiting for their response.' AS [Message],
                       @ExistingOfferId AS Id;
                RETURN;
            END
        END

        EXEC dbo.USP_LogError @ErrorNumber = @E, @ErrorSeverity = @S, @ErrorState = @T,
             @ErrorProcedure = @P, @ErrorLine = @L, @ErrorMessage = @M,
             @ContextInfo = N'USP_SendOffer', @CreatedBy = @ActorUserId;

        IF @E = 50061
        BEGIN
            SELECT 0 AS [Status], 'CONCURRENCY_CONFLICT' AS Code,
                   N'Someone else changed this application a moment ago. Reload and try again.' AS [Message],
                   NULL AS Id;
            RETURN;
        /*
          ⚠️ END; — the semicolon is load-bearing. T-SQL requires the statement
          BEFORE a THROW to be terminated, and a bare `END` is not, which fails
          with "Incorrect syntax near THROW" at deploy time rather than at
          runtime.
        */
        END;

        THROW;
    END CATCH
END
GO


/*==============================================================================
  USP_RespondToOffer — the TEACHER accepts or declines.

  🔴 ACCEPTING ONE OFFER DOES NOT TOUCH THE TEACHER'S OTHER APPLICATIONS, AND
  THAT IS A DECISION.

  The tempting behaviour is to withdraw everything else the moment somebody
  accepts. It is wrong three ways:

    · it is not the teacher's instruction. They accepted ONE offer; nobody
      asked them to abandon the others, and an acceptance can fall through
      before anyone joins;
    · there is no withdraw in the product at all (G28), so this would be the
      one place an application silently disappears — built sideways, for a
      case nobody designed;
    · 🔒 it would REVOKE CONSENT wholesale. Every other school's contact access
      rests on a live application (2.56); mass-closing them would pull contact
      out from under schools mid-conversation through a path nobody wrote down.

  ⚠️ So the other applications stay exactly as they are, and the schools
  holding them see no change. When withdraw is designed (G28), this is one of
  the cases it has to answer.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_RespondToOffer
    @TeacherId       bigint,
    @OfferId         bigint,
    @Accept          bit,
    @TeacherRemarks  nvarchar(1000) = NULL,
    @ActorUserId     bigint         = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now datetime2 = SYSUTCDATETIME(),
            @ApplicationId bigint, @OfferStatusId int, @FromStatusId int,
            @NewOfferStatus int = CASE WHEN @Accept = 1 THEN 2 ELSE 3 END,
            @NewAppStatus   int = CASE WHEN @Accept = 1 THEN 8 ELSE 9 END;

    /*
      🔴 MATCHED ON TeacherId. Another teacher's offer resolves to nothing and
      answers NOT_FOUND — the id is not an oracle (2.6).
    */
    SELECT @ApplicationId = o.ApplicationId,
           @OfferStatusId = o.OfferStatusId
    FROM dbo.t_app_offers o
    WHERE o.OfferId    = @OfferId
      AND o.TeacherId  = @TeacherId
      AND o.Is_Deleted = 0;

    IF @ApplicationId IS NULL
    BEGIN
        SELECT 0 AS [Status], 'NOT_FOUND' AS Code,
               N'That offer was not found.' AS [Message], NULL AS Id;
        RETURN;
    END

    IF @OfferStatusId <> 1
    BEGIN
        /*
          ⚠️ Not a race and not a mistake — usually a second tab, or a school
          that withdrew while the teacher was reading. The message says which
          rather than "invalid".
        */
        SELECT 0 AS [Status], 'OFFER_NOT_LIVE' AS Code,
               CASE @OfferStatusId
                 WHEN 2 THEN N'You have already accepted this offer.'
                 WHEN 3 THEN N'You have already declined this offer.'
                 WHEN 4 THEN N'The school withdrew this offer.'
                 ELSE N'This offer can no longer be answered.'
               END AS [Message], NULL AS Id;
        RETURN;
    END

    SELECT @FromStatusId = a.ApplicationStatusId
    FROM dbo.t_app_applications a
    WHERE a.ApplicationId = @ApplicationId AND a.Is_Deleted = 0;

    IF dbo.fn_ApplicationTransitionAllowed(@FromStatusId, @NewAppStatus) = 0
    BEGIN
        SELECT 0 AS [Status], 'INVALID_TRANSITION' AS Code,
               N'This application is no longer at the offer stage.' AS [Message], NULL AS Id;
        RETURN;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE dbo.t_app_offers
           SET OfferStatusId  = @NewOfferStatus,
               RespondedOn    = @Now,
               TeacherRemarks = @TeacherRemarks,
               RowVersion     = RowVersion + 1,
               ModifiedOn     = @Now,
               ModifiedBy     = @ActorUserId
        WHERE OfferId       = @OfferId
          AND OfferStatusId = 1                 -- the atomic half of the check
          AND Is_Deleted    = 0;

        IF @@ROWCOUNT = 0
            THROW 50062, 'The offer changed while it was being answered.', 1;

        UPDATE dbo.t_app_applications
           SET ApplicationStatusId = @NewAppStatus,
               RowVersion          = RowVersion + 1,
               ModifiedOn          = @Now,
               ModifiedBy          = @ActorUserId
        WHERE ApplicationId = @ApplicationId
          AND ApplicationStatusId = @FromStatusId
          AND Is_Deleted = 0;

        IF @@ROWCOUNT = 0
            THROW 50062, 'The application changed while the offer was being answered.', 1;

        INSERT INTO dbo.t_app_application_status_history
            (ApplicationId, FromStatusId, ToStatusId, ChangedByUserId, Remarks, ChangedOn, CreatedBy)
        VALUES (@ApplicationId, @FromStatusId, @NewAppStatus, @ActorUserId, @TeacherRemarks, @Now, @ActorUserId);

        COMMIT TRANSACTION;

        SELECT 1 AS [Status], NULL AS Code,
               CASE WHEN @Accept = 1 THEN N'Offer accepted.' ELSE N'Offer declined.' END AS [Message],
               @OfferId AS Id;
        RETURN;
    END TRY
    BEGIN CATCH
        DECLARE @E2 int = ERROR_NUMBER(), @S2 int = ERROR_SEVERITY(), @T2 int = ERROR_STATE(),
                @P2 sysname = ERROR_PROCEDURE(), @L2 int = ERROR_LINE(),
                @M2 nvarchar(4000) = ERROR_MESSAGE();

        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        EXEC dbo.USP_LogError @ErrorNumber = @E2, @ErrorSeverity = @S2, @ErrorState = @T2,
             @ErrorProcedure = @P2, @ErrorLine = @L2, @ErrorMessage = @M2,
             @ContextInfo = N'USP_RespondToOffer', @CreatedBy = @ActorUserId;

        IF @E2 = 50062
        BEGIN
            SELECT 0 AS [Status], 'CONCURRENCY_CONFLICT' AS Code,
                   N'This offer changed a moment ago. Reload to see where it stands.' AS [Message],
                   NULL AS Id;
            RETURN;
        /*
          ⚠️ END; — the semicolon is load-bearing. T-SQL requires the statement
          BEFORE a THROW to be terminated, and a bare `END` is not, which fails
          with "Incorrect syntax near THROW" at deploy time rather than at
          runtime.
        */
        END;

        THROW;
    END CATCH
END
GO


/*==============================================================================
  USP_WithdrawOffer — the school pulls its own offer.

  Offer -> Withdrawn, application 7 -> 5 Selected. The candidate is still
  selected, so the next offer is the ordinary 5 -> 7 edge rather than a special
  case (016's header).
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_WithdrawOffer
    @SchoolId     bigint,
    @UserUid      uniqueidentifier,
    @OfferId      bigint,
    @Reason       nvarchar(1000) = NULL,
    @ActorUserId  bigint         = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now datetime2 = SYSUTCDATETIME(),
            @ApplicationId bigint, @OfferStatusId int, @FromStatusId int;

    SELECT @ApplicationId = o.ApplicationId,
           @OfferStatusId = o.OfferStatusId
    FROM dbo.t_app_offers o
        INNER JOIN dbo.fn_VisibleBranches(@SchoolId, @UserUid) v ON v.BranchId = o.BranchId
    WHERE o.OfferId    = @OfferId
      AND o.SchoolId   = @SchoolId
      AND o.Is_Deleted = 0;

    IF @ApplicationId IS NULL
    BEGIN
        SELECT 0 AS [Status], 'NOT_FOUND' AS Code,
               N'That offer was not found.' AS [Message], NULL AS Id;
        RETURN;
    END

    IF @OfferStatusId <> 1
    BEGIN
        /*
          🔴 AN ANSWERED OFFER CANNOT BE WITHDRAWN. Pulling an offer the teacher
          has already accepted would rewrite what they were told — if a school
          needs to undo that, it is a conversation, not a button.
        */
        SELECT 0 AS [Status], 'OFFER_NOT_LIVE' AS Code,
               CASE @OfferStatusId
                 WHEN 2 THEN N'This offer has been accepted and cannot be withdrawn.'
                 WHEN 3 THEN N'This offer was already declined.'
                 WHEN 4 THEN N'This offer has already been withdrawn.'
                 ELSE N'This offer can no longer be withdrawn.'
               END AS [Message], NULL AS Id;
        RETURN;
    END

    SELECT @FromStatusId = a.ApplicationStatusId
    FROM dbo.t_app_applications a
    WHERE a.ApplicationId = @ApplicationId AND a.Is_Deleted = 0;

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE dbo.t_app_offers
           SET OfferStatusId     = 4,
               RespondedOn       = @Now,
               WithdrawnByUserId = @ActorUserId,
               WithdrawalReason  = @Reason,
               RowVersion        = RowVersion + 1,
               ModifiedOn        = @Now,
               ModifiedBy        = @ActorUserId
        WHERE OfferId       = @OfferId
          AND OfferStatusId = 1
          AND Is_Deleted    = 0;

        IF @@ROWCOUNT = 0
            THROW 50063, 'The offer changed while it was being withdrawn.', 1;

        /*
          ⚠️ The application only moves if it is still at OfferSent. A teacher
          who answered in the same instant wins — their response is the one that
          reached the row first, and the withdrawal above will have failed with
          @@ROWCOUNT = 0 before reaching here.
        */
        UPDATE dbo.t_app_applications
           SET ApplicationStatusId = 5,
               RowVersion          = RowVersion + 1,
               ModifiedOn          = @Now,
               ModifiedBy          = @ActorUserId
        WHERE ApplicationId       = @ApplicationId
          AND ApplicationStatusId = 7
          AND Is_Deleted          = 0;

        IF @@ROWCOUNT = 1
            INSERT INTO dbo.t_app_application_status_history
                (ApplicationId, FromStatusId, ToStatusId, ChangedByUserId, Remarks, ChangedOn, CreatedBy)
            VALUES (@ApplicationId, 7, 5, @ActorUserId, @Reason, @Now, @ActorUserId);

        COMMIT TRANSACTION;

        SELECT 1 AS [Status], NULL AS Code, N'Offer withdrawn.' AS [Message], @OfferId AS Id;
        RETURN;
    END TRY
    BEGIN CATCH
        DECLARE @E3 int = ERROR_NUMBER(), @S3 int = ERROR_SEVERITY(), @T3 int = ERROR_STATE(),
                @P3 sysname = ERROR_PROCEDURE(), @L3 int = ERROR_LINE(),
                @M3 nvarchar(4000) = ERROR_MESSAGE();

        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        EXEC dbo.USP_LogError @ErrorNumber = @E3, @ErrorSeverity = @S3, @ErrorState = @T3,
             @ErrorProcedure = @P3, @ErrorLine = @L3, @ErrorMessage = @M3,
             @ContextInfo = N'USP_WithdrawOffer', @CreatedBy = @ActorUserId;

        IF @E3 = 50063
        BEGIN
            SELECT 0 AS [Status], 'CONCURRENCY_CONFLICT' AS Code,
                   N'This offer changed a moment ago. Reload to see where it stands.' AS [Message],
                   NULL AS Id;
            RETURN;
        /*
          ⚠️ END; — the semicolon is load-bearing. T-SQL requires the statement
          BEFORE a THROW to be terminated, and a bare `END` is not, which fails
          with "Incorrect syntax near THROW" at deploy time rather than at
          runtime.
        */
        END;

        THROW;
    END CATCH
END
GO


/*==============================================================================
  USP_ConfirmHire — the school confirms the teacher actually started.

  Application 8 OfferAccepted -> 10 Hired. The OFFER is not touched: it was
  accepted, and it stays accepted. Hiring is a fact about the candidate.

  🔴 SEPARATE FROM ACCEPTANCE, DELIBERATELY. Collapsing the two would record
  people as hired who accepted and never arrived — which is the number a school
  will one day be asked to stand behind.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_ConfirmHire
    @SchoolId       bigint,
    @UserUid        uniqueidentifier,
    @ApplicationId  bigint,
    @Remarks        nvarchar(1000) = NULL,
    @ActorUserId    bigint         = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now datetime2 = SYSUTCDATETIME(), @FromStatusId int;

    SELECT @FromStatusId = a.ApplicationStatusId
    FROM dbo.t_app_applications a
        INNER JOIN dbo.fn_VisibleBranches(@SchoolId, @UserUid) v ON v.BranchId = a.BranchId
    WHERE a.ApplicationId = @ApplicationId
      AND a.SchoolId      = @SchoolId
      AND a.Is_Deleted    = 0;

    IF @FromStatusId IS NULL
    BEGIN
        SELECT 0 AS [Status], 'NOT_FOUND' AS Code,
               N'That application was not found.' AS [Message], NULL AS Id;
        RETURN;
    END

    IF dbo.fn_ApplicationTransitionAllowed(@FromStatusId, 10) = 0
    BEGIN
        SELECT 0 AS [Status], 'INVALID_TRANSITION' AS Code,
               N'Only a candidate who has accepted an offer can be marked as hired.' AS [Message],
               NULL AS Id;
        RETURN;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        UPDATE dbo.t_app_applications
           SET ApplicationStatusId = 10,
               RowVersion          = RowVersion + 1,
               ModifiedOn          = @Now,
               ModifiedBy          = @ActorUserId
        WHERE ApplicationId       = @ApplicationId
          AND ApplicationStatusId = @FromStatusId
          AND Is_Deleted          = 0;

        IF @@ROWCOUNT = 0
            THROW 50064, 'The application changed while it was being confirmed.', 1;

        INSERT INTO dbo.t_app_application_status_history
            (ApplicationId, FromStatusId, ToStatusId, ChangedByUserId, Remarks, ChangedOn, CreatedBy)
        VALUES (@ApplicationId, @FromStatusId, 10, @ActorUserId, @Remarks, @Now, @ActorUserId);

        COMMIT TRANSACTION;

        SELECT 1 AS [Status], NULL AS Code, N'Marked as hired.' AS [Message], @ApplicationId AS Id;
        RETURN;
    END TRY
    BEGIN CATCH
        DECLARE @E4 int = ERROR_NUMBER(), @S4 int = ERROR_SEVERITY(), @T4 int = ERROR_STATE(),
                @P4 sysname = ERROR_PROCEDURE(), @L4 int = ERROR_LINE(),
                @M4 nvarchar(4000) = ERROR_MESSAGE();

        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        EXEC dbo.USP_LogError @ErrorNumber = @E4, @ErrorSeverity = @S4, @ErrorState = @T4,
             @ErrorProcedure = @P4, @ErrorLine = @L4, @ErrorMessage = @M4,
             @ContextInfo = N'USP_ConfirmHire', @CreatedBy = @ActorUserId;

        IF @E4 = 50064
        BEGIN
            SELECT 0 AS [Status], 'CONCURRENCY_CONFLICT' AS Code,
                   N'This application changed a moment ago. Reload and try again.' AS [Message],
                   NULL AS Id;
            RETURN;
        /*
          ⚠️ END; — the semicolon is load-bearing. T-SQL requires the statement
          BEFORE a THROW to be terminated, and a bare `END` is not, which fails
          with "Incorrect syntax near THROW" at deploy time rather than at
          runtime.
        */
        END;

        THROW;
    END CATCH
END
GO


/*==============================================================================
  USP_GetOffersForApplication — every offer this application has ever had.

  🔴 THE WHOLE TRAIL, OLDEST FIRST. A second offer after a decline is allowed
  (016), so "what did we offer this person, and what happened" is a list and not
  a row. Returning only the live one would hide exactly the history the decision
  to allow re-offers was justified by.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetOffersForApplication
    @SchoolId       bigint,
    @UserUid        uniqueidentifier,
    @ApplicationId  bigint
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        o.OfferId,
        o.OfferUid,
        o.ApplicationId,
        o.BranchId,
        b.BranchName,
        o.DesignationId,
        o.OfferedSalary,
        o.JoiningDate,
        o.ReportingTime,
        o.TermsAndConditions,
        o.OfferStatusId,
        st.Name              AS OfferStatusName,
        st.IsLive,
        o.SentOn,
        o.SentByUserId,
        sent.FullName        AS SentByName,
        o.RespondedOn,
        o.TeacherRemarks,
        o.WithdrawalReason,
        o.RowVersion,
        o.Is_Active          AS IsActive          -- 🔴 2.61
    FROM dbo.t_app_offers o
        INNER JOIN dbo.fn_VisibleBranches(@SchoolId, @UserUid) v ON v.BranchId = o.BranchId
        INNER JOIN dbo.m_app_offer_status st      ON st.OfferStatusId = o.OfferStatusId
        INNER JOIN dbo.t_app_school_branches b    ON b.BranchId = o.BranchId
        LEFT  JOIN jp_sso.dbo.t_sso_users u       ON u.UserId = o.SentByUserId
        LEFT  JOIN dbo.t_app_school_users sent    ON sent.UserUid = u.UserUid
                                                 AND sent.SchoolId = @SchoolId
                                                 AND sent.Is_Deleted = 0
    WHERE o.ApplicationId = @ApplicationId
      AND o.SchoolId      = @SchoolId
      AND o.Is_Deleted    = 0
    ORDER BY o.OfferId;
END
GO


/*==============================================================================
  USP_GetMyOffers — the teacher's own offers.

  🔴 TeacherFacingName THROUGHOUT, and the school's WithdrawalReason is NOT in
  this projection. A withdrawal is the school acting against its own offer; the
  teacher is told it was withdrawn, which is the fact, and the school's internal
  note travels no further than the school — the same line 017 draws for a
  rejection reason.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetMyOffers
    @UserUid  uniqueidentifier,
    @LiveOnly bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TeacherId bigint;

    SELECT @TeacherId = t.TeacherId
    FROM dbo.t_app_teachers t
    WHERE t.UserUid = @UserUid AND t.Is_Deleted = 0 AND t.Is_Active = 1 AND t.IsSuspended = 0;

    SELECT
        o.OfferId,
        o.OfferUid,
        o.ApplicationId,
        a.JobId,
        j.JobTitle,
        o.DesignationId,
        o.OfferedSalary,
        o.JoiningDate,
        o.ReportingTime,
        o.TermsAndConditions,
        o.OfferStatusId,
        st.TeacherFacingName AS OfferStatusName,   -- 🔴 never st.Name
        st.IsLive,
        o.SentOn,
        o.RespondedOn,
        o.TeacherRemarks,
        s.SchoolUid,
        s.SchoolName,
        s.LogoPath           AS SchoolLogoPath,
        b.BranchName,
        o.Is_Active          AS IsActive           -- 🔴 2.61
    FROM dbo.t_app_offers o
        INNER JOIN dbo.m_app_offer_status st    ON st.OfferStatusId = o.OfferStatusId
        INNER JOIN dbo.t_app_applications a     ON a.ApplicationId = o.ApplicationId
        INNER JOIN dbo.t_app_jobs j             ON j.JobId = a.JobId
        INNER JOIN dbo.t_app_schools s          ON s.SchoolId = o.SchoolId
        INNER JOIN dbo.t_app_school_branches b  ON b.BranchId = o.BranchId
    WHERE o.TeacherId  = @TeacherId
      AND o.Is_Deleted = 0
      AND (@LiveOnly = 0 OR o.OfferStatusId = 1)
    ORDER BY o.SentOn DESC, o.OfferId DESC;
END
GO


PRINT '    Offer procedures ready.';
GO
