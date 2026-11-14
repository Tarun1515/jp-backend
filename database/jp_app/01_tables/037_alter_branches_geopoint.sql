/*==============================================================================
  jp_app — 037_alter_branches_geopoint.sql

  SCHOOL REVAMP (SR-2). One PERSISTED computed column of SQL Server's built-in
  `geography` type on t_app_school_branches, and the SPATIAL INDEX over it.

      GeoPoint   geography, PERSISTED, derived from Latitude/Longitude

  ---------------------------------------------------------------------------
  🔴 WHY NOW, WHEN NOTHING READS IT YET
  ---------------------------------------------------------------------------
  Both halves of this file get more expensive the longer they are left:

    1. A computed column added later has to be BACKFILLED — PERSISTED means
       SQL Server writes the value for every existing row at ALTER time. Doing
       that on a table with a few dozen campuses is free. Doing it on a
       populated production table is a size-of-data write under a schema lock.

    2. A spatial index built on a populated table is a far bigger operation
       than one built on an almost-empty one, for the same reason, and it is
       the half that cannot be done online in this edition.

  ⚠️ 006_alter_t_app_school_branches_deferred.sql, which created Latitude and
  Longitude in 3C, says the opposite in its own comment: "geography buys
  spatial indexes this product has no query for yet; Phase 4's jobs near me is
  a bounding box on these two columns." That was true when it was written and
  is not any more. SR-2's distance guard (028_branch_pin_review.sql) is the
  first real consumer, and nearby-search is why the INDEX exists rather than
  only the column. The old comment is left where it is — it records what was
  known then — and this file is the record of the change.

  ⚠️ AND THE HONEST LIMIT, STATED: the distance guard reads each campus against
  ITS OWN anchor, one row at a time, so it uses the COLUMN (no per-row re-parse
  of two decimals into a geography) and NOT the index. A spatial index answers
  "which campuses are near THIS point" — the nearby-search this column was
  added for. Nothing in this pass issues that query yet. The index is here
  because of cost (2) above, not because 028 needs it.

  ---------------------------------------------------------------------------
  🔴 geography::Point TAKES LATITUDE FIRST. THE OPPOSITE OF EVERYTHING ELSE.
  ---------------------------------------------------------------------------
      geography::Point( LATITUDE, LONGITUDE, SRID )     <-- what we want
      geometry::Point ( X,        Y,         SRID )     <-- x is LONGITUDE
      GeoJSON / Google / most APIs                      <-- [lng, lat]

  Getting it backwards does not fail. It produces a point in the wrong
  hemisphere that computes distances perfectly happily — Hisar at
  (29.15, 75.72) becomes (75.72, 29.15), which is a spot in the Kara Sea, and
  every distance from it is a plausible-looking large number rather than an
  error. A review queue fed by a reversed point would flag every campus in
  India at once, and the figure it showed would be arithmetically correct.

  So the column names its arguments in the expression below, and the guard at
  the foot of this file re-derives a known point and asserts the latitude comes
  back out of .Lat rather than .Long.

  ---------------------------------------------------------------------------
  ⚠️ PERSISTED, AND WHAT THAT REQUIRED — MEASURED AGAINST THE RULES, NOT HOPED
  ---------------------------------------------------------------------------
  SQL Server will persist a computed column only if the expression is
  DETERMINISTIC. It does NOT require the expression to be PRECISE — precision
  is the rule for INDEXING an unpersisted computed column, and PERSISTED is
  exactly the mechanism that rescues a deterministic-but-imprecise expression
  for indexing.

  Against this expression:

    DETERMINISTIC   yes. geography::Point is a deterministic system method,
                    CAST is deterministic, CASE is deterministic, and the SRID
                    is a literal. Nothing reads the clock, the connection or a
                    non-deterministic built-in.

    PRECISE         NO — and that is the interesting half. Latitude and
                    Longitude are decimal(9,6); geography::Point takes float.
                    Any expression involving float is IMPRECISE by SQL Server's
                    definition, so this column could never be indexed unpersisted.
                    PERSISTED is therefore not an optimisation here. It is the
                    thing that makes the spatial index below legal at all.

  🔴 AND THE NULLABILITY, STATED EXACTLY, because the brief expected otherwise:
  this column IS NULLABLE and it stays that way. A SQL Server spatial index
  tolerates NULL in the indexed column — NULLs are simply not indexed — so
  nothing had to be made NOT NULL and no row had to be given an invented
  coordinate. What a spatial index DOES require, and what was checked:

      a PRIMARY KEY, and it must be CLUSTERED   PK_t_app_school_branches
                                                PRIMARY KEY CLUSTERED (BranchId)
                                                — present since 2F. ✔
      the column is geometry or geography       geography. ✔
      a computed column must be PERSISTED       it is. ✔
      no WHERE clause                           spatial indexes cannot be
                                                filtered, so the "only rows
                                                with coordinates" trick that
                                                IX_..._LatLong uses (006) is
                                                not available here. The NULL
                                                rows are simply not indexed,
                                                which is the same outcome by a
                                                different route. ✔

  ⚠️ NO BOUNDING_BOX. That parameter is geometry-only; a geography index is
  tessellated over the whole globe and the default scheme is
  GEOGRAPHY_AUTO_GRID. It is left at the default deliberately — tuning a grid
  for a table with no spatial query in it yet would be a number chosen against
  nothing.

  ---------------------------------------------------------------------------
  🔴 THE SEVEN SET OPTIONS, AND WHY THEY ARE NOT DECORATION
  ---------------------------------------------------------------------------
  A table carrying an INDEX ON A COMPUTED COLUMN is subject to the same SET
  requirements as an indexed view — ANSI_NULLS, ANSI_PADDING, ANSI_WARNINGS,
  ARITHABORT and QUOTED_IDENTIFIER ON, CONCAT_NULL_YIELDS_NULL ON and
  NUMERIC_ROUNDABORT OFF — both to CREATE the index AND for every later
  INSERT/UPDATE/DELETE on the table. This is the same trap 003 records for
  filtered indexes (2.29), one notch sharper: get it wrong and a school SAVING
  A CAMPUS fails, which reads as a save bug rather than a session setting.

  They are set below for this script. For the APIs: Microsoft.Data.SqlClient
  sets ANSI_NULLS, ANSI_PADDING, ANSI_WARNINGS, CONCAT_NULL_YIELDS_NULL and
  QUOTED_IDENTIFIER ON by default and leaves NUMERIC_ROUNDABORT OFF, and
  ANSI_WARNINGS ON supplies the ARITHABORT behaviour — which is why indexed
  views have always worked from ADO.NET. Nothing in DbConnectionFactory
  overrides any of them.

  Target: SQL Server 2019 (15.0), compat 150.
==============================================================================*/

