/*
================================================================================
  PHASE 6C-2-0 — t_app_teachers.VerifiedByUserId          (G37)

--------------------------------------------------------------------------------
  🔴 WHY THIS COLUMN WAS MISSING, AND WHY THAT MATTERED
--------------------------------------------------------------------------------
  t_app_schools has carried IsVerified / VerifiedOn / VerifiedByUserId since 2F.
  t_app_teachers had the first two and not the third — which looks like an
  oversight and was actually a symptom: nothing ever set the teacher's badge, so
  nothing ever needed somewhere to record who set it.

  G37 is that hole. ApprovalOrchestrationService.RunTeacherVerification returned
  a FAILED outcome whose message read "setting IsVerified requires
  t_app_teachers, which is Phase 3" — and Phase 3 shipped. An admin could
  approve a teacher through the queue, the approval trail was written, and the
  badge never appeared. No error, because that branch was already written to
  report a failure.

  ⚠️ 6C-2 is what made it urgent rather than untidy. The search results,
  applicant detail and invitation screens all show a verified badge; with no way
  to earn one, every badge on every screen would have been seed data. That is
  the mockup-era failure this project keeps writing tests to avoid.

--------------------------------------------------------------------------------
  ⚠️ NOT AN FK, AND THE REASON IS 2.2
--------------------------------------------------------------------------------
  t_sso_users.UserId lives in jp_sso. A cross-database foreign key is not
  something SQL Server will accept, and adding one is not a "fix" — it will not
  compile. The value is written by USP_SetTeacherVerified from the acting
  admin's own id, which the API reads from their token (2.39).

  🔴 It is the bigint UserId rather than the UserUid, matching
  t_app_schools.VerifiedByUserId exactly. Two columns for the same idea in two
  shapes is how a join gets written wrong at 2am.
================================================================================
*/
USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF COL_LENGTH('dbo.t_app_teachers', 'VerifiedByUserId') IS NULL
BEGIN
    PRINT '    Adding [t_app_teachers].[VerifiedByUserId] ...';

    ALTER TABLE dbo.t_app_teachers
        ADD VerifiedByUserId bigint NULL;
END
GO

/*
  🔴 THE GUARD I FIRST WROTE HERE WAS WRONG, AND IT CAUGHT ME ON THE FIRST RUN.

  It asserted that no teacher has IsVerified = 1 and VerifiedOn set without a
  VerifiedByUserId — and its comment claimed the four seeded verified teachers
  "have no VerifiedOn". That was a guess. They all have one, stamped
  2026-08-10 at the seed's own timestamp, and no verifier. So the guard failed
  the build on historical data the moment it ran.

  ⚠️ Three ways out, and two of them are worse than the problem:

    - Backfill those four rows with a verifier. That invents an approval that
      never happened, which is the same class of lie the missing badge was.
    - Scope the guard by date (VerifiedOn > today). That is a date check wearing
      a guard's clothes: it passes forever once the date drifts, and nobody
      maintains it.
    - Assert the invariant that is true of ALL data, and assert the
      three-columns-together rule where it can be stated honestly — against a
      teacher this product actually verified. That is below, and in
      teacher-verification.mjs.

  🔴 What IS a contradiction in any row, seeded or not: a verifier recorded on a
  teacher who is not verified. Nothing can produce that legitimately — 022
  writes the badge and the verifier in one statement — so it stays a build
  guard.
*/
IF EXISTS (SELECT 1 FROM dbo.t_app_teachers
           WHERE IsVerified = 0 AND VerifiedByUserId IS NOT NULL)
    RAISERROR(N'G37 VIOLATION: a teacher has a verifier recorded but no badge. 022 writes both in one statement or neither.', 16, 1);
GO

/*
  ⚠️ AND THE FOUR SEEDED ROWS ARE LEFT EXACTLY AS THEY ARE, ON PURPOSE.

  They are verified with a date and no verifier, which is what "this was seed
  data, not a decision anybody made" looks like. Leaving the shape visible is
  more useful than tidying it: the first person to ask "who verified Meera
  Iyer?" gets the honest answer that nobody did.
*/

PRINT '  t_app_teachers.VerifiedByUserId ready';
GO
