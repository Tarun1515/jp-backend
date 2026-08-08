/*==============================================================================
  _TEMPLATE_table.sql — CANONICAL TABLE TEMPLATE

  Every one of the 87 tables is cut from this file. Do not invent a new shape.
  Copy the relevant block, rename, fill in the business columns, delete the rest.

  This file is a reference only — it is NOT included by run_all.sql and never
  executes.

  ----------------------------------------------------------------------------
  TARGET: SQL SERVER 2019 (15.0)
  ----------------------------------------------------------------------------
  Databases are pinned to COMPATIBILITY_LEVEL 150. Do not use 2022+ syntax:
      GREATEST / LEAST            DATETRUNC / DATE_BUCKET
      IS [NOT] DISTINCT FROM      GENERATE_SERIES
      JSON_OBJECT / JSON_ARRAY    JSON_PATH_EXISTS
      STRING_SPLIT(..., ordinal)  TRIM(chars FROM x) / LTRIM(x, chars)
      APPROX_PERCENTILE_*         WINDOW clause
  These ARE available and fine to use:
      STRING_AGG (2017)  TRIM(x) (2017)  CONCAT_WS (2017)  TRANSLATE (2017)
      OPENJSON / JSON_VALUE / FOR JSON (2016)  OFFSET-FETCH (2012)

  ----------------------------------------------------------------------------
  NAMING RULES
  ----------------------------------------------------------------------------
  Table      m_<db>_<name>  master        t_<db>_<name>  transactional
             all lowercase, singular-ish, e.g. m_sso_user_types, t_app_jobs
  Columns    PascalCase, e.g. UserId, OrganizationUid
             EXCEPT the two standard flags, which keep their underscore form:
             Is_Active, Is_Deleted
  PK         PK_<table>
  FK         FK_<table>_<referenced_table>          (+ _<col> if ambiguous)
  Unique     UQ_<table>_<col1>_<col2>
  Check      CK_<table>_<meaning>
  Default    DF_<table>_<col>
  Index      IX_<table>_<col1>_<col2>               (+ _Inc if it has INCLUDE)

  ----------------------------------------------------------------------------
  HARD RULES
  ----------------------------------------------------------------------------
  * Soft delete only. Nothing ever issues a DELETE. Is_Deleted = 1 is the tombstone.
  * No physical FK crosses a database boundary. Cross-DB links are
    uniqueidentifier Uid columns, validated inside stored procedures.
  * Every FK column gets a non-clustered index (see 02_indexes).
  * Unique indexes on business keys are ALWAYS filtered WHERE Is_Deleted = 0,
    otherwise a soft-deleted row permanently blocks reuse of its key.
  * Do not oversize nvarchar. Email 150, Name 150, Code 30, Mobile 15, Pincode 10.
  * RowVersion (int) goes on header/aggregate-root tables only, for optimistic
    concurrency. It is NOT the SQL Server rowversion/timestamp type — it is a
    plain int the update proc increments and checks.
==============================================================================*/


/*==============================================================================
  BLOCK A — MASTER TABLE  (m_<db>_<name>)

  Masters carry Code / Name / DisplayOrder on top of the standard columns.
  IDs are seeded explicitly and are referenced by enums in JP.Core, so they are
  contract — never renumber a master row once seeded.
==============================================================================*/
USE jp_sso;   -- <-- set to the owning database
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'm_sso_example' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [m_sso_example] ...';

    CREATE TABLE dbo.m_sso_example
    (
        ExampleId       int             NOT NULL,   -- masters: no IDENTITY, IDs are contract
        Code            varchar(30)     NOT NULL,
        Name            nvarchar(150)   NOT NULL,
        DisplayOrder    int             NOT NULL CONSTRAINT DF_m_sso_example_DisplayOrder DEFAULT (0),

        -- ---- standard columns (every table) ----------------------------------
        Is_Active       tinyint         NOT NULL CONSTRAINT DF_m_sso_example_Is_Active  DEFAULT (1),
        Is_Deleted      tinyint         NOT NULL CONSTRAINT DF_m_sso_example_Is_Deleted DEFAULT (0),
        CreatedOn       datetime2       NOT NULL CONSTRAINT DF_m_sso_example_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy       bigint          NULL,
        ModifiedOn      datetime2       NULL,
        ModifiedBy      bigint          NULL,

        CONSTRAINT PK_m_sso_example PRIMARY KEY CLUSTERED (ExampleId),
        CONSTRAINT CK_m_sso_example_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_m_sso_example_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );

    -- Code is the stable lookup key used by seed scripts and procs.
    CREATE UNIQUE NONCLUSTERED INDEX UQ_m_sso_example_Code
        ON dbo.m_sso_example (Code)
        WHERE Is_Deleted = 0;