USE jp_app;
GO

/*
  🔴 ALL SEVEN. Not the two 003 needs for its filtered indexes — see this
  file's header. ARITHABORT and NUMERIC_ROUNDABORT are the two that are NOT
  already set by the rest of this build, and the two whose absence produces a
  failure at INSERT time rather than at CREATE time.
*/
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
GO

/*------------------------------------------------------------------------------
  The column.

  🔴 THE EXPRESSION, ARGUMENT BY ARGUMENT — read this before changing it:

      geography::Point( Latitude, Longitude, 4326 )
                        ^^^^^^^^  ^^^^^^^^^  ^^^^
                        LAT 1st   LONG 2nd   WGS 84

  4326 is WGS 84 — the SRID every consumer coordinate is already in (Google
  Places, a phone's GPS, a map pin). It is a literal rather than a lookup so
  the column cannot silently change meaning.

  ⚠️ CAST(... AS float) IS EXPLICIT, AND IT IS WHERE THE PRECISION GOES.
  geography::Point takes float, so decimal -> float happens either way; an
  implicit conversion here would be the same arithmetic with nothing naming it.
  float(53) carries ~15 significant digits and decimal(9,6) needs 9, so no
  stored coordinate loses anything — but the RESULT type is float, which is
  what makes this expression imprecise. See the header.

  ⚠️ THE CASE IS NOT REDUNDANT DEFENSIVENESS. geography::Point does return NULL
  for a NULL argument, so the bare call would behave identically. The CASE
  states the rule in the column definition, where somebody reading
  sys.computed_columns.definition will see it, instead of leaving "what happens
  to a campus with no pin" to a reader's knowledge of CLR null propagation.

  ⚠️ Guarded separately from the index below (2.29).
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.columns
                WHERE object_id = OBJECT_ID('dbo.t_app_school_branches') AND name = 'GeoPoint')
BEGIN
    PRINT '    Adding computed column [t_app_school_branches].[GeoPoint] (PERSISTED geography) ...';

    ALTER TABLE dbo.t_app_school_branches ADD GeoPoint AS
        CASE
            WHEN Latitude IS NULL OR Longitude IS NULL THEN NULL
            ELSE geography::Point(CAST(Latitude AS float), CAST(Longitude AS float), 4326)
        END
        PERSISTED;
END
ELSE
BEGIN
    PRINT '    [t_app_school_branches].[GeoPoint] already present — skipped.';
END
GO

/*------------------------------------------------------------------------------
  🔒 GUARD — PERSISTED IS ASSERTED, NOT ASSUMED.

  ALTER TABLE ... PERSISTED fails outright if the expression is judged
  non-deterministic, so in principle reaching here means it worked. In practice
  the failure mode this catches is the other one: somebody "simplifying" the
  expression later — dropping the CAST, adding a GETDATE()-flavoured term,
  replacing the literal SRID with a lookup — and losing persistence, at which
  point the spatial index below cannot be rebuilt and nobody finds out until a
  from-scratch build.

  Checked before the index, because the index DEPENDS on this being true.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.computed_columns
                WHERE object_id = OBJECT_ID('dbo.t_app_school_branches')
                  AND name = 'GeoPoint'
                  AND is_persisted = 1)
    RAISERROR('037: [t_app_school_branches].[GeoPoint] exists but is NOT PERSISTED. A spatial index cannot be built on an unpersisted computed column, and this expression can never qualify unpersisted because decimal -> float makes it IMPRECISE. See this file''s header: PERSISTED is what makes the index legal, not an optimisation.', 16, 1);
GO

/*------------------------------------------------------------------------------
  The spatial index.

  Named SIX_ rather than IX_ — the prefix this schema has not needed until now,
  and the one that tells a reader at a glance that this is not an index they can
  seek on an equality.

  ⚠️ NO USING clause, NO GRIDS, NO CELLS_PER_OBJECT. The default for a geography
  column is GEOGRAPHY_AUTO_GRID, and tuning a tessellation against a table that
  has no spatial query in it yet would be four numbers chosen against nothing.
  When nearby-search lands, it tunes this with a measured plan.

  ⚠️ NOT filtered, and it cannot be — spatial indexes take no WHERE clause. The
  rows with no coordinates are simply not indexed, which is what 006's filtered
  IX_..._LatLong achieved by hand.

  🔴 IX_t_app_school_branches_LatLong (006) IS DELIBERATELY LEFT IN PLACE. It
  covers (Latitude, Longitude) with SchoolId/BranchName/CityId/StateId INCLUDEd
  and serves bounding-box reads and anything that projects the raw decimals; a
  spatial index serves STDistance/STIntersects. They are not substitutes, and
  dropping the older one on the assumption that this replaces it would turn
  every existing coordinate read into a scan.

  🔴 Guarded separately from the column (2.29).
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'SIX_t_app_school_branches_GeoPoint'
                  AND object_id = OBJECT_ID('dbo.t_app_school_branches'))
BEGIN
    PRINT '    Creating spatial index [SIX_t_app_school_branches_GeoPoint] ...';

    CREATE SPATIAL INDEX SIX_t_app_school_branches_GeoPoint
        ON dbo.t_app_school_branches (GeoPoint);
END
ELSE
BEGIN
    PRINT '    [SIX_t_app_school_branches_GeoPoint] already exists — skipped.';
END
GO

/*==============================================================================
  BUILD GUARDS
==============================================================================*/

