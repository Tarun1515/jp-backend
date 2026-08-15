/*==============================================================================
  jp_app — 99_tests / 001_test_school_branch.sql

  PHASE 3C — school and branch procedures, and the scope resolver.

  ---------------------------------------------------------------------------
  🔴 THE TEST THAT MATTERS IS THE NEGATIVE ONE
  ---------------------------------------------------------------------------
  "The right rows came back" passes against a resolver that returns everything.
  The assertions that mean something here are the ones checking that a branch HR
  gets ZERO rows for a campus they are not on — not fewer rows, zero — and that
  a member of another school gets zero for all of it.

  ---------------------------------------------------------------------------
  Conventions (2.30):
    - table VARIABLES for the assertion log, never #temp
    - plain EXEC into a table variable, never INSERT..EXEC of a proc that
      itself does INSERT..EXEC
    - builds its own fixtures and rolls them back; the database is unchanged
==============================================================================*/

USE jp_app;
GO

SET NOCOUNT ON;
SET XACT_ABORT OFF;
GO

DECLARE @t TABLE (n int IDENTITY(1,1), section varchar(40), what nvarchar(90), got nvarchar(120), pass varchar(4));

DECLARE @schoolA bigint, @schoolB bigint;
DECLARE @a1 bigint, @a2 bigint, @a3 bigint, @b1 bigint;
DECLARE @ownerA uniqueidentifier = NEWID(),
        @hrA     uniqueidentifier = NEWID(),
        @ownerB  uniqueidentifier = NEWID(),
        @stranger uniqueidentifier = NEWID();
DECLARE @suA bigint, @suHrA bigint, @suB bigint;
DECLARE @rv int, @cnt int, @orgA uniqueidentifier = NEWID(), @orgB uniqueidentifier = NEWID();

DECLARE @r TABLE (Status int, Code varchar(50), Message nvarchar(400), Id bigint);
DECLARE @rb TABLE (Status int, Code varchar(50), Message nvarchar(400), Id bigint, BranchUid uniqueidentifier);
DECLARE @rf TABLE (Status int, Code varchar(50), Message nvarchar(400), Id bigint, Added int, Restored int, Removed int);

BEGIN TRANSACTION;

/*==============================================================================
  FIXTURE

  School A: an owner, and an HR scoped to branch a1 ONLY.
  School B: its own owner. Exists so "another school" is a real thing rather
            than a hypothetical.
==============================================================================*/
INSERT INTO dbo.t_app_schools (OrganizationUid, SchoolName, IsVerified, StateId)
VALUES (@orgA, N'Scope Test School A', 1, 32);
SET @schoolA = SCOPE_IDENTITY();

INSERT INTO dbo.t_app_schools (OrganizationUid, SchoolName, IsVerified, StateId)
VALUES (@orgB, N'Scope Test School B', 1, 14);
SET @schoolB = SCOPE_IDENTITY();

INSERT INTO dbo.t_app_school_branches (SchoolId, BranchName, IsHeadOffice, StateId)
VALUES (@schoolA, N'A — Head Office', 1, 32);
SET @a1 = SCOPE_IDENTITY();

INSERT INTO dbo.t_app_school_branches (SchoolId, BranchName, IsHeadOffice, StateId)
VALUES (@schoolA, N'A — North Campus', 0, 32);
SET @a2 = SCOPE_IDENTITY();

INSERT INTO dbo.t_app_school_branches (SchoolId, BranchName, IsHeadOffice, StateId)
VALUES (@schoolA, N'A — South Campus', 0, 32);
SET @a3 = SCOPE_IDENTITY();

INSERT INTO dbo.t_app_school_branches (SchoolId, BranchName, IsHeadOffice, StateId)
VALUES (@schoolB, N'B — Head Office', 1, 14);
SET @b1 = SCOPE_IDENTITY();

-- Owner of A. 🔴 No link rows, deliberately — that is what "owner" means here.
INSERT INTO dbo.t_app_school_users (SchoolId, UserUid, RoleInSchool) VALUES (@schoolA, @ownerA, 1);
SET @suA = SCOPE_IDENTITY();

-- HR at A, scoped to the head office only.
INSERT INTO dbo.t_app_school_users (SchoolId, UserUid, RoleInSchool) VALUES (@schoolA, @hrA, 3);
SET @suHrA = SCOPE_IDENTITY();
INSERT INTO dbo.t_app_school_user_branches (SchoolUserId, BranchId) VALUES (@suHrA, @a1);

INSERT INTO dbo.t_app_school_users (SchoolId, UserUid, RoleInSchool) VALUES (@schoolB, @ownerB, 1);
SET @suB = SCOPE_IDENTITY();


/*==============================================================================
  1. THE SCOPE RESOLVER — positive
==============================================================================*/
SELECT @cnt = COUNT(*) FROM dbo.fn_VisibleBranches(@schoolA, @ownerA);
INSERT INTO @t VALUES ('resolver', N'Owner sees all 3 branches, with NO link rows',
    CAST(@cnt AS nvarchar(10)) + N' branches', CASE WHEN @cnt = 3 THEN 'PASS' ELSE 'FAIL' END);

