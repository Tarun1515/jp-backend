/*==============================================================================
  jp_app — 020_t_app_error_log.sql

  Centralised error log.

  One per database, deliberately. jp_app must stay independently deployable
  (PROJECT_MEMORY 2.1), so it cannot write its errors into a table that lives
  in jp_mdm. t_mdm_error_log and t_app_error_log are the same shape.

  ---------------------------------------------------------------------------
  WHY THIS TABLE IS WRITTEN AFTER THE ROLLBACK, NEVER BEFORE
  ---------------------------------------------------------------------------
  An INSERT into this table from inside the failed transaction is rolled back
  with everything else. The error record vanishes at precisely the moment it
  was needed. See decision 2.31 and database/_TEMPLATE_procedure.sql for the
  mandatory CATCH ordering.

  ---------------------------------------------------------------------------
  ParametersJson MUST NEVER CONTAIN A SECRET
  ---------------------------------------------------------------------------
  This column exists so a failure can be reproduced. It must never carry a
  password hash, a salt, a token hash, or an OTP. Every calling procedure masks
  those explicitly before building the JSON. A log is exactly the place secrets
  survive longest and get read by the most people.
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_app_error_log' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_app_error_log] ...';

    CREATE TABLE dbo.t_app_error_log
    (
        ErrorLogId      bigint          IDENTITY(1,1) NOT NULL,

        -- Straight from the ERROR_* functions, captured inside the CATCH block.
        ErrorNumber     int             NOT NULL,
        ErrorSeverity   int             NULL,
        ErrorState      int             NULL,
        ErrorProcedure  sysname         NULL,   -- NULL for ad-hoc batches
        ErrorLine       int             NULL,
        ErrorMessage    nvarchar(4000)  NOT NULL,

        -- Who and where. All three are session facts, so they survive the
        -- rollback and cost nothing to capture.
        UserName        sysname         NOT NULL CONSTRAINT DF_t_app_error_log_UserName DEFAULT (SUSER_SNAME()),
        HostName        sysname         NULL,
        AppName         nvarchar(128)   NULL,

        -- Masked input parameters, for reproduction. NEVER secrets.
        ParametersJson  nvarchar(max)   NULL,

        -- Optional free-text from the caller, e.g. 'approval flow, step 2'.
        ContextInfo     nvarchar(500)   NULL,

        OccurredOn      datetime2       NOT NULL CONSTRAINT DF_t_app_error_log_OccurredOn DEFAULT (SYSUTCDATETIME()),

        -- ---- standard columns (decision 2.4 — no exceptions) ---------------
        Is_Active       tinyint         NOT NULL CONSTRAINT DF_t_app_error_log_Is_Active  DEFAULT (1),
        Is_Deleted      tinyint         NOT NULL CONSTRAINT DF_t_app_error_log_Is_Deleted DEFAULT (0),
        CreatedOn       datetime2       NOT NULL CONSTRAINT DF_t_app_error_log_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy       bigint          NULL,
        ModifiedOn      datetime2       NULL,
        ModifiedBy      bigint          NULL,

        CONSTRAINT PK_t_app_error_log PRIMARY KEY CLUSTERED (ErrorLogId),
        CONSTRAINT CK_t_app_error_log_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_app_error_log_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [t_app_error_log] already exists — skipped.';
END
GO

/*------------------------------------------------------------------------------
  "What broke in the last hour" — the first question anyone asks.
  DESC because nobody reads an error log forwards from the beginning.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_error_log_OccurredOn' AND object_id = OBJECT_ID('dbo.t_app_error_log'))
BEGIN
    PRINT '    Creating index [IX_t_app_error_log_OccurredOn] ...';

    CREATE NONCLUSTERED INDEX IX_t_app_error_log_OccurredOn
        ON dbo.t_app_error_log (OccurredOn DESC)
        INCLUDE (ErrorNumber, ErrorProcedure, ErrorMessage);
END
GO

/*------------------------------------------------------------------------------
  "Is this one procedure failing repeatedly?" — the second question.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_error_log_ErrorProcedure' AND object_id = OBJECT_ID('dbo.t_app_error_log'))
BEGIN
    PRINT '    Creating index [IX_t_app_error_log_ErrorProcedure] ...';

    CREATE NONCLUSTERED INDEX IX_t_app_error_log_ErrorProcedure
        ON dbo.t_app_error_log (ErrorProcedure, OccurredOn DESC)
        INCLUDE (ErrorNumber, ErrorMessage)
        WHERE ErrorProcedure IS NOT NULL;
END
GO
