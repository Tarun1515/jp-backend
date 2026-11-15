/*==============================================================================
  jp_app — 041_alter_teacher_geopoint.sql

  D1 — THE TEACHER'S OWN MAP PIN, SO NEARBY JOBS CAN RANK ON TOP.

      Latitude    decimal(9,6)  NULL
      Longitude   decimal(9,6)  NULL
      GeoPoint    geography, PERSISTED, derived from the two above
      SIX_t_app_teachers_GeoPoint   spatial index over it

  Client instruction: a teacher browsing jobs should see the ones near them
  first. 037 gave a CAMPUS the geography column that makes that measurable from
  the school's side; this is the other end of the same line. Until this file
  there was no point on a teacher anywhere in the schema — the nearest thing was
  CurrentCityId, which is a town, not a place.

  ---------------------------------------------------------------------------
  🔴 WHAT THIS PAIR IS, AND THE THREE THINGS IT IS NOT
  ---------------------------------------------------------------------------
  It is ONE optional point: roughly where the teacher lives or wants to commute
  from. It is the LEFT operand of an STDistance against a campus pin, and it
  exists for ordering a list. Nothing is gated on it and nothing is refused
  because of it.

    1. NOT t_app_teacher_preferred_locations. Those are "states and towns I
       would work in" — a SET of named places, which is a different question
       with a different answer shape. A teacher may have three preferred states
       and one home pin, and neither replaces the other. The PREFERRED tab
       still reads that table and must keep doing so.

    2. NOT the school side's ANCHOR / pin pair (038). A campus has TWO points
       on purpose — where the school says the gate is, and where the stated
       address geocoded to — because the admin review queue is the distance
       BETWEEN them. There is no review queue for a teacher's own home, nobody
       audits where somebody lives, and a second column would be a fact nothing
       reads. 🔒 One pair, and the privacy argument is below.

    3. NOT derived from CurrentCityId, NOT NOW AND NOT EVER AS A FALLBACK. See
       the 🔒 note on city centroids further down — it is the single most
       important decision in this file.

  ---------------------------------------------------------------------------
  🔴 NAMED Latitude / Longitude, NOT CurrentLatitude / CurrentLongitude
  ---------------------------------------------------------------------------
  Every other address column on this table carries the `Current` prefix
  (CurrentStateId, CurrentCityId, CurrentDistrictId, CurrentTehsilId,
  CurrentAreaOrVillage — 039), so the prefix was the obvious choice and was
  rejected deliberately. Two reasons, and the first is mechanical:

    · 036_alter_address_columns.sql carries a PLATFORM-WIDE guard that every
      Latitude and Longitude in jp_app is decimal(9,6), and it matches ON THOSE
      TWO NAMES. 038's header records the consequence of escaping it:
      GeocodedLatitude/GeocodedLongitude fall outside that sweep, so 038 had to
      repeat the precision check by hand. A column called CurrentLatitude would
      be a third copy of the same guard waiting to be forgotten. Named
      Latitude, it is covered for free, forever, by a check that already exists.

    · The `Current` prefix exists on this table to separate the teacher's OWN
      address from the preferred-location rows that sit in a child table. There
      is no second coordinate pair on t_app_teachers and there is not going to
      be one (see point 2 above), so there is nothing here to disambiguate from.

  ⚠️ 036's guard runs EARLIER IN THE BUILD than this file, so on a from-scratch
  pass it checks these two columns on the NEXT build rather than this one. That
  is why the narrow repeat at the foot of this file exists — same shape as
  037's, same reason: the expression below CASTs these two columns against
  decimal(9,6), and this file should fail on its own terms if that stops being
  true rather than waiting for a later run of 036.

  ---------------------------------------------------------------------------
  🔴 EVERY COLUMN NULLABLE, NOTHING BACKFILLED
  ---------------------------------------------------------------------------
  Same rule as 036 and 039, and here it is load-bearing rather than tidy. A
  teacher with no pin is a teacher nobody asked, and NULL says that honestly.

  🔴 AND "NO PIN" HAS TO SURVIVE AS A DISTINCT STATE ALL THE WAY TO THE SCREEN,
  because the whole feature branches on it: with no pin the job list must come
  back in exactly the date order it had before this file existed. If a backfill
  invented a point, every teacher in the product would silently acquire a
  "nearby" ordering computed from a place they never told us about — and there
  would be no way left to tell an invented pin from a real one.

  ⚠️ 0, 0 IS NOT "EMPTY". It is a real latitude and a real longitude, in the
  Gulf of Guinea, about 5,600 km from Hisar. A DEFAULT of zero on either column
  would put every teacher in the Atlantic and sort the job list by how close
  each school is to open water. No defaults, on purpose.

  ---------------------------------------------------------------------------
  🔒 NO CITY-CENTROID GUESSING. THERE IS NO FALLBACK AND THERE MUST NOT BE ONE.
  ---------------------------------------------------------------------------
  m_mdm_city and m_mdm_tehsil both carry Latitude/Longitude (038's header lists
  them: "THE TOWN CENTRE", "THE TEHSIL CENTRE"), so filling a missing teacher
  pin from the centre of their saved town is three lines away and would make the
  feature work for everybody. It is refused, and this is the argument:

    · A town centroid is not where anybody lives. Hisar's centroid is a point in
      a market; a teacher in a village 14 km out would be ranked as though they
      were standing in it, and the jobs that came back "nearest" would be
      nearest to somewhere else.

    · A GUESSED distance is indistinguishable from a measured one once it is a
      number on a card. "~4 km away" computed from a centroid is a sentence the
      product states as fact and cannot support. The teacher has no way to know
      which kind of number they are reading.

    · It would destroy the one honest signal we have. Today, a NULL pin means
      "we do not know where you are" and the product can SAY that and offer the
      map. A centroid fallback converts every unanswered question into a
      confident wrong answer, and the invitation to pin your actual location
      disappears with it.

  So: IF EITHER PIN IS MISSING THERE IS NO DISTANCE AND NO LABEL. The teacher's
  pin missing means the list is in date order, unchanged. The campus pin missing
  means that job sorts after every pinned one and shows no distance at all. Both
  halves are written that way in USP_BrowseJobs and both are asserted over HTTP
  by scripts/verify/nearby-jobs.mjs.

  ---------------------------------------------------------------------------
  🔒 PRIVACY — WHAT THIS POINT IS ALLOWED TO LEAVE THE DATABASE AS
  ---------------------------------------------------------------------------
  A home address to ±11 cm is the most sensitive column on this table. 039
  already refused AddressLine1/2 and Pincode for the teacher on exactly this
  ground: "a school address is published on every job advert, a teacher's home
  address is not".

  🔒 SO THE RULE IS: THE COORDINATES GO TO THE TEACHER WHO OWNS THEM AND TO
  NOBODY ELSE. USP_GetTeacherProfile returns them (it is their own form, read
  through their own UserUid). USP_GetTeacherPublicProfile — the SCHOOL's view —
  does NOT, and must never be "made consistent" with the profile read.
  USP_BrowseJobs reads this column and emits a DISTANCE IN METRES, never the
  point: a rounded scalar from an unknown origin cannot be inverted into a
  home, whereas one latitude and one longitude is somebody's front door.

  ⚠️ TeacherBrowseDto has no coordinate properties, which is the C# half of the
  same line (2.56's shape: a type with nowhere to put a fact cannot leak it).

  ---------------------------------------------------------------------------
  🔴 geography::Point TAKES LATITUDE FIRST. THE OPPOSITE OF EVERYTHING ELSE.
  ---------------------------------------------------------------------------
      geography::Point( LATITUDE, LONGITUDE, SRID )     <-- what we want
      geometry::Point ( X,        Y,         SRID )     <-- x is LONGITUDE
      GeoJSON / Google / Leaflet / most APIs            <-- [lng, lat]

  037 wrote this out at length for the campus column and it applies here
  word for word, so it is not re-argued — only restated, because the failure is
  silent. Reversed, a teacher at Hisar (29.15, 75.72) lands at (75.72, 29.15):
  a spot in the Kara Sea, north of Siberia. Nothing errors. Every job in India
  becomes about 4,500 km away, every distance is arithmetically correct, and the
  "nearest first" ordering becomes a ranking by how far north each school is —
  a plausible-looking list that is wrong for a reason nobody would look for.

  ⚠️ AND IT IS WORSE HERE THAN IT WAS IN 037. The campus side feeds an admin
  review queue, where a reversed point flags every campus at once and somebody
  notices the queue is absurd. This side feeds a SORT ORDER on a teacher's job
  list: a wrong order looks exactly like a right one. The guard at the foot of
  this file is the only thing that would catch it.

  ---------------------------------------------------------------------------
  ⚠️ PERSISTED, AND WHY IT IS REQUIRED RATHER THAN CHOSEN
  ---------------------------------------------------------------------------
  Measured against SQL Server's two rules, exactly as 037 did:

    DETERMINISTIC   yes. geography::Point is a deterministic system method, CAST
                    and CASE are deterministic, the SRID is a literal. Nothing
                    reads the clock, the connection or a non-deterministic
                    built-in. So the column CAN be persisted.

    PRECISE         NO. Latitude/Longitude are decimal(9,6) and
                    geography::Point takes float; any expression involving float
                    is IMPRECISE by SQL Server's definition. Precision is the
                    rule for INDEXING an UNPERSISTED computed column — so this
                    expression could never be indexed unpersisted.

  🔴 PERSISTED is therefore not an optimisation. It is the mechanism that
  rescues a deterministic-but-imprecise expression for indexing, and it is what
  makes the CREATE SPATIAL INDEX below legal at all. Drop the word and the index
  cannot be built; drop the CAST and it still cannot, because decimal -> float
  happens implicitly and the result type is float either way.

  ---------------------------------------------------------------------------
  🔴 THE SEVEN SET OPTIONS — AND THIS TABLE IS WRITTEN FAR MORE OFTEN THAN 037'S
  ---------------------------------------------------------------------------
  A table carrying an INDEX ON A COMPUTED COLUMN is subject to the indexed-view
  SET requirements — ANSI_NULLS, ANSI_PADDING, ANSI_WARNINGS, ARITHABORT and
  QUOTED_IDENTIFIER ON, CONCAT_NULL_YIELDS_NULL ON, NUMERIC_ROUNDABORT OFF —
  not only to CREATE the index but for EVERY LATER INSERT, UPDATE and DELETE on
  the table. They are set below for this script.

  ⚠️ 037 made this argument for t_app_school_branches, where the writers are a
  handful of school-side procedures. t_app_teachers is a busier table:
  USP_ProvisionTeacher inserts into it, USP_UpdateTeacherProfile and
  USP_RecalculateTeacherProfile update it, the verification and suspension
  procedures touch it, and 03_seed\001_backfill_phase3b.sql writes it during the
  build. So the blast radius of a wrong session setting is larger — a teacher
  SIGNING UP would fail, which reads as a registration bug rather than a session
  option.

  Checked rather than hoped, for every writer that exists today:

    Microsoft.Data.SqlClient   sets ANSI_NULLS, ANSI_PADDING, ANSI_WARNINGS,
      (both APIs)              CONCAT_NULL_YIELDS_NULL and QUOTED_IDENTIFIER ON
                               by default and leaves NUMERIC_ROUNDABORT OFF;
                               ANSI_WARNINGS ON supplies the ARITHABORT
                               behaviour. This is why indexed views have always
                               worked from ADO.NET, and nothing in
                               DbConnectionFactory overrides any of them. ✔

    run_all.sql                sets QUOTED_IDENTIFIER ON and ANSI_NULLS ON for
                               the whole session at the top, and this file sets
                               all seven for itself. ✔

    sqlcmd with -I             ODBC turns ANSI_DEFAULTS ON (ANSI_NULLS,
                               ANSI_PADDING, ANSI_WARNINGS), -I supplies
                               QUOTED_IDENTIFIER ON, NUMERIC_ROUNDABORT defaults
                               OFF. ✔

    🔴 sqlcmd WITHOUT -I       QUOTED_IDENTIFIER OFF -> Msg 1934 on any write to
                               this table. Every script in database\ and every
                               suite in scripts\verify passes -I (audited: the
                               only file mentioning sqlcmd without it is
                               build-manifest.mjs, which only names it in a
                               comment). ⚠️ ANY NEW ad-hoc sqlcmd that writes
                               t_app_teachers must pass -I. This is the one new
                               obligation this file creates.

  Target: SQL Server 2019 (15.0), compat 150.
==============================================================================*/