SELECT @cnt = COUNT(*) FROM dbo.fn_VisibleBranches(@schoolA, @hrA);
INSERT INTO @t VALUES ('resolver', N'Branch HR sees only their 1 assigned branch',
    CAST(@cnt AS nvarchar(10)) + N' branches', CASE WHEN @cnt = 1 THEN 'PASS' ELSE 'FAIL' END);


/*==============================================================================
  2. 🔴 THE SCOPE RESOLVER — NEGATIVE. The section this phase turns on.

  Every one of these must be ZERO, not "fewer".
==============================================================================*/
SELECT @cnt = COUNT(*) FROM dbo.fn_VisibleBranches(@schoolA, @hrA) WHERE BranchId = @a2;
INSERT INTO @t VALUES ('resolver NEG', N'🔴 Branch HR gets ZERO rows for an unassigned campus',
    CAST(@cnt AS nvarchar(10)) + N' rows', CASE WHEN @cnt = 0 THEN 'PASS' ELSE 'FAIL' END);

SELECT @cnt = COUNT(*) FROM dbo.fn_VisibleBranches(@schoolA, @hrA) WHERE BranchId = @a3;
INSERT INTO @t VALUES ('resolver NEG', N'🔴 …and ZERO for the other unassigned campus',
    CAST(@cnt AS nvarchar(10)) + N' rows', CASE WHEN @cnt = 0 THEN 'PASS' ELSE 'FAIL' END);

SELECT @cnt = COUNT(*) FROM dbo.fn_VisibleBranches(@schoolB, @hrA);
INSERT INTO @t VALUES ('resolver NEG', N'🔴 School A''s HR gets ZERO rows for school B',
    CAST(@cnt AS nvarchar(10)) + N' rows', CASE WHEN @cnt = 0 THEN 'PASS' ELSE 'FAIL' END);

SELECT @cnt = COUNT(*) FROM dbo.fn_VisibleBranches(@schoolA, @ownerB);
INSERT INTO @t VALUES ('resolver NEG', N'🔴 School B''s OWNER gets ZERO rows for school A',
    CAST(@cnt AS nvarchar(10)) + N' rows', CASE WHEN @cnt = 0 THEN 'PASS' ELSE 'FAIL' END);

SELECT @cnt = COUNT(*) FROM dbo.fn_VisibleBranches(@schoolA, @stranger);
INSERT INTO @t VALUES ('resolver NEG', N'🔴 A user with no membership gets ZERO rows',
    CAST(@cnt AS nvarchar(10)) + N' rows', CASE WHEN @cnt = 0 THEN 'PASS' ELSE 'FAIL' END);

-- A soft-deleted link must stop granting access immediately.
UPDATE dbo.t_app_school_user_branches SET Is_Deleted = 1 WHERE SchoolUserId = @suHrA AND BranchId = @a1;
SELECT @cnt = COUNT(*) FROM dbo.fn_VisibleBranches(@schoolA, @hrA);
INSERT INTO @t VALUES ('resolver NEG', N'🔴 A soft-deleted link grants ZERO',
    CAST(@cnt AS nvarchar(10)) + N' rows', CASE WHEN @cnt = 0 THEN 'PASS' ELSE 'FAIL' END);
UPDATE dbo.t_app_school_user_branches SET Is_Deleted = 0 WHERE SchoolUserId = @suHrA AND BranchId = @a1;

-- And a deactivated membership, which is a different column.
UPDATE dbo.t_app_school_users SET Is_Active = 0 WHERE SchoolUserId = @suHrA;
SELECT @cnt = COUNT(*) FROM dbo.fn_VisibleBranches(@schoolA, @hrA);
INSERT INTO @t VALUES ('resolver NEG', N'🔴 A deactivated membership grants ZERO',
    CAST(@cnt AS nvarchar(10)) + N' rows', CASE WHEN @cnt = 0 THEN 'PASS' ELSE 'FAIL' END);
UPDATE dbo.t_app_school_users SET Is_Active = 1 WHERE SchoolUserId = @suHrA;


/*==============================================================================
  3. THE LIST PROCEDURE INHERITS THE RULE

  The resolver being right is not enough — what matters is that the procedures
  actually use it.
==============================================================================*/
DECLARE @list TABLE (BranchId bigint, BranchUid uniqueidentifier, SchoolId bigint,
                     BranchName nvarchar(200), BranchCode varchar(30), IsHeadOffice tinyint,
                     AddressLine1 nvarchar(250), AddressLine2 nvarchar(250),
                     CityId int, DistrictId int, StateId int, Pincode varchar(10),
                     Latitude decimal(9,6), Longitude decimal(9,6),
                     ContactPerson nvarchar(150), ContactEmail nvarchar(150), ContactMobile varchar(15),
                     Is_Active tinyint, RowVersion int, CreatedOn datetime2);

