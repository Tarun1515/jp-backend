/*==============================================================================
  jp_sso — 99_tests / 001_test_sso_procedures.sql

  Behavioural tests for the Phase 1B procedures.

  ---------------------------------------------------------------------------
  HOW TO RUN
  ---------------------------------------------------------------------------
      sqlcmd -S localhost\TARUN -E -b -f 65001 -i database\jp_sso\99_tests\001_test_sso_procedures.sql

  Everything runs inside ONE transaction which is ALWAYS rolled back, so the
  suite leaves no trace and can be run against a database with real data in it.
  The final assertion checks the user count is unchanged.

  Exits non-zero when anything fails, so it can gate a build.

  ---------------------------------------------------------------------------
  A NOTE ON MULTI-RESULT-SET PROCEDURES
  ---------------------------------------------------------------------------
  INSERT ... EXEC requires every result set a procedure returns to match the
  target table. USP_GetUserClaims and USP_GetUserByUid return two and three
  sets respectively, so they are exercised by EXEC (proving they run and their
  plans are valid) and their FILTERING is asserted with queries that mirror
  their predicates. Those assertions are marked [mirror].
==============================================================================*/

USE jp_sso;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

SET NOCOUNT ON;
SET XACT_ABORT OFF;   -- an assertion failure must not abort the run
GO

/*------------------------------------------------------------------------------
  Harness
------------------------------------------------------------------------------*/
-- The assertion log is declared as a TABLE VARIABLE inside the run batch
-- below, not here — see the comment there.

-- Result-shape capture tables, one per distinct procedure signature.
IF OBJECT_ID('tempdb..#RegSchool') IS NOT NULL DROP TABLE #RegSchool;
CREATE TABLE #RegSchool (Status int, Code varchar(50), Message nvarchar(400), Id bigint, UserUid uniqueidentifier, OrganizationUid uniqueidentifier);

IF OBJECT_ID('tempdb..#RegUser') IS NOT NULL DROP TABLE #RegUser;
CREATE TABLE #RegUser (Status int, Code varchar(50), Message nvarchar(400), Id bigint, UserUid uniqueidentifier);

IF OBJECT_ID('tempdb..#Invite') IS NOT NULL DROP TABLE #Invite;
CREATE TABLE #Invite (Status int, Code varchar(50), Message nvarchar(400), Id bigint, UserUid uniqueidentifier, TokenId bigint);

IF OBJECT_ID('tempdb..#Attempt') IS NOT NULL DROP TABLE #Attempt;
CREATE TABLE #Attempt (Status int, Code varchar(50), Message nvarchar(400), Id bigint, FailedAttemptCount int, IsLocked bit, UnlockOn datetime2);

IF OBJECT_ID('tempdb..#Simple') IS NOT NULL DROP TABLE #Simple;
CREATE TABLE #Simple (Status int, Code varchar(50), Message nvarchar(400), Id bigint);

IF OBJECT_ID('tempdb..#Rotate') IS NOT NULL DROP TABLE #Rotate;
CREATE TABLE #Rotate (Status int, Code varchar(50), Message nvarchar(400), Id bigint, ReuseDetected bit, RevokedCount int);

IF OBJECT_ID('tempdb..#Revoke') IS NOT NULL DROP TABLE #Revoke;
CREATE TABLE #Revoke (Status int, Code varchar(50), Message nvarchar(400), Id bigint, RevokedCount int);

IF OBJECT_ID('tempdb..#ResetTok') IS NOT NULL DROP TABLE #ResetTok;
CREATE TABLE #ResetTok (Status int, Code varchar(50), Message nvarchar(400), Id bigint, UserId bigint);

IF OBJECT_ID('tempdb..#ChangePwd') IS NOT NULL DROP TABLE #ChangePwd;
CREATE TABLE #ChangePwd (Status int, Code varchar(50), Message nvarchar(400), Id bigint, RevokedTokenCount int);

IF OBJECT_ID('tempdb..#Otp') IS NOT NULL DROP TABLE #Otp;
CREATE TABLE #Otp (Status int, Code varchar(50), Message nvarchar(400), Id bigint, AttemptCount int, AttemptsRemaining int);

IF OBJECT_ID('tempdb..#StatusUpd') IS NOT NULL DROP TABLE #StatusUpd;
CREATE TABLE #StatusUpd (Status int, Code varchar(50), Message nvarchar(400), Id bigint, RevokedTokenCount int, RoleGranted bit);

IF OBJECT_ID('tempdb..#Unlock') IS NOT NULL DROP TABLE #Unlock;
CREATE TABLE #Unlock (Status int, Code varchar(50), Message nvarchar(400), Id bigint, LockoutsCleared int, RestoredStatusId int);

IF OBJECT_ID('tempdb..#RemoveRole') IS NOT NULL DROP TABLE #RemoveRole;
CREATE TABLE #RemoveRole (Status int, Code varchar(50), Message nvarchar(400), Id bigint, RemovedCount int);

IF OBJECT_ID('tempdb..#Login') IS NOT NULL DROP TABLE #Login;
CREATE TABLE #Login (
    UserId bigint, UserUid uniqueidentifier, UserTypeId int, StatusId int,
    Email nvarchar(150), Mobile varchar(15), IsEmailVerified bit, IsMobileVerified bit,
    OrganizationUid uniqueidentifier, FailedAttemptCount int, LastLoginOn datetime2,
    LastPasswordChangeOn datetime2, [RowVersion] int,
    CredentialId bigint, PasswordHash varbinary(64), PasswordSalt varbinary(32),
    HashAlgorithmId int, Iterations int, CredentialExpiresOn datetime2,
    LockoutId bigint, LockReasonId int, LockedOn datetime2, UnlockOn datetime2,
    PreviousStatusId int, IsLocked bit, EffectiveStatusId int);

IF OBJECT_ID('tempdb..#TokenChk') IS NOT NULL DROP TABLE #TokenChk;
CREATE TABLE #TokenChk (
    TokenId bigint, UserId bigint, ExpiresOn datetime2, UsedOn datetime2, RevokedOn datetime2,
    ReplacedByTokenId bigint, UserUid uniqueidentifier, StatusId int, UserTypeId int,
    OrganizationUid uniqueidentifier, IsValid bit, IsReuseAttempt bit);
