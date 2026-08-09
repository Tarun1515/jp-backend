/*==============================================================================
  jp_app — 04_procedures / 001_provisioning.sql

  USP_ProvisionSchoolFromApproval
  USP_FindOrphanedApprovals   (the reconciliation query)

  ⚠️ Pulled forward from Phase 3 by Phase 2D, for the same reason as
  t_app_schools: the cross-database step after an approval needs somewhere real
  to write.

  ---------------------------------------------------------------------------
  🔴 WHY THESE MUST BE IDEMPOTENT
  ---------------------------------------------------------------------------
  There is no distributed transaction across jp_sso, jp_mdm and jp_app, and
  there deliberately never will be (decision 2.2). The API orchestrates three
  separate commits, so any one of them can fail after an earlier one succeeded,
  and the operator's only recovery is to run it again.

  A retry that created a second school would turn a recoverable failure into a
  data problem. So provisioning keys on SourceRequestUid: called twice, the
  second call returns the row the first created.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*==============================================================================
  USP_ProvisionSchoolFromApproval

  Creates the school that an approved registration earned. Called by the API
  AFTER USP_ProcessApprovalAction reported IsCompleted, and after the user has
  been activated in jp_sso.

  Returns the standard envelope plus SchoolUid, and Code = 'ALREADY_PROVISIONED'
  when the row already existed — which is a SUCCESS, because the caller wanted
  the school to exist and it does.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_ProvisionSchoolFromApproval
    @SourceRequestUid   uniqueidentifier,
    @OrganizationUid    uniqueidentifier,
    @SchoolName         nvarchar(200),
    @SchoolTypeId       int            = NULL,
    @BoardId            int            = NULL,
    @AffiliationNumber  varchar(50)    = NULL,
    @RegistrationNo     varchar(50)    = NULL,
    @LogoPath           nvarchar(500)  = NULL,
    @GroupType          tinyint        = NULL,
    @EstablishedYear    smallint       = NULL,
    @AboutSchool        nvarchar(max)  = NULL,
    @Website            nvarchar(255)  = NULL,
    @ContactEmail       nvarchar(150)  = NULL,
    @ContactMobile      varchar(15)    = NULL,
    @PrincipalName      nvarchar(150)  = NULL,
    @HrContactName      nvarchar(150)  = NULL,
    @HrContactMobile    varchar(15)    = NULL,
    @AddressLine1       nvarchar(250)  = NULL,
    @AddressLine2       nvarchar(250)  = NULL,
    @CityId             int            = NULL,
    @DistrictId         int            = NULL,
    @StateId            int            = NULL,
    @Pincode            varchar(10)    = NULL,
    @VerifiedByUserId   bigint         = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL, @Id bigint = NULL,
            @SchoolUid uniqueidentifier = NULL,
            @Now datetime2 = SYSUTCDATETIME();

    IF @SourceRequestUid IS NULL
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The source request is required.';
    ELSE IF @OrganizationUid IS NULL
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The organisation is required.';
    ELSE IF ISNULL(@SchoolName, N'') = N''
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The school name is required.';

    -- Already provisioned? Return it. This is the retry path, and it succeeds.
    IF @Code IS NULL
    BEGIN
        SELECT @Id = SchoolId, @SchoolUid = SchoolUid
        FROM dbo.t_app_schools
        WHERE SourceRequestUid = @SourceRequestUid AND Is_Deleted = 0;

        IF @Id IS NOT NULL
            SELECT @Status = 1, @Code = 'ALREADY_PROVISIONED',
                   @Message = N'This school was already created for that approval.';
    END

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            INSERT INTO dbo.t_app_schools
                (OrganizationUid, SourceRequestUid, SchoolName, SchoolTypeId, BoardId,
                 AffiliationNumber, RegistrationNo, LogoPath, GroupType, EstablishedYear,
                 AboutSchool, Website, ContactEmail, ContactMobile,
                 PrincipalName, HrContactName, HrContactMobile,
                 AddressLine1, AddressLine2, CityId, DistrictId, StateId, Pincode,
                 IsVerified, VerifiedOn, VerifiedByUserId, CreatedBy)
            VALUES
                (@OrganizationUid, @SourceRequestUid, @SchoolName, @SchoolTypeId, @BoardId,
                 @AffiliationNumber, @RegistrationNo, @LogoPath, @GroupType, @EstablishedYear,
                 @AboutSchool, @Website, @ContactEmail, @ContactMobile,
                 @PrincipalName, @HrContactName, @HrContactMobile,
                 @AddressLine1, @AddressLine2, @CityId, @DistrictId, @StateId, @Pincode,
                 1, @Now, @VerifiedByUserId, @VerifiedByUserId);

            SET @Id = SCOPE_IDENTITY();
            SELECT @SchoolUid = SchoolUid FROM dbo.t_app_schools WHERE SchoolId = @Id;

            COMMIT TRANSACTION;

            SELECT @Status = 1, @Message = N'School created.';
        END TRY
        BEGIN CATCH
            DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                    @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                    @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            DECLARE @Params nvarchar(max) = (
                SELECT @SourceRequestUid AS sourceRequestUid, @OrganizationUid AS organizationUid,
                       @SchoolName AS schoolName
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
                 @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
                 @ErrorMessage = @ErrMessage, @ParametersJson = @Params,
                 @ContextInfo = N'USP_ProvisionSchoolFromApproval', @CreatedBy = @VerifiedByUserId;

            -- A duplicate here means a concurrent retry won the race. The
            -- caller wanted the school to exist, and it does.
            IF @ErrNumber IN (2601, 2627)
            BEGIN
                SELECT @Id = SchoolId, @SchoolUid = SchoolUid
                FROM dbo.t_app_schools
                WHERE SourceRequestUid = @SourceRequestUid AND Is_Deleted = 0;

                SELECT @Status = 1, @Code = 'ALREADY_PROVISIONED',
                       @Message = N'This school was already created for that approval.';
            END
            ELSE
                THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @Id AS Id,
           @SchoolUid AS SchoolUid;
END
GO


/*==============================================================================
  USP_FindOrphanedApprovals — 🔴 THE RECONCILIATION QUERY

  Finds approvals that COMPLETED in jp_mdm but whose school never appeared
  here. That is the exact shape of a partial cross-database failure: the
  approval committed, the user may even have been activated, and then
  provisioning failed — leaving someone who can sign in to an empty shell.

  Without this the failure is invisible. The approval looks done, the admin has
  moved on, and the only person who finds out is the school owner staring at a
  blank screen.

  ---------------------------------------------------------------------------
  WHY IT LIVES IN jp_app AND TAKES A TABLE PARAMETER
  ---------------------------------------------------------------------------
  It cannot join jp_mdm to jp_app — that is the cross-database join decision
  2.2 forbids. So the API reads the completed approvals from jp_mdm, passes
  them in, and this procedure answers which of them have no school.

  Phase 8 turns this into a scheduled check. For now it exists, is documented,
  and can be run by hand the moment something looks wrong.

  Usage from the API: see ApprovalOrchestrationService.FindOrphanedAsync.
==============================================================================*/
IF TYPE_ID(N'dbo.CompletedApprovalList') IS NULL
BEGIN
    PRINT '    Creating table type [CompletedApprovalList] ...';
END
GO

IF TYPE_ID(N'dbo.CompletedApprovalList') IS NULL
    CREATE TYPE dbo.CompletedApprovalList AS TABLE
    (
        RequestUid       uniqueidentifier NOT NULL PRIMARY KEY,
        RequestNo        varchar(30)      NOT NULL,
        OrganizationUid  uniqueidentifier NULL,
        CompletedOn      datetime2        NOT NULL
    );
GO

CREATE OR ALTER PROCEDURE dbo.USP_FindOrphanedApprovals
    @Completed dbo.CompletedApprovalList READONLY
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        c.RequestUid,
        c.RequestNo,
        c.OrganizationUid,
        c.CompletedOn,
        DATEDIFF(HOUR, c.CompletedOn, SYSUTCDATETIME()) AS HoursSinceCompleted
    FROM @Completed c
    WHERE NOT EXISTS (
        SELECT 1 FROM dbo.t_app_schools s
        WHERE s.SourceRequestUid = c.RequestUid AND s.Is_Deleted = 0)
    ORDER BY c.CompletedOn;
END
GO

PRINT '    Provisioning and reconciliation procedures ready.';
GO
