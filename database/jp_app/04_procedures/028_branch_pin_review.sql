/*==============================================================================
  jp_app — 04_procedures / 028_branch_pin_review.sql

  SCHOOL REVAMP (SR-2) — THE DISTANCE GUARD AND THE CAMPUS-PIN DESK.

    USP_SearchCampusPinReview   the list AND both single-row reads
    USP_CorrectCampusPin        an admin moves the pin, with a reason
    USP_ClearCampusPin          an admin judges the distance correct, with a
                                reason — and moves nothing
    USP_GetCampusPinHistory     the trail, scoped for a school or an admin

  Both writes follow 025's shape exactly — Status/Code/Message/Id (2.21),
  remarks required, the log row written BEFORE the value it describes is
  overwritten, and nothing else touched.

  ⚠️ "CAMPUS" IN THE PROCEDURE NAMES, "BRANCH" IN THE TABLE NAMES. The same
  split 005_seed_menus.sql records for the sidebar ("Campuses", route
  /branches): the table is t_app_school_branches because that is what it has
  always been called, and everything this feature exposes — the route
  api/admin/desk/campus-pins, the CampusPinReview contract, the screen — says
  campus, because that is the word a school and an admin use. One word per
  audience, named here so neither reads as a typo.

  ---------------------------------------------------------------------------
  🔴 THE THRESHOLD IS A PARAMETER WITH NO DEFAULT, AND THAT IS THE POINT
  ---------------------------------------------------------------------------
  @ThresholdKm is required. There is no `= 3`, and there is no constant named
  THREE_KM anywhere in this file.

  The number lives in `CampusPinReview:MaxDistanceKm` in appsettings.json,
  beside the RateLimits numbers and for the same reason (2.7): it is a value an
  operator tunes after looking at a real queue, not a fact about the domain. A
  default here would be a SECOND answer to a question configuration already
  answers — and the day the two disagree, the SQL wins silently and nobody can
  see why the queue changed.

  ⚠️ SO `EXEC USP_SearchCampusPinReview` FAILS, loudly, naming the missing
  parameter. Deliberate: a hand-run read with no threshold has no meaning, and
  the alternative is one that quietly uses a number nobody chose.

  🔴 AND IT IS ECHOED BACK ON EVERY ROW as ThresholdKm. The client does not
  keep a copy of a server setting — a client copy is silently wrong the day the
  server is configured to anything else, and the screen would then explain a
  queue using the wrong number.

  ⚠️ KILOMETRES ON EVERY SEAM, METRES AT EXACTLY ONE POINT. The config key, the
  parameter and the contract are all km, because that is what a person types
  and reads. STDistance returns METRES, so the ×1000 happens once, inside the
  comparison below, at the only place that knows STDistance's unit.

  ---------------------------------------------------------------------------
  🔴 WHERE THE ANCHOR COMES FROM, HONESTLY
  ---------------------------------------------------------------------------
  t_app_school_branches.GeocodedLatitude / GeocodedLongitude — three columns
  THIS PASS ADDED, because the product stored no such point. 038's header has
  the full measurement of every coordinate in the database and why none of them
  would do; the short version:

      the branch's Latitude/Longitude    IS the pin. One pair, not two.
      the school's Latitude/Longitude    the HEAD OFFICE's address, at best.
      m_mdm_city / m_mdm_tehsil          THE TOWN CENTRE — explicitly not the
                                         anchor, and the tempting wrong answer.

  🔴 WHICH MEANS NO CAMPUS NEEDS REVIEW UNTIL SOMETHING WRITES THE ANCHOR.
  Nothing in this pass does: the write belongs to the address-lookup path (a
  branch address resolved through Places), which is SR-3's work, and
  USP_SaveBranch does not even carry @GooglePlaceId today. A campus with a pin
  and no anchor appears on the desk with DistanceKm NULL and NeedsReview 0 —
  present and visibly unmeasured, rather than absent and assumed fine.

  ---------------------------------------------------------------------------
  🔴 WHY THE PERSISTED COLUMN EARNS ITS PLACE — AND WHERE IT DOES NOT
  ---------------------------------------------------------------------------
  The distance is `b.GeoPoint.STDistance(<anchor>)`. The LEFT operand is 037's
  PERSISTED column, read from the row as a ready geography instance. Without
  it, every row on the desk would pay two decimal->float conversions and a
  geography::Point construction for the pin as well as the anchor, on every
  read, for a value that cannot change unless the row changes. That is what
  persisting it buys, and it is why 037 is in the same pass as this file rather
  than a phase later.

  ⚠️ AND THE HONEST OTHER HALF: the SPATIAL INDEX is not used by this query and
  cannot be. Every row is compared to ITS OWN anchor, so there is no single
  search point to seek on — this is a row-by-row computation over a filtered
  set, served by IX_t_app_school_branches_PinReview (038). The spatial index is
  for nearby-search, and 037's header says so. A comment here claiming this
  query seeks it would be the kind of thing nobody checks.

  ---------------------------------------------------------------------------
  🔴 ONE READ PROCEDURE, THREE ENTRY SHAPES
  ---------------------------------------------------------------------------
  The list, the read by campus reference and the read by registration request
  are the same procedure with different arguments, for 025's reason: a separate
  single-row read would be a second place that decides what a campus-pin row
  looks like, and the day the two disagree the screen and the detail panel
  report different distances for the same campus.

  ⚠️ @IncludeTrail GOVERNS A THIRD RESULT SET, and defaults to 0. Twenty trails
  for a page nobody has opened is twenty queries nobody asked for; the single
  reads pass 1.

  ---------------------------------------------------------------------------
  🔴 NO SCOPE RESOLVER ON THE ADMIN PATHS, AND THAT IS NOT AN OVERSIGHT
  ---------------------------------------------------------------------------
  fn_VisibleBranches (2.53) decides what a SCHOOL USER may see. These
  procedures are called by an administrator, across every school, and joining
  the resolver would return nothing for them — an admin is not a member of any
  school. The gate is a PERMISSION, MODERATION.CAMPUS_PIN, checked in
  AdminDeskService.

  ⚠️ USP_GetCampusPinHistory IS the exception and takes @OrganizationUid,
  exactly as USP_GetJobModerationHistory does: a school is entitled to see why
  its own pin was moved, and a campus that is not theirs returns ZERO ROWS
  rather than a refusal (2.6).
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
  USP_SearchCampusPinReview — the desk.

  🔴 A QUEUE, NOT A LIST: the campuses that need review come first, then the
  largest distance. 025's ordering principle — the worst first, not the newest
  first.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SearchCampusPinReview
    /*
      🔴 REQUIRED. No default — see this file's header. The number is
      configuration, and a fallback here would be a second answer to it.
    */
    @ThresholdKm       decimal(9, 3),

    /*
      The campus reference, when reading one. This is what the API hands the
      client as an OPAQUE pinRef and gets back unchanged — see the comment on
      the PinRef projection below.
    */
    @BranchUid         uniqueidentifier = NULL,

    /*
      The registration request's UID, when the admin arrived from an approval.

      ⚠️ A UID, NOT THE bigint RequestId the route carries. jp_app stores
      t_app_schools.SourceRequestUid and may not join to jp_mdm (2.2), so the
      service resolves RequestId -> RequestUid against jp_mdm first and passes
      the uid here. That resolution is the same two-reads-one-assembly shape
      the analytics screen already uses.

      ⚠️ IT RESOLVES TO THE HEAD OFFICE. A registration produces one school and
      one campus — the head office, which 003 says is "the branch a school's own
      address belongs to". A school that has since added campuses has them on
      the list; this entry point answers "the campus this registration created".
    */
    @SourceRequestUid  uniqueidentifier = NULL,

    /* Only the campuses that need review. The desk's default tab. */
    @NeedsReviewOnly   bit = 0,

    /* Include the ones an admin has already judged correct. */
    @IncludeCleared    bit = 1,

    @Search            nvarchar(200) = NULL,
    @PageNumber        int = 1,
    @PageSize          int = 20,

    /* Result set 3. Off for the list — see this file's header. */
    @IncludeTrail      bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    /*
      ⚠️ Clamped the way every other list in this schema clamps (025), so a
      caller asking for 10,000 rows gets 20 rather than a refusal.
    */
    DECLARE @Skip int = (CASE WHEN @PageNumber < 1 THEN 0 ELSE @PageNumber - 1 END)
                        * (CASE WHEN @PageSize BETWEEN 1 AND 100 THEN @PageSize ELSE 20 END),
            @Take int = CASE WHEN @PageSize BETWEEN 1 AND 100 THEN @PageSize ELSE 20 END;

    /*
      🔴 THE ONE PLACE KILOMETRES BECOME METRES. See this file's header.

      ⚠️ A NEGATIVE OR ZERO THRESHOLD WOULD FLAG EVERY PINNED CAMPUS, including
      the ones whose pin is exactly right. Floored at one metre rather than
      refused: this procedure answers a question, and the honest reading of "0"
      from a misconfigured file is "as tight as possible", not "fail the admin's
      screen". The options class validates the config properly at startup —
      this is the floor, not the rule.
    */
    DECLARE @ThresholdMetres float =
        CASE WHEN ISNULL(@ThresholdKm, 0) <= 0 THEN 1.0
             ELSE CAST(@ThresholdKm AS float) * 1000.0 END;

    DECLARE @Like nvarchar(210) =
        CASE WHEN @Search IS NULL OR LTRIM(RTRIM(@Search)) = N''
             THEN NULL ELSE N'%' + LTRIM(RTRIM(@Search)) + N'%' END;

    /* 1 when this call is a single-row read. See the pin filter below. */
    DECLARE @IsSingle bit =
        CASE WHEN @BranchUid IS NOT NULL OR @SourceRequestUid IS NOT NULL THEN 1 ELSE 0 END;

    /*
      🔴 ONE CTE, AND EVERY DERIVED FACT IS COMPUTED IN IT EXACTLY ONCE.

      The distance, "is it cleared" and "does it need review" are each used by
      the projection, the WHERE clause and the ORDER BY. Written out at each
      site they would be three chances for the number shown, the rows returned
      and the order they arrive in to disagree — the same reasoning 025 gives
      for building its LIKE pattern into a variable, several notches more
      expensive to get wrong.

      ⚠️ STDistance RETURNS NULL, NOT AN ERROR, when the two instances have
      different SRIDs. Both sides are 4326 — 037's guard asserts the column's,
      and the literal below is the same — and a NULL distance falls out of every
      comparison as unknown, which is why NeedsReview is written as an explicit
      CASE rather than relying on a boolean.

      ⚠️ A CAMPUS WITH NO ANCHOR HAS NO DISTANCE. geography::Point of a NULL is
      NULL, STDistance to NULL is NULL, and NULL > anything is unknown — so it
      reports DistanceKm NULL and NeedsReview 0. Unmeasured, not suspicious.
    */
    ;WITH measured AS
    (
        SELECT
            b.BranchId,
            b.BranchUid,
            b.BranchName,
            b.IsHeadOffice,
            b.SchoolId,
            b.CityId,
            b.AddressLine1,
            b.AddressLine2,
            b.Latitude,
            b.Longitude,
            b.GeocodedLatitude,
            b.GeocodedLongitude,
            b.GeocodedOn,
            b.ModifiedOn,

            d.DistanceMetres,

            /*
              🔴 "CLEARED" IS DERIVED FROM THE TRAIL AND THE CURRENT PIN.

              A CLEAR row whose previous pin EQUALS the pin that is there now.
              038's header has the full argument; the part that matters when
              reading this query is that the judgement LAPSES BY ITSELF when the
              pin moves, with no column to keep in step and no sweep.

              ⚠️ Exact equality, and it is safe because both sides are
              decimal(9,6). The same two facts held as float would make this
              intermittent in the worst way — a campus that reappears on the
              queue sometimes.

              ⚠️ ANY matching CLEAR, not merely the latest log row: a pin
              cleared, moved away and moved back is still the pin an admin
              judged.
            */
            CASE WHEN EXISTS (SELECT 1
                                FROM dbo.t_app_branch_pin_review_log lg
                               WHERE lg.BranchId          = b.BranchId
                                 AND lg.ActionType        = 'CLEAR'
                                 AND lg.PreviousLatitude  = b.Latitude
                                 AND lg.PreviousLongitude = b.Longitude)
                 THEN 1 ELSE 0 END AS IsCleared
          FROM dbo.t_app_school_branches b
         CROSS APPLY (
                SELECT b.GeoPoint.STDistance(
                           geography::Point(CAST(b.GeocodedLatitude AS float),
                                            CAST(b.GeocodedLongitude AS float),
                                            4326)) AS DistanceMetres
              ) d
         WHERE b.Is_Deleted = 0
           /*
             🔴 THE BASE POPULATION IS "CAMPUSES THAT HAVE A PIN", and the
             single-row reads bypass it.

             A pin review has nothing to say about a campus nobody pinned, so
             the list leaves them out — that is what
             IX_t_app_school_branches_PinReview is filtered on. But fetching ONE
             campus by reference must always answer, or the detail panel shows
             nothing for a campus the admin can see elsewhere and the client
             cannot tell that from "not found".
           */
           AND (@IsSingle = 1 OR (b.Latitude IS NOT NULL AND b.Longitude IS NOT NULL))
    ),
    judged AS
    (
        SELECT m.*,
               /*
                 🔴 NEEDS REVIEW = TOO FAR, AND NOT ALREADY JUDGED.

                 NOT the bare comparison. A CLEAR is an admin saying "this
                 campus really is 9km from the address it typed, and that is
                 correct" — a big site with its gate on another road, a village
                 address that geocodes to the panchayat office. If this were
                 only `DistanceKm > ThresholdKm`, that judgement would have
                 nowhere to live and the same campus would be back tomorrow, for
                 ever, which is how a queue stops being worked.
               */
               CASE WHEN m.DistanceMetres > @ThresholdMetres AND m.IsCleared = 0
                    THEN 1 ELSE 0 END AS NeedsReview
          FROM measured m
    )
    SELECT
        /*
          🔴 THE OPAQUE REFERENCE THE CLIENT ECHOES BACK.

          It is the BranchUid rendered as text, and the client is told nothing
          about that: it never builds one, parses one or compares two. So the
          day this desk also lists registrations that have no campus row yet,
          this projection becomes a discriminated string and not one line of
          client code changes.

          ⚠️ A uid and not the bigint BranchId, for 2.39's reason — a surrogate
          key has no business on this boundary — and because a uid is never
          reused even after a soft delete (003), so a stale pinRef from an old
          tab cannot resolve to a different campus.
        */
        CAST(j.BranchUid AS varchar(36)) AS PinRef,

        s.SchoolUid,
        s.SchoolName,
        j.BranchName                     AS CampusName,

        /*
          ⚠️ CAST TO bit IN THE PROJECTION. The column is tinyint, the contract
          is a boolean, and Dapper will only map one to the other if the
          property IS a bool — so the conversion happens here, once, at the one
          place that knows both types (2.61's problem, 034's row-type comment).
        */
        CAST(j.IsHeadOffice AS bit)      AS IsHeadOffice,

        /*
          One line for the screen. CONCAT_WS skips the NULLs, so a campus with
          only line 1 gets line 1 and not "line 1, ".
        */
        NULLIF(LTRIM(RTRIM(CONCAT_WS(N', ',
               NULLIF(LTRIM(RTRIM(j.AddressLine1)), N''),
               NULLIF(LTRIM(RTRIM(j.AddressLine2)), N'')))), N'') AS AddressLine,

        /*
          ⚠️ A CROSS-DATABASE JOIN FOR A CITY NAME, and the precedent is 025's
          USP_SearchJobsForModeration, which does exactly this. 2.2 forbids
          joining jp_app to jp_mdm for BUSINESS data — the geography masters are
          reference data every jp_app read already resolves this way, and the
          alternative is a second round trip to render one label.
        */
        c.Name                           AS CityName,

        /*
          🔴 BOTH PAIRS, LABELLED. The admin has to see WHICH of the two is
          wrong before deciding what to do — a pin dropped in the wrong town is
          a different problem from an address that geocoded badly, and the fix
          differs (move the pin / go back to the school).
        */
        j.Latitude                       AS Latitude,
        j.Longitude                      AS Longitude,
        j.GeocodedLatitude               AS AnchorLatitude,
        j.GeocodedLongitude              AS AnchorLongitude,

        /*
          ⚠️ REPORTED IN KM TO THREE PLACES, COMPARED IN METRES. Comparing the
          rounded value would move the boundary by up to half a metre and make
          the queue disagree with the number beside each row at the edge.
          Rounding is for the screen; NeedsReview used what STDistance said.
        */
        CAST(ROUND(j.DistanceMetres / 1000.0, 3) AS decimal(9, 3)) AS DistanceKm,

        /* 🔴 ON THE ROW, never a client constant. See this file's header. */
        @ThresholdKm                     AS ThresholdKm,

        CAST(j.NeedsReview AS bit)       AS NeedsReview,
        CAST(j.IsCleared   AS bit)       AS IsCleared,

        /*
          ⚠️ THE ANCHOR'S AGE, AND THE CAMPUS'S OWN. 038's header: an address
          edited after its geocode was taken leaves a STALE anchor, and nothing
          can prevent that without re-geocoding on every edit. What an admin can
          do is notice that the anchor predates the last change to the campus —
          so both timestamps are here, beside each other, rather than a derived
          "stale" flag that would have to pick a tolerance.
        */
        j.GeocodedOn                     AS AnchorTakenOn,
        j.ModifiedOn                     AS CampusModifiedOn,

        /*
          The last thing an admin did to this pin, so the row reads as a history
          and not a snapshot. NULL for a campus never touched.

          🔒 THE ACTOR'S ID IS HERE BECAUSE THIS READ IS ADMIN-ONLY — gated on
          MODERATION.CAMPUS_PIN in the service. The SCHOOL-facing read is
          USP_GetCampusPinHistory, which withholds it.
        */
        la.ActionType                    AS LastActionType,
        la.ActionByUserId                AS LastActionByUserId,
        la.ActionOn                      AS LastActionOn
      FROM judged j
      INNER JOIN dbo.t_app_schools s ON s.SchoolId = j.SchoolId
      LEFT  JOIN jp_mdm.dbo.m_mdm_city c ON c.CityId = j.CityId
      OUTER APPLY (
            SELECT TOP (1) lg.ActionType, lg.ActionByUserId, lg.ActionOn
              FROM dbo.t_app_branch_pin_review_log lg
             WHERE lg.BranchId = j.BranchId
             ORDER BY lg.LogId DESC
          ) la
     WHERE s.Is_Deleted = 0
       AND (@BranchUid        IS NULL OR j.BranchUid        = @BranchUid)
       AND (@SourceRequestUid IS NULL
            OR (s.SourceRequestUid = @SourceRequestUid AND j.IsHeadOffice = 1))
       AND (@NeedsReviewOnly = 0 OR j.NeedsReview = 1)
       AND (@IncludeCleared  = 1 OR j.IsCleared   = 0)
       AND (@Like IS NULL OR s.SchoolName LIKE @Like OR j.BranchName LIKE @Like)
     ORDER BY j.NeedsReview DESC,
              j.DistanceMetres DESC,
              j.BranchId
     OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

    /*
      ⚠️ THE TOTAL, THROUGH THE SAME PREDICATE, WRITTEN OUT A SECOND TIME.

      025 does the same and pays the same cost. A view would be a third object
      to keep in step with a threshold that arrives as a parameter, and an
      inline function would be SCHEMABINDING against a table two other files
      alter. The duplication is visible and adjacent, which is the cheapest
      form of it.
    */
    SELECT COUNT(*) AS TotalRecords
      FROM dbo.t_app_school_branches b
      INNER JOIN dbo.t_app_schools s ON s.SchoolId = b.SchoolId
     CROSS APPLY (
            SELECT b.GeoPoint.STDistance(
                       geography::Point(CAST(b.GeocodedLatitude AS float),
                                        CAST(b.GeocodedLongitude AS float),
                                        4326)) AS DistanceMetres
          ) d
     CROSS APPLY (
            SELECT CASE WHEN EXISTS (SELECT 1
                                       FROM dbo.t_app_branch_pin_review_log lg
                                      WHERE lg.BranchId          = b.BranchId
                                        AND lg.ActionType        = 'CLEAR'
                                        AND lg.PreviousLatitude  = b.Latitude
                                        AND lg.PreviousLongitude = b.Longitude)
                        THEN 1 ELSE 0 END AS IsCleared
          ) k
     WHERE b.Is_Deleted = 0
       AND s.Is_Deleted = 0
       AND (@IsSingle = 1 OR (b.Latitude IS NOT NULL AND b.Longitude IS NOT NULL))
       AND (@BranchUid        IS NULL OR b.BranchUid        = @BranchUid)
       AND (@SourceRequestUid IS NULL
            OR (s.SourceRequestUid = @SourceRequestUid AND b.IsHeadOffice = 1))
       AND (@NeedsReviewOnly = 0
            OR (d.DistanceMetres > @ThresholdMetres AND k.IsCleared = 0))
       AND (@IncludeCleared  = 1 OR k.IsCleared = 0)
       AND (@Like IS NULL OR s.SchoolName LIKE @Like OR b.BranchName LIKE @Like);

    /*==========================================================================
      RESULT SET 3 — THE TRAIL, only when asked for.

      ⚠️ SCOPED BY THE SAME TWO REFERENCES, not by "every log row for the page".
      A list call passes @IncludeTrail = 0 and gets nothing here, which is why
      the single reads are the only callers that see it.

      🔴 AND IT IS ALWAYS SENT, EMPTY WHEN NOT ASKED FOR. A procedure that
      returns two result sets sometimes and three others is one a Dapper
      GridReader cannot read without knowing which call it made — and the call
      site that guesses wrong gets a silent empty list rather than an error.
    ==========================================================================*/
    SELECT
        lg.LogId,
        lg.ActionType,
        lg.ActionByUserId,
        lg.ActionOn,
        lg.Remarks,
        lg.PreviousLatitude,
        lg.PreviousLongitude,
        lg.NewLatitude,
        lg.NewLongitude,
        lg.AnchorLatitude,
        lg.AnchorLongitude,
        lg.DistanceMetres,
        CAST(lg.BranchUid AS varchar(36)) AS PinRef
      FROM (
            SELECT l.*, b.BranchUid
              FROM dbo.t_app_branch_pin_review_log l
             INNER JOIN dbo.t_app_school_branches b ON b.BranchId = l.BranchId
             INNER JOIN dbo.t_app_schools s         ON s.SchoolId = b.SchoolId
             WHERE @IncludeTrail = 1
               AND b.Is_Deleted = 0
               AND s.Is_Deleted = 0
               AND (@BranchUid        IS NULL OR b.BranchUid = @BranchUid)
               AND (@SourceRequestUid IS NULL
                    OR (s.SourceRequestUid = @SourceRequestUid AND b.IsHeadOffice = 1))
           ) lg
     ORDER BY lg.LogId DESC;
