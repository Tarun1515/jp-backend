/*==============================================================================
  jp_app — 04_procedures / 013_entitlement.sql

  The entitlement engine: the period function, the atomic consume, reversal,
  credit grants, and the balance read. Phase 2.5.

  Governed by jp-docs/MONETIZATION_DESIGN.md.

  ---------------------------------------------------------------------------
  🔴 THE PROHIBITION THIS ENGINE CARRIES EVERYWHERE (2.56 — LOCKED)
  ---------------------------------------------------------------------------
  The entitlement engine and contact unlock never reference each other, in
  either direction.

  Nothing in this file may be called from fn_TeacherContactUnlocked, and that
  function's two paths — the teacher applied, or accepted an invitation — may
  never be consulted here. A subscription buys CAPABILITY: whether a school may
  search at all, how many invites it may send. It never buys a teacher's phone
  number or email.

  If a requirement seems to need a plan check inside contact unlock, the
  requirement is being described wrongly: what is sold is reach, and reach is
  invites.

  ---------------------------------------------------------------------------
  ⚠️ WHY PART OF THE PRECEDENCE LIVES IN THE API AND NOT IN HERE
  ---------------------------------------------------------------------------
  Features and plan mappings are in jp_mdm; subscriptions and the ledger are
  here. Neither database may join to the other (2.2), so the first step of the
  precedence — does the feature exist, is its kill switch off, what is its mode
  and this plan's quota — is resolved by IEntitlementRepository in ONE query
  against jp_mdm, and passed in as parameters.

  🔴 That split is forced by 2.2, and it does NOT mean "the rule lives in the
  UI". Both halves are server-side and both sit behind IEntitlementService,
  which is the only public way to reach either. No screen and no controller may
  hand-roll "does this plan include the feature" — one place decides
  entitlement.

  ⚠️ And that jp_mdm read is NEVER served from the master cache, today or ever.
  See MONETIZATION_DESIGN.md, "Gating reads never come from the master cache":
  an hour of lag would mean a kill switch that engages an hour after the
  operator flips it, during exactly the incident it was flipped for.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  fn_QuotaPeriodForUtc — the IST calendar month containing a UTC instant.

  ---------------------------------------------------------------------------
  🔴 THE SINGLE POINT OF TRUTH FOR PERIOD BOUNDARIES
  ---------------------------------------------------------------------------
  Quota is DERIVED — used = count of quota consumes inside this window — and
  there is no reset job. The design accepts exactly one single point of failure
  in exchange for having no scheduler, and this function is it. No caller
  computes a month boundary by hand.

  Half-open: [PeriodFromUtc, PeriodToUtc). Always filter
  `>= FromUtc AND < ToUtc`; BETWEEN on datetime2 silently drops everything
  after 00:00:00 on the final day.

  ---------------------------------------------------------------------------
  ⚠️ WHY UTC AND IST DISAGREE ABOUT THE MONTH FOR 5.5 HOURS A DAY
  ---------------------------------------------------------------------------
  An IST day starts at 18:30 UTC the previous day. So:

      2026-08-31 18:29 UTC  ->  31 Aug IST  ->  the AUGUST period
      2026-08-31 18:30 UTC  ->  1 Sep IST   ->  the SEPTEMBER period

  A consume at 18:30 UTC on the 31st belongs to next month's quota. Using
  CAST(SYSUTCDATETIME() AS date) would put it in the wrong one — and the
  symptom is a customer who is refused on the 1st because five and a half hours
  of the previous evening ate this month's allowance.

  Inline TVF, so it expands into the calling query with no execution overhead.

  ---------------------------------------------------------------------------
  ⚠️ WHY THIS SPELLS OUT THE ±330 RATHER THAN CALLING fn_IstDateToUtc
  ---------------------------------------------------------------------------
  Two reasons, and the first is not stylistic.

  1. SCHEMABINDING would make this function a dependent of fn_IstDateToUtc, and
     SQL Server then refuses to CREATE OR ALTER that function while this one
     exists (Msg 3729). 000_fn_datetime_ist.sql is a SHARED file — the same body
     runs in all three databases — and it has to stay re-runnable, because
     run_all.sql is re-run constantly and must create zero objects the second
     time. Breaking that in jp_app alone, for one engine function, trades a
     property of the whole build for a local tidiness.

     🔴 This was found by re-running run_all, not by reasoning about it: the
     first version called fn_IstDateToUtc, built clean, and failed on the
     second pass.

  2. It is what the IST helpers already do. fn_IstDayRangeUtc does not call
     fn_IstDateToUtc either — it writes the DATEADD out. All four spell the
     offset themselves, so this is the house pattern rather than a departure
     from it.

  The offset is a constant of geography, not a policy: IST is UTC+05:30 with no
  daylight saving, ever. There is no scenario where these two copies need to
  disagree, and 2.28 is where the number is decided.
==============================================================================*/
CREATE OR ALTER FUNCTION dbo.fn_QuotaPeriodForUtc (@utc datetime2)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT
        -- Same arithmetic as fn_IstDateToUtc: an IST day starts 330 minutes
        -- before its own midnight, i.e. at 18:30 UTC the previous day.
        DATEADD(MINUTE, -330, CAST(m.FirstOfMonth AS datetime2))                    AS PeriodFromUtc,
        DATEADD(MINUTE, -330, CAST(DATEADD(MONTH, 1, m.FirstOfMonth) AS datetime2)) AS PeriodToUtc,
        m.FirstOfMonth                                                              AS PeriodFirstIstDate
    FROM (
        SELECT DATEFROMPARTS(YEAR(i.IstDate), MONTH(i.IstDate), 1) AS FirstOfMonth
        FROM (
            -- The IST calendar date of this instant. 330 = UTC+05:30, never DST.
            SELECT CAST(DATEADD(MINUTE, 330, @utc) AS date) AS IstDate
        ) i
    ) m;
