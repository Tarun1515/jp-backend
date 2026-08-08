/*==============================================================================
  jp_sso — 04_procedures / 002_login.sql

  The sign-in path: lookup, attempt recording, lockout, claims.

  ---------------------------------------------------------------------------
  NO USER ENUMERATION
  ---------------------------------------------------------------------------
  USP_GetUserForLogin returns an EMPTY result set when the identifier matches
  nothing. It never signals "no such user" in any other way, because the API
  must answer identically for "unknown address" and "wrong password" — any
  difference turns the login form into a tool for discovering who has an
  account. The decision to return INVALID_CREDENTIALS is the API's; this proc
  only supplies facts.

  ---------------------------------------------------------------------------
  LOCKOUT AND STATUS
  ---------------------------------------------------------------------------
  Locking sets StatusId = 5 and records the prior status on the lockout row
  (see 01_tables/018_...). EffectiveStatusId below resolves the two: once the
  lock has expired, it reports the status the account should have returned to,
  so a Pending school does not emerge from a lockout as Active.
==============================================================================*/

USE jp_sso;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  USP_GetUserForLogin

  Everything the API needs to decide a sign-in, in one round trip: the user,
  their current credential, and any lockout still in force.

  This is one of only two procedures permitted to return PasswordHash and
  PasswordSalt (the other is USP_GetPasswordHistory). The comparison itself is
  done in .NET with CryptographicOperations.FixedTimeEquals — never in SQL,
  where a comparison is neither constant-time nor auditable.

  Read-only by design. It does not clear expired lockouts or touch counters;
  USP_RecordLoginAttempt owns every write on this path, which keeps this proc
  safe to retry and safe to run against a read replica later.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetUserForLogin
    @LoginIdentifier nvarchar(150)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Email nvarchar(150) = NULL,
            @Mobile varchar(15) = NULL,
            @Now datetime2 = SYSUTCDATETIME();

    SET @LoginIdentifier = LTRIM(RTRIM(ISNULL(@LoginIdentifier, N'')));

    -- An '@' means it is an email. Anything else is treated as a mobile
    -- number. Splitting here lets each branch seek its own unique index.
    IF @LoginIdentifier LIKE N'%@%'
        SET @Email = LOWER(@LoginIdentifier);
    ELSE
        SET @Mobile = CAST(@LoginIdentifier AS varchar(15));

    SELECT
        u.UserId,
        u.UserUid,
        u.UserTypeId,
        u.StatusId,
        u.Email,
        u.Mobile,
        u.IsEmailVerified,
        u.IsMobileVerified,
        u.OrganizationUid,
        u.FailedAttemptCount,
        u.LastLoginOn,
        u.LastPasswordChangeOn,
        u.[RowVersion],

        -- Current credential. LEFT JOIN: an invited user who has not yet
        -- redeemed their invitation has no credential at all, and that is a
        -- normal state rather than an error.
        c.CredentialId,
        c.PasswordHash,
        c.PasswordSalt,
        c.HashAlgorithmId,
        c.Iterations,
        c.ExpiresOn                     AS CredentialExpiresOn,

        -- Lockout still in force, if any.
        lk.LockoutId,
        lk.LockReasonId,
        lk.LockedOn,
        lk.UnlockOn,
        lk.PreviousStatusId,
        CAST(CASE WHEN lk.LockoutId IS NULL THEN 0 ELSE 1 END AS bit) AS IsLocked,

        /*
          The status to act on.

          StatusId 5 with no lock still in force means the lock has simply
          expired: report what the account was before it was locked.

          PreviousStatusId IS NOT NULL is required. When an administrator has
          superseded the lock, USP_UpdateUserStatus NULLs that marker, and the
          stored StatusId is then the authoritative answer. There is no
          fallback to Active — inventing one is what let a Pending school
          emerge from a lockout already approved.
        */
        CASE
            WHEN u.StatusId = 5 AND lk.LockoutId IS NULL AND lk2.PreviousStatusId IS NOT NULL
                THEN lk2.PreviousStatusId
            ELSE u.StatusId
        END AS EffectiveStatusId

    FROM dbo.t_sso_users u

    LEFT JOIN dbo.t_sso_user_credentials c
           ON c.UserId = u.UserId
          AND c.IsCurrent = 1
          AND c.Is_Deleted = 0

    -- Lockout that has NOT been lifted and has NOT expired.
    OUTER APPLY (
        SELECT TOP (1) lo.LockoutId, lo.LockReasonId, lo.LockedOn, lo.UnlockOn, lo.PreviousStatusId
        FROM dbo.t_sso_user_lockouts lo
        WHERE lo.UserId = u.UserId
          AND lo.Is_Deleted = 0
          AND lo.UnlockedOn IS NULL
          AND (lo.UnlockOn IS NULL OR lo.UnlockOn > @Now)
        ORDER BY lo.LockedOn DESC
    ) lk

    -- Most recent lockout regardless of expiry, purely to recover
    -- PreviousStatusId when the lock above has already lapsed.
    OUTER APPLY (
        SELECT TOP (1) lo2.PreviousStatusId
        FROM dbo.t_sso_user_lockouts lo2
        WHERE lo2.UserId = u.UserId
          AND lo2.Is_Deleted = 0
          AND lo2.UnlockedOn IS NULL
        ORDER BY lo2.LockedOn DESC
    ) lk2

    WHERE u.Is_Deleted = 0
      AND (   (@Email  IS NOT NULL AND u.Email  = @Email)
           OR (@Mobile IS NOT NULL AND u.Mobile = @Mobile));
