/*==============================================================================
  jp_app — 99_tests / 003_test_school_team.sql

  PHASE 3G — school team management.

  ---------------------------------------------------------------------------
  🔴 WHAT THIS SUITE IS FOR
  ---------------------------------------------------------------------------
  Four invariants, and they are all NEGATIVE:

      the owner cannot be demoted or deactivated — by anyone, including
        themselves, and nobody can be promoted into their place;
      a school user cannot touch another school's team, by any parameter they
        control;
      a full-set sync never removes what the caller could not see;
      deactivation revokes access without erasing anything.

  Each of those passes trivially against a procedure that refuses everything, so
  the positive cases are here too — but the ones with 🔴 on them are the reason
  the file exists.

  ---------------------------------------------------------------------------
  ⚠️ USP_GetSchoolUserList IS NOT TESTED HERE, AND THAT IS DELIBERATE
  ---------------------------------------------------------------------------
  It returns TWO result sets, and INSERT..EXEC cannot capture a procedure that
  does — Msg 213, the same wall 3C hit with the school public profile. Writing
  assertions that MIRROR its predicates instead would be worth very little: they
  would pass against a procedure that had dropped the join entirely.

  So it is verified over real HTTP instead, against the running API, in
  jp-docs/scripts/verify/team-contract.mjs — where the response body is the
  thing being read rather than a restatement of the query. Recorded here so
  nobody reads its absence as an oversight.

  Conventions (2.30):
    - table VARIABLES for the assertion log, never #temp
    - plain EXEC into a table variable
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

DECLARE @ownerA   uniqueidentifier = NEWID(),
        @hrA      uniqueidentifier = NEWID(),   -- HR, scoped to a1 only
        @seniorA  uniqueidentifier = NEWID(),   -- Senior HR, scoped to a1 + a2
        @newbie   uniqueidentifier = NEWID(),   -- the person being invited
        @ownerB   uniqueidentifier = NEWID(),
        @stranger uniqueidentifier = NEWID();

DECLARE @suOwnerA bigint, @suHrA bigint, @suSeniorA bigint, @suNewbie bigint, @suB bigint;
DECLARE @cnt int, @orgA uniqueidentifier = NEWID(), @orgB uniqueidentifier = NEWID();
DECLARE @modBefore datetime2, @modAfter datetime2, @createdOn datetime2, @linkId bigint, @linkId2 bigint;
DECLARE @roleNow tinyint, @activeNow tinyint;

-- Result envelopes, one shape per procedure.
DECLARE @rp TABLE (Status int, Code varchar(50), Message nvarchar(400), Id bigint, BranchesLinked int);
DECLARE @rr TABLE (Status int, Code varchar(50), Message nvarchar(400), Id bigint, Changed bit);
DECLARE @rb TABLE (Status int, Code varchar(50), Message nvarchar(400), Id bigint, Added int, Restored int, Removed int);
DECLARE @rd TABLE (Status int, Code varchar(50), Message nvarchar(400), Id bigint);

-- Branch id lists, built per call.
DECLARE @none dbo.BigIntIdList;
DECLARE @one  dbo.BigIntIdList;
DECLARE @two  dbo.BigIntIdList;

BEGIN TRANSACTION;

/*==============================================================================
  FIXTURE

  School A: an owner with NO link rows, an HR scoped to one campus, and a
            Senior HR scoped to two. The Senior HR exists so that "a colleague
            with access the caller cannot see" is a real row rather than a
            hypothesis.
  School B: its own owner, so "another school" is real too.
==============================================================================*/
INSERT INTO dbo.t_app_schools (OrganizationUid, SchoolName, IsVerified, StateId)
VALUES (@orgA, N'Team Test School A', 1, 32);
SET @schoolA = SCOPE_IDENTITY();

INSERT INTO dbo.t_app_schools (OrganizationUid, SchoolName, IsVerified, StateId)
VALUES (@orgB, N'Team Test School B', 1, 14);
SET @schoolB = SCOPE_IDENTITY();

INSERT INTO dbo.t_app_school_branches (SchoolId, BranchName, IsHeadOffice, StateId, CreatedBy)
VALUES (@schoolA, N'A — Head Office', 1, 32, 9001);
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

-- 🔴 The owner has NO link rows. That is what "owner" means here (2.51).
INSERT INTO dbo.t_app_school_users (SchoolId, UserUid, RoleInSchool, FullName)
VALUES (@schoolA, @ownerA, 1, NULL);              -- name deliberately NULL, as provisioning leaves it
SET @suOwnerA = SCOPE_IDENTITY();

INSERT INTO dbo.t_app_school_users (SchoolId, UserUid, RoleInSchool, FullName)
VALUES (@schoolA, @hrA, 3, N'Rekha Nair');
SET @suHrA = SCOPE_IDENTITY();
INSERT INTO dbo.t_app_school_user_branches (SchoolUserId, BranchId) VALUES (@suHrA, @a1);

