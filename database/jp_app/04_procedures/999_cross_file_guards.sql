/*==============================================================================
  jp_app — 999_cross_file_guards.sql

  PHASE 8A. Guards that can only be judged once EVERY procedure exists.

  ---------------------------------------------------------------------------
  🔴 WHY THIS FILE EXISTS, AND THE INCIDENT THAT PROVED IT HAD TO
  ---------------------------------------------------------------------------
  A build guard that reads sys.sql_modules sees whatever is in the DATABASE at
  the moment it runs — not what is in its own file. So a guard sitting at the
  end of 024 can only judge the procedures created before 024, and its verdict
  silently changes depending on what else happens to be deployed.

  8A hit this exactly. 024's ViewCount guard had passed for two phases while
  024 was deployed by hand; the first full ordered build put 025 in the same
  database, 025 projects j.ViewCount for the moderator, and the guard — whose
  pattern could not tell a projection from a filter — failed the entire build
  over a correct procedure.

  ⚠️ THE GUARD'S LOOSENESS WAS A SEPARATE BUG AND WAS FIXED IN 024. What this
  file addresses is the structural half: a rule about ALL procedures belongs
  where all procedures exist, which is after the last one.

  ⚠️ IT RUNS LAST IN run_all FOR jp_app. A guard here that depends on jp_sso or
  jp_mdm would be in the wrong place — those databases finish earlier, so their
  cross-file rules belong in their own final file.

  ---------------------------------------------------------------------------
  WHAT GOES IN HERE, AND WHAT DOES NOT
  ---------------------------------------------------------------------------
  IN:   "no procedure anywhere may X" — a rule whose subject is the whole set.
  OUT:  "this procedure must not X" — that belongs beside the procedure, where
        somebody editing it will read it.

  A guard moved here loses its proximity to the code it protects, which is a
  real cost. It is paid only when the rule genuinely cannot be evaluated
  earlier.
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

PRINT '  Cross-file guards ...';
GO

/*==============================================================================
  🔒 G22 — THE SCOPE RESOLVER IS THE ONLY WAY A READ DECIDES WHAT A SCHOOL
  USER MAY SEE
==============================================================================*/

/*
  🔴 THE GAP, AS G22 WROTE IT: `dbo.fn_VisibleBranches` is the one place branch
  scope is decided, and every school-scoped procedure JOINS it — which is also
  the easiest path (2.53). But nothing in SQL Server stops the next list
  procedure writing its own EXISTS by hand, and a hand-written copy is where
  IDOR lives: one school's HR reading another campus's applicants, with no
  error anywhere.

  G22 asked for exactly this check — count the readers of
  t_app_school_user_branches, and review anything beyond the resolver.

  ---------------------------------------------------------------------------
  ⚠️ AND THE COUNT WAS ALREADY WRONG WHEN IT WAS WRITTEN
  ---------------------------------------------------------------------------
  G22 says the function is "the ONLY reader" of that table. Measured in 8A with
  sys.dm_sql_referenced_entities, it is not, and has not been since 3C:

      fn_VisibleBranches            reads   — the resolver itself
      USP_GetSchoolUserList         reads   — see below
      USP_ProvisionSchoolUser       writes
      USP_SaveSchoolUserBranches    writes
      USP_DeleteBranch              writes

  The second reader is DELIBERATE and documented in 011_school_team.sql: result
  set 1 carries BranchCount as the TRUE, unscoped number of campuses a
  colleague is assigned to, so the screen can say "1 campus, and 2 more you
  cannot see" instead of under-reporting a teammate's access — which would be
  a lie told with a straight face. Result set 2, which returns the branch IDS,
  does go through fn_VisibleBranches.

  🔴 SO THE RULE THIS GUARD ENFORCES IS NOT "ONE READER". It is: the readers
  are the ones named below, each for a stated reason, and a NEW one fails the
  build. That is a weaker claim than G22 hoped for and a true one, which is the
  trade this project keeps making.

  ⚠️ WRITERS ARE NOT THE CONCERN. Assigning somebody to a campus is the
  administrative act this table exists for; reading it to decide what somebody
  may SEE is the act that must go through the resolver. is_updated separates
  them — it is 1 for a column a module writes and 0 for one it only reads, and
  the dependency VIEW does not carry it.

  ⚠️ A MODULE THAT BOTH READS AND WRITES counts as a writer here (MAX), because
  USP_DeleteBranch legitimately reads the rows it is about to remove. The
  narrower risk — a writer that also hand-rolls a scope read — is not caught by
  this, and that is stated rather than papered over.

  Proven to fire: a probe procedure selecting BranchId from this table fails
  this and is named; one that only INSERTs does not.
*/
DECLARE @scopeReaders nvarchar(1000) = N'';

SELECT @scopeReaders = STRING_AGG(CAST(x.name AS nvarchar(128)), N', ')
  FROM (
        SELECT o.name,
               MAX(CAST(r.is_updated AS int)) AS Writes
          FROM sys.objects o
         CROSS APPLY sys.dm_sql_referenced_entities('dbo.' + o.name, 'OBJECT') r
         WHERE o.type IN ('P', 'FN', 'IF', 'TF', 'V')
           AND o.is_ms_shipped = 0
           AND r.referenced_entity_name = 't_app_school_user_branches'
         GROUP BY o.name
       ) x
 WHERE x.Writes = 0
   AND x.name NOT IN (
           /* The resolver. The single definition of branch scope (2.53). */
           'fn_VisibleBranches',

           /*
             The team list. Reads it ONCE, for the unscoped BranchCount on
             result set 1 — so a school owner sees how much access a colleague
             really has. The branch IDS on result set 2 are joined through
             fn_VisibleBranches. Reasoned in 011_school_team.sql's header.
           */
           'USP_GetSchoolUserList');

IF ISNULL(@scopeReaders, N'') <> N''
BEGIN
    DECLARE @g22 nvarchar(1400) =
        N'999_cross_file_guards: 🔒 G22 — A PROCEDURE READS t_app_school_user_branches WITHOUT GOING THROUGH fn_VisibleBranches: '
        + @scopeReaders
        + N'. Branch scope has one definition (2.53), and a hand-written EXISTS beside it is where one school''s HR starts reading another campus''s rows with no error anywhere. JOIN dbo.fn_VisibleBranches(@SchoolId, @UserUid) instead. If this read genuinely must be unscoped — the team list''s BranchCount is the one case — add it to the list here WITH the reason, and add the negative case to its suite in the same commit.';

    RAISERROR('%s', 16, 1, @g22);
END
GO

PRINT '    Cross-file guards passed.';
GO
