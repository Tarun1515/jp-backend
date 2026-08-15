/*==============================================================================
  jp_app — 04_procedures / 006_branches.sql

  USP_GetBranchList   scope-resolved
  USP_GetBranchById   scope-checked
  USP_SaveBranch      insert and update, RowVersion on update
  USP_DeleteBranch    soft delete, with the refusals spelled out

  Every one of these resolves visibility through dbo.fn_VisibleBranches. None
  reimplements the rule (2.53).

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  USP_GetBranchList

  Optional filters use (@P IS NULL OR Col = @P) with OPTION (RECOMPILE), which
  belongs on list procedures only (2.30).

  ---------------------------------------------------------------------------
  🔴 `Is_Active AS IsActive` — THE ALIAS IS LOAD-BEARING. DO NOT REMOVE IT.
  ---------------------------------------------------------------------------
  Dapper matches a column to a property by name, and it does NOT strip
  underscores unless DefaultTypeMap.MatchNamesWithUnderscores is turned on —
  which this solution deliberately leaves off, because a global name-mangling
  rule changes every mapping in the system at once.

  So `Is_Active` did not reach `BranchDto.IsActive` at all, and every branch the
  API returned said isActive: false while the row said 1. It shipped in 3E and
  was invisible for two phases because nothing rendered it; 3F put a status
  badge on the screen and every campus read "Closed".

  ⚠️ The standard columns are the ONLY ones with underscores in this schema
  (2.4), so this is the whole class of bug — anywhere one of them is returned to
  a DTO, it needs the alias.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetBranchList
    @SchoolId       bigint,
    @UserUid        uniqueidentifier,
    @Search         nvarchar(150) = NULL,
    @StateId        int           = NULL,
    @IncludeInactive bit          = 0
AS
BEGIN
    SET NOCOUNT ON;

    -- Escape the LIKE wildcards, so a search for "50%" is a literal search and
    -- not a match against everything.
    DECLARE @SearchPattern nvarchar(160) = CASE
        WHEN NULLIF(LTRIM(RTRIM(@Search)), N'') IS NULL THEN NULL
        ELSE N'%' + REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(@Search)), N'[', N'[[]'), N'%', N'[%]'), N'_', N'[_]') + N'%'
    END;

    SELECT
        b.BranchId, b.BranchUid, b.SchoolId,
        b.BranchName, b.BranchCode, b.IsHeadOffice,
        b.AddressLine1, b.AddressLine2, b.CityId, b.DistrictId, b.StateId, b.Pincode,
        b.Latitude, b.Longitude,
        b.ContactPerson, b.ContactEmail, b.ContactMobile,
        b.Is_Active AS IsActive, b.RowVersion, b.CreatedOn
    FROM dbo.t_app_school_branches b
        -- 🔴 THE SCOPE GATE. An INNER JOIN rather than an EXISTS on purpose:
        -- it is impossible to write this query and forget the filter, because
        -- removing the join removes the table the query reads from.
        INNER JOIN dbo.fn_VisibleBranches(@SchoolId, @UserUid) v ON v.BranchId = b.BranchId
    WHERE b.Is_Deleted = 0
      AND (@IncludeInactive = 1 OR b.Is_Active = 1)
      AND (@StateId IS NULL OR b.StateId = @StateId)
      AND (@SearchPattern IS NULL
           OR b.BranchName LIKE @SearchPattern
           OR b.BranchCode LIKE @SearchPattern)
    ORDER BY b.IsHeadOffice DESC, b.BranchName
    OPTION (RECOMPILE);
END
GO


/*==============================================================================
  USP_GetBranchById

  Returns nothing rather than an error when the branch is out of scope — the
  caller learns the same thing from a branch that does not exist and one that
  is not theirs.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetBranchById
    @BranchId   bigint,
    @UserUid    uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @SchoolId bigint =
        (SELECT SchoolId FROM dbo.t_app_school_branches
         WHERE BranchId = @BranchId AND Is_Deleted = 0);

    SELECT
        b.BranchId, b.BranchUid, b.SchoolId,
        b.BranchName, b.BranchCode, b.IsHeadOffice,
        b.AddressLine1, b.AddressLine2, b.CityId, b.DistrictId, b.StateId, b.Pincode,
        b.Latitude, b.Longitude,
        b.ContactPerson, b.ContactEmail, b.ContactMobile,
        b.Is_Active AS IsActive, b.RowVersion
    FROM dbo.t_app_school_branches b
        INNER JOIN dbo.fn_VisibleBranches(@SchoolId, @UserUid) v ON v.BranchId = b.BranchId
    WHERE b.BranchId = @BranchId AND b.Is_Deleted = 0;
END
GO


/*==============================================================================
  USP_SaveBranch — insert when @BranchId is NULL, update otherwise.

  ⚠️ IsHeadOffice is NOT a parameter. Moving the head office is a different
  operation with its own consequences — the school's own address follows it —
  and letting an ordinary save flip the flag would collide with
  UQ_t_app_school_branches_OneHeadOffice in a way the caller could not predict.
  It stays where provisioning put it until a procedure exists that means to move
  it.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SaveBranch
    @SchoolId       bigint,
    @UserUid        uniqueidentifier,
    @BranchId       bigint         = NULL,     -- NULL = insert
    @RowVersion     int            = NULL,     -- required on update
    @BranchName     nvarchar(200),
    @BranchCode     varchar(30)    = NULL,
    @AddressLine1   nvarchar(250)  = NULL,
    @AddressLine2   nvarchar(250)  = NULL,
    @CityId         int            = NULL,
    @DistrictId     int            = NULL,
    @StateId        int            = NULL,
    @Pincode        varchar(10)    = NULL,
    @Latitude       decimal(9, 6)  = NULL,
    @Longitude      decimal(9, 6)  = NULL,
    @ContactPerson  nvarchar(150)  = NULL,
    @ContactEmail   nvarchar(150)  = NULL,
    @ContactMobile  varchar(15)    = NULL,
    @IsActive       tinyint        = 1,
    @ActionByUserId bigint         = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL, @Id bigint = @BranchId,
            @BranchUid uniqueidentifier = NULL,
            @Now datetime2 = SYSUTCDATETIME();

    DECLARE @CurrentRowVersion int = NULL;

    IF NOT EXISTS (SELECT 1 FROM dbo.t_app_schools WHERE SchoolId = @SchoolId AND Is_Deleted = 0)
        SELECT @Code = 'NOT_FOUND', @Message = N'That school was not found.';
    ELSE IF dbo.fn_IsSchoolMember(@SchoolId, @UserUid) = 0
        SELECT @Code = 'NOT_FOUND', @Message = N'That school was not found.';
    ELSE IF ISNULL(@BranchName, N'') = N''
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The campus needs a name.';

    /*
      🔴 An UPDATE has to pass the scope gate, not just the membership check.

      A branch HR at campus A must not be able to edit campus B by sending its
      id. Membership alone would let them — they are a member of the school.
    */
    ELSE IF @BranchId IS NOT NULL
    BEGIN
        SELECT @CurrentRowVersion = b.RowVersion
        FROM dbo.t_app_school_branches b
            INNER JOIN dbo.fn_VisibleBranches(@SchoolId, @UserUid) v ON v.BranchId = b.BranchId
        WHERE b.BranchId = @BranchId AND b.SchoolId = @SchoolId AND b.Is_Deleted = 0;

        IF @CurrentRowVersion IS NULL
            SELECT @Code = 'NOT_FOUND', @Message = N'That branch was not found.';
        ELSE IF @RowVersion IS NULL
            SELECT @Code = 'VALIDATION_FAILED',
                   @Message = N'The version is required when updating a branch.';
        ELSE IF @CurrentRowVersion <> @RowVersion
            SELECT @Code = 'CONCURRENCY_CONFLICT',
                   @Message = N'Somebody else changed this campus while you were editing it. Reload and try again.';
    END

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            IF @BranchId IS NULL
            BEGIN
                INSERT INTO dbo.t_app_school_branches
                    (SchoolId, BranchName, BranchCode, IsHeadOffice,
                     AddressLine1, AddressLine2, CityId, DistrictId, StateId, Pincode,
                     Latitude, Longitude, ContactPerson, ContactEmail, ContactMobile,
                     Is_Active, CreatedBy)
                VALUES
                    (@SchoolId, @BranchName, @BranchCode, 0,     -- never the head office
                     @AddressLine1, @AddressLine2, @CityId, @DistrictId, @StateId, @Pincode,
                     @Latitude, @Longitude, @ContactPerson, @ContactEmail, @ContactMobile,
                     ISNULL(@IsActive, 1), @ActionByUserId);

                SET @Id = SCOPE_IDENTITY();
                SELECT @BranchUid = BranchUid FROM dbo.t_app_school_branches WHERE BranchId = @Id;

                /*
                  ⚠️ A NEW BRANCH IS INVISIBLE TO NON-OWNERS UNTIL IT IS LINKED.

                  fn_VisibleBranches gives a non-owner only what
                  t_app_school_user_branches lists, so a branch HR who creates a
                  campus cannot then see it. Linking the creator here would be
                  wrong for an owner (owners are never enumerated, 2.51), so the
                  link is the caller's job when it grants somebody access.

                  Stated rather than fixed silently, because the symptom — "I
                  made a campus and it vanished" — reads as a save failure.
                */

                SELECT @Status = 1, @Message = N'Campus added.';
            END
            ELSE
            BEGIN
                UPDATE dbo.t_app_school_branches
                   SET BranchName    = @BranchName,
                       BranchCode    = @BranchCode,
                       AddressLine1  = @AddressLine1,
                       AddressLine2  = @AddressLine2,
                       CityId        = @CityId,
                       DistrictId    = @DistrictId,
                       StateId       = @StateId,
                       Pincode       = @Pincode,
                       Latitude      = @Latitude,
                       Longitude     = @Longitude,
                       ContactPerson = @ContactPerson,
                       ContactEmail  = @ContactEmail,
                       ContactMobile = @ContactMobile,
                       Is_Active     = ISNULL(@IsActive, Is_Active),
                       RowVersion    = RowVersion + 1,
                       ModifiedOn    = @Now,
                       ModifiedBy    = @ActionByUserId
                 WHERE BranchId   = @BranchId
                   AND SchoolId   = @SchoolId
                   AND Is_Deleted = 0
                   AND RowVersion = @RowVersion;   -- 🔴 re-checked HERE, not only above

                IF @@ROWCOUNT = 0
                    SELECT @Code = 'CONCURRENCY_CONFLICT',
                           @Message = N'Somebody else changed this campus while you were editing it. Reload and try again.';
                ELSE
                BEGIN
                    SELECT @BranchUid = BranchUid FROM dbo.t_app_school_branches WHERE BranchId = @BranchId;
                    SELECT @Status = 1, @Message = N'Campus updated.';
                END
            END
        END TRY
        BEGIN CATCH
            DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                    @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                    @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            DECLARE @Params nvarchar(max) = (
                SELECT @SchoolId AS schoolId, @BranchId AS branchId, @BranchName AS branchName
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
                 @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
                 @ErrorMessage = @ErrMessage, @ParametersJson = @Params,
                 @ContextInfo = N'USP_SaveBranch', @CreatedBy = @ActionByUserId;

            THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @Id AS Id,
           @BranchUid AS BranchUid;
END
GO


/*==============================================================================
  USP_DeleteBranch — soft delete, and the three reasons it refuses.

  ---------------------------------------------------------------------------
  🔴 "CANNOT DELETE, AND HERE IS WHY" IS PART OF THE CONTRACT
  ---------------------------------------------------------------------------
  Each refusal returns its own Code and a message written for the person on the
  screen. A single "cannot delete" would leave the UI to guess, and it would
  guess wrong for at least one of these.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_DeleteBranch
    @BranchId       bigint,
    @SchoolId       bigint,
    @UserUid        uniqueidentifier,
    @RowVersion     int,
    @ActionByUserId bigint = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL, @Id bigint = @BranchId,
            @Now datetime2 = SYSUTCDATETIME();

    DECLARE @IsHeadOffice tinyint = NULL, @CurrentRowVersion int = NULL;

    -- Scope-gated read: a branch outside the caller's scope is "not found",
    -- exactly as it is for the list.
    SELECT @IsHeadOffice = b.IsHeadOffice, @CurrentRowVersion = b.RowVersion
    FROM dbo.t_app_school_branches b
        INNER JOIN dbo.fn_VisibleBranches(@SchoolId, @UserUid) v ON v.BranchId = b.BranchId
    WHERE b.BranchId = @BranchId AND b.SchoolId = @SchoolId AND b.Is_Deleted = 0;

    IF @CurrentRowVersion IS NULL
        SELECT @Code = 'NOT_FOUND', @Message = N'That campus was not found.';

    /*
      🔴 REFUSAL 1 — the head office.

      Every school must always have at least one branch. That is the invariant
      Phases 4 and 5 are built on: a job is posted at a branch, so a school with
      none is a school that cannot be used, and every downstream query would
      need a nullable-branch path (2.51).

      UQ_t_app_school_branches_OneHeadOffice enforces "at most one"; this
      enforces "at least one". Neither is sufficient alone.
    */
    ELSE IF @IsHeadOffice = 1
        SELECT @Code = 'BUSINESS_RULE_VIOLATED',
               @Message = N'This is the head office and cannot be removed. Every school keeps at least one campus. '
                        + N'To move the head office, add the new campus first and then contact us.';

    ELSE IF @CurrentRowVersion <> @RowVersion
        SELECT @Code = 'CONCURRENCY_CONFLICT',
               @Message = N'Somebody else changed this campus while you were looking at it. Reload and try again.';

    /*
      🔴 REFUSAL 2 — jobs and applications attached to this branch.

      ⚠️ WRITTEN NOW, DELIBERATELY UNREACHABLE. t_app_jobs and
      t_app_applications arrive in Phases 4 and 5. The rule is not "delete it
      and let the FK complain" — the FK would fire long after the school has
      been told the campus is gone, and the message would be a constraint name.

      When those tables land, replace the block below with:

          ELSE IF EXISTS (SELECT 1 FROM dbo.t_app_jobs j
                          WHERE j.BranchId = @BranchId AND j.Is_Deleted = 0)
              SELECT @Code = 'BUSINESS_RULE_VIOLATED',
                     @Message = N'This campus has jobs posted against it. Close them first.';

          ELSE IF EXISTS (SELECT 1 FROM dbo.t_app_applications a
                          WHERE a.BranchId = @BranchId AND a.Is_Deleted = 0)
              SELECT @Code = 'BUSINESS_RULE_VIOLATED',
                     @Message = N'Teachers have applied to jobs at this campus. Their applications stay with it.';

      🔴 Do not soften either into a warning. An application is somebody's
      record of having applied, and it does not stop being that because a school
      reorganised.

      Written here rather than left for later because the person who deletes a
      branch in Phase 4 will not know this rule exists, and by then the symptom
      is a foreign key error on a screen.
    */

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            UPDATE dbo.t_app_school_branches
               SET Is_Deleted = 1,
                   RowVersion = RowVersion + 1,
                   ModifiedOn = @Now,
                   ModifiedBy = @ActionByUserId
             WHERE BranchId   = @BranchId
               AND SchoolId   = @SchoolId
               AND Is_Deleted = 0
               AND RowVersion = @RowVersion;

            IF @@ROWCOUNT = 0
                SELECT @Code = 'CONCURRENCY_CONFLICT',
                       @Message = N'Somebody else changed this campus while you were looking at it. Reload and try again.';
            ELSE
            BEGIN
                /*
                  The links go with it. Leaving them behind would mean somebody
                  scoped only to this campus keeps a membership pointing at a
                  branch that no longer exists — and fn_VisibleBranches joins
                  through the branch, so they would silently see nothing with no
                  indication why.
                */
                UPDATE ub
                   SET ub.Is_Deleted = 1, ub.ModifiedOn = @Now, ub.ModifiedBy = @ActionByUserId
                FROM dbo.t_app_school_user_branches ub
                WHERE ub.BranchId = @BranchId AND ub.Is_Deleted = 0;

                SELECT @Status = 1, @Message = N'Campus removed.';
            END
        END TRY
        BEGIN CATCH
            DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                    @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                    @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            DECLARE @Params2 nvarchar(max) = (
                SELECT @BranchId AS branchId, @SchoolId AS schoolId
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
                 @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
                 @ErrorMessage = @ErrMessage, @ParametersJson = @Params2,
                 @ContextInfo = N'USP_DeleteBranch', @CreatedBy = @ActionByUserId;

            THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @Id AS Id;
END
GO

PRINT '    Branch procedures ready.';
GO
