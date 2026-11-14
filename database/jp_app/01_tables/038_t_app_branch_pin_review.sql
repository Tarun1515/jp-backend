/*==============================================================================
  jp_app — 038_t_app_branch_pin_review.sql

  SCHOOL REVAMP (SR-2) — the distance guard's storage.

      t_app_school_branches  + GeocodedLatitude / GeocodedLongitude / GeocodedOn
      t_app_branch_pin_review_log   APPEND-ONLY. Every pin correction and clear.

  ---------------------------------------------------------------------------
  🔴 THE ANCHOR DID NOT EXIST, AND THESE THREE COLUMNS ARE INVENTED. READ THIS.
  ---------------------------------------------------------------------------
  The rule being built is: if a school's PIN is further than a configured
  distance from THE GEOCODED POINT OF ITS OWN STATED ADDRESS, the campus goes
  on a review list.

  That needs two points per campus. The product stores ONE.

  Measured before writing, across every table that carries a coordinate:

    t_app_school_branches.Latitude/Longitude   ONE pair, decimal(9,6), since
                                               3C. USP_SaveBranch writes
                                               whatever the school sends, which
                                               IS the pin. There is no second
                                               pair and never has been.
    t_app_school_branches.GooglePlaceId        added by 036 (SR-1) and NEVER
                                               WRITTEN — it is not even a
                                               parameter of USP_SaveBranch. So
                                               not even the provider token for
                                               the stated address survives for
                                               a campus.
    t_app_schools.Latitude/Longitude           the SCHOOL's pair, from
                                               registration via Places. This IS
                                               a geocode of a stated address —
                                               but it is the school's address,
                                               which 003 says belongs to the
                                               HEAD OFFICE branch. It says
                                               nothing about campus three.
    t_mdm_school_registration_details
                 .Latitude/Longitude           the same fact one database
                                               earlier, at registration time.
                                               Same limitation, plus 2.2: jp_app
                                               may not join to jp_mdm.
    m_mdm_city.Latitude/Longitude              THE TOWN CENTRE.
    m_mdm_tehsil.Latitude/Longitude            THE TEHSIL CENTRE.

  🔴 THE LAST TWO ARE THE TEMPTING WRONG ANSWER AND THEY ARE EXPLICITLY NOT THE
  ANCHOR. "Is this pin within 3km of Hisar?" is a different question from "is
  this pin within 3km of the address this school typed". A big campus on the
  edge of a town is legitimately 8km from the town centre and 50m from its own
  gate; measuring against the centroid flags the honest schools and clears the
  dishonest ones in dense areas. It would produce a queue that is worse than no
  queue, because somebody would work it.

  ---------------------------------------------------------------------------
  SO: THE SMALLEST HONEST THING
  ---------------------------------------------------------------------------
  Two coordinate columns for the anchor, and a timestamp, on the branch:

      GeocodedLatitude   decimal(9,6)  the geocode of the STATED address
      GeocodedLongitude  decimal(9,6)
      GeocodedOn         datetime2     when that geocode was taken

  ⚠️ WRITTEN BY THE ADDRESS PATH, NEVER BY A PIN DRAG. That is the whole
  distinction: Latitude/Longitude is where the school SAYS the campus is on a
  map; Geocoded* is where the address they TYPED resolves to. One pair of
  columns cannot be both, which is why the review rule could not be built
  against the existing schema at all.

  ⚠️ NULLABLE, AND NOTHING IS BACKFILLED — 036's rule, for 036's reason. An
  existing campus has no anchor because nobody was ever asked; inventing one
  from a city centroid is precisely the wrong answer above, written into the
  table. A campus with no anchor simply does not appear on the review list, and
  028's read says so in a comment rather than quietly returning fewer rows.

  ⚠️ GeocodedOn EARNS ITS PLACE, it is not audit decoration. The address can be
  edited after the geocode was taken, and then the anchor is stale — the queue
  would be comparing today's pin against the resolution of last month's
  address. Nothing can prevent that without re-geocoding on every address edit
  (a billed call on a path that is not on a keystroke). What CAN be done is let
  an admin SEE it, so 028 returns the anchor's age and the campus's own
  ModifiedOn beside each other. An anchor whose age cannot be seen is one
  nobody can judge.

  🔴 NO SECOND geography COLUMN FOR THE ANCHOR, AND NO SECOND SPATIAL INDEX.
  037's GeoPoint is persisted because the PIN is what nearby-search will search.
  The anchor is only ever read against its own row's pin — one point
  construction per row in 028, never a search — so persisting it would pay the
  write cost and the index cost of a query nothing issues. Stated here because
  "we have one, why not two" is the obvious next edit.

  ---------------------------------------------------------------------------
  🔴 THE TRAIL FOLLOWS t_app_job_moderation_log, NOT A NEW SHAPE
  ---------------------------------------------------------------------------
  The product already records an admin acting on somebody else's data with a
  reason and an actor, twice:

      t_app_job_moderation_log (034)   ActionType / Remarks NOT NULL /
                                       ActionByUserId / ActionOn, append-only,
                                       and the PREVIOUS value so the action is
                                       reversible.
      t_app_reports (034)              ReviewedByUserId + ReviewedOn + remarks,
                                       with CK_..._ReviewTrail asserting that a
                                       terminal state HAS both.

  This table is the first shape, deliberately, because a pin correction is the
  same kind of event as a job pull: an administrator overwrites a value the
  school supplied, and the school's own figure has to survive the overwrite. It
  is NOT the t_app_reports shape — there is no queue row to disposition here,
  because the review list is DERIVED from the distance (the same choice 034
  made for featured placement: a comparison at read time, not a stored flag and
  a sweep).

  ⚠️ So there is no t_app_branch_pin_reviews table and no status column, and
  that absence is the design. A corrected pin leaves the list because it is no
  longer far away, not because something marked it done.

  ---------------------------------------------------------------------------
  🔴 "NEEDS REVIEW" IS NOT "DISTANCE > THRESHOLD". IT IS THAT, AND NOT CLEARED.
  ---------------------------------------------------------------------------
  A CLEAR is an admin saying "this campus really is 9km from the address it
  typed, and that is correct" — a big campus with its gate on another road, a
  village address that geocodes to the panchayat office. That judgement cannot
  be derived from anything. If the row only carried the comparison, CLEAR would
  have nowhere to live and the same campus would be back on the queue tomorrow,
  for ever, which is how a queue stops being worked.

  ⚠️ AND IT IS STILL NOT A STORED VERDICT. The judgement lives as a CLEAR row
  in the append-only log — a record of an ACT, with an actor and a reason —
  never as a flag on the branch. "Cleared" is then derived: a CLEAR row exists
  whose PreviousLatitude/PreviousLongitude EQUAL the campus's current pin.

  🔴 THAT EQUALITY IS THE WHOLE TRICK, AND IT IS WHY NO COLUMN WAS NEEDED. The
  clear applies to the pin that was judged, not to the campus for ever. Move
  the pin and the judgement lapses by itself — no sweep, no expiry job, nothing
  to keep in step. And the comparison is EXACT because both sides are
  decimal(9,6); the same two columns held as float would make this unreliable
  in a way that showed up as a campus occasionally reappearing.

  ⚠️ ANY matching CLEAR counts, not merely the most recent log row. A campus
  cleared at pin P, moved to Q, then moved back to P is cleared again — the
  admin judged P, and P is where it is. Order-independence also means the
  derivation cannot depend on how two actions interleaved.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET NUMERIC_ROUNDABORT OFF;
GO

SET NOCOUNT ON;
GO

/*==============================================================================
  The anchor, on the branch.

  ⚠️ decimal(9,6), the same as the pin — 036's platform-wide guard asserts that
  every Latitude/Longitude in jp_app is that shape, and these two are named
  Geocoded* precisely so they are NOT caught by it. The shape is matched
  anyway: a pin at 6dp compared against an anchor at 5dp is the "school a few
  hundred metres from itself" problem 036 was written about, one column pair
  over.
==============================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.columns
                WHERE object_id = OBJECT_ID('dbo.t_app_school_branches') AND name = 'GeocodedLatitude')
BEGIN
    PRINT '    Adding anchor columns to [t_app_school_branches] ...';

    ALTER TABLE dbo.t_app_school_branches ADD
        GeocodedLatitude    decimal(9, 6)   NULL,
        GeocodedLongitude   decimal(9, 6)   NULL,
        GeocodedOn          datetime2       NULL;
END
ELSE
BEGIN
    PRINT '    [t_app_school_branches] anchor columns already present.';
END
GO

/*
  🔒 GUARD — the anchor columns are decimal(9,6) like the pin.

  036's guard deliberately excludes these (it matches on the names Latitude and
  Longitude). This is the same rule for the same reason, scoped to the two
  columns 036 cannot see.

  Proven to fire: altering GeocodedLatitude to decimal(8,5) fails this.
*/
IF EXISTS (SELECT 1 FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.t_app_school_branches')
              AND name IN ('GeocodedLatitude', 'GeocodedLongitude')
              AND NOT (precision = 9 AND scale = 6))
    RAISERROR('038: an anchor coordinate column on t_app_school_branches is not decimal(9,6). The pin is decimal(9,6) (036) and the distance guard subtracts one from the other — two precisions make a campus a few hundred metres from itself, which is the whole of 036''s header.', 16, 1);
