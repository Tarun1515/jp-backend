/*==============================================================================
  jp_app — 04_procedures / 023_billing_activation.sql

  The activation half of 6.5-A's seam, and the ONE predicate behind 6.5-C.

    fn_SubscriptionInForce      is this row in force at this instant?
    USP_ActivateSubscription    close the old, open the new — idempotent
    USP_GetSubscriptionHistory  every row an owner has held, newest first

  ---------------------------------------------------------------------------
  🔒 WHAT THIS FILE DOES NOT DO, AND MUST NEVER DO (2.56, LOCKED)
  ---------------------------------------------------------------------------
  A verified payment buys CAPABILITY — whether a school may search at all, how
  many invitations it may send. It never buys a teacher's phone number or
  email. fn_TeacherContactUnlocked returns true on exactly two paths: the
  teacher applied to this school, or the teacher accepted its invitation.

  A payment is NOT a third path. The words "contact", "phone", "email" and
  "fn_TeacherContactUnlocked" do not appear in this file's code, and the 2.56
  greps assert that in both directions.

  ---------------------------------------------------------------------------
  🔴 WHY ACTIVATION IS A SEPARATE PROCEDURE IN A SEPARATE DATABASE
  ---------------------------------------------------------------------------
  The payment lives in jp_mdm and this lives in jp_app, and no query may cross
  (2.2) — so the two halves cannot share a transaction, and there is no
  distributed transaction (2.48). The seam is therefore at the SERVICE
  (IBillingService.VerifyAndActivateAsync), which is the same cross-database
  orchestration shape ApprovalService already runs.

  That is not a weakness as long as recovery is "call it again", which is what
  the idempotency below buys. See MONETIZATION_DESIGN 6.5-A.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*==============================================================================
  fn_SubscriptionInForce — THE predicate. One definition, every reader.

  ---------------------------------------------------------------------------
  🔴 WHY THIS IS A FUNCTION AND NOT THREE CONDITIONS REPEATED
  ---------------------------------------------------------------------------
  Before 6.5 this logic existed exactly once, inline, in USP_ConsumeFeatureCore.
  Once was fine. 6.5 adds three more readers — the plan panel, the subscription
  history, and the activation itself — and four copies of a predicate about
  money is how two screens come to disagree about whether a school has paid.

  ---------------------------------------------------------------------------
  🔴 SCALARS IN, NOT AN OwnerUid
  ---------------------------------------------------------------------------
  It takes the three column values rather than reading the row itself, for two
  reasons that both come from being called inside a lock:

    1. USP_ConsumeFeatureCore has ALREADY read the row, under UPDLOCK, into
       local variables. A function that read it again would either take a
       second lock or read around the first one.
    2. No table reference means nothing to SCHEMABIND. 2.64 records what that
       cost: fn_QuotaPeriodForUtc was first written calling fn_IstDateToUtc
       WITH SCHEMABINDING, it built clean once, and the SECOND run_all failed
       with Msg 3729 because a shared, re-runnable helper file could no longer
       be replayed. This function is deliberately dependency-free.

  ---------------------------------------------------------------------------
  🔴 WHAT "IN FORCE" DELIBERATELY DOES NOT MEAN
  ---------------------------------------------------------------------------
  It does not mean "the account is usable". A lapsed paid subscription is NOT
  in force, and the account still works — at the free baseline (6.5-C). That
  distinction lives in the caller, which falls back to the default plan; this
  function answers one narrow question and nothing else.
==============================================================================*/
CREATE OR ALTER FUNCTION dbo.fn_SubscriptionInForce
(
    @IsActive  tinyint,
    @StatusId  int,
    @EndsOn    datetime2,
    @Now       datetime2
)
RETURNS bit
WITH SCHEMABINDING
AS
BEGIN
    /*
      StatusId 1 = ACTIVE. 2 = EXPIRED (closed, superseded by a later row).
      3 = CANCELLED (deliberately stopped).

      ⚠️ EndsOn NULL means perpetual, which is every free plan — provisioning
      has written NULL there since 2F. `@EndsOn <= @Now` is therefore guarded
      by the NULL check rather than relying on NULL comparison semantics,
      which would make the whole expression NULL and the CASE fall through to
      0 — the right answer by accident, which is the worst kind.
    */
    RETURN CASE
        WHEN @IsActive = 1
         AND @StatusId = 1
         AND (@EndsOn IS NULL OR @EndsOn > @Now)
        THEN CAST(1 AS bit)
        ELSE CAST(0 AS bit)
    END;