/*
  🔒 GUARD 1 — LATITUDE IS STILL THE FIRST ARGUMENT.

  🔴 THIS IS THE ONE THAT MATTERS. Every other failure in this file is loud;
  this one is silent, plausible and arithmetically consistent. A reversed
  Point() call puts Indian campuses in the Kara Sea and still returns tidy
  distances, so no query errors and no row looks malformed — the review queue
  just flags everything, with numbers that add up.

  Makes the same call the column makes, against a known pair, and asserts the
  latitude comes back out of .Lat. Hisar: 29.150000 N, 75.720000 E. If the
  arguments were swapped, .Lat would be 75.72 — which is also a legal latitude,
  which is exactly why eyes do not catch this.

  ⚠️ Deliberately NOT a read of the stored column: on a fresh build there are
  no branches with coordinates, so a guard that queried the table would pass by
  finding nothing. This one is true on an empty database.

  ⚠️ And deliberately WITHOUT the CASE wrapper — both probe values are present,
  so the CASE would only test SQL Server's ability to evaluate a CASE. What is
  under test here is the argument ORDER of the call inside it.

  Proven to fire: swapping the two CAST arguments in the expression above fails
  this with both numbers named.
*/
DECLARE @lat decimal(9, 6) = 29.150000,
        @lng decimal(9, 6) = 75.720000;

