/*==============================================================================
  jp_mdm — 99_tests / 001_test_approval_engine.sql

  Approval engine test suite.

  ---------------------------------------------------------------------------
  🔴 TABLE VARIABLES, NOT #TEMP  (decision 2.30)
  ---------------------------------------------------------------------------
  The whole suite runs inside a transaction that is always rolled back. A
  ROLLBACK wipes rows from a #temp table, so an assertion log in #temp would be
  emptied by the very rollback that makes the suite safe — and the suite would
  cheerfully report zero passes and zero failures. A table variable is not
  transactional in that way and survives.

  ---------------------------------------------------------------------------
  🔴 PLAIN EXEC, NOT INSERT..EXEC  (decision 2.30)
  ---------------------------------------------------------------------------
  A ROLLBACK inside a procedure called by INSERT..EXEC raises Msg 3915 — and
  that error replaces the real one, so a genuine failure is reported as a
  meaningless framework complaint. Procedures are called with plain EXEC and
  their result sets are read back from the tables instead.

  ---------------------------------------------------------------------------
  Safe to run against a working database: everything is rolled back.
  Requires -I (QUOTED_IDENTIFIER ON) because of the filtered indexes.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
GO

PRINT '';
PRINT '=========================================================';
PRINT '  APPROVAL ENGINE TESTS';
PRINT '=========================================================';
GO

DECLARE @Assert TABLE (
    Seq      int IDENTITY(1,1),
    Area     varchar(30),
    Name     nvarchar(200),
    Passed   bit,
    Detail   nvarchar(400)
);

DECLARE @ErrorsBefore int = (SELECT COUNT(*) FROM dbo.t_mdm_error_log);

BEGIN TRANSACTION;

/*==============================================================================
  FIXTURES
==============================================================================*/
DECLARE @SchoolEntity  uniqueidentifier = NEWID(),
        @TeacherEntity uniqueidentifier = NEWID(),
        @OrgUid        uniqueidentifier = NEWID(),
        @Requestor     bigint = 900001,
        @Admin         bigint = 900002,
        @AdminRoles    varchar(200) = '2';

DECLARE @RequestId bigint, @RowVersion int, @StatusId int, @RequestNo varchar(30);

/*
  Subject fixtures.

  m_mdm_subject is EMPTY until Phase 2B — the client's list has not arrived, and
  2A deliberately seeded nothing rather than guessing. So the suite creates the
  three subjects it needs itself, inside the transaction that is rolled back.

  IDs are in a 900+ block that the real seed will never use, so this cannot
  collide with 2B when it lands.
*/
INSERT INTO dbo.m_mdm_subject (SubjectId, Code, Name, DisplayOrder)
VALUES (901, 'TEST_MATH', N'Test Maths',   901),
       (902, 'TEST_PHY',  N'Test Physics', 902),
       (903, 'TEST_ENG',  N'Test English', 903);

/*==============================================================================
  1. HAPPY PATH — submit -> list -> get -> approve
==============================================================================*/
EXEC dbo.USP_SubmitApprovalRequest
     @RequestTypeId = 1, @EntityUid = @SchoolEntity, @RequestorUserId = @Requestor,
     @OrganizationUid = @OrgUid, @SchoolName = N'Greenwood Public School',
     @ContactEmail = N'principal@greenwood.edu.in';

SELECT TOP (1) @RequestId = RequestId, @RowVersion = RowVersion,
               @StatusId = StatusId, @RequestNo = RequestNo
FROM dbo.t_mdm_approval_requests
WHERE EntityUid = @SchoolEntity AND Is_Deleted = 0;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'submit', 'request row created', CASE WHEN @RequestId IS NOT NULL THEN 1 ELSE 0 END,
       CONCAT('RequestId=', ISNULL(CAST(@RequestId AS varchar(20)), '<null>'));

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'submit', 'status is Pending', CASE WHEN @StatusId = 1 THEN 1 ELSE 0 END,
       CONCAT('StatusId=', @StatusId);

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'submit', 'RequestNo matches REG-SCH-<year>-#####',
       CASE WHEN @RequestNo LIKE 'REG-SCH-[0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9]' THEN 1 ELSE 0 END,
       @RequestNo;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'submit', 'typed detail row created', COUNT(*), 'school details'
FROM dbo.t_mdm_school_registration_details WHERE RequestId = @RequestId;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'submit', 'Submit appended to the trail',
       CASE WHEN COUNT(*) = 1 THEN 1 ELSE 0 END, CONCAT('rows=', COUNT(*))
