/*==============================================================================
  jp_sso — 04_procedures / 005_otp.sql

  One-time passwords for email and mobile verification.

  Codes are stored hashed, like every other token. A 6-digit code has only a
  million possibilities, so the hash is not much of a barrier by itself — the
  real protections are the 10-minute expiry, the 5-attempt cap, and the rate
  limit on the send endpoint. The hash is there so a database leak does not
  hand over live codes.
==============================================================================*/

USE jp_sso;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  USP_SaveOtp

  Issues a code, retiring any earlier unverified code for the same user and
  channel first.

  Only ONE code may be live at a time. Without that, a user who taps "resend"
  three times leaves three valid codes in play, and each of them carries its
  own independent 5-attempt budget — the cap becomes 15 without anyone
  choosing that.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SaveOtp
    @UserId         bigint,
    @OtpChannelId   int,
    @OtpHash        varchar(128),
    @SentTo         nvarchar(150),
    @ExpiresOn      datetime2
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0,
            @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL,
            @OtpId bigint = NULL,
            @Now datetime2 = SYSUTCDATETIME();

    IF ISNULL(@OtpHash, '') = ''
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The code is missing.';
    ELSE IF @ExpiresOn IS NULL OR @ExpiresOn <= @Now
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The code expiry is not valid.';
    ELSE IF NOT EXISTS (SELECT 1 FROM dbo.m_sso_otp_channels
                        WHERE OtpChannelId = @OtpChannelId AND Is_Active = 1 AND Is_Deleted = 0)
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'That delivery channel is not recognised.';
    ELSE IF NOT EXISTS (SELECT 1 FROM dbo.t_sso_users WHERE UserId = @UserId AND Is_Deleted = 0)
        SELECT @Code = 'NOT_FOUND', @Message = N'That account no longer exists.';

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            -- Retire earlier live codes for this channel. Soft delete, so the
            -- audit trail of what was sent survives.
            UPDATE dbo.t_sso_user_otps
            SET Is_Active = 0,
                Is_Deleted = 1,
                ModifiedOn = @Now,
                ModifiedBy = @UserId
            WHERE UserId = @UserId
              AND OtpChannelId = @OtpChannelId
              AND IsVerified = 0
              AND Is_Deleted = 0;

            INSERT INTO dbo.t_sso_user_otps
                (UserId, OtpChannelId, OtpHash, SentTo, ExpiresOn, AttemptCount, IsVerified, CreatedBy)
            VALUES
                (@UserId, @OtpChannelId, @OtpHash, @SentTo, @ExpiresOn, 0, 0, @UserId);

            SET @OtpId = SCOPE_IDENTITY();

            COMMIT TRANSACTION;

            SELECT @Status = 1, @Message = N'Verification code sent.';
        END TRY
        BEGIN CATCH
            -- CAPTURE -> ROLLBACK -> LOG -> RESPOND (decision 2.31).
            DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                    @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                    @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            -- A 6-digit code has a million possibilities; its hash in a log is
            -- as good as the code itself.
            DECLARE @Params nvarchar(max) = (
                SELECT @UserId AS userId, @OtpChannelId AS otpChannelId,
                       '***masked***' AS otpHash, @SentTo AS sentTo, @ExpiresOn AS expiresOn
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
                 @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
                 @ErrorMessage = @ErrMessage, @ParametersJson = @Params,
                 @ContextInfo = N'USP_SaveOtp', @CreatedBy = @UserId;

            THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @OtpId AS Id;
END
GO


/*==============================================================================
  USP_VerifyOtp

  Checks a code and, on success, marks the matching address or number verified.

  The attempt counter is incremented on EVERY check, including the ones that
  fail — that is what makes the cap meaningful. Incrementing only on success,
  or forgetting to persist the increment when the code is wrong, leaves the
  code brute-forceable inside its validity window.

  Comparison is by hash: the API hashes the submitted digits and passes the
  digest, so the plaintext code never reaches SQL.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_VerifyOtp
    @UserId         bigint,
    @OtpChannelId   int,
    @OtpHash        varchar(128),
    @MaxAttempts    int = 5           -- AppConstants.Otp.MaxVerifyAttempts
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0,
            @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL,
            @OtpId bigint = NULL,
            @StoredHash varchar(128) = NULL,
            @ExpiresOn datetime2 = NULL,
            @AttemptCount int = NULL,
            @IsVerified bit = NULL,
            @AttemptsRemaining int = NULL,
            @Now datetime2 = SYSUTCDATETIME();

    BEGIN TRY
        BEGIN TRANSACTION;

        -- Newest live code for this channel. UPDLOCK so two simultaneous
        -- guesses cannot both read the same attempt count.
        SELECT TOP (1)
               @OtpId = o.OtpId, @StoredHash = o.OtpHash, @ExpiresOn = o.ExpiresOn,
               @AttemptCount = o.AttemptCount, @IsVerified = o.IsVerified
        FROM dbo.t_sso_user_otps o WITH (UPDLOCK, HOLDLOCK)
        WHERE o.UserId = @UserId
          AND o.OtpChannelId = @OtpChannelId
          AND o.Is_Deleted = 0
        ORDER BY o.CreatedOn DESC, o.OtpId DESC;

        IF @OtpId IS NULL
            SELECT @Code = 'OTP_INVALID', @Message = N'That code is not valid. Request a new one.';
        ELSE IF @IsVerified = 1
            SELECT @Code = 'OTP_INVALID', @Message = N'That code has already been used.';
        ELSE IF @AttemptCount >= @MaxAttempts
            SELECT @Code = 'OTP_MAX_ATTEMPTS', @Message = N'Too many incorrect attempts. Request a new code.';
        ELSE IF @ExpiresOn <= @Now
            SELECT @Code = 'OTP_EXPIRED', @Message = N'That code has expired. Request a new one.';

        IF @Code IS NULL
        BEGIN
            -- Count the attempt before judging it, so a wrong guess is paid for
            -- even if the caller abandons the request.
            SET @AttemptCount = @AttemptCount + 1;

            UPDATE dbo.t_sso_user_otps
            SET AttemptCount = @AttemptCount,
                ModifiedOn = @Now
            WHERE OtpId = @OtpId;

            IF @StoredHash = @OtpHash
            BEGIN
                UPDATE dbo.t_sso_user_otps
                SET IsVerified = 1,
                    VerifiedOn = @Now,
                    ModifiedOn = @Now
                WHERE OtpId = @OtpId;

                -- Channel 1 = Email, 2 = SMS.
                UPDATE dbo.t_sso_users
                SET IsEmailVerified  = CASE WHEN @OtpChannelId = 1 THEN 1 ELSE IsEmailVerified END,
                    IsMobileVerified = CASE WHEN @OtpChannelId = 2 THEN 1 ELSE IsMobileVerified END,
                    ModifiedOn = @Now,
                    ModifiedBy = @UserId
                WHERE UserId = @UserId;

                SELECT @Status = 1, @Message = N'Verified.';
            END
            ELSE
            BEGIN
                SET @AttemptsRemaining = @MaxAttempts - @AttemptCount;

                SELECT @Code = CASE WHEN @AttemptsRemaining <= 0 THEN 'OTP_MAX_ATTEMPTS' ELSE 'OTP_INVALID' END,
                       @Message = CASE WHEN @AttemptsRemaining <= 0
                                       THEN N'Too many incorrect attempts. Request a new code.'
                                       ELSE N'That code is not correct.' END;
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

        -- The SUBMITTED code hash is masked too — it is a guess at a live
        -- secret, and a log full of guesses narrows the search for an attacker.
        DECLARE @Params nvarchar(max) = (
            SELECT @UserId AS userId, @OtpChannelId AS otpChannelId,
                   '***masked***' AS otpHash, @MaxAttempts AS maxAttempts,
                   @OtpId AS otpId, @AttemptCount AS attemptCount
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
             @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
             @ErrorMessage = @ErrMessage, @ParametersJson = @Params,
             @ContextInfo = N'USP_VerifyOtp', @CreatedBy = @UserId;

        THROW;
    END CATCH

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @OtpId AS Id,
           @AttemptCount AS AttemptCount,
           CASE WHEN @AttemptCount IS NULL THEN NULL
                ELSE CASE WHEN @MaxAttempts - @AttemptCount < 0 THEN 0
                          ELSE @MaxAttempts - @AttemptCount END
           END AS AttemptsRemaining;
END
GO

PRINT '    OTP procedures ready.';
GO