DELETE FROM @list;
INSERT INTO @list EXEC dbo.USP_GetBranchList @SchoolId = @schoolA, @UserUid = @ownerA;
SELECT @cnt = COUNT(*) FROM @list;
INSERT INTO @t VALUES ('list', N'USP_GetBranchList: owner gets 3',
    CAST(@cnt AS nvarchar(10)) + N' rows', CASE WHEN @cnt = 3 THEN 'PASS' ELSE 'FAIL' END);

DELETE FROM @list;
INSERT INTO @list EXEC dbo.USP_GetBranchList @SchoolId = @schoolA, @UserUid = @hrA;
SELECT @cnt = COUNT(*) FROM @list;
INSERT INTO @t VALUES ('list NEG', N'🔴 USP_GetBranchList: branch HR gets exactly 1',
    CAST(@cnt AS nvarchar(10)) + N' rows', CASE WHEN @cnt = 1 THEN 'PASS' ELSE 'FAIL' END);

SELECT @cnt = COUNT(*) FROM @list WHERE BranchId IN (@a2, @a3);
INSERT INTO @t VALUES ('list NEG', N'🔴 …and ZERO of them are the unassigned campuses',
    CAST(@cnt AS nvarchar(10)) + N' rows', CASE WHEN @cnt = 0 THEN 'PASS' ELSE 'FAIL' END);

DELETE FROM @list;
INSERT INTO @list EXEC dbo.USP_GetBranchList @SchoolId = @schoolA, @UserUid = @stranger;
SELECT @cnt = COUNT(*) FROM @list;
INSERT INTO @t VALUES ('list NEG', N'🔴 USP_GetBranchList: a stranger gets ZERO',
    CAST(@cnt AS nvarchar(10)) + N' rows', CASE WHEN @cnt = 0 THEN 'PASS' ELSE 'FAIL' END);


/*==============================================================================
  4. WRITES ARE SCOPE-GATED TOO

  A read-only gate would be worth very little: the interesting attack is editing
  a campus you cannot see.
==============================================================================*/
SELECT @rv = RowVersion FROM dbo.t_app_school_branches WHERE BranchId = @a2;

DELETE FROM @rb;
INSERT INTO @rb EXEC dbo.USP_SaveBranch
    @SchoolId = @schoolA, @UserUid = @hrA, @BranchId = @a2, @RowVersion = @rv,
    @BranchName = N'Renamed by somebody who cannot see it';

INSERT INTO @t
SELECT 'write NEG', N'🔴 Branch HR cannot EDIT an unassigned campus',
       ISNULL(Code, '(succeeded)'), CASE WHEN Code = 'NOT_FOUND' THEN 'PASS' ELSE 'FAIL' END
FROM @rb;

DELETE FROM @rb;
INSERT INTO @rb EXEC dbo.USP_SaveBranch
    @SchoolId = @schoolA, @UserUid = @hrA, @BranchId = @a1, @RowVersion = 1,
    @BranchName = N'A — Head Office, renamed';

INSERT INTO @t
SELECT 'write', N'Branch HR CAN edit their own campus',
       ISNULL(Code, '(ok)'), CASE WHEN Status = 1 THEN 'PASS' ELSE 'FAIL' END
FROM @rb;


/*==============================================================================
  5. ROWVERSION
==============================================================================*/
SELECT @rv = RowVersion FROM dbo.t_app_schools WHERE SchoolId = @schoolA;

DELETE FROM @r;
INSERT INTO @r EXEC dbo.USP_UpdateSchoolProfile
    @SchoolId = @schoolA, @UserUid = @ownerA, @RowVersion = @rv, @AboutSchool = N'First edit';

INSERT INTO @t
SELECT 'rowversion', N'A correct RowVersion is accepted',
       ISNULL(Code, '(ok)'), CASE WHEN Status = 1 THEN 'PASS' ELSE 'FAIL' END
FROM @r;

DELETE FROM @r;
INSERT INTO @r EXEC dbo.USP_UpdateSchoolProfile
    @SchoolId = @schoolA, @UserUid = @ownerA, @RowVersion = @rv, @AboutSchool = N'Stale edit';

INSERT INTO @t
SELECT 'rowversion', N'🔴 A stale RowVersion is REFUSED',
       ISNULL(Code, '(succeeded)'), CASE WHEN Code = 'CONCURRENCY_CONFLICT' THEN 'PASS' ELSE 'FAIL' END
FROM @r;

SELECT @cnt = CASE WHEN AboutSchool = N'First edit' THEN 1 ELSE 0 END
FROM dbo.t_app_schools WHERE SchoolId = @schoolA;
INSERT INTO @t VALUES ('rowversion', N'…and the stale edit changed nothing',
    CASE WHEN @cnt = 1 THEN N'first edit intact' ELSE N'OVERWRITTEN' END,
    CASE WHEN @cnt = 1 THEN 'PASS' ELSE 'FAIL' END);

