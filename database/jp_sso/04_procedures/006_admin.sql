/*==============================================================================
  jp_sso — 04_procedures / 006_admin.sql

  Administrative actions: status transitions, unlocking, role grants.
==============================================================================*/

USE jp_sso;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  USP_UpdateUserStatus

  The single entry point for every status transition: approve, reject,
  suspend, reactivate, mark for resubmission.

  ---------------------------------------------------------------------------
  Optimistic concurrency
  ---------------------------------------------------------------------------
  @RowVersion must match. Two admins opening the same pending registration and
  clicking Approve and Reject a second apart would otherwise both "succeed",
  and the outcome would be whichever UPDATE landed last. The second one now
  gets a conflict and re-reads.

  ---------------------------------------------------------------------------
  Side effects, by target status
  ---------------------------------------------------------------------------
  2  Active     a school with no roles yet is granted SCHOOL_OWNER — this is
                the moment an approved registration becomes a usable account
                (PROJECT_MEMORY 2.9). Any lockout is closed.
  3  Rejected   every token revoked.
  4  Suspended  every token revoked AND an audit lockout row written. A
                suspended user with a live refresh token is not suspended.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_UpdateUserStatus
    @UserUid        uniqueidentifier,
    @NewStatusId    int,
    @RowVersion     int,
    @ActionByUserId bigint,
    @Remarks        nvarchar(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0,
            @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL,
            @UserId bigint = NULL,
            @CurrentStatusId int = NULL,
            @CurrentRowVersion int = NULL,
            @UserTypeId int = NULL,
            @OrganizationUid uniqueidentifier = NULL,
            @RoleId int = NULL,
            @RevokedCount int = 0,
            @RoleGranted bit = 0,
            @Now datetime2 = SYSUTCDATETIME();

    SELECT @UserId = UserId, @CurrentStatusId = StatusId, @CurrentRowVersion = [RowVersion],
           @UserTypeId = UserTypeId, @OrganizationUid = OrganizationUid
    FROM dbo.t_sso_users
    WHERE UserUid = @UserUid AND Is_Deleted = 0;

    IF @UserId IS NULL
        SELECT @Code = 'NOT_FOUND', @Message = N'That account was not found.';
    ELSE IF NOT EXISTS (SELECT 1 FROM dbo.m_sso_user_status
                        WHERE StatusId = @NewStatusId AND Is_Active = 1 AND Is_Deleted = 0)
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'That status is not recognised.';
    ELSE IF @NewStatusId = 5
        -- Locked is produced by the login path, never set by hand. Admins
        -- suspend (4); the lockout machinery owns 5.
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'Use suspend rather than lock for an administrative action.';
    ELSE IF @CurrentRowVersion <> @RowVersion
        SELECT @Code = 'CONCURRENCY_CONFLICT',
               @Message = N'This account was changed by someone else. Reload and try again.';
    ELSE IF @CurrentStatusId = @NewStatusId
        SELECT @Code = 'BUSINESS_RULE_VIOLATED', @Message = N'The account is already in that state.';

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            UPDATE dbo.t_sso_users
            SET StatusId = @NewStatusId,
                ModifiedOn = @Now,
                ModifiedBy = @ActionByUserId,
                [RowVersion] = [RowVersion] + 1
            WHERE UserId = @UserId AND [RowVersion] = @RowVersion;

            -- Belt and braces: if the row moved between the read and here, the
            -- UPDATE matches nothing and the whole thing rolls back.
            IF @@ROWCOUNT = 0
                THROW 50002, 'The account was modified concurrently.', 1;

            /*
              An administrator has just set the status explicitly, so any lock
              still in force no longer has a status to restore. NULLing
              PreviousStatusId records that as a FACT rather than leaving it to
              be inferred later from timestamps.

              Without this, the sequence
                  Pending -> locked (Previous=1) -> admin rejects (Status=3)
                  -> lock expires -> "restore" to Pending
              silently reverses the rejection.

              Runs BEFORE the suspension branch below, so the new lockout row
              that a suspension writes keeps its own PreviousStatusId.
            */
            UPDATE dbo.t_sso_user_lockouts
            SET PreviousStatusId = NULL,
                ModifiedOn = @Now,
                ModifiedBy = @ActionByUserId
            WHERE UserId = @UserId
              AND Is_Deleted = 0
              AND UnlockedOn IS NULL
              AND PreviousStatusId IS NOT NULL;

            -- ---- becoming Active --------------------------------------------
            IF @NewStatusId = 2
            BEGIN
                UPDATE dbo.t_sso_user_lockouts
                SET UnlockedOn = @Now,
                    UnlockedByUserId = @ActionByUserId,
                    ModifiedOn = @Now
                WHERE UserId = @UserId AND Is_Deleted = 0 AND UnlockedOn IS NULL;

                UPDATE dbo.t_sso_users
                SET FailedAttemptCount = 0
                WHERE UserId = @UserId;

                -- An approved school owner gets their role now. Guarded on
                -- "has no role yet" so re-approving a reactivated account does
                -- not hand SCHOOL_OWNER to someone demoted to HR.
                IF @UserTypeId = 2
                   AND NOT EXISTS (SELECT 1 FROM dbo.t_sso_user_roles
                                   WHERE UserId = @UserId AND Is_Deleted = 0)
                BEGIN
                    SELECT @RoleId = RoleId
                    FROM dbo.t_sso_roles
                    WHERE RoleCode = 'SCHOOL_OWNER' AND OrganizationUid IS NULL
                      AND Is_Deleted = 0 AND Is_Active = 1;

                    IF @RoleId IS NULL
                        THROW 50001, 'Seed data is missing: the global SCHOOL_OWNER role was not found.', 1;

                    INSERT INTO dbo.t_sso_user_roles
                        (UserId, RoleId, OrganizationUid, AssignedByUserId, ValidFrom, CreatedBy)
                    VALUES
                        (@UserId, @RoleId, @OrganizationUid, @ActionByUserId, dbo.fn_IstToday(), @ActionByUserId);

                    SET @RoleGranted = 1;
                END
            END

            -- ---- rejected or suspended --------------------------------------
            IF @NewStatusId IN (3, 4)
            BEGIN
                UPDATE dbo.t_sso_user_tokens
                SET RevokedOn = @Now,
                    ModifiedOn = @Now,
                    ModifiedBy = @ActionByUserId
                WHERE UserId = @UserId AND Is_Deleted = 0 AND RevokedOn IS NULL;

                SET @RevokedCount = @@ROWCOUNT;
            END

            -- Suspension is recorded as a lockout too, so "why can I not sign
            -- in" has one place to look, with the admin and the reason on it.
            IF @NewStatusId = 4
            BEGIN
                INSERT INTO dbo.t_sso_user_lockouts
                    (UserId, LockReasonId, LockedOn, UnlockOn, PreviousStatusId, Remarks, CreatedBy)
                VALUES
                    (@UserId, 2, @Now, NULL, NULLIF(@CurrentStatusId, 5),
                     ISNULL(@Remarks, N'Suspended by an administrator.'), @ActionByUserId);
            END

            COMMIT TRANSACTION;

            SELECT @Status = 1, @Message = N'Account status updated.';
        END TRY
        BEGIN CATCH
            -- CAPTURE -> ROLLBACK -> LOG -> RESPOND (decision 2.31).
            DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                    @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                    @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            -- No secrets here, so everything is logged as-is. The RowVersion is
            -- worth keeping: most failures on this proc are concurrency.
            DECLARE @Params nvarchar(max) = (
                SELECT @UserUid AS userUid, @NewStatusId AS newStatusId,
                       @RowVersion AS rowVersion, @CurrentStatusId AS currentStatusId,
                       @ActionByUserId AS actionByUserId
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
                 @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
                 @ErrorMessage = @ErrMessage, @ParametersJson = @Params,
                 @ContextInfo = N'USP_UpdateUserStatus', @CreatedBy = @ActionByUserId;

            THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @UserId AS Id,
           @RevokedCount AS RevokedTokenCount, @RoleGranted AS RoleGranted;
END
GO


/*==============================================================================
  USP_UnlockUser

  Manual unlock by an administrator, ahead of the automatic expiry.

  Restores the status the account held before it was locked — see script 018
  for why that is not simply "Active".
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_UnlockUser
    @UserUid        uniqueidentifier,
    @ActionByUserId bigint,
    @Remarks        nvarchar(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0,
            @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL,
            @UserId bigint = NULL,
            @CurrentStatusId int = NULL,
            @RestoreStatusId int = NULL,
            @LockCount int = 0,
            @Now datetime2 = SYSUTCDATETIME();

    SELECT @UserId = UserId, @CurrentStatusId = StatusId
    FROM dbo.t_sso_users
    WHERE UserUid = @UserUid AND Is_Deleted = 0;

    IF @UserId IS NULL
        SELECT @Code = 'NOT_FOUND', @Message = N'That account was not found.';
    ELSE IF NOT EXISTS (SELECT 1 FROM dbo.t_sso_user_lockouts
                        WHERE UserId = @UserId AND Is_Deleted = 0 AND UnlockedOn IS NULL)
           AND @CurrentStatusId <> 5
        SELECT @Code = 'BUSINESS_RULE_VIOLATED', @Message = N'That account is not locked.';

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            SELECT TOP (1) @RestoreStatusId = PreviousStatusId
            FROM dbo.t_sso_user_lockouts
            WHERE UserId = @UserId AND Is_Deleted = 0 AND UnlockedOn IS NULL
            ORDER BY LockedOn DESC;

            UPDATE dbo.t_sso_user_lockouts
            SET UnlockedOn = @Now,
                UnlockedByUserId = @ActionByUserId,
                Remarks = ISNULL(@Remarks, Remarks),
                ModifiedOn = @Now,
                ModifiedBy = @ActionByUserId
            WHERE UserId = @UserId AND Is_Deleted = 0 AND UnlockedOn IS NULL;

            SET @LockCount = @@ROWCOUNT;

            -- Only touch the status if the lock is what changed it AND there is
            -- something recorded to restore. No fallback to Active — see the
            -- note in USP_RecordLoginAttempt.
            UPDATE dbo.t_sso_users
            SET StatusId = CASE WHEN @CurrentStatusId = 5 AND @RestoreStatusId IS NOT NULL
                                THEN @RestoreStatusId ELSE StatusId END,
                FailedAttemptCount = 0,
                ModifiedOn = @Now,
                ModifiedBy = @ActionByUserId,
                [RowVersion] = [RowVersion] + 1
            WHERE UserId = @UserId;

            COMMIT TRANSACTION;

            SELECT @Status = 1, @Message = N'Account unlocked.';
        END TRY
        BEGIN CATCH
            -- CAPTURE -> ROLLBACK -> LOG -> RESPOND (decision 2.31).
            DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                    @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                    @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            DECLARE @Params nvarchar(max) = (
                SELECT @UserUid AS userUid, @ActionByUserId AS actionByUserId,
                       @CurrentStatusId AS currentStatusId, @RestoreStatusId AS restoreStatusId
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
                 @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
                 @ErrorMessage = @ErrMessage, @ParametersJson = @Params,
                 @ContextInfo = N'USP_UnlockUser', @CreatedBy = @ActionByUserId;

            THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @UserId AS Id,
           @LockCount AS LockoutsCleared, @RestoreStatusId AS RestoredStatusId;
END
GO


/*==============================================================================
  USP_AssignUserRole

  Grants a role, scoped to an organisation.

  Refuses a role belonging to a different organisation, and refuses one meant
  for a different user type — an HR role cannot be attached to a teacher
  account. Re-granting an existing live role is reported as a business failure
  rather than silently inserting a duplicate the unique index would reject.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_AssignUserRole
    @UserUid            uniqueidentifier,
    @RoleCode           varchar(50),
    @OrganizationUid    uniqueidentifier = NULL,
    @AssignedByUserId   bigint,
    @ValidFrom          date = NULL,
    @ValidTo            date = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Status int = 0,
            @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL,
            @UserId bigint = NULL,
            @UserTypeId int = NULL,
            @UserOrganizationUid uniqueidentifier = NULL,
            @RoleId int = NULL,
            @RoleUserTypeId int = NULL,
            @UserRoleId bigint = NULL;

    -- Calendar dates, so today is IST's today (decision 2.28).
    SET @ValidFrom = ISNULL(@ValidFrom, dbo.fn_IstToday());

    SELECT @UserId = UserId, @UserTypeId = UserTypeId, @UserOrganizationUid = OrganizationUid
    FROM dbo.t_sso_users
    WHERE UserUid = @UserUid AND Is_Deleted = 0;

    SELECT @RoleId = RoleId, @RoleUserTypeId = UserTypeId
    FROM dbo.t_sso_roles
    WHERE RoleCode = @RoleCode
      AND (OrganizationUid IS NULL OR OrganizationUid = @OrganizationUid)
      AND Is_Deleted = 0 AND Is_Active = 1;

    IF @UserId IS NULL
        SELECT @Code = 'NOT_FOUND', @Message = N'That account was not found.';
    ELSE IF @RoleId IS NULL
        SELECT @Code = 'NOT_FOUND', @Message = N'That role was not found for this organisation.';
    ELSE IF @RoleUserTypeId <> @UserTypeId
        SELECT @Code = 'BUSINESS_RULE_VIOLATED', @Message = N'That role cannot be granted to this kind of account.';
    ELSE IF @OrganizationUid IS NOT NULL AND @UserOrganizationUid IS NOT NULL
            AND @OrganizationUid <> @UserOrganizationUid
        SELECT @Code = 'FORBIDDEN', @Message = N'That user belongs to a different organisation.';
    ELSE IF @ValidTo IS NOT NULL AND @ValidTo < @ValidFrom
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The end date cannot be before the start date.';
    ELSE IF EXISTS (SELECT 1 FROM dbo.t_sso_user_roles
                    WHERE UserId = @UserId AND RoleId = @RoleId
                      AND ((OrganizationUid IS NULL AND @OrganizationUid IS NULL)
                           OR OrganizationUid = @OrganizationUid)
                      AND Is_Deleted = 0)
        SELECT @Code = 'DUPLICATE_RECORD', @Message = N'That role is already assigned.';

    IF @Code IS NULL
    BEGIN
        INSERT INTO dbo.t_sso_user_roles
            (UserId, RoleId, OrganizationUid, AssignedByUserId, ValidFrom, ValidTo, CreatedBy)
        VALUES
            (@UserId, @RoleId, @OrganizationUid, @AssignedByUserId, @ValidFrom, @ValidTo, @AssignedByUserId);

        SELECT @UserRoleId = SCOPE_IDENTITY(), @Status = 1, @Message = N'Role assigned.';
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @UserRoleId AS Id;
END
GO


/*==============================================================================
  USP_RemoveUserRole

  Soft-removes a role grant. Never a DELETE — who held what, and when, is
  exactly the kind of question an audit asks.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_RemoveUserRole
    @UserUid            uniqueidentifier,
    @RoleCode           varchar(50),
    @OrganizationUid    uniqueidentifier = NULL,
    @RemovedByUserId    bigint
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Status int = 0,
            @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL,
            @UserId bigint = NULL,
            @RoleId int = NULL,
            @RemovedCount int = 0,
            @Now datetime2 = SYSUTCDATETIME();

    SELECT @UserId = UserId FROM dbo.t_sso_users WHERE UserUid = @UserUid AND Is_Deleted = 0;

    SELECT @RoleId = RoleId
    FROM dbo.t_sso_roles
    WHERE RoleCode = @RoleCode
      AND (OrganizationUid IS NULL OR OrganizationUid = @OrganizationUid)
      AND Is_Deleted = 0;

    IF @UserId IS NULL
        SELECT @Code = 'NOT_FOUND', @Message = N'That account was not found.';
    ELSE IF @RoleId IS NULL
        SELECT @Code = 'NOT_FOUND', @Message = N'That role was not found.';

    IF @Code IS NULL
    BEGIN
        UPDATE dbo.t_sso_user_roles
        SET Is_Deleted = 1,
            Is_Active = 0,
            ModifiedOn = @Now,
            ModifiedBy = @RemovedByUserId
        WHERE UserId = @UserId
          AND RoleId = @RoleId
          AND ((OrganizationUid IS NULL AND @OrganizationUid IS NULL)
               OR OrganizationUid = @OrganizationUid)
          AND Is_Deleted = 0;

        SET @RemovedCount = @@ROWCOUNT;

        IF @RemovedCount = 0
            SELECT @Code = 'NOT_FOUND', @Message = N'That role was not assigned to this account.';
        ELSE
            SELECT @Status = 1, @Message = N'Role removed.';
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @UserId AS Id,
           @RemovedCount AS RemovedCount;
END
GO

/*==============================================================================
  USP_CreateSchoolRole

  A school defines a custom role for its own organisation.

  Permissions are chosen from the seeded catalogue — a school composes roles out
  of existing permissions, it never invents one, because a permission code must
  correspond to a check that exists in the application code. An unrecognised
  code is refused outright rather than silently dropped, which would create a
  role that looks right in the UI and quietly grants less than it claims.

  @PermissionCodes is a comma-separated list, split with STRING_SPLIT (2016+).
  No dynamic SQL.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_CreateSchoolRole
    @OrganizationUid    uniqueidentifier,
    @RoleCode           varchar(50),
    @RoleName           nvarchar(100),
    @PermissionCodes    nvarchar(4000),
    @CreatedByUserId    bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0,
            @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL,
            @RoleId int = NULL,
            @GrantedCount int = 0,
            @RequestedCount int = 0,
            @ResolvedCount int = 0,
            @Now datetime2 = SYSUTCDATETIME();

    SET @RoleCode = UPPER(LTRIM(RTRIM(ISNULL(@RoleCode, ''))));
    SET @RoleName = LTRIM(RTRIM(ISNULL(@RoleName, N'')));

    DECLARE @Requested TABLE (PermissionCode varchar(50) PRIMARY KEY);

    INSERT INTO @Requested (PermissionCode)
    SELECT DISTINCT LTRIM(RTRIM(value))
    FROM STRING_SPLIT(ISNULL(@PermissionCodes, N''), ',')
    WHERE LTRIM(RTRIM(value)) <> '';

    SELECT @RequestedCount = COUNT(*) FROM @Requested;

    SELECT @ResolvedCount = COUNT(*)
    FROM @Requested r
    INNER JOIN dbo.t_sso_permissions p
            ON p.PermissionCode = r.PermissionCode AND p.Is_Deleted = 0 AND p.Is_Active = 1;

    IF @OrganizationUid IS NULL
        SELECT @Code = 'FORBIDDEN', @Message = N'This account is not linked to an organisation.';
    ELSE IF @RoleCode = ''
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'A role code is required.';
    ELSE IF @RoleName = N''
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'A role name is required.';
    ELSE IF @RequestedCount = 0
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'Select at least one permission for this role.';
    ELSE IF @ResolvedCount <> @RequestedCount
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'One or more of those permissions is not recognised.';
    -- A school must not shadow a seeded role code.
    ELSE IF EXISTS (SELECT 1 FROM dbo.t_sso_roles
                    WHERE RoleCode = @RoleCode AND OrganizationUid IS NULL AND Is_Deleted = 0)
        SELECT @Code = 'DUPLICATE_RECORD', @Message = N'That code is reserved by a built-in role.';
    ELSE IF EXISTS (SELECT 1 FROM dbo.t_sso_roles
                    WHERE RoleCode = @RoleCode AND OrganizationUid = @OrganizationUid AND Is_Deleted = 0)
        SELECT @Code = 'DUPLICATE_RECORD', @Message = N'Your organisation already has a role with that code.';

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            -- UserTypeId 2: a custom role always belongs to school users.
            INSERT INTO dbo.t_sso_roles
                (RoleCode, RoleName, UserTypeId, IsSystemRole, OrganizationUid, CreatedBy)
            VALUES
                (@RoleCode, @RoleName, 2, 0, @OrganizationUid, @CreatedByUserId);

            SET @RoleId = SCOPE_IDENTITY();

            INSERT INTO dbo.t_sso_role_permissions (RoleId, PermissionId, CreatedBy)
            SELECT @RoleId, p.PermissionId, @CreatedByUserId
            FROM @Requested r
            INNER JOIN dbo.t_sso_permissions p
                    ON p.PermissionCode = r.PermissionCode AND p.Is_Deleted = 0 AND p.Is_Active = 1;

            SET @GrantedCount = @@ROWCOUNT;

            COMMIT TRANSACTION;

            SELECT @Status = 1, @Message = N'Role created.';
        END TRY
        BEGIN CATCH
            -- CAPTURE -> ROLLBACK -> LOG -> RESPOND (decision 2.31).
            DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                    @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                    @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            DECLARE @Params nvarchar(max) = (
                SELECT @OrganizationUid AS organizationUid, @RoleCode AS roleCode,
                       @RoleName AS roleName, @PermissionCodes AS permissionCodes
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
                 @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
                 @ErrorMessage = @ErrMessage, @ParametersJson = @Params,
                 @ContextInfo = N'USP_CreateSchoolRole', @CreatedBy = @CreatedByUserId;

            THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @RoleId AS Id,
           @GrantedCount AS GrantedCount;
END
GO

PRINT '    Admin procedures ready.';
GO