USE jp_app;
GO

/*
  🔴 ALL SEVEN, for the reason 037 gives: ARITHABORT and NUMERIC_ROUNDABORT are
  the two the rest of this build does NOT already set, and the two whose absence
  produces a failure at INSERT time rather than at CREATE time.
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
  1. THE TWO SOURCE COLUMNS.

  decimal(9,6) — the platform shape (036). Six decimal places is about 11 cm,
  and 9 total digits leaves the three before the point that -180..180 needs.

  ⚠️ GUARDED PER COLUMN, NOT PER BLOCK. 020_m_mdm_document_types.sql records
  what a block-level guard costs: a table was created, its index failed, and on
  re-run the exists-check skipped the whole block and left it permanently
  unindexed (2.29). Four separate guards in this file — two columns, the
  computed column, the index — means a half-applied run completes itself on the
  next pass instead of locking in the half.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.columns
                WHERE object_id = OBJECT_ID('dbo.t_app_teachers') AND name = 'Latitude')
BEGIN
    PRINT '    Adding [Latitude] to [t_app_teachers] ...';

    ALTER TABLE dbo.t_app_teachers ADD Latitude decimal(9, 6) NULL;
END
ELSE
BEGIN
    PRINT '    [t_app_teachers].[Latitude] already present — skipped.';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns
                WHERE object_id = OBJECT_ID('dbo.t_app_teachers') AND name = 'Longitude')
BEGIN
    PRINT '    Adding [Longitude] to [t_app_teachers] ...';

    ALTER TABLE dbo.t_app_teachers ADD Longitude decimal(9, 6) NULL;
END
ELSE
BEGIN
    PRINT '    [t_app_teachers].[Longitude] already present — skipped.';
END
GO

/*------------------------------------------------------------------------------
  2. THE COMPUTED COLUMN.

  🔴 THE EXPRESSION, ARGUMENT BY ARGUMENT — read this before changing it:

      geography::Point( Latitude, Longitude, 4326 )
                        ^^^^^^^^  ^^^^^^^^^  ^^^^
                        LAT 1st   LONG 2nd   WGS 84

  4326 is WGS 84 — what a phone's GPS, Google Places and a Leaflet click all
  already are, and what 037's campus column is. It is a LITERAL rather than a
  lookup so the column cannot silently change meaning, and because the two
  operands of an STDistance must share an SRID: mismatched SRIDs make STDistance
  return NULL rather than raise, and a NULL distance here would not break the
  job list — it would quietly turn "nearest first" back into date order for
  every teacher at once, which is a feature failing to a passing-looking state.

  ⚠️ CAST(... AS float) IS EXPLICIT, AND IT IS WHERE THE PRECISION GOES.
  geography::Point takes float, so decimal -> float happens either way; an
  implicit conversion would be the same arithmetic with nothing naming it.
  float(53) carries ~15 significant digits and decimal(9,6) needs 9, so no
  stored coordinate loses anything — but the RESULT type is float, which is
  exactly what makes this expression IMPRECISE and PERSISTED mandatory. See the
  header.

  ⚠️ THE CASE IS NOT REDUNDANT DEFENSIVENESS, and the reasoning is 037's:
  geography::Point does return NULL for a NULL argument, so the bare call would
  behave identically. The CASE states the rule IN THE COLUMN DEFINITION, where
  somebody reading sys.computed_columns.definition will see it — instead of
  leaving "what happens to a teacher with no pin" to a reader's knowledge of CLR
  null propagation. And "what happens to a teacher with no pin" is the question
  this entire feature turns on.

  🔴 HALF A PIN IS NOT A PLACE, AND THE CASE IS WHERE THAT IS ENFORCED IN
  STORAGE. A latitude with no longitude would otherwise be a point on the
  Greenwich meridian — in the Atlantic, for anything in India. The CASE makes it
  NULL, which is "no pin", which is the right answer. USP_UpdateTeacherProfile
  refuses the pair up front as well, so this is the second line rather than the
  only one.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.columns
                WHERE object_id = OBJECT_ID('dbo.t_app_teachers') AND name = 'GeoPoint')
BEGIN
    PRINT '    Adding computed column [t_app_teachers].[GeoPoint] (PERSISTED geography) ...';

    ALTER TABLE dbo.t_app_teachers ADD GeoPoint AS
        CASE
            WHEN Latitude IS NULL OR Longitude IS NULL THEN NULL
            ELSE geography::Point(CAST(Latitude AS float), CAST(Longitude AS float), 4326)
        END
        PERSISTED;
END
ELSE
BEGIN
    PRINT '    [t_app_teachers].[GeoPoint] already present — skipped.';
END
GO

/*------------------------------------------------------------------------------
  🔒 GUARD — PERSISTED IS ASSERTED, NOT ASSUMED.

  ALTER TABLE ... PERSISTED fails outright if the expression is judged
  non-deterministic, so in principle reaching here means it worked. The failure
  this catches is the other one: somebody "simplifying" the expression later —
  dropping the CAST, replacing the literal SRID with a lookup, adding a
  GETDATE()-flavoured term — and losing persistence. At that point the spatial
  index below cannot be rebuilt, and nobody finds out until a from-scratch
  build.

  🔴 is_persisted LIVES ON sys.computed_columns, NOT sys.columns. A query
  against sys.columns compiles, returns nothing, and this guard then passes by
  finding no offending row — a guard that cannot fail. Same trap 037 names.

  Checked BEFORE the index, because the index DEPENDS on this being true.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.computed_columns
                WHERE object_id = OBJECT_ID('dbo.t_app_teachers')
                  AND name = 'GeoPoint'
                  AND is_persisted = 1)
    RAISERROR('041: [t_app_teachers].[GeoPoint] exists but is NOT PERSISTED. A spatial index cannot be built on an unpersisted computed column, and this expression can never qualify unpersisted because decimal -> float makes it IMPRECISE. See this file''s header: PERSISTED is what makes the index legal, not an optimisation.', 16, 1);
GO

/*------------------------------------------------------------------------------
  3. THE SPATIAL INDEX.

  SIX_ rather than IX_, the prefix 037 introduced: it tells a reader at a glance
  that this is not an index they can seek on an equality.

  ---------------------------------------------------------------------------
  ⚠️ AND THE HONEST LIMIT, STATED PLAINLY: D1 DOES NOT USE THIS INDEX.
  ---------------------------------------------------------------------------
  USP_BrowseJobs resolves ONE teacher's point into a variable and then measures
  every candidate campus against it. The LEFT operand is the CAMPUS's GeoPoint
  (037's column); this teacher column is read as a scalar, once, by primary key.
  So D1 uses THIS COLUMN — no per-row re-parse of two decimals into a geography
  — and the campus-side index is likewise not used, because the query orders a
  candidate set rather than asking "what is within X metres of this point".

  🔴 SO WHY BUILD IT. Two reasons, both the ones 037 recorded for the campus:

    1. COST. A spatial index built on a populated table is a size-of-data
       operation under a schema lock, and it cannot be done online in this
       edition. Building it on a table with a few dozen pinned teachers is free;
       building it the day somebody needs it is not.

    2. THE SYMMETRIC QUERY IS COMING AND IT IS A SEEK. "Which teachers are near
       THIS campus" — a school searching for staff within commuting distance —
       is a spatial predicate over this column with a point on the other side,
       and that is exactly what a spatial index answers. D1 is the half of the
       feature that does not need it.

  ⚠️ NO BOUNDING_BOX, NO GRIDS, NO CELLS_PER_OBJECT. BOUNDING_BOX is
  geometry-only; a geography index is tessellated over the whole globe and the
  default is GEOGRAPHY_AUTO_GRID. Tuning a tessellation against a table with no
  spatial SEEK in it yet would be four numbers chosen against nothing. When the
  symmetric query lands, it tunes this with a measured plan.

  ⚠️ NOT FILTERED, AND IT CANNOT BE. Spatial indexes take no WHERE clause, so
  the "only rows with coordinates" trick that filtered indexes use is
  unavailable. NULL rows are simply not indexed, which is the same outcome by a
  different route — and the reason no column here had to be made NOT NULL and no
  teacher had to be given an invented coordinate.

  What a spatial index DOES require, checked rather than assumed:

      a PRIMARY KEY, and it must be CLUSTERED   PK_t_app_teachers
                                                PRIMARY KEY CLUSTERED (TeacherId)
                                                — present since 011. ✔
      the column is geometry or geography       geography. ✔
      a computed column must be PERSISTED      asserted immediately above. ✔
      no WHERE clause                          none. ✔

  🔴 Guarded separately from the column (2.29).
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'SIX_t_app_teachers_GeoPoint'
                  AND object_id = OBJECT_ID('dbo.t_app_teachers'))
BEGIN
    PRINT '    Creating spatial index [SIX_t_app_teachers_GeoPoint] ...';

    CREATE SPATIAL INDEX SIX_t_app_teachers_GeoPoint
        ON dbo.t_app_teachers (GeoPoint);
END
ELSE
BEGIN
    PRINT '    [SIX_t_app_teachers_GeoPoint] already exists — skipped.';
END
GO

/*==============================================================================
  BUILD GUARDS
==============================================================================*/