END
GO

/*==============================================================================
  USP_CorrectCampusPin — the admin moves the pin, and says why.

  🔴 Writes t_app_school_branches' two coordinate columns and ONE log row.
  Nothing else. In particular NOT the anchor — see the guard at the foot.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_CorrectCampusPin
    @BranchUid   uniqueidentifier,
    @Latitude    decimal(9, 6),
    @Longitude   decimal(9, 6),
    @Remarks     nvarchar(1000),
    @ActorUserId bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @BranchId  bigint        = NULL,
            @PrevLat   decimal(9, 6) = NULL,
            @PrevLng   decimal(9, 6) = NULL,
            @AnchorLat decimal(9, 6) = NULL,
            @AnchorLng decimal(9, 6) = NULL,
            @Distance  int           = NULL,
            @Now       datetime2     = SYSUTCDATETIME();

    SELECT @BranchId  = b.BranchId,
           @PrevLat   = b.Latitude,
           @PrevLng   = b.Longitude,
           @AnchorLat = b.GeocodedLatitude,
           @AnchorLng = b.GeocodedLongitude
      FROM dbo.t_app_school_branches b
     WHERE b.BranchUid  = @BranchUid
       AND b.Is_Deleted = 0;

    /*
      ⚠️ A deleted or unknown campus is NOT_FOUND, never FORBIDDEN (2.6). The
      caller already holds MODERATION.CAMPUS_PIN — there is nothing to protect
      by being vague, and "not found" is simply true. 025's reasoning, verbatim.
    */
    IF @BranchId IS NULL
    BEGIN
        SELECT Status = 0, Code = 'NOT_FOUND', Id = NULL,
               [Message] = N'That campus was not found.';
        RETURN;
    END

    /*
      🔴 BOTH COORDINATES OR NEITHER — and "neither" is not expressible here at
      all. A correction that sets a latitude and leaves the longitude alone
      produces a half-moved pin: a point on the right line of latitude, in the
      wrong place, which is worse than the pin it replaced because it looks
      deliberate.

      ⚠️ AND CLEARING IS NOT THIS PROCEDURE WITH NULLS. See USP_ClearCampusPin.
    */
    IF @Latitude IS NULL OR @Longitude IS NULL
    BEGIN
        SELECT Status = 0, Code = 'VALIDATION_FAILED', Id = NULL,
               [Message] = N'A corrected pin needs both a latitude and a longitude.';
        RETURN;
    END

    /*
      ⚠️ RANGE-CHECKED HERE, because geography::Point RAISES on an out-of-range
      latitude rather than returning NULL — and it would raise inside the
      PERSISTED computed column's evaluation during the UPDATE, surfacing as a
      constraint-shaped error naming a column the caller never sent. This turns
      it into a sentence somebody can act on.

      ⚠️ decimal(9,6) cannot hold 1000 anyway (three digits before the point),
      so this catches the realistic mistake: a longitude pasted into the
      latitude box. 95.0 is a valid longitude and an invalid latitude, and every
      coordinate in India has a longitude out of latitude range.
    */
    IF @Latitude NOT BETWEEN -90 AND 90
    BEGIN
        SELECT Status = 0, Code = 'VALIDATION_FAILED', Id = NULL,
               [Message] = N'A latitude is between -90 and 90. Check the two values are not the wrong way round.';
        RETURN;
    END

    IF @Longitude NOT BETWEEN -180 AND 180
    BEGIN
        SELECT Status = 0, Code = 'VALIDATION_FAILED', Id = NULL,
               [Message] = N'A longitude is between -180 and 180.';
        RETURN;
    END

    /*
      🔴 CORRECTING A PIN TO WHERE IT ALREADY IS IS REFUSED.

      Not pedantry — it is the difference between the two actions this feature
      has. Posting the unchanged pin back through this procedure would write a
      CORRECT row recording a move that did not happen, and the trail would then
      read "corrected by X" about somebody who deliberately did not move
      anything. Judging a distance acceptable is USP_ClearCampusPin, and the
      message says so.
    */
    IF @PrevLat = @Latitude AND @PrevLng = @Longitude
    BEGIN
        SELECT Status = 0, Code = 'VALIDATION_FAILED', Id = NULL,
               [Message] = N'That is where the pin already is. To record that the distance is correct, clear it for review instead.';
        RETURN;
    END

    /*
      🔴 REMARKS ARE REQUIRED. 025's floor, for 025's reason: the school is
      entitled to know why its own figure was overwritten, and a correction
      nobody can explain is the one that becomes an argument later. The column
      has a CHECK too; this is the half that produces a clean refusal rather
      than a constraint violation.
    */
    IF LEN(LTRIM(RTRIM(ISNULL(@Remarks, N'')))) = 0
    BEGIN
        SELECT Status = 0, Code = 'REMARKS_REQUIRED', Id = NULL,
               [Message] = N'Say why this pin is being corrected — the school is shown this.';
        RETURN;
    END

    /*
      The distance that justified the correction, recorded as it stood. NULL
      when the campus has no anchor (nothing to measure) or had no pin.

      ⚠️ COMPUTED FROM THE PREVIOUS PIN, not the new one. The log answers "how
      wrong was it"; measuring the corrected pin would record a few metres for
      every correction ever made.

      ⚠️ The two points go into variables before STDistance is called on one of
      them. A method invoked directly on a function result is not something this
      file relies on being legal — a variable is unambiguous and costs nothing.
    */
    IF @PrevLat IS NOT NULL AND @AnchorLat IS NOT NULL
    BEGIN
        DECLARE @prevPoint   geography = geography::Point(CAST(@PrevLat   AS float), CAST(@PrevLng   AS float), 4326);
        DECLARE @anchorPoint geography = geography::Point(CAST(@AnchorLat AS float), CAST(@AnchorLng AS float), 4326);

        SET @Distance = CAST(ROUND(@prevPoint.STDistance(@anchorPoint), 0) AS int);
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        /*
          ⚠️ THE LOG ROW FIRST, so the previous pin is recorded before it is
          overwritten. 025's ordering, for 025's reason: the other order works
          too and reads as though the branch row were the source of truth for
          what it used to be.
        */
        INSERT INTO dbo.t_app_branch_pin_review_log
            (BranchId, ActionType,
             PreviousLatitude, PreviousLongitude,
             NewLatitude, NewLongitude,
             AnchorLatitude, AnchorLongitude,
             DistanceMetres, Remarks, ActionByUserId, ActionOn)
        VALUES
            (@BranchId, 'CORRECT',
             @PrevLat, @PrevLng,
             @Latitude, @Longitude,
             @AnchorLat, @AnchorLng,
             @Distance, LTRIM(RTRIM(@Remarks)), @ActorUserId, @Now);

        /*
          🔴 TWO COLUMNS, AND THE BOOKKEEPING. The anchor is NOT touched: see
          the guard at the foot of this file for why that is asserted rather
          than trusted.

          ⚠️ RowVersion IS BUMPED BUT NOT CHECKED, and that is a decision.
          USP_SaveBranch requires a RowVersion because a school editing its own
          campus has just read it. An admin acting on a QUEUE row has not — a
          queue is stale by nature, and requiring a version would mean
          re-reading every campus between opening the screen and acting on it.
          What protects the school is the log: the pin it set is recorded, so a
          clobbered edit is visible and reversible rather than lost. Bumping the
          version means the school's own next save gets a clean
          CONCURRENCY_CONFLICT instead of silently winning.

          ⚠️ GeoPoint (037) is NOT in this SET list and must never be — it is a
          computed column, and SQL Server recomputes and re-persists it as part
          of this UPDATE.
        */
        UPDATE dbo.t_app_school_branches
           SET Latitude   = @Latitude,
               Longitude  = @Longitude,
               RowVersion = RowVersion + 1,
               ModifiedOn = @Now,
               ModifiedBy = @ActorUserId
         WHERE BranchId   = @BranchId
           AND Is_Deleted = 0;

        COMMIT TRANSACTION;

        SELECT Status = 1, Code = NULL, Id = @BranchId,
               [Message] = N'The campus pin has been corrected.';
    END TRY
    BEGIN CATCH
        DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        DECLARE @Params nvarchar(max) = (
            SELECT @BranchUid AS branchUid, @Latitude AS latitude, @Longitude AS longitude
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
             @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
             @ErrorMessage = @ErrMessage, @ParametersJson = @Params,
             @ContextInfo = N'USP_CorrectCampusPin', @CreatedBy = @ActorUserId;

        SELECT Status = 0, Code = 'CORRECT_PIN_FAILED', Id = NULL, [Message] = @ErrMessage;
    END CATCH
END
GO

/*==============================================================================
  USP_ClearCampusPin — the admin judges the distance correct, and MOVES NOTHING.

  ---------------------------------------------------------------------------
  🔴 A CLEAR DOES NOT TOUCH t_app_school_branches. NOT ONE COLUMN.
  ---------------------------------------------------------------------------
  This is the half that is easy to get wrong, so it is stated before the code:
  clearing a campus for review means "the pin the school set is right, and the
  distance from its stated address is explained by the real world". A big site
  with its gate on another road. A village address that geocodes to the
  panchayat office. A boarding school whose postal address is its city office.

  So this procedure writes ONE log row and makes no UPDATE at all — no
  coordinates, no RowVersion, no ModifiedOn. The campus is exactly as the school
  left it, which is the point: nothing was corrected.

  ⚠️ AND IT IS NOT "CORRECT WITH THE SAME COORDINATES". That would write a
  CORRECT row describing a move that did not happen, bump the school's
  RowVersion for nothing, and leave the trail saying "corrected by X" about
  somebody who deliberately did not move anything. USP_CorrectCampusPin refuses
  an unchanged pin for exactly this reason and points the caller here.

  ⚠️ HOW THE CAMPUS THEN LEAVES THE QUEUE: it does not leave the TABLE, it
  stops NEEDING REVIEW. USP_SearchCampusPinReview derives that from this log
  row — a CLEAR whose previous pin equals the pin that is there now (038's
  header) — so the judgement lapses by itself if the school later moves the pin,
  with no column to go stale and no sweep to forget to run.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_ClearCampusPin
    @BranchUid   uniqueidentifier,
    @Remarks     nvarchar(1000),
    @ActorUserId bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @BranchId  bigint        = NULL,
            @PinLat    decimal(9, 6) = NULL,
            @PinLng    decimal(9, 6) = NULL,
            @AnchorLat decimal(9, 6) = NULL,
            @AnchorLng decimal(9, 6) = NULL,
            @Distance  int           = NULL,
            @Now       datetime2     = SYSUTCDATETIME();

    SELECT @BranchId  = b.BranchId,
           @PinLat    = b.Latitude,
           @PinLng    = b.Longitude,
           @AnchorLat = b.GeocodedLatitude,
           @AnchorLng = b.GeocodedLongitude
      FROM dbo.t_app_school_branches b
     WHERE b.BranchUid  = @BranchUid
       AND b.Is_Deleted = 0;

    IF @BranchId IS NULL
    BEGIN
        SELECT Status = 0, Code = 'NOT_FOUND', Id = NULL,
               [Message] = N'That campus was not found.';
        RETURN;
    END

    /*
      🔴 THERE MUST BE A PIN TO JUDGE.

      A clear says "THIS pin is correct". With no pin there is nothing to say it
      about, the log row could not name the pin it judged — which is how the
      read derives "cleared" — and CK_..._Result would refuse the INSERT anyway.
      Refused here so the caller gets a sentence instead of a constraint.
    */
    IF @PinLat IS NULL OR @PinLng IS NULL
    BEGIN
        SELECT Status = 0, Code = 'NO_PIN', Id = NULL,
               [Message] = N'That campus has no pin, so there is no distance to judge.';
        RETURN;
    END

    /*
      ⚠️ CLEARING AN ALREADY-CLEARED PIN IS REFUSED RATHER THAN IGNORED.

      025 refuses to pull an already-pulled job for the structural reason that
      the log must not describe a state the row was never in. Here the cost is
      different and just as real: a second identical CLEAR row adds nothing a
      reader can use and makes the trail look like somebody kept changing their
      mind. The match is on the exact pin, so a clear after the school MOVED the
      pin is a new judgement and is allowed.
    */
    IF EXISTS (SELECT 1
                 FROM dbo.t_app_branch_pin_review_log lg
                WHERE lg.BranchId          = @BranchId
                  AND lg.ActionType        = 'CLEAR'
                  AND lg.PreviousLatitude  = @PinLat
                  AND lg.PreviousLongitude = @PinLng)
    BEGIN
        SELECT Status = 0, Code = 'ALREADY_CLEARED', Id = NULL,
               [Message] = N'This pin has already been cleared for review.';
        RETURN;
    END

    IF LEN(LTRIM(RTRIM(ISNULL(@Remarks, N'')))) = 0
    BEGIN
        SELECT Status = 0, Code = 'REMARKS_REQUIRED', Id = NULL,
               [Message] = N'Say why this distance is correct — the school is shown this.';
        RETURN;
    END

    IF @AnchorLat IS NOT NULL
    BEGIN
        DECLARE @pinPoint    geography = geography::Point(CAST(@PinLat    AS float), CAST(@PinLng    AS float), 4326);
        DECLARE @anchorPoint geography = geography::Point(CAST(@AnchorLat AS float), CAST(@AnchorLng AS float), 4326);

        SET @Distance = CAST(ROUND(@pinPoint.STDistance(@anchorPoint), 0) AS int);
    END

    BEGIN TRY
        /*
          ⚠️ NO TRANSACTION, AND THAT IS NOT AN OMISSION. There is exactly ONE
          statement — see this procedure's header. A BEGIN TRANSACTION around a
          single INSERT reads as though a second write were coming and invites
          somebody to add one without noticing there is nothing holding them
          together.
        */
        INSERT INTO dbo.t_app_branch_pin_review_log
            (BranchId, ActionType,
             PreviousLatitude, PreviousLongitude,
             NewLatitude, NewLongitude,
             AnchorLatitude, AnchorLongitude,
             DistanceMetres, Remarks, ActionByUserId, ActionOn)
        VALUES
            (@BranchId, 'CLEAR',
             @PinLat, @PinLng,            -- the pin being judged correct
             NULL, NULL,                  -- a clear SETS nothing (CK_..._Result)
             @AnchorLat, @AnchorLng,
             @Distance, LTRIM(RTRIM(@Remarks)), @ActorUserId, @Now);

        SELECT Status = 1, Code = NULL, Id = @BranchId,
               [Message] = N'The distance has been recorded as correct. The campus pin is unchanged.';
    END TRY
    BEGIN CATCH
        DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        DECLARE @Params nvarchar(max) = (
            SELECT @BranchUid AS branchUid
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
             @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
             @ErrorMessage = @ErrMessage, @ParametersJson = @Params,
             @ContextInfo = N'USP_ClearCampusPin', @CreatedBy = @ActorUserId;

        SELECT Status = 0, Code = 'CLEAR_PIN_FAILED', Id = NULL, [Message] = @ErrMessage;
    END CATCH
END
GO

/*==============================================================================
  USP_GetCampusPinHistory — the trail, for the SCHOOL as well as the admin.

  🔴 THE SAME ROWS FOR BOTH, with one exception named below. The remarks are
  written to be shown; what differs is who may call it, which is the API's
  business — 025's rule.

  ⚠️ This is NOT the trail USP_SearchCampusPinReview's third result set
  returns. That one is the admin desk's, reached with the threshold and the
  whole row; this one is the school's own, reached from its campus screen with
  nothing but its organisation uid. One procedure serving both would have to
  take the threshold it does not need in order to answer a question about
  history, and the school-facing caller would be passing a configured number
  into a read that must not depend on one.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetCampusPinHistory
    @BranchUid       uniqueidentifier,

    /*
      🔒 THE SCHOOL'S OWN COPY IS SCOPED HERE, NOT IN C#.

      An admin calls this with NULL and sees any campus's history. A school
      calls it with its own organisation uid, and a campus that is not theirs
      returns ZERO ROWS — which the API turns into the same 404 a campus that
      never existed gives (2.6).

      ⚠️ The scoping lives in the procedure because that is where the rule can
      only be written once. A C# ownership check beside an unscoped procedure is
      a second answer to the same question, and the day they disagree the
      lenient one wins — which here would mean one school reading another's
      correction remarks.
    */
    @OrganizationUid uniqueidentifier = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        l.LogId,
        l.ActionType,
        l.Remarks,
        l.ActionOn,

        l.PreviousLatitude,
        l.PreviousLongitude,
        l.NewLatitude,
        l.NewLongitude,
        l.AnchorLatitude,
        l.AnchorLongitude,
        l.DistanceMetres,

        /*
          🔒 THE ACTOR, TO THE ADMIN ONLY.

          ⚠️ A DELIBERATE DEVIATION FROM 025, STATED. USP_GetJobModerationHistory
          projects no actor at all, on the reasoning that a school does not need
          to know which administrator pulled its advert — and its comment then
          says "the admin's own screen joins the user table itself", which that
          screen cannot do, because the id is not in the result set either. The
          rule was right and the implementation left the admin desk with
          nothing.

          So the rule is kept and the gap is not: the id is projected when the
          caller is an admin (@OrganizationUid IS NULL) and NULL when the caller
          is a school. One projection, one condition, and a school still cannot
          learn which person moved its pin and go after them directly.
        */
        CASE WHEN @OrganizationUid IS NULL THEN l.ActionByUserId END AS ActionByUserId
      FROM dbo.t_app_branch_pin_review_log l
      INNER JOIN dbo.t_app_school_branches b ON b.BranchId = l.BranchId
      INNER JOIN dbo.t_app_schools sc        ON sc.SchoolId = b.SchoolId
     WHERE b.BranchUid  = @BranchUid
       AND b.Is_Deleted = 0
       AND (@OrganizationUid IS NULL OR sc.OrganizationUid = @OrganizationUid)
     ORDER BY l.LogId DESC;
END
GO

/*==============================================================================
  BUILD GUARDS

  ⚠️ ALL THREE HAVE THESE PROCEDURES AS THEIR SUBJECT, which is why they are
  here and not in 999_cross_file_guards.sql. The rule whose subject is EVERY
  procedure — "nothing but these two may write the log" — is in 999, where it
  can be judged, and 999's header is the incident that proved a whole-set guard
  cannot live beside one file.
==============================================================================*/

/*
  🔴 A PIN ACTION MUST NOT MOVE THE ANCHOR. THIS IS THE LOAD-BEARING ONE.

  If USP_CorrectCampusPin could write GeocodedLatitude/GeocodedLongitude, the
  cheapest way to clear the review queue would be to move the anchor to the pin
  — the distance would come out 0, the campus would leave the list, and the log
  would record a correction that corrected nothing. The queue would clear itself
  by moving the goalposts, and every number in it would be true.

  The anchor is the geocode of what the SCHOOL STATED. It changes when the
  address changes and is re-geocoded (SR-3's path), never when somebody
  disagrees with a pin.

  Checked by DEPENDENCY at COLUMN granularity: sys.dm_sql_referenced_entities
  carries referenced_minor_name and is_updated, which the dependency VIEW does
  not — so this asserts what the server compiled rather than what the text looks
  like (025's lesson, where a guard matched its own prose).

  ⚠️ AND ITS LIMIT, STATED: the DMV reports column granularity only while the
  module's references all resolve. If it ever reports a whole-table row with a
  NULL minor name instead, this guard passes rather than fires — a false
  negative, never a false positive. Deliberate: a guard that fails the build on
  its own blind spot is a guard somebody deletes.

  Proven to fire: adding "GeocodedLatitude = @Latitude" to the UPDATE in
  USP_CorrectCampusPin fails this and names the column.
*/
DECLARE @anchorWriters nvarchar(1000) = N'';

SELECT @anchorWriters = STRING_AGG(
           CAST(x.ProcName AS nvarchar(128)) + N'.' + CAST(x.ColumnName AS nvarchar(128)), N', ')
  FROM (
        SELECT 'USP_CorrectCampusPin' AS ProcName, r.referenced_minor_name AS ColumnName
          FROM sys.dm_sql_referenced_entities('dbo.USP_CorrectCampusPin', 'OBJECT') r
         WHERE r.referenced_entity_name = 't_app_school_branches'
           AND r.referenced_minor_name IN ('GeocodedLatitude', 'GeocodedLongitude', 'GeocodedOn')
           AND r.is_updated = 1
        UNION ALL
        SELECT 'USP_ClearCampusPin', r.referenced_minor_name
          FROM sys.dm_sql_referenced_entities('dbo.USP_ClearCampusPin', 'OBJECT') r
         WHERE r.referenced_entity_name = 't_app_school_branches'
           AND r.referenced_minor_name IN ('GeocodedLatitude', 'GeocodedLongitude', 'GeocodedOn')
           AND r.is_updated = 1
       ) x;

IF ISNULL(@anchorWriters, N'') <> N''
BEGIN
    DECLARE @anchorMsg nvarchar(1400) =
        N'028_branch_pin_review: 🔴 A PIN PROCEDURE WRITES THE ANCHOR: '
        + @anchorWriters
        + N'. The anchor is the geocode of the address the SCHOOL STATED. An action that moves it '
        + N'clears the review queue by moving the goalposts — distance 0, campus gone from the list, '
        + N'and a log row recording a correction that corrected nothing. See this guard''s comment.';

    RAISERROR('%s', 16, 1, @anchorMsg);
END
GO

/*
  🔴 CLEARING MUST NOT MOVE THE PIN EITHER, AND THAT IS THE WHOLE DISTINCTION.

  A CLEAR records a judgement; a CORRECT changes a value. If USP_ClearCampusPin
  could write Latitude or Longitude, the two actions would become one with a
  different log label, and the trail's only honest claim — "nobody moved this,
  somebody judged it" — would stop being true while still being recorded.

  ⚠️ This asserts that USP_ClearCampusPin writes NOTHING on the branch at all,
  not merely that it leaves the coordinates alone: it must not bump RowVersion
  or ModifiedOn either, because a school's optimistic-concurrency check would
  then fail over an action that changed none of its data (see this procedure's
  header).

  Proven to fire: adding "Latitude = @PinLat" to a new UPDATE in
  USP_ClearCampusPin fails this.
*/
IF EXISTS (SELECT 1
             FROM sys.dm_sql_referenced_entities('dbo.USP_ClearCampusPin', 'OBJECT')
            WHERE referenced_entity_name = 't_app_school_branches'
              AND is_updated = 1)
    RAISERROR('028_branch_pin_review: 🔴 USP_ClearCampusPin WRITES to t_app_school_branches. A clear records a JUDGEMENT and changes nothing — not the coordinates, not RowVersion, not ModifiedOn. See this procedure''s header: if it could move the pin, CORRECT and CLEAR would be one action with two labels.', 16, 1);
GO

/*
  🔒 THE DESK READS. IT DOES NOT WRITE.

  025's second guard, on this file's read: a queue is a report, and a report
  that can change the rows it reports on is one whose numbers cannot be trusted
  the second time somebody opens it.

  ⚠️ is_updated again, for the reason 025 gives: it is 1 for an entity a module
  writes and 0 for one it only reads, and the dependency view does not carry it.

  Proven to fire BOTH WAYS before being trusted, the way 025's was: a probe
  procedure selecting from t_app_school_branches reports is_updated = 0, and one
  containing an UPDATE of ModifiedOn guarded by WHERE 1 = 0 reports 1 — so this
  is not a check that can only pass.
*/
IF EXISTS (SELECT 1
             FROM sys.dm_sql_referenced_entities('dbo.USP_SearchCampusPinReview', 'OBJECT')
            WHERE referenced_entity_name IN
                  ('t_app_school_branches', 't_app_schools', 't_app_branch_pin_review_log')
              AND is_updated = 1)
    RAISERROR('028_branch_pin_review: 🔒 USP_SearchCampusPinReview WRITES to data it reports on. The desk is a report over a DERIVED verdict (038''s header) — it must not be able to change a pin, a school or the trail.', 16, 1);
GO

PRINT '    Campus pin review procedures ready.';
GO