DELETE FROM @r;
INSERT INTO @r EXEC dbo.USP_UpdateSchoolProfile
    @SchoolId = @schoolA, @UserUid = @stranger, @RowVersion = 99, @AboutSchool = N'Not mine';

INSERT INTO @t
SELECT 'write NEG', N'🔴 A stranger cannot update the school profile',
       ISNULL(Code, '(succeeded)'), CASE WHEN Code = 'NOT_FOUND' THEN 'PASS' ELSE 'FAIL' END
FROM @r;


/*==============================================================================
  6. DELETE REFUSALS
==============================================================================*/
SELECT @rv = RowVersion FROM dbo.t_app_school_branches WHERE BranchId = @a1;

DELETE FROM @r;
INSERT INTO @r EXEC dbo.USP_DeleteBranch
    @BranchId = @a1, @SchoolId = @schoolA, @UserUid = @ownerA, @RowVersion = @rv;

INSERT INTO @t
SELECT 'delete', N'🔴 The head office cannot be deleted',
       ISNULL(Code, '(succeeded)'), CASE WHEN Code = 'BUSINESS_RULE_VIOLATED' THEN 'PASS' ELSE 'FAIL' END
FROM @r;

SELECT @cnt = COUNT(*) FROM dbo.t_app_school_branches
WHERE SchoolId = @schoolA AND IsHeadOffice = 1 AND Is_Deleted = 0;
INSERT INTO @t VALUES ('delete', N'…and the school still has its head office',
    CAST(@cnt AS nvarchar(10)) + N' head office', CASE WHEN @cnt = 1 THEN 'PASS' ELSE 'FAIL' END);

SELECT @rv = RowVersion FROM dbo.t_app_school_branches WHERE BranchId = @a2;
DELETE FROM @r;
INSERT INTO @r EXEC dbo.USP_DeleteBranch
    @BranchId = @a2, @SchoolId = @schoolA, @UserUid = @hrA, @RowVersion = @rv;

INSERT INTO @t
SELECT 'delete NEG', N'🔴 Branch HR cannot delete an unassigned campus',
       ISNULL(Code, '(succeeded)'), CASE WHEN Code = 'NOT_FOUND' THEN 'PASS' ELSE 'FAIL' END
FROM @r;

DELETE FROM @r;
INSERT INTO @r EXEC dbo.USP_DeleteBranch
    @BranchId = @a2, @SchoolId = @schoolA, @UserUid = @ownerA, @RowVersion = @rv;

INSERT INTO @t
SELECT 'delete', N'An ordinary campus CAN be deleted by the owner',
       ISNULL(Code, '(ok)'), CASE WHEN Status = 1 THEN 'PASS' ELSE 'FAIL' END
FROM @r;


/*==============================================================================
  7. BRIDGE SYNC — add, remove, no-op
==============================================================================*/
DECLARE @fac dbo.IntIdList;

INSERT INTO @fac (Id) VALUES (1), (2), (3);
DELETE FROM @rf;
INSERT INTO @rf EXEC dbo.USP_SaveSchoolFacilities
    @SchoolId = @schoolA, @UserUid = @ownerA, @BranchId = NULL, @FacilityIds = @fac;

INSERT INTO @t
SELECT 'bridge', N'Adding 3 facilities inserts 3',
       N'added ' + CAST(Added AS nvarchar(4)) + N', removed ' + CAST(Removed AS nvarchar(4)),
       CASE WHEN Added = 3 AND Removed = 0 THEN 'PASS' ELSE 'FAIL' END
FROM @rf;

-- 🔴 THE NO-OP. Saving the same set again must write nothing at all.
DELETE FROM @rf;
INSERT INTO @rf EXEC dbo.USP_SaveSchoolFacilities
    @SchoolId = @schoolA, @UserUid = @ownerA, @BranchId = NULL, @FacilityIds = @fac;

INSERT INTO @t
SELECT 'bridge', N'🔴 A no-op save writes NOTHING',
       N'added ' + CAST(Added AS nvarchar(4)) + N', restored ' + CAST(Restored AS nvarchar(4))
     + N', removed ' + CAST(Removed AS nvarchar(4)),
       CASE WHEN Added = 0 AND Restored = 0 AND Removed = 0 THEN 'PASS' ELSE 'FAIL' END
FROM @rf;

-- Identities must survive a no-op — the whole reason for the diff.
DECLARE @idsBefore nvarchar(200) =
    (SELECT STRING_AGG(CAST(Id AS nvarchar(20)), ',') WITHIN GROUP (ORDER BY Id)
     FROM dbo.t_app_school_facilities WHERE SchoolId = @schoolA AND Is_Deleted = 0);