/*
  🔒 GUARD 1 — LATITUDE IS STILL THE FIRST ARGUMENT.

  🔴 THIS IS THE ONE THAT MATTERS, and it matters more here than it did in 037.
  Every other failure in this file is loud. This one is silent, plausible and
  arithmetically consistent, and on this side of the feature it corrupts a SORT
  ORDER — which looks exactly like a correct sort order. A reversed point puts
  an Indian teacher in the Kara Sea, makes every school in India roughly
  equidistant, and ranks the list by how far north each campus is. No query
  errors, no row looks malformed, and the only symptom is "nearby jobs feels
  wrong", which nobody can file.

  Makes the same call the column makes, against a known pair, and asserts the
  latitude comes back out of .Lat. Hisar: 29.150000 N, 75.720000 E. If the
  arguments were swapped, .Lat would be 75.72 — also a legal latitude, which is
  exactly why eyes do not catch this.

  ⚠️ Deliberately NOT a read of the stored column: on a fresh build no teacher
  has coordinates, so a guard that queried the table would pass by finding
  nothing. This one is true on an empty database.

  ⚠️ And deliberately WITHOUT the CASE wrapper — both probe values are present,
  so the CASE would only test SQL Server's ability to evaluate a CASE. What is
  under test is the argument ORDER of the call inside it.
*/
DECLARE @lat decimal(9, 6) = 29.150000,
        @lng decimal(9, 6) = 75.720000;