GO

/*==============================================================================
  RUN
==============================================================================*/
-- A TABLE VARIABLE, not a temp table: changes to table variables are NOT
-- undone by ROLLBACK, so the assertion log survives the rollback that discards
-- all the test data. A #temp table here silently loses every result.
DECLARE @Assert TABLE (Seq int IDENTITY(1,1), Area varchar(30), Name nvarchar(120),
                       Passed bit, Detail nvarchar(400));

DECLARE @UsersBefore int = (SELECT COUNT(*) FROM dbo.t_sso_users);

DECLARE @H  varbinary(64) = CAST(REPLICATE('a', 64) AS varbinary(64));
DECLARE @H2 varbinary(64) = CAST(REPLICATE('z', 64) AS varbinary(64));
DECLARE @S  varbinary(32) = CAST(REPLICATE('b', 32) AS varbinary(32));
DECLARE @Now datetime2 = SYSUTCDATETIME();

DECLARE @SchoolUserId bigint, @SchoolUid uniqueidentifier, @SchoolOrgUid uniqueidentifier,
        @TeacherUserId bigint, @TeacherUid uniqueidentifier,
        @AdminUserId bigint, @AdminUid uniqueidentifier,
        @HrUserId bigint, @HrUid uniqueidentifier, @InviteTokenId bigint,
        @RowVer int, @n int, @i int, @ResetTokenId bigint;

BEGIN TRANSACTION;

/*------------------------------------------------------------------------------
  1. REGISTRATION
------------------------------------------------------------------------------*/
DELETE FROM #RegSchool;
INSERT INTO #RegSchool
EXEC dbo.USP_RegisterSchoolUser
     @Email = N'Test.School@Example.COM',   -- deliberately mixed case
     @Mobile = '9990000101', @PasswordHash = @H, @PasswordSalt = @S,
     @HashAlgorithmId = 1, @Iterations = 210000;

SELECT @SchoolUserId = Id, @SchoolUid = UserUid, @SchoolOrgUid = OrganizationUid FROM #RegSchool;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'registration', 'school registers successfully',
       CASE WHEN Status = 1 AND Id IS NOT NULL AND OrganizationUid IS NOT NULL THEN 1 ELSE 0 END,
       CONCAT('Status=', Status, ' Code=', ISNULL(Code,'<null>')) FROM #RegSchool;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'registration', 'school starts at StatusId 1 (PendingApproval)',
       CASE WHEN StatusId = 1 THEN 1 ELSE 0 END, CONCAT('StatusId=', StatusId)
FROM dbo.t_sso_users WHERE UserId = @SchoolUserId;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'registration', 'email stored lowercased',
       CASE WHEN Email COLLATE Latin1_General_BIN2 = N'test.school@example.com' THEN 1 ELSE 0 END,
       Email FROM dbo.t_sso_users WHERE UserId = @SchoolUserId;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'registration', 'school gets NO role until approved',
       CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END, CONCAT('roles=', COUNT(*))
FROM dbo.t_sso_user_roles WHERE UserId = @SchoolUserId AND Is_Deleted = 0;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'registration', 'exactly one current credential created',
       CASE WHEN COUNT(*) = 1 THEN 1 ELSE 0 END, CONCAT('current=', COUNT(*))
FROM dbo.t_sso_user_credentials WHERE UserId = @SchoolUserId AND IsCurrent = 1;

-- duplicate email
DELETE FROM #RegSchool;
INSERT INTO #RegSchool
EXEC dbo.USP_RegisterSchoolUser @Email = N'test.school@example.com', @PasswordHash = @H,
     @PasswordSalt = @S, @Iterations = 210000;
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'registration', 'duplicate email returns Status 0 / DUPLICATE_EMAIL',
       CASE WHEN Status = 0 AND Code = 'DUPLICATE_EMAIL' THEN 1 ELSE 0 END,
       CONCAT('Status=', Status, ' Code=', ISNULL(Code,'<null>')) FROM #RegSchool;

-- malformed email
DELETE FROM #RegSchool;
INSERT INTO #RegSchool
EXEC dbo.USP_RegisterSchoolUser @Email = N'not-an-email', @PasswordHash = @H,
     @PasswordSalt = @S, @Iterations = 210000;
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'registration', 'malformed email rejected as VALIDATION_FAILED',
       CASE WHEN Status = 0 AND Code = 'VALIDATION_FAILED' THEN 1 ELSE 0 END,
       ISNULL(Code,'<null>') FROM #RegSchool;

-- wrong hash length
DELETE FROM #RegSchool;
INSERT INTO #RegSchool
EXEC dbo.USP_RegisterSchoolUser @Email = N'shorthash@example.com',
     @PasswordHash = 0x41, @PasswordSalt = @S, @Iterations = 210000;
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'registration', 'wrong hash length rejected before any insert',
       CASE WHEN Status = 0 AND Code = 'VALIDATION_FAILED' THEN 1 ELSE 0 END,
       ISNULL(Code,'<null>') FROM #RegSchool;

-- teacher
DELETE FROM #RegUser;
INSERT INTO #RegUser
EXEC dbo.USP_RegisterTeacherUser @Email = N'teacher@example.com', @Mobile = '9990000102',
     @PasswordHash = @H, @PasswordSalt = @S, @Iterations = 210000;
SELECT @TeacherUserId = Id, @TeacherUid = UserUid FROM #RegUser;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'registration', 'teacher is Active immediately (StatusId 2)',
       CASE WHEN StatusId = 2 THEN 1 ELSE 0 END, CONCAT('StatusId=', StatusId)
FROM dbo.t_sso_users WHERE UserId = @TeacherUserId;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'registration', 'teacher gets TEACHER role immediately',
       CASE WHEN COUNT(*) = 1 THEN 1 ELSE 0 END, CONCAT('roles=', COUNT(*))
FROM dbo.t_sso_user_roles ur JOIN dbo.t_sso_roles r ON r.RoleId = ur.RoleId
WHERE ur.UserId = @TeacherUserId AND r.RoleCode = 'TEACHER' AND ur.Is_Deleted = 0;