GO

/*------------------------------------------------------------------------------
  Campuses that have a PIN — the population the review screen lists.

  🔴 FILTERED ON THE PIN ONLY, NOT ON THE ANCHOR, AND THAT IS DELIBERATE. The
  first version of this index required all four coordinates, which matches the
  set that NEEDS REVIEW but not the set the screen SHOWS: the admin desk can
  also list campuses it has already cleared and campuses whose distance cannot
  be measured because nothing geocoded their address. A campus with a pin and
  no anchor is a real row on that screen — it reports no distance, says so, and
  is visible rather than silently missing.

  ⚠️ A campus with NO pin is out, and that is the honest boundary: a pin review
  has nothing to say about a campus nobody has pinned. The single-row reads in
  028 deliberately bypass this filter so that fetching one campus by reference
  always answers.

  ⚠️ INCLUDEs everything the list projects from the branch row, so the read is
  covered: both coordinate pairs, the anchor's age and the name. GeoPoint is NOT
  INCLUDEd and cannot be — a geography column is not byte-ordered, so it may be
  neither an index key nor an INCLUDE, and the persisted value is fetched from
  the row itself. That is the one place 037's column costs something, and it is
  far cheaper than re-deriving it per row.

  🔴 Guarded separately from the columns (2.29).
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'IX_t_app_school_branches_PinReview'
                  AND object_id = OBJECT_ID('dbo.t_app_school_branches'))
BEGIN
    PRINT '    Creating index [IX_t_app_school_branches_PinReview] ...';

    CREATE NONCLUSTERED INDEX IX_t_app_school_branches_PinReview
        ON dbo.t_app_school_branches (SchoolId, BranchId)
        INCLUDE (BranchName, IsHeadOffice, Latitude, Longitude,
                 GeocodedLatitude, GeocodedLongitude, GeocodedOn)
        WHERE Latitude IS NOT NULL AND Longitude IS NOT NULL AND Is_Deleted = 0;
END
ELSE
BEGIN
    PRINT '    [IX_t_app_school_branches_PinReview] already exists — skipped.';
END
GO

/*==============================================================================
  t_app_branch_pin_review_log — APPEND-ONLY. Every correction and every clear.

  🔴 NO Is_Deleted, NO ModifiedOn, NO ModifiedBy. 034's rule, and the same
  structural half of "append-only": there is no column through which an edit or
  a deletion can be expressed, so the soft-delete shape every other table here
  uses is simply absent.

  ⚠️ NO TRIGGER, for 034's reason — this schema has no triggers in any
  production file, and introducing the first one for this would mean every
  future reader of this table has to know writes behave differently here.
  028_branch_pin_review.sql carries a build guard instead: no procedure may
  UPDATE or DELETE this table.

  ⚠️ AND THE SAME LIMIT, STATED: somebody with direct database access can still
  UPDATE a row. One login, no DENY. What is prevented is the application
  growing a way to do it.
==============================================================================*/
IF OBJECT_ID('dbo.t_app_branch_pin_review_log', 'U') IS NULL
BEGIN
    PRINT '    Creating table [t_app_branch_pin_review_log] ...';

    CREATE TABLE dbo.t_app_branch_pin_review_log
    (
        LogId              bigint         IDENTITY(1, 1) NOT NULL,

        BranchId           bigint         NOT NULL,

        /*
          🔴 CORRECT or CLEAR. A CHECK rather than a master table: there are two
          values, they are decided by what the code can do, and a master would
          invite a third that no procedure writes (034's reasoning, verbatim).
        */
        ActionType         varchar(10)    NOT NULL,

        /*
          🔴 THE PIN AS IT STOOD WHEN THE ADMIN ACTED. TWO JOBS, BOTH LOAD-BEARING.

          On a CORRECT it is what makes the action reversible — the same role
          PreviousStatusId plays in 034. A pin is one column pair, so correcting
          it overwrites what the school chose; without this, "put it back" is a
          guess, and a school disputing a correction has nothing to point at.

          🔴 On a CLEAR it is the SUBJECT OF THE JUDGEMENT, and it is what makes
          "cleared" derivable without a flag on the branch. A clear says "THIS
          pin is correct despite the distance", so the pin it names is how the
          read knows whether the judgement still applies. See this file's
          header.

          ⚠️ NULLABLE for a CORRECT (a campus may have had no pin at all) and
          REQUIRED for a CLEAR (there is nothing to judge otherwise) — asserted
          by CK_..._Result below rather than left to the procedures.
        */
        PreviousLatitude   decimal(9, 6)  NULL,
        PreviousLongitude  decimal(9, 6)  NULL,

        /*
          What the admin SET it to. NULL for a CLEAR, and that is not a gap —
          a clear sets nothing. It leaves the coordinates exactly as the school
          left them and records that somebody decided the distance was fine.

          ⚠️ SO A CLEAR MUST NOT COPY THE PIN IN HERE "for completeness". A
          CORRECT and a CLEAR would then be indistinguishable in the trail
          except by ActionType, and the first read that forgot to check it would
          report "corrected by X" about somebody who deliberately did not move
          anything. CK_..._Result makes that shape impossible to insert.
        */
        NewLatitude        decimal(9, 6)  NULL,
        NewLongitude       decimal(9, 6)  NULL,

        /*
          ⚠️ THE ANCHOR AS IT STOOD AT THE MOMENT OF THE ACTION, COPIED.

          Not a join back to the branch, deliberately. The anchor can be
          re-geocoded after an address edit, and then a trail that joined live
          would silently re-tell the story against a point that was not there
          at the time — "corrected because it was 9km out" rendered as 300m out,
          with no record that anything moved. A log that can change its own past
          is not a log.
        */
        AnchorLatitude     decimal(9, 6)  NULL,
        AnchorLongitude    decimal(9, 6)  NULL,

        /*
          ⚠️ THE DISTANCE THAT PUT IT ON THE LIST, IN METRES, int.

          Metres rather than km: STDistance returns metres for SRID 4326, and
          converting at the write would mean storing a rounded figure derived
          from the real one. int because the earth is 40,000km round and a
          distance in metres fits with four orders of magnitude to spare.

          ⚠️ NULLABLE. A CLEAR of a pin whose campus has no anchor has no
          distance to record, and 0 would be a lie — it would read as "the pin
          was exactly right" about a campus nothing could measure.
        */
        DistanceMetres     int            NULL,

        /*
          🔴 REQUIRED, AND NOT NULLABLE. 034's rule: a correction nobody can
          explain later is the one that becomes an argument, and the school is
          entitled to the reason its own figure was overwritten. The procedure
          refuses an empty one too — this is the floor.
        */
        Remarks            nvarchar(1000) NOT NULL,

        ActionByUserId     bigint         NOT NULL,
        ActionOn           datetime2      NOT NULL
                           CONSTRAINT DF_t_app_branch_pin_review_log_ActionOn DEFAULT (SYSUTCDATETIME()),

        CONSTRAINT PK_t_app_branch_pin_review_log PRIMARY KEY CLUSTERED (LogId),

        CONSTRAINT FK_t_app_branch_pin_review_log_Branch
            FOREIGN KEY (BranchId) REFERENCES dbo.t_app_school_branches (BranchId),

        CONSTRAINT CK_t_app_branch_pin_review_log_ActionType
            CHECK (ActionType IN ('CORRECT', 'CLEAR')),

        /*
          🔴 THE ACTION AND ITS RESULT CANNOT DISAGREE.

          The same structural rule CK_t_app_reports_ReviewTrail puts on a
          reviewed report (034), for the same reason: a row whose ActionType
          says CORRECT and whose new coordinates are NULL is a log entry that
          describes something that did not happen, and the shape that produces
          it is an INSERT that sets the type and forgets the rest.

          CORRECT  -> both new coordinates present. That IS the correction.
          CLEAR    -> both absent, and a PREVIOUS pair present. A clear sets
                      nothing and judges the pin that is there, so a clear with
                      no previous pin is a judgement about nothing.
        */
        CONSTRAINT CK_t_app_branch_pin_review_log_Result
            CHECK (
                (ActionType = 'CORRECT' AND NewLatitude IS NOT NULL AND NewLongitude IS NOT NULL)
                OR
                (ActionType = 'CLEAR'   AND NewLatitude IS NULL     AND NewLongitude IS NULL
                                        AND PreviousLatitude IS NOT NULL
                                        AND PreviousLongitude IS NOT NULL)
            ),

        /*
          ⚠️ A HALF COORDINATE IS NOT A COORDINATE. Every pair in this table is
          both-or-neither — a latitude with no longitude is a point on a line of
          latitude, which is not a place.
        */
        CONSTRAINT CK_t_app_branch_pin_review_log_PairsComplete
            CHECK (
                    (    (PreviousLatitude IS NULL     AND PreviousLongitude IS NULL)
                      OR (PreviousLatitude IS NOT NULL AND PreviousLongitude IS NOT NULL))
                AND (    (AnchorLatitude   IS NULL     AND AnchorLongitude   IS NULL)
                      OR (AnchorLatitude   IS NOT NULL AND AnchorLongitude   IS NOT NULL))
            ),

        CONSTRAINT CK_t_app_branch_pin_review_log_Remarks
            CHECK (LEN(LTRIM(RTRIM(Remarks))) > 0)
    );

    /* One campus's history, newest first — 034's index, for 034's screen. */
    CREATE NONCLUSTERED INDEX IX_t_app_branch_pin_review_log_Branch
        ON dbo.t_app_branch_pin_review_log (BranchId, LogId DESC);

    PRINT '      Table + 1 index created.';
