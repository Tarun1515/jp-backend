/*==============================================================================
  jp_app — 03_seed / 001_backfill_phase3b.sql

  PHASE 3B — the backfill.

  Four things, in dependency order:

      1. a t_app_teachers profile for every existing teacher account
      2. TEACHER_FREE for every teacher, including the ones just created
      3. a head-office branch for any school approved before Phase 2F landed
      4. SCHOOL_FREE for any organisation approved before Phase 2F landed

  ---------------------------------------------------------------------------
  ⚠️ THIS SCRIPT READS jp_sso AND WRITES jp_app. THAT IS ALLOWED HERE.
  ---------------------------------------------------------------------------
  Decision 2.2 forbids cross-database joins — in the APPLICATION. The point of
  that rule is that the running system stays uncoupled, so the databases can be
  deployed and moved independently.

  This is not application code. It is a one-time migration an operator runs with
  sqlcmd, against one server, at a moment chosen by a person. Writing an API
  endpoint to backfill eleven rows would be more machinery than the task
  deserves, and it would put a permanent, callable "rewrite everybody's profile"
  surface into the product to serve a job that runs once.

  🔴 Nothing here may be called by the application. If a procedure ever needs
  this shape, it goes through the API layer like everything else.

  ---------------------------------------------------------------------------
  🔴 IDEMPOTENCY: 2601 IS "ALREADY DONE", NOT AN ERROR
  ---------------------------------------------------------------------------
  UQ_t_app_teachers_UserUid REFUSES a duplicate rather than silently skipping
  it. So this inserts row by row inside TRY/CATCH and swallows exactly 2601 and
  2627 — the same shape USP_ProvisionSchoolFromApproval uses (2.48).

  It deliberately does NOT do `WHERE NOT EXISTS`. That is check-then-act, which
  is the race this project has now fixed twice, and it would pass every test on
  a single-threaded run while still being wrong.

  A second run reports 0 created for every category. That is the test.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

SET NOCOUNT ON;
GO

DECLARE @Now datetime2 = SYSUTCDATETIME();

-- What the plans are. Read once, by CODE — the ids are IDENTITY and are not
-- contract (2.47 makes Code the stable key, not the number).
DECLARE @TeacherPlanId int = (SELECT PlanId FROM jp_mdm.dbo.m_mdm_plans
                              WHERE PlanCode = 'TEACHER_FREE' AND Is_Deleted = 0);
DECLARE @SchoolPlanId  int = (SELECT PlanId FROM jp_mdm.dbo.m_mdm_plans
                              WHERE PlanCode = 'SCHOOL_FREE'  AND Is_Deleted = 0);

IF @TeacherPlanId IS NULL OR @SchoolPlanId IS NULL
    THROW 50101, 'A default plan is missing. Run 03_seed/008_seed_plans.sql first.', 1;

DECLARE @createdProfiles  int = 0, @skippedProfiles  int = 0;
DECLARE @createdTeacherSubs int = 0, @skippedTeacherSubs int = 0;
DECLARE @createdBranches  int = 0, @skippedBranches  int = 0;
DECLARE @createdSchoolSubs int = 0, @skippedSchoolSubs int = 0;

PRINT '';
PRINT '=========================================================';
PRINT '  PHASE 3B BACKFILL';
PRINT '=========================================================';


/*==============================================================================
  1. TEACHER PROFILES

  FullName comes from the SSO account where it carries one. It does not — the
  users table holds an email and a mobile, not a display name — so the profile
  starts with the local part of the email as a placeholder and Part 2 replaces
  it. Recorded here rather than quietly inventing a name in a migration.
==============================================================================*/
PRINT '';
PRINT '  1. Teacher profiles';

DECLARE @Teachers TABLE (rn int IDENTITY(1,1), UserUid uniqueidentifier, Email nvarchar(150));

INSERT INTO @Teachers (UserUid, Email)
SELECT u.UserUid, u.Email
FROM jp_sso.dbo.t_sso_users u
WHERE u.UserTypeId = 3          -- Teacher
  AND u.Is_Deleted = 0
ORDER BY u.UserId;

DECLARE @i int = 1, @n int = (SELECT COUNT(*) FROM @Teachers);
DECLARE @UserUid uniqueidentifier, @Email nvarchar(150), @Name nvarchar(150);