-- admin
DELETE FROM #RegUser;
INSERT INTO #RegUser
EXEC dbo.USP_CreateAdminUser @Email = N'admin@example.com', @PasswordHash = @H,
     @PasswordSalt = @S, @Iterations = 210000, @RoleCode = 'SUPER_ADMIN';
SELECT @AdminUserId = Id, @AdminUid = UserUid FROM #RegUser;
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'registration', 'admin created with SUPER_ADMIN',
       CASE WHEN Status = 1 THEN 1 ELSE 0 END, ISNULL(Code,'<null>') FROM #RegUser;

-- admin proc refuses a school role
DELETE FROM #RegUser;
INSERT INTO #RegUser
EXEC dbo.USP_CreateAdminUser @Email = N'admin2@example.com', @PasswordHash = @H,
     @PasswordSalt = @S, @Iterations = 210000, @RoleCode = 'SCHOOL_OWNER';
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'registration', 'admin proc refuses a non-admin role',
       CASE WHEN Status = 0 AND Code = 'VALIDATION_FAILED' THEN 1 ELSE 0 END,
       ISNULL(Code,'<null>') FROM #RegUser;

/*------------------------------------------------------------------------------
  2. LOGIN LOOKUP AND LOCKOUT
------------------------------------------------------------------------------*/
DELETE FROM #Login;
INSERT INTO #Login EXEC dbo.USP_GetUserForLogin @LoginIdentifier = N'TEST.SCHOOL@EXAMPLE.COM';
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'login', 'lookup by email (mixed case) returns the user + credential',
       CASE WHEN COUNT(*) = 1 AND MAX(CASE WHEN PasswordHash IS NOT NULL THEN 1 ELSE 0 END) = 1
            THEN 1 ELSE 0 END, CONCAT('rows=', COUNT(*)) FROM #Login;

DELETE FROM #Login;
INSERT INTO #Login EXEC dbo.USP_GetUserForLogin @LoginIdentifier = N'9990000101';
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'login', 'lookup by mobile returns the user',
       CASE WHEN COUNT(*) = 1 THEN 1 ELSE 0 END, CONCAT('rows=', COUNT(*)) FROM #Login;

DELETE FROM #Login;
INSERT INTO #Login EXEC dbo.USP_GetUserForLogin @LoginIdentifier = N'nobody@example.com';
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'login', 'unknown identifier returns EMPTY set (no enumeration)',
       CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END, CONCAT('rows=', COUNT(*)) FROM #Login;

-- five failures -> lockout, on the PENDING school so status preservation is tested
SET @i = 1;
WHILE @i <= 5
BEGIN
    DELETE FROM #Attempt;
    INSERT INTO #Attempt
    EXEC dbo.USP_RecordLoginAttempt @UserId = @SchoolUserId, @LoginIdentifier = N'test.school@example.com',
         @IpAddress = '10.0.0.1', @IsSuccess = 0, @FailureReason = 'INVALID_PASSWORD';
    SET @i = @i + 1;
END

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'lockout', '5th failure reports the lock on the attempt that caused it',
       CASE WHEN IsLocked = 1 AND Code = 'ACCOUNT_LOCKED' THEN 1 ELSE 0 END,
       CONCAT('IsLocked=', IsLocked, ' Code=', ISNULL(Code,'<null>')) FROM #Attempt;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'lockout', 'account moved to StatusId 5 (Locked)',
       CASE WHEN StatusId = 5 THEN 1 ELSE 0 END, CONCAT('StatusId=', StatusId)
FROM dbo.t_sso_users WHERE UserId = @SchoolUserId;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'lockout', 'lockout row records PreviousStatusId = 1 (was Pending)',
       CASE WHEN PreviousStatusId = 1 THEN 1 ELSE 0 END,
       CONCAT('PreviousStatusId=', ISNULL(CAST(PreviousStatusId AS varchar(3)), '<null>'))
FROM dbo.t_sso_user_lockouts WHERE UserId = @SchoolUserId AND UnlockedOn IS NULL;

DELETE FROM #Login;
INSERT INTO #Login EXEC dbo.USP_GetUserForLogin @LoginIdentifier = N'test.school@example.com';
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'lockout', 'GetUserForLogin reports IsLocked = 1',
       CASE WHEN IsLocked = 1 THEN 1 ELSE 0 END, CONCAT('IsLocked=', IsLocked) FROM #Login;

-- Age the lock so it has expired, then a successful login must restore PENDING.
-- LockedOn moves back too: CK_t_sso_user_lockouts_UnlockOn requires
-- UnlockOn > LockedOn, so backdating only UnlockOn is rejected — correctly.
UPDATE dbo.t_sso_user_lockouts
SET LockedOn = DATEADD(MINUTE, -60, SYSUTCDATETIME()),
    UnlockOn = DATEADD(MINUTE, -30, SYSUTCDATETIME())
WHERE UserId = @SchoolUserId AND UnlockedOn IS NULL;

DELETE FROM #Login;
INSERT INTO #Login EXEC dbo.USP_GetUserForLogin @LoginIdentifier = N'test.school@example.com';
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'lockout', 'expired lock: EffectiveStatusId reports 1, not 5',
       CASE WHEN IsLocked = 0 AND EffectiveStatusId = 1 THEN 1 ELSE 0 END,
       CONCAT('IsLocked=', IsLocked, ' Effective=', EffectiveStatusId) FROM #Login;

DELETE FROM #Attempt;
INSERT INTO #Attempt
EXEC dbo.USP_RecordLoginAttempt @UserId = @SchoolUserId, @LoginIdentifier = N'test.school@example.com',
     @IsSuccess = 1;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'lockout', 'successful login restores PendingApproval — NOT Active',
       CASE WHEN StatusId = 1 THEN 1 ELSE 0 END, CONCAT('StatusId=', StatusId)
FROM dbo.t_sso_users WHERE UserId = @SchoolUserId;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'lockout', 'failure counter reset to 0 on success',
       CASE WHEN FailedAttemptCount = 0 THEN 1 ELSE 0 END, CONCAT('count=', FailedAttemptCount)
FROM dbo.t_sso_users WHERE UserId = @SchoolUserId;

