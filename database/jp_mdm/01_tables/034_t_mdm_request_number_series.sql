/*==============================================================================
  jp_mdm — 034_t_mdm_request_number_series.sql

  The counter behind RequestNo — one row per (request type, year).

  ---------------------------------------------------------------------------
  🔴 WHY A COUNTER TABLE AND NOT MAX(...) + 1
  ---------------------------------------------------------------------------
  MAX(RequestNo) + 1 races. Two sessions read the same maximum before either
  inserts, and both produce the same number. It is silent — nothing errors,
  the duplicate simply exists — until two schools quote the same reference to
  support and neither can be found.

  UQ_t_mdm_approval_requests_RequestNo would catch the collision, but as a 2627
  at insert time: an error rather than an answer, on a submission that had
  nothing wrong with it.

  ---------------------------------------------------------------------------
  🔴 WHY NOT A SEQUENCE OBJECT
  ---------------------------------------------------------------------------
  A SEQUENCE is the natural choice and would be simpler — but the numbering
  restarts per YEAR and per REQUEST TYPE. That needs one SEQUENCE per
  combination, created on the fly with dynamic SQL every January, which is
  worse than a row.

  A row also survives a restore and can be read, corrected and audited. A
  SEQUENCE's current value is server state that no backup of the data carries.

  ---------------------------------------------------------------------------
  HOW IT IS USED
  ---------------------------------------------------------------------------
  USP_SubmitApprovalRequest does a single UPDATE ... OUTPUT under UPDLOCK,
  inside the same transaction as the insert. The row lock serialises concurrent
  submissions of the same type in the same year; everything else runs in
  parallel. See that procedure for the exact statement.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_mdm_request_number_series' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_mdm_request_number_series] ...';

    CREATE TABLE dbo.t_mdm_request_number_series
    (
        SeriesId            int               IDENTITY(1,1) NOT NULL,

        RequestTypeId       int               NOT NULL,

        -- The IST year, not the UTC one. A request submitted at 01:00 IST on
        -- 1 January is still 18:30 UTC on 31 December — numbering it into the
        -- previous year would be visible on the very first request of a year
        -- (decision 2.28).
        SeriesYear          smallint          NOT NULL,

        LastNumber          int               NOT NULL CONSTRAINT DF_t_mdm_request_number_series_LastNumber DEFAULT (0),

        Is_Active           tinyint           NOT NULL CONSTRAINT DF_t_mdm_request_number_series_Is_Active  DEFAULT (1),
        Is_Deleted          tinyint           NOT NULL CONSTRAINT DF_t_mdm_request_number_series_Is_Deleted DEFAULT (0),
        CreatedOn           datetime2         NOT NULL CONSTRAINT DF_t_mdm_request_number_series_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy           bigint            NULL,
        ModifiedOn          datetime2         NULL,
        ModifiedBy          bigint            NULL,

        CONSTRAINT PK_t_mdm_request_number_series PRIMARY KEY CLUSTERED (SeriesId),
        CONSTRAINT FK_t_mdm_request_number_series_m_mdm_request_types
            FOREIGN KEY (RequestTypeId) REFERENCES dbo.m_mdm_request_types (RequestTypeId),
        CONSTRAINT CK_t_mdm_request_number_series_LastNumber CHECK (LastNumber >= 0),
        CONSTRAINT CK_t_mdm_request_number_series_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_mdm_request_number_series_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [t_mdm_request_number_series] already exists — skipped.';
END
GO

/*------------------------------------------------------------------------------
  One counter per (type, year) — the whole point of the table.

  ⚠️ UNFILTERED, unlike every other business key here. A counter must never be
  soft-deleted and re-created: a second row for the same year would restart the
  numbering at 1 and hand out references that already exist.

  🔴 Guarded separately from the table (decision 2.29).
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_mdm_request_number_series_Type_Year' AND object_id = OBJECT_ID('dbo.t_mdm_request_number_series'))
BEGIN
    PRINT '    Creating index [UQ_t_mdm_request_number_series_Type_Year] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_mdm_request_number_series_Type_Year
        ON dbo.t_mdm_request_number_series (RequestTypeId, SeriesYear);
END
GO