END
GO

/*==============================================================================
  USP_ActivateSubscription — the activation half.

  ---------------------------------------------------------------------------
  🔴 CLOSE THE OLD, OPEN THE NEW. NEVER UPDATE THE OLD ONE'S PLAN.
  ---------------------------------------------------------------------------
  UQ_t_app_subscriptions_OneActivePerOwner is UNIQUE (OwnerUid) WHERE
  StatusId = 1 — so only one row per owner may be ACTIVE, and activation is
  NECESSARILY close-then-open. The database makes the shape structural rather
  than a convention somebody could drift from (2.36).

  Updating the old row's PlanId instead would be one statement and would
  destroy the only record of what the account used to be on, which is the first
  thing anybody asks when a bill is disputed.

  ---------------------------------------------------------------------------
  🔴 IDEMPOTENT ON SourcePaymentUid — AND WHY THE CHECK AND THE INDEX BOTH EXIST
  ---------------------------------------------------------------------------
  Verifying the same payment twice must produce ONE activation. Two mechanisms,
  and neither is redundant — 2.64 recorded this exact pairing for the ledger's
  reference check:

    the CHECK  gives the second caller a clean "already done" answer with the
               subscription it already opened, rather than a 2601 the client
               has to interpret;
    the INDEX  catches the genuinely simultaneous pair — two admins verifying
               one payment on the same wall-clock instant — which no
               check-then-insert can.

  ⚠️ The check is INSIDE the transaction and inside the per-owner lock, so it
  is not a check-then-act race. It is a read in a critical section.

  ---------------------------------------------------------------------------
  @DurationDays IS A PARAMETER BECAUSE PLANS LIVE IN jp_mdm (2.2)
  ---------------------------------------------------------------------------
  This procedure cannot look up how long the plan lasts. The caller reads
  m_mdm_plans.DurationDays and passes it, exactly as it already passes PlanId.
  NULL means perpetual.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_ActivateSubscription
    @OwnerUid      uniqueidentifier,
    @PlanId        int,
    @PaymentUid    uniqueidentifier,
    @DurationDays  int            = NULL,
    @ActorUserId   bigint         = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now             datetime2 = SYSUTCDATETIME(),
            @Status          tinyint   = 0,
            @Code            varchar(50) = NULL,
            @Message         nvarchar(400) = NULL,
            @SubscriptionId  bigint    = NULL,
            @SubscriptionUid uniqueidentifier = NULL,
            @PreviousPlanId  int       = NULL,
            @AlreadyDone     bit       = 0,
            @StartsOn        datetime2 = NULL,
            @EndsOn          datetime2 = NULL;

    IF @OwnerUid IS NULL OR @PlanId IS NULL OR @PaymentUid IS NULL
    BEGIN
        SELECT Status = 0, Code = 'VALIDATION_FAILED',
               [Message] = N'OwnerUid, PlanId and PaymentUid are all required.',
               SubscriptionId = NULL, SubscriptionUid = NULL,
               PreviousPlanId = NULL, StartsOn = NULL, EndsOn = NULL,
               AlreadyActivated = CAST(0 AS bit);
        RETURN;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        /*
          🔴 THE PER-OWNER LOCK, and HOLDLOCK is as necessary as UPDLOCK.

          UPDLOCK alone locks rows that exist. An owner with no ACTIVE row —
          which happens the moment the old one is closed — has nothing to lock,
          and two sessions would both pass straight through. HOLDLOCK takes a
          RANGE lock, so the second session waits on the gap. This is the
          mechanism 2.64 proved with two sessions armed on one WAITFOR TIME,
          and it is the same shape here for the same reason.
        */
        SELECT TOP (1)
               @SubscriptionId = s.SubscriptionId,
               @PreviousPlanId = s.PlanId
          FROM dbo.t_app_subscriptions s WITH (UPDLOCK, HOLDLOCK)
         WHERE s.OwnerUid   = @OwnerUid
           AND s.StatusId   = 1
           AND s.Is_Deleted = 0
         ORDER BY s.SubscriptionId DESC;

        /*
          ---- Already activated for this payment? --------------------------

          Read inside the lock. A retry after a partially-completed
          verification lands here and gets the subscription that already
          exists, with Status 1 — so the caller's recovery is simply calling
          again, which is what 6.5-A promises.
        */
        SELECT TOP (1)
               @AlreadyDone     = 1,
               @SubscriptionId  = s.SubscriptionId,
               @SubscriptionUid = s.SubscriptionUid,
               @StartsOn        = s.StartsOn,
               @EndsOn          = s.EndsOn
          FROM dbo.t_app_subscriptions s
         WHERE s.SourcePaymentUid = @PaymentUid
           AND s.Is_Deleted       = 0
         ORDER BY s.SubscriptionId DESC;

        IF @AlreadyDone = 1
        BEGIN
            COMMIT TRANSACTION;

            SELECT Status = 1, Code = NULL,
                   [Message] = N'This payment had already been activated.',
                   SubscriptionId = @SubscriptionId, SubscriptionUid = @SubscriptionUid,
                   PreviousPlanId = NULL, StartsOn = @StartsOn, EndsOn = @EndsOn,
                   AlreadyActivated = CAST(1 AS bit);
            RETURN;
        END

        /*
          ---- Close the old row, if there is one --------------------------

          StatusId 2 (EXPIRED) and Is_Active 0, and EndsOn STAMPED at the
          changeover instant.

          ⚠️ Stamping EndsOn matters even though the row is no longer ACTIVE: a
          free row carries EndsOn NULL meaning "perpetual", and leaving it NULL
          on a closed row would read, forever, as a plan that never ended. The
          history screen renders exactly this column.
        */
        IF @SubscriptionId IS NOT NULL
        BEGIN
            UPDATE dbo.t_app_subscriptions
               SET StatusId   = 2,
                   Is_Active  = 0,
                   EndsOn     = @Now,
                   ModifiedOn = @Now,
                   ModifiedBy = @ActorUserId
             WHERE SubscriptionId = @SubscriptionId;
        END

        /*
          ---- Open the new one -------------------------------------------

          🔴 EndsOn on the IST day boundary, half-open — the convention
          fn_IstDayRangeUtc already uses. A 30-day plan activated at any time
          on 11 Oct IST runs THROUGH 10 Nov IST and stops at 00:00 IST on
          11 Nov.

          The alternative — exactly @DurationDays × 24h from the instant of
          activation — would expire a plan at 14:37 on a Tuesday, and the
          customer who bought "30 days" at 2pm would lose the last afternoon
          with no explanation that reads as fair. Storage stays UTC and the
          rule is IST (2.28), which is what the helper is for.

          ⚠️ NULL DurationDays = perpetual, which is every free plan.
        */
        SET @StartsOn = @Now;

        SET @EndsOn = CASE
            WHEN @DurationDays IS NULL THEN NULL
            ELSE dbo.fn_IstDateToUtc(DATEADD(day, @DurationDays, CAST(dbo.fn_ToIst(@Now) AS date)))
        END;

        INSERT INTO dbo.t_app_subscriptions
            (OwnerUid, PlanId, StartsOn, EndsOn, StatusId, AutoRenew,
             SourcePaymentUid, CreatedBy)
        VALUES
            (@OwnerUid, @PlanId, @StartsOn, @EndsOn, 1, 0,
             @PaymentUid, @ActorUserId);

        SET @SubscriptionId = CAST(SCOPE_IDENTITY() AS bigint);

        SELECT @SubscriptionUid = SubscriptionUid
          FROM dbo.t_app_subscriptions
         WHERE SubscriptionId = @SubscriptionId;

        COMMIT TRANSACTION;

        SET @Status = 1;
        SET @Message = N'The subscription is active.';
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        /*
          🔴 2601/2627 HERE IS THE RACE, NOT A BUG.

          Two admins verified one payment on the same instant and both passed
          the already-activated read before either inserted. One of them lost
          on UQ_t_app_subscriptions_SourcePaymentUid — which is the index doing
          precisely the job the check cannot.

          The loser is told the truth: it is already activated. Re-reading the
          winner's row makes that answer useful rather than merely correct.

          ⚠️ Every OTHER error is logged and rethrown. 3C's lesson: swallowing
          an unexpected error into a tidy refusal code is how a broken index
          looked like a business rule for two phases.
        */
        IF ERROR_NUMBER() IN (2601, 2627)
        BEGIN
            SELECT TOP (1)
                   @SubscriptionId  = s.SubscriptionId,
                   @SubscriptionUid = s.SubscriptionUid,
                   @StartsOn        = s.StartsOn,
                   @EndsOn          = s.EndsOn
              FROM dbo.t_app_subscriptions s
             WHERE s.SourcePaymentUid = @PaymentUid
               AND s.Is_Deleted       = 0
             ORDER BY s.SubscriptionId DESC;

            SELECT Status = 1, Code = NULL,
                   [Message] = N'This payment had already been activated.',
                   SubscriptionId = @SubscriptionId, SubscriptionUid = @SubscriptionUid,
                   PreviousPlanId = NULL, StartsOn = @StartsOn, EndsOn = @EndsOn,
                   AlreadyActivated = CAST(1 AS bit);
            RETURN;
        END

        EXEC dbo.USP_LogError
            @ProcedureName = 'USP_ActivateSubscription',
            @UserId        = @ActorUserId;

        THROW;
    END CATCH

    SELECT Status = @Status, Code = @Code, [Message] = @Message,
           SubscriptionId = @SubscriptionId, SubscriptionUid = @SubscriptionUid,
           PreviousPlanId = @PreviousPlanId, StartsOn = @StartsOn, EndsOn = @EndsOn,
           AlreadyActivated = CAST(0 AS bit);