/*------------------------------------------------------------------------------
  2b. ADMIN ACTS WHILE THE ACCOUNT IS LOCKED

  The hole that decision 018 opened, and the reason USP_UpdateUserStatus NULLs
  PreviousStatusId:

      Pending -> 5 failures -> locked (PreviousStatusId = 1)
      admin REJECTS while locked   -> StatusId = 3
      lock expires, user signs in  -> must STAY 3, not revert to Pending

  Uses a second school so the earlier assertions are untouched.
------------------------------------------------------------------------------*/
DECLARE @S2UserId bigint, @S2Uid uniqueidentifier, @S2RowVer int;

DELETE FROM #RegSchool;
INSERT INTO #RegSchool
EXEC dbo.USP_RegisterSchoolUser @Email = N'reject.while.locked@example.com',
     @PasswordHash = @H, @PasswordSalt = @S, @Iterations = 210000;
SELECT @S2UserId = Id, @S2Uid = UserUid FROM #RegSchool;

SET @i = 1;
WHILE @i <= 5
BEGIN
    DELETE FROM #Attempt;
    INSERT INTO #Attempt
    EXEC dbo.USP_RecordLoginAttempt @UserId = @S2UserId,
         @LoginIdentifier = N'reject.while.locked@example.com',
         @IsSuccess = 0, @FailureReason = 'INVALID_PASSWORD';
    SET @i = @i + 1;
END

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'supersede', 'locked with PreviousStatusId = 1 recorded',
       CASE WHEN COUNT(*) = 1 THEN 1 ELSE 0 END, CONCAT('rows=', COUNT(*))
FROM dbo.t_sso_user_lockouts
WHERE UserId = @S2UserId AND UnlockedOn IS NULL AND PreviousStatusId = 1;

-- Admin rejects WHILE the account is locked.
SELECT @S2RowVer = [RowVersion] FROM dbo.t_sso_users WHERE UserId = @S2UserId;
DELETE FROM #StatusUpd;
INSERT INTO #StatusUpd
EXEC dbo.USP_UpdateUserStatus @UserUid = @S2Uid, @NewStatusId = 3, @RowVersion = @S2RowVer,
     @ActionByUserId = @AdminUserId, @Remarks = N'Documents could not be verified.';

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'supersede', 'admin can reject an account that is currently locked',
       CASE WHEN Status = 1 THEN 1 ELSE 0 END, ISNULL(Code,'<null>') FROM #StatusUpd;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'supersede', 'admin action NULLs PreviousStatusId on the live lockout',
       CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END,
       CONCAT('rows still carrying a restore target=', COUNT(*))
FROM dbo.t_sso_user_lockouts
WHERE UserId = @S2UserId AND UnlockedOn IS NULL AND PreviousStatusId IS NOT NULL;

-- Age the lock out, then sign in successfully.
UPDATE dbo.t_sso_user_lockouts
SET LockedOn = DATEADD(MINUTE, -60, SYSUTCDATETIME()),
    UnlockOn = DATEADD(MINUTE, -30, SYSUTCDATETIME())
WHERE UserId = @S2UserId AND UnlockedOn IS NULL;

DELETE FROM #Login;
INSERT INTO #Login EXEC dbo.USP_GetUserForLogin @LoginIdentifier = N'reject.while.locked@example.com';
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'supersede', 'EffectiveStatusId reports Rejected (3), not Pending',
       CASE WHEN EffectiveStatusId = 3 THEN 1 ELSE 0 END,
       CONCAT('Effective=', EffectiveStatusId) FROM #Login;

DELETE FROM #Attempt;
INSERT INTO #Attempt
EXEC dbo.USP_RecordLoginAttempt @UserId = @S2UserId,
     @LoginIdentifier = N'reject.while.locked@example.com', @IsSuccess = 1;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'supersede', 'THE FIX: rejection survives the lock expiring (StatusId stays 3)',
       CASE WHEN StatusId = 3 THEN 1 ELSE 0 END, CONCAT('StatusId=', StatusId)
FROM dbo.t_sso_users WHERE UserId = @S2UserId;

/*------------------------------------------------------------------------------
  3. CLAIMS
------------------------------------------------------------------------------*/
EXEC dbo.USP_GetUserClaims @UserId = @TeacherUserId;    -- smoke: must execute
EXEC dbo.USP_GetUserByUid  @UserUid = @TeacherUid;      -- smoke: must execute

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'claims', '[mirror] teacher resolves to 2 permissions (PROFILE.EDIT, JOB.VIEW)',
       CASE WHEN COUNT(DISTINCT p.PermissionCode) = 2 THEN 1 ELSE 0 END,
       CONCAT('perms=', COUNT(DISTINCT p.PermissionCode))
FROM dbo.t_sso_user_roles ur
JOIN dbo.t_sso_roles r ON r.RoleId = ur.RoleId AND r.Is_Deleted = 0 AND r.Is_Active = 1
JOIN dbo.t_sso_role_permissions rp ON rp.RoleId = r.RoleId AND rp.Is_Deleted = 0 AND rp.Is_Active = 1
JOIN dbo.t_sso_permissions p ON p.PermissionId = rp.PermissionId AND p.Is_Deleted = 0 AND p.Is_Active = 1
WHERE ur.UserId = @TeacherUserId AND ur.Is_Deleted = 0 AND ur.Is_Active = 1
  AND ur.ValidFrom <= dbo.fn_IstToday()
  AND (ur.ValidTo IS NULL OR ur.ValidTo >= dbo.fn_IstToday());

-- Expire the grant: it must drop out. ValidFrom moves back as well, because
-- CK_t_sso_user_roles_ValidRange requires ValidTo >= ValidFrom.
UPDATE dbo.t_sso_user_roles
SET ValidFrom = DATEADD(DAY, -10, dbo.fn_IstToday()),
    ValidTo   = DATEADD(DAY,  -1, dbo.fn_IstToday())
WHERE UserId = @TeacherUserId;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'claims', '[mirror] role expired yesterday (IST) is excluded',
       CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END, CONCAT('roles=', COUNT(*))
FROM dbo.t_sso_user_roles ur
WHERE ur.UserId = @TeacherUserId AND ur.Is_Deleted = 0 AND ur.Is_Active = 1
  AND ur.ValidFrom <= dbo.fn_IstToday()
  AND (ur.ValidTo IS NULL OR ur.ValidTo >= dbo.fn_IstToday());

