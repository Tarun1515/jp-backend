/*==============================================================================
  jp_mdm — 04_procedures / 004_documents_masters.sql

  USP_SaveRequestDocument   upload, with the version bump
  USP_VerifyDocument        per-document verify or reject
  USP_GetMaster             generic, whitelist-driven master fetch

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  USP_SaveRequestDocument

  🔴 Never overwrites. A second upload of the same document type on the same
  request creates Version = previous + 1 and leaves the old row in place.

  A rejected document is the evidence for the rejection. If a resubmit replaced
  the file, the rejection reason would point at a document that no longer
  exists, and the applicant could change what was rejected after the fact.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SaveRequestDocument
    @RequestId          bigint,
    @DocumentTypeId     int,
    @FilePath           nvarchar(500),
    @FileName           nvarchar(255),
    @FileSizeKb         int,
    @MimeType           varchar(100),
    @ActionByUserId     bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL, @Id bigint = NULL,
            @Now datetime2 = SYSUTCDATETIME();

    DECLARE @MaxSizeKb int = NULL, @AllowedExt varchar(200) = NULL, @DocRequestType int = NULL;

    SELECT @MaxSizeKb = dt.MaxSizeKb, @AllowedExt = dt.AllowedExtensions, @DocRequestType = dt.RequestTypeId
    FROM dbo.m_mdm_document_types dt
    WHERE dt.DocumentTypeId = @DocumentTypeId AND dt.Is_Deleted = 0 AND dt.Is_Active = 1;

    DECLARE @RequestTypeId int = NULL, @RequestStatus int = NULL;

    SELECT @RequestTypeId = RequestTypeId, @RequestStatus = StatusId
    FROM dbo.t_mdm_approval_requests
    WHERE RequestId = @RequestId AND Is_Deleted = 0;

    -- The extension, lower-cased, from the last dot in the file name.
    DECLARE @Ext varchar(20) = LOWER(REVERSE(LEFT(REVERSE(@FileName),
                                CHARINDEX('.', REVERSE(@FileName) + '.') - 1)));

    IF @RequestTypeId IS NULL
        SELECT @Code = 'NOT_FOUND', @Message = N'That request was not found.';
    ELSE IF @MaxSizeKb IS NULL
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'That document type is not recognised.';
    ELSE IF @DocRequestType <> @RequestTypeId
        SELECT @Code = 'VALIDATION_FAILED',
               @Message = N'That document does not belong on this kind of request.';
    ELSE IF @RequestStatus IN (2, 3)   -- Rejected, Approved
        SELECT @Code = 'INVALID_STATUS',
               @Message = N'This request is closed and no longer accepts documents.';
    ELSE IF ISNULL(@FileSizeKb, 0) <= 0
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'That file appears to be empty.';
    ELSE IF @FileSizeKb > @MaxSizeKb
        SELECT @Code = 'FILE_TOO_LARGE',
               @Message = N'That file is larger than the ' + CAST(@MaxSizeKb / 1024 AS nvarchar(10)) + N' MB limit.';
    ELSE IF NOT EXISTS (SELECT 1 FROM STRING_SPLIT(@AllowedExt, ',')
                        WHERE LTRIM(RTRIM(LOWER(value))) = @Ext)
        SELECT @Code = 'INVALID_FILE_TYPE',
               @Message = N'That file type is not accepted. Allowed: ' + CAST(@AllowedExt AS nvarchar(200)) + N'.';

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            /*
              UPDLOCK/HOLDLOCK on the version read: two uploads racing would
              otherwise both read the same MAX and both insert Version = n+1,
              which the unique index would reject — failing an upload that was
              not wrong.
            */
            DECLARE @NextVersion int =
                ISNULL((SELECT MAX(d.Version)
                        FROM dbo.t_mdm_request_documents d WITH (UPDLOCK, HOLDLOCK)
                        WHERE d.RequestId = @RequestId
                          AND d.DocumentTypeId = @DocumentTypeId
                          AND d.Is_Deleted = 0), 0) + 1;

            INSERT INTO dbo.t_mdm_request_documents
                (RequestId, DocumentTypeId, FilePath, FileName, FileSizeKb, MimeType,
                 Version, IsVerified, CreatedBy)
            VALUES
                (@RequestId, @DocumentTypeId, @FilePath, @FileName, @FileSizeKb, @MimeType,
                 @NextVersion, 0, @ActionByUserId);

            SET @Id = SCOPE_IDENTITY();

            COMMIT TRANSACTION;

            SELECT @Status = 1, @Message = N'Document uploaded.';
        END TRY
        BEGIN CATCH
            DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                    @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                    @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            DECLARE @Params nvarchar(max) = (
                SELECT @RequestId AS requestId, @DocumentTypeId AS documentTypeId,
                       @FileName AS fileName, @FileSizeKb AS fileSizeKb
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
                 @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
                 @ErrorMessage = @ErrMessage, @ParametersJson = @Params,
                 @ContextInfo = N'USP_SaveRequestDocument', @CreatedBy = @ActionByUserId;

            THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @Id AS Id;
END
GO


/*==============================================================================
  USP_VerifyDocument

  Verify or reject ONE document. A rejection carries a reason — a document
  rejected without one leaves the applicant with nothing to act on.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_VerifyDocument
    @DocumentId         bigint,
    @IsVerified         tinyint,          -- 1 verified, 0 rejected
    @ActionByUserId     bigint,
    @RejectionReasonId  int            = NULL,
    @Remarks            nvarchar(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL, @Id bigint = @DocumentId,
            @Now datetime2 = SYSUTCDATETIME();

    IF NOT EXISTS (SELECT 1 FROM dbo.t_mdm_request_documents
                   WHERE DocumentId = @DocumentId AND Is_Deleted = 0)
        SELECT @Code = 'NOT_FOUND', @Message = N'That document was not found.';
    ELSE IF @IsVerified NOT IN (0, 1)
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The verification result is required.';
    ELSE IF @IsVerified = 0 AND @RejectionReasonId IS NULL
        SELECT @Code = 'VALIDATION_FAILED',
               @Message = N'A reason is required when rejecting a document.';
    ELSE IF @RejectionReasonId IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM dbo.m_mdm_rejection_reasons
                        WHERE RejectionReasonId = @RejectionReasonId AND Is_Deleted = 0)
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'That rejection reason is not recognised.';

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            UPDATE dbo.t_mdm_request_documents
               SET IsVerified        = @IsVerified,
                   VerifiedByUserId  = @ActionByUserId,
                   VerifiedOn        = @Now,
                   RejectionReasonId = CASE WHEN @IsVerified = 0 THEN @RejectionReasonId ELSE NULL END,
                   Remarks           = @Remarks,
                   ModifiedOn        = @Now,
                   ModifiedBy        = @ActionByUserId
            WHERE DocumentId = @DocumentId AND Is_Deleted = 0;

            COMMIT TRANSACTION;

            SELECT @Status = 1,
                   @Message = CASE WHEN @IsVerified = 1 THEN N'Document verified.'
                                   ELSE N'Document rejected.' END;
        END TRY
        BEGIN CATCH
            DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                    @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                    @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            DECLARE @Params nvarchar(max) = (
                SELECT @DocumentId AS documentId, @IsVerified AS isVerified,
                       @RejectionReasonId AS rejectionReasonId
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
                 @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
                 @ErrorMessage = @ErrMessage, @ParametersJson = @Params,
                 @ContextInfo = N'USP_VerifyDocument', @CreatedBy = @ActionByUserId;

            THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @Id AS Id;
END
GO


/*==============================================================================
  USP_GetMaster — one procedure for every master lookup.

  ---------------------------------------------------------------------------
  🔴 WHITELIST, NOT DYNAMIC SQL ON THE PARAMETER
  ---------------------------------------------------------------------------
  @MasterCode comes from a query string. Concatenating it into a table name is
  a SQL injection hole regardless of how it is quoted, so the parameter only
  ever selects a branch of a CASE that this file wrote.

  A master not listed here returns an empty set. Adding one is a deliberate
  edit, which is the point: the list of what an anonymous caller can enumerate
  should be visible in one place.

  ---------------------------------------------------------------------------
  ⚠️ THE KEY IS NORMALISED, BECAUSE A URL AND A CODE SPELL THINGS DIFFERENTLY
  ---------------------------------------------------------------------------
  The branch names below are SQL-ish: SCHOOL_TYPE, CLASS_LEVEL. The client
  sends a URL segment, which is kebab: /api/masters/school-type. Uppercasing
  alone turns that into SCHOOL-TYPE, which matches no branch and returns an
  empty list — a dropdown that is silently and permanently blank, with a 200
  and no error anywhere to explain it.

  Found in Phase 2E: every multi-word master was returning nothing. Normalising
  here rather than mapping in the API keeps decision 2.48's rule intact — one
  gate, in the procedure, with no second list to drift out of step with it.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetMaster
    @MasterCode varchar(50),
    @ParentId   int = NULL,    -- for the geography cascade and the scoped masters

    /*
      🔴 1 when the key matched a branch, 0 when it did not.

      The RESPONSE is unchanged either way — an unknown key still returns an
      empty set, because a caller probing for table names should learn nothing
      from the difference.

      But we should. A whitelist that fails closed and silently protects
      against an attacker and hides our own typos equally well, and only one of
      those was the intention: the school-type key mismatch (2.49) returned 200
      with no rows for weeks, and was found by a human noticing a blank
      dropdown rather than by anything in a log.

      So the caller learns nothing and the API logs a warning naming the key.
    */
    @Recognised bit = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @Recognised = 1;

    SET @MasterCode = UPPER(REPLACE(LTRIM(RTRIM(@MasterCode)), '-', '_'));

    IF @MasterCode = 'COUNTRY'
        SELECT CountryId AS Id, Code, Name, DisplayOrder FROM dbo.m_mdm_country
        WHERE Is_Deleted = 0 AND Is_Active = 1 ORDER BY DisplayOrder, Name;

    ELSE IF @MasterCode = 'STATE'
        SELECT StateId AS Id, Code, Name, DisplayOrder, CountryId AS ParentId FROM dbo.m_mdm_state
        WHERE Is_Deleted = 0 AND Is_Active = 1 AND (@ParentId IS NULL OR CountryId = @ParentId)
        ORDER BY DisplayOrder, Name;

    ELSE IF @MasterCode = 'DISTRICT'
        SELECT DistrictId AS Id, Code, Name, DisplayOrder, StateId AS ParentId FROM dbo.m_mdm_district
        WHERE Is_Deleted = 0 AND Is_Active = 1 AND (@ParentId IS NULL OR StateId = @ParentId)
        ORDER BY DisplayOrder, Name;

    ELSE IF @MasterCode = 'CITY'
        SELECT CityId AS Id, Code, Name, DisplayOrder, DistrictId AS ParentId FROM dbo.m_mdm_city
        WHERE Is_Deleted = 0 AND Is_Active = 1 AND (@ParentId IS NULL OR DistrictId = @ParentId)
        ORDER BY DisplayOrder, Name;

    ELSE IF @MasterCode = 'BOARD'
        SELECT BoardId AS Id, Code, Name, DisplayOrder FROM dbo.m_mdm_board
        WHERE Is_Deleted = 0 AND Is_Active = 1 ORDER BY DisplayOrder, Name;

    ELSE IF @MasterCode = 'SCHOOL_TYPE'
        SELECT SchoolTypeId AS Id, Code, Name, DisplayOrder FROM dbo.m_mdm_school_type
        WHERE Is_Deleted = 0 AND Is_Active = 1 ORDER BY DisplayOrder, Name;

    ELSE IF @MasterCode = 'QUALIFICATION'
        SELECT QualificationId AS Id, Code, Name, DisplayOrder FROM dbo.m_mdm_qualification
        WHERE Is_Deleted = 0 AND Is_Active = 1 ORDER BY DisplayOrder, Name;

    ELSE IF @MasterCode = 'SUBJECT'
        SELECT SubjectId AS Id, Code, Name, DisplayOrder FROM dbo.m_mdm_subject
        WHERE Is_Deleted = 0 AND Is_Active = 1 ORDER BY DisplayOrder, Name;

    ELSE IF @MasterCode = 'DESIGNATION'
        SELECT DesignationId AS Id, Code, Name, DisplayOrder FROM dbo.m_mdm_designation
        WHERE Is_Deleted = 0 AND Is_Active = 1 ORDER BY DisplayOrder, Name;

    ELSE IF @MasterCode = 'CLASS_LEVEL'
        SELECT ClassLevelId AS Id, Code, Name, DisplayOrder FROM dbo.m_mdm_class_level
        WHERE Is_Deleted = 0 AND Is_Active = 1 ORDER BY DisplayOrder, Name;

    ELSE IF @MasterCode = 'STREAM'
        SELECT StreamId AS Id, Code, Name, DisplayOrder FROM dbo.m_mdm_stream
        WHERE Is_Deleted = 0 AND Is_Active = 1 ORDER BY DisplayOrder, Name;

    ELSE IF @MasterCode = 'GENDER'
        SELECT GenderId AS Id, Code, Name, DisplayOrder FROM dbo.m_mdm_gender
        WHERE Is_Deleted = 0 AND Is_Active = 1 ORDER BY DisplayOrder, Name;

    ELSE IF @MasterCode = 'SKILL'
        SELECT SkillId AS Id, Code, Name, DisplayOrder FROM dbo.m_mdm_skill
        WHERE Is_Deleted = 0 AND Is_Active = 1 ORDER BY DisplayOrder, Name;

    ELSE IF @MasterCode = 'LANGUAGE'
        SELECT LanguageId AS Id, Code, Name, DisplayOrder FROM dbo.m_mdm_language
        WHERE Is_Deleted = 0 AND Is_Active = 1 ORDER BY DisplayOrder, Name;

    ELSE IF @MasterCode = 'FACILITY'
        SELECT FacilityId AS Id, Code, Name, DisplayOrder FROM dbo.m_mdm_facility
        WHERE Is_Deleted = 0 AND Is_Active = 1 ORDER BY DisplayOrder, Name;

    ELSE IF @MasterCode = 'EXPERIENCE_RANGE'
        SELECT ExperienceRangeId AS Id, Code, Name, DisplayOrder, MinMonths, MaxMonths
        FROM dbo.m_mdm_experience_range
        WHERE Is_Deleted = 0 AND Is_Active = 1 ORDER BY DisplayOrder, MinMonths;

    ELSE IF @MasterCode = 'REQUEST_TYPE'
        SELECT RequestTypeId AS Id, Code, Name, DisplayOrder FROM dbo.m_mdm_request_types
        WHERE Is_Deleted = 0 AND Is_Active = 1 ORDER BY DisplayOrder;

    ELSE IF @MasterCode = 'APPROVAL_STATUS'
        SELECT ApprovalStatusId AS Id, Code, Name, DisplayOrder FROM dbo.m_mdm_approval_status
        WHERE Is_Deleted = 0 AND Is_Active = 1 ORDER BY DisplayOrder;

    ELSE IF @MasterCode = 'ACTION_TYPE'
        SELECT ActionTypeId AS Id, Code, Name, DisplayOrder FROM dbo.m_mdm_action_types
        WHERE Is_Deleted = 0 AND Is_Active = 1 ORDER BY DisplayOrder;

    ELSE IF @MasterCode = 'DOCUMENT_TYPE'
        SELECT DocumentTypeId AS Id, Code, Name, DisplayOrder, RequestTypeId AS ParentId,
               IsMandatory, MaxSizeKb, AllowedExtensions
        FROM dbo.m_mdm_document_types
        WHERE Is_Deleted = 0 AND Is_Active = 1 AND (@ParentId IS NULL OR RequestTypeId = @ParentId)
        ORDER BY DisplayOrder, Name;

    ELSE IF @MasterCode = 'REJECTION_REASON'
        SELECT RejectionReasonId AS Id, Code, Name, DisplayOrder, RequestTypeId AS ParentId
        FROM dbo.m_mdm_rejection_reasons
        WHERE Is_Deleted = 0 AND Is_Active = 1 AND (@ParentId IS NULL OR RequestTypeId = @ParentId)
        ORDER BY DisplayOrder, Name;

    ELSE IF @MasterCode = 'PAYMENT_MODE'
        SELECT PaymentModeId AS Id, Code, Name, DisplayOrder FROM dbo.m_mdm_payment_modes
        WHERE Is_Deleted = 0 AND Is_Active = 1 ORDER BY DisplayOrder;

    ELSE IF @MasterCode = 'PAYMENT_STATUS'
        SELECT PaymentStatusId AS Id, Code, Name, DisplayOrder FROM dbo.m_mdm_payment_status
        WHERE Is_Deleted = 0 AND Is_Active = 1 ORDER BY DisplayOrder;

    ELSE
    BEGIN
        /*
          An unknown code returns nothing at all — not an error, because the
          caller cannot fix it, and not a guess.

          The flag is the only thing that changed in Phase 2F: the RESPONSE is
          identical, and the API turns this into a warning naming the key.
        */
        SET @Recognised = 0;

        SELECT TOP (0) CAST(NULL AS int) AS Id, CAST(NULL AS varchar(30)) AS Code,
                       CAST(NULL AS nvarchar(150)) AS Name, CAST(NULL AS int) AS DisplayOrder;
    END

END
GO

PRINT '    Document and master procedures ready.';
GO
