/*==============================================================================
  jp_app — 04_procedures / 004_school_profile.sql

  USP_GetSchoolProfile         the school's own view
  USP_GetSchoolPublicProfile   what a teacher sees — a SEPARATE procedure
  USP_UpdateSchoolProfile      RowVersion checked
  USP_SaveSchoolLogo
  USP_SaveSchoolPhotos         add, reorder, soft-delete
  USP_SaveSchoolFacilities     🔴 the bridge-sync pattern 3D follows

  Every procedure that touches one school takes @UserUid and checks membership
  through dbo.fn_IsSchoolMember. None of them take an organisation or a role
  from the caller — the API passes the Uid off the token (2.39) and this layer
  decides what it means.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  USP_GetSchoolProfile — the school's own view.

  Four result sets: the school, its branches, its photos, its facilities.
  Read procedure, so no transaction and no CATCH (Block B of the template).
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetSchoolProfile
    @SchoolId   bigint,
    @UserUid    uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;

    -- Not a member? Nothing at all, and deliberately not an error: the caller
    -- learns the same thing from a school that does not exist and one that is
    -- not theirs.
    IF dbo.fn_IsSchoolMember(@SchoolId, @UserUid) = 0
    BEGIN
        SELECT TOP (0) CAST(NULL AS bigint) AS SchoolId;
        SELECT TOP (0) CAST(NULL AS bigint) AS BranchId;
        SELECT TOP (0) CAST(NULL AS bigint) AS PhotoId;
        SELECT TOP (0) CAST(NULL AS int)    AS FacilityId;
        RETURN;
    END

    -- ---- 1. the school --------------------------------------------------
    SELECT
        s.SchoolId, s.SchoolUid, s.OrganizationUid,
        s.SchoolName, s.SchoolTypeId, s.BoardId,
        s.AffiliationNumber, s.RegistrationNo, s.PanNumber,
        s.LogoPath, s.GroupType, s.EstablishedYear, s.AboutSchool, s.Website,
        s.ContactEmail, s.ContactMobile,
        s.PrincipalName, s.HrContactName, s.HrContactMobile,
        s.AddressLine1, s.AddressLine2, s.CityId, s.DistrictId, s.StateId, s.Pincode,
        s.IsVerified, s.VerifiedOn,
        s.IsSuspended, s.SuspendedOn, s.SuspensionReason,
        s.RowVersion,
        (SELECT COUNT(*) FROM dbo.t_app_school_branches b
         WHERE b.SchoolId = s.SchoolId AND b.Is_Deleted = 0) AS BranchCount
    FROM dbo.t_app_schools s
    WHERE s.SchoolId = @SchoolId AND s.Is_Deleted = 0;

    -- ---- 2. branches, SCOPE-RESOLVED -------------------------------------
    -- 🔴 Even on the school's own profile. A branch HR opening the profile
    -- sees their campuses, not all of them.
    SELECT
        b.BranchId, b.BranchUid, b.BranchName, b.BranchCode, b.IsHeadOffice,
        b.AddressLine1, b.AddressLine2, b.CityId, b.DistrictId, b.StateId, b.Pincode,
        b.Latitude, b.Longitude, b.ContactPerson, b.ContactEmail, b.ContactMobile,
        b.Is_Active, b.RowVersion
    FROM dbo.t_app_school_branches b
        INNER JOIN dbo.fn_VisibleBranches(@SchoolId, @UserUid) v ON v.BranchId = b.BranchId
    WHERE b.Is_Deleted = 0
    ORDER BY b.IsHeadOffice DESC, b.BranchName;

    -- ---- 3. photos --------------------------------------------------------
    SELECT p.PhotoId, p.SchoolId, p.BranchId, p.FilePath, p.Caption, p.DisplayOrder
    FROM dbo.t_app_school_photos p
    WHERE p.SchoolId = @SchoolId AND p.Is_Deleted = 0
    ORDER BY p.DisplayOrder, p.PhotoId;

    -- ---- 4. facilities ----------------------------------------------------
    SELECT f.Id, f.SchoolId, f.BranchId, f.FacilityId
    FROM dbo.t_app_school_facilities f
    WHERE f.SchoolId = @SchoolId AND f.Is_Deleted = 0;
END
GO


/*==============================================================================
  USP_GetSchoolPublicProfile — what a TEACHER sees.

  ---------------------------------------------------------------------------
  🔴 A SEPARATE PROCEDURE, NOT A FLAG ON THE ONE ABOVE
  ---------------------------------------------------------------------------
  The obvious design is one procedure with @IsPublic and a CASE per sensitive
  column. It is one forgotten column away from a leak, and the forgetting
  happens later — when somebody adds a column to the own-view SELECT and does
  not think about the flag, because the flag is forty lines further up.

  Two procedures cannot drift that way. Adding a column here is a deliberate act
  of publishing it.

  NOT RETURNED, and each for a reason:
    PanNumber          a tax identifier. No teacher has any use for it.
    OrganizationUid    an internal key; exposing it invites enumeration.
    SuspensionReason   an administrative note about the school, written for us.
    IsSuspended        ⚠️ not hidden — ENFORCED. A suspended school returns
                       nothing at all, rather than returning a profile with a
                       flag the caller is trusted to honour.
    RowVersion         concurrency plumbing for an editor. There is no editor.
    Internal contacts  HrContactMobile and the rest are for our admins, not for
                       a teacher who has not applied yet.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetSchoolPublicProfile
    @SchoolUid  uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @SchoolId bigint;

    /*
      🔴 Looked up by Uid, not by id. A public URL carries the Uid (2.51), and
      a sequential id in a public route is an invitation to walk the range.

      Suspended and unverified schools resolve to nothing here — the filter is
      on the lookup, so every result set below is empty rather than each one
      having to remember.
    */
    SELECT @SchoolId = s.SchoolId
    FROM dbo.t_app_schools s
    WHERE s.SchoolUid    = @SchoolUid
      AND s.Is_Deleted   = 0
      AND s.Is_Active    = 1
      AND s.IsSuspended  = 0
      AND s.IsVerified   = 1;      -- an unverified school is not public yet

    -- ---- 1. the school, public columns only ------------------------------
    SELECT
        s.SchoolUid, s.SchoolName, s.SchoolTypeId, s.BoardId,
        s.LogoPath, s.EstablishedYear, s.AboutSchool, s.Website,
        s.AddressLine1, s.AddressLine2, s.CityId, s.DistrictId, s.StateId, s.Pincode,
        s.IsVerified
    FROM dbo.t_app_schools s
    WHERE s.SchoolId = @SchoolId;

    -- ---- 2. branches, public columns only --------------------------------
    -- No scope resolver: this is the public view and there is no member to
    -- resolve against. Inactive campuses are excluded instead.
    SELECT
        b.BranchUid, b.BranchName,
        b.AddressLine1, b.AddressLine2, b.CityId, b.DistrictId, b.StateId, b.Pincode,
        b.Latitude, b.Longitude
    FROM dbo.t_app_school_branches b
    WHERE b.SchoolId = @SchoolId AND b.Is_Deleted = 0 AND b.Is_Active = 1
    ORDER BY b.IsHeadOffice DESC, b.BranchName;

    -- ---- 3. photos --------------------------------------------------------
    SELECT p.FilePath, p.Caption, p.DisplayOrder
    FROM dbo.t_app_school_photos p
    WHERE p.SchoolId = @SchoolId AND p.Is_Deleted = 0 AND p.Is_Active = 1
    ORDER BY p.DisplayOrder, p.PhotoId;

    -- ---- 4. facilities ----------------------------------------------------
    SELECT DISTINCT f.FacilityId
    FROM dbo.t_app_school_facilities f
    WHERE f.SchoolId = @SchoolId AND f.Is_Deleted = 0;