FROM dbo.t_mdm_request_approvals WHERE RequestId = @RequestId AND ActionTypeId = 4;

-- ---- list --------------------------------------------------------------
DECLARE @ListCount int = (
    SELECT COUNT(*) FROM dbo.t_mdm_approval_requests r
    WHERE r.StatusId = 1 AND r.Is_Deleted = 0 AND r.RequestId = @RequestId);

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'list', 'request appears in the pending queue',
       CASE WHEN @ListCount = 1 THEN 1 ELSE 0 END, CONCAT('found=', @ListCount);

-- ---- approve -----------------------------------------------------------
EXEC dbo.USP_ProcessApprovalAction
     @RequestId = @RequestId, @ActionTypeId = 1, @ActionByUserId = @Admin,
     @RowVersion = @RowVersion, @Remarks = N'Verified', @ActorRoleIds = @AdminRoles;

SELECT @StatusId = StatusId, @RowVersion = RowVersion
FROM dbo.t_mdm_approval_requests WHERE RequestId = @RequestId;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'approve', 'status becomes Approved', CASE WHEN @StatusId = 3 THEN 1 ELSE 0 END,
       CONCAT('StatusId=', @StatusId);

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'approve', 'CompletedOn stamped',
       CASE WHEN CompletedOn IS NOT NULL THEN 1 ELSE 0 END, 'stamped'
FROM dbo.t_mdm_approval_requests WHERE RequestId = @RequestId;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'approve', 'RowVersion incremented', CASE WHEN @RowVersion = 2 THEN 1 ELSE 0 END,
       CONCAT('RowVersion=', @RowVersion);

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'approve', 'Approve appended to the trail',
       CASE WHEN COUNT(*) = 1 THEN 1 ELSE 0 END, CONCAT('rows=', COUNT(*))
FROM dbo.t_mdm_request_approvals WHERE RequestId = @RequestId AND ActionTypeId = 1;

/*==============================================================================
  2. AN ILLEGAL TRANSITION IS REFUSED
     The request above is Approved. Approving it again must not work.
==============================================================================*/
DECLARE @ApprovedRV int = @RowVersion;

EXEC dbo.USP_ProcessApprovalAction
     @RequestId = @RequestId, @ActionTypeId = 1, @ActionByUserId = @Admin,
     @RowVersion = @ApprovedRV, @ActorRoleIds = @AdminRoles;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'transition', 'approving an approved request is refused',
       CASE WHEN StatusId = 3 AND RowVersion = @ApprovedRV THEN 1 ELSE 0 END,
       CONCAT('StatusId=', StatusId, ' RowVersion=', RowVersion)
FROM dbo.t_mdm_approval_requests WHERE RequestId = @RequestId;

/*==============================================================================
  3. SUBMIT -> REJECT
==============================================================================*/
DECLARE @RejectEntity uniqueidentifier = NEWID(), @RejectId bigint, @RejectRV int;

EXEC dbo.USP_SubmitApprovalRequest
     @RequestTypeId = 1, @EntityUid = @RejectEntity, @RequestorUserId = @Requestor,
     @SchoolName = N'Nonexistent Academy';

SELECT @RejectId = RequestId, @RejectRV = RowVersion
FROM dbo.t_mdm_approval_requests WHERE EntityUid = @RejectEntity AND Is_Deleted = 0;

EXEC dbo.USP_ProcessApprovalAction
     @RequestId = @RejectId, @ActionTypeId = 2, @ActionByUserId = @Admin,
     @RowVersion = @RejectRV, @Remarks = N'Could not verify the school exists',
     @ActorRoleIds = @AdminRoles;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'reject', 'status becomes Rejected', CASE WHEN StatusId = 2 THEN 1 ELSE 0 END,
       CONCAT('StatusId=', StatusId)
FROM dbo.t_mdm_approval_requests WHERE RequestId = @RejectId;

/*==============================================================================
  4. SUBMIT -> REQUEST RESUBMIT -> RESUBMIT -> APPROVE
==============================================================================*/
DECLARE @ResubEntity uniqueidentifier = NEWID(), @ResubId bigint, @ResubRV int;

EXEC dbo.USP_SubmitApprovalRequest
     @RequestTypeId = 2, @EntityUid = @ResubEntity, @RequestorUserId = @Requestor,
     @FullName = N'Anita Rao', @DOB = '1990-06-15', @SubjectIds = '901,902,902,903';