INSERT INTO dbo.t_app_school_users (SchoolId, UserUid, RoleInSchool, FullName)
VALUES (@schoolA, @seniorA, 2, N'Imtiaz Shaikh');
SET @suSeniorA = SCOPE_IDENTITY();
INSERT INTO dbo.t_app_school_user_branches (SchoolUserId, BranchId) VALUES (@suSeniorA, @a1);
INSERT INTO dbo.t_app_school_user_branches (SchoolUserId, BranchId) VALUES (@suSeniorA, @a2);

INSERT INTO dbo.t_app_school_users (SchoolId, UserUid, RoleInSchool) VALUES (@schoolB, @ownerB, 1);
SET @suB = SCOPE_IDENTITY();


/*==============================================================================
  1. 🔴 THE OWNER IS UNTOUCHABLE

  Four attempts from two directions. A school with no owner cannot administer
  itself and cannot undo the change that got it there.
==============================================================================*/
DELETE FROM @rr;
INSERT INTO @rr EXEC dbo.USP_SaveSchoolUserRole
    @SchoolId = @schoolA, @UserUid = @ownerA, @TargetUserUid = @ownerA, @RoleInSchool = 3;
INSERT INTO @t
SELECT 'owner NEG', N'🔴 The owner cannot demote THEMSELVES',
       ISNULL(Code, '(succeeded)'),
       CASE WHEN Status = 0 AND Code = 'BUSINESS_RULE_VIOLATED' THEN 'PASS' ELSE 'FAIL' END FROM @rr;

DELETE FROM @rr;
INSERT INTO @rr EXEC dbo.USP_SaveSchoolUserRole
    @SchoolId = @schoolA, @UserUid = @seniorA, @TargetUserUid = @ownerA, @RoleInSchool = 4;
INSERT INTO @t
SELECT 'owner NEG', N'🔴 …nor can a colleague demote them',
       ISNULL(Code, '(succeeded)'),
       CASE WHEN Status = 0 AND Code = 'BUSINESS_RULE_VIOLATED' THEN 'PASS' ELSE 'FAIL' END FROM @rr;

DELETE FROM @rd;
INSERT INTO @rd EXEC dbo.USP_DeactivateSchoolUser
    @SchoolId = @schoolA, @UserUid = @ownerA, @TargetUserUid = @ownerA;
INSERT INTO @t
SELECT 'owner NEG', N'🔴 The owner cannot deactivate themselves',
       ISNULL(Code, '(succeeded)'),
       CASE WHEN Status = 0 AND Code = 'BUSINESS_RULE_VIOLATED' THEN 'PASS' ELSE 'FAIL' END FROM @rd;

DELETE FROM @rd;
INSERT INTO @rd EXEC dbo.USP_DeactivateSchoolUser
    @SchoolId = @schoolA, @UserUid = @seniorA, @TargetUserUid = @ownerA;
INSERT INTO @t
SELECT 'owner NEG', N'🔴 …nor can a colleague deactivate them',
       ISNULL(Code, '(succeeded)'),
       CASE WHEN Status = 0 AND Code = 'BUSINESS_RULE_VIOLATED' THEN 'PASS' ELSE 'FAIL' END FROM @rd;

-- The row itself, after four attempts. Codes are worth nothing if the write
-- happened anyway.
SELECT @roleNow = RoleInSchool, @activeNow = Is_Active
FROM dbo.t_app_school_users WHERE SchoolUserId = @suOwnerA;
INSERT INTO @t VALUES ('owner NEG', N'🔴 …and the owner row is untouched: still role 1, still active',
    N'role ' + CAST(@roleNow AS nvarchar(3)) + N', active ' + CAST(@activeNow AS nvarchar(3)),
    CASE WHEN @roleNow = 1 AND @activeNow = 1 THEN 'PASS' ELSE 'FAIL' END);

-- Nobody may be promoted into the role either — see rule 2.
DELETE FROM @rr;
INSERT INTO @rr EXEC dbo.USP_SaveSchoolUserRole
    @SchoolId = @schoolA, @UserUid = @ownerA, @TargetUserUid = @seniorA, @RoleInSchool = 1;
INSERT INTO @t
SELECT 'owner NEG', N'🔴 Nobody can be PROMOTED to owner either',
       ISNULL(Code, '(succeeded)'),
       CASE WHEN Status = 0 AND Code = 'BUSINESS_RULE_VIOLATED' THEN 'PASS' ELSE 'FAIL' END FROM @rr;

DELETE FROM @rp;
INSERT INTO @rp EXEC dbo.USP_ProvisionSchoolUser
    @SchoolId = @schoolA, @UserUid = @ownerA, @NewUserUid = @newbie,
    @RoleInSchool = 1, @BranchIds = @none;
INSERT INTO @t
SELECT 'owner NEG', N'🔴 …and a second owner cannot be INVITED in',
       ISNULL(Code, '(succeeded)'),
       CASE WHEN Status = 0 AND Code = 'BUSINESS_RULE_VIOLATED' THEN 'PASS' ELSE 'FAIL' END FROM @rp;

