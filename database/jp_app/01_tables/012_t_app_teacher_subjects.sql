/*==============================================================================
  jp_app — 012_t_app_teacher_subjects.sql

  Which subjects a teacher can teach.

  This is the single most important filter in the product. A school looking
  for a physics teacher searches this table, so it is also the one whose
  duplicates are most visible: the same teacher appearing twice in one result
  list, which reads as a broken search rather than a broken bridge.

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

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_app_teacher_subjects' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_app_teacher_subjects] ...';

    CREATE TABLE dbo.t_app_teacher_subjects
    (
        Id              bigint      IDENTITY(1,1) NOT NULL,
        TeacherId       bigint      NOT NULL,

        /*
          ⚠️ CROSS-DATABASE — m_mdm_subject in jp_mdm. NO foreign key, and never
          one (decision 2.2). Validated in the procedure; indexed below, because
          an unenforced reference is still one that gets filtered on.

          int, matching m_mdm_subject.SubjectId — verified against the live
          column rather than the spec table.
        */
        SubjectId       int         NOT NULL,

        -- ---- standard columns -------------------------------------------------
        Is_Active       tinyint     NOT NULL CONSTRAINT DF_t_app_teacher_subjects_Is_Active  DEFAULT (1),
        Is_Deleted      tinyint     NOT NULL CONSTRAINT DF_t_app_teacher_subjects_Is_Deleted DEFAULT (0),
        CreatedOn       datetime2   NOT NULL CONSTRAINT DF_t_app_teacher_subjects_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy       bigint      NULL,
        ModifiedOn      datetime2   NULL,
        ModifiedBy      bigint      NULL,

        CONSTRAINT PK_t_app_teacher_subjects PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_t_app_teacher_subjects_t_app_teachers
            FOREIGN KEY (TeacherId) REFERENCES dbo.t_app_teachers (TeacherId),
        CONSTRAINT CK_t_app_teacher_subjects_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_app_teacher_subjects_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [t_app_teacher_subjects] already exists — skipped.';
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
               WHERE name = 'UQ_t_app_teacher_subjects_TeacherId_SubjectId'
                 AND object_id = OBJECT_ID('dbo.t_app_teacher_subjects'))
BEGIN
    PRINT '    Creating index [UQ_t_app_teacher_subjects_TeacherId_SubjectId] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_app_teacher_subjects_TeacherId_SubjectId
        ON dbo.t_app_teacher_subjects (TeacherId, SubjectId)
        WHERE Is_Deleted = 0;
END
GO
/*------------------------------------------------------------------------------
  🔴 The reverse lookup — "who teaches physics" — is the teacher search's
  first move, and it must be an index seek. Without this it is a scan of every
  subject row for every teacher in the system.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_teacher_subjects_SubjectId'
                 AND object_id = OBJECT_ID('dbo.t_app_teacher_subjects'))
BEGIN
    PRINT '    Creating index [IX_t_app_teacher_subjects_SubjectId] ...';

    CREATE NONCLUSTERED INDEX IX_t_app_teacher_subjects_SubjectId
        ON dbo.t_app_teacher_subjects (SubjectId)
        INCLUDE (TeacherId)
        WHERE Is_Deleted = 0;
END
GO
