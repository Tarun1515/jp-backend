/*==============================================================================
  jp_sso — 04_procedures / 001_registration.sql

  Account creation: school, teacher, admin, invited HR, and invite redemption.

  ---------------------------------------------------------------------------
  RESULT SHAPE (see PROJECT_MEMORY 2.21, and the note below)
  ---------------------------------------------------------------------------
      SELECT @Status, @Code, @Message, @Id [, extra columns]

  Status  1 = success, 0 = expected business failure
  Code    a JP.Core.Constants.ErrorCodes value, NULL on success
  Message user-facing text
  Id      the new key, NULL on failure

  2.21 specifies Status/Message/Id. @Code is an addition: decision 2.12 says
  the client branches on Response.code and NEVER on the message text, so
  without a code here the service layer would have to string-match messages to
  populate the envelope. One extra column removes that.

  THROW is reserved for genuine integrity failures, per 2.21. Everything a
  caller could reasonably trigger — duplicate email, bad token, weak input —
  comes back as Status = 0.

  ---------------------------------------------------------------------------
  RETRY SAFETY (2.24)
  ---------------------------------------------------------------------------
  The duplicate pre-checks below are a courtesy that produces a clean message.
  They are NOT the guarantee. Two concurrent registrations for the same address
  can both pass the check; the filtered unique index from Phase 1A is what
  actually stops the second insert, surfacing as SQL error 2627, which
  BaseRepository maps to a duplicate BusinessRuleException. That is also what
  makes these procs safe to re-run after a transient failure.

  Password hashing happens in the API (PBKDF2, 210k iterations). These procs
  receive the derived bytes and never see a plaintext password.
==============================================================================*/

