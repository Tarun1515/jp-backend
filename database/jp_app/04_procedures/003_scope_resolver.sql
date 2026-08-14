/*==============================================================================
  jp_app — 04_procedures / 003_scope_resolver.sql

  fn_VisibleBranches   🔴 THE ONE PLACE BRANCH SCOPE IS DECIDED

  ---------------------------------------------------------------------------
  THE RULE
  ---------------------------------------------------------------------------
      RoleInSchool = 1 (Owner)  ->  every branch of the school.
                                    NO link rows are needed or expected: an
                                    owner is never enumerated in
                                    t_app_school_user_branches (2.51).

      anything else             ->  only the branches listed in
                                    t_app_school_user_branches.

  ---------------------------------------------------------------------------
  🔴 WHY AN INLINE TABLE-VALUED FUNCTION, AND NOT A PROCEDURE
  ---------------------------------------------------------------------------
  Every school-scoped query from Phase 4 onward filters through this. Getting it
  wrong is not a wrong number on a screen — it is an IDOR, one school's HR
  reading another campus's applicants, inherited by every screen built after it.

  So the shape matters as much as the logic:

  1. IT CAN BE JOINED TO. `INNER JOIN dbo.fn_VisibleBranches(@SchoolId, @UserUid)`
     is the path of least resistance for anybody writing a list procedure. A
     stored procedure cannot be joined; every caller would have to INSERT..EXEC
     into a temp table first, which is enough friction that somebody eventually
     writes the two-line EXISTS by hand instead — and that hand-written version
     is where the bug lives.

  2. IT IS INLINE, NOT MULTI-STATEMENT. An inline TVF is expanded into the
     calling query and costed with it. A multi-statement TVF is a black box the
     optimiser guesses at, and on a join against a large jobs table that guess
     is usually wrong.

  3. IT FAILS CLOSED. An unknown user, a soft-deleted membership or a user at
     another school all produce zero rows, not every row.

  ⚠️ HOW A FUTURE LIST PROC IS STOPPED FROM WRITING ITS OWN VERSION — honestly:
  nothing in SQL Server prevents it. What exists instead is
    - this function is the ONLY object that reads t_app_school_user_branches,
      so a second reader of that table is visible in a search for it;
    - 99_tests asserts the negative case, and any new school-scoped procedure is
      expected to add its own negative-case assertion beside it;
    - the note in _TEMPLATE_procedure.sql points here.
  That is a convention with a test behind it, not an enforcement. Said plainly
  so nobody assumes it is stronger than it is.

  ---------------------------------------------------------------------------
  ⚠️ THE NEGATIVE CASE IS THE TEST THAT MATTERS
  ---------------------------------------------------------------------------
  A test that checks "the right rows came back" passes against a resolver that
  returns everything. The test that means something is: a branch HR assigned to
  branch A gets ZERO rows for branch B — not fewer, zero.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

CREATE OR ALTER FUNCTION dbo.fn_VisibleBranches
(
    @SchoolId   bigint,
    @UserUid    uniqueidentifier
)
RETURNS TABLE
AS
RETURN
(
    /*
      Owner: every branch of the school.

      The EXISTS is on the membership, not on link rows — an owner having no
      rows in t_app_school_user_branches is the normal case and the reason this
      branch of the UNION is written separately rather than as an OUTER JOIN
      with a NULL check.
    */
    SELECT b.BranchId
    FROM dbo.t_app_school_branches b
    WHERE b.SchoolId = @SchoolId
      AND b.Is_Deleted = 0
      AND EXISTS (
            SELECT 1
            FROM dbo.t_app_school_users su
            WHERE su.SchoolId     = @SchoolId
              AND su.UserUid      = @UserUid
              AND su.RoleInSchool = 1          -- Owner
              AND su.Is_Active    = 1
              AND su.Is_Deleted   = 0)

    UNION

    /*
      Everybody else: only what they are linked to.

      Every join is filtered on Is_Deleted AND Is_Active, at all three levels —
      the membership, the link and the branch. Removing somebody from a campus
      is a soft delete on the link, and a resolver that read only Is_Deleted
      would keep showing them a campus they had been taken off.

      ⚠️ UNION, not UNION ALL: an owner who ALSO has stray link rows — which
      should not happen, but a bad import could produce — would otherwise see
      those branches twice, and a duplicate branch id silently multiplies rows
      in every query that joins through this.
    */
    SELECT ub.BranchId
    FROM dbo.t_app_school_users su
        INNER JOIN dbo.t_app_school_user_branches ub
            ON ub.SchoolUserId = su.SchoolUserId
           AND ub.Is_Active    = 1
           AND ub.Is_Deleted   = 0
        INNER JOIN dbo.t_app_school_branches b
            ON b.BranchId  = ub.BranchId
           AND b.SchoolId  = @SchoolId          -- a link to another school's
                                                -- branch resolves to nothing
           AND b.Is_Deleted = 0
    WHERE su.SchoolId     = @SchoolId
      AND su.UserUid      = @UserUid
      AND su.RoleInSchool <> 1
      AND su.Is_Active    = 1
      AND su.Is_Deleted   = 0
);
GO


/*==============================================================================
  fn_IsSchoolMember

  Whether somebody belongs to a school at all, regardless of campus.

  Used by the school-level procedures — profile, logo, photos, facilities —
  where the question is "is this your school" rather than "which campuses".

  ⚠️ Separate from fn_VisibleBranches on purpose. A school with no branches at
  all would make the branch resolver return nothing, and folding the two
  together would then deny an owner access to their own school profile because
  of an unrelated fact about campuses.
==============================================================================*/
CREATE OR ALTER FUNCTION dbo.fn_IsSchoolMember
(
    @SchoolId   bigint,
    @UserUid    uniqueidentifier
)
RETURNS bit
AS
BEGIN
    RETURN CASE WHEN EXISTS (
        SELECT 1 FROM dbo.t_app_school_users su
        WHERE su.SchoolId   = @SchoolId
          AND su.UserUid    = @UserUid
          AND su.Is_Active  = 1
          AND su.Is_Deleted = 0) THEN 1 ELSE 0 END;
END
GO

PRINT '    Scope resolver ready.';
GO
