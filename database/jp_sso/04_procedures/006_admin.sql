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

    /*----------------------------------------------------------------------
      🔴 G46 — AN ADMINISTRATOR MAY NOT ACT ON THEIR OWN ACCOUNT, AND MAY NOT
      REMOVE THE LAST ONE. Phase 8A.

      Neither guard existed. 8-0 found it while building the Accounts screen:
      an administrator could suspend themselves, and if they were the only
      active SUPER_ADMIN the platform was left with nobody who could
      administer it — recoverable only through JP.Tools.SeedAdmin or direct
      SQL, which is to say a deployment.

      The screen stopped offering it on your own row at the time, and said in
      writing that this was a mitigation and not the fix, because hiding a
      button is presentation. This is the fix.

      ⚠️ TWO SEPARATE CONDITIONS, NOT ONE. They fail for different reasons and
      a person needs to be told which:

        self        — you cannot change your own status at all. Not suspend,
                      not reject. An administrator correcting their own
                      account is a conflict of interest even when it is
                      harmless, and the harmless case is not worth the hole.

        last admin  — the LAST active administrator cannot be moved out of
                      ACTIVE by anybody, including another administrator.
                      Counted over ACTIVE admin accounts, not over roles: a
                      SUPER_ADMIN who is already suspended is not holding the
                      door open.

      ⚠️ THE SELF CHECK COMES FIRST, deliberately. A sole administrator
      suspending themselves trips both, and "you cannot change your own
      status" is the more useful of the two sentences — it tells them the
      rule rather than the arithmetic.

      🔴 COUNTED AT DECISION TIME, INSIDE THIS PROCEDURE. A count taken in C#
      and passed in would be a second read that can disagree with the first,
      which is the shape every concurrency bug in this project has had.
    ----------------------------------------------------------------------*/
    ELSE IF @UserId = @ActionByUserId
        SELECT @Code = 'BUSINESS_RULE_VIOLATED',
               @Message = N'You cannot change your own account''s status. Ask another administrator.';

    ELSE IF @NewStatusId <> 2
            AND EXISTS (SELECT 1 FROM dbo.t_sso_users me
                         WHERE me.UserId = @UserId AND me.UserTypeId = 1)
            AND (SELECT COUNT(*) FROM dbo.t_sso_users other
                  WHERE other.UserTypeId = 1
                    AND other.StatusId = 2
                    AND other.Is_Deleted = 0) <= 1
        SELECT @Code = 'BUSINESS_RULE_VIOLATED',
               @Message = N'This is the last active administrator. Make another account an administrator first, or the platform is left with nobody who can administer it.';

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

            /*------------------------------------------------------------------
              🔴 G45 — EVERY TRANSITION, WITH ITS REASON. Phase 8A.

              @Remarks has been a parameter on this procedure since 1B and was
              kept in exactly ONE case: the suspension above, as a lockout row.
              A reactivation's reason and a rejection's reason were accepted,
              validated for length, and discarded — so the product could not
              answer the question a rejected school asks six weeks later, which
              is *on what grounds*.

              ⚠️ UNCONDITIONAL, AND THAT IS THE POINT. No IF around it. The old
              behaviour was an IF, and every status this procedure learns to set
              from now on is recorded without anybody remembering to add a
              branch. The one before it (status 4) stays conditional because a
              LOCKOUT genuinely only applies to a suspension.

              ⚠️ INSIDE THE SAME TRANSACTION as the status change itself. A
              history that can disagree with the row it describes is worse than
              no history: it would be evidence, and it would be wrong. Either
              both land or neither does.

              🔴 FromStatusId IS @CurrentStatusId, PLAINLY — AND THE FIRST VERSION
              OF THIS LINE WAS WRONG. It read NULLIF(@CurrentStatusId, 5),
              copied from the lockout INSERT above, on the assumption that 5
              meant some pre-registration state. 5 is LOCKED. The lockout row
              blanks it for its own reason — PreviousStatusId is what an unlock
              RESTORES, and restoring an account to Locked is not a thing — but
              in a HISTORY, "it was Locked" is exactly the fact worth keeping.
              The copied NULLIF would have recorded every unlock as a change
              from nothing.

              This procedure always reads @CurrentStatusId before deciding, so
              the previous status is always known. NULL stays available on the
              column for rows this procedure does not write — a registration
              arriving at its first status, or a backfill.
            ------------------------------------------------------------------*/
            INSERT INTO dbo.t_sso_user_status_history
                (UserId, FromStatusId, ToStatusId, Reason, ActionByUserId, CreatedOn)
            VALUES
                (@UserId, @CurrentStatusId, @NewStatusId,
                 NULLIF(LTRIM(RTRIM(ISNULL(@Remarks, N''))), N''), @ActionByUserId, @Now);

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

            /*------------------------------------------------------------------
              🔴 G45 ALSO APPLIES HERE, AND THIS IS THE HOLE IT NEARLY LEFT.

              G45 was built around USP_UpdateUserStatus, which is where an
              administrator's status changes go. But THIS procedure moves
              StatusId as well — an unlock restores the status the lock
              displaced — and it wrote no history row. The timeline would have
              shown an account going to Locked and then being Active again with
              nothing in between: a gap exactly where somebody looking for
              "who let them back in" would look.

              Found by asking what else writes t_sso_users.StatusId instead of
              trusting that the status endpoint was the only way in. It was the
              same question that found G46.

              ⚠️ CONDITIONAL, BECAUSE THE UPDATE ABOVE IS CONDITIONAL. Clearing
              a lockout on an account whose status the lock never changed is a
              real and common case (an automatic lock on an ACTIVE account),
              and writing "Active -> Active" would both violate 023's CHECK and
              describe something that did not happen.
            ------------------------------------------------------------------*/
            IF @CurrentStatusId = 5
               AND @RestoreStatusId IS NOT NULL
               AND @RestoreStatusId <> @CurrentStatusId
            BEGIN
                INSERT INTO dbo.t_sso_user_status_history
                    (UserId, FromStatusId, ToStatusId, Reason, ActionByUserId, CreatedOn)
                VALUES
                    (@UserId, @CurrentStatusId, @RestoreStatusId,
                     NULLIF(LTRIM(RTRIM(ISNULL(@Remarks, N''))), N''),
                     @ActionByUserId, @Now);
            END

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