UPDATE dbo.t_sso_user_roles
SET ValidFrom = dbo.fn_IstToday(), ValidTo = NULL
WHERE UserId = @TeacherUserId;

/*------------------------------------------------------------------------------
  4. REFRESH TOKENS AND REUSE DETECTION
------------------------------------------------------------------------------*/
DELETE FROM #Simple;
INSERT INTO #Simple
EXEC dbo.USP_SaveRefreshToken @UserId = @TeacherUserId, @TokenHash = 'hash-token-1',
     @ExpiresOn = '2099-01-01', @IpAddress = '10.0.0.9';
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'tokens', 'refresh token issued', CASE WHEN Status = 1 THEN 1 ELSE 0 END,
       ISNULL(Code,'<null>') FROM #Simple;

DELETE FROM #TokenChk;
INSERT INTO #TokenChk EXEC dbo.USP_ValidateRefreshToken @TokenHash = 'hash-token-1';
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'tokens', 'fresh token validates as IsValid = 1',
       CASE WHEN IsValid = 1 AND IsReuseAttempt = 0 THEN 1 ELSE 0 END,
       CONCAT('IsValid=', IsValid) FROM #TokenChk;

DELETE FROM #Rotate;
INSERT INTO #Rotate
EXEC dbo.USP_RotateRefreshToken @UserId = @TeacherUserId, @OldTokenHash = 'hash-token-1',
     @NewTokenHash = 'hash-token-2', @NewExpiresOn = '2099-01-01';
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'tokens', 'rotation succeeds', CASE WHEN Status = 1 THEN 1 ELSE 0 END,
       ISNULL(Code,'<null>') FROM #Rotate;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'tokens', 'old token consumed, revoked and chained to its replacement',
       CASE WHEN UsedOn IS NOT NULL AND RevokedOn IS NOT NULL AND ReplacedByTokenId IS NOT NULL
            THEN 1 ELSE 0 END, 'chain link set'
FROM dbo.t_sso_user_tokens WHERE TokenHash = 'hash-token-1';

-- replay the already-consumed token: the whole chain must burn
DELETE FROM #Rotate;
INSERT INTO #Rotate
EXEC dbo.USP_RotateRefreshToken @UserId = @TeacherUserId, @OldTokenHash = 'hash-token-1',
     @NewTokenHash = 'hash-token-3', @NewExpiresOn = '2099-01-01';
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'tokens', 'REUSE DETECTED on replay of a consumed token',
       CASE WHEN Status = 0 AND Code = 'TOKEN_REVOKED' AND ReuseDetected = 1 THEN 1 ELSE 0 END,
       CONCAT('Code=', ISNULL(Code,'<null>'), ' Reuse=', ReuseDetected) FROM #Rotate;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'tokens', 'entire chain revoked, including the still-good newest token',
       CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END, CONCAT('live tokens=', COUNT(*))
FROM dbo.t_sso_user_tokens
WHERE UserId = @TeacherUserId AND TokenTypeId = 1 AND RevokedOn IS NULL;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'tokens', 'no replacement token minted during a reuse attempt',
       CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END, CONCAT('token3=', COUNT(*))
FROM dbo.t_sso_user_tokens WHERE TokenHash = 'hash-token-3';

/*------------------------------------------------------------------------------
  5. PASSWORD
------------------------------------------------------------------------------*/
DELETE FROM #ChangePwd;
INSERT INTO #ChangePwd
EXEC dbo.USP_ChangePassword @UserId = @TeacherUserId, @PasswordHash = @H2,
     @PasswordSalt = @S, @Iterations = 210000, @ChangedByUserId = @TeacherUserId;
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'password', 'password change succeeds', CASE WHEN Status = 1 THEN 1 ELSE 0 END,
       ISNULL(Code,'<null>') FROM #ChangePwd;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'password', 'still exactly one current credential after change',
       CASE WHEN COUNT(*) = 1 THEN 1 ELSE 0 END, CONCAT('current=', COUNT(*))
FROM dbo.t_sso_user_credentials WHERE UserId = @TeacherUserId AND IsCurrent = 1;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'password', 'old credential retained as history (IsCurrent = 0)',
       CASE WHEN COUNT(*) = 1 THEN 1 ELSE 0 END, CONCAT('history=', COUNT(*))
FROM dbo.t_sso_user_credentials WHERE UserId = @TeacherUserId AND IsCurrent = 0;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'password', 'LastPasswordChangeOn stamped',
       CASE WHEN LastPasswordChangeOn IS NOT NULL THEN 1 ELSE 0 END, 'stamped'
FROM dbo.t_sso_users WHERE UserId = @TeacherUserId;

-- reset-link flow
DELETE FROM #ResetTok;
INSERT INTO #ResetTok
EXEC dbo.USP_CreatePasswordResetToken @Email = N'teacher@example.com',
     @TokenHash = 'reset-hash-1', @ExpiresOn = '2099-01-01';
SELECT @ResetTokenId = Id FROM #ResetTok;
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'password', 'reset token issued for a known address',
       CASE WHEN Status = 1 AND UserId IS NOT NULL THEN 1 ELSE 0 END,
       ISNULL(Code,'<null>') FROM #ResetTok;

DELETE FROM #ResetTok;
INSERT INTO #ResetTok
EXEC dbo.USP_CreatePasswordResetToken @Email = N'ghost@example.com',
     @TokenHash = 'reset-hash-ghost', @ExpiresOn = '2099-01-01';
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'password', 'unknown address still returns Status 1 with UserId NULL (no oracle)',
       CASE WHEN Status = 1 AND UserId IS NULL AND Id IS NULL THEN 1 ELSE 0 END,
       CONCAT('Status=', Status, ' UserId=', ISNULL(CAST(UserId AS varchar(20)),'<null>')) FROM #ResetTok;

DELETE FROM #ChangePwd;
INSERT INTO #ChangePwd
EXEC dbo.USP_ChangePassword @UserId = @TeacherUserId, @PasswordHash = @H,
     @PasswordSalt = @S, @Iterations = 210000, @ResetTokenHash = 'reset-hash-1';
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'password', 'password change via reset link succeeds',
       CASE WHEN Status = 1 THEN 1 ELSE 0 END, ISNULL(Code,'<null>') FROM #ChangePwd;

