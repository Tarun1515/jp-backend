/*==============================================================================
  jp_app — 99_tests / 002_test_teacher.sql

  PHASE 3D — teacher procedures.

  ---------------------------------------------------------------------------
  🔴 THE SECTIONS THAT MATTER ARE 2 AND 7
  ---------------------------------------------------------------------------
  Section 2 is every path by which teacher A might touch teacher B. Section 7 is
  the public profile refusing to hand over a contact detail.

  Everything else checks that the procedures work. Those two check that they
  cannot be made to work for the wrong person, which is the harder property and
  the one nobody notices is missing.

  Conventions (2.30): table VARIABLES for the assertion log, plain EXEC, builds
  its own fixtures and rolls them back.
==============================================================================*/

USE jp_app;
GO

SET NOCOUNT ON;
SET XACT_ABORT OFF;
GO

DECLARE @t TABLE (n int IDENTITY(1,1), section varchar(24), what nvarchar(94), got nvarchar(60), pass varchar(4));

DECLARE @userA uniqueidentifier = NEWID(),
        @userB uniqueidentifier = NEWID(),
        @stranger uniqueidentifier = NEWID();
DECLARE @teacherA bigint, @teacherB bigint;
DECLARE @expA bigint, @expB bigint, @docA bigint, @docB bigint;
DECLARE @cnt int, @rv int, @pct int, @months int;
DECLARE @planId int = (SELECT PlanId FROM jp_mdm.dbo.m_mdm_plans WHERE PlanCode = 'TEACHER_FREE');

DECLARE @r  TABLE (Status int, Code varchar(50), Message nvarchar(400), Id bigint);
DECLARE @rb TABLE (Status int, Code varchar(50), Message nvarchar(400), Id bigint,
                   Added int, Restored int, Removed int);
DECLARE @rl TABLE (Status int, Code varchar(50), Message nvarchar(400), Id bigint,
                   Added int, Restored int, Removed int, Updated int);
DECLARE @rp TABLE (Status int, Code varchar(50), Message nvarchar(400), Id bigint, TeacherUid uniqueidentifier);

BEGIN TRANSACTION;

/*==============================================================================
  FIXTURE — two teachers who must never see each other
==============================================================================*/
INSERT INTO @rp EXEC dbo.USP_ProvisionTeacherProfile @UserUid = @userA, @FullName = N'Teacher A', @PlanId = @planId;
INSERT INTO @rp EXEC dbo.USP_ProvisionTeacherProfile @UserUid = @userB, @FullName = N'Teacher B', @PlanId = @planId;

SET @teacherA = dbo.fn_TeacherIdForUser(@userA);
SET @teacherB = dbo.fn_TeacherIdForUser(@userB);

INSERT INTO @t VALUES ('fixture', N'Two profiles created and resolvable by UserUid',
    CAST(ISNULL(@teacherA,0) AS nvarchar(10)) + N' / ' + CAST(ISNULL(@teacherB,0) AS nvarchar(10)),
    CASE WHEN @teacherA IS NOT NULL AND @teacherB IS NOT NULL AND @teacherA <> @teacherB THEN 'PASS' ELSE 'FAIL' END);


/*==============================================================================
  1. THE SCOPE RULE resolves from the token, and only the token
==============================================================================*/
SET @cnt = CASE WHEN dbo.fn_TeacherIdForUser(@stranger) IS NULL THEN 1 ELSE 0 END;
INSERT INTO @t VALUES ('scope', N'An unknown UserUid resolves to NULL, not to somebody',
    CASE WHEN @cnt = 1 THEN N'NULL' ELSE N'resolved!' END, CASE WHEN @cnt = 1 THEN 'PASS' ELSE 'FAIL' END);


/*==============================================================================
  2. 🔴 TEACHER A CANNOT TOUCH TEACHER B — every path A controls
==============================================================================*/
-- B's own rows, created by B.
DELETE FROM @r;
INSERT INTO @r EXEC dbo.USP_SaveTeacherExperience
    @UserUid = @userB, @SchoolName = N'B''s School', @FromDate = '2020-01-01', @IsCurrent = 1;
SELECT @expB = Id FROM @r;

