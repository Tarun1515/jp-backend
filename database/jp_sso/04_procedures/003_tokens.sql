/*==============================================================================
  jp_sso — 04_procedures / 003_tokens.sql

  Refresh token lifecycle: issue, validate, rotate, revoke, purge.

  Tokens are stored ONLY as SHA-256 hashes. The plaintext exists in the
  response body and nowhere else — not in this database, not in a log. Every
  lookup here is by hash, which is why UQ_t_sso_user_tokens_TokenHash exists.

  TokenTypeId 1 = Refresh throughout this file.
==============================================================================*/

USE jp_sso;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  USP_SaveRefreshToken

  Issues a refresh token at the end of a successful sign-in.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SaveRefreshToken
    @UserId     bigint,
    @TokenHash  varchar(128),
    @ExpiresOn  datetime2,
    @IpAddress  varchar(45)   = NULL,
    @UserAgent  nvarchar(400) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Status int = 0,
            @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL,
            @TokenId bigint = NULL;

    IF ISNULL(@TokenHash, '') = ''
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The token hash is missing.';
    ELSE IF @ExpiresOn IS NULL OR @ExpiresOn <= SYSUTCDATETIME()
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The token expiry is not valid.';
    ELSE IF NOT EXISTS (SELECT 1 FROM dbo.t_sso_users WHERE UserId = @UserId AND Is_Deleted = 0)
        SELECT @Code = 'NOT_FOUND', @Message = N'That account no longer exists.';

    IF @Code IS NULL
    BEGIN
        INSERT INTO dbo.t_sso_user_tokens
            (UserId, TokenTypeId, TokenHash, ExpiresOn, IpAddress, UserAgent, CreatedBy)
        VALUES
            (@UserId, 1, @TokenHash, @ExpiresOn, @IpAddress, @UserAgent, @UserId);

        SELECT @TokenId = SCOPE_IDENTITY(), @Status = 1, @Message = N'Refresh token issued.';
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @TokenId AS Id;
END
GO