DELETE FROM @fac;
INSERT INTO @fac (Id) VALUES (1), (3);       -- 2 removed
DELETE FROM @rf;
INSERT INTO @rf EXEC dbo.USP_SaveSchoolFacilities
    @SchoolId = @schoolA, @UserUid = @ownerA, @BranchId = NULL, @FacilityIds = @fac;

INSERT INTO @t
SELECT 'bridge', N'Removing one soft-deletes exactly one',
       N'removed ' + CAST(Removed AS nvarchar(4)),
       CASE WHEN Removed = 1 AND Added = 0 THEN 'PASS' ELSE 'FAIL' END
FROM @rf;

-- 🔴 RESTORE, not re-insert.
DELETE FROM @fac;
INSERT INTO @fac (Id) VALUES (1), (2), (3);
DELETE FROM @rf;
INSERT INTO @rf EXEC dbo.USP_SaveSchoolFacilities
    @SchoolId = @schoolA, @UserUid = @ownerA, @BranchId = NULL, @FacilityIds = @fac;

INSERT INTO @t
SELECT 'bridge', N'🔴 Re-adding RESTORES the old row, does not insert a new one',
       N'added ' + CAST(Added AS nvarchar(4)) + N', restored ' + CAST(Restored AS nvarchar(4)),
       CASE WHEN Restored = 1 AND Added = 0 THEN 'PASS' ELSE 'FAIL' END
FROM @rf;

DECLARE @idsAfter nvarchar(200) =
    (SELECT STRING_AGG(CAST(Id AS nvarchar(20)), ',') WITHIN GROUP (ORDER BY Id)
     FROM dbo.t_app_school_facilities WHERE SchoolId = @schoolA AND Is_Deleted = 0);

INSERT INTO @t VALUES ('bridge', N'🔴 …and the row identities are unchanged throughout',
    CASE WHEN @idsBefore = @idsAfter THEN N'same ids' ELSE N'ids changed' END,
    CASE WHEN @idsBefore = @idsAfter THEN 'PASS' ELSE 'FAIL' END);

-- Branch-scoped facilities are a separate set from school-level ones.
DELETE FROM @fac;
INSERT INTO @fac (Id) VALUES (1);
DELETE FROM @rf;
INSERT INTO @rf EXEC dbo.USP_SaveSchoolFacilities
    @SchoolId = @schoolA, @UserUid = @ownerA, @BranchId = @a3, @FacilityIds = @fac;

SELECT @cnt = COUNT(*) FROM dbo.t_app_school_facilities
WHERE SchoolId = @schoolA AND BranchId IS NULL AND Is_Deleted = 0;
INSERT INTO @t VALUES ('bridge', N'A branch-level save leaves the school-level set alone',
    CAST(@cnt AS nvarchar(10)) + N' school-level', CASE WHEN @cnt = 3 THEN 'PASS' ELSE 'FAIL' END);


/*==============================================================================
  8. THE PUBLIC PROFILE LEAKS NOTHING

  ⚠️ NOT tested with INSERT..EXEC, and the reason is worth recording: that
  captures EVERY result set a procedure emits and tries to push all of them into
  one table variable. USP_GetSchoolPublicProfile returns four, so it fails with
  Msg 213 on the second one — which is also why decision 2.30 says tests use
  plain EXEC rather than INSERT..EXEC.

  So the shape is asserted against the procedure's METADATA instead, which is
  the stronger test anyway: it checks that a column is ABSENT rather than that
  its value happened to be NULL on this row. A column present-but-empty today is
  a column somebody populates next month.
==============================================================================*/
UPDATE dbo.t_app_schools SET PanNumber = 'AAAAA1111A' WHERE SchoolId = @schoolA;

DECLARE @publicColumns TABLE (name sysname);

INSERT INTO @publicColumns (name)
SELECT r.name
FROM sys.dm_exec_describe_first_result_set(N'EXEC dbo.USP_GetSchoolPublicProfile @SchoolUid = NULL', NULL, 0) r;

DECLARE @leaked nvarchar(400) =
    (SELECT STRING_AGG(name, ', ') FROM @publicColumns
     WHERE name IN ('PanNumber', 'OrganizationUid', 'SuspensionReason', 'IsSuspended',
                    'RowVersion', 'HrContactMobile', 'HrContactName', 'PrincipalName',
                    'ContactEmail', 'ContactMobile', 'VerifiedByUserId', 'SchoolId'));

INSERT INTO @t VALUES ('public', N'🔴 The public shape carries NO PAN and no internal columns',
    ISNULL(N'leaked: ' + @leaked, N'none of them present'),
    CASE WHEN @leaked IS NULL THEN 'PASS' ELSE 'FAIL' END);

-- And it does return the columns a teacher actually needs, so the check above
-- cannot be passing merely because the procedure returns nothing at all.
SELECT @cnt = COUNT(*) FROM @publicColumns WHERE name IN ('SchoolUid', 'SchoolName', 'AboutSchool');
INSERT INTO @t VALUES ('public', N'…while still returning the public columns',
    CAST(@cnt AS nvarchar(10)) + N' of 3 present', CASE WHEN @cnt = 3 THEN 'PASS' ELSE 'FAIL' END);

