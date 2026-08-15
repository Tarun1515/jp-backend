/*==============================================================================
  jp_app — 04_procedures / 010_teacher_public_profile.sql

  USP_GetTeacherPublicProfile     what a school sees while browsing
  USP_GetTeacherContactForSchool  🔴 contact details, and when they unlock

  ---------------------------------------------------------------------------
  🔴 WHERE THE LINE IS, AND WHY IT IS THERE
  ---------------------------------------------------------------------------
  A school browsing the teacher database gets everything it needs to decide
  whether it wants this person — and no way to contact them off-platform.

  🔴 CONTACT UNLOCKS ON TEACHER CONSENT, AND ONLY ON TEACHER CONSENT.
  Decision 2.56, LOCKED.

  Consent has exactly two forms:

      1. the teacher APPLIED to this school, or
      2. the teacher ACCEPTED an invite from this school

  and nothing else. Not payment. Not an invite the school merely sent.

  ⚠️ A SCHOOL CAN PAY FOR CAPABILITY, NEVER FOR CONTACT. What a subscription
  buys is the right to SEARCH the teacher database at all, how many invites it
  may send, and possibly featured placement. It never buys a phone number. No
  amount of money moves this line, because the line is not ours to move — it is
  the teacher's.

  That is better commercially as well as ethically: a school that pays gets
  teachers who RESPONDED, not a list to cold-call. A contact list sold at browse
  time means the first phone call happens off-platform and nothing after it
  involves us.

  The reasons, in order of weight:

  1. CONSENT. A teacher who applied, or who accepted an invitation, has decided
     that school may contact them. A teacher who merely appeared in a search
     result has decided nothing, and handing over their mobile number is a
     decision made on their behalf.

  2. IT IS WHAT MAKES THE PLATFORM WORTH ANYTHING. Contact details given away
     at browse time are the whole product given away — the school takes the
     number, rings the teacher, and nothing that happens next involves us. No
     applications, no offers, no record, and no reason to come back.

  3. IT IS WHAT STOPS A TEACHER REGRETTING THE PROFILE. Somebody who uploads a
     resume to find a job and starts getting cold calls from forty schools does
     not update that profile again, and tells other teachers not to make one.

  ---------------------------------------------------------------------------
  🔴 THE RESUME IS A CONTACT DETAIL
  ---------------------------------------------------------------------------
  This is the part that is easy to get wrong. A resume contains a phone number
  and an email address in its first three lines. Masking the columns while
  serving the file is theatre: the school downloads the PDF and reads what the
  procedure just refused to tell them.

  So ResumePath is returned ONLY by the contact procedure, under the same unlock
  rule as the phone number. The browse procedure does not return it, and cannot
  — the column is not in its SELECT.

  ---------------------------------------------------------------------------
  TWO PROCEDURES, NOT A FLAG — the 3C precedent (2.53)
  ---------------------------------------------------------------------------
  A single procedure with @IncludeContact is one forgotten column away from a
  leak, and the forgetting happens later, when somebody adds a column and does
  not think about a flag forty lines up.

  Here the stakes are higher than they were for the school profile: what leaks
  is a person's mobile number rather than a company's tax reference. So the
  browse procedure does not have the columns at all, and adding one is a
  deliberate act of publishing it.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  fn_TeacherContactUnlocked

  🔴 WRITTEN NOW, DELIBERATELY ALWAYS 0.

  t_app_applications arrives in Phase 5 and t_app_teacher_invites in Phase 6.
  Until then no teacher has applied to anybody or accepted anything, so "not
  unlocked" is not a placeholder — it is the correct answer.

  ---------------------------------------------------------------------------
  🔴 EXACTLY TWO PATHS, AND THEY ARE BOTH THE TEACHER'S OWN ACT (2.56, LOCKED)
  ---------------------------------------------------------------------------
  When those tables land, the body becomes:

      RETURN CASE WHEN EXISTS (
          -- 1. the teacher APPLIED to this school
          SELECT 1 FROM dbo.t_app_applications a
          WHERE a.TeacherId  = @TeacherId
            AND a.SchoolId   = @ViewerSchoolId
            AND a.Is_Deleted = 0

          UNION ALL

          -- 2. the teacher ACCEPTED an invite from this school
          SELECT 1 FROM dbo.t_app_teacher_invites i
          WHERE i.TeacherId    = @TeacherId
            AND i.SchoolId     = @ViewerSchoolId
            AND i.InviteStatus = <ACCEPTED>
            AND i.Is_Deleted   = 0
      ) THEN 1 ELSE 0 END;

  ⚠️ SENT IS NOT ACCEPTED, AND THE DIFFERENCE IS THE WHOLE RULE.

  An invite the school SENT unlocks nothing — otherwise a school invites every
  teacher in the database on Monday and has every phone number by Tuesday, which
  is the same as having no rule at all.

  An invite the teacher ACCEPTED is consent in exactly the way an application
  is: the teacher was asked, and said yes.

  🔴 An earlier version of this comment said only "do not widen this to
  invites", which reads as excluding both. It excludes one.

  ---------------------------------------------------------------------------
  ⚠️ THE SPEC HAS NO "ACCEPTED" STATUS YET — PHASE 6 MUST ADD ONE
  ---------------------------------------------------------------------------
  DB_TABLE_STRUCTURE gives t_app_teacher_invites the statuses
  Sent / Viewed / Applied / Ignored. None of them means what path 2 needs:

      Sent     the school acted, not the teacher
      Viewed   opening a message is not saying yes
      Applied  already covered by path 1 — an application exists — so mapping
               path 2 onto it makes path 2 do nothing
      Ignored  a refusal

  So Phase 6 adds an ACCEPTED status, or path 2 quietly collapses into path 1
  and the monetization plan is broken again with nobody noticing. That is
  precisely the shape of failure this file exists to prevent.

  ---------------------------------------------------------------------------
  🔴 AND NEVER A THIRD PATH
  ---------------------------------------------------------------------------
  Not "the school has a paid plan". Not "the school has invites remaining". A
  subscription buys CAPABILITY — whether a school may search at all, how many
  invites it may send — and never the teacher's contact details (2.56).

  If a future requirement seems to need payment here, the requirement is being
  described wrongly: what is being sold is reach, and reach is invites.

  Written now rather than left for Phase 5 because whoever adds applications
  will not know this rule exists, and the failure mode is silent — contact
  details that were never supposed to flow, flowing.
==============================================================================*/
CREATE OR ALTER FUNCTION dbo.fn_TeacherContactUnlocked
(
    @TeacherId       bigint,
    @ViewerSchoolId  bigint
)
RETURNS bit
AS
BEGIN
    -- Phase 5 replaces this. See the note above.
    RETURN 0;
