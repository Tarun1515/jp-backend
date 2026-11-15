/*==============================================================================
  jp_app — 040_alter_preferred_location_tvp.sql

  dbo.PreferredLocationList GAINS TehsilId.

  ---------------------------------------------------------------------------
  🔴 WHY A MIGRATION FILE AND NOT AN EDIT TO 008
  ---------------------------------------------------------------------------
  A TABLE TYPE cannot be ALTERed. It has to be dropped and recreated, and it
  cannot be dropped while a procedure references it — so the order is:

      1. drop USP_SaveTeacherPreferredLocations   (the ONLY dependent, measured)
      2. drop dbo.PreferredLocationList
      3. 008_teacher_bridges.sql recreates BOTH, with TehsilId

  Step 3 is why this file does not recreate anything itself: 008 already owns
  both objects and runs later in run_all.sql. Two files creating one type is how
  they drift.

  ⚠️ ONE DEPENDENT, VERIFIED RATHER THAN ASSUMED:

      SELECT o.name FROM sys.sql_modules m JOIN sys.objects o ...
       WHERE m.definition LIKE '%PreferredLocationList%'
      -> USP_SaveTeacherPreferredLocations

  If that ever grows, this file's guard fails loudly on the DROP TYPE rather
  than silently skipping — which is the behaviour to want.

  ---------------------------------------------------------------------------
  🔴 WHAT THIS CLOSES — A CONTROL THAT ATE WHAT SOMEBODY CHOSE
  ---------------------------------------------------------------------------
  Measured 15 Nov 2026:

      t_app_teacher_preferred_locations   HAS TehsilId (column 12, from 036)
      dbo.PreferredLocationList           CityId, StateId, PreferenceOrder

  The teacher profile rendered a Tehsil/Sub-tehsil picker for any town that had
  tehsils — Haryana, after the 11 November geography seed — accepted the choice,
  reported "Saved", and the value was dropped HERE, at the table-type boundary.
  The column existed and nothing on earth could write to it.

  ⚠️ 008's own comment had predicted exactly this, and that is the lesson worth
  keeping: it warned that the picker "must land in the SAME change as the
  tehsil-by-city master, or the control starts eating a choice." The master
  landed; this hop did not. A comment warning that two changes must land
  together does not make them land together.

  ---------------------------------------------------------------------------
  ⚠️ IDEMPOTENT, AND A NO-OP ONCE DONE
  ---------------------------------------------------------------------------
  Guarded on the COLUMN, not on the type: the type exists either way, so
  `TYPE_ID IS NULL` would skip for ever on a database that already has the old
  shape. That is the trap this guard is written against.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF TYPE_ID(N'dbo.PreferredLocationList') IS NOT NULL
   AND NOT EXISTS (SELECT 1
                   FROM sys.table_types tt
                     JOIN sys.columns c ON c.object_id = tt.type_table_object_id
                   WHERE tt.name = 'PreferredLocationList' AND c.name = 'TehsilId')
BEGIN
    PRINT '    Rebuilding table type [PreferredLocationList] with TehsilId ...';

    /*
      The procedure is dropped, not altered. 008_teacher_bridges.sql recreates
      it with CREATE OR ALTER a few files later in the same run, so the window
      in which it does not exist is inside one scripted run and never inside a
      request.
    */
    IF OBJECT_ID(N'dbo.USP_SaveTeacherPreferredLocations', N'P') IS NOT NULL
        DROP PROCEDURE dbo.USP_SaveTeacherPreferredLocations;

    DROP TYPE dbo.PreferredLocationList;

    PRINT '    Dropped — 008_teacher_bridges.sql recreates both with TehsilId.';
END
ELSE
BEGIN
    PRINT '    Table type [PreferredLocationList] already carries TehsilId — skipped.';
END
GO
