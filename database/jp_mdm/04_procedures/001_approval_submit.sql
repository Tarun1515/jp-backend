/*==============================================================================
  jp_mdm — 04_procedures / 001_approval_submit.sql

  USP_SubmitApprovalRequest
  USP_ResubmitApprovalRequest

  Both follow decision 2.21: a write procedure returns
  SELECT @Status, @Code, @Message, @Id. THROW is reserved for genuine integrity
  violations — never both in one procedure.

  CATCH ordering is capture -> rollback -> log -> respond (decision 2.31), cut
  from _TEMPLATE_procedure.sql.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  USP_SubmitApprovalRequest

  Creates the request header, the typed detail row, and any subject bridge
  rows — in ONE transaction. A header without its detail is a request the admin
  queue can show but nobody can open.

  ---------------------------------------------------------------------------
  🔴 IDEMPOTENT
  ---------------------------------------------------------------------------
  If a Pending request already exists for this (RequestTypeId, EntityUid) it is
  RETURNED, not duplicated. Two tabs, a double click, or a retry after a client
  timeout must not produce two rows in an admin's queue.

  The filtered unique index UQ_t_mdm_approval_requests_OnePendingPerEntity is
  the backstop, and it is what actually guarantees this. But hitting it produces
  a 2627 — an error, on a submission that was not wrong. So the check comes
  first and the index catches the race between the check and the insert.

  ---------------------------------------------------------------------------
  🔴 RequestNo — REG-SCH-2026-00001
  ---------------------------------------------------------------------------
  Sequenced per request type per IST year, from t_mdm_request_number_series.

  NOT MAX(...) + 1: two sessions read the same maximum before either inserts and
  both get the same number. Nothing errors — the duplicate just exists, until
  two schools quote the same reference to support.

  The UPDATE ... OUTPUT below takes an exclusive row lock for the rest of the
  transaction, so concurrent submissions of the same type in the same year
  serialise on that one row and everything else stays parallel.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SubmitApprovalRequest
    @RequestTypeId      int,
    @EntityUid          uniqueidentifier,
    @RequestorUserId    bigint,
    @OrganizationUid    uniqueidentifier = NULL,

    -- ---- school payload (RequestTypeId = 1 / 3) ----------------------------
    @SchoolName         nvarchar(200)  = NULL,
    @SchoolTypeId       int            = NULL,
    @BoardId            int            = NULL,
    @AffiliationNumber  varchar(50)    = NULL,
    @RegistrationNo     varchar(50)    = NULL,

    -- Optional. See the column comment on t_mdm_school_registration_details:
    -- blocking registration on a field an admin can chase later costs more
    -- sign-ups than it saves effort.
    @PanNumber          varchar(10)    = NULL,

    @LogoPath           nvarchar(500)  = NULL,
    @GroupType          tinyint        = NULL,
    @EstablishedYear    smallint       = NULL,
    @AddressLine1       nvarchar(250)  = NULL,
    @AddressLine2       nvarchar(250)  = NULL,
    @CityId             int            = NULL,
    @DistrictId         int            = NULL,
    @StateId            int            = NULL,
    @Pincode            varchar(10)    = NULL,
    @PrincipalName      nvarchar(150)  = NULL,
    @PrincipalMobile    varchar(15)    = NULL,
    @HrContactName      nvarchar(150)  = NULL,
    @HrContactMobile    varchar(15)    = NULL,
    @ContactEmail       nvarchar(150)  = NULL,
    @ContactMobile      varchar(15)    = NULL,
    @Website            nvarchar(255)  = NULL,
    @AboutSchool        nvarchar(max)  = NULL,

    -- ---- teacher payload (RequestTypeId = 2) -------------------------------
    @FullName               nvarchar(150) = NULL,
    @DOB                    date          = NULL,   -- calendar date (2.28)
    @GenderId               int           = NULL,
    @QualificationId        int           = NULL,
    @TotalExperienceMonths  int           = NULL,
    @CurrentCityId          int           = NULL,
    @CurrentStateId         int           = NULL,
    @CurrentSchool          nvarchar(200) = NULL,

    -- Comma-separated SubjectIds. Split with STRING_SPLIT (2017, allowed).
    @SubjectIds         varchar(500)   = NULL,

    @IpAddress          varchar(45)    = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status  int           = 0,
            @Code    varchar(50)   = NULL,
            @Message nvarchar(400) = NULL,
            @Id      bigint        = NULL,
            @Now     datetime2     = SYSUTCDATETIME();

    DECLARE @PENDING_STATUS int = 1,   -- m_mdm_approval_status.PENDING
            @ACTION_SUBMIT  int = 4;   -- m_mdm_action_types.SUBMIT

    /*--------------------------------------------------------------------------
      1. VALIDATE. Everything a caller could reasonably trigger is answered as
         Status = 0. No transaction is open, so a rejected call costs nothing.
    --------------------------------------------------------------------------*/
    DECLARE @Prefix varchar(10) = NULL;

    SELECT @Prefix = RequestNoPrefix
    FROM dbo.m_mdm_request_types
    WHERE RequestTypeId = @RequestTypeId AND Is_Deleted = 0 AND Is_Active = 1;

    IF @Prefix IS NULL
        SELECT @Code = 'VALIDATION_FAILED',
               @Message = N'That request type is not recognised.';
    ELSE IF @EntityUid IS NULL OR @EntityUid = 0x0
        SELECT @Code = 'VALIDATION_FAILED',
               @Message = N'The entity being registered is required.';
    ELSE IF ISNULL(@RequestorUserId, 0) <= 0
        SELECT @Code = 'VALIDATION_FAILED',
               @Message = N'The requesting user is required.';
    ELSE IF @RequestTypeId = 2 AND ISNULL(@FullName, N'') = N''
        SELECT @Code = 'VALIDATION_FAILED',
               @Message = N'Your full name is required.';
    ELSE IF @RequestTypeId IN (1, 3) AND ISNULL(@SchoolName, N'') = N''
        SELECT @Code = 'VALIDATION_FAILED',
               @Message = N'The school name is required.';

    /*--------------------------------------------------------------------------
      2. ALREADY PENDING? Return it rather than creating a second.

         Not an error: resubmitting the same thing is a normal consequence of a
         flaky connection, and the caller wants the request either way.
    --------------------------------------------------------------------------*/
    IF @Code IS NULL
    BEGIN
        SELECT TOP (1) @Id = RequestId
        FROM dbo.t_mdm_approval_requests
        WHERE RequestTypeId = @RequestTypeId
          AND EntityUid     = @EntityUid
          AND StatusId      = @PENDING_STATUS
          AND Is_Deleted    = 0;

        IF @Id IS NOT NULL
            SELECT @Status = 1,
                   @Code = 'ALREADY_PENDING',
                   @Message = N'A request for this is already awaiting review.';
    END

    /*--------------------------------------------------------------------------
      3. ACT.
    --------------------------------------------------------------------------*/
    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            -- ---- 3a. RequestNo, under the series row lock --------------------
            -- The IST year, not the UTC one: a request at 01:00 IST on 1 Jan is
            -- still 31 Dec in UTC, and numbering it into the old year would show
            -- up on the first request of every year (decision 2.28).
            DECLARE @Year smallint = YEAR(dbo.fn_IstToday());

            IF NOT EXISTS (SELECT 1 FROM dbo.t_mdm_request_number_series
                           WHERE RequestTypeId = @RequestTypeId AND SeriesYear = @Year)
            BEGIN
                -- Two sessions can both reach here for the first request of a
                -- year. The unique index makes one of them lose; swallow that
                -- one specific collision and carry on to the UPDATE, which is
                -- what both of them actually need.
                BEGIN TRY
                    INSERT INTO dbo.t_mdm_request_number_series
                        (RequestTypeId, SeriesYear, LastNumber, CreatedBy)
                    VALUES (@RequestTypeId, @Year, 0, @RequestorUserId);
                END TRY
                BEGIN CATCH
                    IF ERROR_NUMBER() NOT IN (2601, 2627) THROW;
                END CATCH
            END

            DECLARE @Seq TABLE (NextNumber int);

            UPDATE s
               SET LastNumber = s.LastNumber + 1,
                   ModifiedOn = @Now,
                   ModifiedBy = @RequestorUserId
            OUTPUT inserted.LastNumber INTO @Seq (NextNumber)
            FROM dbo.t_mdm_request_number_series AS s WITH (UPDLOCK, ROWLOCK)
            WHERE s.RequestTypeId = @RequestTypeId AND s.SeriesYear = @Year;

            DECLARE @NextNumber int = (SELECT TOP (1) NextNumber FROM @Seq);

            IF @NextNumber IS NULL
                THROW 50021, 'Could not allocate a request number.', 1;

            DECLARE @RequestNo varchar(30) =
                @Prefix + '-' + CAST(@Year AS varchar(4)) + '-'
                + RIGHT('00000' + CAST(@NextNumber AS varchar(10)), 5);

            -- ---- 3b. header --------------------------------------------------
            INSERT INTO dbo.t_mdm_approval_requests
                (RequestNo, RequestTypeId, StatusId, CurrentApprovalLevel,
                 EntityUid, OrganizationUid, RequestorUserId, SubmittedOn, CreatedBy)
            VALUES
                (@RequestNo, @RequestTypeId, @PENDING_STATUS, 1,
                 @EntityUid, @OrganizationUid, @RequestorUserId, @Now, @RequestorUserId);

            SET @Id = SCOPE_IDENTITY();

            -- ---- 3c. typed detail --------------------------------------------
            IF @RequestTypeId IN (1, 3)
            BEGIN
                INSERT INTO dbo.t_mdm_school_registration_details
                    (RequestId, SchoolName, SchoolTypeId, BoardId, AffiliationNumber,
                     RegistrationNo, PanNumber, LogoPath, GroupType, EstablishedYear,
                     AddressLine1, AddressLine2, CityId, DistrictId, StateId, Pincode,
                     PrincipalName, PrincipalMobile, HrContactName, HrContactMobile,
                     ContactEmail, ContactMobile, Website, AboutSchool, CreatedBy)
                VALUES
                    (@Id, @SchoolName, @SchoolTypeId, @BoardId, @AffiliationNumber,
                     @RegistrationNo, @PanNumber, @LogoPath, @GroupType, @EstablishedYear,
                     @AddressLine1, @AddressLine2, @CityId, @DistrictId, @StateId, @Pincode,
                     @PrincipalName, @PrincipalMobile, @HrContactName, @HrContactMobile,
                     @ContactEmail, @ContactMobile, @Website, @AboutSchool, @RequestorUserId);
            END
            ELSE IF @RequestTypeId = 2
            BEGIN
                INSERT INTO dbo.t_mdm_teacher_registration_details
                    (RequestId, FullName, DOB, GenderId, QualificationId,
                     TotalExperienceMonths, CurrentCityId, CurrentStateId,
                     CurrentSchool, CreatedBy)
                VALUES
                    (@Id, @FullName, @DOB, @GenderId, @QualificationId,
                     @TotalExperienceMonths, @CurrentCityId, @CurrentStateId,
                     @CurrentSchool, @RequestorUserId);

                -- ---- 3d. subject bridge --------------------------------------
                -- DISTINCT because a duplicate in the input would otherwise hit
                -- UQ_..._Request_Subject and fail a submission over a typo.
                IF NULLIF(@SubjectIds, '') IS NOT NULL
                BEGIN
                    INSERT INTO dbo.t_mdm_teacher_registration_subjects
                        (RequestId, SubjectId, CreatedBy)
                    SELECT DISTINCT @Id, TRY_CAST(LTRIM(RTRIM(value)) AS int), @RequestorUserId
                    FROM STRING_SPLIT(@SubjectIds, ',')
                    WHERE TRY_CAST(LTRIM(RTRIM(value)) AS int) IS NOT NULL;
                END
            END

            -- ---- 3e. the trail starts here -----------------------------------
            -- Submit is an action. Without this row the trail cannot answer
            -- "when was this sent in" without joining the header.
            INSERT INTO dbo.t_mdm_request_approvals
                (RequestId, LevelNumber, ActionTypeId, ActionByUserId, ActionOn, IpAddress, CreatedBy)
            VALUES
                (@Id, 1, @ACTION_SUBMIT, @RequestorUserId, @Now, @IpAddress, @RequestorUserId);

            COMMIT TRANSACTION;

            SELECT @Status = 1, @Message = N'Your request has been submitted for review.';
        END TRY
        BEGIN CATCH
            -- 1. CAPTURE
            DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                    @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                    @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

            -- 2. ROLLBACK
            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            -- 3. LOG — outside the transaction now, so the row survives.
            DECLARE @Params nvarchar(max) = (
                SELECT @RequestTypeId AS requestTypeId, @EntityUid AS entityUid,
                       @RequestorUserId AS requestorUserId, @OrganizationUid AS organizationUid
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
                 @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
                 @ErrorMessage = @ErrMessage, @ParametersJson = @Params,
                 @ContextInfo = N'USP_SubmitApprovalRequest', @CreatedBy = @RequestorUserId;

            -- 4. RESPOND. A 2627 here means the one-pending index caught the
            --    race between the check above and this insert — the caller's
            --    request DOES exist, just not the one this call made.
            IF @ErrNumber IN (2601, 2627)
            BEGIN
                SELECT TOP (1) @Id = RequestId
                FROM dbo.t_mdm_approval_requests
                WHERE RequestTypeId = @RequestTypeId AND EntityUid = @EntityUid
                  AND StatusId = @PENDING_STATUS AND Is_Deleted = 0;

                SELECT @Status = 1, @Code = 'ALREADY_PENDING',
                       @Message = N'A request for this is already awaiting review.';
            END
            ELSE
                THROW;
        END CATCH
    END

    /*--------------------------------------------------------------------------
      4. SINGLE EXIT.
    --------------------------------------------------------------------------*/
    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @Id AS Id;
END
GO


/*==============================================================================
  USP_ResubmitApprovalRequest

  The applicant answering a ResubmitRequired. Sets the request back to Pending,
  resets it to level 1, and appends a Resubmit action.

  🔴 Documents are NOT touched here. Their Version is bumped by
  USP_SaveRequestDocument when the replacement file is uploaded, and the earlier
  version is kept — a rejected document is the evidence of why it was rejected.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_ResubmitApprovalRequest
    @RequestId          bigint,
    @ActionByUserId     bigint,
    @Remarks            nvarchar(1000) = NULL,
    @RowVersion         int            = NULL,
    @IpAddress          varchar(45)    = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL, @Id bigint = @RequestId,
            @Now datetime2 = SYSUTCDATETIME();

    DECLARE @PENDING int = 1, @RESUBMIT_REQUIRED int = 4, @ACTION_RESUBMIT int = 5;

    DECLARE @CurrentStatus int = NULL, @CurrentRowVersion int = NULL;

    SELECT @CurrentStatus = StatusId, @CurrentRowVersion = RowVersion
    FROM dbo.t_mdm_approval_requests
    WHERE RequestId = @RequestId AND Is_Deleted = 0;

    IF @CurrentStatus IS NULL
        SELECT @Code = 'NOT_FOUND', @Message = N'That request was not found.';
    ELSE IF @CurrentStatus <> @RESUBMIT_REQUIRED
        SELECT @Code = 'INVALID_STATUS',
               @Message = N'This request is not awaiting a resubmission.';
    ELSE IF @RowVersion IS NOT NULL AND @RowVersion <> @CurrentRowVersion
        SELECT @Code = 'CONCURRENCY_CONFLICT',
               @Message = N'Someone else changed this request. Reload and try again.';

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            UPDATE dbo.t_mdm_approval_requests
               SET StatusId             = @PENDING,
                   CurrentApprovalLevel = 1,
                   ApproverUserId       = NULL,
                   CompletedOn          = NULL,
                   ModifiedOn           = @Now,
                   ModifiedBy           = @ActionByUserId,
                   RowVersion           = RowVersion + 1
            WHERE RequestId = @RequestId
              AND StatusId  = @RESUBMIT_REQUIRED
              AND Is_Deleted = 0;

            IF @@ROWCOUNT = 0
                THROW 50022, 'The request changed while it was being resubmitted.', 1;

            INSERT INTO dbo.t_mdm_request_approvals
                (RequestId, LevelNumber, ActionTypeId, ActionByUserId, Remarks, ActionOn, IpAddress, CreatedBy)
            VALUES
                (@RequestId, 1, @ACTION_RESUBMIT, @ActionByUserId, @Remarks, @Now, @IpAddress, @ActionByUserId);

            COMMIT TRANSACTION;

            SELECT @Status = 1, @Message = N'Your request has been resubmitted for review.';
        END TRY
        BEGIN CATCH
            DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                    @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                    @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            DECLARE @Params nvarchar(max) = (
                SELECT @RequestId AS requestId, @ActionByUserId AS actionByUserId
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
                 @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
                 @ErrorMessage = @ErrMessage, @ParametersJson = @Params,
                 @ContextInfo = N'USP_ResubmitApprovalRequest', @CreatedBy = @ActionByUserId;

            THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @Id AS Id;
END
GO

PRINT '    Approval submit procedures ready.';
GO