END
GO


/*==============================================================================
  USP_GetTeacherPublicProfile — the browse view.

  ⚠️ AN UNVERIFIED TEACHER IS STILL VISIBLE, and that is the asymmetry with
  schools.

  A school is hidden until verified because an unverified school might not
  exist, and a teacher applying to a fake school loses their time and their
  documents. A teacher's verification is a BADGE on a real person's profile
  (2.9), not a gate — hiding unverified teachers would empty the database and
  punish people for our queue length.

  A SUSPENDED teacher is not visible. That is an administrative decision about
  the person, and it is enforced here rather than returned as a flag for the
  caller to honour.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetTeacherPublicProfile
    @TeacherUid uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TeacherId bigint;

    SELECT @TeacherId = t.TeacherId
    FROM dbo.t_app_teachers t
    WHERE t.TeacherUid  = @TeacherUid
      AND t.Is_Deleted  = 0
      AND t.Is_Active   = 1
      AND t.IsSuspended = 0;

    /*
      ---- 1. the person ------------------------------------------------------

      NOT RETURNED, each for its own reason:

        ContactMobile / ContactEmail  the whole point. See the header.
        ResumePath                    a resume IS contact details. See the header.
        DOB                           an age is not needed to decide whether
                                      somebody can teach physics, and publishing
                                      it makes age discrimination a filter away.
        UserUid                       an internal key, and the join to jp_sso.
        TeacherId / RowVersion        plumbing for an editor. There is no editor.
        IsSuspended                   enforced above, not published.

      RETURNED, and deliberately:

        FullName          a name is not contact information, and a school
                          cannot decide whether to invite an anonymous row.
        ExpectedSalary    the teacher entered it AS A FILTER — hiding it wastes
                          both sides' time on offers that were never going to
                          work. It is a stated preference, not a private fact.
        CurrentCity/State where they are is the second thing a school filters on
                          after subject. Withholding it makes the search useless
                          while protecting nothing — it is not an address.
    */
    SELECT
        t.TeacherUid,
        t.FullName,
        t.PhotoPath,
        t.GenderId,
        t.QualificationId,
        t.HighestQualificationText,
        t.DesignationId,
        t.TotalExperienceMonths,
        t.CurrentSchool,
        t.LastSchool,
        t.ExpectedSalaryMin,
        t.ExpectedSalaryMax,
        t.CurrentCityId,
        t.CurrentStateId,
        t.AboutMe,
        t.IsVerified,
        t.ProfileCompletionPercent
    FROM dbo.t_app_teachers t
    WHERE t.TeacherId = @TeacherId;

    -- ---- 2..5 what they teach --------------------------------------------
    SELECT s.SubjectId FROM dbo.t_app_teacher_subjects s
    WHERE s.TeacherId = @TeacherId AND s.Is_Deleted = 0;

    SELECT c.ClassLevelId FROM dbo.t_app_teacher_class_levels c
    WHERE c.TeacherId = @TeacherId AND c.Is_Deleted = 0;

    SELECT k.SkillId FROM dbo.t_app_teacher_skills k
    WHERE k.TeacherId = @TeacherId AND k.Is_Deleted = 0;

    SELECT l.LanguageId, l.ProficiencyLevel FROM dbo.t_app_teacher_languages l
    WHERE l.TeacherId = @TeacherId AND l.Is_Deleted = 0;

    -- ---- 6. where they will work -----------------------------------------
    SELECT p.CityId, p.StateId, p.PreferenceOrder
    FROM dbo.t_app_teacher_preferred_locations p
    WHERE p.TeacherId = @TeacherId AND p.Is_Deleted = 0
    ORDER BY p.PreferenceOrder;

    /*
      ---- 7. experience ------------------------------------------------------

      School names and dates are returned; a school judging a candidate needs to
      see where they have taught. This is the same information a resume would
      carry, minus the contact block — which is exactly the split this file is
      about.
    */
    SELECT e.SchoolName, e.DesignationId, e.SubjectId, e.FromDate, e.ToDate, e.IsCurrent
    FROM dbo.t_app_teacher_experiences e
    WHERE e.TeacherId = @TeacherId AND e.Is_Deleted = 0
    ORDER BY e.IsCurrent DESC, e.FromDate DESC;

    /*
      ---- 8. documents: THE FACT, NOT THE FILE -------------------------------

      A school can see that a degree certificate exists and has been verified by
      us. It cannot see the file, the filename or the path.

      That is the useful half — "somebody checked this" is what a school wants
      from a document it is not qualified to authenticate anyway — without
      handing over a scan of somebody's identity document to every school that
      runs a search.
    */
    SELECT d.DocumentTypeId, d.IsVerified
    FROM dbo.t_app_teacher_documents d
    WHERE d.TeacherId = @TeacherId AND d.Is_Deleted = 0;