/*
  🔴 THE DISTINCTION THAT MATTERS: the owner's ROLE is frozen, their ROW is not.

  Every membership provisioning ever created has FullName NULL. If the guard
  were "the owner row cannot be written", no owner could put their own name on
  their own team screen, forever.
*/
DELETE FROM @rr;
INSERT INTO @rr EXEC dbo.USP_SaveSchoolUserRole
    @SchoolId = @schoolA, @UserUid = @ownerA, @TargetUserUid = @ownerA,
    @RoleInSchool = 1, @FullName = N'Vandana Rao', @DesignationText = N'Trustee';
INSERT INTO @t
SELECT 'owner', N'🔴 …but the owner CAN set their own name (role unchanged)',
       ISNULL(Code, '(ok)') + N' / changed ' + CAST(Changed AS nvarchar(3)),
       CASE WHEN Status = 1 AND Changed = 1 THEN 'PASS' ELSE 'FAIL' END FROM @rr;

SELECT @cnt = COUNT(*) FROM dbo.t_app_school_users
WHERE SchoolUserId = @suOwnerA AND FullName = N'Vandana Rao' AND RoleInSchool = 1;
INSERT INTO @t VALUES ('owner', N'…and the name is on the row, with role still 1',
    CAST(@cnt AS nvarchar(4)) + N' row', CASE WHEN @cnt = 1 THEN 'PASS' ELSE 'FAIL' END);

-- Rule 3, from the other side: an owner may not be given link rows.
DELETE FROM @two; INSERT INTO @two (Id) VALUES (@a1), (@a2);
DELETE FROM @rb;
INSERT INTO @rb EXEC dbo.USP_SaveSchoolUserBranches
    @SchoolId = @schoolA, @UserUid = @ownerA, @TargetUserUid = @ownerA, @BranchIds = @two;
INSERT INTO @t
SELECT 'owner NEG', N'🔴 An owner cannot be given campus rows',
       ISNULL(Code, '(succeeded)'),
       CASE WHEN Status = 0 AND Code = 'BUSINESS_RULE_VIOLATED' THEN 'PASS' ELSE 'FAIL' END FROM @rb;

SELECT @cnt = COUNT(*) FROM dbo.t_app_school_user_branches WHERE SchoolUserId = @suOwnerA;
INSERT INTO @t VALUES ('owner NEG', N'🔴 …and ZERO rows were written for them',
    CAST(@cnt AS nvarchar(4)) + N' rows', CASE WHEN @cnt = 0 THEN 'PASS' ELSE 'FAIL' END);


/*==============================================================================
  2. 🔴 ANOTHER SCHOOL'S TEAM IS NOT REACHABLE

  Two shapes of the same attack:
    - school B's owner, acting inside their OWN school, naming a member of A;
    - a forged @SchoolId, naming school A while holding no membership in it.

  Both must be NOT_FOUND. Not 403 — a different status for "exists but is not
  yours" confirms that the account exists (2.48).
==============================================================================*/
DELETE FROM @rr;
INSERT INTO @rr EXEC dbo.USP_SaveSchoolUserRole
    @SchoolId = @schoolB, @UserUid = @ownerB, @TargetUserUid = @hrA, @RoleInSchool = 4;
INSERT INTO @t
SELECT 'cross NEG', N'🔴 School B''s owner cannot re-role a member of school A',
       ISNULL(Code, '(succeeded)'),
       CASE WHEN Status = 0 AND Code = 'NOT_FOUND' THEN 'PASS' ELSE 'FAIL' END FROM @rr;

DELETE FROM @rr;
INSERT INTO @rr EXEC dbo.USP_SaveSchoolUserRole
    @SchoolId = @schoolA, @UserUid = @ownerB, @TargetUserUid = @hrA, @RoleInSchool = 4;
INSERT INTO @t
SELECT 'cross NEG', N'🔴 …nor by naming school A directly',
       ISNULL(Code, '(succeeded)'),
       CASE WHEN Status = 0 AND Code = 'NOT_FOUND' THEN 'PASS' ELSE 'FAIL' END FROM @rr;

DELETE FROM @one; INSERT INTO @one (Id) VALUES (@b1);
DELETE FROM @rb;
INSERT INTO @rb EXEC dbo.USP_SaveSchoolUserBranches
    @SchoolId = @schoolA, @UserUid = @ownerB, @TargetUserUid = @hrA, @BranchIds = @one;
INSERT INTO @t
SELECT 'cross NEG', N'🔴 …nor set their campus scope',
       ISNULL(Code, '(succeeded)'),
       CASE WHEN Status = 0 AND Code = 'NOT_FOUND' THEN 'PASS' ELSE 'FAIL' END FROM @rb;

DELETE FROM @rd;
INSERT INTO @rd EXEC dbo.USP_DeactivateSchoolUser
    @SchoolId = @schoolA, @UserUid = @ownerB, @TargetUserUid = @hrA;