DELETE FROM #ChangePwd;
INSERT INTO #ChangePwd
EXEC dbo.USP_ChangePassword @UserId = @TeacherUserId, @PasswordHash = @H2,
     @PasswordSalt = @S, @Iterations = 210000, @ResetTokenHash = 'reset-hash-1';
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'password', 'consumed reset link cannot be reused',
       CASE WHEN Status = 0 AND Code = 'TOKEN_ALREADY_USED' THEN 1 ELSE 0 END,
       ISNULL(Code,'<null>') FROM #ChangePwd;

/*------------------------------------------------------------------------------
  6. OTP
------------------------------------------------------------------------------*/
DELETE FROM #Simple;
INSERT INTO #Simple
EXEC dbo.USP_SaveOtp @UserId = @TeacherUserId, @OtpChannelId = 1, @OtpHash = 'otp-hash-1',
     @SentTo = N'teacher@example.com', @ExpiresOn = '2099-01-01';
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'otp', 'OTP issued', CASE WHEN Status = 1 THEN 1 ELSE 0 END, ISNULL(Code,'<null>') FROM #Simple;

DELETE FROM #Otp;
INSERT INTO #Otp EXEC dbo.USP_VerifyOtp @UserId = @TeacherUserId, @OtpChannelId = 1, @OtpHash = 'wrong';
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'otp', 'wrong code fails and consumes an attempt',
       CASE WHEN Status = 0 AND Code = 'OTP_INVALID' AND AttemptCount = 1 THEN 1 ELSE 0 END,
       CONCAT('Code=', ISNULL(Code,'<null>'), ' attempts=', AttemptCount) FROM #Otp;

SET @i = 1;
WHILE @i <= 4
BEGIN
    DELETE FROM #Otp;
    INSERT INTO #Otp EXEC dbo.USP_VerifyOtp @UserId = @TeacherUserId, @OtpChannelId = 1, @OtpHash = 'wrong';
    SET @i = @i + 1;
END
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'otp', 'attempt cap reached at 5 -> OTP_MAX_ATTEMPTS',
       CASE WHEN Code = 'OTP_MAX_ATTEMPTS' THEN 1 ELSE 0 END, ISNULL(Code,'<null>') FROM #Otp;

DELETE FROM #Otp;
INSERT INTO #Otp EXEC dbo.USP_VerifyOtp @UserId = @TeacherUserId, @OtpChannelId = 1, @OtpHash = 'otp-hash-1';
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'otp', 'correct code still refused once the cap is hit',
       CASE WHEN Status = 0 AND Code = 'OTP_MAX_ATTEMPTS' THEN 1 ELSE 0 END,
       ISNULL(Code,'<null>') FROM #Otp;

-- resend, then verify correctly
DELETE FROM #Simple;
INSERT INTO #Simple
EXEC dbo.USP_SaveOtp @UserId = @TeacherUserId, @OtpChannelId = 1, @OtpHash = 'otp-hash-2',
     @SentTo = N'teacher@example.com', @ExpiresOn = '2099-01-01';

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'otp', 'resend leaves exactly ONE live code for the channel',
       CASE WHEN COUNT(*) = 1 THEN 1 ELSE 0 END, CONCAT('live=', COUNT(*))
FROM dbo.t_sso_user_otps WHERE UserId = @TeacherUserId AND OtpChannelId = 1 AND Is_Deleted = 0;

DELETE FROM #Otp;
INSERT INTO #Otp EXEC dbo.USP_VerifyOtp @UserId = @TeacherUserId, @OtpChannelId = 1, @OtpHash = 'otp-hash-2';
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'otp', 'correct code on the fresh OTP verifies',
       CASE WHEN Status = 1 THEN 1 ELSE 0 END, ISNULL(Code,'<null>') FROM #Otp;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'otp', 'IsEmailVerified set on the user',
       CASE WHEN IsEmailVerified = 1 THEN 1 ELSE 0 END, CONCAT('verified=', IsEmailVerified)
FROM dbo.t_sso_users WHERE UserId = @TeacherUserId;

/*------------------------------------------------------------------------------
  7. ADMIN
------------------------------------------------------------------------------*/
SELECT @RowVer = [RowVersion] FROM dbo.t_sso_users WHERE UserId = @SchoolUserId;

DELETE FROM #StatusUpd;
INSERT INTO #StatusUpd
EXEC dbo.USP_UpdateUserStatus @UserUid = @SchoolUid, @NewStatusId = 2, @RowVersion = @RowVer,
     @ActionByUserId = @AdminUserId, @Remarks = N'Documents verified.';
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'admin', 'approval succeeds and grants SCHOOL_OWNER',
       CASE WHEN Status = 1 AND RoleGranted = 1 THEN 1 ELSE 0 END,
       CONCAT('Status=', Status, ' RoleGranted=', RoleGranted) FROM #StatusUpd;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'admin', 'approved school now holds SCHOOL_OWNER scoped to its org',
       CASE WHEN COUNT(*) = 1 THEN 1 ELSE 0 END, CONCAT('rows=', COUNT(*))
FROM dbo.t_sso_user_roles ur JOIN dbo.t_sso_roles r ON r.RoleId = ur.RoleId
WHERE ur.UserId = @SchoolUserId AND r.RoleCode = 'SCHOOL_OWNER'
  AND ur.OrganizationUid = @SchoolOrgUid AND ur.Is_Deleted = 0;

-- stale RowVersion
DELETE FROM #StatusUpd;
INSERT INTO #StatusUpd
EXEC dbo.USP_UpdateUserStatus @UserUid = @SchoolUid, @NewStatusId = 4, @RowVersion = @RowVer,
     @ActionByUserId = @AdminUserId;
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'admin', 'stale RowVersion rejected as CONCURRENCY_CONFLICT',
       CASE WHEN Status = 0 AND Code = 'CONCURRENCY_CONFLICT' THEN 1 ELSE 0 END,
       ISNULL(Code,'<null>') FROM #StatusUpd;

-- invite an HR colleague
DELETE FROM #Invite;
INSERT INTO #Invite
EXEC dbo.USP_InviteSchoolUser @InvitedByUserId = @SchoolUserId, @OrganizationUid = @SchoolOrgUid,
     @Email = N'hr@example.com', @RoleCode = 'HR', @TokenHash = 'invite-hash-1',
     @TokenExpiresOn = '2099-01-01';
