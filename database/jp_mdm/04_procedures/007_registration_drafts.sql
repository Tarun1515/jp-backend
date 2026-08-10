/*==============================================================================
  jp_mdm — 04_procedures / 007_registration_drafts.sql

  USP_SaveSchoolRegistrationDraft   upsert the draft
  USP_GetSchoolRegistrationDraftId  which draft belongs to this user
  USP_SubmitRegistrationDraft       promote a draft to Pending

  ---------------------------------------------------------------------------
  🔴 A DRAFT IS A REQUEST IN DRAFT STATUS, NOT A SEPARATE TABLE
  ---------------------------------------------------------------------------
  The registration form is six steps plus document uploads. A school MUST be
  able to leave and come back — losing a half-filled form with documents
  already attached means they do not come back at all.

  The obvious design is a drafts table holding a JSON blob. It does not work,
  and the reason is documents: an upload is attached to a RequestId, so there
  has to be a request row before the first file can be stored. A JSON draft
  would need its own parallel document store, and then a migration of those
  documents onto the real request at submit — a step that can fail after the
  school has been told it succeeded.

  So the draft IS the request, sitting in StatusId 8 (DRAFT), which
  m_mdm_approval_status has always carried and nothing has used until now.
  Documents attach to it from the first upload and never move.

  ⚠️ The one-pending-per-entity index is filtered on StatusId = 1, so drafts
  do not collide with it. That is what makes this work without touching the
  index.

  ---------------------------------------------------------------------------
  WHY A DRAFT DOES NOT GET A REAL REQUEST NUMBER
  ---------------------------------------------------------------------------
  RequestNo is NOT NULL and unique, and the real one comes from a per-type,
  per-year counter. Allocating from that counter at draft time would burn a
  number every time somebody opened the form and wandered off, leaving
  permanent holes in a sequence people read as complete.

  So a draft carries `DRAFT-000123` from its own sequence, and the real number
  is allocated at submit — the moment the request actually exists as far as
  anybody outside is concerned.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*------------------------------------------------------------------------------
  The draft numbering. Separate from the real series on purpose — an abandoned
  draft must not leave a gap in the numbers a school can quote.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.sequences WHERE name = 'seq_mdm_draft_no' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating sequence [seq_mdm_draft_no] ...';

    CREATE SEQUENCE dbo.seq_mdm_draft_no AS int START WITH 1 INCREMENT BY 1;
END
GO


/*==============================================================================
  USP_SaveSchoolRegistrationDraft

  Called on every step change. Creates the draft on the first call and updates
  it thereafter, so the school's work survives a closed tab, a flat battery, or
  finishing on a different device.

  Returns the RequestId and the EntityUid, both of which the client needs: the
  first to upload documents against, the second so a resumed draft keeps
  identifying the same school rather than inventing a new one each save.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SaveSchoolRegistrationDraft
    @RequestorUserId    bigint,
    @OrganizationUid    uniqueidentifier = NULL,

    /*
      NULL on the first save; the caller sends back what it was given after
      that. Generated here rather than by the client so two tabs cannot create
      two entities for one school.
    */
    @EntityUid          uniqueidentifier = NULL,

    @SchoolName         nvarchar(200)  = NULL,
    @SchoolTypeId       int            = NULL,
    @BoardId            int            = NULL,
    @AffiliationNumber  varchar(50)    = NULL,
    @RegistrationNo     varchar(50)    = NULL,
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
    @AboutSchool        nvarchar(max)  = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL, @Id bigint = NULL,
            @Now datetime2 = SYSUTCDATETIME();

    DECLARE @DRAFT_STATUS int = 8, @SCHOOL_REG int = 1;

    IF @RequestorUserId IS NULL
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The requestor is required.';

    /*
      🔴 A school that already has a request in flight must not start a second
      one. Checked here rather than left to the unique index, because the index
      only covers Pending — a school with a Pending request could otherwise
      build a whole second draft and only discover the problem at submit, with
      the documents already uploaded.
    */
    IF @Code IS NULL AND @EntityUid IS NOT NULL
       AND EXISTS (SELECT 1 FROM dbo.t_mdm_approval_requests
                   WHERE RequestTypeId = @SCHOOL_REG AND EntityUid = @EntityUid
                     AND StatusId = 1 AND Is_Deleted = 0)
        SELECT @Code = 'ALREADY_PENDING',
               @Message = N'This registration has already been submitted and is being reviewed.';

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            -- The caller's existing draft, if there is one. One per user:
            -- a school registers itself once.
            SELECT @Id = RequestId, @EntityUid = COALESCE(@EntityUid, EntityUid)
            FROM dbo.t_mdm_approval_requests
            WHERE RequestorUserId = @RequestorUserId
              AND RequestTypeId   = @SCHOOL_REG
              AND StatusId        = @DRAFT_STATUS
              AND Is_Deleted      = 0;

            IF @Id IS NULL
            BEGIN
                SET @EntityUid = COALESCE(@EntityUid, NEWID());

                DECLARE @DraftNo varchar(30) =
                    'DRAFT-' + RIGHT('000000' + CAST(NEXT VALUE FOR dbo.seq_mdm_draft_no AS varchar(10)), 6);

                INSERT INTO dbo.t_mdm_approval_requests
                    (RequestNo, RequestTypeId, StatusId, CurrentApprovalLevel,
                     EntityUid, OrganizationUid, RequestorUserId, SubmittedOn, CreatedBy)
                VALUES
                    (@DraftNo, @SCHOOL_REG, @DRAFT_STATUS, 1,
                     @EntityUid, @OrganizationUid, @RequestorUserId, @Now, @RequestorUserId);

                SET @Id = SCOPE_IDENTITY();

                INSERT INTO dbo.t_mdm_school_registration_details
                    (RequestId, SchoolName, SchoolTypeId, BoardId, AffiliationNumber,
                     RegistrationNo, PanNumber, LogoPath, GroupType, EstablishedYear,
                     AddressLine1, AddressLine2, CityId, DistrictId, StateId, Pincode,
                     PrincipalName, PrincipalMobile, HrContactName, HrContactMobile,
                     ContactEmail, ContactMobile, Website, AboutSchool, CreatedBy)
                VALUES
                    (@Id, ISNULL(@SchoolName, N''), @SchoolTypeId, @BoardId, @AffiliationNumber,
                     @RegistrationNo, @PanNumber, @LogoPath, @GroupType, @EstablishedYear,
                     @AddressLine1, @AddressLine2, @CityId, @DistrictId, @StateId, @Pincode,
                     @PrincipalName, @PrincipalMobile, @HrContactName, @HrContactMobile,
                     @ContactEmail, @ContactMobile, @Website, @AboutSchool, @RequestorUserId);
            END
            ELSE
            BEGIN
                /*
                  A blanket overwrite, deliberately: the client sends the whole
                  form on every save, so a field cleared on screen has to clear
                  here. COALESCE-ing to the stored value would make deleting
                  anything impossible — the field would reappear on reload and
                  read as the save having failed.
                */
                UPDATE dbo.t_mdm_school_registration_details
                   SET SchoolName        = ISNULL(@SchoolName, N''),
                       SchoolTypeId      = @SchoolTypeId,
                       BoardId           = @BoardId,
                       AffiliationNumber = @AffiliationNumber,
                       RegistrationNo    = @RegistrationNo,
                       PanNumber         = @PanNumber,
                       LogoPath          = @LogoPath,
                       GroupType         = @GroupType,
                       EstablishedYear   = @EstablishedYear,
                       AddressLine1      = @AddressLine1,
                       AddressLine2      = @AddressLine2,
                       CityId            = @CityId,
                       DistrictId        = @DistrictId,
                       StateId           = @StateId,
                       Pincode           = @Pincode,
                       PrincipalName     = @PrincipalName,
                       PrincipalMobile   = @PrincipalMobile,
                       HrContactName     = @HrContactName,
                       HrContactMobile   = @HrContactMobile,
                       ContactEmail      = @ContactEmail,
                       ContactMobile     = @ContactMobile,
                       Website           = @Website,
                       AboutSchool       = @AboutSchool,
                       ModifiedOn        = @Now,
                       ModifiedBy        = @RequestorUserId
                 WHERE RequestId = @Id;

                UPDATE dbo.t_mdm_approval_requests
                   SET OrganizationUid = COALESCE(@OrganizationUid, OrganizationUid),
                       ModifiedOn      = @Now,
                       ModifiedBy      = @RequestorUserId
                 WHERE RequestId = @Id;
            END

            COMMIT TRANSACTION;

            SELECT @Status = 1, @Message = N'Draft saved.';
        END TRY
        BEGIN CATCH
            DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                    @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                    @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            DECLARE @Params nvarchar(max) = (
                SELECT @RequestorUserId AS requestorUserId, @EntityUid AS entityUid
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
                 @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
                 @ErrorMessage = @ErrMessage, @ParametersJson = @Params,
                 @ContextInfo = N'USP_SaveSchoolRegistrationDraft', @CreatedBy = @RequestorUserId;

            THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @Id AS Id,
           @EntityUid AS EntityUid;
END
GO


/*==============================================================================
  USP_GetSchoolRegistrationDraftId

  Which draft, if any, belongs to this user. Returns the id only — the caller
  then reads it through USP_GetApprovalRequestById, so there is one procedure
  that knows how to assemble a request and not two that must agree.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetSchoolRegistrationDraftId
    @RequestorUserId bigint
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP (1) RequestId
    FROM dbo.t_mdm_approval_requests
    WHERE RequestorUserId = @RequestorUserId
      AND RequestTypeId   = 1
      AND StatusId        = 8      -- DRAFT
      AND Is_Deleted      = 0
    ORDER BY RequestId DESC;
END
GO


/*==============================================================================
  USP_SubmitRegistrationDraft

  Promotes a draft to Pending: allocates the real request number, stamps the
  submission time, and writes the SUBMIT trail row.

  ⚠️ The number allocation is the SAME pattern as USP_SubmitApprovalRequest —
  an UPDATE with UPDLOCK and OUTPUT, never MAX()+1 — because two schools can
  submit in the same second and the counter is the only thing standing between
  that and two requests sharing a number.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SubmitRegistrationDraft
    @RequestId          bigint,
    @RequestorUserId    bigint,
    @IpAddress          varchar(45) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL, @Id bigint = @RequestId,
            @Now datetime2 = SYSUTCDATETIME();

    DECLARE @DRAFT_STATUS int = 8, @PENDING_STATUS int = 1, @ACTION_SUBMIT int = 4;

    DECLARE @RequestTypeId int = NULL, @EntityUid uniqueidentifier = NULL,
            @OwnerUserId bigint = NULL, @StatusId int = NULL, @Prefix varchar(10) = NULL;

    SELECT @RequestTypeId = r.RequestTypeId,
           @EntityUid     = r.EntityUid,
           @OwnerUserId   = r.RequestorUserId,
           @StatusId      = r.StatusId,
           @Prefix        = rt.RequestNoPrefix
    FROM dbo.t_mdm_approval_requests r
        INNER JOIN dbo.m_mdm_request_types rt ON rt.RequestTypeId = r.RequestTypeId
    WHERE r.RequestId = @RequestId AND r.Is_Deleted = 0;

    IF @RequestTypeId IS NULL
        SELECT @Code = 'NOT_FOUND', @Message = N'That draft was not found.';

    /*
      🔴 The draft belongs to whoever started it, and nobody else — not another
      user in the same organisation, not an administrator. A registration is
      the applicant's statement about themselves.
    */
    ELSE IF @OwnerUserId <> @RequestorUserId
        SELECT @Code = 'FORBIDDEN', @Message = N'That draft belongs to someone else.';

    ELSE IF @StatusId <> @DRAFT_STATUS
        SELECT @Code = 'INVALID_STATUS',
               @Message = N'This registration has already been submitted.';

    -- The name is the one field with no sensible empty value: a request the
    -- admin cannot identify is one that sits in the queue being skipped.
    ELSE IF NOT EXISTS (SELECT 1 FROM dbo.t_mdm_school_registration_details
                        WHERE RequestId = @RequestId AND Is_Deleted = 0
                          AND ISNULL(SchoolName, N'') <> N'')
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The school name is required.';

    ELSE IF EXISTS (SELECT 1 FROM dbo.t_mdm_approval_requests
                    WHERE RequestTypeId = @RequestTypeId AND EntityUid = @EntityUid
                      AND StatusId = @PENDING_STATUS AND Is_Deleted = 0)
        SELECT @Code = 'ALREADY_PENDING',
               @Message = N'This registration is already being reviewed.';

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            DECLARE @Year smallint = YEAR(dbo.fn_IstToday());   -- same helper the submit proc uses

            IF NOT EXISTS (SELECT 1 FROM dbo.t_mdm_request_number_series
                           WHERE RequestTypeId = @RequestTypeId AND SeriesYear = @Year)
            BEGIN
                BEGIN TRY
                    INSERT INTO dbo.t_mdm_request_number_series
                        (RequestTypeId, SeriesYear, LastNumber, CreatedBy)
                    VALUES (@RequestTypeId, @Year, 0, @RequestorUserId);
                END TRY
                BEGIN CATCH
                    -- Two first-of-the-year submissions racing. One loses the
                    -- insert; both need the UPDATE below.
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

            UPDATE dbo.t_mdm_approval_requests
               SET RequestNo            = @RequestNo,
                   StatusId             = @PENDING_STATUS,
                   CurrentApprovalLevel = 1,
                   SubmittedOn          = @Now,
                   RowVersion           = RowVersion + 1,
                   ModifiedOn           = @Now,
                   ModifiedBy           = @RequestorUserId
             WHERE RequestId = @RequestId AND StatusId = @DRAFT_STATUS;

            IF @@ROWCOUNT = 0
                THROW 50022, 'The draft changed while it was being submitted.', 1;

            INSERT INTO dbo.t_mdm_request_approvals
                (RequestId, LevelNumber, ActionTypeId, ActionByUserId,
                 Remarks, ActionOn, IpAddress, CreatedBy)
            VALUES
                (@RequestId, 1, @ACTION_SUBMIT, @RequestorUserId,
                 NULL, @Now, @IpAddress, @RequestorUserId);

            COMMIT TRANSACTION;

            SELECT @Status = 1, @Message = N'Your registration has been submitted for review.';
        END TRY
        BEGIN CATCH
            DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                    @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                    @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            DECLARE @Params nvarchar(max) = (
                SELECT @RequestId AS requestId, @RequestorUserId AS requestorUserId
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
                 @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
                 @ErrorMessage = @ErrMessage, @ParametersJson = @Params,
                 @ContextInfo = N'USP_SubmitRegistrationDraft', @CreatedBy = @RequestorUserId;

            THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @Id AS Id;
END
GO

PRINT '    Registration draft procedures ready.';
GO