INSERT INTO @t
SELECT 'cross NEG', N'🔴 …nor deactivate them',
       ISNULL(Code, '(succeeded)'),
       CASE WHEN Status = 0 AND Code = 'NOT_FOUND' THEN 'PASS' ELSE 'FAIL' END FROM @rd;

DELETE FROM @rp;
INSERT INTO @rp EXEC dbo.USP_ProvisionSchoolUser
    @SchoolId = @schoolA, @UserUid = @stranger, @NewUserUid = @newbie,
    @RoleInSchool = 3, @BranchIds = @none;
INSERT INTO @t
SELECT 'cross NEG', N'🔴 A user with no membership cannot invite anybody',
       ISNULL(Code, '(succeeded)'),
       CASE WHEN Status = 0 AND Code = 'NOT_FOUND' THEN 'PASS' ELSE 'FAIL' END FROM @rp;

-- 🔴 And the target row is exactly as it was: role 3, active, one campus.
SELECT @cnt = COUNT(*)
FROM dbo.t_app_school_users su
WHERE su.SchoolUserId = @suHrA AND su.RoleInSchool = 3 AND su.Is_Active = 1;
INSERT INTO @t VALUES ('cross NEG', N'🔴 …and school A''s HR row survived all of it',
    CAST(@cnt AS nvarchar(4)) + N' row', CASE WHEN @cnt = 1 THEN 'PASS' ELSE 'FAIL' END);

SELECT @cnt = COUNT(*) FROM dbo.t_app_school_user_branches
WHERE SchoolUserId = @suHrA AND Is_Deleted = 0;
INSERT INTO @t VALUES ('cross NEG', N'🔴 …with its one campus link intact',
    CAST(@cnt AS nvarchar(4)) + N' link', CASE WHEN @cnt = 1 THEN 'PASS' ELSE 'FAIL' END);


/*==============================================================================
  3. THE BRIDGE SYNC — add, no-op, remove, revive
==============================================================================*/
DELETE FROM @two; INSERT INTO @two (Id) VALUES (@a1), (@a2);
DELETE FROM @rb;
INSERT INTO @rb EXEC dbo.USP_SaveSchoolUserBranches
    @SchoolId = @schoolA, @UserUid = @ownerA, @TargetUserUid = @hrA, @BranchIds = @two;
INSERT INTO @t
SELECT 'sync', N'Adding a campus: added 1, removed 0',
       N'+' + CAST(Added AS nvarchar(3)) + N' ~' + CAST(Restored AS nvarchar(3)) + N' -' + CAST(Removed AS nvarchar(3)),
       CASE WHEN Status = 1 AND Added = 1 AND Restored = 0 AND Removed = 0 THEN 'PASS' ELSE 'FAIL' END FROM @rb;

SELECT @cnt = COUNT(*) FROM dbo.fn_VisibleBranches(@schoolA, @hrA);
INSERT INTO @t VALUES ('sync', N'…and the resolver now gives them 2',
    CAST(@cnt AS nvarchar(4)) + N' branches', CASE WHEN @cnt = 2 THEN 'PASS' ELSE 'FAIL' END);

/*
  🔴 THE NO-OP. 3D shipped a save that changed nothing and stamped ModifiedOn
  anyway (2.54), and it was found by an independent check rather than by a
  suite. So: same set again, and NOTHING may move — not the links, and not the
  membership row above them.
*/
SELECT @modBefore = ModifiedOn FROM dbo.t_app_school_users WHERE SchoolUserId = @suHrA;

DELETE FROM @rb;
INSERT INTO @rb EXEC dbo.USP_SaveSchoolUserBranches
    @SchoolId = @schoolA, @UserUid = @ownerA, @TargetUserUid = @hrA, @BranchIds = @two;
INSERT INTO @t
SELECT 'sync NEG', N'🔴 Saving the same set writes NOTHING',
       N'+' + CAST(Added AS nvarchar(3)) + N' ~' + CAST(Restored AS nvarchar(3)) + N' -' + CAST(Removed AS nvarchar(3)),
       CASE WHEN Status = 1 AND Added = 0 AND Restored = 0 AND Removed = 0 THEN 'PASS' ELSE 'FAIL' END FROM @rb;

SELECT @modAfter = ModifiedOn FROM dbo.t_app_school_users WHERE SchoolUserId = @suHrA;
INSERT INTO @t VALUES ('sync NEG', N'🔴 …and does not stamp the membership row either',
    CASE WHEN @modAfter IS NULL THEN N'(still NULL)' ELSE CONVERT(nvarchar(30), @modAfter, 126) END,
    CASE WHEN (@modBefore IS NULL AND @modAfter IS NULL) OR @modBefore = @modAfter THEN 'PASS' ELSE 'FAIL' END);

-- Removal, and then the revive that proves a tombstone is reused rather than
-- inserted beside.
SELECT @linkId = Id FROM dbo.t_app_school_user_branches
WHERE SchoolUserId = @suHrA AND BranchId = @a2;