/*==============================================================================
  USP_GetUserStatusHistory

  One account's status history, newest first. G45, phase 8A.

  🔴 WHY A SEPARATE PROCEDURE AND NOT A SECOND RESULT SET ON THE DETAIL READ.
  The Accounts screen shows the history in a panel the administrator opens, and
  most views of a user never open it. Bolting it onto USP_GetUserById would
  make every account page pay for a table nobody looked at, and 2.21's shape is
  one procedure per question.

  ⚠️ THE REASON TEXT IS ADMIN-ONLY. It is written by one administrator about
  somebody's account and may say things that are true and unkind. No
  school-facing or teacher-facing procedure reads this table, and a build guard
  below asserts that — the same shape as 025's reporter-identity guard, for the
  same reason.

  ⚠️ NO PAGING, deliberately, and the bound is real: a status history has as
  many rows as an administrator has pressed a button on that one account —
  single digits for the life of a normal account. @Top exists as a ceiling so a
  pathological row count cannot become a pathological response, not as paging.
==============================================================================*/
IF OBJECT_ID('dbo.USP_GetUserStatusHistory', 'P') IS NOT NULL
    DROP PROCEDURE dbo.USP_GetUserStatusHistory;
GO

CREATE PROCEDURE dbo.USP_GetUserStatusHistory
    @UserUid        uniqueidentifier,
    @Top            int = 50
AS
BEGIN
    SET NOCOUNT ON;

    IF @Top IS NULL OR @Top < 1 OR @Top > 200
        SET @Top = 50;

    DECLARE @UserId bigint = (SELECT UserId FROM dbo.t_sso_users
                               WHERE UserUid = @UserUid AND Is_Deleted = 0);

    IF @UserId IS NULL
    BEGIN
        SELECT 0 AS Status, 'NOT_FOUND' AS Code,
               N'That account does not exist.' AS Message;
        RETURN;
    END

    SELECT 1 AS Status, NULL AS Code, NULL AS Message;

    SELECT TOP (@Top)
           h.StatusHistoryId,
           h.FromStatusId,
           fs.Name              AS FromStatusName,
           h.ToStatusId,
           ts.Name              AS ToStatusName,
           h.Reason,
           h.ActionByUserId,
           /*
             The administrator's email, when the account still exists. The
             table deliberately carries no FK (see 023's header), so this is a
             LEFT JOIN and the screen says "an administrator (account no longer
             exists)" rather than showing a bare number.
           */
           ab.Email             AS ActionByEmail,
           h.CreatedOn
      FROM dbo.t_sso_user_status_history h
      LEFT JOIN dbo.m_sso_user_status fs ON fs.StatusId = h.FromStatusId
      LEFT JOIN dbo.m_sso_user_status ts ON ts.StatusId = h.ToStatusId
      LEFT JOIN dbo.t_sso_users ab       ON ab.UserId  = h.ActionByUserId
     WHERE h.UserId = @UserId
     ORDER BY h.CreatedOn DESC, h.StatusHistoryId DESC;
END
GO


/*==============================================================================
  BUILD GUARDS — G45
==============================================================================*/