DECLARE @probe geography = geography::Point(CAST(@lat AS float), CAST(@lng AS float), 4326);

IF @probe IS NULL
    RAISERROR('041: the GeoPoint expression returned NULL for a complete coordinate pair. geography::Point(29.15, 75.72, 4326) must produce a point.', 16, 1);
ELSE IF ABS(@probe.Lat - 29.15) > 0.000001 OR ABS(@probe.Long - 75.72) > 0.000001
BEGIN
    DECLARE @swapped nvarchar(1000) =
        N'041: 🔴 geography::Point ARGUMENTS ARE THE WRONG WAY ROUND. '
      + N'Built from latitude 29.150000 / longitude 75.720000, the point reports Lat='
      + CAST(@probe.Lat AS nvarchar(30)) + N' Long=' + CAST(@probe.Long AS nvarchar(30))
      + N'. geography::Point takes LATITUDE FIRST — the opposite of geometry::Point and of '
      + N'GeoJSON/Google/Leaflet [lng, lat]. Reversed, an Indian teacher lands in the Kara Sea, '
      + N'every school in India is about 4,500 km away, and the job list is silently ranked by '
      + N'how far north each campus is. See this file''s header.';

    RAISERROR('%s', 16, 1, @swapped);
END
GO

/*
  🔒 GUARD 2 — THE SRID IS 4326, IN THE DEPLOYED DEFINITION ITSELF.

  STDistance between two geography instances of DIFFERENT SRIDs returns NULL —
  not an error, NULL. 037's campus column is 4326; a teacher column built on
  4283 or 0 would make every distance NULL, which in USP_BrowseJobs means the
  pinned/unpinned split collapses and every tab falls back to date order. 🔴 The
  feature would appear to be "off" for every teacher with a pin, with nothing
  logged and nothing failing — the worst available outcome, because "nearby jobs
  does not seem to do anything" is indistinguishable from "no teacher has pinned
  themselves yet".

  Read out of sys.computed_columns rather than re-derived, because what matters
  is the SRID in the DEPLOYED definition, not in a probe this script just wrote.
*/
DECLARE @def nvarchar(max) =
    (SELECT cc.definition
       FROM sys.computed_columns cc
      WHERE cc.object_id = OBJECT_ID('dbo.t_app_teachers')
        AND cc.name = 'GeoPoint');

