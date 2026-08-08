/*==============================================================================
  jp_sso — 99_tests / 002_test_error_log.sql

  Proves the CATCH ordering rule from decision 2.31 actually works.

      sqlcmd -S localhost\TARUN -E -b -f 65001 -i database\jp_sso\99_tests\002_test_error_log.sql

  ---------------------------------------------------------------------------
  WHAT IS BEING PROVEN
  ---------------------------------------------------------------------------
  Two things, and the second is the one that matters:

      a) the failed transaction rolled back — no partial data survives
      b) the error log row EXISTS afterwards

  (b) is the whole exercise. It is what fails if USP_LogError is called BEFORE
  the ROLLBACK instead of after: the log INSERT is part of the doomed
  transaction and disappears with it. The test would still see a rolled-back
  transaction and could easily be written to pass on (a) alone — which is
  exactly how this bug survives in real systems.

  ---------------------------------------------------------------------------
  HOW THE FAILURE IS INDUCED
  ---------------------------------------------------------------------------
  A temporary AFTER INSERT trigger on t_sso_user_credentials that throws. That
  puts the error in the middle of USP_RegisterSchoolUser's transaction, after
  the user row is written but before COMMIT — precisely the shape of a real
  unexpected failure.

  ---------------------------------------------------------------------------
  WHY THIS SUITE DOES NOT WRAP EVERYTHING IN ONE TRANSACTION
  ---------------------------------------------------------------------------
  001_test_sso_procedures.sql wraps its work in a transaction and rolls back at
  the end. That is impossible here: the procedure under test performs its OWN
  ROLLBACK, which would destroy an enclosing transaction and take the log row
  with it — the very thing being tested. So this suite writes real rows and
  cleans up explicitly at the end.
==============================================================================*/

USE jp_sso;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

SET NOCOUNT ON;
GO

/*------------------------------------------------------------------------------
  A trigger that fails, to force an error mid-transaction.
------------------------------------------------------------------------------*/
IF OBJECT_ID('dbo.TR_TEST_FailCredentialInsert', 'TR') IS NOT NULL
    DROP TRIGGER dbo.TR_TEST_FailCredentialInsert;
GO

CREATE TRIGGER dbo.TR_TEST_FailCredentialInsert
ON dbo.t_sso_user_credentials
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;
    -- 50000+ so it looks like any other deliberate failure. Dropped at the end.
    THROW 50900, 'TEST: simulated failure inside the transaction.', 1;
END
GO

/*==============================================================================
  RUN
==============================================================================*/
DECLARE @Assert TABLE (Seq int IDENTITY(1,1), Name nvarchar(140), Passed bit, Detail nvarchar(400));

DECLARE @H varbinary(64) = CAST(REPLICATE('a', 64) AS varbinary(64));
DECLARE @S varbinary(32) = CAST(REPLICATE('b', 32) AS varbinary(32));
DECLARE @TestEmail nvarchar(150) = N'errorlog.probe@example.com';

DECLARE @LogCountBefore  int = (SELECT COUNT(*) FROM dbo.t_sso_error_log);
DECLARE @UserCountBefore int = (SELECT COUNT(*) FROM dbo.t_sso_users);
DECLARE @TranCountBefore int = @@TRANCOUNT;

DECLARE @Caught bit = 0, @CaughtNumber int = NULL, @CaughtMessage nvarchar(400) = NULL;

/*------------------------------------------------------------------------------
  Trigger the failure. The procedure opens a transaction, writes the user row,
  hits the trigger on the credential insert, and runs its CATCH.
------------------------------------------------------------------------------*/
/*
  PLAIN EXEC, deliberately — NOT `INSERT ... EXEC`.

  Inside an INSERT-EXEC, SQL Server forbids the called procedure from issuing a
  ROLLBACK and raises Msg 3915 instead. That aborts the CATCH block before
  USP_LogError is reached, so the log row is never written and the failure
  number reported to the caller is 3915 rather than the real one. The test
  harness would then be masking the exact behaviour under test.

  This matters beyond the test: any caller that wraps one of these procedures
  in INSERT-EXEC silently loses its error handling. BaseRepository uses Dapper,
  which does not, so production is unaffected — but it is a trap worth knowing.

  The failure path throws anyway, so there is no result set to capture here.
*/
BEGIN TRY
    EXEC dbo.USP_RegisterSchoolUser
         @Email = @TestEmail, @Mobile = '9990009999',
         @PasswordHash = @H, @PasswordSalt = @S, @Iterations = 210000;