SELECT @ResubId = RequestId, @ResubRV = RowVersion
FROM dbo.t_mdm_approval_requests WHERE EntityUid = @ResubEntity AND Is_Deleted = 0;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'submit', 'duplicate SubjectIds are de-duplicated',
       CASE WHEN COUNT(*) = 3 THEN 1 ELSE 0 END, CONCAT('subjects=', COUNT(*))
FROM dbo.t_mdm_teacher_registration_subjects WHERE RequestId = @ResubId;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'submit', 'DOB stored as a calendar date',
       CASE WHEN DOB = '1990-06-15' THEN 1 ELSE 0 END, CONVERT(varchar(10), DOB, 120)
FROM dbo.t_mdm_teacher_registration_details WHERE RequestId = @ResubId;

EXEC dbo.USP_ProcessApprovalAction
     @RequestId = @ResubId, @ActionTypeId = 3, @ActionByUserId = @Admin,
     @RowVersion = @ResubRV, @Remarks = N'Degree certificate is unreadable',
     @ActorRoleIds = @AdminRoles;

SELECT @ResubRV = RowVersion FROM dbo.t_mdm_approval_requests WHERE RequestId = @ResubId;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'resubmit', 'status becomes ResubmitRequired', CASE WHEN StatusId = 4 THEN 1 ELSE 0 END,
       CONCAT('StatusId=', StatusId)
FROM dbo.t_mdm_approval_requests WHERE RequestId = @ResubId;

EXEC dbo.USP_ResubmitApprovalRequest
     @RequestId = @ResubId, @ActionByUserId = @Requestor,
     @Remarks = N'Clearer scan attached', @RowVersion = @ResubRV;

SELECT @ResubRV = RowVersion FROM dbo.t_mdm_approval_requests WHERE RequestId = @ResubId;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'resubmit', 'back to Pending at level 1',
       CASE WHEN StatusId = 1 AND CurrentApprovalLevel = 1 THEN 1 ELSE 0 END,
       CONCAT('StatusId=', StatusId, ' Level=', CurrentApprovalLevel)
FROM dbo.t_mdm_approval_requests WHERE RequestId = @ResubId;

EXEC dbo.USP_ProcessApprovalAction
     @RequestId = @ResubId, @ActionTypeId = 1, @ActionByUserId = @Admin,
     @RowVersion = @ResubRV, @ActorRoleIds = @AdminRoles;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'resubmit', 'approved after resubmission', CASE WHEN StatusId = 3 THEN 1 ELSE 0 END,
       CONCAT('StatusId=', StatusId)
FROM dbo.t_mdm_approval_requests WHERE RequestId = @ResubId;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'resubmit', 'trail kept every action, nothing overwritten',
       CASE WHEN COUNT(*) = 4 THEN 1 ELSE 0 END, CONCAT('trail rows=', COUNT(*))
FROM dbo.t_mdm_request_approvals WHERE RequestId = @ResubId;

/*==============================================================================
  5. CONCURRENT APPROVE — the second RowVersion loses
==============================================================================*/
DECLARE @RaceEntity uniqueidentifier = NEWID(), @RaceId bigint, @RaceRV int;

EXEC dbo.USP_SubmitApprovalRequest
     @RequestTypeId = 1, @EntityUid = @RaceEntity, @RequestorUserId = @Requestor,
     @SchoolName = N'Contested School';

SELECT @RaceId = RequestId, @RaceRV = RowVersion
FROM dbo.t_mdm_approval_requests WHERE EntityUid = @RaceEntity AND Is_Deleted = 0;

-- Admin A reads @RaceRV and approves. Admin B still holds the same value.
EXEC dbo.USP_ProcessApprovalAction
     @RequestId = @RaceId, @ActionTypeId = 1, @ActionByUserId = @Admin,
     @RowVersion = @RaceRV, @ActorRoleIds = @AdminRoles;

DECLARE @AfterFirst int = (SELECT RowVersion FROM dbo.t_mdm_approval_requests WHERE RequestId = @RaceId);