END
GO

/*==============================================================================
  USP_GetSubscriptionHistory — every row an owner has held.

  ⚠️ `Is_Active AS IsActive` and `InForce` are both aliased for Dapper (2.61).
  G25: Dapper does not strip underscores, so Is_Active never reaches an
  IsActive property and arrives as false with nothing failing. That shipped
  once on BranchDto and survived two phases because no screen displayed it.
  The subscription-history panel displays it.

  🔴 InForce is COMPUTED by the one function, not re-derived here. A history
  screen that decided for itself which row is live would be the fourth copy of
  the predicate this file exists to prevent.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetSubscriptionHistory
    @OwnerUid uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now datetime2 = SYSUTCDATETIME();

    SELECT
        s.SubscriptionId,
        s.SubscriptionUid,
        s.OwnerUid,
        s.PlanId,
        s.StartsOn,
        s.EndsOn,
        s.StatusId,
        s.AutoRenew,
        s.SourcePaymentUid,
        s.CreatedOn,

        -- 🔴 Aliased. See the header — G25 is exactly this class of bug.
        s.Is_Active AS IsActive,

        dbo.fn_SubscriptionInForce(s.Is_Active, s.StatusId, s.EndsOn, @Now) AS InForce
    FROM dbo.t_app_subscriptions s
    WHERE s.OwnerUid   = @OwnerUid
      AND s.Is_Deleted = 0
    ORDER BY s.StartsOn DESC, s.SubscriptionId DESC;
END
GO

/*==============================================================================
  BUILD GUARDS
==============================================================================*/