END TRY
BEGIN CATCH
    SET @Caught = 1;
    SET @CaughtNumber = ERROR_NUMBER();
    SET @CaughtMessage = LEFT(ERROR_MESSAGE(), 300);

    -- The procedure already rolled back; INSERT-EXEC may leave this batch's
    -- transaction unusable, so make sure nothing is left open.
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
END CATCH

DECLARE @LogCountAfter  int = (SELECT COUNT(*) FROM dbo.t_sso_error_log);
DECLARE @UserCountAfter int = (SELECT COUNT(*) FROM dbo.t_sso_users);

/*------------------------------------------------------------------------------
  Assertions
------------------------------------------------------------------------------*/
INSERT INTO @Assert (Name, Passed, Detail)
VALUES ('the induced error actually reached the caller',
        CASE WHEN @Caught = 1 THEN 1 ELSE 0 END,
        CONCAT('caught=', @Caught, ' number=', ISNULL(CAST(@CaughtNumber AS varchar(12)), '<none>')));

INSERT INTO @Assert (Name, Passed, Detail)
VALUES ('THROW preserved the ORIGINAL error number (50900), not a rewrite',
        CASE WHEN @CaughtNumber = 50900 THEN 1 ELSE 0 END,
        CONCAT('number=', ISNULL(CAST(@CaughtNumber AS varchar(12)), '<none>')));

-- (a) the transaction rolled back
INSERT INTO @Assert (Name, Passed, Detail)
VALUES ('(a) ROLLBACK: no user row survived the failed transaction',
        CASE WHEN @UserCountAfter = @UserCountBefore THEN 1 ELSE 0 END,
        CONCAT('before=', @UserCountBefore, ' after=', @UserCountAfter));

INSERT INTO @Assert (Name, Passed, Detail)
SELECT '(a) ROLLBACK: the specific test email is absent',
       CASE WHEN COUNT(*) = 0 THEN 1 ELSE 0 END, CONCAT('rows=', COUNT(*))
FROM dbo.t_sso_users WHERE Email = @TestEmail;

INSERT INTO @Assert (Name, Passed, Detail)
VALUES ('no transaction left dangling',
        CASE WHEN @@TRANCOUNT = @TranCountBefore THEN 1 ELSE 0 END,
        CONCAT('trancount=', @@TRANCOUNT));

-- (b) THE ASSERTION THAT MATTERS: the log row outlived the rollback
INSERT INTO @Assert (Name, Passed, Detail)
VALUES ('(b) THE ERROR LOG ROW SURVIVED THE ROLLBACK',
        CASE WHEN @LogCountAfter = @LogCountBefore + 1 THEN 1 ELSE 0 END,
        CONCAT('before=', @LogCountBefore, ' after=', @LogCountAfter));

INSERT INTO @Assert (Name, Passed, Detail)
SELECT '(b) logged row carries the original error number',
       CASE WHEN ErrorNumber = 50900 THEN 1 ELSE 0 END,
       CONCAT('number=', ErrorNumber)
FROM dbo.t_sso_error_log WHERE ErrorLogId = (SELECT MAX(ErrorLogId) FROM dbo.t_sso_error_log);