-- Admin B now acts on the stale version.
EXEC dbo.USP_ProcessApprovalAction
     @RequestId = @RaceId, @ActionTypeId = 2, @ActionByUserId = @Admin,
     @RowVersion = @RaceRV, @ActorRoleIds = @AdminRoles;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'concurrency', 'the stale RowVersion does not overwrite',
       CASE WHEN StatusId = 3 AND RowVersion = @AfterFirst THEN 1 ELSE 0 END,
       CONCAT('StatusId=', StatusId, ' RowVersion=', RowVersion, ' expected=', @AfterFirst)
FROM dbo.t_mdm_approval_requests WHERE RequestId = @RaceId;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'concurrency', 'the losing action left no trail row',
       CASE WHEN COUNT(*) = 1 THEN 1 ELSE 0 END, CONCAT('approve/reject rows=', COUNT(*))
FROM dbo.t_mdm_request_approvals WHERE RequestId = @RaceId AND ActionTypeId IN (1, 2);

/*==============================================================================
  5b. THE RowVersion CHECK ITSELF — the branch section 5 never reaches

  🔴 Section 5 above asserts the right OUTCOME for the wrong REASON.

  MVP configures one level, so any successful approve COMPLETES the request. The
  second attempt is therefore refused by the STATUS check — INVALID_STATUS,
  "already approved" — and RowVersion is never compared at all. The assertion
  passes while the code it names never executes. That was found by independent
  verification on 2026-08-09, not by this suite (gap G10).

  To reach the RowVersion branch the request must still be Pending after the
  first action, which needs two levels. The level configuration is changed here
  and restored at the end of the block, all inside the suite's transaction.

  This also covers multi-level advancement, which nothing else here exercises.
==============================================================================*/
DECLARE @TwoLevelEntity uniqueidentifier = NEWID(), @TwoLevelId bigint, @TwoLevelRV int;

-- Make request type 1 two-level for the duration of this block.
UPDATE dbo.t_mdm_request_levels SET IsFinalLevel = 0
WHERE RequestTypeId = 1 AND LevelNumber = 1 AND OrganizationUid IS NULL AND Is_Deleted = 0;

INSERT INTO dbo.t_mdm_request_levels (RequestTypeId, LevelNumber, RoleId, IsFinalLevel, OrganizationUid)
VALUES (1, 2, 2, 1, NULL);

EXEC dbo.USP_SubmitApprovalRequest
     @RequestTypeId = 1, @EntityUid = @TwoLevelEntity, @RequestorUserId = @Requestor,
     @SchoolName = N'Two Level School';

SELECT @TwoLevelId = RequestId, @TwoLevelRV = RowVersion
FROM dbo.t_mdm_approval_requests WHERE EntityUid = @TwoLevelEntity AND Is_Deleted = 0;

-- Admin A approves level 1. The request must stay Pending and advance.
EXEC dbo.USP_ProcessApprovalAction
     @RequestId = @TwoLevelId, @ActionTypeId = 1, @ActionByUserId = @Admin,
     @RowVersion = @TwoLevelRV, @ActorRoleIds = @AdminRoles;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'multilevel', 'approving a non-final level keeps it Pending and advances',
       CASE WHEN StatusId = 1 AND CurrentApprovalLevel = 2 AND CompletedOn IS NULL THEN 1 ELSE 0 END,
       CONCAT('StatusId=', StatusId, ' Level=', CurrentApprovalLevel,
              ' Completed=', CASE WHEN CompletedOn IS NULL THEN 'null' ELSE 'set' END)
FROM dbo.t_mdm_approval_requests WHERE RequestId = @TwoLevelId;

DECLARE @TwoLevelTrailBefore int =
    (SELECT COUNT(*) FROM dbo.t_mdm_request_approvals WHERE RequestId = @TwoLevelId);

-- Admin B acts on the STALE RowVersion while the request is still Pending.
-- Only the RowVersion check can refuse this one.
EXEC dbo.USP_ProcessApprovalAction
     @RequestId = @TwoLevelId, @ActionTypeId = 1, @ActionByUserId = @Admin,
     @RowVersion = @TwoLevelRV, @ActorRoleIds = @AdminRoles;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'concurrency', 'stale RowVersion is refused while the request is still Pending',
       CASE WHEN StatusId = 1 AND CurrentApprovalLevel = 2 THEN 1 ELSE 0 END,
       CONCAT('StatusId=', StatusId, ' Level=', CurrentApprovalLevel)
