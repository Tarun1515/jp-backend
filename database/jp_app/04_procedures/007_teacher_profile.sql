/*==============================================================================
  jp_app — 04_procedures / 007_teacher_profile.sql

  fn_TeacherIdForUser        🔴 the teacher-side scope rule
  USP_GetTeacherProfile      the teacher's own view — everything
  USP_UpdateTeacherProfile   RowVersion checked
  USP_SaveTeacherPhoto
  USP_SaveTeacherResume
  USP_RecalculateTeacherProfile   completion percentage + experience total

  ---------------------------------------------------------------------------
  🔴 THE SCOPE RULE: A TEACHER OWNS EXACTLY ONE PROFILE
  ---------------------------------------------------------------------------
  Simpler than the school side and it has to be just as strict. Every write
  resolves the teacher from the caller's UserUid — never from a TeacherId
  parameter.

  The procedures are shaped so that "edit somebody else's profile" cannot be
  EXPRESSED, not merely so that it is rejected: none of them take a TeacherId
  from the caller at all. Where a child row is addressed by id — an experience,
  a document — the id is checked against the resolved teacher before anything
  happens.

  There is no legitimate case where one teacher edits another's profile, and an
  admin correcting a profile is a different procedure with its own audit trail,
  not a parameter on this one.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  fn_TeacherIdForUser

  The one place a UserUid becomes a TeacherId.

  ⚠️ Scalar rather than a table-valued function, unlike fn_VisibleBranches: the
  school answer is a SET of branches that has to be joined to, the teacher answer
  is one row or nothing. A TVF here would invite `JOIN fn_TeacherIdForUser(...)`
  in places where the honest statement is `WHERE TeacherId = @me`.

  Returns NULL for an unknown or deleted account, so every caller's guard is the
  same `IS NULL` check and nobody has to remember a sentinel value.
==============================================================================*/
CREATE OR ALTER FUNCTION dbo.fn_TeacherIdForUser
(
    @UserUid uniqueidentifier
)
RETURNS bigint
AS
BEGIN
    RETURN (SELECT t.TeacherId
            FROM dbo.t_app_teachers t
            WHERE t.UserUid = @UserUid AND t.Is_Deleted = 0);
END
GO