/*
  ERROR_PROCEDURE() reports the INNERMOST module the error came from — here the
  trigger, not USP_RegisterSchoolUser which called it. That is correct and
  useful: it points at where the fault actually happened.

  It is also why ContextInfo exists. ERROR_PROCEDURE gives the origin;
  ContextInfo gives the entry point the caller invoked. Diagnosing a failure
  usually needs both, so both are stored.
*/
INSERT INTO @Assert (Name, Passed, Detail)
SELECT '(b) ErrorProcedure names the ORIGIN of the fault (the trigger)',
       CASE WHEN ErrorProcedure = 'TR_TEST_FailCredentialInsert' THEN 1 ELSE 0 END,
       CONCAT('proc=', ISNULL(ErrorProcedure, '<null>'), '  (ContextInfo has the entry point)')
FROM dbo.t_sso_error_log WHERE ErrorLogId = (SELECT MAX(ErrorLogId) FROM dbo.t_sso_error_log);

INSERT INTO @Assert (Name, Passed, Detail)
SELECT '(b) ErrorLine captured',
       CASE WHEN ErrorLine IS NOT NULL AND ErrorLine > 0 THEN 1 ELSE 0 END,
       CONCAT('line=', ISNULL(CAST(ErrorLine AS varchar(12)), '<null>'))
FROM dbo.t_sso_error_log WHERE ErrorLogId = (SELECT MAX(ErrorLogId) FROM dbo.t_sso_error_log);

INSERT INTO @Assert (Name, Passed, Detail)
SELECT '(b) session context captured (user, host, app)',
       CASE WHEN UserName IS NOT NULL AND AppName IS NOT NULL THEN 1 ELSE 0 END,
       CONCAT('user=', UserName, ' app=', LEFT(ISNULL(AppName,'<null>'), 30))
FROM dbo.t_sso_error_log WHERE ErrorLogId = (SELECT MAX(ErrorLogId) FROM dbo.t_sso_error_log);

INSERT INTO @Assert (Name, Passed, Detail)
SELECT '(b) ContextInfo names the failing procedure',
       CASE WHEN ContextInfo = N'USP_RegisterSchoolUser' THEN 1 ELSE 0 END,
       ISNULL(ContextInfo, '<null>')
FROM dbo.t_sso_error_log WHERE ErrorLogId = (SELECT MAX(ErrorLogId) FROM dbo.t_sso_error_log);

-- Masking
INSERT INTO @Assert (Name, Passed, Detail)
SELECT 'ParametersJson captured the reproducible inputs',
       CASE WHEN ParametersJson LIKE '%errorlog.probe@example.com%' THEN 1 ELSE 0 END,
       LEFT(ISNULL(ParametersJson, '<null>'), 200)
FROM dbo.t_sso_error_log WHERE ErrorLogId = (SELECT MAX(ErrorLogId) FROM dbo.t_sso_error_log);

INSERT INTO @Assert (Name, Passed, Detail)
SELECT 'ParametersJson MASKED the password hash and salt',
       CASE WHEN ParametersJson LIKE '%***masked***%'
             AND ParametersJson NOT LIKE '%aaaaaaaa%'
             AND ParametersJson NOT LIKE '%bbbbbbbb%'
            THEN 1 ELSE 0 END,
       LEFT(ISNULL(ParametersJson, '<null>'), 200)
FROM dbo.t_sso_error_log WHERE ErrorLogId = (SELECT MAX(ErrorLogId) FROM dbo.t_sso_error_log);

INSERT INTO @Assert (Name, Passed, Detail)
SELECT 'log row carries the standard columns (decision 2.4)',
       CASE WHEN Is_Active = 1 AND Is_Deleted = 0 AND CreatedOn IS NOT NULL THEN 1 ELSE 0 END,
       CONCAT('Is_Active=', Is_Active, ' Is_Deleted=', Is_Deleted)
FROM dbo.t_sso_error_log WHERE ErrorLogId = (SELECT MAX(ErrorLogId) FROM dbo.t_sso_error_log);

/*------------------------------------------------------------------------------
  Control: with the trigger gone, the same call must SUCCEED and log nothing.
  Without this, a proc that logged on every call would still pass everything
  above.
------------------------------------------------------------------------------*/
DROP TRIGGER dbo.TR_TEST_FailCredentialInsert;