END
GO


/*==============================================================================
  USP_RecordLoginAttempt

  Records every attempt and maintains the failure counter and lockouts.

  Called on BOTH outcomes, and for unknown identifiers too — an attempt against
  an address that does not exist is exactly the row you want when investigating
  credential stuffing, so @UserId is nullable.

  Success  : counter reset to 0, and if the account was locked by a lock that
             has since expired, its previous status is restored.
  Failure  : counter incremented. On reaching the threshold, a lockout row is
             written, the prior status is recorded on it, and the account moves
             to StatusId 5.

  Returns the resulting lock state so the API can tell the user "locked for 30
  minutes" on the attempt that actually caused it, rather than on the next one.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_RecordLoginAttempt
    @UserId             bigint          = NULL,
    @LoginIdentifier    nvarchar(150),
    @IpAddress          varchar(45)     = NULL,
    @UserAgent          nvarchar(400)   = NULL,
    @IsSuccess          bit,
    @FailureReason      varchar(50)     = NULL,
    @MaxFailedAttempts  int             = 5,      -- AppConstants.Lockout.MaxFailedAttempts
    @LockoutMinutes     int             = 30      -- AppConstants.Lockout.LockoutMinutes
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 1,
            @Code varchar(50) = NULL,
            @Message nvarchar(400) = N'Attempt recorded.',
            @AttemptId bigint = NULL,
            @FailedCount int = NULL,
            @IsNowLocked bit = 0,
            @UnlockOn datetime2 = NULL,
            @Now datetime2 = SYSUTCDATETIME(),
            @CurrentStatusId int = NULL,
            @HasActiveLock bit = 0;

    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO dbo.t_sso_user_login_attempts
            (UserId, LoginIdentifier, IpAddress, UserAgent, IsSuccess, FailureReason, AttemptedOn)
        VALUES
            (@UserId, @LoginIdentifier, @IpAddress, @UserAgent, @IsSuccess,
             CASE WHEN @IsSuccess = 1 THEN NULL ELSE @FailureReason END, @Now);

        SET @AttemptId = SCOPE_IDENTITY();

        IF @UserId IS NOT NULL
        BEGIN
            -- UPDLOCK/HOLDLOCK: two simultaneous failures must not both read
            -- count 4 and each decide they are the fifth. Serialising the read
            -- here is what makes the threshold exact.
            SELECT @CurrentStatusId = StatusId, @FailedCount = FailedAttemptCount
            FROM dbo.t_sso_users WITH (UPDLOCK, HOLDLOCK)
            WHERE UserId = @UserId AND Is_Deleted = 0;

            SELECT @HasActiveLock = CASE WHEN EXISTS (
                SELECT 1 FROM dbo.t_sso_user_lockouts
                WHERE UserId = @UserId AND Is_Deleted = 0 AND UnlockedOn IS NULL
                  AND (UnlockOn IS NULL OR UnlockOn > @Now)
            ) THEN 1 ELSE 0 END;

            IF @IsSuccess = 1
            BEGIN
                DECLARE @RestoreStatusId int = NULL;

                /*
                  Restoring the pre-lock status has TWO guards, and both matter.

                  1. StatusId must still be 5. If an administrator rejected or
                     suspended the account while it was locked, the status is
                     already 3 or 4 and their decision stands.

                  2. PreviousStatusId must still be set. USP_UpdateUserStatus
                     NULLs it on every active lockout it supersedes, so an admin
                     action leaves an explicit "nothing to restore" marker
                     rather than something to be inferred from timestamps.

                  Without guard 1, this sequence silently undid an admin:
                     Pending -> locked (Previous=1) -> admin rejects (Status=3)
                     -> lock expires -> restored to Pending. Rejection reversed.

                  Note what is deliberately NOT used here: a comparison of
                  t_sso_users.ModifiedOn against LockedOn. ModifiedOn is bumped
                  by ordinary failed attempts, password changes and OTP
                  verification too, so "modified after the lock" does not mean
                  "an admin acted" — and treating it that way would strand
                  accounts at StatusId 5 forever. The NULL marker is exact.
                */
                IF @CurrentStatusId = 5 AND @HasActiveLock = 0
                BEGIN
                    SELECT TOP (1) @RestoreStatusId = PreviousStatusId
                    FROM dbo.t_sso_user_lockouts
                    WHERE UserId = @UserId AND Is_Deleted = 0 AND UnlockedOn IS NULL
                    ORDER BY LockedOn DESC;

                    -- No ISNULL(..., 2) fallback. Inventing "Active" is exactly
                    -- how a Pending school walks through the approval gate.

                    -- Close the lapsed lockouts so they are not reconsidered.
                    UPDATE dbo.t_sso_user_lockouts
                    SET UnlockedOn = @Now,
                        ModifiedOn = @Now
                    WHERE UserId = @UserId AND Is_Deleted = 0 AND UnlockedOn IS NULL;
                END

                UPDATE dbo.t_sso_users
                SET FailedAttemptCount = 0,
                    StatusId = ISNULL(@RestoreStatusId, StatusId),
                    ModifiedOn = @Now
                WHERE UserId = @UserId;

                SET @FailedCount = 0;
            END
            ELSE
            BEGIN
                SET @FailedCount = ISNULL(@FailedCount, 0) + 1;

                UPDATE dbo.t_sso_users
                SET FailedAttemptCount = @FailedCount,
                    ModifiedOn = @Now
                WHERE UserId = @UserId;

                -- Threshold reached, and not already locked.
                IF @FailedCount >= @MaxFailedAttempts AND @HasActiveLock = 0
                BEGIN
                    SET @UnlockOn = DATEADD(MINUTE, @LockoutMinutes, @Now);

                    INSERT INTO dbo.t_sso_user_lockouts
                        (UserId, LockReasonId, LockedOn, UnlockOn, PreviousStatusId, Remarks)
                    VALUES
                        (@UserId, 1, @Now, @UnlockOn,
                         -- Never record 5; CK_..._PreviousStatusId forbids it and
                         -- restoring to "Locked" would strand the account.
                         NULLIF(@CurrentStatusId, 5),
                         N'Automatic lock after ' + CAST(@FailedCount AS nvarchar(10)) + N' failed sign-in attempts.');

                    UPDATE dbo.t_sso_users
                    SET StatusId = 5,
                        ModifiedOn = @Now
                    WHERE UserId = @UserId;

                    SET @IsNowLocked = 1;
                    SET @Code = 'ACCOUNT_LOCKED';
                    SET @Message = N'Too many failed attempts. This account is locked for '
                                 + CAST(@LockoutMinutes AS nvarchar(10)) + N' minutes.';
                END
                ELSE IF @HasActiveLock = 1
                BEGIN
                    SET @IsNowLocked = 1;
                END
            END
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        -- CAPTURE -> ROLLBACK -> LOG -> RESPOND (decision 2.31).
        DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        -- No password material reaches this procedure, so nothing to mask.
        DECLARE @Params nvarchar(max) = (
            SELECT @UserId AS userId, @LoginIdentifier AS loginIdentifier,
                   @IpAddress AS ipAddress, @IsSuccess AS isSuccess,
                   @FailureReason AS failureReason
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
             @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
             @ErrorMessage = @ErrMessage, @ParametersJson = @Params,
             @ContextInfo = N'USP_RecordLoginAttempt', @CreatedBy = @UserId;

        THROW;
    END CATCH

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @AttemptId AS Id,
           @FailedCount AS FailedAttemptCount, @IsNowLocked AS IsLocked, @UnlockOn AS UnlockOn;
END
GO


/*==============================================================================
  USP_UpdateLastLogin

  Separate from USP_RecordLoginAttempt because it runs at a different moment:
  the attempt is recorded as soon as the password is verified, whereas this
  runs once the token has actually been issued and the session exists.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_UpdateLastLogin
    @UserId bigint
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Status int = 0,
            @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL,
            @Now datetime2 = SYSUTCDATETIME();

    UPDATE dbo.t_sso_users
    SET LastLoginOn = @Now,
        ModifiedOn = @Now
    WHERE UserId = @UserId AND Is_Deleted = 0;

    IF @@ROWCOUNT = 0
        SELECT @Code = 'NOT_FOUND', @Message = N'That account no longer exists.';
    ELSE
        SELECT @Status = 1, @Message = N'Last login recorded.';

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @UserId AS Id;
END
GO


/*==============================================================================
  USP_GetUserClaims

  The role and permission codes that go into the JWT. Two result sets: roles,
  then permissions.

  Every join filters Is_Active AND Is_Deleted, at every level — user-role,
  role, role-permission, permission. A permission must stop being granted the
  moment ANY link in that chain is deactivated; checking only the outermost
  row would leave a deactivated role still handing out its permissions.

  Validity is compared against dbo.fn_IstToday(), not GETUTCDATE(). ValidFrom
  and ValidTo are `date` columns holding calendar dates (decision 2.28), so
  the comparison has to be made in the calendar the dates were written in —
  otherwise a grant valid "until 31 March" would expire 5.5 hours early for
  everyone.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetUserClaims
    @UserId bigint
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Today date = dbo.fn_IstToday();

    -- Result set 1: role codes
    SELECT DISTINCT r.RoleCode, ur.OrganizationUid
    FROM dbo.t_sso_user_roles ur
    INNER JOIN dbo.t_sso_roles r
            ON r.RoleId = ur.RoleId
           AND r.Is_Deleted = 0 AND r.Is_Active = 1
    WHERE ur.UserId = @UserId
      AND ur.Is_Deleted = 0 AND ur.Is_Active = 1
      AND ur.ValidFrom <= @Today
      AND (ur.ValidTo IS NULL OR ur.ValidTo >= @Today);

    -- Result set 2: permission codes
    SELECT DISTINCT p.PermissionCode
    FROM dbo.t_sso_user_roles ur
    INNER JOIN dbo.t_sso_roles r
            ON r.RoleId = ur.RoleId
           AND r.Is_Deleted = 0 AND r.Is_Active = 1
    INNER JOIN dbo.t_sso_role_permissions rp
            ON rp.RoleId = r.RoleId
           AND rp.Is_Deleted = 0 AND rp.Is_Active = 1
    INNER JOIN dbo.t_sso_permissions p
            ON p.PermissionId = rp.PermissionId
           AND p.Is_Deleted = 0 AND p.Is_Active = 1
    WHERE ur.UserId = @UserId
      AND ur.Is_Deleted = 0 AND ur.Is_Active = 1
      AND ur.ValidFrom <= @Today
      AND (ur.ValidTo IS NULL OR ur.ValidTo >= @Today);
END
GO


/*==============================================================================
  USP_GetUserByUid

  Backs GET /api/auth/me. Three result sets — profile, roles, permissions — so
  the endpoint is a single round trip.

  Takes the Uid, not the UserId: the numeric key never leaves the database.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetUserByUid
    @UserUid uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @UserId bigint = NULL,
            @Today date = dbo.fn_IstToday();

    SELECT @UserId = UserId
    FROM dbo.t_sso_users
    WHERE UserUid = @UserUid AND Is_Deleted = 0;

    -- Result set 1: the profile. Deliberately no credential columns.
    SELECT
        u.UserId, u.UserUid, u.UserTypeId, ut.Code AS UserTypeCode,
        u.StatusId, us.Code AS StatusCode, us.Name AS StatusName,
        u.Email, u.Mobile, u.IsEmailVerified, u.IsMobileVerified,
        u.OrganizationUid, u.LastLoginOn, u.LastPasswordChangeOn,
        u.CreatedOn, u.[RowVersion]
    FROM dbo.t_sso_users u
    INNER JOIN dbo.m_sso_user_types  ut ON ut.UserTypeId = u.UserTypeId
    INNER JOIN dbo.m_sso_user_status us ON us.StatusId  = u.StatusId
    WHERE u.UserId = @UserId;

    -- Result sets 2 and 3: same rules as USP_GetUserClaims.
    SELECT DISTINCT r.RoleCode, ur.OrganizationUid
    FROM dbo.t_sso_user_roles ur
    INNER JOIN dbo.t_sso_roles r
            ON r.RoleId = ur.RoleId AND r.Is_Deleted = 0 AND r.Is_Active = 1
    WHERE ur.UserId = @UserId
      AND ur.Is_Deleted = 0 AND ur.Is_Active = 1
      AND ur.ValidFrom <= @Today
      AND (ur.ValidTo IS NULL OR ur.ValidTo >= @Today);

    SELECT DISTINCT p.PermissionCode
    FROM dbo.t_sso_user_roles ur
    INNER JOIN dbo.t_sso_roles r
            ON r.RoleId = ur.RoleId AND r.Is_Deleted = 0 AND r.Is_Active = 1
    INNER JOIN dbo.t_sso_role_permissions rp
            ON rp.RoleId = r.RoleId AND rp.Is_Deleted = 0 AND rp.Is_Active = 1
    INNER JOIN dbo.t_sso_permissions p
            ON p.PermissionId = rp.PermissionId AND p.Is_Deleted = 0 AND p.Is_Active = 1
    WHERE ur.UserId = @UserId
      AND ur.Is_Deleted = 0 AND ur.Is_Active = 1
      AND ur.ValidFrom <= @Today
      AND (ur.ValidTo IS NULL OR ur.ValidTo >= @Today);
END
GO

PRINT '    Login procedures ready.';
GO
