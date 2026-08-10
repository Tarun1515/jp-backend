/*==============================================================================
  jp_app — 014_t_app_teacher_skills.sql

  What a teacher can do beyond their subject.

  Smart-board fluency, sports coaching, exam-board experience. Not a filter
  a school starts with, but the one that decides between two otherwise equal
  candidates — so it is worth having, and worth having exactly once each.

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

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_app_teacher_skills' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_app_teacher_skills] ...';

    CREATE TABLE dbo.t_app_teacher_skills
    (
        Id              bigint      IDENTITY(1,1) NOT NULL,
        TeacherId       bigint      NOT NULL,

        /*
          ⚠️ CROSS-DATABASE — m_mdm_skill in jp_mdm. NO foreign key, and never
          one (decision 2.2). Validated in the procedure; indexed below, because
          an unenforced reference is still one that gets filtered on.

          int, matching m_mdm_skill.SkillId — verified against the live
          column rather than the spec table.
        */
        SkillId         int         NOT NULL,

        -- ---- standard columns -------------------------------------------------
        Is_Active       tinyint     NOT NULL CONSTRAINT DF_t_app_teacher_skills_Is_Active  DEFAULT (1),
        Is_Deleted      tinyint     NOT NULL CONSTRAINT DF_t_app_teacher_skills_Is_Deleted DEFAULT (0),
        CreatedOn       datetime2   NOT NULL CONSTRAINT DF_t_app_teacher_skills_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy       bigint      NULL,
        ModifiedOn      datetime2   NULL,
        ModifiedBy      bigint      NULL,

        CONSTRAINT PK_t_app_teacher_skills PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_t_app_teacher_skills_t_app_teachers
            FOREIGN KEY (TeacherId) REFERENCES dbo.t_app_teachers (TeacherId),
        CONSTRAINT CK_t_app_teacher_skills_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_app_teacher_skills_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [t_app_teacher_skills] already exists — skipped.';
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
               WHERE name = 'UQ_t_app_teacher_skills_TeacherId_SkillId'
                 AND object_id = OBJECT_ID('dbo.t_app_teacher_skills'))
BEGIN
    PRINT '    Creating index [UQ_t_app_teacher_skills_TeacherId_SkillId] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_app_teacher_skills_TeacherId_SkillId
        ON dbo.t_app_teacher_skills (TeacherId, SkillId)
        WHERE Is_Deleted = 0;
END
GO
/*------------------------------------------------------------------------------
  Read the other way when a school filters on a specific skill.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_teacher_skills_SkillId'
                 AND object_id = OBJECT_ID('dbo.t_app_teacher_skills'))
BEGIN
    PRINT '    Creating index [IX_t_app_teacher_skills_SkillId] ...';

    CREATE NONCLUSTERED INDEX IX_t_app_teacher_skills_SkillId
        ON dbo.t_app_teacher_skills (SkillId)
        INCLUDE (TeacherId)
        WHERE Is_Deleted = 0;
END
GO