DELETE FROM @one; INSERT INTO @one (Id) VALUES (@a1);
DELETE FROM @rb;
INSERT INTO @rb EXEC dbo.USP_SaveSchoolUserBranches
    @SchoolId = @schoolA, @UserUid = @ownerA, @TargetUserUid = @hrA, @BranchIds = @one;
INSERT INTO @t
SELECT 'sync', N'Dropping a campus: removed 1',
       N'+' + CAST(Added AS nvarchar(3)) + N' -' + CAST(Removed AS nvarchar(3)),
       CASE WHEN Status = 1 AND Removed = 1 AND Added = 0 THEN 'PASS' ELSE 'FAIL' END FROM @rb;

SELECT @cnt = COUNT(*) FROM dbo.fn_VisibleBranches(@schoolA, @hrA) WHERE BranchId = @a2;
INSERT INTO @t VALUES ('sync NEG', N'🔴 …and the dropped campus resolves to ZERO',
    CAST(@cnt AS nvarchar(4)) + N' rows', CASE WHEN @cnt = 0 THEN 'PASS' ELSE 'FAIL' END);

DELETE FROM @rb;
INSERT INTO @rb EXEC dbo.USP_SaveSchoolUserBranches
    @SchoolId = @schoolA, @UserUid = @ownerA, @TargetUserUid = @hrA, @BranchIds = @two;
INSERT INTO @t
SELECT 'sync', N'Adding it back RESTORES the tombstone (added 0)',
       N'+' + CAST(Added AS nvarchar(3)) + N' ~' + CAST(Restored AS nvarchar(3)),
       CASE WHEN Status = 1 AND Restored = 1 AND Added = 0 THEN 'PASS' ELSE 'FAIL' END FROM @rb;

SELECT @linkId2 = Id FROM dbo.t_app_school_user_branches
WHERE SchoolUserId = @suHrA AND BranchId = @a2 AND Is_Deleted = 0;
INSERT INTO @t VALUES ('sync', N'…and it is the SAME row, not a second one',
    N'id ' + CAST(ISNULL(@linkId2, 0) AS nvarchar(12)),
    CASE WHEN @linkId2 = @linkId THEN 'PASS' ELSE 'FAIL' END);


/*==============================================================================
  4. 🔴 A FULL-SET SYNC NEVER REMOVES WHAT THE CALLER COULD NOT SEE

  The failure this prevents:

    An HR scoped to the head office opens a Senior HR colleague's campus
    access. The screen can only show them campuses they themselves can see —
    one. They untick nothing, save, and the plain full-set pattern would
    silently revoke that colleague's access to the North campus, which was
    never on the screen.

  It would look like a successful save. The colleague would find out by losing a
  campus.
==============================================================================*/
/*
  ⚠️ RESET THE FIXTURE FIRST — and this line is here because the suite caught
  the test being wrong before it caught anything else.

  Section 3 left the branch HR with TWO campuses. The assertion below then
  "passed" a save that removed both, because by that point the caller really
  could see both — the check had quietly become vacuous while still looking
  like it was testing something.

  A scoping test whose premise has drifted is worse than no test: it reports
  PASS for the exact bug it was written to catch.
*/
DELETE FROM @one; INSERT INTO @one (Id) VALUES (@a1);
DELETE FROM @rb;
INSERT INTO @rb EXEC dbo.USP_SaveSchoolUserBranches
    @SchoolId = @schoolA, @UserUid = @ownerA, @TargetUserUid = @hrA, @BranchIds = @one;

SELECT @cnt = COUNT(*) FROM dbo.fn_VisibleBranches(@schoolA, @hrA);
INSERT INTO @t VALUES ('scoped sync', N'Premise: the branch HR can see exactly 1 campus',
    CAST(@cnt AS nvarchar(4)) + N' branches', CASE WHEN @cnt = 1 THEN 'PASS' ELSE 'FAIL' END);

SELECT @cnt = COUNT(*) FROM dbo.t_app_school_user_branches
WHERE SchoolUserId = @suSeniorA AND Is_Deleted = 0;
INSERT INTO @t VALUES ('scoped sync', N'…and the Senior HR has 2, one of them invisible to the HR',
    CAST(@cnt AS nvarchar(4)) + N' links', CASE WHEN @cnt = 2 THEN 'PASS' ELSE 'FAIL' END);

-- The branch HR (visible: a1 only) saves an EMPTY set for that colleague.
DELETE FROM @rb;
INSERT INTO @rb EXEC dbo.USP_SaveSchoolUserBranches
    @SchoolId = @schoolA, @UserUid = @hrA, @TargetUserUid = @seniorA, @BranchIds = @none;
INSERT INTO @t
SELECT 'scoped sync', N'A branch HR''s empty save removes only what THEY can see',
       N'-' + CAST(Removed AS nvarchar(3)),
       CASE WHEN Status = 1 AND Removed = 1 THEN 'PASS' ELSE 'FAIL' END FROM @rb;