/*
  The suspended and unverified gates.

  ⚠️ These assert against the procedure's own lookup predicate rather than
  against its output, for the INSERT..EXEC reason above. That makes them the
  WEAKER assertions in this file: they would still pass if somebody deleted the
  filter from the procedure.

  Recorded as a limitation rather than dressed up. The real protection for those
  two lines is the column-level check above plus a Phase 4 integration test that
  fetches a suspended school over HTTP and expects a 404.
*/
DECLARE @publicVisible int;

SELECT @publicVisible = COUNT(*)
FROM dbo.t_app_schools s
WHERE s.SchoolId = @schoolA
  AND s.Is_Deleted = 0 AND s.Is_Active = 1 AND s.IsSuspended = 0 AND s.IsVerified = 1;

INSERT INTO @t VALUES ('public', N'A verified, unsuspended school IS publicly visible',
    CAST(@publicVisible AS nvarchar(10)) + N' rows', CASE WHEN @publicVisible = 1 THEN 'PASS' ELSE 'FAIL' END);

UPDATE dbo.t_app_schools SET IsSuspended = 1 WHERE SchoolId = @schoolA;
SELECT @publicVisible = COUNT(*)
FROM dbo.t_app_schools s
WHERE s.SchoolId = @schoolA
  AND s.Is_Deleted = 0 AND s.Is_Active = 1 AND s.IsSuspended = 0 AND s.IsVerified = 1;
INSERT INTO @t VALUES ('public NEG', N'🔴 A SUSPENDED school is not publicly visible (mirrored)',
    CAST(@publicVisible AS nvarchar(10)) + N' rows', CASE WHEN @publicVisible = 0 THEN 'PASS' ELSE 'FAIL' END);
UPDATE dbo.t_app_schools SET IsSuspended = 0 WHERE SchoolId = @schoolA;

UPDATE dbo.t_app_schools SET IsVerified = 0 WHERE SchoolId = @schoolA;
SELECT @publicVisible = COUNT(*)
FROM dbo.t_app_schools s
WHERE s.SchoolId = @schoolA
  AND s.Is_Deleted = 0 AND s.Is_Active = 1 AND s.IsSuspended = 0 AND s.IsVerified = 1;
INSERT INTO @t VALUES ('public NEG', N'🔴 An UNVERIFIED school is not publicly visible (mirrored)',
    CAST(@publicVisible AS nvarchar(10)) + N' rows', CASE WHEN @publicVisible = 0 THEN 'PASS' ELSE 'FAIL' END);
UPDATE dbo.t_app_schools SET IsVerified = 1 WHERE SchoolId = @schoolA;


/*==============================================================================
  9. TEACHER PROFILE PROVISIONING (G21) — idempotent
==============================================================================*/
DECLARE @newTeacher uniqueidentifier = NEWID();
DECLARE @teacherPlan int = (SELECT PlanId FROM jp_mdm.dbo.m_mdm_plans WHERE PlanCode = 'TEACHER_FREE');
DECLARE @rt TABLE (Status int, Code varchar(50), Message nvarchar(400), Id bigint, TeacherUid uniqueidentifier);

INSERT INTO @rt EXEC dbo.USP_ProvisionTeacherProfile
    @UserUid = @newTeacher, @FullName = NULL, @PlanId = @teacherPlan;

INSERT INTO @t
SELECT 'G21', N'A new teacher gets a profile',
       ISNULL(Code, '(created)'), CASE WHEN Status = 1 THEN 'PASS' ELSE 'FAIL' END
FROM @rt;

SELECT @cnt = COUNT(*) FROM dbo.t_app_subscriptions WHERE OwnerUid = @newTeacher AND Is_Deleted = 0;
INSERT INTO @t VALUES ('G21', N'…and a TEACHER_FREE subscription in the same call',
    CAST(@cnt AS nvarchar(10)) + N' subscription', CASE WHEN @cnt = 1 THEN 'PASS' ELSE 'FAIL' END);

DELETE FROM @rt;
INSERT INTO @rt EXEC dbo.USP_ProvisionTeacherProfile
    @UserUid = @newTeacher, @FullName = NULL, @PlanId = @teacherPlan;

INSERT INTO @t
SELECT 'G21', N'🔴 Calling it twice is ALREADY_PROVISIONED, not an error',
       ISNULL(Code, '(created again)'),
       CASE WHEN Status = 1 AND Code = 'ALREADY_PROVISIONED' THEN 'PASS' ELSE 'FAIL' END
FROM @rt;

SELECT @cnt = COUNT(*) FROM dbo.t_app_teachers WHERE UserUid = @newTeacher AND Is_Deleted = 0;
INSERT INTO @t VALUES ('G21', N'…and there is still exactly one profile',
    CAST(@cnt AS nvarchar(10)) + N' profile', CASE WHEN @cnt = 1 THEN 'PASS' ELSE 'FAIL' END);