END
ELSE
BEGIN
    PRINT '    Table [m_sso_example] already exists — skipped.';
END
GO


/*==============================================================================
  BLOCK B — TRANSACTIONAL HEADER TABLE  (t_<db>_<name>)

  Header = aggregate root. Gets IDENTITY, a public-facing Uid, and RowVersion.
  Never expose the bigint PK in a URL or API payload — expose the Uid.
==============================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_sso_example' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_sso_example] ...';

    CREATE TABLE dbo.t_sso_example
    (
        ExampleId       bigint              IDENTITY(1,1) NOT NULL,
        ExampleUid      uniqueidentifier    NOT NULL CONSTRAINT DF_t_sso_example_ExampleUid DEFAULT (NEWID()),

        -- ---- business columns -------------------------------------------------
        ExampleTypeId   int                 NOT NULL,           -- FK to a master
        Title           nvarchar(150)       NOT NULL,
        Email           nvarchar(150)       NULL,
        Mobile          varchar(15)         NULL,

        -- Cross-database reference. Uid only — NEVER a physical FK.
        -- Validated in the stored procedure with IF NOT EXISTS ... THROW.
        OrganizationUid uniqueidentifier    NULL,

        -- ---- standard columns -------------------------------------------------
        Is_Active       tinyint             NOT NULL CONSTRAINT DF_t_sso_example_Is_Active   DEFAULT (1),
        Is_Deleted      tinyint             NOT NULL CONSTRAINT DF_t_sso_example_Is_Deleted  DEFAULT (0),
        CreatedOn       datetime2           NOT NULL CONSTRAINT DF_t_sso_example_CreatedOn   DEFAULT (SYSUTCDATETIME()),
        CreatedBy       bigint              NULL,
        ModifiedOn      datetime2           NULL,
        ModifiedBy      bigint              NULL,
        RowVersion      int                 NOT NULL CONSTRAINT DF_t_sso_example_RowVersion  DEFAULT (1),

        CONSTRAINT PK_t_sso_example PRIMARY KEY CLUSTERED (ExampleId),
        CONSTRAINT FK_t_sso_example_m_sso_example
            FOREIGN KEY (ExampleTypeId) REFERENCES dbo.m_sso_example (ExampleId),
        CONSTRAINT CK_t_sso_example_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_sso_example_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );

    -- The public identifier. Unfiltered: a Uid must never be reused, even after
    -- a soft delete, or an old URL would resolve to a different row.
    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_sso_example_ExampleUid
        ON dbo.t_sso_example (ExampleUid);

    -- Business keys ARE filtered, so a soft-deleted row frees its email again.
    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_sso_example_Email
        ON dbo.t_sso_example (Email)
        WHERE Is_Deleted = 0 AND Email IS NOT NULL;
END
ELSE
BEGIN
    PRINT '    Table [t_sso_example] already exists — skipped.';
END
GO


/*==============================================================================
  BLOCK C — BRIDGE / CHILD TABLE

  Many-to-many is ALWAYS a bridge table. Never a comma-separated column.
  Child rows get no Uid and no RowVersion — the parent header owns both.
==============================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_sso_example_items' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_sso_example_items] ...';

    CREATE TABLE dbo.t_sso_example_items
    (
        Id              bigint      IDENTITY(1,1) NOT NULL,
        ExampleId       bigint      NOT NULL,
        ItemId          int         NOT NULL,

        Is_Active       tinyint     NOT NULL CONSTRAINT DF_t_sso_example_items_Is_Active  DEFAULT (1),
        Is_Deleted      tinyint     NOT NULL CONSTRAINT DF_t_sso_example_items_Is_Deleted DEFAULT (0),
        CreatedOn       datetime2   NOT NULL CONSTRAINT DF_t_sso_example_items_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy       bigint      NULL,
        ModifiedOn      datetime2   NULL,
        ModifiedBy      bigint      NULL,

        CONSTRAINT PK_t_sso_example_items PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_t_sso_example_items_t_sso_example
            FOREIGN KEY (ExampleId) REFERENCES dbo.t_sso_example (ExampleId),
        CONSTRAINT CK_t_sso_example_items_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_sso_example_items_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );

    -- Stops the same item being attached twice while still allowing re-add
    -- after a soft delete.
    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_sso_example_items_ExampleId_ItemId
        ON dbo.t_sso_example_items (ExampleId, ItemId)
        WHERE Is_Deleted = 0;
END
ELSE
BEGIN
    PRINT '    Table [t_sso_example_items] already exists — skipped.';
END
GO


/*==============================================================================
  BLOCK D — ADDING A COLUMN TO AN EXISTING TABLE

  Tables already deployed are never edited in place. Add a new numbered script
  in 01_tables/ using this guard, so run_all.sql stays replayable from scratch
  AND applies cleanly to an existing database.
==============================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.t_sso_example') AND name = 'NewColumn')
BEGIN
    PRINT '    Adding column [t_sso_example].[NewColumn] ...';
    ALTER TABLE dbo.t_sso_example
        ADD NewColumn nvarchar(100) NULL;
END
GO


/*==============================================================================
  BLOCK E — INDEX SCRIPT PATTERN  (goes in 02_indexes/)

  One index per FK column, plus the columns that get filtered on constantly:
  StatusId, UserTypeId, OrganizationUid, IsCurrent, ExpiresOn.
==============================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_sso_example_ExampleTypeId' AND object_id = OBJECT_ID('dbo.t_sso_example'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_t_sso_example_ExampleTypeId
        ON dbo.t_sso_example (ExampleTypeId)
        WHERE Is_Deleted = 0;
END
GO


/*==============================================================================
  BLOCK F — SEED SCRIPT PATTERN  (goes in 03_seed/)

  Re-runnable. MERGE for masters so a changed Name is corrected on re-run,
  while never touching rows an admin has deliberately deactivated.
  Do NOT let MERGE delete unmatched target rows — soft delete only.
==============================================================================*/
MERGE dbo.m_sso_example AS tgt
USING (VALUES
        (1, 'ALPHA', N'Alpha', 1),
        (2, 'BETA',  N'Beta',  2),
        (3, 'GAMMA', N'Gamma', 3)
      ) AS src (ExampleId, Code, Name, DisplayOrder)
    ON tgt.ExampleId = src.ExampleId
WHEN MATCHED AND (tgt.Code <> src.Code OR tgt.Name <> src.Name OR tgt.DisplayOrder <> src.DisplayOrder)
    THEN UPDATE SET
        tgt.Code         = src.Code,
        tgt.Name         = src.Name,
        tgt.DisplayOrder = src.DisplayOrder,
        tgt.ModifiedOn   = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (ExampleId, Code, Name, DisplayOrder)
         VALUES (src.ExampleId, src.Code, src.Name, src.DisplayOrder);
GO