/*==============================================================================
  USP_GetTeacherProfile — the teacher's own view.

  Seven result sets: profile, subjects, class levels, skills, languages,
  preferred locations, experiences, documents.

  Read procedure: no transaction, no CATCH (Block B of the template).
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetTeacherProfile
    @UserUid uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TeacherId bigint = dbo.fn_TeacherIdForUser(@UserUid);

    -- ---- 1. the profile ---------------------------------------------------
    SELECT
        t.TeacherId, t.TeacherUid, t.UserUid,
        t.FullName, t.PhotoPath, t.DOB, t.GenderId,
        t.QualificationId, t.HighestQualificationText, t.DesignationId,
        t.TotalExperienceMonths, t.CurrentSchool, t.LastSchool,
        t.ExpectedSalaryMin, t.ExpectedSalaryMax,
        t.CurrentCityId, t.CurrentStateId,
        t.CurrentDistrictId, t.CurrentTehsilId, t.CurrentAreaOrVillage,

        /*
          D1. THE MAP PIN — 041_alter_teacher_geopoint.sql.

          🔒 RETURNED HERE AND NOWHERE ELSE. This procedure is the teacher's own
          form, read through their own UserUid, so the pin is going back to the
          person who placed it. USP_GetTeacherPublicProfile — what a SCHOOL sees
          — does NOT return these and must never be "made consistent" with this
          read: a home coordinate to ±11 cm is somebody's front door, and 039
          already refused the teacher AddressLine1/2 and Pincode on exactly that
          ground. What leaves the building is a DISTANCE IN METRES from
          USP_BrowseJobs, which cannot be inverted into a place.

          ⚠️ GeoPoint ITSELF IS NOT PROJECTED. It is a CLR type that no DTO in
          this product can hold, and the two decimals are what the map picker
          reads and writes. The computed column exists to be measured against,
          not to travel.
        */
        t.Latitude, t.Longitude,

        t.AboutMe, t.ResumePath,
        t.IsVerified, t.VerifiedOn, t.IsSuspended,
        t.ProfileCompletionPercent,
        t.RowVersion
    FROM dbo.t_app_teachers t
    WHERE t.TeacherId = @TeacherId;

    -- ---- 2..6 the bridges -------------------------------------------------
    SELECT s.SubjectId FROM dbo.t_app_teacher_subjects s
    WHERE s.TeacherId = @TeacherId AND s.Is_Deleted = 0;

    SELECT c.ClassLevelId FROM dbo.t_app_teacher_class_levels c
    WHERE c.TeacherId = @TeacherId AND c.Is_Deleted = 0;

    SELECT k.SkillId FROM dbo.t_app_teacher_skills k
    WHERE k.TeacherId = @TeacherId AND k.Is_Deleted = 0;

    SELECT l.LanguageId, l.ProficiencyLevel FROM dbo.t_app_teacher_languages l
    WHERE l.TeacherId = @TeacherId AND l.Is_Deleted = 0;

    /*
      ⚠️ TehsilId IS RETURNED NOW. It has been on this table since 036 and was
      never read back, so a screen could not have shown a saved tehsil even if
      one had ever been written — and none ever was, because the table type that
      carries the save had no column for it until today. Both halves are fixed
      together, which is the whole point.
    */
    SELECT p.Id, p.CityId, p.StateId, p.PreferenceOrder, p.TehsilId
    FROM dbo.t_app_teacher_preferred_locations p
    WHERE p.TeacherId = @TeacherId AND p.Is_Deleted = 0
    ORDER BY p.PreferenceOrder, p.Id;

    -- ---- 7. experiences, newest first — a career reads backwards ----------
    SELECT e.Id, e.SchoolName, e.DesignationId, e.SubjectId,
           e.FromDate, e.ToDate, e.IsCurrent
    FROM dbo.t_app_teacher_experiences e
    WHERE e.TeacherId = @TeacherId AND e.Is_Deleted = 0
    ORDER BY e.IsCurrent DESC, e.FromDate DESC;

    -- ---- 8. documents ------------------------------------------------------
    SELECT d.DocumentId, d.DocumentTypeId, d.FileName, d.FileSizeKb,
           d.MimeType, d.IsVerified, d.VerifiedOn, d.CreatedOn
    FROM dbo.t_app_teacher_documents d
    WHERE d.TeacherId = @TeacherId AND d.Is_Deleted = 0
    ORDER BY d.DocumentTypeId, d.CreatedOn DESC;
END
GO


