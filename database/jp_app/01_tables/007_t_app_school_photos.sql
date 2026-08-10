/*==============================================================================
  jp_app — 007_t_app_school_photos.sql

  Photos of a school, or of one of its campuses.

  BranchId is NULLABLE and that is the whole design: a photo of the school as a
  whole (the crest, the main building) belongs to no single campus, and forcing
  it onto one would make it disappear when that campus is closed.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

-- Filtered indexes REQUIRE these, both to CREATE them and for any later
-- INSERT/UPDATE on the table (decision 2.29).
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_app_school_photos' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_app_school_photos] ...';

    CREATE TABLE dbo.t_app_school_photos
    (
        PhotoId         bigint          IDENTITY(1,1) NOT NULL,
        SchoolId        bigint          NOT NULL,

        -- NULL = a photo of the school itself rather than of one campus.
        BranchId        bigint          NULL,

        /*
          The storage path, which is a GENERATED name (2.48) — never the
          client's filename. Nothing here is served statically; the file is
          reached through an access-checked endpoint.
        */
        FilePath        nvarchar(500)   NOT NULL,

        Caption         nvarchar(250)   NULL,
        DisplayOrder    int             NOT NULL CONSTRAINT DF_t_app_school_photos_DisplayOrder DEFAULT (0),

        -- ---- standard columns -------------------------------------------------
        Is_Active       tinyint         NOT NULL CONSTRAINT DF_t_app_school_photos_Is_Active  DEFAULT (1),
        Is_Deleted      tinyint         NOT NULL CONSTRAINT DF_t_app_school_photos_Is_Deleted DEFAULT (0),
        CreatedOn       datetime2       NOT NULL CONSTRAINT DF_t_app_school_photos_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy       bigint          NULL,
        ModifiedOn      datetime2       NULL,
        ModifiedBy      bigint          NULL,

        CONSTRAINT PK_t_app_school_photos PRIMARY KEY CLUSTERED (PhotoId),
        CONSTRAINT FK_t_app_school_photos_t_app_schools
            FOREIGN KEY (SchoolId) REFERENCES dbo.t_app_schools (SchoolId),
        CONSTRAINT FK_t_app_school_photos_t_app_school_branches
            FOREIGN KEY (BranchId) REFERENCES dbo.t_app_school_branches (BranchId),
        CONSTRAINT CK_t_app_school_photos_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_app_school_photos_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [t_app_school_photos] already exists — skipped.';
END
GO
/*------------------------------------------------------------------------------
  🔴 ONE ROW PER STORED FILE.

  There is no natural business key here — the same building photographed twice
  is two legitimate rows, and two rows may share a caption.

  But the FILE is different. Storage names are generated GUIDs, so two rows
  pointing at one path cannot happen by a school uploading similar pictures; it
  can only happen by the same upload being recorded twice, which is the
  double-clicked-save case. And it matters more than a duplicate row: deleting
  one of the two photos would delete the file the other still points at.

  So the key is the path, filtered so a re-upload after a delete is allowed.

  🔴 Guarded separately from the table (decision 2.29).
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_app_school_photos_FilePath' AND object_id = OBJECT_ID('dbo.t_app_school_photos'))
BEGIN
    PRINT '    Creating index [UQ_t_app_school_photos_FilePath] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_app_school_photos_FilePath
        ON dbo.t_app_school_photos (FilePath)
        WHERE Is_Deleted = 0;
END
GO
/*------------------------------------------------------------------------------
  The gallery, in the order the school arranged it.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_school_photos_SchoolId' AND object_id = OBJECT_ID('dbo.t_app_school_photos'))
BEGIN
    PRINT '    Creating index [IX_t_app_school_photos_SchoolId] ...';

    CREATE NONCLUSTERED INDEX IX_t_app_school_photos_SchoolId
        ON dbo.t_app_school_photos (SchoolId, DisplayOrder)
        INCLUDE (BranchId, FilePath, Caption)
        WHERE Is_Deleted = 0;
END
GO
/*------------------------------------------------------------------------------
  Every FK column gets an index. BranchId is filtered to the rows that have one,
  because most photos belong to the school rather than a campus.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_school_photos_BranchId' AND object_id = OBJECT_ID('dbo.t_app_school_photos'))
BEGIN
    PRINT '    Creating index [IX_t_app_school_photos_BranchId] ...';

    CREATE NONCLUSTERED INDEX IX_t_app_school_photos_BranchId
        ON dbo.t_app_school_photos (BranchId, DisplayOrder)
        WHERE BranchId IS NOT NULL AND Is_Deleted = 0;
END
GO
