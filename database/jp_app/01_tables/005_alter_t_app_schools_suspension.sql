/*==============================================================================
  jp_app — 005_alter_t_app_schools_suspension.sql

  The three columns Phase 2D deferred when it pulled t_app_schools forward.

  ⚠️ The CREATE in 001 is NOT edited, and that is the rule rather than a
  preference (Block D of _TEMPLATE_table.sql). Editing it would erase the record
  of what was pulled forward and what was left behind — which is the only thing
  that makes a pull-forward reviewable six months later.

  ---------------------------------------------------------------------------
  WHAT THIS ADDS, AGAINST THE SPEC
  ---------------------------------------------------------------------------
      IsSuspended       an admin has paused this school
      SuspendedOn       when
      SuspensionReason  why, in words the school will be shown

  Everything else in the spec's t_app_schools row is already present. PanNumber
  is on the table and NOT in the spec — Phase 2F added it deliberately (2.50).

  ---------------------------------------------------------------------------
  ⚠️ SUSPENSION IS NOT DELETION AND NOT REJECTION
  ---------------------------------------------------------------------------
  Is_Deleted is the tombstone. Is_Active is whether the row is usable in
  ordinary operation. IsSuspended is a DECISION somebody made about the school,
  with a reason attached and a date, and it is the only one of the three a
  school is ever told about.

  Keeping it separate means "suspended" survives a reactivation of Is_Active and
  can be reported on. Folding it into Is_Active would lose the reason, which is
  the only part the school can act on.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.t_app_schools') AND name = 'IsSuspended')
BEGIN
    PRINT '    Adding column [t_app_schools].[IsSuspended] ...';

    -- tinyint with a CHECK, not bit: the same shape as Is_Active / Is_Deleted,
    -- so every boolean in this database reads and indexes the same way.
    ALTER TABLE dbo.t_app_schools
        ADD IsSuspended tinyint NOT NULL
            CONSTRAINT DF_t_app_schools_IsSuspended DEFAULT (0);
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
               WHERE name = 'CK_t_app_schools_IsSuspended')
BEGIN
    PRINT '    Adding constraint [CK_t_app_schools_IsSuspended] ...';

    ALTER TABLE dbo.t_app_schools
        ADD CONSTRAINT CK_t_app_schools_IsSuspended CHECK (IsSuspended IN (0, 1));
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.t_app_schools') AND name = 'SuspendedOn')
BEGIN
    PRINT '    Adding column [t_app_schools].[SuspendedOn] ...';

    -- An event timestamp, so UTC datetime2 (decision 2.28). "When was this
    -- school suspended" is an instant, not a calendar day.
    ALTER TABLE dbo.t_app_schools ADD SuspendedOn datetime2 NULL;
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.t_app_schools') AND name = 'SuspensionReason')
BEGIN
    PRINT '    Adding column [t_app_schools].[SuspensionReason] ...';

    /*
      Free text, and deliberately not a reason master.

      A suspension is a judgement about one school. A dropdown of reasons would
      be read as a taxonomy somebody has to fit the situation into, and the part
      that matters to the school — what specifically happened and what would
      lift it — is exactly the part a code cannot carry.
    */
    ALTER TABLE dbo.t_app_schools ADD SuspensionReason nvarchar(500) NULL;
END
GO
/*------------------------------------------------------------------------------
  Suspended schools, for the admin screen that lists them.

  Filtered to the suspended ones only: they are a handful out of everything, and
  an unfiltered index on a column that is 0 for almost every row is an index the
  optimiser ignores and the writer still pays for.

  🔴 Guarded separately from the column (decision 2.29).
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_schools_IsSuspended' AND object_id = OBJECT_ID('dbo.t_app_schools'))
BEGIN
    PRINT '    Creating index [IX_t_app_schools_IsSuspended] ...';

    CREATE NONCLUSTERED INDEX IX_t_app_schools_IsSuspended
        ON dbo.t_app_schools (SuspendedOn DESC)
        INCLUDE (SchoolName, OrganizationUid, SuspensionReason)
        WHERE IsSuspended = 1 AND Is_Deleted = 0;
END
GO