DECLARE @probe geography = geography::Point(CAST(@lat AS float), CAST(@lng AS float), 4326);

IF @probe IS NULL
    RAISERROR('037: the GeoPoint expression returned NULL for a complete coordinate pair. geography::Point(29.15, 75.72, 4326) must produce a point.', 16, 1);
ELSE IF ABS(@probe.Lat - 29.15) > 0.000001 OR ABS(@probe.Long - 75.72) > 0.000001
BEGIN
    DECLARE @swapped nvarchar(1000) =
        N'037: 🔴 geography::Point ARGUMENTS ARE THE WRONG WAY ROUND. '
      + N'Built from latitude 29.150000 / longitude 75.720000, the point reports Lat='
      + CAST(@probe.Lat AS nvarchar(30)) + N' Long=' + CAST(@probe.Long AS nvarchar(30))
      + N'. geography::Point takes LATITUDE FIRST — the opposite of geometry::Point and of '
      + N'GeoJSON/Google [lng, lat]. Reversed, Indian campuses land in the Kara Sea and every '
      + N'distance is a plausible large number rather than an error. See this file''s header.';

    RAISERROR('%s', 16, 1, @swapped);
END
GO

/*
  🔒 GUARD 2 — THE SRID IS 4326, IN THE DEFINITION ITSELF.

  STDistance between two geography instances of DIFFERENT SRIDs returns NULL —
  not an error, NULL. So a column built on 4283 or 0 would make every distance
  in the review queue NULL, every comparison false, and the queue permanently
  empty. An empty review queue looks like good news.

  Read out of sys.computed_columns rather than re-derived, because what matters
  is the SRID in the DEPLOYED definition, not in a probe this script wrote.

  Proven to fire: changing 4326 to 4283 in the expression fails this.
*/
DECLARE @def nvarchar(max) =
    (SELECT cc.definition
       FROM sys.computed_columns cc
      WHERE cc.object_id = OBJECT_ID('dbo.t_app_school_branches')
        AND cc.name = 'GeoPoint');

IF @def IS NULL OR @def NOT LIKE '%4326%'
    RAISERROR('037: [GeoPoint] is not built on SRID 4326. Two geography instances with different SRIDs make STDistance return NULL rather than raise — so the distance guard''s review queue would be silently, permanently empty. 4326 is WGS 84, which is what every coordinate reaching this product already is.', 16, 1);
GO

/*
  🔒 GUARD 3 — THE PIN COLUMNS ARE STILL decimal(9,6).

  The CAST in the expression is written against that shape. 036 already asserts
  it platform-wide for its own reason (the same place must not be stored at two
  precisions); this names the second consequence, which is local to this file:
  widen the scale and the persisted values go stale against the source columns
  until the table is rebuilt.

  Narrow and specific on purpose — 036's guard covers every Latitude/Longitude
  in the database and would fire first. This one exists so that if somebody
  relaxes 036, the dependency THIS file has is still stated somewhere.
*/
IF EXISTS (SELECT 1 FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.t_app_school_branches')
              AND name IN ('Latitude', 'Longitude')
              AND NOT (precision = 9 AND scale = 6))
    RAISERROR('037: [t_app_school_branches].Latitude/Longitude are no longer decimal(9,6). [GeoPoint] CASTs them to float against that shape — see 036''s guard for the platform-wide rule and this file''s header for the local one.', 16, 1);
GO

PRINT '    Branch GeoPoint column and spatial index ready.';
GO