SELECT @HrUserId = Id, @HrUid = UserUid, @InviteTokenId = TokenId FROM #Invite;
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'admin', 'HR invitation created with no credential',
       CASE WHEN Status = 1 AND TokenId IS NOT NULL THEN 1 ELSE 0 END,
       ISNULL(Code,'<null>') FROM #Invite;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'admin', 'invited user has no password until the invite is redeemed',
       CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END, CONCAT('credentials=', COUNT(*))
FROM dbo.t_sso_user_credentials WHERE UserId = @HrUserId;

-- invite from an organisation the caller does not belong to.
-- NEWID() cannot be passed inline: T-SQL only accepts a constant or a variable
-- as a procedure argument.
DECLARE @OtherOrgUid uniqueidentifier = NEWID();

DELETE FROM #Invite;
INSERT INTO #Invite
EXEC dbo.USP_InviteSchoolUser @InvitedByUserId = @SchoolUserId, @OrganizationUid = @OtherOrgUid,
     @Email = N'hr2@example.com', @RoleCode = 'HR', @TokenHash = 'invite-hash-2',
     @TokenExpiresOn = '2099-01-01';
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'admin', 'cannot invite into someone else''s organisation (IDOR)',
       CASE WHEN Status = 0 AND Code = 'FORBIDDEN' THEN 1 ELSE 0 END,
       ISNULL(Code,'<null>') FROM #Invite;

DELETE FROM #RegUser;
INSERT INTO #RegUser
EXEC dbo.USP_SetPasswordFromInvite @TokenHash = 'invite-hash-1', @PasswordHash = @H,
     @PasswordSalt = @S, @Iterations = 210000;
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'admin', 'invite redeemed and first password set',
       CASE WHEN Status = 1 THEN 1 ELSE 0 END, ISNULL(Code,'<null>') FROM #RegUser;

DELETE FROM #RegUser;
INSERT INTO #RegUser
EXEC dbo.USP_SetPasswordFromInvite @TokenHash = 'invite-hash-1', @PasswordHash = @H2,
     @PasswordSalt = @S, @Iterations = 210000;
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'admin', 'invite cannot be redeemed twice',
       CASE WHEN Status = 0 THEN 1 ELSE 0 END, ISNULL(Code,'<null>') FROM #RegUser;

-- suspend
SELECT @RowVer = [RowVersion] FROM dbo.t_sso_users WHERE UserId = @HrUserId;
DELETE FROM #Simple;
INSERT INTO #Simple EXEC dbo.USP_SaveRefreshToken @UserId = @HrUserId,
     @TokenHash = 'hr-token-1', @ExpiresOn = '2099-01-01';

DELETE FROM #StatusUpd;
INSERT INTO #StatusUpd
EXEC dbo.USP_UpdateUserStatus @UserUid = @HrUid, @NewStatusId = 4, @RowVersion = @RowVer,
     @ActionByUserId = @AdminUserId, @Remarks = N'Policy breach.';
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'admin', 'suspension revokes live tokens',
       CASE WHEN Status = 1 AND RevokedTokenCount >= 1 THEN 1 ELSE 0 END,
       CONCAT('revoked=', RevokedTokenCount) FROM #StatusUpd;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'admin', 'suspension writes an audit lockout row (reason 2)',
       CASE WHEN COUNT(*) = 1 THEN 1 ELSE 0 END, CONCAT('rows=', COUNT(*))
FROM dbo.t_sso_user_lockouts WHERE UserId = @HrUserId AND LockReasonId = 2;

-- roles
DELETE FROM #Simple;
INSERT INTO #Simple
EXEC dbo.USP_AssignUserRole @UserUid = @HrUid, @RoleCode = 'SENIOR_HR',
     @OrganizationUid = @SchoolOrgUid, @AssignedByUserId = @SchoolUserId;
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'admin', 'role assigned', CASE WHEN Status = 1 THEN 1 ELSE 0 END,
       ISNULL(Code,'<null>') FROM #Simple;

DELETE FROM #Simple;
INSERT INTO #Simple
EXEC dbo.USP_AssignUserRole @UserUid = @HrUid, @RoleCode = 'SENIOR_HR',
     @OrganizationUid = @SchoolOrgUid, @AssignedByUserId = @SchoolUserId;
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'admin', 'duplicate role assignment refused',
       CASE WHEN Status = 0 AND Code = 'DUPLICATE_RECORD' THEN 1 ELSE 0 END,
       ISNULL(Code,'<null>') FROM #Simple;

DELETE FROM #Simple;
INSERT INTO #Simple
EXEC dbo.USP_AssignUserRole @UserUid = @HrUid, @RoleCode = 'TEACHER',
     @OrganizationUid = @SchoolOrgUid, @AssignedByUserId = @SchoolUserId;
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'admin', 'teacher role refused on a school account',
       CASE WHEN Status = 0 THEN 1 ELSE 0 END, ISNULL(Code,'<null>') FROM #Simple;

DELETE FROM #RemoveRole;
INSERT INTO #RemoveRole
EXEC dbo.USP_RemoveUserRole @UserUid = @HrUid, @RoleCode = 'SENIOR_HR',
     @OrganizationUid = @SchoolOrgUid, @RemovedByUserId = @SchoolUserId;
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'admin', 'role removed by soft delete',
       CASE WHEN Status = 1 AND RemovedCount = 1 THEN 1 ELSE 0 END,
       CONCAT('removed=', RemovedCount) FROM #RemoveRole;

-- unlock
DELETE FROM #Unlock;
INSERT INTO #Unlock EXEC dbo.USP_UnlockUser @UserUid = @HrUid, @ActionByUserId = @AdminUserId;
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'admin', 'manual unlock clears the lockout rows',
       CASE WHEN Status = 1 AND LockoutsCleared >= 1 THEN 1 ELSE 0 END,
       CONCAT('cleared=', LockoutsCleared) FROM #Unlock;