IF @def IS NULL OR @def NOT LIKE '%4326%'
    RAISERROR('041: [t_app_teachers].[GeoPoint] is not built on SRID 4326. Two geography instances with different SRIDs make STDistance return NULL rather than raise — so every nearby-jobs distance would be NULL and every tab would silently fall back to date order, which is indistinguishable from "nobody has pinned themselves yet". 4326 is WGS 84, and it is what 037''s campus GeoPoint is built on.', 16, 1);
GO

/*
  🔒 GUARD 3 — THE SAME SRID AS THE CAMPUS COLUMN, NAMED AS A PAIR.

  Guard 2 says this column is 4326. This one says the thing that is actually
  load-bearing: that it is 4326 AT THE SAME TIME AS 037's. An STDistance needs
  both operands to agree, so the invariant belongs to the PAIR and not to either
  column — and a guard on one column alone would pass on a database where
  somebody had rebuilt the other.

  ⚠️ Deliberately asserts on the definitions rather than on a computed value:
  on a fresh build no teacher and no campus has coordinates, so nothing can be
  measured yet. What can be checked is that both expressions name the same SRID.
*/
IF EXISTS (
    SELECT 1
      FROM sys.computed_columns t
     CROSS JOIN sys.computed_columns b
     WHERE t.object_id = OBJECT_ID('dbo.t_app_teachers')        AND t.name = 'GeoPoint'
       AND b.object_id = OBJECT_ID('dbo.t_app_school_branches') AND b.name = 'GeoPoint'
       AND (b.definition NOT LIKE '%4326%' OR t.definition NOT LIKE '%4326%'))
    RAISERROR('041: [t_app_teachers].[GeoPoint] and [t_app_school_branches].[GeoPoint] are not both on SRID 4326. The nearby-jobs distance is an STDistance BETWEEN them, and STDistance across two SRIDs returns NULL rather than raising. The invariant belongs to the pair: fixing one column is not fixing this.', 16, 1);