WHILE @i <= @n
BEGIN
    SELECT @UserUid = UserUid, @Email = Email FROM @Teachers WHERE rn = @i;

    -- Placeholder only. Part 2 overwrites it with a real name.
    SET @Name = LEFT(@Email, CHARINDEX('@', @Email + '@') - 1);

    BEGIN TRY
        INSERT INTO dbo.t_app_teachers (UserUid, FullName, CreatedBy)
        VALUES (@UserUid, @Name, NULL);

        SET @createdProfiles = @createdProfiles + 1;
    END TRY
    BEGIN CATCH
        -- 🔴 2601 / 2627 = the unique index did its job. Already backfilled.
        IF ERROR_NUMBER() NOT IN (2601, 2627) THROW;

        SET @skippedProfiles = @skippedProfiles + 1;
    END CATCH

    SET @i = @i + 1;
END

PRINT '     accounts found : ' + CAST(@n AS varchar(6));
PRINT '     created        : ' + CAST(@createdProfiles AS varchar(6));
PRINT '     already present: ' + CAST(@skippedProfiles AS varchar(6));


/*==============================================================================
  2. TEACHER SUBSCRIPTIONS

  Keyed on the teacher's UserUid — a teacher IS their own owner, unlike a school
  whose subscription belongs to its organisation (2.50).
==============================================================================*/
PRINT '';
PRINT '  2. Teacher subscriptions';

/*
  ⚠️ A SEPARATE table variable, not @Teachers reused.

  A table variable's IDENTITY does not reset on DELETE. Re-filling @Teachers
  would restart its rn at 12, the `WHERE rn = @i` loop below would match
  nothing, and @UserUid would keep its value from the previous section — so the
  same teacher would be inserted once per profile: one success and ten
  duplicate-key hits, reported as "already present".

  That is exactly what the first run of this script did, and the only reason it
  was caught is that the numbers were impossible.
*/
DECLARE @TeacherProfiles TABLE (rn int IDENTITY(1,1), UserUid uniqueidentifier);

INSERT INTO @TeacherProfiles (UserUid)
SELECT t.UserUid FROM dbo.t_app_teachers t WHERE t.Is_Deleted = 0;

SET @i = 1; SET @n = (SELECT COUNT(*) FROM @TeacherProfiles);

WHILE @i <= @n
BEGIN
    SELECT @UserUid = UserUid FROM @TeacherProfiles WHERE rn = @i;

    BEGIN TRY
        INSERT INTO dbo.t_app_subscriptions (OwnerUid, PlanId, StartsOn, EndsOn, StatusId, AutoRenew)
        VALUES (@UserUid, @TeacherPlanId, @Now, NULL, 1, 0);

        SET @createdTeacherSubs = @createdTeacherSubs + 1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() NOT IN (2601, 2627) THROW;

        SET @skippedTeacherSubs = @skippedTeacherSubs + 1;
    END CATCH

    SET @i = @i + 1;
END

PRINT '     profiles found : ' + CAST(@n AS varchar(6));
PRINT '     created        : ' + CAST(@createdTeacherSubs AS varchar(6));
PRINT '     already present: ' + CAST(@skippedTeacherSubs AS varchar(6));


/*==============================================================================
  3. HEAD-OFFICE BRANCHES

  Only for schools provisioned BEFORE Phase 2F, when provisioning began creating
  the branch itself. Address copied from the school, because that is where the
  head office is by definition — 2F's provisioning does exactly the same.

  ⚠️ There is no unique index to catch a duplicate here in the way UserUid does;
  UQ_t_app_school_branches_OneHeadOffice is that index, and it is why this can
  use the same 2601 shape rather than a NOT EXISTS.
==============================================================================*/
PRINT '';
PRINT '  3. Head-office branches';

DECLARE @Schools TABLE (rn int IDENTITY(1,1), SchoolId bigint);

INSERT INTO @Schools (SchoolId)
SELECT s.SchoolId FROM dbo.t_app_schools s WHERE s.Is_Deleted = 0 ORDER BY s.SchoolId;

SET @i = 1; SET @n = (SELECT COUNT(*) FROM @Schools);
DECLARE @SchoolId bigint;