SELECT @cnt = COUNT(*) FROM dbo.fn_VisibleBranches(@schoolA, @seniorA) WHERE BranchId = @a2;
INSERT INTO @t VALUES ('scoped sync', N'🔴 …the campus they could NOT see survives',
    CAST(@cnt AS nvarchar(4)) + N' rows', CASE WHEN @cnt = 1 THEN 'PASS' ELSE 'FAIL' END);

-- Put it back, so the rest of the file starts from the fixture.
DELETE FROM @rb;
INSERT INTO @rb EXEC dbo.USP_SaveSchoolUserBranches
    @SchoolId = @schoolA, @UserUid = @ownerA, @TargetUserUid = @seniorA, @BranchIds = @two;

-- 🔴 And the other half of the same rule: you cannot GRANT what you cannot see.
DELETE FROM @one; INSERT INTO @one (Id) VALUES (@a3);
DELETE FROM @rb;
INSERT INTO @rb EXEC dbo.USP_SaveSchoolUserBranches
    @SchoolId = @schoolA, @UserUid = @hrA, @TargetUserUid = @seniorA, @BranchIds = @one;
INSERT INTO @t
SELECT 'scoped sync NEG', N'🔴 A branch HR cannot grant a campus they cannot see',
       ISNULL(Code, '(succeeded)'),
       CASE WHEN Status = 0 AND Code = 'VALIDATION_FAILED' THEN 'PASS' ELSE 'FAIL' END FROM @rb;

SELECT @cnt = COUNT(*) FROM dbo.fn_VisibleBranches(@schoolA, @seniorA) WHERE BranchId = @a3;
INSERT INTO @t VALUES ('scoped sync NEG', N'🔴 …and nothing was granted',
    CAST(@cnt AS nvarchar(4)) + N' rows', CASE WHEN @cnt = 0 THEN 'PASS' ELSE 'FAIL' END);

-- The same gate on the invite path — including granting it to THEMSELVES.
DELETE FROM @rp;
INSERT INTO @rp EXEC dbo.USP_ProvisionSchoolUser
    @SchoolId = @schoolA, @UserUid = @hrA, @NewUserUid = @newbie,
    @RoleInSchool = 3, @BranchIds = @one;
INSERT INTO @t
SELECT 'scoped sync NEG', N'🔴 …nor invite somebody INTO a campus they cannot see',
       ISNULL(Code, '(succeeded)'),
       CASE WHEN Status = 0 AND Code = 'VALIDATION_FAILED' THEN 'PASS' ELSE 'FAIL' END FROM @rp;


/*==============================================================================
  5. THE INVITE — idempotent on UserUid, because its other half is in jp_sso

  A partial failure leaves an account with no membership, and the retry has to
  converge rather than double up or refuse forever (2.48).
==============================================================================*/
DELETE FROM @two; INSERT INTO @two (Id) VALUES (@a1), (@a2);
DELETE FROM @rp;
INSERT INTO @rp EXEC dbo.USP_ProvisionSchoolUser
    @SchoolId = @schoolA, @UserUid = @ownerA, @NewUserUid = @newbie,
    @RoleInSchool = 2, @FullName = N'Farhan Qureshi', @DesignationText = N'Vice Principal (Academics)',
    @BranchIds = @two;
SELECT @suNewbie = Id FROM @rp;
INSERT INTO @t
SELECT 'invite', N'A colleague is added, with their campuses',
       ISNULL(Code, '(ok)') + N' / ' + CAST(BranchesLinked AS nvarchar(3)) + N' campuses',
       CASE WHEN Status = 1 AND Code IS NULL AND BranchesLinked = 2 THEN 'PASS' ELSE 'FAIL' END FROM @rp;

SELECT @cnt = COUNT(*) FROM dbo.fn_VisibleBranches(@schoolA, @newbie);
INSERT INTO @t VALUES ('invite', N'…and the resolver gives them exactly those 2',
    CAST(@cnt AS nvarchar(4)) + N' branches', CASE WHEN @cnt = 2 THEN 'PASS' ELSE 'FAIL' END);

-- 🔴 The retry. Same call, and it must neither duplicate nor fail.
DELETE FROM @rp;
INSERT INTO @rp EXEC dbo.USP_ProvisionSchoolUser
    @SchoolId = @schoolA, @UserUid = @ownerA, @NewUserUid = @newbie,
    @RoleInSchool = 4, @BranchIds = @none;
INSERT INTO @t
SELECT 'invite', N'🔴 Re-inviting is ALREADY_A_MEMBER, not an error',
       ISNULL(Code, '(created again)'),
       CASE WHEN Status = 1 AND Code = 'ALREADY_A_MEMBER' THEN 'PASS' ELSE 'FAIL' END FROM @rp;

