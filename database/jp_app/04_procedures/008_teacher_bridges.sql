/*==============================================================================
  jp_app — 04_procedures / 008_teacher_bridges.sql

  USP_SaveTeacherSubjects            plain set sync
  USP_SaveTeacherClassLevels         plain set sync
  USP_SaveTeacherSkills              plain set sync
  USP_SaveTeacherLanguages           🔴 sync WITH A PAYLOAD
  USP_SaveTeacherPreferredLocations  🔴 three-column key, NULL-equality

  ---------------------------------------------------------------------------
  ALL FIVE FOLLOW THE PATTERN 3C SETTLED (2.53)
  ---------------------------------------------------------------------------
  Send the whole desired set; diff against what is stored; INSERT what is new,
  SOFT-DELETE what has gone, REVIVE a tombstone rather than inserting beside it.
  Never delete-all-then-reinsert.

  The reference implementation is USP_SaveSchoolFacilities. Two of these five
  are not plain sets, and the differences are called out where they occur rather
  than left for a reader to notice.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*------------------------------------------------------------------------------
  Languages carry a level, so they need a type with two columns.

  ⚠️ A table type cannot be ALTERed — only dropped and recreated, and the drop
  fails while any procedure references it. A third column here means a new type
  with a new name, not an edit to this one.
------------------------------------------------------------------------------*/
IF TYPE_ID(N'dbo.LanguageProficiencyList') IS NULL
BEGIN
    PRINT '    Creating table type [LanguageProficiencyList] ...';

    CREATE TYPE dbo.LanguageProficiencyList AS TABLE
    (
        LanguageId       int      NOT NULL PRIMARY KEY,
        ProficiencyLevel tinyint  NULL
    );
END
GO

/*------------------------------------------------------------------------------
  Preferred locations key on (CityId, StateId), and CityId is nullable.
------------------------------------------------------------------------------*/
IF TYPE_ID(N'dbo.PreferredLocationList') IS NULL
BEGIN
    PRINT '    Creating table type [PreferredLocationList] ...';

    CREATE TYPE dbo.PreferredLocationList AS TABLE
    (
        -- ⚠️ NOT a primary key on (CityId, StateId): a PK forbids NULL, and
        -- "anywhere in Maharashtra" is a NULL city. The uniqueness that matters
        -- is enforced by the target table's filtered index, and the procedure
        -- deduplicates the input before touching anything.
        CityId          int NULL,
        StateId         int NOT NULL,
        PreferenceOrder int NOT NULL
    );
END
GO


