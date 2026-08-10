/*==============================================================================
  jp_app — 015_t_app_teacher_languages.sql

  Which languages a teacher can teach in.

  In India this is frequently the deciding fact rather than a nice extra —
  a school teaching in Marathi needs somebody who can, whatever their subject.

  Cut from Block C of _TEMPLATE_table.sql: a bridge, so no Uid and no
  RowVersion — the teacher header owns both.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

-- Filtered indexes REQUIRE these, both to CREATE them and for any later
-- INSERT/UPDATE on the table (decision 2.29).
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_app_teacher_languages' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_app_teacher_languages] ...';

    CREATE TABLE dbo.t_app_teacher_languages
    (
        Id              bigint      IDENTITY(1,1) NOT NULL,
        TeacherId       bigint      NOT NULL,

        /*
          ⚠️ CROSS-DATABASE — m_mdm_language in jp_mdm. NO foreign key, and never
          one (decision 2.2). Validated in the procedure; indexed below, because
          an unenforced reference is still one that gets filtered on.

          int, matching m_mdm_language.LanguageId — verified against the live
          column rather than the spec table.
        */
        LanguageId      int         NOT NULL,

        /*
          1 = basic, 2 = conversational, 3 = fluent, 4 = native.

          A CHECK rather than a master: four levels are structural, they are
          branched on when a profile renders, and a fifth would be a code change
          rather than a data change.
        */
        ProficiencyLevel tinyint    NULL,

        -- ---- standard columns -------------------------------------------------
        Is_Active       tinyint     NOT NULL CONSTRAINT DF_t_app_teacher_languages_Is_Active  DEFAULT (1),
        Is_Deleted      tinyint     NOT NULL CONSTRAINT DF_t_app_teacher_languages_Is_Deleted DEFAULT (0),
        CreatedOn       datetime2   NOT NULL CONSTRAINT DF_t_app_teacher_languages_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy       bigint      NULL,
        ModifiedOn      datetime2   NULL,
        ModifiedBy      bigint      NULL,

        CONSTRAINT PK_t_app_teacher_languages PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_t_app_teacher_languages_t_app_teachers
            FOREIGN KEY (TeacherId) REFERENCES dbo.t_app_teachers (TeacherId),
        CONSTRAINT CK_t_app_teacher_languages_ProficiencyLevel
            CHECK (ProficiencyLevel IS NULL OR ProficiencyLevel IN (1, 2, 3, 4)),
        CONSTRAINT CK_t_app_teacher_languages_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_app_teacher_languages_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [t_app_teacher_languages] already exists — skipped.';
END
GO
/*------------------------------------------------------------------------------
  🔴 ONCE PER TEACHER.

  Filtered so a removed entry can be added back, which is the whole reason
  business keys are filtered rather than plain unique (see the template).

  A teacher listed twice against the same value is a data bug that surfaces as a
  duplicate chip in the UI, and nobody traces a duplicate chip back to a missing
  index.

  🔴 Guarded separately from the table (decision 2.29).
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_app_teacher_languages_TeacherId_LanguageId'
                 AND object_id = OBJECT_ID('dbo.t_app_teacher_languages'))
BEGIN
    PRINT '    Creating index [UQ_t_app_teacher_languages_TeacherId_LanguageId] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_app_teacher_languages_TeacherId_LanguageId
        ON dbo.t_app_teacher_languages (TeacherId, LanguageId)
        WHERE Is_Deleted = 0;
END
GO
/*------------------------------------------------------------------------------
  Read the other way when a school filters by medium of instruction.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_teacher_languages_LanguageId'
                 AND object_id = OBJECT_ID('dbo.t_app_teacher_languages'))
BEGIN
    PRINT '    Creating index [IX_t_app_teacher_languages_LanguageId] ...';

    CREATE NONCLUSTERED INDEX IX_t_app_teacher_languages_LanguageId
        ON dbo.t_app_teacher_languages (LanguageId)
        INCLUDE (TeacherId)
        WHERE Is_Deleted = 0;
END
GO
