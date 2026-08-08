/*==============================================================================
  jp_sso — 04_procedures / 004_password.sql

  Password reset and password change.

  ---------------------------------------------------------------------------
  WHERE THE REUSE CHECK ACTUALLY HAPPENS
  ---------------------------------------------------------------------------
  "Block reuse of the last 3" cannot be decided in SQL. Each historical
  credential has its OWN random salt, so proving the new password matches an
  old one means running PBKDF2 once per historical row, with that row's salt
  and iteration count, and comparing in constant time. That is .NET work.

  So the rule is enforced across two calls:

      1. USP_GetPasswordHistory  -> returns the last N hash+salt+iterations
      2. (API) IPasswordService.VerifyPassword against each; refuse on a match
      3. USP_ChangePassword      -> performs the swap

  USP_GetPasswordHistory is therefore the second and last procedure allowed to
  return hash material, alongside USP_GetUserForLogin.
==============================================================================*/

USE jp_sso;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  USP_CreatePasswordResetToken

  Issues a reset token for an email address.

  Returns Status = 1 whether or not the address exists, with UserId NULL when
  it does not. The API sends an email only when UserId comes back, and answers
  the caller identically either way — "if that address has an account, we've
  sent a link". A proc that failed for unknown addresses would turn
  forgot-password into an account-existence oracle.

  Any earlier unused reset token is revoked first, so only the newest link
  works. Otherwise every link ever requested stays live until it expires.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_CreatePasswordResetToken
    @Email      nvarchar(150),
    @TokenHash  varchar(128),
    @ExpiresOn  datetime2,
    @IpAddress  varchar(45)   = NULL,
    @UserAgent  nvarchar(400) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 1,
            @Code varchar(50) = NULL,
            @Message nvarchar(400) = N'If that address has an account, a reset link has been sent.',
            @UserId bigint = NULL,
            @UserTypeId int = NULL,
            @TokenId bigint = NULL,
            @Now datetime2 = SYSUTCDATETIME();

    SET @Email = LOWER(LTRIM(RTRIM(ISNULL(@Email, N''))));

    SELECT @UserId = UserId, @UserTypeId = UserTypeId
    FROM dbo.t_sso_users
    WHERE Email = @Email AND Is_Deleted = 0 AND Is_Active = 1;

    IF ISNULL(@TokenHash, '') = '' OR @ExpiresOn IS NULL OR @ExpiresOn <= @Now
    BEGIN
        SELECT @Status = 0, @Code = 'VALIDATION_FAILED', @Message = N'The reset token is not valid.';
    END
    ELSE IF @UserId IS NOT NULL
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            -- TokenTypeId 2 = PasswordReset
            UPDATE dbo.t_sso_user_tokens
            SET RevokedOn = @Now,
                ModifiedOn = @Now
            WHERE UserId = @UserId
              AND TokenTypeId = 2
              AND Is_Deleted = 0
              AND RevokedOn IS NULL
              AND UsedOn IS NULL;

            INSERT INTO dbo.t_sso_user_tokens
                (UserId, TokenTypeId, TokenHash, ExpiresOn, IpAddress, UserAgent, CreatedBy)
            VALUES
                (@UserId, 2, @TokenHash, @ExpiresOn, @IpAddress, @UserAgent, @UserId);

            SET @TokenId = SCOPE_IDENTITY();

            COMMIT TRANSACTION;
        END TRY
        BEGIN CATCH
            -- CAPTURE -> ROLLBACK -> LOG -> RESPOND (decision 2.31).
            DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                    @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                    @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            -- The reset token hash grants a password change. Never logged.
            DECLARE @Params nvarchar(max) = (
                SELECT @Email AS email, @UserId AS userId,
                       '***masked***' AS tokenHash, @ExpiresOn AS expiresOn
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
                 @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
                 @ErrorMessage = @ErrMessage, @ParametersJson = @Params,
                 @ContextInfo = N'USP_CreatePasswordResetToken', @CreatedBy = @UserId;

            THROW;
        END CATCH
    END

    /*
      UserTypeId is returned so the API can build the reset link for the RIGHT
      app. Since admin, school and teacher became separate deployments there is
      no single portal URL to send someone to, and a link into the wrong app
      lands on its login page with a token it will never use.

      It leaks nothing: the caller already supplied the email, and for an
      address with no account both UserId and UserTypeId come back NULL — the
      response stays identical either way, which is what keeps this endpoint
      from being an account-existence oracle (decision 2.32).
    */
    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @TokenId AS Id,
           @UserId AS UserId, @UserTypeId AS UserTypeId;
END
GO


/*==============================================================================
  USP_ValidatePasswordResetToken

  Read-only. Backs the "is this link still good?" check when the reset page
  first loads, so the user is told the link is stale before they type a new
  password rather than after.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_ValidatePasswordResetToken
    @TokenHash varchar(128)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now datetime2 = SYSUTCDATETIME();

    SELECT
        t.TokenId,
        t.UserId,
        t.ExpiresOn,
        t.UsedOn,
        t.RevokedOn,
        u.UserUid,
        u.Email,
        u.StatusId,
        CAST(CASE WHEN t.RevokedOn IS NULL
                   AND t.UsedOn IS NULL
                   AND t.ExpiresOn > @Now
                   AND t.Is_Deleted = 0
                   AND u.Is_Deleted = 0
                  THEN 1 ELSE 0 END AS bit) AS IsValid
    FROM dbo.t_sso_user_tokens t
    INNER JOIN dbo.t_sso_users u ON u.UserId = t.UserId
    WHERE t.TokenHash = @TokenHash
      AND t.TokenTypeId = 2;
END
GO


/*==============================================================================
  USP_GetPasswordHistory

  The last @Depth credentials for a user, newest first, for the reuse check.

  Returns hash material, so it is called only from the change-password service
  and never from anything user-facing.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetPasswordHistory
    @UserId bigint,
    @Depth  int = 3           -- AppConstants.Password.HistoryDepth
AS
BEGIN
    SET NOCOUNT ON;

    -- Includes the CURRENT credential as well as retired ones: reusing the
    -- password you are already signed in with is the most obvious reuse of all.
    SELECT TOP (@Depth)
        c.CredentialId,
        c.PasswordHash,
        c.PasswordSalt,
        c.HashAlgorithmId,
        c.Iterations,
        c.IsCurrent,
        c.CreatedOn
    FROM dbo.t_sso_user_credentials c
    WHERE c.UserId = @UserId
      AND c.Is_Deleted = 0
    ORDER BY c.CreatedOn DESC, c.CredentialId DESC;
END
GO


/*==============================================================================
  USP_ChangePassword

  Retires the current credential and installs a new one.

  Everything below happens in ONE transaction:
    1. current credential  -> IsCurrent = 0   (must precede the insert, or the
                              filtered unique index rejects the second current row)
    2. new credential      -> inserted, IsCurrent = 1
    3. LastPasswordChangeOn updated, FailedAttemptCount cleared
    4. every live token revoked
    5. reset token consumed, when this change came from a reset link

  Step 4 is not optional. A password change that leaves refresh tokens alive
  has not ended anyone's access — whoever prompted the change keeps their
  session. That is the whole reason the user changed it.

  @ResetTokenHash makes the reset flow atomic: the link is consumed in the same
  transaction as the password swap, so it can never set two passwords.

  The reuse check runs in the service layer BEFORE this call — see the header.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_ChangePassword
    @UserId             bigint,
    @PasswordHash       varbinary(64),
    @PasswordSalt       varbinary(32),
    @HashAlgorithmId    int             = 1,
    @Iterations         int,
    @ResetTokenHash     varchar(128)    = NULL,
    @ChangedByUserId    bigint          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0,
            @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL,
            @CredentialId bigint = NULL,
            @RevokedCount int = 0,
            @ResetTokenId bigint = NULL,
            @ResetTokenUserId bigint = NULL,
            @ResetExpiresOn datetime2 = NULL,
            @ResetUsedOn datetime2 = NULL,
            @ResetRevokedOn datetime2 = NULL,
            @Now datetime2 = SYSUTCDATETIME();

    IF @PasswordHash IS NULL OR DATALENGTH(@PasswordHash) <> 64
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The password hash is malformed.';
    ELSE IF @PasswordSalt IS NULL OR DATALENGTH(@PasswordSalt) <> 32
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The password salt is malformed.';
    ELSE IF ISNULL(@Iterations, 0) <= 0
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The iteration count is not valid.';
    ELSE IF NOT EXISTS (SELECT 1 FROM dbo.t_sso_users WHERE UserId = @UserId AND Is_Deleted = 0)
        SELECT @Code = 'NOT_FOUND', @Message = N'That account no longer exists.';

    -- Reset-link path: the token must still be good, and must belong to this user.
    IF @Code IS NULL AND @ResetTokenHash IS NOT NULL
    BEGIN
        SELECT @ResetTokenId = TokenId, @ResetTokenUserId = UserId,
               @ResetExpiresOn = ExpiresOn, @ResetUsedOn = UsedOn, @ResetRevokedOn = RevokedOn
        FROM dbo.t_sso_user_tokens
        WHERE TokenHash = @ResetTokenHash AND TokenTypeId = 2 AND Is_Deleted = 0;

        IF @ResetTokenId IS NULL OR @ResetTokenUserId <> @UserId
            SELECT @Code = 'TOKEN_INVALID', @Message = N'This reset link is not valid.';
        ELSE IF @ResetUsedOn IS NOT NULL OR @ResetRevokedOn IS NOT NULL
            SELECT @Code = 'TOKEN_ALREADY_USED', @Message = N'This reset link has already been used.';
        ELSE IF @ResetExpiresOn <= @Now
            SELECT @Code = 'TOKEN_EXPIRED', @Message = N'This reset link has expired. Request a new one.';
    END

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            -- 1. Retire the current credential FIRST.
            UPDATE dbo.t_sso_user_credentials
            SET IsCurrent = 0,
                ModifiedOn = @Now,
                ModifiedBy = @ChangedByUserId
            WHERE UserId = @UserId AND IsCurrent = 1;

            -- 2. Install the new one.
            INSERT INTO dbo.t_sso_user_credentials
                (UserId, PasswordHash, PasswordSalt, HashAlgorithmId, Iterations, IsCurrent, CreatedBy)
            VALUES
                (@UserId, @PasswordHash, @PasswordSalt, @HashAlgorithmId, @Iterations, 1, @ChangedByUserId);

            SET @CredentialId = SCOPE_IDENTITY();

            -- 3. Stamp the user. FailedAttemptCount clears too: someone who
            --    just proved control of the account should not inherit a
            --    counter that is one attempt away from a lockout.
            UPDATE dbo.t_sso_users
            SET LastPasswordChangeOn = @Now,
                FailedAttemptCount = 0,
                ModifiedOn = @Now,
                ModifiedBy = @ChangedByUserId,
                [RowVersion] = [RowVersion] + 1
            WHERE UserId = @UserId;

            -- 4. Kill every live session and every outstanding link.
            UPDATE dbo.t_sso_user_tokens
            SET RevokedOn = @Now,
                ModifiedOn = @Now,
                ModifiedBy = @ChangedByUserId
            WHERE UserId = @UserId
              AND Is_Deleted = 0
              AND RevokedOn IS NULL
              AND TokenId <> ISNULL(@ResetTokenId, -1);

            SET @RevokedCount = @@ROWCOUNT;

            -- 5. Consume the reset link itself.
            IF @ResetTokenId IS NOT NULL
            BEGIN
                UPDATE dbo.t_sso_user_tokens
                SET UsedOn = @Now,
                    RevokedOn = @Now,
                    ModifiedOn = @Now,
                    ModifiedBy = @UserId
                WHERE TokenId = @ResetTokenId;

                SET @RevokedCount = @RevokedCount + 1;
            END

            COMMIT TRANSACTION;

            SELECT @Status = 1,
                   @Message = N'Your password has been changed. Other devices have been signed out.';
        END TRY
        BEGIN CATCH
            -- CAPTURE -> ROLLBACK -> LOG -> RESPOND (decision 2.31).
            DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                    @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                    @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            -- Every secret this procedure touches is masked: the new password
            -- material and the reset token that authorised the change.
            DECLARE @Params nvarchar(max) = (
                SELECT @UserId AS userId, '***masked***' AS passwordHash,
                       '***masked***' AS passwordSalt, @Iterations AS iterations,
                       CASE WHEN @ResetTokenHash IS NULL THEN NULL ELSE '***masked***' END AS resetTokenHash,
                       @ResetTokenId AS resetTokenId
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
                 @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
                 @ErrorMessage = @ErrMessage, @ParametersJson = @Params,
                 @ContextInfo = N'USP_ChangePassword', @CreatedBy = @ChangedByUserId;

            THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @CredentialId AS Id,
           @RevokedCount AS RevokedTokenCount;
END
GO

PRINT '    Password procedures ready.';
GO