GO

/*
  🔒 GUARD 4 — THE PIN COLUMNS ARE decimal(9,6).

  The CAST in the expression is written against that shape: widen the scale and
  the PERSISTED values go stale against their own source columns until the table
  is rebuilt.

  Narrow and specific on purpose. 036 carries the platform-wide version of this
  check and it covers these two columns by name — but 036 runs EARLIER in the
  build than this file, so on a from-scratch pass it judges these columns on the
  NEXT run. This one judges them now, which is when the expression above was
  written against them. Same reason 037 repeats it, plus the ordering.
*/
IF EXISTS (SELECT 1 FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.t_app_teachers')
              AND name IN ('Latitude', 'Longitude')
              AND NOT (precision = 9 AND scale = 6))
    RAISERROR('041: [t_app_teachers].Latitude/Longitude are no longer decimal(9,6). [GeoPoint] CASTs them to float against that shape, and 036 carries the platform-wide rule that every coordinate in jp_app is decimal(9,6) — but 036 runs before this file, so this is the check that applies on the build that adds these columns.', 16, 1);
GO

/*
  🔒 GUARD 5 — NEITHER COLUMN GAINED A DEFAULT.

  ⚠️ 0, 0 IS A REAL PLACE. A DEFAULT of zero on either column — added later by
  somebody tidying up "nullable with no default" — would put every new teacher
  in the Gulf of Guinea and rank their job list by proximity to open water. And
  because the computed column only NULLs when a coordinate is MISSING, a
  defaulted zero is a complete, valid, perfectly indexable pin: nothing
  downstream could tell it from a point somebody chose.

  🔴 This is also what keeps "nobody asked this teacher" expressible at all. The
  whole feature branches on NULL meaning no pin.
*/
IF EXISTS (SELECT 1 FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.t_app_teachers')
              AND name IN ('Latitude', 'Longitude')
              AND default_object_id <> 0)
    RAISERROR('041: a DEFAULT has been added to [t_app_teachers].Latitude or Longitude. 0,0 is a real coordinate in the Gulf of Guinea, not an empty value — a default would give every teacher a complete, indexable pin they never chose, and would destroy the NULL that means "nobody asked". Both columns stay nullable with no default.', 16, 1);
GO

PRINT '    Teacher GeoPoint column and spatial index ready.';
GO