/*==============================================================================
  USP_ValidateRefreshToken

  Read-only check. Returns the token row and a decision, without mutating
  anything — rotation is a separate call so that a caller which only wants to
  inspect a token cannot accidentally consume it.

  Empty result set when the hash matches nothing, for the same
  no-enumeration reason as USP_GetUserForLogin.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_ValidateRefreshToken
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
        t.ReplacedByTokenId,
        u.UserUid,
        u.StatusId,
        u.UserTypeId,
        u.OrganizationUid,

        -- A single flag the API can act on, so the rules live in one place.
        CAST(CASE WHEN t.RevokedOn IS NULL
                   AND t.UsedOn IS NULL
                   AND t.ExpiresOn > @Now
                   AND t.Is_Deleted = 0
                   AND u.Is_Deleted = 0
                  THEN 1 ELSE 0 END AS bit) AS IsValid,

        -- Distinguishes a stale token from a leaked one. A token that was
        -- already consumed and is being presented again is the signature of a
        -- stolen token, not of an expired session.
        CAST(CASE WHEN t.RevokedOn IS NOT NULL OR t.UsedOn IS NOT NULL
                  THEN 1 ELSE 0 END AS bit) AS IsReuseAttempt

    FROM dbo.t_sso_user_tokens t
    INNER JOIN dbo.t_sso_users u ON u.UserId = t.UserId
    WHERE t.TokenHash = @TokenHash
      AND t.TokenTypeId = 1;
END
GO


/*==============================================================================
  USP_RotateRefreshToken

  Exchanges a refresh token for a new one. Old token consumed and revoked, new
  token inserted, chain linked — all in one transaction.

  ---------------------------------------------------------------------------
  THIS IS THE REUSE-DETECTION POINT
  ---------------------------------------------------------------------------
  Rotation means a refresh token is valid exactly once. So if a token that has
  ALREADY been consumed is presented again, there are only two explanations:
  the legitimate client retried a request whose response it never saw, or a
  stolen token is being replayed. The two are indistinguishable from here.

  The safe reading is theft, because the cost of being wrong differs wildly:
  treat a replay as innocent and an attacker keeps a live session indefinitely;
  treat a retry as theft and a user signs in again.

  So every refresh token for that user is revoked — not just the presented one.
  The attacker holds a token from somewhere in the chain and the real user
  holds the newest; revoking one link would leave the other working, and there
  is no way to tell which is which.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_RotateRefreshToken
    @UserId         bigint,
    @OldTokenHash   varchar(128),
    @NewTokenHash   varchar(128),
    @NewExpiresOn   datetime2,
    @IpAddress      varchar(45)   = NULL,
    @UserAgent      nvarchar(400) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0,
            @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL,
            @NewTokenId bigint = NULL,
            @OldTokenId bigint = NULL,
            @OldUserId bigint = NULL,
            @OldExpiresOn datetime2 = NULL,
            @OldUsedOn datetime2 = NULL,
            @OldRevokedOn datetime2 = NULL,
            @RevokedCount int = 0,
            @ReuseDetected bit = 0,
            @Now datetime2 = SYSUTCDATETIME();

    BEGIN TRY
        BEGIN TRANSACTION;

        -- UPDLOCK: two refreshes racing with the same token must not both pass
        -- the "not yet used" check and both mint a new one.
        SELECT @OldTokenId  = t.TokenId,
               @OldUserId   = t.UserId,
               @OldExpiresOn= t.ExpiresOn,
               @OldUsedOn   = t.UsedOn,
               @OldRevokedOn= t.RevokedOn
        FROM dbo.t_sso_user_tokens t WITH (UPDLOCK, HOLDLOCK)
        WHERE t.TokenHash = @OldTokenHash
          AND t.TokenTypeId = 1
          AND t.Is_Deleted = 0;

        IF @OldTokenId IS NULL
            SELECT @Code = 'TOKEN_INVALID', @Message = N'Your session is no longer valid. Please sign in again.';

        -- Belongs to a different user: the caller's own token is not this one.
        ELSE IF @OldUserId <> @UserId
            SELECT @Code = 'TOKEN_INVALID', @Message = N'Your session is no longer valid. Please sign in again.';

        -- Already consumed or revoked => replay. Burn the whole chain.
        ELSE IF @OldUsedOn IS NOT NULL OR @OldRevokedOn IS NOT NULL
        BEGIN
            UPDATE dbo.t_sso_user_tokens
            SET RevokedOn = @Now,
                ModifiedOn = @Now
            WHERE UserId = @OldUserId
              AND TokenTypeId = 1
              AND Is_Deleted = 0
              AND RevokedOn IS NULL;

            SET @RevokedCount = @@ROWCOUNT;
            SET @ReuseDetected = 1;

            SELECT @Code = 'TOKEN_REVOKED',
                   @Message = N'This session has been ended for security reasons. Please sign in again.';
        END

        ELSE IF @OldExpiresOn <= @Now
            SELECT @Code = 'TOKEN_EXPIRED', @Message = N'Your session has expired. Please sign in again.';

        ELSE IF ISNULL(@NewTokenHash, '') = '' OR @NewExpiresOn IS NULL OR @NewExpiresOn <= @Now
            SELECT @Code = 'VALIDATION_FAILED', @Message = N'The replacement token is not valid.';

        ELSE IF NOT EXISTS (SELECT 1 FROM dbo.t_sso_users
                            WHERE UserId = @UserId AND Is_Deleted = 0 AND Is_Active = 1)
            SELECT @Code = 'NOT_FOUND', @Message = N'That account is no longer available.';

        IF @Code IS NULL
        BEGIN
            INSERT INTO dbo.t_sso_user_tokens
                (UserId, TokenTypeId, TokenHash, ExpiresOn, IpAddress, UserAgent, CreatedBy)
            VALUES
                (@UserId, 1, @NewTokenHash, @NewExpiresOn, @IpAddress, @UserAgent, @UserId);

            SET @NewTokenId = SCOPE_IDENTITY();

            -- UsedOn AND RevokedOn: consumed, and no longer acceptable.
            -- ReplacedByTokenId is what makes the chain walkable for forensics.
            UPDATE dbo.t_sso_user_tokens
            SET UsedOn = @Now,
                RevokedOn = @Now,
                ReplacedByTokenId = @NewTokenId,
                ModifiedOn = @Now,
                ModifiedBy = @UserId
            WHERE TokenId = @OldTokenId;

            SELECT @Status = 1, @Message = N'Session refreshed.';
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        -- CAPTURE -> ROLLBACK -> LOG -> RESPOND (decision 2.31).
        DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        -- BOTH token hashes are masked. Logging either one would put a live
        -- session credential into the most widely read table in the system.
        DECLARE @Params nvarchar(max) = (
            SELECT @UserId AS userId, '***masked***' AS oldTokenHash,
                   '***masked***' AS newTokenHash, @NewExpiresOn AS newExpiresOn,
                   @IpAddress AS ipAddress
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
             @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
             @ErrorMessage = @ErrMessage, @ParametersJson = @Params,
             @ContextInfo = N'USP_RotateRefreshToken', @CreatedBy = @UserId;

        THROW;
    END CATCH

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @NewTokenId AS Id,
           @ReuseDetected AS ReuseDetected, @RevokedCount AS RevokedCount;
END
GO


/*==============================================================================
  USP_RevokeRefreshToken

  Single-token revocation — an ordinary sign-out.

  Deliberately reports success even when the token was already gone. Sign-out
  is idempotent from the user's point of view, and telling an anonymous caller
  whether a token hash existed would leak exactly the fact the hashing is
  there to protect.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_RevokeRefreshToken
    @TokenHash varchar(128),
    @UserId    bigint = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Status int = 1,
            @Code varchar(50) = NULL,
            @Message nvarchar(400) = N'Signed out.',
            @RevokedCount int = 0,
            @Now datetime2 = SYSUTCDATETIME();

    UPDATE dbo.t_sso_user_tokens
    SET RevokedOn = @Now,
        ModifiedOn = @Now,
        ModifiedBy = @UserId
    WHERE TokenHash = @TokenHash
      AND TokenTypeId = 1
      AND Is_Deleted = 0
      AND RevokedOn IS NULL
      AND (@UserId IS NULL OR UserId = @UserId);

    SET @RevokedCount = @@ROWCOUNT;

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, NULL AS Id,
           @RevokedCount AS RevokedCount;
END
GO


/*==============================================================================
  USP_RevokeAllUserTokens

  Kills every live token for a user.

  Called on password change and on admin suspension. A password change that
  leaves old refresh tokens working has not actually locked anyone out — the
  attacker who prompted the change keeps their session. Same for a suspension.

  @TokenTypeId NULL means every type, which also invalidates any outstanding
  password-reset and invite links.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_RevokeAllUserTokens
    @UserId         bigint,
    @TokenTypeId    int    = NULL,
    @RevokedByUserId bigint = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Status int = 1,
            @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL,
            @RevokedCount int = 0,
            @Now datetime2 = SYSUTCDATETIME();

    UPDATE dbo.t_sso_user_tokens
    SET RevokedOn = @Now,
        ModifiedOn = @Now,
        ModifiedBy = @RevokedByUserId
    WHERE UserId = @UserId
      AND Is_Deleted = 0
      AND RevokedOn IS NULL
      AND (@TokenTypeId IS NULL OR TokenTypeId = @TokenTypeId);

    SET @RevokedCount = @@ROWCOUNT;
    SET @Message = N'Revoked ' + CAST(@RevokedCount AS nvarchar(10)) + N' token(s).';

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @UserId AS Id,
           @RevokedCount AS RevokedCount;
END
GO


/*==============================================================================
  USP_CleanupExpiredTokens

  Maintenance. Hard-deletes tokens that expired more than @RetentionDays ago.

  ---------------------------------------------------------------------------
  The one place a DELETE is correct
  ---------------------------------------------------------------------------
  The soft-delete rule (2.4) exists so business records stay auditable. An
  expired token hash is not a business record — it is a spent credential with
  no informational value, and t_sso_user_tokens gains a row per sign-in and per
  refresh forever. The retention window keeps recent history available for
  investigating a reuse incident.

  Deletes in batches so a large backlog does not hold a lock long enough to
  block sign-ins, and so the transaction log has somewhere to breathe.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_CleanupExpiredTokens
    @RetentionDays int = 30,
    @BatchSize     int = 5000
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Status int = 1,
            @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL,
            @DeletedCount int = 0,
            @BatchCount int = 1,
            @Cutoff datetime2 = DATEADD(DAY, -ABS(@RetentionDays), SYSUTCDATETIME());

    WHILE @BatchCount > 0
    BEGIN
        DELETE TOP (@BatchSize) FROM dbo.t_sso_user_tokens
        WHERE ExpiresOn < @Cutoff;

        SET @BatchCount = @@ROWCOUNT;
        SET @DeletedCount = @DeletedCount + @BatchCount;
    END

    SET @Message = N'Removed ' + CAST(@DeletedCount AS nvarchar(10))
                 + N' token(s) expired before ' + CONVERT(nvarchar(30), @Cutoff, 126) + N'Z.';

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, NULL AS Id,
           @DeletedCount AS DeletedCount;
END
GO

PRINT '    Token procedures ready.';
GO