DECLARE @LogCountControl int = (SELECT COUNT(*) FROM dbo.t_sso_error_log);
DECLARE @R2 TABLE (Status int, Code varchar(50), Message nvarchar(400), Id bigint,
                   UserUid uniqueidentifier, OrganizationUid uniqueidentifier);
DECLARE @NewUserId bigint = NULL, @ControlStatus int = NULL;

INSERT INTO @R2
EXEC dbo.USP_RegisterSchoolUser
     @Email = @TestEmail, @Mobile = '9990009999',
     @PasswordHash = @H, @PasswordSalt = @S, @Iterations = 210000;

SELECT @NewUserId = Id, @ControlStatus = Status FROM @R2;

INSERT INTO @Assert (Name, Passed, Detail)
VALUES ('control: same call succeeds once the fault is removed',
        CASE WHEN @ControlStatus = 1 AND @NewUserId IS NOT NULL THEN 1 ELSE 0 END,
        CONCAT('Status=', ISNULL(CAST(@ControlStatus AS varchar(3)),'<null>')));

INSERT INTO @Assert (Name, Passed, Detail)
VALUES ('control: a SUCCESSFUL call logs nothing',
        CASE WHEN (SELECT COUNT(*) FROM dbo.t_sso_error_log) = @LogCountControl THEN 1 ELSE 0 END,
        CONCAT('before=', @LogCountControl, ' after=', (SELECT COUNT(*) FROM dbo.t_sso_error_log)));

/*------------------------------------------------------------------------------
  Clean up. This suite writes real rows, so it removes them explicitly.
  Hard DELETE is correct here: these are test artefacts, not business records.
------------------------------------------------------------------------------*/
DELETE FROM dbo.t_sso_user_credentials WHERE UserId = @NewUserId;
DELETE FROM dbo.t_sso_user_roles       WHERE UserId = @NewUserId;
DELETE FROM dbo.t_sso_users            WHERE UserId = @NewUserId;
DELETE FROM dbo.t_sso_error_log        WHERE ErrorNumber = 50900 AND ContextInfo = N'USP_RegisterSchoolUser';

INSERT INTO @Assert (Name, Passed, Detail)
SELECT 'cleanup: no test rows left behind',
       CASE WHEN (SELECT COUNT(*) FROM dbo.t_sso_users WHERE Email = @TestEmail) = 0
             AND (SELECT COUNT(*) FROM dbo.t_sso_error_log) = @LogCountBefore
            THEN 1 ELSE 0 END,
       CONCAT('users=', (SELECT COUNT(*) FROM dbo.t_sso_users WHERE Email = @TestEmail),
              ' log=', (SELECT COUNT(*) FROM dbo.t_sso_error_log), ' (baseline ', @LogCountBefore, ')');

/*------------------------------------------------------------------------------
  Report
------------------------------------------------------------------------------*/
DECLARE @Passed int = (SELECT COUNT(*) FROM @Assert WHERE Passed = 1);
DECLARE @Failed int = (SELECT COUNT(*) FROM @Assert WHERE Passed = 0);
DECLARE @Line nvarchar(500), @Cur int = 1, @Max int = (SELECT MAX(Seq) FROM @Assert);

PRINT '';
PRINT '================================================================================';
PRINT ' ERROR LOG / ROLLBACK ORDERING TESTS';
PRINT '================================================================================';

WHILE @Cur <= @Max
BEGIN
    SELECT @Line = CONCAT(CASE WHEN Passed = 1 THEN '  PASS  ' ELSE '  FAIL  ' END,
                          RIGHT('  ' + CAST(Seq AS varchar(3)), 3), '  ', Name,
                          '   -> ', ISNULL(Detail, ''))
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

-- Belt and braces: the trigger must never outlive this script.
IF OBJECT_ID('dbo.TR_TEST_FailCredentialInsert', 'TR') IS NOT NULL
BEGIN
    DROP TRIGGER dbo.TR_TEST_FailCredentialInsert;
    RAISERROR('WARNING: the test trigger was still present and has been dropped.', 10, 1);
END
GO