/*
  🔴 THE HISTORY IS APPEND-ONLY, SO NO PROCEDURE MAY UPDATE OR DELETE IT.

  023 removes the COLUMNS an edit would be expressed through; this stops the
  application growing a statement that edits what is left.

  ⚠️ WHY NOT sys.dm_sql_referenced_entities.is_updated, WHICH 025 USES. Because
  is_updated is 1 for an INSERT target as well as an UPDATE or DELETE target,
  and this table is written by INSERT on purpose — the dependency metadata
  cannot tell the sanctioned write from the forbidden one. 025's guard works
  there precisely because that procedure must not write AT ALL.

  ⚠️ SO THIS IS A TEXT CHECK, WITH ITS LIMIT NAMED. A text search over
  sys.sql_modules cannot tell code from prose about code — 6.5A learned that
  when a guard naming what it banned matched its own comment. Two things keep
  it honest: it looks for the table name immediately after UPDATE or DELETE
  FROM (prose does not usually read "DELETE FROM dbo.t_sso_user_status_history"
  unless it is talking about this very ban, and the one comment that does is in
  THIS file, which is not a module), and it names the offender rather than just
  failing.

  Proven to fire: adding
      DELETE FROM dbo.t_sso_user_status_history WHERE UserId = @UserId
  to USP_UpdateUserStatus fails this with that procedure named.
*/
DECLARE @mutators nvarchar(1000) = N'';

SELECT @mutators = STRING_AGG(CAST(OBJECT_NAME(m.object_id) AS nvarchar(128)), N', ')
  FROM sys.sql_modules m
 WHERE m.definition LIKE '%UPDATE dbo.t[_]sso[_]user[_]status[_]history%'
    OR m.definition LIKE '%UPDATE t[_]sso[_]user[_]status[_]history%'
    OR m.definition LIKE '%DELETE FROM dbo.t[_]sso[_]user[_]status[_]history%'
    OR m.definition LIKE '%DELETE FROM t[_]sso[_]user[_]status[_]history%'
    OR m.definition LIKE '%TRUNCATE TABLE dbo.t[_]sso[_]user[_]status[_]history%';

IF ISNULL(@mutators, N'') <> N''
BEGIN
    DECLARE @m1 nvarchar(1200) =
        N'006_admin: 🔴 A PROCEDURE EDITS OR DELETES THE STATUS HISTORY: '
        + @mutators
        + N'. That table is the record of who changed whose account and why, and it is append-only (023). If a row is wrong, the correction is another row. If this is a data-retention requirement, it needs a decision in PROJECT_MEMORY first, not a DELETE here.';

    RAISERROR('%s', 16, 1, @m1);
END
GO

/*
  🔒 AND ONLY THE ADMIN READ MAY SEE THE REASON TEXT.

  The reason is one administrator's words about somebody's account. Any OTHER
  procedure that reads this table is a procedure that might be school-facing or
  teacher-facing — the same risk 025 guards for the reporter's identity, and
  the same guard shape, by dependency because reading a table IS recorded
  reliably.

  The allowed list is exactly: the two writers, and the admin read.
  USP_UnlockUser is a writer because an unlock restores the status a lock
  displaced — which is a transition, and was the one G45 nearly missed.

  ⚠️ RESTRICTED TO CODE, AND IT CAUGHT ITSELF FIRST. The first version of this
  guard failed the moment it ran, naming CK_t_sso_user_status_history_Moved
  twice — because sys.sql_expression_dependencies records CHECK constraints as
  referencing entities too, and 023's own constraint references two columns of
  the table it lives on. A guard whose first run is a false positive teaches
  the next person to add names to the allowed list until it goes quiet, which
  is how an allow-list stops meaning anything. So the join to sys.objects is
  load bearing: only procedures, functions and views can be consumers in the
  sense this guard is about.

  Proven to fire: a probe procedure selecting Reason from this table fails
  this, and is named in the message.
*/
DECLARE @readers nvarchar(1000) = N'';

SELECT @readers = STRING_AGG(CAST(o.name AS nvarchar(128)), N', ')
  FROM (SELECT DISTINCT d.referencing_id
          FROM sys.sql_expression_dependencies d
         WHERE d.referenced_entity_name = 't_sso_user_status_history') d
  JOIN sys.objects o ON o.object_id = d.referencing_id
 WHERE o.type IN ('P', 'FN', 'IF', 'TF', 'V', 'TR')
   AND o.name NOT IN ('USP_UpdateUserStatus', 'USP_GetUserStatusHistory', 'USP_UnlockUser');

IF ISNULL(@readers, N'') <> N''
BEGIN
    DECLARE @m2 nvarchar(1200) =
        N'006_admin: 🔒 A PROCEDURE OUTSIDE THE ADMIN SURFACE TOUCHES THE STATUS HISTORY: '
        + @readers
        + N'. The reason text is written by an administrator about somebody''s account and must not reach that person or their school. If this procedure is genuinely admin-only, add it to the allowed list here WITH the reason.';

    RAISERROR('%s', 16, 1, @m2);
END
GO

PRINT '    Admin procedures ready (incl. status history, G45).';
GO