/*==============================================================================
  USP_SaveTeacherSubjects — the plain shape, and the one 3D repeats twice more.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SaveTeacherSubjects
    @UserUid    uniqueidentifier,
    @SubjectIds dbo.IntIdList READONLY
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL, @Message nvarchar(400) = NULL,
            @added int = 0, @restored int = 0, @removed int = 0,
            @Now datetime2 = SYSUTCDATETIME();

    DECLARE @TeacherId bigint = dbo.fn_TeacherIdForUser(@UserUid);

    IF @TeacherId IS NULL
        SELECT @Code = 'NOT_FOUND', @Message = N'That profile was not found.';

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            -- 1. GONE — live here, absent from the incoming set.
            UPDATE s SET s.Is_Deleted = 1, s.ModifiedOn = @Now
            FROM dbo.t_app_teacher_subjects s
            WHERE s.TeacherId = @TeacherId AND s.Is_Deleted = 0
              AND NOT EXISTS (SELECT 1 FROM @SubjectIds i WHERE i.Id = s.SubjectId);
            SET @removed = @@ROWCOUNT;

            -- 2. BACK — tombstoned, and wanted again. Revived in place, which
            --    keeps the original Id and CreatedOn and satisfies the filtered
            --    unique index that an INSERT would collide with.
            UPDATE s SET s.Is_Deleted = 0, s.Is_Active = 1, s.ModifiedOn = @Now
            FROM dbo.t_app_teacher_subjects s
                INNER JOIN @SubjectIds i ON i.Id = s.SubjectId
            WHERE s.TeacherId = @TeacherId AND s.Is_Deleted = 1;
            SET @restored = @@ROWCOUNT;

            -- 3. NEW — no row at all. Step 2 already revived every tombstone,
            --    so anything still missing has genuinely never existed.
            INSERT INTO dbo.t_app_teacher_subjects (TeacherId, SubjectId)
            SELECT @TeacherId, i.Id
            FROM @SubjectIds i
            WHERE NOT EXISTS (SELECT 1 FROM dbo.t_app_teacher_subjects s
                              WHERE s.TeacherId = @TeacherId AND s.SubjectId = i.Id);
            SET @added = @@ROWCOUNT;

            COMMIT TRANSACTION;

            EXEC dbo.USP_RecalculateTeacherProfile @TeacherId = @TeacherId;

            SELECT @Status = 1, @Message = N'Subjects saved.';
        END TRY
        BEGIN CATCH
            DECLARE @E1 int = ERROR_NUMBER(), @S1 int = ERROR_SEVERITY(), @T1 int = ERROR_STATE(),
                    @P1 sysname = ERROR_PROCEDURE(), @L1 int = ERROR_LINE(), @M1 nvarchar(4000) = ERROR_MESSAGE();
            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
            EXEC dbo.USP_LogError @ErrorNumber = @E1, @ErrorSeverity = @S1, @ErrorState = @T1,
                 @ErrorProcedure = @P1, @ErrorLine = @L1, @ErrorMessage = @M1,
                 @ContextInfo = N'USP_SaveTeacherSubjects';
            THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @TeacherId AS Id,
           @added AS Added, @restored AS Restored, @removed AS Removed;
END
GO


/*==============================================================================
  USP_SaveTeacherClassLevels — identical shape.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SaveTeacherClassLevels
    @UserUid       uniqueidentifier,
    @ClassLevelIds dbo.IntIdList READONLY
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL, @Message nvarchar(400) = NULL,
            @added int = 0, @restored int = 0, @removed int = 0,
            @Now datetime2 = SYSUTCDATETIME();

    DECLARE @TeacherId bigint = dbo.fn_TeacherIdForUser(@UserUid);

    IF @TeacherId IS NULL
        SELECT @Code = 'NOT_FOUND', @Message = N'That profile was not found.';

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            UPDATE c SET c.Is_Deleted = 1, c.ModifiedOn = @Now
            FROM dbo.t_app_teacher_class_levels c
            WHERE c.TeacherId = @TeacherId AND c.Is_Deleted = 0
              AND NOT EXISTS (SELECT 1 FROM @ClassLevelIds i WHERE i.Id = c.ClassLevelId);
            SET @removed = @@ROWCOUNT;

            UPDATE c SET c.Is_Deleted = 0, c.Is_Active = 1, c.ModifiedOn = @Now
            FROM dbo.t_app_teacher_class_levels c
                INNER JOIN @ClassLevelIds i ON i.Id = c.ClassLevelId
            WHERE c.TeacherId = @TeacherId AND c.Is_Deleted = 1;
            SET @restored = @@ROWCOUNT;

            INSERT INTO dbo.t_app_teacher_class_levels (TeacherId, ClassLevelId)
            SELECT @TeacherId, i.Id
            FROM @ClassLevelIds i
            WHERE NOT EXISTS (SELECT 1 FROM dbo.t_app_teacher_class_levels c
                              WHERE c.TeacherId = @TeacherId AND c.ClassLevelId = i.Id);
            SET @added = @@ROWCOUNT;

            COMMIT TRANSACTION;

            EXEC dbo.USP_RecalculateTeacherProfile @TeacherId = @TeacherId;

            SELECT @Status = 1, @Message = N'Class levels saved.';
        END TRY
        BEGIN CATCH
            DECLARE @E2 int = ERROR_NUMBER(), @S2 int = ERROR_SEVERITY(), @T2 int = ERROR_STATE(),
                    @P2 sysname = ERROR_PROCEDURE(), @L2 int = ERROR_LINE(), @M2 nvarchar(4000) = ERROR_MESSAGE();
            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
            EXEC dbo.USP_LogError @ErrorNumber = @E2, @ErrorSeverity = @S2, @ErrorState = @T2,
                 @ErrorProcedure = @P2, @ErrorLine = @L2, @ErrorMessage = @M2,
                 @ContextInfo = N'USP_SaveTeacherClassLevels';
            THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @TeacherId AS Id,
           @added AS Added, @restored AS Restored, @removed AS Removed;
END
GO


/*==============================================================================
  USP_SaveTeacherSkills — identical shape.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SaveTeacherSkills
    @UserUid  uniqueidentifier,
    @SkillIds dbo.IntIdList READONLY
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL, @Message nvarchar(400) = NULL,
            @added int = 0, @restored int = 0, @removed int = 0,
            @Now datetime2 = SYSUTCDATETIME();

    DECLARE @TeacherId bigint = dbo.fn_TeacherIdForUser(@UserUid);

    IF @TeacherId IS NULL
        SELECT @Code = 'NOT_FOUND', @Message = N'That profile was not found.';

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            UPDATE k SET k.Is_Deleted = 1, k.ModifiedOn = @Now
            FROM dbo.t_app_teacher_skills k
            WHERE k.TeacherId = @TeacherId AND k.Is_Deleted = 0
              AND NOT EXISTS (SELECT 1 FROM @SkillIds i WHERE i.Id = k.SkillId);
            SET @removed = @@ROWCOUNT;

            UPDATE k SET k.Is_Deleted = 0, k.Is_Active = 1, k.ModifiedOn = @Now
            FROM dbo.t_app_teacher_skills k
                INNER JOIN @SkillIds i ON i.Id = k.SkillId
            WHERE k.TeacherId = @TeacherId AND k.Is_Deleted = 1;
            SET @restored = @@ROWCOUNT;

            INSERT INTO dbo.t_app_teacher_skills (TeacherId, SkillId)
            SELECT @TeacherId, i.Id
            FROM @SkillIds i
            WHERE NOT EXISTS (SELECT 1 FROM dbo.t_app_teacher_skills k
                              WHERE k.TeacherId = @TeacherId AND k.SkillId = i.Id);
            SET @added = @@ROWCOUNT;

            COMMIT TRANSACTION;

            EXEC dbo.USP_RecalculateTeacherProfile @TeacherId = @TeacherId;

            SELECT @Status = 1, @Message = N'Skills saved.';
        END TRY
        BEGIN CATCH
            DECLARE @E3 int = ERROR_NUMBER(), @S3 int = ERROR_SEVERITY(), @T3 int = ERROR_STATE(),
                    @P3 sysname = ERROR_PROCEDURE(), @L3 int = ERROR_LINE(), @M3 nvarchar(4000) = ERROR_MESSAGE();
            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
            EXEC dbo.USP_LogError @ErrorNumber = @E3, @ErrorSeverity = @S3, @ErrorState = @T3,
                 @ErrorProcedure = @P3, @ErrorLine = @L3, @ErrorMessage = @M3,
                 @ContextInfo = N'USP_SaveTeacherSkills';
            THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @TeacherId AS Id,
           @added AS Added, @restored AS Restored, @removed AS Removed;
END
GO


/*==============================================================================
  USP_SaveTeacherLanguages — 🔴 A SYNC WITH A PAYLOAD.

  ---------------------------------------------------------------------------
  THE DIFFERENCE FROM THE THREE ABOVE
  ---------------------------------------------------------------------------
  A language row carries ProficiencyLevel. So there is a FOURTH case the plain
  pattern does not have: the row is present, still wanted, and its level has
  CHANGED.

  That is an UPDATE. Treating it as delete-and-insert would give the row a new
  Id and a new CreatedOn for what is, from the teacher's point of view, moving a
  dropdown from "conversational" to "fluent" — and it would churn identities on
  the commonest edit this table will ever see.

  So: removed, restored, updated, added. Four counters, and the test asserts
  that a level change reports updated = 1 and added = 0.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SaveTeacherLanguages
    @UserUid   uniqueidentifier,
    @Languages dbo.LanguageProficiencyList READONLY
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL, @Message nvarchar(400) = NULL,
            @added int = 0, @restored int = 0, @removed int = 0, @updated int = 0,
            @Now datetime2 = SYSUTCDATETIME();

    DECLARE @TeacherId bigint = dbo.fn_TeacherIdForUser(@UserUid);

    IF @TeacherId IS NULL
        SELECT @Code = 'NOT_FOUND', @Message = N'That profile was not found.';
    ELSE IF EXISTS (SELECT 1 FROM @Languages
                    WHERE ProficiencyLevel IS NOT NULL AND ProficiencyLevel NOT IN (1, 2, 3, 4))
        SELECT @Code = 'VALIDATION_FAILED',
               @Message = N'A proficiency level must be 1 (basic) to 4 (native).';

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            -- 1. GONE
            UPDATE l SET l.Is_Deleted = 1, l.ModifiedOn = @Now
            FROM dbo.t_app_teacher_languages l
            WHERE l.TeacherId = @TeacherId AND l.Is_Deleted = 0
              AND NOT EXISTS (SELECT 1 FROM @Languages i WHERE i.LanguageId = l.LanguageId);
            SET @removed = @@ROWCOUNT;

            -- 2. BACK — revived, and the level it comes back with is the one
            --    just sent, not the one it had when it was removed.
            UPDATE l
               SET l.Is_Deleted = 0, l.Is_Active = 1,
                   l.ProficiencyLevel = i.ProficiencyLevel,
                   l.ModifiedOn = @Now
            FROM dbo.t_app_teacher_languages l
                INNER JOIN @Languages i ON i.LanguageId = l.LanguageId
            WHERE l.TeacherId = @TeacherId AND l.Is_Deleted = 1;
            SET @restored = @@ROWCOUNT;

            /*
              3. 🔴 CHANGED — the case the plain pattern does not have.

              Only rows whose level actually differs are touched, so a no-op
              save still writes nothing. The NULL handling is explicit because
              `<>` is never true when either side is NULL, and "had no level,
              now has one" is exactly the edit somebody makes first.
            */
            UPDATE l
               SET l.ProficiencyLevel = i.ProficiencyLevel,
                   l.ModifiedOn = @Now
            FROM dbo.t_app_teacher_languages l
                INNER JOIN @Languages i ON i.LanguageId = l.LanguageId
            WHERE l.TeacherId = @TeacherId
              AND l.Is_Deleted = 0
              AND (   (l.ProficiencyLevel IS NULL     AND i.ProficiencyLevel IS NOT NULL)
                   OR (l.ProficiencyLevel IS NOT NULL AND i.ProficiencyLevel IS NULL)
                   OR (l.ProficiencyLevel <> i.ProficiencyLevel));
            SET @updated = @@ROWCOUNT;

            -- 4. NEW
            INSERT INTO dbo.t_app_teacher_languages (TeacherId, LanguageId, ProficiencyLevel)
            SELECT @TeacherId, i.LanguageId, i.ProficiencyLevel
            FROM @Languages i
            WHERE NOT EXISTS (SELECT 1 FROM dbo.t_app_teacher_languages l
                              WHERE l.TeacherId = @TeacherId AND l.LanguageId = i.LanguageId);
            SET @added = @@ROWCOUNT;

            COMMIT TRANSACTION;

            SELECT @Status = 1, @Message = N'Languages saved.';
        END TRY
        BEGIN CATCH
            DECLARE @E4 int = ERROR_NUMBER(), @S4 int = ERROR_SEVERITY(), @T4 int = ERROR_STATE(),
                    @P4 sysname = ERROR_PROCEDURE(), @L4 int = ERROR_LINE(), @M4 nvarchar(4000) = ERROR_MESSAGE();
            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
            EXEC dbo.USP_LogError @ErrorNumber = @E4, @ErrorSeverity = @S4, @ErrorState = @T4,
                 @ErrorProcedure = @P4, @ErrorLine = @L4, @ErrorMessage = @M4,
                 @ContextInfo = N'USP_SaveTeacherLanguages';
            THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @TeacherId AS Id,
           @added AS Added, @restored AS Restored, @removed AS Removed, @updated AS Updated;