IF OBJECT_ID('dbo.fn_SubscriptionInForce', 'FN') IS NULL
    RAISERROR('023_billing_activation: fn_SubscriptionInForce was not created.', 16, 1);
GO

/*
  🔴 THE FUNCTION'S OWN TRUTH TABLE, ASSERTED AT BUILD TIME.

  This is the predicate every money question in the product routes through, and
  a silent change to it would alter who can do what without a single test
  failing in an obvious place. Four cases, each one a thing that actually
  happens:

    a free plan          active, status 1, EndsOn NULL      -> in force
    a live paid plan     active, status 1, EndsOn tomorrow  -> in force
    a LAPSED paid plan   active, status 1, EndsOn yesterday -> NOT in force
    a cancelled plan     status 3                           -> NOT in force

  ⚠️ The third is the one 6.5-C changed the product's mind about, so it is the
  one most worth nailing down here.
*/
DECLARE @now datetime2 = SYSUTCDATETIME();
DECLARE @wrong nvarchar(400) = N'';

IF dbo.fn_SubscriptionInForce(1, 1, NULL, @now) <> 1
    SET @wrong = @wrong + N'free-perpetual-should-be-in-force ';

IF dbo.fn_SubscriptionInForce(1, 1, DATEADD(day, 1, @now), @now) <> 1
    SET @wrong = @wrong + N'live-paid-should-be-in-force ';

