/*==============================================================================
  jp_mdm — 032_t_mdm_error_log.sql

  Centralised error log — jp_mdm's OWN copy.

  One per database, deliberately. jp_mdm must stay independently deployable
  (decision 2.1), so it cannot write its errors into a table in jp_sso.
  t_sso_error_log and t_app_error_log are the same shape.

  ---------------------------------------------------------------------------
  WRITTEN AFTER THE ROLLBACK, NEVER BEFORE
  ---------------------------------------------------------------------------
  An INSERT here from inside the failed transaction is rolled back with it, and
  the error record vanishes at precisely the moment it was needed. Mandatory
  CATCH ordering is decision 2.31: capture -> rollback -> log -> respond.

  ---------------------------------------------------------------------------
  ParametersJson MUST NEVER CONTAIN A SECRET
  ---------------------------------------------------------------------------
  It exists so a failure can be reproduced — never for a token, a hash or an
  OTP. A log is where secrets survive longest and are read by the most people.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_mdm_error_log' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_mdm_error_log] ...';

    CREATE TABLE dbo.t_mdm_error_log
    (
        ErrorLogId          bigint            IDENTITY(1,1) NOT NULL,

        ErrorNumber         int               NOT NULL,
        ErrorSeverity       int               NULL,
        ErrorState          int               NULL,
        ErrorProcedure      sysname           NULL,
        ErrorLine           int               NULL,
        ErrorMessage        nvarchar(4000)    NOT NULL,

        UserName            sysname           NOT NULL CONSTRAINT DF_t_mdm_error_log_UserName DEFAULT (SUSER_SNAME()),
        HostName            sysname           NULL,
        AppName             nvarchar(128)     NULL,

        ParametersJson      nvarchar(max)     NULL,
        ContextInfo         nvarchar(500)     NULL,

        OccurredOn          datetime2         NOT NULL CONSTRAINT DF_t_mdm_error_log_OccurredOn DEFAULT (SYSUTCDATETIME()),

        Is_Active           tinyint           NOT NULL CONSTRAINT DF_t_mdm_error_log_Is_Active  DEFAULT (1),
        Is_Deleted          tinyint           NOT NULL CONSTRAINT DF_t_mdm_error_log_Is_Deleted DEFAULT (0),
        CreatedOn           datetime2         NOT NULL CONSTRAINT DF_t_mdm_error_log_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy           bigint            NULL,
        ModifiedOn          datetime2         NULL,
        ModifiedBy          bigint            NULL,

        CONSTRAINT PK_t_mdm_error_log PRIMARY KEY CLUSTERED (ErrorLogId),
        CONSTRAINT CK_t_mdm_error_log_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_mdm_error_log_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [t_mdm_error_log] already exists — skipped.';
END
GO
/*------------------------------------------------------------------------------
  "What broke in the last hour" — the first question anyone asks. DESC because
  nobody reads an error log forwards from the beginning.

  🔴 Guarded separately from the table (decision 2.29).
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_mdm_error_log_OccurredOn' AND object_id = OBJECT_ID('dbo.t_mdm_error_log'))
BEGIN
    PRINT '    Creating index [IX_t_mdm_error_log_OccurredOn] ...';

    CREATE NONCLUSTERED INDEX IX_t_mdm_error_log_OccurredOn
        ON dbo.t_mdm_error_log (OccurredOn DESC)
        INCLUDE (ErrorNumber, ErrorProcedure, ErrorMessage);
END
GO
/*------------------------------------------------------------------------------
  "Is this one procedure failing repeatedly?" — the second question.

  🔴 Guarded separately from the table (decision 2.29).
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_mdm_error_log_ErrorProcedure' AND object_id = OBJECT_ID('dbo.t_mdm_error_log'))
BEGIN
    PRINT '    Creating index [IX_t_mdm_error_log_ErrorProcedure] ...';

    CREATE NONCLUSTERED INDEX IX_t_mdm_error_log_ErrorProcedure
        ON dbo.t_mdm_error_log (ErrorProcedure, OccurredOn DESC)
        INCLUDE (ErrorNumber, ErrorMessage)
        WHERE ErrorProcedure IS NOT NULL;
END
GO