WHILE @i <= @n
BEGIN
    SELECT @SchoolId = SchoolId FROM @Schools WHERE rn = @i;

    BEGIN TRY
        INSERT INTO dbo.t_app_school_branches
            (SchoolId, BranchName, IsHeadOffice,
             AddressLine1, AddressLine2, CityId, DistrictId, StateId, Pincode,
             ContactEmail, ContactMobile)
        SELECT s.SchoolId, s.SchoolName, 1,
               s.AddressLine1, s.AddressLine2, s.CityId, s.DistrictId, s.StateId, s.Pincode,
               s.ContactEmail, s.ContactMobile
        FROM dbo.t_app_schools s
        WHERE s.SchoolId = @SchoolId;

        SET @createdBranches = @createdBranches + 1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() NOT IN (2601, 2627) THROW;

        SET @skippedBranches = @skippedBranches + 1;
    END CATCH

    SET @i = @i + 1;
END

PRINT '     schools found  : ' + CAST(@n AS varchar(6));
PRINT '     created        : ' + CAST(@createdBranches AS varchar(6));
PRINT '     already present: ' + CAST(@skippedBranches AS varchar(6));


/*==============================================================================
  4. SCHOOL SUBSCRIPTIONS

  Per ORGANISATION, not per school (2.50): a group with several schools under
  one organisation is on one plan, which UQ_t_app_subscriptions_OneActivePerOwner
  already asserts.

  ⚠️ Driven from the SSO accounts rather than from t_app_schools, so an Active
  school account whose registration predates the approval engine — and which
  therefore has no school row at all — still gets its plan. Every account has
  one, and "has a school" was never the condition.

  ⚠️ ACTIVE ONLY, though. See the note on the query below: giving a pending
  organisation a plan now would break the provisioning that runs when it is
  approved.
==============================================================================*/
PRINT '';
PRINT '  4. School subscriptions';

DECLARE @Orgs TABLE (rn int IDENTITY(1,1), OrganizationUid uniqueidentifier);

/*
  🔴 ACTIVE organisations only. A pending one must NOT be given a plan here.

  USP_ProvisionSchoolFromApproval creates the school, its head office and its
  subscription in one transaction, and its CATCH reads 2601 as "already
  provisioned". Give a pending org a subscription now and that insert collides
  at approval time, the whole transaction rolls back — school included — and
  the procedure reports success with a null id.

  A school approved and never created, reported as fine. That is the exact
  failure 2.48 exists to prevent, arrived at from a new direction.

  A pending registration gets its plan when it is approved. That is the design,
  and this backfill's job is only the accounts that predate it.
*/
INSERT INTO @Orgs (OrganizationUid)
SELECT DISTINCT u.OrganizationUid
FROM jp_sso.dbo.t_sso_users u
WHERE u.UserTypeId = 2          -- School
  AND u.StatusId   = 2          -- Active
  AND u.Is_Deleted = 0
  AND u.OrganizationUid IS NOT NULL;

SET @i = 1; SET @n = (SELECT COUNT(*) FROM @Orgs);
DECLARE @Org uniqueidentifier;

WHILE @i <= @n
BEGIN
    SELECT @Org = OrganizationUid FROM @Orgs WHERE rn = @i;

    BEGIN TRY
        INSERT INTO dbo.t_app_subscriptions (OwnerUid, PlanId, StartsOn, EndsOn, StatusId, AutoRenew)
        VALUES (@Org, @SchoolPlanId, @Now, NULL, 1, 0);

        SET @createdSchoolSubs = @createdSchoolSubs + 1;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() NOT IN (2601, 2627) THROW;

        SET @skippedSchoolSubs = @skippedSchoolSubs + 1;
    END CATCH

    SET @i = @i + 1;
END

PRINT '     organisations  : ' + CAST(@n AS varchar(6));
PRINT '     created        : ' + CAST(@createdSchoolSubs AS varchar(6));
PRINT '     already present: ' + CAST(@skippedSchoolSubs AS varchar(6));

PRINT '';
PRINT '=========================================================';
PRINT '  CREATED  profiles ' + CAST(@createdProfiles AS varchar(6))
    + '  teacherSubs ' + CAST(@createdTeacherSubs AS varchar(6))
    + '  branches ' + CAST(@createdBranches AS varchar(6))
    + '  schoolSubs ' + CAST(@createdSchoolSubs AS varchar(6));
PRINT '  A SECOND RUN MUST REPORT 0 CREATED IN EVERY COLUMN.';
PRINT '=========================================================';
GO