/*------------------------------------------------------------------------------
  8. LISTS
------------------------------------------------------------------------------*/
/*
  USP_GetUserList returns TWO result sets (page, then total), so INSERT ... EXEC
  cannot capture it — the shapes differ. It is therefore exercised by EXEC, and
  its filtering is asserted with [mirror] queries using the same
  fn_IstDateToUtc boundary maths the procedure performs.
*/
DECLARE @IstToday date = dbo.fn_IstToday();

EXEC dbo.USP_GetUserList @UserTypeId = 2, @FromDate = @IstToday, @ToDate = @IstToday, @PageNumber = 1, @PageSize = 50;

-- The assertion that would fail if the UTC/IST conversion were wrong: rows
-- created seconds ago must fall inside "today" in IST. Between 18:30 and 24:00
-- UTC these rows belong to TOMORROW in UTC terms but still today in IST.
DECLARE @FromUtc datetime2 = dbo.fn_IstDateToUtc(@IstToday);
DECLARE @ToUtc   datetime2 = dbo.fn_IstDateToUtc(DATEADD(DAY, 1, @IstToday));

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'lists', '[mirror] IST "today" range includes rows created just now',
       CASE WHEN COUNT(*) >= 2 THEN 1 ELSE 0 END,
       CONCAT('rows=', COUNT(*), ' window=', CONVERT(varchar(30), @FromUtc, 126),
              ' .. ', CONVERT(varchar(30), @ToUtc, 126))
FROM dbo.t_sso_users
WHERE UserTypeId = 2 AND Is_Deleted = 0
  AND CreatedOn >= @FromUtc AND CreatedOn < @ToUtc;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'lists', '[mirror] IST day window is exactly 24 hours, half-open',
       CASE WHEN DATEDIFF(MINUTE, @FromUtc, @ToUtc) = 1440 THEN 1 ELSE 0 END,
       CONCAT('minutes=', DATEDIFF(MINUTE, @FromUtc, @ToUtc));

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'lists', '[mirror] org scoping matches only that organisation',
       CASE WHEN COUNT(*) = 2 THEN 1 ELSE 0 END, CONCAT('rows=', COUNT(*))
FROM dbo.t_sso_users WHERE OrganizationUid = @SchoolOrgUid AND Is_Deleted = 0;

IF OBJECT_ID('tempdb..#Perms') IS NOT NULL DROP TABLE #Perms;
CREATE TABLE #Perms (PermissionId int, PermissionCode varchar(50), PermissionName nvarchar(150),
                     ModuleId int, ModuleCode varchar(30), ModuleName nvarchar(150),
                     ModuleDisplayOrder int, DisplayOrder int);
INSERT INTO #Perms EXEC dbo.USP_GetPermissionList;
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'lists', 'permission catalogue returns all 23',
       CASE WHEN COUNT(*) = 23 THEN 1 ELSE 0 END, CONCAT('rows=', COUNT(*)) FROM #Perms;

IF OBJECT_ID('tempdb..#RolePerms') IS NOT NULL DROP TABLE #RolePerms;
CREATE TABLE #RolePerms (PermissionId int, PermissionCode varchar(50), PermissionName nvarchar(150),
                         ModuleId int, ModuleCode varchar(30), ModuleName nvarchar(150), IsGranted bit);
DECLARE @SuperAdminRoleId int = (SELECT RoleId FROM dbo.t_sso_roles
                                 WHERE RoleCode = 'SUPER_ADMIN' AND OrganizationUid IS NULL);
INSERT INTO #RolePerms EXEC dbo.USP_GetRolePermissions @RoleId = @SuperAdminRoleId;
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'lists', 'SUPER_ADMIN shows all 23 permissions granted',
       CASE WHEN SUM(CAST(IsGranted AS int)) = 23 THEN 1 ELSE 0 END,
       CONCAT('granted=', SUM(CAST(IsGranted AS int))) FROM #RolePerms;

EXEC dbo.USP_GetRoleList @OrganizationUid = @SchoolOrgUid;   -- smoke

/*------------------------------------------------------------------------------
  9. MAINTENANCE
------------------------------------------------------------------------------*/
DELETE FROM #Revoke;
INSERT INTO #Revoke EXEC dbo.USP_RevokeAllUserTokens @UserId = @HrUserId;
INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'tokens', 'revoke-all runs and reports a count',
       CASE WHEN Status = 1 THEN 1 ELSE 0 END, CONCAT('revoked=', RevokedCount) FROM #Revoke;

ROLLBACK TRANSACTION;

/*------------------------------------------------------------------------------
  REPORT
------------------------------------------------------------------------------*/
DECLARE @UsersAfter int = (SELECT COUNT(*) FROM dbo.t_sso_users);

INSERT INTO @Assert (Area, Name, Passed, Detail)
VALUES ('cleanup', 'rollback left no test rows behind',
        CASE WHEN @UsersBefore = @UsersAfter THEN 1 ELSE 0 END,
        CONCAT('before=', @UsersBefore, ' after=', @UsersAfter));

DECLARE @Passed int = (SELECT COUNT(*) FROM @Assert WHERE Passed = 1);
DECLARE @Failed int = (SELECT COUNT(*) FROM @Assert WHERE Passed = 0);

DECLARE @Line nvarchar(400), @Cur int = 1, @Max int = (SELECT MAX(Seq) FROM @Assert);

PRINT '';
PRINT '================================================================================';
PRINT ' jp_sso PROCEDURE TESTS';
PRINT '================================================================================';

WHILE @Cur <= @Max
BEGIN
    SELECT @Line = CONCAT(
        CASE WHEN Passed = 1 THEN '  PASS  ' ELSE '  FAIL  ' END,
        RIGHT('  ' + CAST(Seq AS varchar(3)), 3), '  [', Area, '] ', Name,
        CASE WHEN Passed = 1 THEN '' ELSE '   -> ' + ISNULL(Detail, '') END)
    FROM @Assert WHERE Seq = @Cur;

    IF @Line IS NOT NULL PRINT @Line;
    SET @Cur = @Cur + 1;
END

PRINT '--------------------------------------------------------------------------------';
PRINT CONCAT(' TOTAL ', @Passed + @Failed, '   PASSED ', @Passed, '   FAILED ', @Failed);
PRINT '================================================================================';
PRINT '';

IF @Failed > 0
    RAISERROR('%d test(s) failed.', 16, 1, @Failed);
GO