END
GO


/*==============================================================================
  USP_SaveTeacherPreferredLocations — 🔴 THREE-COLUMN KEY, NULL-EQUALITY.

  ---------------------------------------------------------------------------
  WHY THIS ONE IS DIFFERENT
  ---------------------------------------------------------------------------
  A "place" is a state, OR a city within one. CityId is nullable and stays that
  way: the city dataset has not been imported (2.47), so today every row is
  "anywhere in <state>" — and even afterwards, that is a real preference rather
  than a placeholder for one.

  The target's unique index is (TeacherId, CityId, StateId) filtered on
  Is_Deleted = 0, and it relies on SQL Server treating NULLs as EQUAL inside a
  unique index (3A). So (me, NULL, Maharashtra) can exist once — which is
  exactly the rule.

  ⚠️ Every join below therefore needs explicit NULL-equality: `a.CityId =
  b.CityId` is UNKNOWN when both are NULL, so the plain pattern would treat
  "anywhere in Maharashtra" as absent from the incoming set, soft-delete it, and
  then insert it again — a new Id on every save, and a collision with the
  tombstone it had just created.

  The incoming set is deduplicated first, because the caller can send the same
  place twice and the index would reject the batch rather than the duplicate.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SaveTeacherPreferredLocations
    @UserUid   uniqueidentifier,
    @Locations dbo.PreferredLocationList READONLY
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL, @Message nvarchar(400) = NULL,
            @added int = 0, @restored int = 0, @removed int = 0, @updated int = 0,
            @Now datetime2 = SYSUTCDATETIME();

    DECLARE @TeacherId bigint = dbo.fn_TeacherIdForUser(@UserUid);

    IF @TeacherId IS NULL
        SELECT @Code = 'NOT_FOUND', @Message = N'That profile was not found.';

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            /*
              Deduplicate the input.

              The same place sent twice is a client bug, not a teacher's
              intention — and left alone it would hit the unique index and fail
              the whole save rather than the duplicate. The lowest
              PreferenceOrder wins, because if somebody listed Pune first and
              again later, first is what they meant.
            */
            DECLARE @Wanted TABLE (CityId int NULL, StateId int NOT NULL, PreferenceOrder int NOT NULL);

            INSERT INTO @Wanted (CityId, StateId, PreferenceOrder)
            SELECT CityId, StateId, MIN(PreferenceOrder)
            FROM @Locations
            GROUP BY CityId, StateId;

            -- 1. GONE. Note the NULL-equality on CityId.
            UPDATE p SET p.Is_Deleted = 1, p.ModifiedOn = @Now
            FROM dbo.t_app_teacher_preferred_locations p
            WHERE p.TeacherId = @TeacherId AND p.Is_Deleted = 0
              AND NOT EXISTS (
                    SELECT 1 FROM @Wanted w
                    WHERE w.StateId = p.StateId
                      AND ((w.CityId IS NULL AND p.CityId IS NULL) OR w.CityId = p.CityId));
            SET @removed = @@ROWCOUNT;

            -- 2. BACK
            UPDATE p
               SET p.Is_Deleted = 0, p.Is_Active = 1,
                   p.PreferenceOrder = w.PreferenceOrder,
                   p.ModifiedOn = @Now
            FROM dbo.t_app_teacher_preferred_locations p
                INNER JOIN @Wanted w
                    ON w.StateId = p.StateId
                   AND ((w.CityId IS NULL AND p.CityId IS NULL) OR w.CityId = p.CityId)
            WHERE p.TeacherId = @TeacherId AND p.Is_Deleted = 1;
            SET @restored = @@ROWCOUNT;

            -- 3. REORDERED — the place is the same, its rank changed. An
            --    UPDATE, for the same reason a language level is.
            UPDATE p
               SET p.PreferenceOrder = w.PreferenceOrder,
                   p.ModifiedOn = @Now
            FROM dbo.t_app_teacher_preferred_locations p
                INNER JOIN @Wanted w
                    ON w.StateId = p.StateId
                   AND ((w.CityId IS NULL AND p.CityId IS NULL) OR w.CityId = p.CityId)
            WHERE p.TeacherId = @TeacherId
              AND p.Is_Deleted = 0
              AND p.PreferenceOrder <> w.PreferenceOrder;
            SET @updated = @@ROWCOUNT;

            -- 4. NEW
            INSERT INTO dbo.t_app_teacher_preferred_locations
                (TeacherId, CityId, StateId, PreferenceOrder)
            SELECT @TeacherId, w.CityId, w.StateId, w.PreferenceOrder
            FROM @Wanted w
            WHERE NOT EXISTS (
                SELECT 1 FROM dbo.t_app_teacher_preferred_locations p
                WHERE p.TeacherId = @TeacherId
                  AND p.StateId = w.StateId
                  AND ((w.CityId IS NULL AND p.CityId IS NULL) OR w.CityId = p.CityId));
            SET @added = @@ROWCOUNT;

            COMMIT TRANSACTION;

            EXEC dbo.USP_RecalculateTeacherProfile @TeacherId = @TeacherId;

            SELECT @Status = 1, @Message = N'Preferred locations saved.';
        END TRY
        BEGIN CATCH
            DECLARE @E5 int = ERROR_NUMBER(), @S5 int = ERROR_SEVERITY(), @T5 int = ERROR_STATE(),
                    @P5 sysname = ERROR_PROCEDURE(), @L5 int = ERROR_LINE(), @M5 nvarchar(4000) = ERROR_MESSAGE();
            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
            EXEC dbo.USP_LogError @ErrorNumber = @E5, @ErrorSeverity = @S5, @ErrorState = @T5,
                 @ErrorProcedure = @P5, @ErrorLine = @L5, @ErrorMessage = @M5,
                 @ContextInfo = N'USP_SaveTeacherPreferredLocations';
            THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @TeacherId AS Id,
           @added AS Added, @restored AS Restored, @removed AS Removed, @updated AS Updated;
END
GO

PRINT '    Teacher bridge procedures ready.';
GO
