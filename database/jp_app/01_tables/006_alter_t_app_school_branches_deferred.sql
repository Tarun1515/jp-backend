/*==============================================================================
  jp_app — 006_alter_t_app_school_branches_deferred.sql

  The columns Phase 2F deferred when it pulled t_app_school_branches forward.

  2F created the table with the minimum a head office needs at provisioning
  time. These are the rest of the spec's columns — the ones a school fills in
  from its dashboard once it is verified, which is Phase 3 work.

  ⚠️ The CREATE in 003 is not edited (Block D). Same reason as 005.

  ---------------------------------------------------------------------------
  WHAT THIS ADDS, AGAINST THE SPEC
  ---------------------------------------------------------------------------
      BranchCode      the school's own reference for the campus
      Latitude        \  map position, for the distance search in Phase 4
      Longitude       /
      ContactPerson   who to ask for at this campus

  ---------------------------------------------------------------------------
  🔴 TWO SPEC COLUMNS ARE ALREADY HERE UNDER DIFFERENT NAMES
  ---------------------------------------------------------------------------
  The spec calls them `Phone` and `Email`. The table has `ContactMobile` and
  `ContactEmail`, created that way in 2F to match t_app_schools, where the same
  two facts already carried those names.

  Nothing is lost — the columns exist and provisioning writes them. The naming
  is the deviation, and it is the consistent one: a reader moving between a
  school and its branch sees the same column names for the same thing rather
  than two conventions in adjacent tables.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.t_app_school_branches') AND name = 'BranchCode')
BEGIN
    PRINT '    Adding column [t_app_school_branches].[BranchCode] ...';

    /*
      The school's own code for the campus, not ours. Deliberately NOT unique:
      it is whatever they already write on their own paperwork, and rejecting a
      duplicate would be this system telling a school its filing is wrong.
    */
    ALTER TABLE dbo.t_app_school_branches ADD BranchCode varchar(30) NULL;
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.t_app_school_branches') AND name = 'Latitude')
BEGIN
    PRINT '    Adding column [t_app_school_branches].[Latitude] ...';

    /*
      decimal(9,6) / decimal(9,6), not float and not the geography type.

      Six decimal places is about 11 cm — far past what a school's pin needs.
      float would make two identical coordinates compare unequal, and geography
      buys spatial indexes this product has no query for yet; Phase 4's "jobs
      near me" is a bounding box on these two columns.
    */
    ALTER TABLE dbo.t_app_school_branches ADD Latitude decimal(9, 6) NULL;
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.t_app_school_branches') AND name = 'Longitude')
BEGIN
    PRINT '    Adding column [t_app_school_branches].[Longitude] ...';

    ALTER TABLE dbo.t_app_school_branches ADD Longitude decimal(9, 6) NULL;
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.t_app_school_branches') AND name = 'ContactPerson')
BEGIN
    PRINT '    Adding column [t_app_school_branches].[ContactPerson] ...';

    ALTER TABLE dbo.t_app_school_branches ADD ContactPerson nvarchar(150) NULL;
END
GO
/*------------------------------------------------------------------------------
  Branches that have a map position, for the distance search Phase 4 adds.

  Filtered on both columns being present: a branch with no coordinates cannot
  answer a distance question, and including those rows would make the index
  mostly NULLs the query has to skip anyway.

  🔴 Guarded separately from the columns (decision 2.29).
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_school_branches_LatLong' AND object_id = OBJECT_ID('dbo.t_app_school_branches'))
BEGIN
    PRINT '    Creating index [IX_t_app_school_branches_LatLong] ...';

    CREATE NONCLUSTERED INDEX IX_t_app_school_branches_LatLong
        ON dbo.t_app_school_branches (Latitude, Longitude)
        INCLUDE (SchoolId, BranchName, CityId, StateId)
        WHERE Latitude IS NOT NULL AND Longitude IS NOT NULL AND Is_Deleted = 0;
END
GO