END
GO


/*==============================================================================
  USP_GetTeacherContactForSchool

  🔴 The ONLY route to a teacher's contact details and resume.

  Returns them when the teacher has applied to this school, and a refusal
  otherwise — with a Code the UI can turn into an explanation rather than a
  dead end.

  ⚠️ Takes @ViewerSchoolId, which the API supplies from the caller's own
  membership (2.53) — never from a route or a body. A school naming another
  school's id would otherwise unlock everything that school had earned.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetTeacherContactForSchool
    @TeacherUid     uniqueidentifier,
    @ViewerSchoolId bigint
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL, @Message nvarchar(400) = NULL;
    DECLARE @TeacherId bigint;

    SELECT @TeacherId = t.TeacherId
    FROM dbo.t_app_teachers t
    WHERE t.TeacherUid  = @TeacherUid
      AND t.Is_Deleted  = 0
      AND t.Is_Active   = 1
      AND t.IsSuspended = 0;

    IF @TeacherId IS NULL
        SELECT @Code = 'NOT_FOUND', @Message = N'That teacher was not found.';
    ELSE IF @ViewerSchoolId IS NULL
        SELECT @Code = 'FORBIDDEN', @Message = N'Only a school can request contact details.';
    ELSE IF dbo.fn_TeacherContactUnlocked(@TeacherId, @ViewerSchoolId) = 0
        SELECT @Code = 'CONTACT_LOCKED',
               @Message = N'You will see this teacher''s contact details once they apply to one of your jobs, '
                        + N'or accept an invitation from you. Until then you can invite them through the platform '
                        + N'— they will see your message and can reply.';

    IF @Code IS NULL
    BEGIN
        SET @Status = 1;
        SET @Message = N'Contact details unlocked.';
    END

    /*
      🔴 ONE result set: the envelope AND the contact block together.

      Two result sets would make this unreadable through INSERT..EXEC, which is
      how every other write procedure in this database is consumed and tested —
      the same Msg 213 the school public profile hit in 3C.

      ⚠️ The contact columns are present and NULL when locked, which is the
      OPPOSITE of the rule the browse procedure follows. That is deliberate.
      There, a contact column must not exist at all, because the procedure's
      purpose is not contact and a column present-but-empty is one somebody
      populates later without thinking. Here contact IS the purpose: the columns
      are the contract, and the caller reads Code to know whether they are real.

      The resume travels with them, because a resume carries a phone number in
      its first three lines. Returning the file while withholding the column
      would be theatre.

      ⚠️ Email and mobile are read from the jp_sso account rather than copied
      onto the profile — a teacher's email is their sign-in identity, and a
      second copy here would let the two disagree about how to reach somebody.
    */
    SELECT
        @Status     AS Status,
        @Code       AS Code,
        @Message    AS Message,
        @TeacherId  AS Id,
        CASE WHEN @Status = 1 THEN t.ResumePath END AS ResumePath,
        CASE WHEN @Status = 1 THEN u.Email      END AS ContactEmail,
        CASE WHEN @Status = 1 THEN u.Mobile     END AS ContactMobile
    FROM (SELECT 1 AS one) anchor
        LEFT JOIN dbo.t_app_teachers t
            ON t.TeacherId = @TeacherId
        LEFT JOIN jp_sso.dbo.t_sso_users u
            ON u.UserUid = t.UserUid;
END
GO

PRINT '    Teacher public profile procedures ready.';
GO