/*==============================================================================
  10. SCHOOL OWNER PROVISIONING — idempotent, and it feeds the resolver
==============================================================================*/
DECLARE @newOwner uniqueidentifier = NEWID();

DELETE FROM @r;
INSERT INTO @r EXEC dbo.USP_ProvisionSchoolOwner @SchoolId = @schoolB, @UserUid = @newOwner;

INSERT INTO @t
SELECT 'owner', N'An owner can be recorded',
       ISNULL(Code, '(created)'), CASE WHEN Status = 1 THEN 'PASS' ELSE 'FAIL' END
FROM @r;

SELECT @cnt = COUNT(*) FROM dbo.fn_VisibleBranches(@schoolB, @newOwner);
INSERT INTO @t VALUES ('owner', N'🔴 …and the resolver immediately gives them every branch',
    CAST(@cnt AS nvarchar(10)) + N' branches', CASE WHEN @cnt = 1 THEN 'PASS' ELSE 'FAIL' END);

DELETE FROM @r;
INSERT INTO @r EXEC dbo.USP_ProvisionSchoolOwner @SchoolId = @schoolB, @UserUid = @newOwner;

INSERT INTO @t
SELECT 'owner', N'Recording the same owner twice is ALREADY_PROVISIONED',
       ISNULL(Code, '(created again)'),
       CASE WHEN Status = 1 AND Code = 'ALREADY_PROVISIONED' THEN 'PASS' ELSE 'FAIL' END
FROM @r;


/*==============================================================================
  11. 🔴 THE GALLERY — ADDED IN 3F, BECAUSE REORDER DID NOT REORDER

  ---------------------------------------------------------------------------
  The bug this section exists to keep dead
  ---------------------------------------------------------------------------
  USP_SaveSchoolPhotos took a bare id list and derived each photo's position
  with ROW_NUMBER() OVER (ORDER BY Id) — the ID VALUE, not the caller's order.
  So every reorder wrote insertion order, reported "Photos reordered." and
  Status 1, and the list came back unchanged looking like a UI bug.

  It survived 3C's suite because 3C never asserted the ORDER, only that the call
  succeeded. A green suite is not evidence; asking for c, a, b and looking at
  what came back is.
==============================================================================*/
DECLARE @ph1 bigint, @ph2 bigint, @ph3 bigint;
DECLARE @pOrder dbo.OrderedIdList;
DECLARE @rp TABLE (Status int, Code varchar(50), Message nvarchar(400), Id bigint);
DECLARE @capModBefore datetime2, @capModAfter datetime2;

INSERT INTO dbo.t_app_school_photos (SchoolId, FilePath, DisplayOrder) VALUES (@schoolA, N'p-a.jpg', 1);
SET @ph1 = SCOPE_IDENTITY();
INSERT INTO dbo.t_app_school_photos (SchoolId, FilePath, DisplayOrder) VALUES (@schoolA, N'p-b.jpg', 2);
SET @ph2 = SCOPE_IDENTITY();
INSERT INTO dbo.t_app_school_photos (SchoolId, FilePath, DisplayOrder) VALUES (@schoolA, N'p-c.jpg', 3);
SET @ph3 = SCOPE_IDENTITY();

-- Ask for c, a, b — an order the ids alone can never produce.
INSERT INTO @pOrder (Id, Position) VALUES (@ph3, 1), (@ph1, 2), (@ph2, 3);

DELETE FROM @r;
INSERT INTO @r EXEC dbo.USP_SaveSchoolPhotos
    @SchoolId = @schoolA, @UserUid = @ownerA, @Action = 'REORDER', @PhotoOrder = @pOrder;

SELECT @cnt = COUNT(*) FROM dbo.t_app_school_photos
WHERE (PhotoId = @ph3 AND DisplayOrder = 1)
   OR (PhotoId = @ph1 AND DisplayOrder = 2)
   OR (PhotoId = @ph2 AND DisplayOrder = 3);
INSERT INTO @t VALUES ('photos NEG', N'🔴 REORDER honours the ORDER SENT, not the id order',
    CAST(@cnt AS nvarchar(10)) + N' of 3 in place', CASE WHEN @cnt = 3 THEN 'PASS' ELSE 'FAIL' END);

-- The captions.
DELETE FROM @r;
INSERT INTO @r EXEC dbo.USP_SaveSchoolPhotos
    @SchoolId = @schoolA, @UserUid = @ownerA, @Action = 'CAPTION',
    @PhotoId = @ph1, @Caption = N'The quadrangle', @PhotoOrder = @pOrder;