END
GO


/*==============================================================================
  USP_UpdateSchoolProfile

  ⚠️ RowVersion is re-checked INSIDE the UPDATE's WHERE clause, not only in
  validation. Checking it in validation alone leaves a window between the read
  and the write in which the other writer commits — the exact bug 2.46 records
  and 2C's suite reaches through a two-level fixture.

  The name, the verification flags and the suspension flags are NOT updatable
  here. A school renaming itself changes what was verified; suspension is an
  admin decision. Both belong to procedures an admin calls.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_UpdateSchoolProfile
    @SchoolId           bigint,
    @UserUid            uniqueidentifier,
    @RowVersion         int,
    @SchoolTypeId       int            = NULL,
    @BoardId            int            = NULL,
    @AffiliationNumber  varchar(50)    = NULL,
    @RegistrationNo     varchar(50)    = NULL,
    @PanNumber          varchar(10)    = NULL,
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
    @ActionByUserId     bigint         = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL, @Id bigint = @SchoolId,
            @Now datetime2 = SYSUTCDATETIME();

    DECLARE @CurrentRowVersion int = NULL, @IsSuspended tinyint = NULL;

    SELECT @CurrentRowVersion = s.RowVersion, @IsSuspended = s.IsSuspended
    FROM dbo.t_app_schools s
    WHERE s.SchoolId = @SchoolId AND s.Is_Deleted = 0;

    IF @CurrentRowVersion IS NULL
        SELECT @Code = 'NOT_FOUND', @Message = N'That school was not found.';
    ELSE IF dbo.fn_IsSchoolMember(@SchoolId, @UserUid) = 0
        -- Same message as a missing school. Confirming that a school exists but
        -- is not yours is itself a small disclosure.
        SELECT @Code = 'NOT_FOUND', @Message = N'That school was not found.';
    ELSE IF @IsSuspended = 1
        SELECT @Code = 'BUSINESS_RULE_VIOLATED',
               @Message = N'This school is suspended and cannot be edited.';
    ELSE IF @CurrentRowVersion <> @RowVersion
        SELECT @Code = 'CONCURRENCY_CONFLICT',
               @Message = N'Somebody else changed this school while you were editing it. Reload and try again.';

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            UPDATE dbo.t_app_schools
               SET SchoolTypeId      = @SchoolTypeId,
                   BoardId           = @BoardId,
                   AffiliationNumber = @AffiliationNumber,
                   RegistrationNo    = @RegistrationNo,
                   PanNumber         = @PanNumber,
                   GroupType         = @GroupType,
                   EstablishedYear   = @EstablishedYear,
                   AboutSchool       = @AboutSchool,
                   Website           = @Website,
                   ContactEmail      = @ContactEmail,
                   ContactMobile     = @ContactMobile,
                   PrincipalName     = @PrincipalName,
                   HrContactName     = @HrContactName,
                   HrContactMobile   = @HrContactMobile,
                   AddressLine1      = @AddressLine1,
                   AddressLine2      = @AddressLine2,
                   CityId            = @CityId,
                   DistrictId        = @DistrictId,
                   StateId           = @StateId,
                   Pincode           = @Pincode,
                   RowVersion        = RowVersion + 1,
                   ModifiedOn        = @Now,
                   ModifiedBy        = @ActionByUserId
             WHERE SchoolId    = @SchoolId
               AND Is_Deleted  = 0
               AND RowVersion  = @RowVersion;   -- 🔴 re-checked HERE

            IF @@ROWCOUNT = 0
                SELECT @Code = 'CONCURRENCY_CONFLICT',
                       @Message = N'Somebody else changed this school while you were editing it. Reload and try again.';
            ELSE
                SELECT @Status = 1, @Message = N'School profile updated.';
        END TRY
        BEGIN CATCH
            DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                    @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                    @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            DECLARE @Params nvarchar(max) = (
                SELECT @SchoolId AS schoolId, @RowVersion AS rowVersion
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
                 @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
                 @ErrorMessage = @ErrMessage, @ParametersJson = @Params,
                 @ContextInfo = N'USP_UpdateSchoolProfile', @CreatedBy = @ActionByUserId;

            THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @Id AS Id;
END
GO


/*==============================================================================
  USP_SaveSchoolLogo

  ⚠️ No RowVersion. A logo upload is not an edit of the form somebody else might
  have open — it is its own action, and making it fail because a colleague saved
  the address a minute ago would be a rule nobody could explain.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SaveSchoolLogo
    @SchoolId       bigint,
    @UserUid        uniqueidentifier,
    @LogoPath       nvarchar(500),
    @ActionByUserId bigint = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL, @Id bigint = @SchoolId;

    IF NOT EXISTS (SELECT 1 FROM dbo.t_app_schools WHERE SchoolId = @SchoolId AND Is_Deleted = 0)
        SELECT @Code = 'NOT_FOUND', @Message = N'That school was not found.';
    ELSE IF dbo.fn_IsSchoolMember(@SchoolId, @UserUid) = 0
        SELECT @Code = 'NOT_FOUND', @Message = N'That school was not found.';
    ELSE IF ISNULL(@LogoPath, N'') = N''
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The logo file is required.';

    IF @Code IS NULL
    BEGIN
        UPDATE dbo.t_app_schools
           SET LogoPath   = @LogoPath,
               ModifiedOn = SYSUTCDATETIME(),
               ModifiedBy = @ActionByUserId
         WHERE SchoolId = @SchoolId AND Is_Deleted = 0;

        SELECT @Status = 1, @Message = N'Logo updated.';
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @Id AS Id;
END
GO