/*
  🔴 …and it changed NOTHING. The retry above asked for role 4 and no campuses.
  If an invite could quietly re-role an existing member it would be a way around
  USP_SaveSchoolUserRole and its owner guard.
*/
SELECT @roleNow = RoleInSchool FROM dbo.t_app_school_users WHERE SchoolUserId = @suNewbie;
SELECT @cnt = COUNT(*) FROM dbo.fn_VisibleBranches(@schoolA, @newbie);
INSERT INTO @t VALUES ('invite NEG', N'🔴 …and an invite cannot re-role or re-scope a member',
    N'role ' + CAST(@roleNow AS nvarchar(3)) + N', ' + CAST(@cnt AS nvarchar(3)) + N' campuses',
    CASE WHEN @roleNow = 2 AND @cnt = 2 THEN 'PASS' ELSE 'FAIL' END);

SELECT @cnt = COUNT(*) FROM dbo.t_app_school_users
WHERE SchoolId = @schoolA AND UserUid = @newbie AND Is_Deleted = 0;
INSERT INTO @t VALUES ('invite', N'…and there is exactly ONE membership row for them',
    CAST(@cnt AS nvarchar(4)) + N' rows', CASE WHEN @cnt = 1 THEN 'PASS' ELSE 'FAIL' END);


/*==============================================================================
  6. THE ROLE SAVE, AND ITS NO-OP
==============================================================================*/
DELETE FROM @rr;
INSERT INTO @rr EXEC dbo.USP_SaveSchoolUserRole
    @SchoolId = @schoolA, @UserUid = @ownerA, @TargetUserUid = @newbie,
    @RoleInSchool = 3, @FullName = N'Farhan Qureshi', @DesignationText = N'Vice Principal (Academics)';
INSERT INTO @t
SELECT 'role', N'A real change reports Changed = 1',
       N'changed ' + CAST(Changed AS nvarchar(3)),
       CASE WHEN Status = 1 AND Changed = 1 THEN 'PASS' ELSE 'FAIL' END FROM @rr;

SELECT @modBefore = ModifiedOn FROM dbo.t_app_school_users WHERE SchoolUserId = @suNewbie;

DELETE FROM @rr;
INSERT INTO @rr EXEC dbo.USP_SaveSchoolUserRole
    @SchoolId = @schoolA, @UserUid = @ownerA, @TargetUserUid = @newbie,
    @RoleInSchool = 3, @FullName = N'Farhan Qureshi', @DesignationText = N'Vice Principal (Academics)';
INSERT INTO @t
SELECT 'role NEG', N'🔴 Saving the same values reports Changed = 0',
       N'changed ' + CAST(Changed AS nvarchar(3)),
       CASE WHEN Status = 1 AND Changed = 0 THEN 'PASS' ELSE 'FAIL' END FROM @rr;

SELECT @modAfter = ModifiedOn FROM dbo.t_app_school_users WHERE SchoolUserId = @suNewbie;
INSERT INTO @t VALUES ('role NEG', N'🔴 …and ModifiedOn did not move',
    CONVERT(nvarchar(30), @modAfter, 126),
    CASE WHEN @modBefore = @modAfter THEN 'PASS' ELSE 'FAIL' END);

DELETE FROM @rr;
INSERT INTO @rr EXEC dbo.USP_SaveSchoolUserRole
    @SchoolId = @schoolA, @UserUid = @ownerA, @TargetUserUid = @stranger, @RoleInSchool = 3;
INSERT INTO @t
SELECT 'role NEG', N'🔴 A uid that is on no team at all is NOT_FOUND',
       ISNULL(Code, '(succeeded)'),
       CASE WHEN Status = 0 AND Code = 'NOT_FOUND' THEN 'PASS' ELSE 'FAIL' END FROM @rr;


/*==============================================================================
  7. 🔴 DEACTIVATION REVOKES ACCESS AND ERASES NOTHING
==============================================================================*/
SELECT @createdOn = CreatedOn FROM dbo.t_app_school_users WHERE SchoolUserId = @suHrA;

DELETE FROM @rd;
INSERT INTO @rd EXEC dbo.USP_DeactivateSchoolUser
    @SchoolId = @schoolA, @UserUid = @ownerA, @TargetUserUid = @hrA;
INSERT INTO @t
SELECT 'deactivate', N'An HR''s access is removed',
       ISNULL(Code, '(ok)'), CASE WHEN Status = 1 AND Code IS NULL THEN 'PASS' ELSE 'FAIL' END FROM @rd;

SELECT @cnt = COUNT(*) FROM dbo.fn_VisibleBranches(@schoolA, @hrA);
INSERT INTO @t VALUES ('deactivate', N'🔴 …the resolver immediately gives them ZERO',
    CAST(@cnt AS nvarchar(4)) + N' branches', CASE WHEN @cnt = 0 THEN 'PASS' ELSE 'FAIL' END);

SELECT @cnt = CAST(dbo.fn_IsSchoolMember(@schoolA, @hrA) AS int);
INSERT INTO @t VALUES ('deactivate', N'…and they are no longer a member for any school screen',
    CAST(@cnt AS nvarchar(4)), CASE WHEN @cnt = 0 THEN 'PASS' ELSE 'FAIL' END);