DELETE FROM @r;
INSERT INTO @r EXEC dbo.USP_SaveTeacherDocument
    @UserUid = @userB, @DocumentTypeId = 11, @FilePath = N'teacher-docs/b-degree.pdf',
    @FileName = N'degree.pdf', @FileSizeKb = 120, @MimeType = 'application/pdf';
SELECT @docB = Id FROM @r;

-- A tries to EDIT B's experience by id.
DELETE FROM @r;
INSERT INTO @r EXEC dbo.USP_SaveTeacherExperience
    @UserUid = @userA, @Id = @expB, @SchoolName = N'Hijacked', @FromDate = '2020-01-01', @IsCurrent = 1;
INSERT INTO @t
SELECT 'A vs B', N'🔴 A cannot EDIT B''s experience row by id', ISNULL(Code, '(succeeded!)'),
       CASE WHEN Code = 'NOT_FOUND' THEN 'PASS' ELSE 'FAIL' END FROM @r;

SELECT @cnt = COUNT(*) FROM dbo.t_app_teacher_experiences
WHERE Id = @expB AND SchoolName = N'B''s School';
INSERT INTO @t VALUES ('A vs B', N'…and B''s row is untouched',
    CASE WHEN @cnt = 1 THEN N'intact' ELSE N'MODIFIED' END, CASE WHEN @cnt = 1 THEN 'PASS' ELSE 'FAIL' END);

-- A tries to DELETE B's experience.
DELETE FROM @r;
INSERT INTO @r EXEC dbo.USP_DeleteTeacherExperience @UserUid = @userA, @Id = @expB;
INSERT INTO @t
SELECT 'A vs B', N'🔴 A cannot DELETE B''s experience row', ISNULL(Code, '(succeeded!)'),
       CASE WHEN Code = 'NOT_FOUND' THEN 'PASS' ELSE 'FAIL' END FROM @r;

-- A tries to DELETE B's document.
DELETE FROM @r;
INSERT INTO @r EXEC dbo.USP_DeleteTeacherDocument @UserUid = @userA, @DocumentId = @docB;
INSERT INTO @t
SELECT 'A vs B', N'🔴 A cannot DELETE B''s document', ISNULL(Code, '(succeeded!)'),
       CASE WHEN Code = 'NOT_FOUND' THEN 'PASS' ELSE 'FAIL' END FROM @r;

SELECT @cnt = COUNT(*) FROM dbo.t_app_teacher_documents WHERE DocumentId = @docB AND Is_Deleted = 0;
INSERT INTO @t VALUES ('A vs B', N'…and B''s document is still there',
    CAST(@cnt AS nvarchar(4)) + N' live', CASE WHEN @cnt = 1 THEN 'PASS' ELSE 'FAIL' END);

-- A stranger with no profile at all.
DELETE FROM @r;
INSERT INTO @r EXEC dbo.USP_UpdateTeacherProfile
    @UserUid = @stranger, @RowVersion = 1, @FullName = N'Nobody';
INSERT INTO @t
SELECT 'A vs B', N'🔴 A user with no profile cannot update one', ISNULL(Code, '(succeeded!)'),
       CASE WHEN Code = 'NOT_FOUND' THEN 'PASS' ELSE 'FAIL' END FROM @r;