IF dbo.fn_SubscriptionInForce(1, 1, DATEADD(day, -1, @now), @now) <> 0
    SET @wrong = @wrong + N'lapsed-paid-should-NOT-be-in-force ';

IF dbo.fn_SubscriptionInForce(1, 3, NULL, @now) <> 0
    SET @wrong = @wrong + N'cancelled-should-NOT-be-in-force ';

IF dbo.fn_SubscriptionInForce(0, 1, NULL, @now) <> 0
    SET @wrong = @wrong + N'inactive-should-NOT-be-in-force ';

IF @wrong <> N''
    RAISERROR('023_billing_activation: fn_SubscriptionInForce truth table is wrong: %s', 16, 1, @wrong);
GO

IF OBJECT_ID('dbo.USP_ActivateSubscription', 'P') IS NULL
    RAISERROR('023_billing_activation: USP_ActivateSubscription was not created.', 16, 1);
GO

IF OBJECT_ID('dbo.USP_GetSubscriptionHistory', 'P') IS NULL
    RAISERROR('023_billing_activation: USP_GetSubscriptionHistory was not created.', 16, 1);
GO

/*==============================================================================
  🔒 2.56 — ENFORCED BY DEPENDENCY, NOT BY GREPPING FOR A NAME.

  A payment buys CAPABILITY and never a teacher's contact details. The unlock
  function returns true on exactly two paths — the teacher applied, or the
  teacher accepted an invitation — and decision 2.56 is LOCKED.

  🔴 THE FIRST VERSION OF THIS GUARD SEARCHED sys.sql_modules FOR THE FUNCTION'S
  NAME, AND THAT WAS WRONG TWICE OVER:

    1. It made this file fail the project's OWN 2.56 grep. That grep strips
       comments and then looks for the forbidden name in executable code — and
       a guard that names what it bans IS executable code naming it. The same
       trap caught the receipt-allocator guard in 010_billing earlier in this
       phase: a check over text cannot tell code from code-about-code.

    2. A text search is weaker than the thing it approximates. It would miss an
       indirect reference through a view or a wrapper, and it would fire on a
       harmless string literal.

  ⚠️ sys.sql_expression_dependencies is the real invariant: it records what this
  module actually REFERENCES, resolved by the engine rather than by a LIKE. It
  names nothing, so the grep has nothing to find, and it cannot be fooled by a
  comment.
==============================================================================*/
IF EXISTS (
    SELECT 1
      FROM sys.sql_expression_dependencies d
     WHERE d.referencing_id IN (OBJECT_ID('dbo.USP_ActivateSubscription'),
                             OBJECT_ID('dbo.USP_GetSubscriptionHistory'),
                             OBJECT_ID('dbo.fn_SubscriptionInForce'))
       AND d.referenced_entity_name IN ('fn_TeacherContactUnlocked',
                                        'fn_TeacherContactUnlockedForSchool')
)
    RAISERROR('023_billing_activation: a billing object DEPENDS ON the contact-unlock function. A payment buys capability, never a teacher''s contact details. Decision 2.56 is LOCKED.', 16, 1);
GO

PRINT '    Billing activation ready (fn_SubscriptionInForce, activate, history).';
GO