/*==============================================================================
  USP_RecalculateTeacherProfile

  🔴 THE COMPLETION RULE, AND THE EXPERIENCE TOTAL, IN ONE PLACE.

  Called by every procedure in this file that changes anything a percentage
  depends on. Not by the client, and not duplicated per procedure — the whole
  point of a single number is that everything agrees on it.

  ---------------------------------------------------------------------------
  🔴 WHAT COUNTS, AND WHY IT IS WEIGHTED THIS WAY
  ---------------------------------------------------------------------------
  Weighted toward WHAT GETS SOMEBODY HIRED, not toward what fills fields.

      25  a resume            the single thing a school asks for first
      20  at least one subject   without it the teacher is unfindable
      15  at least one experience row
      10  a photo
      10  designation + qualification (5 each)
       8  about me, 40 characters or more
       7  at least one preferred location
       5  class levels

  🔴 A PROFILE WITH NO RESUME CANNOT EXCEED 75.

  That is the point of the weighting, and it is why the resume is worth more
  than anything else here. A teacher shown 100% with no resume has been told
  they are finished by a system that is about to watch schools discard them.
  Better to show 75 and have them ask why.

  ⚠️ AboutMe is measured at 40 characters, not at "not empty". A single word in
  a free-text box is a field somebody filled to make a number move, and counting
  it would teach exactly that.

  Subjects are worth more than class levels because a school searches on subject
  first; a teacher with no subject rows is invisible to the search that matters,
  whatever else they have filled in.

  ---------------------------------------------------------------------------
  TotalExperienceMonths IS DERIVED, NEVER STORED INDEPENDENTLY
  ---------------------------------------------------------------------------
  Phase 3B found hand-written values disagreeing with their own experience rows
  by up to thirteen months. A total that contradicts its own evidence surfaces
  in a search filter and cannot be explained to the person it belongs to.

  An open row (IsCurrent = 1) counts up to today, which is why this is
  recomputed on every change rather than only on insert.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_RecalculateTeacherProfile
    @TeacherId bigint
AS
BEGIN
    SET NOCOUNT ON;

    IF @TeacherId IS NULL RETURN;

    DECLARE @pct int = 0;
    DECLARE @today date = CAST(SYSUTCDATETIME() AS date);

    DECLARE @hasResume      bit, @hasPhoto bit, @hasAbout bit,
            @hasDesignation bit, @hasQualification bit,
            @subjects int, @classLevels int, @locations int, @experiences int;

    SELECT @hasResume        = CASE WHEN NULLIF(LTRIM(RTRIM(t.ResumePath)), N'') IS NOT NULL THEN 1 ELSE 0 END,
           @hasPhoto         = CASE WHEN NULLIF(LTRIM(RTRIM(t.PhotoPath)),  N'') IS NOT NULL THEN 1 ELSE 0 END,
           -- 40 characters, not "not empty". See the note above.
           @hasAbout         = CASE WHEN LEN(LTRIM(RTRIM(ISNULL(t.AboutMe, N'')))) >= 40 THEN 1 ELSE 0 END,
           @hasDesignation   = CASE WHEN t.DesignationId   IS NOT NULL THEN 1 ELSE 0 END,
           @hasQualification = CASE WHEN t.QualificationId IS NOT NULL THEN 1 ELSE 0 END
    FROM dbo.t_app_teachers t
    WHERE t.TeacherId = @TeacherId;

    SELECT @subjects    = COUNT(*) FROM dbo.t_app_teacher_subjects            WHERE TeacherId = @TeacherId AND Is_Deleted = 0;
    SELECT @classLevels = COUNT(*) FROM dbo.t_app_teacher_class_levels        WHERE TeacherId = @TeacherId AND Is_Deleted = 0;
    SELECT @locations   = COUNT(*) FROM dbo.t_app_teacher_preferred_locations WHERE TeacherId = @TeacherId AND Is_Deleted = 0;
    SELECT @experiences = COUNT(*) FROM dbo.t_app_teacher_experiences         WHERE TeacherId = @TeacherId AND Is_Deleted = 0;

    SET @pct =
          (CASE WHEN @hasResume        = 1 THEN 25 ELSE 0 END)
        + (CASE WHEN @subjects         > 0 THEN 20 ELSE 0 END)
        + (CASE WHEN @experiences      > 0 THEN 15 ELSE 0 END)
        + (CASE WHEN @hasPhoto         = 1 THEN 10 ELSE 0 END)
        + (CASE WHEN @hasDesignation   = 1 THEN  5 ELSE 0 END)
        + (CASE WHEN @hasQualification = 1 THEN  5 ELSE 0 END)
        + (CASE WHEN @hasAbout         = 1 THEN  8 ELSE 0 END)
        + (CASE WHEN @locations        > 0 THEN  7 ELSE 0 END)
        + (CASE WHEN @classLevels      > 0 THEN  5 ELSE 0 END);

    /*
      🔴 ToDate + 1 DAY, and the reason is not cosmetic.

      DATEDIFF(MONTH, ...) counts BOUNDARIES CROSSED, not months elapsed. For
      1 June 2020 to 31 May 2022 it returns 23, because the 31st has not crossed
      into June — but that teacher worked twenty-four months.

      Every closed period was short by one, so a career of six jobs was short by
      six. Treating ToDate as the LAST DAY WORKED makes the period
      [FromDate, ToDate + 1) and DATEDIFF counts it correctly.

      An open period runs to today untouched: the current month genuinely is not
      complete, and rounding it up would claim a month somebody has not yet
      worked.
    */
    DECLARE @months int;

    SELECT @months = SUM(DATEDIFF(
               MONTH,
               e.FromDate,
               CASE WHEN e.ToDate IS NULL THEN @today ELSE DATEADD(DAY, 1, e.ToDate) END))
    FROM dbo.t_app_teacher_experiences e
    WHERE e.TeacherId = @TeacherId AND e.Is_Deleted = 0;

    /*
      🔴 COMPUTE, COMPARE, THEN WRITE — never write unconditionally.

      This runs after every save, including one that changed nothing. An
      unconditional UPDATE stamps ModifiedOn each time, which turns "when did
      this teacher last change something" into "when did anybody last press
      Save" — the exact failure the bridge-sync argument in
      005_school_photos_facilities.sql rejects, committed on the parent row
      instead of the child.

      ⚠️ Found by the Phase 3D independent verification, not by the suite. The
      suite asserted on the procedure's own Added/Restored/Removed counters,
      which were correctly zero; the verification read the TABLE afterwards and
      saw ModifiedOn had moved anyway. A counter is a procedure's claim about
      itself.

      RowVersion is deliberately NOT bumped here either way: a recalculation is
      the server's own bookkeeping, not an edit somebody else should lose a
      concurrency race to.
    */
    DECLARE @currentPct tinyint, @currentMonths int;

    SELECT @currentPct = t.ProfileCompletionPercent, @currentMonths = t.TotalExperienceMonths
    FROM dbo.t_app_teachers t
    WHERE t.TeacherId = @TeacherId;

    IF @currentPct = @pct
       AND ((@currentMonths IS NULL AND @months IS NULL) OR @currentMonths = @months)
        RETURN;

    UPDATE dbo.t_app_teachers
       SET ProfileCompletionPercent = @pct,
           TotalExperienceMonths    = @months,
           ModifiedOn               = SYSUTCDATETIME()
     WHERE TeacherId = @TeacherId;