SELECT @cnt = COUNT(*) FROM dbo.t_app_school_photos
WHERE PhotoId = @ph1 AND Caption = N'The quadrangle' AND FilePath = N'p-a.jpg' AND DisplayOrder = 2;
INSERT INTO @t VALUES ('photos', N'CAPTION retitles one photo and touches nothing else',
    CAST(@cnt AS nvarchar(10)) + N' row', CASE WHEN @cnt = 1 THEN 'PASS' ELSE 'FAIL' END);

SELECT @capModBefore = ModifiedOn FROM dbo.t_app_school_photos WHERE PhotoId = @ph1;

DELETE FROM @r;
INSERT INTO @r EXEC dbo.USP_SaveSchoolPhotos
    @SchoolId = @schoolA, @UserUid = @ownerA, @Action = 'CAPTION',
    @PhotoId = @ph1, @Caption = N'The quadrangle', @PhotoOrder = @pOrder;

SELECT @capModAfter = ModifiedOn FROM dbo.t_app_school_photos WHERE PhotoId = @ph1;
INSERT INTO @t VALUES ('photos NEG', N'🔴 …and the same caption again writes NOTHING (2.54)',
    CONVERT(nvarchar(30), @capModAfter, 126),
    CASE WHEN @capModBefore = @capModAfter THEN 'PASS' ELSE 'FAIL' END);

-- 🔴 And the cross-school case, which is the reason PhotoId is checked at all.
DELETE FROM @r;
INSERT INTO @r EXEC dbo.USP_SaveSchoolPhotos
    @SchoolId = @schoolB, @UserUid = @ownerB, @Action = 'DELETE',
    @PhotoId = @ph1, @PhotoOrder = @pOrder;

INSERT INTO @t
SELECT 'photos NEG', N'🔴 Another school cannot delete our photo',
       ISNULL(Code, '(deleted it)'),
       CASE WHEN Status = 0 AND Code = 'NOT_FOUND' THEN 'PASS' ELSE 'FAIL' END
FROM @r;

SELECT @cnt = COUNT(*) FROM dbo.t_app_school_photos WHERE PhotoId = @ph1 AND Is_Deleted = 0;
INSERT INTO @t VALUES ('photos NEG', N'🔴 …and it is still there',
    CAST(@cnt AS nvarchar(10)) + N' row', CASE WHEN @cnt = 1 THEN 'PASS' ELSE 'FAIL' END);

-- The media path read, which is what lets a browser show any of this.
SELECT @cnt = COUNT(*) FROM (
    SELECT FilePath FROM dbo.t_app_school_photos p
    WHERE p.PhotoId = @ph1 AND p.Is_Deleted = 0
      AND dbo.fn_IsSchoolMember(p.SchoolId, @ownerA) = 1) x;
INSERT INTO @t VALUES ('photos', N'A member can resolve a photo''s stored path',
    CAST(@cnt AS nvarchar(10)) + N' row', CASE WHEN @cnt = 1 THEN 'PASS' ELSE 'FAIL' END);

SELECT @cnt = COUNT(*) FROM (
    SELECT FilePath FROM dbo.t_app_school_photos p
    WHERE p.PhotoId = @ph1 AND p.Is_Deleted = 0
      AND dbo.fn_IsSchoolMember(p.SchoolId, @ownerB) = 1) x;
INSERT INTO @t VALUES ('photos NEG', N'🔴 …and another school''s owner resolves ZERO',
    CAST(@cnt AS nvarchar(10)) + N' rows', CASE WHEN @cnt = 0 THEN 'PASS' ELSE 'FAIL' END);


ROLLBACK TRANSACTION;

/*==============================================================================
  RESULTS
==============================================================================*/
PRINT '';
PRINT '===============================================================================';
SELECT RIGHT('  ' + CAST(n AS varchar(3)), 3) + '  '
     + LEFT(section + REPLICATE(' ', 13), 13) + '  '
     + LEFT(what + REPLICATE(N' ', 58), 58) + '  '
     + LEFT(got + REPLICATE(N' ', 22), 22) + '  ' + pass
FROM @t ORDER BY n;

DECLARE @total int = (SELECT COUNT(*) FROM @t),
        @failed int = (SELECT COUNT(*) FROM @t WHERE pass = 'FAIL'),
        @negTotal int = (SELECT COUNT(*) FROM @t WHERE section LIKE '%NEG%'),
        @negFailed int = (SELECT COUNT(*) FROM @t WHERE section LIKE '%NEG%' AND pass = 'FAIL');

PRINT '===============================================================================';
PRINT '  SCHOOL + BRANCH: TOTAL ' + CAST(@total AS varchar(4))
    + '   PASSED ' + CAST(@total - @failed AS varchar(4))
    + '   FAILED ' + CAST(@failed AS varchar(4));
PRINT '  🔴 NEGATIVE CASES: ' + CAST(@negTotal AS varchar(4))
    + '   PASSED ' + CAST(@negTotal - @negFailed AS varchar(4))
    + '   FAILED ' + CAST(@negFailed AS varchar(4));
PRINT '===============================================================================';
GO
