/*==============================================================================
  jp_mdm — 031_t_mdm_teacher_registration_subjects.sql

  Which subjects a registering teacher teaches — a bridge table.

  Many-to-many is ALWAYS a bridge, never a comma-separated column: a filter for
  "teaches Physics" has to be an index seek, not a LIKE over a string.

  Child row: no Uid and no RowVersion — the request header owns both.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_mdm_teacher_registration_subjects' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_mdm_teacher_registration_subjects] ...';

    CREATE TABLE dbo.t_mdm_teacher_registration_subjects
    (
        Id                  bigint            IDENTITY(1,1) NOT NULL,
        RequestId           bigint            NOT NULL,
        SubjectId           int               NOT NULL,

        Is_Active           tinyint           NOT NULL CONSTRAINT DF_t_mdm_teacher_registration_subjects_Is_Active  DEFAULT (1),
        Is_Deleted          tinyint           NOT NULL CONSTRAINT DF_t_mdm_teacher_registration_subjects_Is_Deleted DEFAULT (0),
        CreatedOn           datetime2         NOT NULL CONSTRAINT DF_t_mdm_teacher_registration_subjects_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy           bigint            NULL,
        ModifiedOn          datetime2         NULL,
        ModifiedBy          bigint            NULL,

        CONSTRAINT PK_t_mdm_teacher_registration_subjects PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_t_mdm_teacher_registration_subjects_t_mdm_approval_requests
            FOREIGN KEY (RequestId) REFERENCES dbo.t_mdm_approval_requests (RequestId),
        CONSTRAINT FK_t_mdm_teacher_registration_subjects_m_mdm_subject
            FOREIGN KEY (SubjectId) REFERENCES dbo.m_mdm_subject (SubjectId),
        CONSTRAINT CK_t_mdm_teacher_registration_subjects_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_mdm_teacher_registration_subjects_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [t_mdm_teacher_registration_subjects] already exists — skipped.';
END
GO
/*------------------------------------------------------------------------------
  A subject cannot be attached twice to one request — which a double-clicked
  submit would otherwise do — while a soft-deleted row still frees it for
  re-adding.

  🔴 Guarded separately from the table (decision 2.29).
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_mdm_teacher_registration_subjects_Request_Subject' AND object_id = OBJECT_ID('dbo.t_mdm_teacher_registration_subjects'))
BEGIN
    PRINT '    Creating index [UQ_t_mdm_teacher_registration_subjects_Request_Subject] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_mdm_teacher_registration_subjects_Request_Subject
        ON dbo.t_mdm_teacher_registration_subjects (RequestId, SubjectId)
        WHERE Is_Deleted = 0;
END
GO