END
GO


/*==============================================================================
  USP_UpdateTeacherProfile

  ⚠️ RowVersion re-checked INSIDE the UPDATE's WHERE clause, not only in
  validation — the window between a validating read and the write is the bug
  2.46 records.

  IsVerified and IsSuspended are NOT updatable here. Verification is an
  administrator's decision about a person's documents (2.9); a teacher marking
  themselves verified would make the badge worthless.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_UpdateTeacherProfile
    @UserUid                    uniqueidentifier,
    @RowVersion                 int,
    @FullName                   nvarchar(150),
    @DOB                        date           = NULL,
    @GenderId                   int            = NULL,
    @QualificationId            int            = NULL,
    @HighestQualificationText   nvarchar(200)  = NULL,
    @DesignationId              int            = NULL,
    @CurrentSchool              nvarchar(200)  = NULL,
    @LastSchool                 nvarchar(200)  = NULL,
    @ExpectedSalaryMin          decimal(12, 2) = NULL,
    @ExpectedSalaryMax          decimal(12, 2) = NULL,
    @CurrentCityId              int            = NULL,
    @CurrentStateId             int            = NULL,

    /*
      Client instruction, 15 Nov 2026: the teacher's address gets the same chain
      the school has — State, District, City/Town, Tehsil/Sub-tehsil, Area or
      village. 039_alter_teacher_address_columns.sql added the three columns;
      these are how they are written.

      ⚠️ DISTRICT IS NOW STORED, NOT DERIVED. The screen used to rebuild it from
      the saved city on every re-open, which worked only because a city belongs
      to exactly one district — and stops being defensible under a tehsil, which
      sits BETWEEN them. A derived parent cannot be checked against a stored
      child.

      ⚠️ ALL THREE OPTIONAL, like every other field on this procedure. A teacher
      who filled in their address before today has NULL in them, which is the
      honest value: nobody asked.
    */
    @CurrentDistrictId          int            = NULL,
    @CurrentTehsilId            int            = NULL,
    @CurrentAreaOrVillage       nvarchar(200)  = NULL,

    /*
      ----------------------------------------------------------------------------
      D1. THE TEACHER'S MAP PIN — 041_alter_teacher_geopoint.sql.
      ----------------------------------------------------------------------------
      One optional point, roughly where they live. It is the LEFT operand of the
      STDistance that orders their job list nearest-first, and it is the only
      thing that makes that ordering possible: with no pin, USP_BrowseJobs
      returns the list in exactly the date order it returned before D1 existed.

      ⚠️ decimal(9,6) TO MATCH THE COLUMNS, not float. Binding float here would
      hand SQL Server a conversion on every save and, worse, make the value that
      round-trips differ in the last bits from the value that was sent — which
      the map picker reads as "the host moved my pin" and re-emits. Same shape
      as USP_SaveBranch's @Latitude/@Longitude, for the same reasons.

      🔴 NOT COALESCED WITH WHAT IS STORED, UNLIKE THE CAMPUS ANCHOR. 006's
      @GeocodedLatitude keeps the stored value when the caller sends NULL,
      because a campus edit must not un-geocode an address. This is the
      opposite: the teacher's form SENDS THE WHOLE ROW on every save (the
      RowVersion contract), so NULL here means "they cleared their pin" and has
      to be written. Coalescing would make the pin unremovable — and "remove my
      home coordinates" is a request this product must be able to honour.

      ⚠️ WHICH MAKES THE CLIENT RESPONSIBLE for sending the pin back on every
      save of this row. UpdateTeacherProfileBody carries it, the profile screen
      seeds the draft from the GET, and nearby-jobs.mjs asserts the round trip —
      because a section save that dropped the field would silently delete
      somebody's pin while saying "Saved".
    */
    @Latitude                   decimal(9, 6)  = NULL,
    @Longitude                  decimal(9, 6)  = NULL,

    @AboutMe                    nvarchar(max)  = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL, @Id bigint = NULL,
            @Now datetime2 = SYSUTCDATETIME();

    DECLARE @TeacherId bigint = dbo.fn_TeacherIdForUser(@UserUid);
    DECLARE @CurrentRowVersion int = NULL, @IsSuspended tinyint = NULL;

    SET @Id = @TeacherId;

    SELECT @CurrentRowVersion = t.RowVersion, @IsSuspended = t.IsSuspended
    FROM dbo.t_app_teachers t WHERE t.TeacherId = @TeacherId;

    IF @TeacherId IS NULL
        SELECT @Code = 'NOT_FOUND', @Message = N'That profile was not found.';
    ELSE IF ISNULL(@FullName, N'') = N''
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'Your name is required.';
    ELSE IF @IsSuspended = 1
        SELECT @Code = 'BUSINESS_RULE_VIOLATED',
               @Message = N'This profile is suspended and cannot be edited.';
    ELSE IF @ExpectedSalaryMin IS NOT NULL AND @ExpectedSalaryMax IS NOT NULL
        AND @ExpectedSalaryMax < @ExpectedSalaryMin
        SELECT @Code = 'VALIDATION_FAILED',
               @Message = N'The salary range runs backwards — the maximum is below the minimum.';

    -- A date of birth in the future, or implying an age under 18, is a typo
    -- rather than a fact. Checked here because it is cheap and because the
    -- alternative is a teacher search returning a nine-year-old.
    ELSE IF @DOB IS NOT NULL AND @DOB > DATEADD(YEAR, -18, CAST(@Now AS date))
        SELECT @Code = 'VALIDATION_FAILED',
               @Message = N'That date of birth does not look right.';

    /*
      ----------------------------------------------------------------------------
      D1. 🔴 HALF A PIN IS NOT A PLACE, AND THE REFUSAL NAMES WHICH HALF (2.21).
      ----------------------------------------------------------------------------
      The two columns are independent, so a latitude with no longitude would
      store happily — and 041's computed column would then read it as NO PIN,
      because its CASE NULLs the geography whenever either coordinate is
      missing. 🔴 That is the dangerous outcome: the teacher's screen would show
      a latitude they entered, the job list would behave as though they had
      pinned nothing, and the two facts would never be reconciled on any screen.

      So it is refused here, up front, rather than absorbed. The CASE in 041
      remains the second line of defence for any writer that bypasses this
      procedure; this is the line that can explain itself to a person.

      ⚠️ BOTH NULL IS VALID AND IS THE DEFAULT STATE. A teacher who never opened
      the map, and a teacher who deliberately cleared their pin, both arrive
      here with two NULLs — and both are saved. Requiring the pair in only one
      direction would make the pin unremovable.
    */
    /*
      ⚠️ THE XOR IS SPELLED WITH TWO CASEs, not `(@a IS NULL) <> (@b IS NULL)`.
      T-SQL has no boolean VALUE — a predicate is only legal where a predicate
      is expected — so the obvious spelling is a syntax error rather than a
      subtle bug. Recorded because it is the second thing anybody tidying this
      up will try.
    */
    ELSE IF (CASE WHEN @Latitude  IS NULL THEN 1 ELSE 0 END)
         <> (CASE WHEN @Longitude IS NULL THEN 1 ELSE 0 END)
        SELECT @Code = 'VALIDATION_FAILED',
               @Message = CASE WHEN @Latitude IS NULL
                               THEN N'A map pin needs both numbers. The latitude is missing — add it, or clear the longitude to remove the pin.'
                               ELSE N'A map pin needs both numbers. The longitude is missing — add it, or clear the latitude to remove the pin.'
                          END;

    /*
      ⚠️ THE RANGE CHECK NAMES THE SWAP, because that is what has almost always
      happened. In India a longitude is 68–97 and a latitude is 8–37, so a
      longitude typed into the latitude box is the mistake this catches most —
      and it is the one mistake that produces a VALID-looking point. 29.15 and
      75.72 are both legal latitudes; reversed, the teacher lands in the Kara
      Sea and their job list is silently ranked by how far north each school is
      (041's guard 1 argues this at length).

      ⚠️ decimal(9,6) ALREADY BOUNDS THE MAGNITUDE at ±999.999999, so this is
      not about overflow — it is about the band in between, which the type
      cannot express and a person can type.
    */
    ELSE IF @Latitude IS NOT NULL AND (@Latitude < -90 OR @Latitude > 90)
        SELECT @Code = 'VALIDATION_FAILED',
               @Message = N'A latitude is between -90 and 90. Check the two numbers have not been swapped — in India a latitude is roughly 8 to 37 and a longitude 68 to 97.';
    ELSE IF @Longitude IS NOT NULL AND (@Longitude < -180 OR @Longitude > 180)
        SELECT @Code = 'VALIDATION_FAILED',
               @Message = N'A longitude is between -180 and 180. Check the two numbers have not been swapped — in India a latitude is roughly 8 to 37 and a longitude 68 to 97.';

    ELSE IF @CurrentRowVersion <> @RowVersion
        SELECT @Code = 'CONCURRENCY_CONFLICT',
               @Message = N'Your profile was changed somewhere else while you were editing it. Reload and try again.';

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            UPDATE dbo.t_app_teachers
               SET FullName                 = @FullName,
                   DOB                      = @DOB,
                   GenderId                 = @GenderId,
                   QualificationId          = @QualificationId,
                   HighestQualificationText = @HighestQualificationText,
                   DesignationId            = @DesignationId,
                   CurrentSchool            = @CurrentSchool,
                   LastSchool               = @LastSchool,
                   ExpectedSalaryMin        = @ExpectedSalaryMin,
                   ExpectedSalaryMax        = @ExpectedSalaryMax,
                   CurrentCityId            = @CurrentCityId,
                   CurrentStateId           = @CurrentStateId,
                   CurrentDistrictId        = @CurrentDistrictId,
                   CurrentTehsilId          = @CurrentTehsilId,
                   CurrentAreaOrVillage     = @CurrentAreaOrVillage,

                   /*
                     D1. 🔴 WRITTEN PLAINLY, NOT COALESCED. NULL clears the pin
                     — see the parameter comment. GeoPoint is not in this list
                     and must never be: it is a computed column (041) and SQL
                     Server maintains it from these two.
                   */
                   Latitude                 = @Latitude,
                   Longitude                = @Longitude,

                   AboutMe                  = @AboutMe,
                   RowVersion               = RowVersion + 1,
                   ModifiedOn               = @Now
             WHERE TeacherId  = @TeacherId
               AND Is_Deleted = 0
               AND RowVersion = @RowVersion;   -- 🔴 re-checked HERE

            IF @@ROWCOUNT = 0
                SELECT @Code = 'CONCURRENCY_CONFLICT',
                       @Message = N'Your profile was changed somewhere else while you were editing it. Reload and try again.';
            ELSE
            BEGIN
                EXEC dbo.USP_RecalculateTeacherProfile @TeacherId = @TeacherId;
                SELECT @Status = 1, @Message = N'Profile saved.';
            END
        END TRY
        BEGIN CATCH
            DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                    @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                    @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            DECLARE @Params nvarchar(max) = (
                SELECT @TeacherId AS teacherId, @RowVersion AS rowVersion
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
                 @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
                 @ErrorMessage = @ErrMessage, @ParametersJson = @Params,
                 @ContextInfo = N'USP_UpdateTeacherProfile';

            THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @Id AS Id;
END
GO


/*==============================================================================
  USP_SaveTeacherPhoto / USP_SaveTeacherResume

  ⚠️ No RowVersion, for the same reason as the school logo (2.53): an upload is
  its own action, not an edit of a form somebody else has open. Failing it
  because the teacher saved their About Me a minute ago would be a rule nobody
  could explain.

  Both recalculate, because both move the percentage — the resume by 25.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SaveTeacherPhoto
    @UserUid    uniqueidentifier,
    @PhotoPath  nvarchar(500)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL;

    DECLARE @TeacherId bigint = dbo.fn_TeacherIdForUser(@UserUid);

    IF @TeacherId IS NULL
        SELECT @Code = 'NOT_FOUND', @Message = N'That profile was not found.';
    ELSE IF ISNULL(@PhotoPath, N'') = N''
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The photo file is required.';

    IF @Code IS NULL
    BEGIN
        UPDATE dbo.t_app_teachers
           SET PhotoPath = @PhotoPath, ModifiedOn = SYSUTCDATETIME()
         WHERE TeacherId = @TeacherId AND Is_Deleted = 0;

        EXEC dbo.USP_RecalculateTeacherProfile @TeacherId = @TeacherId;

        SELECT @Status = 1, @Message = N'Photo saved.';
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @TeacherId AS Id;
END
GO

CREATE OR ALTER PROCEDURE dbo.USP_SaveTeacherResume
    @UserUid    uniqueidentifier,
    @ResumePath nvarchar(500)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL;

    DECLARE @TeacherId bigint = dbo.fn_TeacherIdForUser(@UserUid);

    IF @TeacherId IS NULL
        SELECT @Code = 'NOT_FOUND', @Message = N'That profile was not found.';
    ELSE IF ISNULL(@ResumePath, N'') = N''
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The resume file is required.';

    IF @Code IS NULL
    BEGIN
        UPDATE dbo.t_app_teachers
           SET ResumePath = @ResumePath, ModifiedOn = SYSUTCDATETIME()
         WHERE TeacherId = @TeacherId AND Is_Deleted = 0;

        EXEC dbo.USP_RecalculateTeacherProfile @TeacherId = @TeacherId;

        SELECT @Status = 1, @Message = N'Resume saved.';
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @TeacherId AS Id;
END
GO

PRINT '    Teacher profile procedures ready.';
GO