GO


/*==============================================================================
  USP_ConsumeFeature — the one atomic entitlement decision.

  Returns (2.21): Status / Code / Message / Id, plus the engine's own columns.

  ---------------------------------------------------------------------------
  🔴 CHECK-THEN-CONSUME IS FORBIDDEN
  ---------------------------------------------------------------------------
  There is no "may I?" call. Asking and acting in two round trips means two
  sessions can both be told yes for the same last unit. This procedure decides
  and records inside one transaction, and the loser of a race receives a
  refusal with its own Code.

  ---------------------------------------------------------------------------
  🔴 UPDLOCK, HOLDLOCK ON THE SUBSCRIPTION ROW IS THE WHOLE MECHANISM
  ---------------------------------------------------------------------------
  It makes read-decide-write a single critical section PER OWNER, so the last
  unit has exactly one winner without a counter table — that is, without a
  second place where the truth lives and can drift.

  HOLDLOCK matters as much as UPDLOCK: on an owner with no subscription row it
  takes a range lock, so two sessions cannot both pass the missing-row branch
  while a row is being inserted between them.

  ⚠️ The cost, accepted: consumes for one owner serialise across ALL features.
  A school posting a handful of jobs a day will never notice. The upgrade, if
  one is ever needed, is in the design doc — and it is rejected for MVP because
  it reintroduces a number that must be reconciled.

  ---------------------------------------------------------------------------
  🔴 ONE CONSUME NEVER SPLITS ACROSS QUOTA AND CREDITS
  ---------------------------------------------------------------------------
  Not a preference — it is forced by Decision 5. The idempotency index is
  UNIQUE on (FeatureId, RefEntityTypeId, RefEntityUid) for live consumes, so
  one action gets exactly one row, and one row carries exactly one SourceId.

  So for @Units > 1: quota must cover the whole amount, or credits must, or the
  request is refused. It cannot take three from quota and two from credits.

  ⚠️ This interaction is not spelled out in the design doc and was found while
  building. It is harmless at @Units = 1, which is every caller today, and the
  alternative — allowing a split — would mean either two rows for one reference
  (which the index forbids) or a nullable second source column (which makes
  every balance query two-sided). Recorded rather than silently assumed.
==============================================================================*/
/*------------------------------------------------------------------------------
  🔴 CORE + WRAPPER, AND WHY IT IS SPLIT THAT WAY (Phase 4)

  The decision lives in USP_ConsumeFeatureCore, which reports through OUTPUT
  parameters. USP_ConsumeFeature is a thin wrapper that calls it and SELECTs the
  result set — so the contract Phase 2.5 shipped and tested is byte-for-byte
  unchanged.

  The split exists because USP_PublishJob has to CALL the consume from inside
  its own transaction. Capturing a result set means INSERT ... EXEC, and that
  carries two limits that only appear at runtime:

    - INSERT ... EXEC cannot nest, so anything wrapping the publish would fail;
    - a ROLLBACK inside an INSERT ... EXEC is illegal outright (Msg 3915) —
      which is exactly what the refusal path does.

  🔴 Both were found by running it, not by reading the documentation: the first
  version of the publish used INSERT ... EXEC, and the smoke test died on Msg
  3915 the first time a consume was attempted.

  OUTPUT parameters have neither limit. Nothing about the engine's behaviour
  changed — only how its answer is handed back.
------------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE dbo.USP_ConsumeFeatureCore
    @OwnerUid         uniqueidentifier,
    @FeatureId        int,

    /*
      Resolved from jp_mdm by IEntitlementRepository, in one query, on every
      call. 1 = FREE, 2 = BOOLEAN, 3 = METERED.

      ⚠️ FEATURE_DISABLED is decided BEFORE this procedure is reached — the
      feature's Is_Active lives in the other database. See the file header.
    */
    @GatingModeId     tinyint,
    @HasMapping       tinyint,
    @IsIncluded       tinyint          = 0,
    @QuotaPerPeriod   int              = NULL,   -- NULL = unlimited within plan

    /*
      🔴 THE PLAN THE CALLER RESOLVED AGAINST — the guard on a real race.

      The service must read the subscription to learn the PlanId BEFORE it can
      look up that plan's mapping in jp_mdm (the databases cannot join, 2.2).
      That read is not under this procedure's lock, so between it and the lock
      below the owner's plan can change — an upgrade, a support correction —
      and the quota handed in would belong to the plan they are no longer on.

      Passing it back and comparing under the lock turns a silent mispricing
      into PLAN_CHANGED, which the service answers by re-resolving and retrying
      exactly once.

      ⚠️ Optional so the SQL test suite can call the procedure directly without
      restating the plan it just read. Production callers always pass it.
    */
    @ExpectedPlanId   int              = NULL,

    @Units            int              = 1,
    @RefEntityTypeId  tinyint          = NULL,
    @RefEntityUid     uniqueidentifier = NULL,
    @Notes            nvarchar(400)    = NULL,
    @ActorUserId      bigint           = NULL,

    -- The answer. Identical in meaning to the columns the wrapper SELECTs.
    @Status           int              OUTPUT,
    @Code             varchar(50)      OUTPUT,
    @Message          nvarchar(400)    OUTPUT,
    @EntryId          bigint           OUTPUT,
    @Consumed         tinyint          OUTPUT,
    @SourceId         tinyint          OUTPUT,
    @QuotaUsed        int              OUTPUT,
    @QuotaRemaining   int              OUTPUT,
    @CreditBalance    int              OUTPUT,
    @PeriodFromUtc    datetime2        OUTPUT,
    @PeriodToUtc      datetime2        OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT @Status = 0, @Code = NULL, @Message = NULL, @EntryId = NULL,
           @Consumed = 0, @SourceId = NULL, @QuotaUsed = NULL,
           @QuotaRemaining = NULL, @CreditBalance = NULL,
           @PeriodFromUtc = NULL, @PeriodToUtc = NULL;

    DECLARE @SubscriptionId bigint           = NULL,
            @SubStatusId    int              = NULL,
            @SubIsActive    tinyint          = NULL,
            @SubEndsOn      datetime2        = NULL,
            @PlanIdOnSub    int              = NULL,

            -- The already-charged row, if this reference has one. See the
            -- idempotency block inside the transaction.
            @ExistingEntryId  bigint  = NULL,
            @ExistingSourceId tinyint = NULL;

    -- One instant for the whole decision. Reading the clock twice inside a
    -- transaction can straddle a period boundary and count against two months.
    DECLARE @Now datetime2 = SYSUTCDATETIME();

    IF @Units IS NULL OR @Units < 1
    BEGIN
        SELECT @Status = 0, @Code = 'VALIDATION_FAILED',
               @Message = N'Units must be at least 1.';
        RETURN;
    END

    /*
      A metered consume MUST carry a reference. Without one the idempotency
      index has nothing to protect and a retried request charges twice —
      which is the failure this whole design exists to prevent.
    */
    IF @GatingModeId = 3 AND (@RefEntityTypeId IS NULL OR @RefEntityUid IS NULL)
    BEGIN
        SELECT @Status = 0, @Code = 'VALIDATION_FAILED',
               @Message = N'A metered consume must carry a reference to what it is for.';
        RETURN;
    END

    /*
      🔴 NESTING DISCIPLINE — added in Phase 4, and it is load-bearing there.

      USP_PublishJob calls this procedure from INSIDE its own transaction, so
      that a publish and its consume are one atomic act: a refused consume
      leaves the job in Draft, and a publish that fails after consuming leaves
      no ledger row.

      T-SQL has no real nested transactions — an inner COMMIT only decrements
      @@TRANCOUNT, and an inner ROLLBACK destroys the OUTER transaction. So a
      procedure that unconditionally BEGINs and COMMITs is safe alone and
      quietly wrong when nested: its ROLLBACK on the 2601 path would tear down
      the caller's transaction, and the caller would then COMMIT something that
      no longer exists.

      The rule: only the procedure that OPENED the transaction may end it.
      Nested, this one does its work and leaves the outcome to the caller —
      including, on an error, re-throwing so the caller's CATCH rolls back.

      ⚠️ Phase 2.5's two suites are the proof this changed nothing when the
      procedure is called on its own: @OwnsTran is 1 in every one of those
      calls, which is exactly the old behaviour.
    */
    DECLARE @OwnsTran bit = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    BEGIN TRY
        IF @OwnsTran = 1 BEGIN TRANSACTION;

        /*
          🔴 THE CRITICAL SECTION OPENS HERE.

          TOP (1) with the newest first mirrors USP_GetCurrentSubscription:
          UQ_t_app_subscriptions_OneActivePerOwner makes two ACTIVE rows
          impossible, but an owner may hold an expired one beside a live one.
        */
        SELECT TOP (1)
            @SubscriptionId = s.SubscriptionId,
            @PlanIdOnSub    = s.PlanId,
            @SubStatusId    = s.StatusId,
            @SubIsActive    = s.Is_Active,
            @SubEndsOn      = s.EndsOn
        FROM dbo.t_app_subscriptions s WITH (UPDLOCK, HOLDLOCK)
        WHERE s.OwnerUid = @OwnerUid
          AND s.Is_Deleted = 0
        ORDER BY s.Is_Active DESC, s.StartsOn DESC, s.SubscriptionId DESC;

        /*--------------------------------------------------------------------
          🔴 IDEMPOTENCY IS CHECKED **BEFORE** THE QUOTA DECISION.

          The first version of this procedure relied on the unique index alone:
          the INSERT collided with 2601 and the CATCH answered ALREADY_CONSUMED.
          That is correct only while the request would otherwise have been
          allowed — and it silently is not, the moment quota runs out.

          The failure, found by running the real path rather than reading it:

              quota 1. Job A is posted and charged. The connection drops. The
              client retries the SAME reference. Quota is now spent, so the
              quota branch refuses with QUOTA_EXHAUSTED and the INSERT is never
              reached — so the index never fires and ALREADY_CONSUMED never
              happens.

          The customer is told "you have used everything your plan includes this
          month" for an action they have ALREADY PAID FOR, and the caller sees a
          refusal for work that succeeded. That is the mirror image of the
          double charge this whole design exists to prevent.

          ⚠️ This is NOT check-then-consume. The read is inside the same
          transaction, under the same per-owner lock taken above, so no session
          can slip an insert between this check and the decision below.

          The unique index STAYS, and is still the mechanism for the genuine
          race — two concurrent FIRST-TIME requests carrying one reference,
          where neither read can see the other's uncommitted row. Belt and
          braces, each covering what the other cannot.
        --------------------------------------------------------------------*/
        IF @RefEntityTypeId IS NOT NULL AND @RefEntityUid IS NOT NULL
        BEGIN
            SELECT TOP (1)
                @ExistingEntryId  = l.EntryId,
                @ExistingSourceId = l.SourceId
            FROM dbo.t_app_feature_ledger l
            WHERE l.FeatureId       = @FeatureId
              AND l.RefEntityTypeId = @RefEntityTypeId
              AND l.RefEntityUid    = @RefEntityUid
              AND l.EntryTypeId     = 2
              AND l.Is_Deleted      = 0
              AND l.ReversedOn IS NULL       -- a reversal frees the reference
            ORDER BY l.EntryId;
        END

        /*--------------------------------------------------------------------
          PRECEDENCE — first failure wins (design doc, Decision 1).

          FEATURE_DISABLED is already handled by the caller; everything below
          runs in the documented order.
        --------------------------------------------------------------------*/

        /*
          🔴 SUBSCRIPTION_MISSING IS A DATA-INTEGRITY ERROR, NOT A NORMAL STATE.

          Every account has a plan from the moment it exists — 2F puts
          SCHOOL_FREE into provisioning and G21's closure puts TEACHER_FREE into
          teacher signup. If this branch is ever reached, provisioning is
          broken. The service logs it at Error with the OwnerUid.

          It is checked BEFORE the subscription's state because the distinction
          matters to whoever reads the log: "no row" is our bug, "expired row"
          is the customer's situation.
        */
        IF @SubscriptionId IS NULL
        BEGIN
            SELECT @Code = 'SUBSCRIPTION_MISSING',
                   @Message = N'This account has no subscription on file. Please contact support.';
        END
        ELSE IF @SubIsActive = 0
             OR @SubStatusId <> 1
             OR (@SubEndsOn IS NOT NULL AND @SubEndsOn <= @Now)
        BEGIN
            SELECT @Code = 'SUBSCRIPTION_INACTIVE',
                   @Message = N'This account''s subscription is not active.';
        END

        /*
          🔴 The plan moved under the caller. See @ExpectedPlanId's comment.

          Checked here — after the subscription is known usable, before any
          mode branch reads the quota that was resolved for the wrong plan.
        */
        ELSE IF @ExpectedPlanId IS NOT NULL AND @PlanIdOnSub <> @ExpectedPlanId
        BEGIN
            SELECT @Code = 'PLAN_CHANGED',
                   @Message = N'This account''s plan changed while the request was being processed.';
        END

        /*
          🔴 ALREADY CHARGED — answered before any quota or mapping is read.

          Status = 1. A retried job posting told "you already paid for this" and
          then treated as an error by its caller is how a customer gets charged
          twice by a system built not to charge them twice.

          ⚠️ Deliberately below the subscription checks and above everything
          else. A killed feature or a dead subscription still outrank it — those
          are answers about the account, not about this action — but a plan
          mapping that changed since the original charge must not turn a
          completed, paid action into PLAN_LACKS_FEATURE.
        */
        ELSE IF @ExistingEntryId IS NOT NULL
        BEGIN
            SELECT @Status   = 1,
                   @Consumed = 0,
                   @EntryId  = @ExistingEntryId,
                   @SourceId = @ExistingSourceId,
                   @Code     = 'ALREADY_CONSUMED',
                   @Message  = N'This was already counted. You have not been charged twice.';
        END

        -- ---- FREE: the mode is the grant. No mapping read, nothing written.
        ELSE IF @GatingModeId = 1
        BEGIN
            SELECT @Status = 1, @Consumed = 0;
        END

        /*
          ---- BOOLEAN: included, or not.

          🔴 WRITES NOTHING TO THE LEDGER — not even on success. A row that can
          never change a balance is an access log wearing a ledger's clothes,
          and it would outnumber every row that does change one.

          ⚠️ But the check still comes through here rather than being inlined
          into a screen. One place decides entitlement.

          A missing mapping is DENIED: absence of a row is absence of a
          decision, and reading "nobody said anything" as "yes" grants
          capability nobody sold.
        */
        ELSE IF @GatingModeId = 2
        BEGIN
            IF @HasMapping = 1 AND @IsIncluded = 1
                SELECT @Status = 1, @Consumed = 0;
            ELSE
                SELECT @Code = 'PLAN_LACKS_FEATURE',
                       @Message = N'Your plan does not include this.';
        END

        -- ---- METERED: quota, then credits, then refusal.
        ELSE IF @GatingModeId = 3
        BEGIN
            IF @HasMapping = 0
            BEGIN
                SELECT @Code = 'PLAN_LACKS_FEATURE',
                       @Message = N'Your plan does not include this.';
            END
            ELSE
            BEGIN
                SELECT @PeriodFromUtc = p.PeriodFromUtc,
                       @PeriodToUtc   = p.PeriodToUtc
                FROM dbo.fn_QuotaPeriodForUtc(@Now) p;

                /*
                  Units used from QUOTA in this period.

                  Units on a consume are negative, so negate the sum to get a
                  positive "used".

                  🔴 ReversedOn IS NULL is what makes a reversal restore quota.
                  A refunded job posting stops counting against the month, which
                  is what a refund means. There is no compensating row for this —
                  see USP_ReverseLedgerEntry's header.
                */
                SELECT @QuotaUsed = ISNULL(-SUM(l.Units), 0)
                FROM dbo.t_app_feature_ledger l
                WHERE l.OwnerUid   = @OwnerUid
                  AND l.FeatureId  = @FeatureId
                  AND l.EntryTypeId = 2
                  AND l.SourceId    = 1
                  AND l.Is_Deleted  = 0
                  AND l.ReversedOn IS NULL
                  AND l.OccurredOn >= @PeriodFromUtc
                  AND l.OccurredOn <  @PeriodToUtc;

                /*
                  ⚠️ NULL quota means unlimited WITHIN THE PLAN; 0 means
                  explicitly none. They are not the same and must not be
                  conflated — NULL skips the comparison, 0 fails it and falls
                  through to credits.
                */
                IF @QuotaPerPeriod IS NULL
                BEGIN
                    SET @SourceId = 1;
                    SET @QuotaRemaining = NULL;
                END
                ELSE
                BEGIN
                    SET @QuotaRemaining = @QuotaPerPeriod - @QuotaUsed;

                    -- 🔴 QUOTA BEFORE CREDITS. Quota is included allowance;
                    -- credits are money the customer already paid. Burning the
                    -- paid thing first while free allowance sits unused is a
                    -- refund conversation nobody should have to have.
                    IF @QuotaUsed + @Units <= @QuotaPerPeriod
                        SET @SourceId = 1;
                END

                IF @SourceId IS NULL
                BEGIN
                    /*
                      Credit balance — see USP_GetFeatureBalance for the one
                      authoritative statement of this sum and why reversal rows
                      are not part of it.
                    */
                    SELECT @CreditBalance = ISNULL(SUM(l.Units), 0)
                    FROM dbo.t_app_feature_ledger l
                    WHERE l.OwnerUid  = @OwnerUid
                      AND l.FeatureId = @FeatureId
                      AND l.Is_Deleted = 0
                      AND l.ReversedOn IS NULL
                      AND (l.EntryTypeId = 1                              -- grant      (+)
                        OR l.EntryTypeId = 4                              -- expiry     (-)
                        OR (l.EntryTypeId = 2 AND l.SourceId = 2));       -- credit use (-)

                    IF @CreditBalance >= @Units
                        SET @SourceId = 2;
                    ELSE
                        SELECT @Code = 'QUOTA_EXHAUSTED',
                               @Message = N'You have used everything your plan includes this month, and have no credits left.';
                END

                IF @SourceId IS NOT NULL
                BEGIN
                    INSERT INTO dbo.t_app_feature_ledger
                        (OwnerUid, FeatureId, EntryTypeId, SourceId, Units,
                         RefEntityTypeId, RefEntityUid, OccurredOn, Notes, CreatedBy)
                    VALUES
                        (@OwnerUid, @FeatureId, 2, @SourceId, -@Units,
                         @RefEntityTypeId, @RefEntityUid, @Now, @Notes, @ActorUserId);

                    SET @EntryId = CAST(SCOPE_IDENTITY() AS bigint);
                    SELECT @Status = 1, @Consumed = 1;

                    IF @SourceId = 1 AND @QuotaRemaining IS NOT NULL
                        SET @QuotaRemaining = @QuotaRemaining - @Units;
                    IF @SourceId = 2
                        SET @CreditBalance = @CreditBalance - @Units;
                END
            END
        END
        ELSE
        BEGIN
            /*
              Unreachable while CK_m_mdm_features_GatingModeId holds. Here
              because "unreachable" and "cannot happen" are different words:
              if a fourth mode ever arrives as data, this refuses rather than
              falling through to an implicit allow.
            */
            SELECT @Code = 'BUSINESS_RULE_VIOLATED',
                   @Message = N'That feature is configured with a gating mode this build does not understand.';
        END

        IF @OwnsTran = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        DECLARE @E int = ERROR_NUMBER(), @S int = ERROR_SEVERITY(), @T int = ERROR_STATE(),
                @P sysname = ERROR_PROCEDURE(), @L int = ERROR_LINE(),
                @M nvarchar(4000) = ERROR_MESSAGE();

        -- Only the owner rolls back. Nested, the caller's CATCH does it.
        IF @OwnsTran = 1 AND XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        /*
          🔴 2601 ON THE REFERENCE INDEX MEANS "ALREADY DONE" — BUT ONLY AFTER
          RE-READING THE ROW (2.48).

          "The index says it is there" is not the same as having seen it. And
          the re-read genuinely can come back empty: a reversal landing between
          the collision and the read frees the reference. That is
          CONSUME_CONFLICT — retryable, distinct, and NOT a loop. A retry policy
          belongs in the caller, not in an unbounded spin inside a procedure.
        */
        IF @E IN (2601, 2627)
        BEGIN
            SELECT TOP (1)
                @EntryId  = l.EntryId,
                @SourceId = l.SourceId
            FROM dbo.t_app_feature_ledger l
            WHERE l.FeatureId       = @FeatureId
              AND l.RefEntityTypeId = @RefEntityTypeId
              AND l.RefEntityUid    = @RefEntityUid
              AND l.EntryTypeId     = 2
              AND l.Is_Deleted      = 0
              AND l.ReversedOn IS NULL
            ORDER BY l.EntryId;

            IF @EntryId IS NOT NULL
            BEGIN
                /*
                  🔴 Status = 1. A retried job posting told "you already paid
                  for this" and then treated as an error by its caller is how a
                  customer gets charged twice by a system built not to charge
                  them twice.
                */
                SELECT @Status = 1, @Consumed = 0,
                       @Code = 'ALREADY_CONSUMED',
                       @Message = N'This was already counted. You have not been charged twice.';
            END
            ELSE
            BEGIN
                SELECT @Status = 0, @Code = 'CONSUME_CONFLICT',
                       @Message = N'That request collided with another change. Please try again.';
            END
        END

        IF @Status = 0 AND @Code IS NULL
        BEGIN
            DECLARE @Params nvarchar(max) = (
                SELECT @OwnerUid AS ownerUid, @FeatureId AS featureId,
                       @GatingModeId AS gatingModeId, @Units AS units,
                       @RefEntityTypeId AS refEntityTypeId, @RefEntityUid AS refEntityUid
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @E, @ErrorSeverity = @S, @ErrorState = @T,
                 @ErrorProcedure = @P, @ErrorLine = @L, @ErrorMessage = @M,
                 @ParametersJson = @Params, @ContextInfo = N'USP_ConsumeFeature',
                 @CreatedBy = @ActorUserId;

            THROW;
        END
    END CATCH

END
GO


/*==============================================================================
  USP_ConsumeFeature — the result-set face of the core.

  🔴 THE CONTRACT PHASE 2.5 SHIPPED, UNCHANGED. Same name, same parameters,
  same eleven columns in the same order. Both 2.5 suites call this and neither
  needed a line changed when the core was extracted — which is the proof that
  the extraction was a refactor and not a redesign.

  Callers that need the answer inside their own transaction — USP_PublishJob —
  call the CORE with OUTPUT parameters instead, avoiding INSERT ... EXEC and
  its two runtime traps. See the core's header.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_ConsumeFeature
    @OwnerUid         uniqueidentifier,
    @FeatureId        int,
    @GatingModeId     tinyint,
    @HasMapping       tinyint,
    @IsIncluded       tinyint          = 0,
    @QuotaPerPeriod   int              = NULL,
    @ExpectedPlanId   int              = NULL,
    @Units            int              = 1,
    @RefEntityTypeId  tinyint          = NULL,
    @RefEntityUid     uniqueidentifier = NULL,
    @Notes            nvarchar(400)    = NULL,
    @ActorUserId      bigint           = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Status int, @Code varchar(50), @Message nvarchar(400), @EntryId bigint,
            @Consumed tinyint, @SourceId tinyint, @QuotaUsed int, @QuotaRemaining int,
            @CreditBalance int, @PeriodFromUtc datetime2, @PeriodToUtc datetime2;

    EXEC dbo.USP_ConsumeFeatureCore
        @OwnerUid        = @OwnerUid,
        @FeatureId       = @FeatureId,
        @GatingModeId    = @GatingModeId,
        @HasMapping      = @HasMapping,
        @IsIncluded      = @IsIncluded,
        @QuotaPerPeriod  = @QuotaPerPeriod,
        @ExpectedPlanId  = @ExpectedPlanId,
        @Units           = @Units,
        @RefEntityTypeId = @RefEntityTypeId,
        @RefEntityUid    = @RefEntityUid,
        @Notes           = @Notes,
        @ActorUserId     = @ActorUserId,
        @Status          = @Status         OUTPUT,
        @Code            = @Code           OUTPUT,
        @Message         = @Message        OUTPUT,
        @EntryId         = @EntryId        OUTPUT,
        @Consumed        = @Consumed       OUTPUT,
        @SourceId        = @SourceId       OUTPUT,
        @QuotaUsed       = @QuotaUsed      OUTPUT,
        @QuotaRemaining  = @QuotaRemaining OUTPUT,
        @CreditBalance   = @CreditBalance  OUTPUT,
        @PeriodFromUtc   = @PeriodFromUtc  OUTPUT,
        @PeriodToUtc     = @PeriodToUtc    OUTPUT;

    SELECT @Status         AS [Status],
           @Code           AS Code,
           @Message        AS [Message],
           @EntryId        AS Id,
           @Consumed       AS Consumed,
           @SourceId       AS SourceId,
           @QuotaUsed      AS QuotaUsed,
           @QuotaRemaining AS QuotaRemaining,
           @CreditBalance  AS CreditBalance,
           @PeriodFromUtc  AS PeriodFromUtc,
           @PeriodToUtc    AS PeriodToUtc;
END
GO


/*==============================================================================
  USP_ReverseLedgerEntry — undo one entry, without deleting it.

  ---------------------------------------------------------------------------
  🔴 REVERSAL IS EXPRESSED BY EXCLUSION, NOT BY A COMPENSATING SUM
  ---------------------------------------------------------------------------
  Two rows change: a REVERSAL row is inserted pointing at the original, and the
  original is stamped ReversedOn — both in one transaction.

  Every balance query then filters `ReversedOn IS NULL`, so the reversed entry
  simply stops counting. The reversal row itself is an audit record and is NOT
  summed into any balance.

  ⚠️ THIS DIFFERS FROM THE DESIGN DOC, WHICH LISTED "Reversal +N" AS PART OF
  THE BALANCE SUM. That formula double-counts, and worse, it invents credits:

      A QUOTA consume is reversed. The consume was never part of the credit
      balance (SourceId = 1), but its reversal row carries Units > 0 with no
      SourceId of its own — so summing reversals would add a credit the
      customer never bought, every time a quota consume was refunded.

  The reversal row cannot carry a SourceId to fix this: CK_..._SourceOnConsume
  reserves that column for consumes, and relaxing it would make every balance
  query two-sided. Exclusion is also what the QUOTA side already had to do,
  because ReversedOn must exist anyway for the idempotency index. One mechanism
  for both.

  The design doc has been corrected to match this.

  ⚠️ Reversing a GRANT is legitimate and is the support remedy for stuck
  credits: reverse the unused grant, issue another for a different feature.
  Both rows stay, so the customer's history remains true.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_ReverseLedgerEntry
    @EntryId      bigint,
    @Notes        nvarchar(400) = NULL,
    @ActorUserId  bigint        = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL, @Message nvarchar(400) = NULL,
            @NewEntryId bigint = NULL,
            @OwnerUid uniqueidentifier, @FeatureId int, @EntryTypeId tinyint,
            @Units int, @AlreadyReversed datetime2;

    DECLARE @Now datetime2 = SYSUTCDATETIME();

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT @OwnerUid        = l.OwnerUid,
               @FeatureId       = l.FeatureId,
               @EntryTypeId     = l.EntryTypeId,
               @Units           = l.Units,
               @AlreadyReversed = l.ReversedOn
        FROM dbo.t_app_feature_ledger l WITH (UPDLOCK, HOLDLOCK)
        WHERE l.EntryId = @EntryId
          AND l.Is_Deleted = 0;

        IF @OwnerUid IS NULL
        BEGIN
            SELECT @Code = 'NOT_FOUND', @Message = N'That ledger entry does not exist.';
        END
        ELSE IF @EntryTypeId = 3
        BEGIN
            -- Reversing a reversal is an accounting knot nobody can read back.
            -- The honest correction is a fresh grant or consume.
            SELECT @Code = 'BUSINESS_RULE_VIOLATED',
                   @Message = N'A reversal cannot itself be reversed. Record a new entry instead.';
        END
        ELSE IF @AlreadyReversed IS NOT NULL
        BEGIN
            -- Idempotent: asking twice is not an error (2.48).
            SELECT @Status = 1, @Code = 'ALREADY_REVERSED',
                   @Message = N'That entry was already reversed.';
        END
        ELSE
        BEGIN
            UPDATE dbo.t_app_feature_ledger
            SET ReversedOn = @Now,
                ModifiedOn = @Now,
                ModifiedBy = @ActorUserId
            WHERE EntryId = @EntryId;

            INSERT INTO dbo.t_app_feature_ledger
                (OwnerUid, FeatureId, EntryTypeId, SourceId, Units,
                 RefEntityTypeId, RefEntityUid, ReversalOfEntryId, OccurredOn, Notes, CreatedBy)
            VALUES
                (@OwnerUid, @FeatureId, 3, NULL, ABS(@Units),
                 NULL, NULL, @EntryId, @Now, @Notes, @ActorUserId);

            SET @NewEntryId = CAST(SCOPE_IDENTITY() AS bigint);
            SET @Status = 1;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        DECLARE @E int = ERROR_NUMBER(), @S int = ERROR_SEVERITY(), @T int = ERROR_STATE(),
                @P sysname = ERROR_PROCEDURE(), @L int = ERROR_LINE(),
                @M nvarchar(4000) = ERROR_MESSAGE();

        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        DECLARE @Params nvarchar(max) = (
            SELECT @EntryId AS entryId FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC dbo.USP_LogError @ErrorNumber = @E, @ErrorSeverity = @S, @ErrorState = @T,
             @ErrorProcedure = @P, @ErrorLine = @L, @ErrorMessage = @M,
             @ParametersJson = @Params, @ContextInfo = N'USP_ReverseLedgerEntry',
             @CreatedBy = @ActorUserId;

        THROW;
    END CATCH

    SELECT @Status AS [Status], @Code AS Code, @Message AS [Message], @NewEntryId AS Id;
END
GO


/*==============================================================================
  USP_GrantFeatureCredits — put credits on an account.

  In MVP the only caller is an administrator. In Phase 6.5 a successful payment
  calls this with the payment's reference, and nothing about the row changes.

  ⚠️ Credits are PER FEATURE and non-fungible. Five job-post credits are five
  job posts. The stuck-money case — credits for a feature the customer no
  longer wants — is deliberate, and its remedy is human: reverse the grant and
  issue another. Both rows stay, so the history stays true.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GrantFeatureCredits
    @OwnerUid         uniqueidentifier,
    @FeatureId        int,
    @Units            int,
    @RefEntityTypeId  tinyint          = 4,       -- MANUAL
    @RefEntityUid     uniqueidentifier = NULL,
    @Notes            nvarchar(400)    = NULL,
    @ActorUserId      bigint           = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL, @Message nvarchar(400) = NULL,
            @EntryId bigint = NULL;

    IF @Units IS NULL OR @Units < 1
    BEGIN
        SELECT 0 AS [Status], 'VALIDATION_FAILED' AS Code,
               N'A grant must be at least one unit.' AS [Message], NULL AS Id;
        RETURN;
    END

    BEGIN TRY
        /*
          ⚠️ A grant carries a reference so two support actions cannot be
          mistaken for one another in the audit trail — but it is NOT covered by
          the idempotency index, which is filtered to consumes. Two identical
          grants are two grants, deliberately: an administrator issuing credits
          twice has issued credits twice, and silently collapsing that would
          hide a mistake rather than prevent one.
        */
        INSERT INTO dbo.t_app_feature_ledger
            (OwnerUid, FeatureId, EntryTypeId, SourceId, Units,
             RefEntityTypeId, RefEntityUid, OccurredOn, Notes, CreatedBy)
        VALUES
            (@OwnerUid, @FeatureId, 1, NULL, @Units,
             @RefEntityTypeId, ISNULL(@RefEntityUid, NEWID()), SYSUTCDATETIME(), @Notes, @ActorUserId);

        SET @EntryId = CAST(SCOPE_IDENTITY() AS bigint);
        SET @Status = 1;
    END TRY
    BEGIN CATCH
        DECLARE @E int = ERROR_NUMBER(), @S int = ERROR_SEVERITY(), @T int = ERROR_STATE(),
                @P sysname = ERROR_PROCEDURE(), @L int = ERROR_LINE(),
                @M nvarchar(4000) = ERROR_MESSAGE();

        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        DECLARE @Params nvarchar(max) = (
            SELECT @OwnerUid AS ownerUid, @FeatureId AS featureId, @Units AS units
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC dbo.USP_LogError @ErrorNumber = @E, @ErrorSeverity = @S, @ErrorState = @T,
             @ErrorProcedure = @P, @ErrorLine = @L, @ErrorMessage = @M,
             @ParametersJson = @Params, @ContextInfo = N'USP_GrantFeatureCredits',
             @CreatedBy = @ActorUserId;

        THROW;
    END CATCH

    SELECT @Status AS [Status], @Code AS Code, @Message AS [Message], @EntryId AS Id;
END
GO


/*==============================================================================
  USP_GetFeatureBalance — the authoritative balance statement.

  ---------------------------------------------------------------------------
  🔴 THIS IS THE ONLY DEFINITION OF "BALANCE" IN THE SYSTEM
  ---------------------------------------------------------------------------
  There is no cached balance column and no stored counter, so nothing can drift
  out of agreement with the ledger. The phase's verification recomputes both
  numbers from raw rows and asserts they match what this returns — which is
  also what would make a cache safe to add later, if one is ever needed.

  Credit balance sums three entry types over live, non-reversed rows:

      Grant       (+)   EntryTypeId 1
      Expiry      (-)   EntryTypeId 4
      Credit use  (-)   EntryTypeId 2 AND SourceId = 2

  ⚠️ REVERSAL ROWS ARE NOT SUMMED. A reversal takes effect by stamping
  ReversedOn on its target, which drops the target out of every one of these
  filters. Summing the reversal as well would double-count it — and for a
  reversed QUOTA consume it would invent a credit out of nothing, because the
  consume was never in this sum to begin with. See USP_ReverseLedgerEntry.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetFeatureBalance
    @OwnerUid   uniqueidentifier,
    @FeatureId  int,
    @AsOfUtc    datetime2 = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now datetime2 = ISNULL(@AsOfUtc, SYSUTCDATETIME());
    DECLARE @PeriodFromUtc datetime2, @PeriodToUtc datetime2;

    SELECT @PeriodFromUtc = p.PeriodFromUtc,
           @PeriodToUtc   = p.PeriodToUtc
    FROM dbo.fn_QuotaPeriodForUtc(@Now) p;

    SELECT
        @OwnerUid       AS OwnerUid,
        @FeatureId      AS FeatureId,
        @PeriodFromUtc  AS PeriodFromUtc,
        @PeriodToUtc    AS PeriodToUtc,

        -- Units taken from plan quota inside this period.
        ISNULL((SELECT -SUM(l.Units)
                FROM dbo.t_app_feature_ledger l
                WHERE l.OwnerUid = @OwnerUid AND l.FeatureId = @FeatureId
                  AND l.EntryTypeId = 2 AND l.SourceId = 1
                  AND l.Is_Deleted = 0 AND l.ReversedOn IS NULL
                  AND l.OccurredOn >= @PeriodFromUtc AND l.OccurredOn < @PeriodToUtc), 0)
                                                    AS QuotaUsed,

        -- Credits available. See the header for why reversals are absent.
        ISNULL((SELECT SUM(l.Units)
                FROM dbo.t_app_feature_ledger l
                WHERE l.OwnerUid = @OwnerUid AND l.FeatureId = @FeatureId
                  AND l.Is_Deleted = 0 AND l.ReversedOn IS NULL
                  AND (l.EntryTypeId = 1
                    OR l.EntryTypeId = 4
                    OR (l.EntryTypeId = 2 AND l.SourceId = 2))), 0)
                                                    AS CreditBalance,

        -- Units taken from credits inside this period, for reporting only.
        ISNULL((SELECT -SUM(l.Units)
                FROM dbo.t_app_feature_ledger l
                WHERE l.OwnerUid = @OwnerUid AND l.FeatureId = @FeatureId
                  AND l.EntryTypeId = 2 AND l.SourceId = 2
                  AND l.Is_Deleted = 0 AND l.ReversedOn IS NULL
                  AND l.OccurredOn >= @PeriodFromUtc AND l.OccurredOn < @PeriodToUtc), 0)
                                                    AS CreditUsedThisPeriod;
END
GO


/*==============================================================================
  USP_GetFeatureLedger — the rows themselves, newest first.

  For the verification scripts and for support. Not a customer-facing read.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetFeatureLedger
    @OwnerUid   uniqueidentifier,
    @FeatureId  int = NULL,
    @Top        int = 200
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP (@Top)
        l.EntryId,
        l.EntryUid,
        l.OwnerUid,
        l.FeatureId,
        l.EntryTypeId,
        et.Code            AS EntryTypeCode,
        l.SourceId,
        sr.Code            AS SourceCode,
        l.Units,
        l.RefEntityTypeId,
        rt.Code            AS RefEntityTypeCode,
        l.RefEntityUid,
        l.ReversalOfEntryId,
        l.ReversedOn,
        l.OccurredOn,
        l.Notes,

        -- 🔴 Aliased. Dapper does not strip underscores (2.61, incident G25).
        l.Is_Active        AS IsActive
    FROM dbo.t_app_feature_ledger l
        INNER JOIN dbo.m_app_ledger_entry_types et ON et.EntryTypeId = l.EntryTypeId
        LEFT  JOIN dbo.m_app_ledger_sources     sr ON sr.SourceId    = l.SourceId
        LEFT  JOIN dbo.m_app_ref_entity_types   rt ON rt.RefEntityTypeId = l.RefEntityTypeId
    WHERE l.OwnerUid = @OwnerUid
      AND (@FeatureId IS NULL OR l.FeatureId = @FeatureId)
      AND l.Is_Deleted = 0
    ORDER BY l.EntryId DESC;
END
GO

PRINT '    Entitlement engine procedures ready.';
GO