-- 🔴 THE HISTORY. Soft, not deleted, and nothing about the past rewritten.
SELECT @cnt = COUNT(*) FROM dbo.t_app_school_users
WHERE SchoolUserId = @suHrA AND Is_Deleted = 0 AND Is_Active = 0 AND CreatedOn = @createdOn;
INSERT INTO @t VALUES ('deactivate', N'🔴 The membership row SURVIVES: Is_Deleted 0, CreatedOn intact',
    CAST(@cnt AS nvarchar(4)) + N' row', CASE WHEN @cnt = 1 THEN 'PASS' ELSE 'FAIL' END);

SELECT @cnt = COUNT(*) FROM dbo.t_app_school_branches
WHERE BranchId = @a1 AND CreatedBy = 9001;
INSERT INTO @t VALUES ('deactivate', N'🔴 …and the campus they created still says they created it',
    CAST(@cnt AS nvarchar(4)) + N' row', CASE WHEN @cnt = 1 THEN 'PASS' ELSE 'FAIL' END);

SELECT @cnt = COUNT(*) FROM dbo.t_app_school_user_branches
WHERE SchoolUserId = @suHrA AND Is_Deleted = 0;
INSERT INTO @t VALUES ('deactivate', N'…their campus links are kept, so re-inviting restores them',
    CAST(@cnt AS nvarchar(4)) + N' links', CASE WHEN @cnt = 1 THEN 'PASS' ELSE 'FAIL' END);

DELETE FROM @rd;
INSERT INTO @rd EXEC dbo.USP_DeactivateSchoolUser
    @SchoolId = @schoolA, @UserUid = @ownerA, @TargetUserUid = @hrA;
INSERT INTO @t
SELECT 'deactivate', N'Doing it twice is ALREADY_INACTIVE, not an error',
       ISNULL(Code, '(none)'),
       CASE WHEN Status = 1 AND Code = 'ALREADY_INACTIVE' THEN 'PASS' ELSE 'FAIL' END FROM @rd;

DELETE FROM @rd;
INSERT INTO @rd EXEC dbo.USP_DeactivateSchoolUser
    @SchoolId = @schoolA, @UserUid = @seniorA, @TargetUserUid = @seniorA;
INSERT INTO @t
SELECT 'deactivate NEG', N'🔴 Nobody removes their OWN access',
       ISNULL(Code, '(succeeded)'),
       CASE WHEN Status = 0 AND Code = 'BUSINESS_RULE_VIOLATED' THEN 'PASS' ELSE 'FAIL' END FROM @rd;

-- Re-inviting is the undo, and it reuses the same membership row.
DELETE FROM @rp;
INSERT INTO @rp EXEC dbo.USP_ProvisionSchoolUser
    @SchoolId = @schoolA, @UserUid = @ownerA, @NewUserUid = @hrA,
    @RoleInSchool = 3, @BranchIds = @none;
INSERT INTO @t
SELECT 'deactivate', N'🔴 Re-inviting them REVIVES the same membership row',
       N'id ' + CAST(ISNULL(Id, 0) AS nvarchar(12)),
       CASE WHEN Status = 1 AND Id = @suHrA THEN 'PASS' ELSE 'FAIL' END FROM @rp;

SELECT @cnt = COUNT(*) FROM dbo.fn_VisibleBranches(@schoolA, @hrA);
INSERT INTO @t VALUES ('deactivate', N'…and their campus comes back with them',
    CAST(@cnt AS nvarchar(4)) + N' branches', CASE WHEN @cnt = 1 THEN 'PASS' ELSE 'FAIL' END);


ROLLBACK TRANSACTION;

/*==============================================================================
  RESULTS
==============================================================================*/
PRINT '';
PRINT '===============================================================================';
SELECT RIGHT('  ' + CAST(n AS varchar(3)), 3) + '  '
     + LEFT(section + REPLICATE(' ', 16), 16) + '  '
     + LEFT(what + REPLICATE(N' ', 58), 58) + '  '
     + LEFT(got + REPLICATE(N' ', 26), 26) + '  ' + pass
FROM @t ORDER BY n;

DECLARE @total int = (SELECT COUNT(*) FROM @t),
        @failed int = (SELECT COUNT(*) FROM @t WHERE pass = 'FAIL'),
        @negTotal int = (SELECT COUNT(*) FROM @t WHERE section LIKE '%NEG%'),
        @negFailed int = (SELECT COUNT(*) FROM @t WHERE section LIKE '%NEG%' AND pass = 'FAIL');

PRINT '===============================================================================';
PRINT '  SCHOOL TEAM: TOTAL ' + CAST(@total AS varchar(4))
    + '   PASSED ' + CAST(@total - @failed AS varchar(4))
    + '   FAILED ' + CAST(@failed AS varchar(4));
PRINT '  🔴 NEGATIVE CASES: ' + CAST(@negTotal AS varchar(4))
    + '   PASSED ' + CAST(@negTotal - @negFailed AS varchar(4))
    + '   FAILED ' + CAST(@negFailed AS varchar(4));
PRINT '===============================================================================';
GO