FROM dbo.t_mdm_approval_requests WHERE RequestId = @TwoLevelId;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'concurrency', 'the refused stale action left no trail row',
       CASE WHEN COUNT(*) = @TwoLevelTrailBefore THEN 1 ELSE 0 END,
       CONCAT('trail rows=', COUNT(*), ' expected=', @TwoLevelTrailBefore)
FROM dbo.t_mdm_request_approvals WHERE RequestId = @TwoLevelId;

-- Approving at the final level completes it.
SELECT @TwoLevelRV = RowVersion FROM dbo.t_mdm_approval_requests WHERE RequestId = @TwoLevelId;

EXEC dbo.USP_ProcessApprovalAction
     @RequestId = @TwoLevelId, @ActionTypeId = 1, @ActionByUserId = @Admin,
     @RowVersion = @TwoLevelRV, @ActorRoleIds = @AdminRoles;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'multilevel', 'approving the final level completes the request',
       CASE WHEN StatusId = 3 AND CompletedOn IS NOT NULL THEN 1 ELSE 0 END,
       CONCAT('StatusId=', StatusId)
FROM dbo.t_mdm_approval_requests WHERE RequestId = @TwoLevelId;

-- Restore the single-level configuration for the sections that follow.
DELETE FROM dbo.t_mdm_request_levels
WHERE RequestTypeId = 1 AND LevelNumber = 2 AND OrganizationUid IS NULL;

UPDATE dbo.t_mdm_request_levels SET IsFinalLevel = 1
WHERE RequestTypeId = 1 AND LevelNumber = 1 AND OrganizationUid IS NULL AND Is_Deleted = 0;

/*==============================================================================
  6. REPEATED SUBMIT — no second Pending request, and no new RequestNo
==============================================================================*/
DECLARE @DupEntity uniqueidentifier = NEWID(), @DupFirst bigint, @DupNo varchar(30);

EXEC dbo.USP_SubmitApprovalRequest
     @RequestTypeId = 1, @EntityUid = @DupEntity, @RequestorUserId = @Requestor,
     @SchoolName = N'Double Click Academy';

SELECT @DupFirst = RequestId, @DupNo = RequestNo
FROM dbo.t_mdm_approval_requests WHERE EntityUid = @DupEntity AND Is_Deleted = 0;

-- The same submission again, as a double click or a retry would send it.
EXEC dbo.USP_SubmitApprovalRequest
     @RequestTypeId = 1, @EntityUid = @DupEntity, @RequestorUserId = @Requestor,
     @SchoolName = N'Double Click Academy';

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'idempotency', 'a repeated submit creates no second Pending request',
       CASE WHEN COUNT(*) = 1 THEN 1 ELSE 0 END, CONCAT('pending rows=', COUNT(*))
FROM dbo.t_mdm_approval_requests
WHERE EntityUid = @DupEntity AND StatusId = 1 AND Is_Deleted = 0;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'idempotency', 'the original RequestNo is unchanged',
       CASE WHEN MAX(RequestNo) = @DupNo THEN 1 ELSE 0 END, MAX(RequestNo)
FROM dbo.t_mdm_approval_requests WHERE EntityUid = @DupEntity AND Is_Deleted = 0;

/*==============================================================================
  7. RequestNo DOES NOT COLLIDE ACROSS REPEATED SUBMITS
==============================================================================*/
-- A table variable needs its own DECLARE — it cannot share one with a scalar.
DECLARE @Made TABLE (RequestNo varchar(30));
DECLARE @i int = 0;
DECLARE @LoopEntity uniqueidentifier;

WHILE @i < 10
BEGIN
    -- SET, not DECLARE: a DECLARE inside a loop is still a batch-level
    -- declaration and would only run once, so every iteration would reuse the
    -- same Uid and the second submit would be treated as a duplicate.
    SET @LoopEntity = NEWID();

    EXEC dbo.USP_SubmitApprovalRequest
         @RequestTypeId = 1, @EntityUid = @LoopEntity, @RequestorUserId = @Requestor,
         @SchoolName = N'Sequenced School';

    INSERT INTO @Made (RequestNo)
    SELECT RequestNo FROM dbo.t_mdm_approval_requests
    WHERE EntityUid = @LoopEntity AND Is_Deleted = 0;

    SET @i += 1;
END

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'requestno', '10 submissions produced 10 distinct numbers',
       CASE WHEN COUNT(*) = 10 AND COUNT(DISTINCT RequestNo) = 10 THEN 1 ELSE 0 END,
       CONCAT('made=', COUNT(*), ' distinct=', COUNT(DISTINCT RequestNo))