END
ELSE
    PRINT '    Table [t_app_branch_pin_review_log] already exists — skipped.';
GO

/*
  🔒 GUARD — the append-only shape is asserted, not just described.

  034's guard, on this table. If somebody adds Is_Deleted, ModifiedOn or
  ModifiedBy, the ordinary soft-delete and edit shapes become expressible and
  this stops being a log.

  Proven to fire: adding Is_Deleted to the CREATE above fails this.
*/
IF EXISTS (SELECT 1 FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.t_app_branch_pin_review_log')
              AND name IN ('Is_Deleted', 'Is_Active', 'ModifiedOn', 'ModifiedBy'))
    RAISERROR('038: t_app_branch_pin_review_log has gained an edit or delete column. It is APPEND-ONLY: with no such column there is no shape through which a pin correction can be rewritten or hidden. Remove it, and see this file''s header and 034''s.', 16, 1);
GO

/*
  🔒 GUARD — "needs review" stays DERIVED, AND SO DOES "cleared".

  034's featured-placement guard, transplanted. A NeedsReview, IsFlagged or
  ReviewStatusId column on the BRANCH would make the verdict storable, and then
  something has to keep it in step with the distance and the configured
  threshold — which is a sweep, and a sweep is a job that will one day not run,
  silently. Worse here than for featured placement: the threshold is
  configuration, so a stored verdict would be stale the moment somebody edits
  appsettings.json and would never recover.

  🔴 PinClearedOn / PinClearedBy ARE IN THIS LIST TOO, and they are the ones
  somebody will reach for. They look innocent — an actor and a timestamp, the
  shape this schema uses everywhere — and they would be a SECOND place the
  clear decision lives beside the log row that already holds it, with no
  reference to the pin that was judged. Move the pin and the columns would
  still say cleared. The log-row derivation in this file's header lapses by
  itself; a pair of columns cannot.

  Proven to fire: adding NeedsPinReview to t_app_school_branches fails this.
*/
IF EXISTS (SELECT 1 FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.t_app_school_branches')
              AND name IN ('NeedsPinReview', 'IsPinFlagged', 'PinReviewStatusId',
                           'PinDistanceMetres', 'PinClearedOn', 'PinClearedBy'))
    RAISERROR('038: t_app_school_branches has gained a stored pin-review verdict or clear flag. "Needs review" is DERIVED at read time from STDistance and the CONFIGURED threshold, and "cleared" is derived from a CLEAR log row whose previous pin EQUALS the current one (this file''s header, 034, 2.5). A stored flag needs a sweep to stay true, goes stale the moment appsettings.json changes, and in the clear''s case would survive the school moving the pin it judged.', 16, 1);
GO

PRINT '    Branch pin anchor and review log ready.';
GO