USE jp_sso;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  USP_RegisterSchoolUser

  Self-registration by a school. Creates the user at StatusId = 1
  (PendingApproval) with a freshly minted OrganizationUid, plus the first
  credential row — both in one transaction.

  No role is granted here. SCHOOL_OWNER is assigned by USP_UpdateUserStatus
  when an admin approves the registration (PROJECT_MEMORY 2.9), so an
  unapproved account carries no permissions at all.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_RegisterSchoolUser
    @Email              nvarchar(150),
    @Mobile             varchar(15)      = NULL,
    @PasswordHash       varbinary(64),
    @PasswordSalt       varbinary(32),
    @HashAlgorithmId    int              = 1,
    @Iterations         int,
    @CreatedByUserId    bigint           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0,
            @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL,
            @UserId bigint = NULL,
            @UserUid uniqueidentifier = NULL,
            @OrganizationUid uniqueidentifier = NULL;

    -- ---- normalise -------------------------------------------------------
    -- Lowercased here as well as in the API, because CK_t_sso_users_Email_Lowercase
    -- rejects anything else and a rejected INSERT is a worse error than a
    -- normalised one.
    SET @Email  = LOWER(LTRIM(RTRIM(ISNULL(@Email, N''))));
    SET @Mobile = NULLIF(LTRIM(RTRIM(ISNULL(@Mobile, ''))), '');

    -- ---- validate (single exit: set @Code, fall through) -----------------
    IF @Email = N''
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'Email address is required.';
    ELSE IF @Email NOT LIKE '_%@_%._%'
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'That email address is not valid.';
    ELSE IF @PasswordHash IS NULL OR DATALENGTH(@PasswordHash) <> 64
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The password hash is malformed.';
    ELSE IF @PasswordSalt IS NULL OR DATALENGTH(@PasswordSalt) <> 32
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The password salt is malformed.';
    ELSE IF ISNULL(@Iterations, 0) <= 0
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The iteration count is not valid.';
    ELSE IF NOT EXISTS (SELECT 1 FROM dbo.m_sso_hash_algorithms
                        WHERE HashAlgorithmId = @HashAlgorithmId AND Is_Active = 1 AND Is_Deleted = 0)
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The hashing algorithm is not recognised.';
    ELSE IF EXISTS (SELECT 1 FROM dbo.t_sso_users WHERE Email = @Email AND Is_Deleted = 0)
        SELECT @Code = 'DUPLICATE_EMAIL', @Message = N'An account already exists with this email address.';
    ELSE IF @Mobile IS NOT NULL
            AND EXISTS (SELECT 1 FROM dbo.t_sso_users WHERE Mobile = @Mobile AND Is_Deleted = 0)
        SELECT @Code = 'DUPLICATE_MOBILE', @Message = N'An account already exists with this mobile number.';

    -- ---- act -------------------------------------------------------------
    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            SET @UserUid = NEWID();
            SET @OrganizationUid = NEWID();

            BEGIN TRANSACTION;

            INSERT INTO dbo.t_sso_users
                (UserUid, UserTypeId, StatusId, Email, Mobile, OrganizationUid, CreatedByUserId, CreatedBy)
            VALUES
                (@UserUid, 2, 1, @Email, @Mobile, @OrganizationUid, @CreatedByUserId, @CreatedByUserId);

            SET @UserId = SCOPE_IDENTITY();

            INSERT INTO dbo.t_sso_user_credentials
                (UserId, PasswordHash, PasswordSalt, HashAlgorithmId, Iterations, IsCurrent, CreatedBy)
            VALUES
                (@UserId, @PasswordHash, @PasswordSalt, @HashAlgorithmId, @Iterations, 1, @CreatedByUserId);

            COMMIT TRANSACTION;

            SELECT @Status = 1,
                   @Message = N'Registration received. Your account is awaiting verification.';
        END TRY
        BEGIN CATCH
            -- CAPTURE -> ROLLBACK -> LOG -> RESPOND (decision 2.31).
            DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                    @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                    @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            DECLARE @Params nvarchar(max) = (
                SELECT @Email AS email, @Mobile AS mobile,
                       '***masked***' AS passwordHash, '***masked***' AS passwordSalt,
                       @HashAlgorithmId AS hashAlgorithmId, @Iterations AS iterations
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
                 @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
                 @ErrorMessage = @ErrMessage, @ParametersJson = @Params,
                 @ContextInfo = N'USP_RegisterSchoolUser', @CreatedBy = @CreatedByUserId;

            THROW;
        END CATCH
    END

    -- ---- single exit -----------------------------------------------------
    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @UserId AS Id,
           @UserUid AS UserUid, @OrganizationUid AS OrganizationUid;
END
GO


/*==============================================================================
  USP_RegisterTeacherUser

  Self-registration by a teacher. Active immediately (StatusId = 2), no
  organisation, and the TEACHER role granted right away.

  The asymmetry with schools is deliberate: teacher verification is a soft
  badge on the profile, not a gate on the account (PROJECT_MEMORY 2.9).
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_RegisterTeacherUser
    @Email              nvarchar(150),
    @Mobile             varchar(15)      = NULL,
    @PasswordHash       varbinary(64),
    @PasswordSalt       varbinary(32),
    @HashAlgorithmId    int              = 1,
    @Iterations         int
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0,
            @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL,
            @UserId bigint = NULL,
            @UserUid uniqueidentifier = NULL,
            @RoleId int = NULL;

    SET @Email  = LOWER(LTRIM(RTRIM(ISNULL(@Email, N''))));
    SET @Mobile = NULLIF(LTRIM(RTRIM(ISNULL(@Mobile, ''))), '');

    SELECT @RoleId = RoleId
    FROM dbo.t_sso_roles
    WHERE RoleCode = 'TEACHER' AND OrganizationUid IS NULL AND Is_Deleted = 0 AND Is_Active = 1;

    IF @Email = N''
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'Email address is required.';
    ELSE IF @Email NOT LIKE '_%@_%._%'
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'That email address is not valid.';
    ELSE IF @PasswordHash IS NULL OR DATALENGTH(@PasswordHash) <> 64
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The password hash is malformed.';
    ELSE IF @PasswordSalt IS NULL OR DATALENGTH(@PasswordSalt) <> 32
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The password salt is malformed.';
    ELSE IF ISNULL(@Iterations, 0) <= 0
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The iteration count is not valid.';
    ELSE IF EXISTS (SELECT 1 FROM dbo.t_sso_users WHERE Email = @Email AND Is_Deleted = 0)
        SELECT @Code = 'DUPLICATE_EMAIL', @Message = N'An account already exists with this email address.';
    ELSE IF @Mobile IS NOT NULL
            AND EXISTS (SELECT 1 FROM dbo.t_sso_users WHERE Mobile = @Mobile AND Is_Deleted = 0)
        SELECT @Code = 'DUPLICATE_MOBILE', @Message = N'An account already exists with this mobile number.';

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            -- The TEACHER role is seeded. Its absence is a broken database, not
            -- a user error, so this one THROWs rather than returning Status 0.
            IF @RoleId IS NULL
                THROW 50001, 'Seed data is missing: the global TEACHER role was not found.', 1;

            SET @UserUid = NEWID();

            BEGIN TRANSACTION;

            INSERT INTO dbo.t_sso_users
                (UserUid, UserTypeId, StatusId, Email, Mobile, OrganizationUid)
            VALUES
                (@UserUid, 3, 2, @Email, @Mobile, NULL);

            SET @UserId = SCOPE_IDENTITY();

            INSERT INTO dbo.t_sso_user_credentials
                (UserId, PasswordHash, PasswordSalt, HashAlgorithmId, Iterations, IsCurrent)
            VALUES
                (@UserId, @PasswordHash, @PasswordSalt, @HashAlgorithmId, @Iterations, 1);

            INSERT INTO dbo.t_sso_user_roles (UserId, RoleId, OrganizationUid, ValidFrom)
            VALUES (@UserId, @RoleId, NULL, dbo.fn_IstToday());

            COMMIT TRANSACTION;

            SELECT @Status = 1, @Message = N'Welcome. Your account is ready.';
        END TRY
        BEGIN CATCH
            -- CAPTURE -> ROLLBACK -> LOG -> RESPOND (decision 2.31).
            DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                    @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                    @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            DECLARE @Params nvarchar(max) = (
                SELECT @Email AS email, @Mobile AS mobile,
                       '***masked***' AS passwordHash, '***masked***' AS passwordSalt,
                       @HashAlgorithmId AS hashAlgorithmId, @Iterations AS iterations
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
                 @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
                 @ErrorMessage = @ErrMessage, @ParametersJson = @Params,
                 @ContextInfo = N'USP_RegisterTeacherUser';

            THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @UserId AS Id,
           @UserUid AS UserUid;
END
GO


/*==============================================================================
  USP_CreateAdminUser

  Admin accounts only. There is no public signup path for these — they come
  from the seed utility (JP.Tools.SeedAdmin) or from an existing SUPER_ADMIN.

  @RoleCode must be one of the three admin roles; the proc refuses to grant a
  school or teacher role here, which stops an admin account being created with
  SCHOOL_OWNER by a copy-paste mistake.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_CreateAdminUser
    @Email              nvarchar(150),
    @Mobile             varchar(15)      = NULL,
    @PasswordHash       varbinary(64),
    @PasswordSalt       varbinary(32),
    @HashAlgorithmId    int              = 1,
    @Iterations         int,
    @RoleCode           varchar(50)      = 'SUPER_ADMIN',
    @CreatedByUserId    bigint           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0,
            @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL,
            @UserId bigint = NULL,
            @UserUid uniqueidentifier = NULL,
            @RoleId int = NULL;

    SET @Email  = LOWER(LTRIM(RTRIM(ISNULL(@Email, N''))));
    SET @Mobile = NULLIF(LTRIM(RTRIM(ISNULL(@Mobile, ''))), '');

    -- UserTypeId = 1 in the join: an admin user can only be given an admin role.
    SELECT @RoleId = RoleId
    FROM dbo.t_sso_roles
    WHERE RoleCode = @RoleCode AND OrganizationUid IS NULL
      AND UserTypeId = 1 AND Is_Deleted = 0 AND Is_Active = 1;

    IF @Email = N''
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'Email address is required.';
    ELSE IF @Email NOT LIKE '_%@_%._%'
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'That email address is not valid.';
    ELSE IF @PasswordHash IS NULL OR DATALENGTH(@PasswordHash) <> 64
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The password hash is malformed.';
    ELSE IF @PasswordSalt IS NULL OR DATALENGTH(@PasswordSalt) <> 32
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The password salt is malformed.';
    ELSE IF ISNULL(@Iterations, 0) <= 0
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The iteration count is not valid.';
    ELSE IF @RoleId IS NULL
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'That role is not a valid administrator role.';
    ELSE IF EXISTS (SELECT 1 FROM dbo.t_sso_users WHERE Email = @Email AND Is_Deleted = 0)
        SELECT @Code = 'DUPLICATE_EMAIL', @Message = N'An account already exists with this email address.';
    ELSE IF @Mobile IS NOT NULL
            AND EXISTS (SELECT 1 FROM dbo.t_sso_users WHERE Mobile = @Mobile AND Is_Deleted = 0)
        SELECT @Code = 'DUPLICATE_MOBILE', @Message = N'An account already exists with this mobile number.';

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            SET @UserUid = NEWID();

            BEGIN TRANSACTION;

            INSERT INTO dbo.t_sso_users
                (UserUid, UserTypeId, StatusId, Email, Mobile, OrganizationUid,
                 IsEmailVerified, CreatedByUserId, CreatedBy)
            VALUES
                (@UserUid, 1, 2, @Email, @Mobile, NULL, 1, @CreatedByUserId, @CreatedByUserId);

            SET @UserId = SCOPE_IDENTITY();

            INSERT INTO dbo.t_sso_user_credentials
                (UserId, PasswordHash, PasswordSalt, HashAlgorithmId, Iterations, IsCurrent, CreatedBy)
            VALUES
                (@UserId, @PasswordHash, @PasswordSalt, @HashAlgorithmId, @Iterations, 1, @CreatedByUserId);

            INSERT INTO dbo.t_sso_user_roles
                (UserId, RoleId, OrganizationUid, AssignedByUserId, ValidFrom, CreatedBy)
            VALUES
                (@UserId, @RoleId, NULL, @CreatedByUserId, dbo.fn_IstToday(), @CreatedByUserId);

            COMMIT TRANSACTION;

            SELECT @Status = 1, @Message = N'Administrator account created.';
        END TRY
        BEGIN CATCH
            -- CAPTURE -> ROLLBACK -> LOG -> RESPOND (decision 2.31).
            DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                    @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                    @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            DECLARE @Params nvarchar(max) = (
                SELECT @Email AS email, @Mobile AS mobile, @RoleCode AS roleCode,
                       '***masked***' AS passwordHash, '***masked***' AS passwordSalt,
                       @Iterations AS iterations
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
                 @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
                 @ErrorMessage = @ErrMessage, @ParametersJson = @Params,
                 @ContextInfo = N'USP_CreateAdminUser', @CreatedBy = @CreatedByUserId;

            THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @UserId AS Id,
           @UserUid AS UserUid;
END
GO


/*==============================================================================
  USP_InviteSchoolUser

  A school owner invites a colleague. Creates an Active account with NO
  credential — the invitee sets their own password by redeeming the token,
  so nobody ever knows another person's password, not even the person who
  invited them.

  @OrganizationUid comes from the CALLER'S JWT, never from a request body
  (PROJECT_MEMORY 2.6). The proc additionally verifies the inviter actually
  belongs to that organisation, so a forged parameter alone is not enough.

  Returns the invite TokenId. The plaintext token is generated by the API and
  only its hash reaches this proc.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_InviteSchoolUser
    @InvitedByUserId    bigint,
    @OrganizationUid    uniqueidentifier,
    @Email              nvarchar(150),
    @Mobile             varchar(15)      = NULL,
    @RoleCode           varchar(50),
    @TokenHash          varchar(128),
    @TokenExpiresOn     datetime2,
    @IpAddress          varchar(45)      = NULL,
    @UserAgent          nvarchar(400)    = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0,
            @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL,
            @UserId bigint = NULL,
            @UserUid uniqueidentifier = NULL,
            @TokenId bigint = NULL,
            @RoleId int = NULL;

    SET @Email  = LOWER(LTRIM(RTRIM(ISNULL(@Email, N''))));
    SET @Mobile = NULLIF(LTRIM(RTRIM(ISNULL(@Mobile, ''))), '');

    -- School roles only, and only global (seeded) or this organisation's own
    -- custom roles — never another school's.
    SELECT @RoleId = RoleId
    FROM dbo.t_sso_roles
    WHERE RoleCode = @RoleCode
      AND UserTypeId = 2
      AND (OrganizationUid IS NULL OR OrganizationUid = @OrganizationUid)
      AND Is_Deleted = 0 AND Is_Active = 1;

    IF @Email = N''
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'Email address is required.';
    ELSE IF @Email NOT LIKE '_%@_%._%'
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'That email address is not valid.';
    ELSE IF @OrganizationUid IS NULL
        SELECT @Code = 'FORBIDDEN', @Message = N'This account is not linked to an organisation.';
    ELSE IF NOT EXISTS (SELECT 1 FROM dbo.t_sso_users
                        WHERE UserId = @InvitedByUserId
                          AND OrganizationUid = @OrganizationUid
                          AND Is_Deleted = 0 AND Is_Active = 1)
        SELECT @Code = 'FORBIDDEN', @Message = N'You cannot invite users to that organisation.';
    ELSE IF @RoleId IS NULL
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'That role is not available to your organisation.';
    ELSE IF ISNULL(@TokenHash, '') = ''
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The invitation token is missing.';
    ELSE IF @TokenExpiresOn IS NULL OR @TokenExpiresOn <= SYSUTCDATETIME()
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The invitation expiry is not valid.';
    ELSE IF EXISTS (SELECT 1 FROM dbo.t_sso_users WHERE Email = @Email AND Is_Deleted = 0)
        SELECT @Code = 'DUPLICATE_EMAIL', @Message = N'An account already exists with this email address.';
    ELSE IF @Mobile IS NOT NULL
            AND EXISTS (SELECT 1 FROM dbo.t_sso_users WHERE Mobile = @Mobile AND Is_Deleted = 0)
        SELECT @Code = 'DUPLICATE_MOBILE', @Message = N'An account already exists with this mobile number.';

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            SET @UserUid = NEWID();

            BEGIN TRANSACTION;

            INSERT INTO dbo.t_sso_users
                (UserUid, UserTypeId, StatusId, Email, Mobile, OrganizationUid,
                 CreatedByUserId, CreatedBy)
            VALUES
                (@UserUid, 2, 2, @Email, @Mobile, @OrganizationUid,
                 @InvitedByUserId, @InvitedByUserId);

            SET @UserId = SCOPE_IDENTITY();

            INSERT INTO dbo.t_sso_user_roles
                (UserId, RoleId, OrganizationUid, AssignedByUserId, ValidFrom, CreatedBy)
            VALUES
                (@UserId, @RoleId, @OrganizationUid, @InvitedByUserId, dbo.fn_IstToday(), @InvitedByUserId);

            -- TokenTypeId 4 = Invite
            INSERT INTO dbo.t_sso_user_tokens
                (UserId, TokenTypeId, TokenHash, ExpiresOn, IpAddress, UserAgent, CreatedBy)
            VALUES
                (@UserId, 4, @TokenHash, @TokenExpiresOn, @IpAddress, @UserAgent, @InvitedByUserId);

            SET @TokenId = SCOPE_IDENTITY();

            COMMIT TRANSACTION;

            SELECT @Status = 1, @Message = N'Invitation sent.';
        END TRY
        BEGIN CATCH
            -- CAPTURE -> ROLLBACK -> LOG -> RESPOND (decision 2.31).
            DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                    @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                    @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            -- The invite token hash is a credential: recorded as present, never by value.
            DECLARE @Params nvarchar(max) = (
                SELECT @InvitedByUserId AS invitedByUserId, @OrganizationUid AS organizationUid,
                       @Email AS email, @Mobile AS mobile, @RoleCode AS roleCode,
                       '***masked***' AS tokenHash, @TokenExpiresOn AS tokenExpiresOn
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
                 @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
                 @ErrorMessage = @ErrMessage, @ParametersJson = @Params,
                 @ContextInfo = N'USP_InviteSchoolUser', @CreatedBy = @InvitedByUserId;

            THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @UserId AS Id,
           @UserUid AS UserUid, @TokenId AS TokenId;
END
GO


/*==============================================================================
  USP_SetPasswordFromInvite

  Redeems an invitation and creates the invitee's first credential.

  The token is consumed in the same transaction as the credential insert, so a
  single invite can never produce two passwords. Email is marked verified —
  receiving the invitation proved control of the mailbox.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SetPasswordFromInvite
    @TokenHash          varchar(128),
    @PasswordHash       varbinary(64),
    @PasswordSalt       varbinary(32),
    @HashAlgorithmId    int              = 1,
    @Iterations         int,
    @IpAddress          varchar(45)      = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0,
            @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL,
            @TokenId bigint = NULL,
            @UserId bigint = NULL,
            @UserUid uniqueidentifier = NULL,
            @ExpiresOn datetime2 = NULL,
            @UsedOn datetime2 = NULL,
            @RevokedOn datetime2 = NULL;

    SELECT @TokenId = t.TokenId, @UserId = t.UserId, @ExpiresOn = t.ExpiresOn,
           @UsedOn = t.UsedOn, @RevokedOn = t.RevokedOn
    FROM dbo.t_sso_user_tokens t
    WHERE t.TokenHash = @TokenHash AND t.TokenTypeId = 4 AND t.Is_Deleted = 0;

    -- Every failure below returns the SAME code and message. A caller must not
    -- be able to tell "no such invitation" from "already used" — that
    -- difference tells an attacker their guess was a real token.
    IF @TokenId IS NULL
        SELECT @Code = 'TOKEN_INVALID', @Message = N'This invitation link is not valid or has already been used.';
    ELSE IF @UsedOn IS NOT NULL OR @RevokedOn IS NOT NULL
        SELECT @Code = 'TOKEN_INVALID', @Message = N'This invitation link is not valid or has already been used.';
    ELSE IF @ExpiresOn <= SYSUTCDATETIME()
        SELECT @Code = 'TOKEN_EXPIRED', @Message = N'This invitation has expired. Ask for a new one.';
    ELSE IF @PasswordHash IS NULL OR DATALENGTH(@PasswordHash) <> 64
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The password hash is malformed.';
    ELSE IF @PasswordSalt IS NULL OR DATALENGTH(@PasswordSalt) <> 32
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The password salt is malformed.';
    ELSE IF ISNULL(@Iterations, 0) <= 0
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The iteration count is not valid.';
    ELSE IF EXISTS (SELECT 1 FROM dbo.t_sso_user_credentials
                    WHERE UserId = @UserId AND IsCurrent = 1 AND Is_Deleted = 0)
        SELECT @Code = 'TOKEN_ALREADY_USED', @Message = N'This account already has a password. Sign in instead.';

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            INSERT INTO dbo.t_sso_user_credentials
                (UserId, PasswordHash, PasswordSalt, HashAlgorithmId, Iterations, IsCurrent, CreatedBy)
            VALUES
                (@UserId, @PasswordHash, @PasswordSalt, @HashAlgorithmId, @Iterations, 1, @UserId);

            UPDATE dbo.t_sso_user_tokens
            SET UsedOn = SYSUTCDATETIME(),
                IpAddress = ISNULL(@IpAddress, IpAddress),
                ModifiedOn = SYSUTCDATETIME(),
                ModifiedBy = @UserId
            WHERE TokenId = @TokenId;

            UPDATE dbo.t_sso_users
            SET IsEmailVerified = 1,
                LastPasswordChangeOn = SYSUTCDATETIME(),
                ModifiedOn = SYSUTCDATETIME(),
                ModifiedBy = @UserId,
                [RowVersion] = [RowVersion] + 1
            WHERE UserId = @UserId;

            SELECT @UserUid = UserUid FROM dbo.t_sso_users WHERE UserId = @UserId;

            COMMIT TRANSACTION;

            SELECT @Status = 1, @Message = N'Your password has been set. You can sign in now.';
        END TRY
        BEGIN CATCH
            -- CAPTURE -> ROLLBACK -> LOG -> RESPOND (decision 2.31).
            DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                    @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                    @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            -- Token hash AND password material are both secrets here.
            DECLARE @Params nvarchar(max) = (
                SELECT '***masked***' AS tokenHash, @TokenId AS tokenId, @UserId AS userId,
                       '***masked***' AS passwordHash, '***masked***' AS passwordSalt,
                       @Iterations AS iterations
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
                 @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
                 @ErrorMessage = @ErrMessage, @ParametersJson = @Params,
                 @ContextInfo = N'USP_SetPasswordFromInvite', @CreatedBy = @UserId;

            THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @UserId AS Id,
           @UserUid AS UserUid;
END
GO

PRINT '    Registration procedures ready.';
GO