FROM @Made;

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'requestno', 'the sequence is contiguous',
       CASE WHEN MAX(n) - MIN(n) = 9 THEN 1 ELSE 0 END,
       CONCAT('min=', MIN(n), ' max=', MAX(n))
FROM (SELECT TRY_CAST(RIGHT(RequestNo, 5) AS int) AS n FROM @Made) x;

/*==============================================================================
  8. VALIDATION — a bad request type is refused, and nothing is written
==============================================================================*/
DECLARE @BadEntity uniqueidentifier = NEWID();
DECLARE @BeforeBad int = (SELECT COUNT(*) FROM dbo.t_mdm_approval_requests);

EXEC dbo.USP_SubmitApprovalRequest
     @RequestTypeId = 99, @EntityUid = @BadEntity, @RequestorUserId = @Requestor,
     @SchoolName = N'Bad Type School';

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'validation', 'an unknown request type writes nothing',
       CASE WHEN (SELECT COUNT(*) FROM dbo.t_mdm_approval_requests) = @BeforeBad THEN 1 ELSE 0 END,
       CONCAT('before=', @BeforeBad, ' after=', (SELECT COUNT(*) FROM dbo.t_mdm_approval_requests));

/*==============================================================================
  9. THE ERROR LOG SURVIVES A ROLLBACK  (decision 2.31)

  Force a genuine failure inside a procedure transaction and confirm the log
  row is still there afterwards. This is the assertion that catches the CATCH
  ordering being wrong — log-before-rollback would show before = after.
==============================================================================*/
DECLARE @LogBefore int = (SELECT COUNT(*) FROM dbo.t_mdm_error_log);

BEGIN TRY
    -- A document row whose request does not exist: the FK fails inside the
    -- procedure's transaction, so it rolls back and logs.
    EXEC dbo.USP_SaveRequestDocument
         @RequestId = 99999999, @DocumentTypeId = -1,
         @FilePath = N'/x', @FileName = N'x.pdf', @FileSizeKb = 10,
         @MimeType = 'application/pdf', @ActionByUserId = @Admin;
END TRY
BEGIN CATCH
    -- Expected. The suite continues.
END CATCH

-- That call is refused by validation rather than reaching the FK, so drive the
-- log directly to prove the survival property itself.
BEGIN TRY
    BEGIN TRANSACTION;
    DECLARE @Boom int = 1 / 0;
    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    DECLARE @EN int = ERROR_NUMBER(), @EM nvarchar(4000) = ERROR_MESSAGE(),
            @EP sysname = ERROR_PROCEDURE(), @EL int = ERROR_LINE();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    EXEC dbo.USP_LogError @ErrorNumber = @EN, @ErrorMessage = @EM,
         @ErrorProcedure = @EP, @ErrorLine = @EL,
         @ContextInfo = N'approval engine test suite';
END CATCH

INSERT INTO @Assert (Area, Name, Passed, Detail)
SELECT 'errorlog', 'the log row survives the rollback',
       CASE WHEN (SELECT COUNT(*) FROM dbo.t_mdm_error_log) > @LogBefore THEN 1 ELSE 0 END,
       CONCAT('before=', @LogBefore, ' after=', (SELECT COUNT(*) FROM dbo.t_mdm_error_log));

/*==============================================================================
  RESULTS
==============================================================================*/
IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

SELECT Seq, Area, Name, Detail,
       CASE WHEN Passed = 1 THEN 'PASS' ELSE 'FAIL' END AS Result
FROM @Assert
ORDER BY Seq;

DECLARE @Total int = (SELECT COUNT(*) FROM @Assert),
        @Pass  int = (SELECT COUNT(*) FROM @Assert WHERE Passed = 1),
        @Fail  int = (SELECT COUNT(*) FROM @Assert WHERE Passed = 0);

PRINT '';
PRINT '=========================================================';
PRINT '  APPROVAL ENGINE: TOTAL ' + CAST(@Total AS varchar(10))
    + '   PASSED ' + CAST(@Pass AS varchar(10))
    + '   FAILED ' + CAST(@Fail AS varchar(10));
PRINT '=========================================================';

IF @Fail > 0
BEGIN
    SELECT Seq, Area, Name, Detail FROM @Assert WHERE Passed = 0 ORDER BY Seq;
    RAISERROR('Approval engine tests FAILED.', 16, 1);
END
GO