-- ⚠️ An EMPTY table variable, not NULL: a TVP cannot be NULL ("Operand type
-- clash"). It is also the truer test — clearing your subjects is a real save.
DECLARE @noIds dbo.IntIdList;

DELETE FROM @rb;
INSERT INTO @rb EXEC dbo.USP_SaveTeacherSubjects @UserUid = @stranger, @SubjectIds = @noIds;
INSERT INTO @t
SELECT 'A vs B', N'🔴 …and cannot save subjects either', ISNULL(Code, '(succeeded!)'),
       CASE WHEN Code = 'NOT_FOUND' THEN 'PASS' ELSE 'FAIL' END FROM @rb;

/*
  🔴 THE STRUCTURAL POINT: there is no TeacherId parameter to abuse.

  Every write procedure resolves the teacher from @UserUid. "Edit somebody
  else's profile" is not rejected — it cannot be expressed. Asserted against the
  catalogue rather than by trying it, because the absence of a parameter is the
  property, not the behaviour of one.
*/
SELECT @cnt = COUNT(*)
FROM sys.parameters p
    INNER JOIN sys.procedures s ON s.object_id = p.object_id
WHERE s.name IN ('USP_UpdateTeacherProfile', 'USP_SaveTeacherPhoto', 'USP_SaveTeacherResume',
                 'USP_SaveTeacherSubjects', 'USP_SaveTeacherClassLevels', 'USP_SaveTeacherSkills',
                 'USP_SaveTeacherLanguages', 'USP_SaveTeacherPreferredLocations',
                 'USP_SaveTeacherExperience', 'USP_DeleteTeacherExperience',
                 'USP_SaveTeacherDocument', 'USP_DeleteTeacherDocument')
  AND p.name = '@TeacherId';

INSERT INTO @t VALUES ('A vs B', N'🔴 NO teacher write procedure accepts a @TeacherId parameter',
    CAST(@cnt AS nvarchar(4)) + N' found', CASE WHEN @cnt = 0 THEN 'PASS' ELSE 'FAIL' END);


/*==============================================================================
  3. BRIDGE SYNC — add, remove, no-op, revive
==============================================================================*/
DECLARE @ids dbo.IntIdList;

INSERT INTO @ids (Id) VALUES (1), (2), (10);
DELETE FROM @rb;
INSERT INTO @rb EXEC dbo.USP_SaveTeacherSubjects @UserUid = @userA, @SubjectIds = @ids;
INSERT INTO @t
SELECT 'bridge', N'Adding 3 subjects inserts 3',
       N'added ' + CAST(Added AS nvarchar(4)), CASE WHEN Added = 3 AND Removed = 0 THEN 'PASS' ELSE 'FAIL' END FROM @rb;

DELETE FROM @rb;
INSERT INTO @rb EXEC dbo.USP_SaveTeacherSubjects @UserUid = @userA, @SubjectIds = @ids;
INSERT INTO @t
SELECT 'bridge', N'🔴 A no-op save writes NOTHING',
       N'a' + CAST(Added AS nvarchar(3)) + N'/r' + CAST(Restored AS nvarchar(3)) + N'/d' + CAST(Removed AS nvarchar(3)),
       CASE WHEN Added = 0 AND Restored = 0 AND Removed = 0 THEN 'PASS' ELSE 'FAIL' END FROM @rb;

DECLARE @idsBefore nvarchar(200) = (SELECT STRING_AGG(CAST(Id AS nvarchar(20)), ',') WITHIN GROUP (ORDER BY Id)
                                    FROM dbo.t_app_teacher_subjects WHERE TeacherId = @teacherA AND Is_Deleted = 0);

DELETE FROM @ids; INSERT INTO @ids (Id) VALUES (1), (10);
DELETE FROM @rb;
INSERT INTO @rb EXEC dbo.USP_SaveTeacherSubjects @UserUid = @userA, @SubjectIds = @ids;
INSERT INTO @t
SELECT 'bridge', N'Removing one soft-deletes exactly one',
       N'removed ' + CAST(Removed AS nvarchar(4)), CASE WHEN Removed = 1 AND Added = 0 THEN 'PASS' ELSE 'FAIL' END FROM @rb;

DELETE FROM @ids; INSERT INTO @ids (Id) VALUES (1), (2), (10);
DELETE FROM @rb;
INSERT INTO @rb EXEC dbo.USP_SaveTeacherSubjects @UserUid = @userA, @SubjectIds = @ids;
INSERT INTO @t
SELECT 'bridge', N'🔴 Re-adding REVIVES the tombstone rather than inserting',
       N'restored ' + CAST(Restored AS nvarchar(4)), CASE WHEN Restored = 1 AND Added = 0 THEN 'PASS' ELSE 'FAIL' END FROM @rb;

DECLARE @idsAfter nvarchar(200) = (SELECT STRING_AGG(CAST(Id AS nvarchar(20)), ',') WITHIN GROUP (ORDER BY Id)
                                   FROM dbo.t_app_teacher_subjects WHERE TeacherId = @teacherA AND Is_Deleted = 0);
INSERT INTO @t VALUES ('bridge', N'🔴 …and the row identities are unchanged throughout',
    CASE WHEN @idsBefore = @idsAfter THEN N'same ids' ELSE N'ids changed' END,
    CASE WHEN @idsBefore = @idsAfter THEN 'PASS' ELSE 'FAIL' END);


/*==============================================================================
  4. 🔴 LANGUAGES — a sync WITH A PAYLOAD
==============================================================================*/
DECLARE @langs dbo.LanguageProficiencyList;

INSERT INTO @langs (LanguageId, ProficiencyLevel) VALUES (1, 4), (2, 3);
DELETE FROM @rl;
INSERT INTO @rl EXEC dbo.USP_SaveTeacherLanguages @UserUid = @userA, @Languages = @langs;
INSERT INTO @t
SELECT 'language', N'Adding 2 languages inserts 2',
       N'added ' + CAST(Added AS nvarchar(4)), CASE WHEN Added = 2 THEN 'PASS' ELSE 'FAIL' END FROM @rl;

DELETE FROM @rl;
INSERT INTO @rl EXEC dbo.USP_SaveTeacherLanguages @UserUid = @userA, @Languages = @langs;
INSERT INTO @t
SELECT 'language', N'🔴 A no-op save writes nothing — including no UPDATE',
       N'u' + CAST(Updated AS nvarchar(3)) + N'/a' + CAST(Added AS nvarchar(3)),
       CASE WHEN Updated = 0 AND Added = 0 AND Removed = 0 THEN 'PASS' ELSE 'FAIL' END FROM @rl;

-- 🔴 The case a plain set sync does not have: same language, new level.
DECLARE @langIdBefore bigint = (SELECT Id FROM dbo.t_app_teacher_languages
                                WHERE TeacherId = @teacherA AND LanguageId = 2 AND Is_Deleted = 0);

DELETE FROM @langs; INSERT INTO @langs (LanguageId, ProficiencyLevel) VALUES (1, 4), (2, 1);
DELETE FROM @rl;
INSERT INTO @rl EXEC dbo.USP_SaveTeacherLanguages @UserUid = @userA, @Languages = @langs;
INSERT INTO @t
SELECT 'language', N'🔴 Changing a proficiency is an UPDATE, not delete-and-insert',
       N'updated ' + CAST(Updated AS nvarchar(3)) + N', added ' + CAST(Added AS nvarchar(3)),
       CASE WHEN Updated = 1 AND Added = 0 AND Removed = 0 THEN 'PASS' ELSE 'FAIL' END FROM @rl;

DECLARE @langIdAfter bigint = (SELECT Id FROM dbo.t_app_teacher_languages
                               WHERE TeacherId = @teacherA AND LanguageId = 2 AND Is_Deleted = 0);
SELECT @cnt = CASE WHEN @langIdBefore = @langIdAfter THEN 1 ELSE 0 END;
INSERT INTO @t VALUES ('language', N'…and the row keeps its identity',
    CASE WHEN @cnt = 1 THEN N'same Id' ELSE N'new Id' END, CASE WHEN @cnt = 1 THEN 'PASS' ELSE 'FAIL' END);

SELECT @cnt = ProficiencyLevel FROM dbo.t_app_teacher_languages
WHERE TeacherId = @teacherA AND LanguageId = 2 AND Is_Deleted = 0;
INSERT INTO @t VALUES ('language', N'…and the new level is what was sent',
    N'level ' + CAST(@cnt AS nvarchar(3)), CASE WHEN @cnt = 1 THEN 'PASS' ELSE 'FAIL' END);

DELETE FROM @langs; INSERT INTO @langs (LanguageId, ProficiencyLevel) VALUES (1, 9);
DELETE FROM @rl;
INSERT INTO @rl EXEC dbo.USP_SaveTeacherLanguages @UserUid = @userA, @Languages = @langs;
INSERT INTO @t
SELECT 'language', N'An out-of-range proficiency is refused', ISNULL(Code, '(accepted!)'),
       CASE WHEN Code = 'VALIDATION_FAILED' THEN 'PASS' ELSE 'FAIL' END FROM @rl;


/*==============================================================================
  5. 🔴 PREFERRED LOCATIONS — NULL-equality on a three-column key
==============================================================================*/
DECLARE @locs dbo.PreferredLocationList;

INSERT INTO @locs (CityId, StateId, PreferenceOrder) VALUES (NULL, 14, 1), (NULL, 32, 2);
DELETE FROM @rl;
INSERT INTO @rl EXEC dbo.USP_SaveTeacherPreferredLocations @UserUid = @userA, @Locations = @locs;
INSERT INTO @t
SELECT 'location', N'Two "anywhere in <state>" rows are added',
       N'added ' + CAST(Added AS nvarchar(4)), CASE WHEN Added = 2 THEN 'PASS' ELSE 'FAIL' END FROM @rl;

-- 🔴 The one that breaks a naive implementation: a no-op with NULL cities.
DELETE FROM @rl;
INSERT INTO @rl EXEC dbo.USP_SaveTeacherPreferredLocations @UserUid = @userA, @Locations = @locs;
INSERT INTO @t
SELECT 'location', N'🔴 A no-op save with NULL cities writes NOTHING',
       N'a' + CAST(Added AS nvarchar(3)) + N'/d' + CAST(Removed AS nvarchar(3)),
       CASE WHEN Added = 0 AND Removed = 0 AND Updated = 0 THEN 'PASS' ELSE 'FAIL' END FROM @rl;

SELECT @cnt = COUNT(*) FROM dbo.t_app_teacher_preferred_locations
WHERE TeacherId = @teacherA AND Is_Deleted = 0;
INSERT INTO @t VALUES ('location', N'🔴 …and "anywhere in Maharashtra" exists exactly ONCE',
    CAST(@cnt AS nvarchar(4)) + N' rows total', CASE WHEN @cnt = 2 THEN 'PASS' ELSE 'FAIL' END);

-- The same place sent twice in one call is deduplicated, not rejected.
DELETE FROM @locs;
INSERT INTO @locs (CityId, StateId, PreferenceOrder) VALUES (NULL, 14, 1), (NULL, 14, 5), (NULL, 32, 2);
DELETE FROM @rl;
INSERT INTO @rl EXEC dbo.USP_SaveTeacherPreferredLocations @UserUid = @userA, @Locations = @locs;
INSERT INTO @t
SELECT 'location', N'🔴 The same place twice in one call is deduplicated, not an error',
       ISNULL(Code, '(ok)') + N' a' + CAST(Added AS nvarchar(3)),
       CASE WHEN Status = 1 AND Added = 0 THEN 'PASS' ELSE 'FAIL' END FROM @rl;

SELECT @cnt = COUNT(*) FROM dbo.t_app_teacher_preferred_locations
WHERE TeacherId = @teacherA AND StateId = 14 AND Is_Deleted = 0;
INSERT INTO @t VALUES ('location', N'…and Maharashtra is still a single row',
    CAST(@cnt AS nvarchar(4)) + N' rows', CASE WHEN @cnt = 1 THEN 'PASS' ELSE 'FAIL' END);


/*==============================================================================
  6. EXPERIENCES — entities, and the derived total
==============================================================================*/
DELETE FROM @r;
INSERT INTO @r EXEC dbo.USP_SaveTeacherExperience
    @UserUid = @userA, @SchoolName = N'Two Hats School', @SubjectId = 1,
    @FromDate = '2020-06-01', @ToDate = '2022-05-31', @IsCurrent = 0;
SELECT @expA = Id FROM @r;

-- 🔴 3A deliberately has NO unique index here: two roles at one school starting
-- the same month are legitimate.
DELETE FROM @r;
INSERT INTO @r EXEC dbo.USP_SaveTeacherExperience
    @UserUid = @userA, @SchoolName = N'Two Hats School', @SubjectId = 42,
    @FromDate = '2020-06-01', @ToDate = '2022-05-31', @IsCurrent = 0;
INSERT INTO @t
SELECT 'experience', N'🔴 Two roles at one school, same month, are BOTH accepted',
       ISNULL(Code, '(ok)'), CASE WHEN Status = 1 THEN 'PASS' ELSE 'FAIL' END FROM @r;

SELECT @months = TotalExperienceMonths FROM dbo.t_app_teachers WHERE TeacherId = @teacherA;
INSERT INTO @t VALUES ('experience', N'TotalExperienceMonths recomputed after add (24 + 24)',
    CAST(ISNULL(@months, -1) AS nvarchar(6)) + N'm', CASE WHEN @months = 48 THEN 'PASS' ELSE 'FAIL' END);

-- Edit one to be shorter; the total must follow.
DELETE FROM @r;
INSERT INTO @r EXEC dbo.USP_SaveTeacherExperience
    @UserUid = @userA, @Id = @expA, @SchoolName = N'Two Hats School', @SubjectId = 1,
    @FromDate = '2020-06-01', @ToDate = '2021-05-31', @IsCurrent = 0;

SELECT @months = TotalExperienceMonths FROM dbo.t_app_teachers WHERE TeacherId = @teacherA;
INSERT INTO @t VALUES ('experience', N'🔴 …and after an EDIT that shortened one row (12 + 24)',
    CAST(ISNULL(@months, -1) AS nvarchar(6)) + N'm', CASE WHEN @months = 36 THEN 'PASS' ELSE 'FAIL' END);

DELETE FROM @r;
INSERT INTO @r EXEC dbo.USP_DeleteTeacherExperience @UserUid = @userA, @Id = @expA;
SELECT @months = TotalExperienceMonths FROM dbo.t_app_teachers WHERE TeacherId = @teacherA;
INSERT INTO @t VALUES ('experience', N'🔴 …and after a DELETE (24)',
    CAST(ISNULL(@months, -1) AS nvarchar(6)) + N'm', CASE WHEN @months = 24 THEN 'PASS' ELSE 'FAIL' END);

-- The contradictions the CHECK constraints exist for, refused with a sentence.
DELETE FROM @r;
INSERT INTO @r EXEC dbo.USP_SaveTeacherExperience
    @UserUid = @userA, @SchoolName = N'Backwards', @FromDate = '2021-01-01', @ToDate = '2019-01-01', @IsCurrent = 0;
INSERT INTO @t
SELECT 'experience', N'A role that ended before it started is refused', ISNULL(Code, '(accepted!)'),
       CASE WHEN Code = 'VALIDATION_FAILED' THEN 'PASS' ELSE 'FAIL' END FROM @r;

DELETE FROM @r;
INSERT INTO @r EXEC dbo.USP_SaveTeacherExperience
    @UserUid = @userA, @SchoolName = N'Open ended', @FromDate = '2019-01-01', @ToDate = NULL, @IsCurrent = 0;
INSERT INTO @t
SELECT 'experience', N'A past role with no end date is refused', ISNULL(Code, '(accepted!)'),
       CASE WHEN Code = 'VALIDATION_FAILED' THEN 'PASS' ELSE 'FAIL' END FROM @r;


/*==============================================================================
  7. 🔴 THE PUBLIC PROFILE HANDS OVER NO CONTACT DETAIL

  Against the procedure's METADATA — a column that is absent cannot be populated
  later by somebody who did not read this test (2.53).
==============================================================================*/
DECLARE @publicCols TABLE (name sysname);

INSERT INTO @publicCols (name)
SELECT r.name FROM sys.dm_exec_describe_first_result_set(
    N'EXEC dbo.USP_GetTeacherPublicProfile @TeacherUid = NULL', NULL, 0) r;

DECLARE @leaked nvarchar(400) = (SELECT STRING_AGG(name, ', ') FROM @publicCols
    WHERE name IN ('ContactEmail', 'ContactMobile', 'Email', 'Mobile', 'ResumePath',
                   'DOB', 'UserUid', 'TeacherId', 'RowVersion', 'IsSuspended'));

INSERT INTO @t VALUES ('public', N'🔴 The browse view has NO contact, NO resume, NO date of birth',
    ISNULL(N'leaked: ' + @leaked, N'none present'), CASE WHEN @leaked IS NULL THEN 'PASS' ELSE 'FAIL' END);

SELECT @cnt = COUNT(*) FROM @publicCols WHERE name IN ('TeacherUid', 'FullName', 'TotalExperienceMonths');
INSERT INTO @t VALUES ('public', N'…while still returning what a school needs to decide',
    CAST(@cnt AS nvarchar(4)) + N' of 3', CASE WHEN @cnt = 3 THEN 'PASS' ELSE 'FAIL' END);

-- The contact procedure refuses until the teacher has applied.
DECLARE @teacherAUid uniqueidentifier = (SELECT TeacherUid FROM dbo.t_app_teachers WHERE TeacherId = @teacherA);
DECLARE @someSchool bigint = (SELECT TOP (1) SchoolId FROM dbo.t_app_schools WHERE Is_Deleted = 0);

DECLARE @contact TABLE (Status int, Code varchar(50), Message nvarchar(400), Id bigint,
                        ResumePath nvarchar(500), ContactEmail nvarchar(150), ContactMobile varchar(15));

INSERT INTO @contact EXEC dbo.USP_GetTeacherContactForSchool
    @TeacherUid = @teacherAUid, @ViewerSchoolId = @someSchool;

INSERT INTO @t
SELECT 'public', N'🔴 Contact details are LOCKED until the teacher applies', ISNULL(Code, '(unlocked!)'),
       CASE WHEN Code = 'CONTACT_LOCKED' THEN 'PASS' ELSE 'FAIL' END FROM @contact;

-- 🔴 And the columns are genuinely empty, not merely flagged.
INSERT INTO @t
SELECT 'public', N'🔴 …and the email, mobile and resume come back NULL, not populated',
       CASE WHEN ContactEmail IS NULL AND ContactMobile IS NULL AND ResumePath IS NULL
            THEN N'all NULL' ELSE N'SOMETHING LEAKED' END,
       CASE WHEN ContactEmail IS NULL AND ContactMobile IS NULL AND ResumePath IS NULL
            THEN 'PASS' ELSE 'FAIL' END
FROM @contact;

INSERT INTO @t VALUES ('public', N'…and fn_TeacherContactUnlocked is 0 for every school today',
    CAST(dbo.fn_TeacherContactUnlocked(@teacherA, @someSchool) AS nvarchar(4)),
    CASE WHEN dbo.fn_TeacherContactUnlocked(@teacherA, @someSchool) = 0 THEN 'PASS' ELSE 'FAIL' END);


/*==============================================================================
  8. ROWVERSION on the profile update
==============================================================================*/
SELECT @rv = RowVersion FROM dbo.t_app_teachers WHERE TeacherId = @teacherA;

DELETE FROM @r;
INSERT INTO @r EXEC dbo.USP_UpdateTeacherProfile
    @UserUid = @userA, @RowVersion = @rv, @FullName = N'Teacher A', @AboutMe = N'First edit';
INSERT INTO @t
SELECT 'rowversion', N'A correct RowVersion is accepted', ISNULL(Code, '(ok)'),
       CASE WHEN Status = 1 THEN 'PASS' ELSE 'FAIL' END FROM @r;

DELETE FROM @r;
INSERT INTO @r EXEC dbo.USP_UpdateTeacherProfile
    @UserUid = @userA, @RowVersion = @rv, @FullName = N'Teacher A', @AboutMe = N'Stale edit';
INSERT INTO @t
SELECT 'rowversion', N'🔴 A stale RowVersion is REFUSED', ISNULL(Code, '(succeeded!)'),
       CASE WHEN Code = 'CONCURRENCY_CONFLICT' THEN 'PASS' ELSE 'FAIL' END FROM @r;

-- A salary range that runs backwards.
SELECT @rv = RowVersion FROM dbo.t_app_teachers WHERE TeacherId = @teacherA;
DELETE FROM @r;
INSERT INTO @r EXEC dbo.USP_UpdateTeacherProfile
    @UserUid = @userA, @RowVersion = @rv, @FullName = N'Teacher A',
    @ExpectedSalaryMin = 90000, @ExpectedSalaryMax = 40000;
INSERT INTO @t
SELECT 'rowversion', N'A backwards salary range is refused', ISNULL(Code, '(accepted!)'),
       CASE WHEN Code = 'VALIDATION_FAILED' THEN 'PASS' ELSE 'FAIL' END FROM @r;


/*==============================================================================
  9. 🔴 PROFILE COMPLETION — the promise the rule makes
==============================================================================*/
EXEC dbo.USP_RecalculateTeacherProfile @TeacherId = @teacherA;
SELECT @pct = ProfileCompletionPercent FROM dbo.t_app_teachers WHERE TeacherId = @teacherA;

INSERT INTO @t VALUES ('completion', N'🔴 No resume means the score CANNOT exceed 75',
    CAST(@pct AS nvarchar(4)) + N'%', CASE WHEN @pct <= 75 THEN 'PASS' ELSE 'FAIL' END);

UPDATE dbo.t_app_teachers SET ResumePath = N'teacher-docs/a-resume.pdf' WHERE TeacherId = @teacherA;
EXEC dbo.USP_RecalculateTeacherProfile @TeacherId = @teacherA;
DECLARE @pctWithCv int = (SELECT ProfileCompletionPercent FROM dbo.t_app_teachers WHERE TeacherId = @teacherA);

INSERT INTO @t VALUES ('completion', N'…and adding one is worth exactly 25',
    CAST(@pct AS nvarchar(4)) + N' -> ' + CAST(@pctWithCv AS nvarchar(4)),
    CASE WHEN @pctWithCv - @pct = 25 THEN 'PASS' ELSE 'FAIL' END);

-- A one-word About Me must not count. Filling a box is not writing about
-- yourself, and awarding it would teach exactly that.
SELECT @rv = RowVersion FROM dbo.t_app_teachers WHERE TeacherId = @teacherA;
DELETE FROM @r;
INSERT INTO @r EXEC dbo.USP_UpdateTeacherProfile
    @UserUid = @userA, @RowVersion = @rv, @FullName = N'Teacher A', @AboutMe = N'Teacher.';
DECLARE @pctShort int = (SELECT ProfileCompletionPercent FROM dbo.t_app_teachers WHERE TeacherId = @teacherA);

INSERT INTO @t VALUES ('completion', N'🔴 A one-word About Me earns nothing',
    CAST(@pctShort AS nvarchar(4)) + N'%', CASE WHEN @pctShort = @pctWithCv - 8 OR @pctShort = @pctWithCv THEN 'PASS' ELSE 'FAIL' END);

-- An empty profile is 0, not a participation score.
DECLARE @pctB int;
EXEC dbo.USP_RecalculateTeacherProfile @TeacherId = @teacherB;
SELECT @pctB = ProfileCompletionPercent FROM dbo.t_app_teachers WHERE TeacherId = @teacherB;
INSERT INTO @t VALUES ('completion', N'A profile with only a name and one experience is low, not generous',
    CAST(@pctB AS nvarchar(4)) + N'%', CASE WHEN @pctB <= 20 THEN 'PASS' ELSE 'FAIL' END);


ROLLBACK TRANSACTION;

/*==============================================================================
  RESULTS
==============================================================================*/
PRINT '';
PRINT '===============================================================================';
SELECT RIGHT('  ' + CAST(n AS varchar(3)), 3) + '  '
     + LEFT(section + REPLICATE(' ', 11), 11) + '  '
     + LEFT(what + REPLICATE(N' ', 62), 62) + '  '
     + LEFT(got + REPLICATE(N' ', 20), 20) + '  ' + pass
FROM @t ORDER BY n;

DECLARE @total int = (SELECT COUNT(*) FROM @t),
        @failed int = (SELECT COUNT(*) FROM @t WHERE pass = 'FAIL'),
        @avb int = (SELECT COUNT(*) FROM @t WHERE section = 'A vs B'),
        @avbFail int = (SELECT COUNT(*) FROM @t WHERE section = 'A vs B' AND pass = 'FAIL');

PRINT '===============================================================================';
PRINT '  TEACHER: TOTAL ' + CAST(@total AS varchar(4))
    + '   PASSED ' + CAST(@total - @failed AS varchar(4))
    + '   FAILED ' + CAST(@failed AS varchar(4));
PRINT '  A-CANNOT-TOUCH-B: ' + CAST(@avb AS varchar(4))
    + '   PASSED ' + CAST(@avb - @avbFail AS varchar(4));
PRINT '===============================================================================';
GO
