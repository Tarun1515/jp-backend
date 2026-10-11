/*==============================================================================
  jp_mdm — 04_procedures / 010_billing.sql

  The manual billing path's jp_mdm half.

    USP_AllocateReceiptNo       RCP-YYYY-NNNNN, from a counter row (2.46)
    USP_GetPlanCatalog          the public plans for one user type
    USP_RequestPlanChange       request + pending payment, one transaction
    USP_GetPendingPayments      the admin queue
    USP_GetPaymentForVerify     one payment, with the expected amount beside it
    USP_VerifyPayment           the verify half of 6.5-A's seam — idempotent

  ---------------------------------------------------------------------------
  🔒 WHAT A PAYMENT BUYS, AND WHAT IT NEVER BUYS (2.56, LOCKED)
  ---------------------------------------------------------------------------
  Capability: whether a school may search at all, how many invitations it may
  send, whether it may post a job. NEVER a teacher's phone number or email.
  fn_TeacherContactUnlocked returns true on exactly two paths — the teacher
  applied, or the teacher accepted an invitation — and a verified payment is
  NOT a third one. The 2.56 greps assert that against this file.

  ---------------------------------------------------------------------------
  🔴 PENDING CHANGES NOTHING
  ---------------------------------------------------------------------------
  USP_RequestPlanChange writes a request and a PENDING payment and touches no
  entitlement, no subscription and no quota. The active subscription rules
  until a payment is verified. A pending request that quietly granted anything
  would mean the product gives capability away for an unpaid intention — and
  the verification proves the ledger is unchanged across that state.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*==============================================================================
  USP_AllocateReceiptNo — RCP-2026-00001.

  ---------------------------------------------------------------------------
  🔴 AN OUTPUT PARAMETER, NOT A RESULT SET — AND THAT IS THE WHOLE POINT
  ---------------------------------------------------------------------------
  USP_VerifyPayment EXECs this. An EXEC'd procedure emits its result sets to
  the CLIENT first, so a procedure that ended by returning the receipt number
  as a ROW would hand Dapper that row instead of its caller's
  Status/Code/Message — with no error anywhere. This project has made that
  exact mistake and recorded it.

  An OUTPUT parameter emits nothing. It is the only shape that composes.

  ⚠️ This paragraph deliberately does NOT spell out the forbidden statement.
  The build guard at the foot of this file reads sys.sql_modules.definition,
  which INCLUDES comments — so the first version of that guard matched this
  very explanation and failed the build on a correct procedure. A guard that
  cannot tell code from prose about code is a guard that cries wolf.

  ---------------------------------------------------------------------------
  🔴 WHY A COUNTER ROW AND NEVER MAX(...) + 1 (2.46)
  ---------------------------------------------------------------------------
  MAX + 1 races: two sessions read the same maximum before either inserts and
  both produce the same number. Nothing errors — the duplicate simply exists,
  until two schools quote the same receipt number to support.

  The UPDATE ... OUTPUT below takes an exclusive row lock for the rest of the
  caller's transaction, so concurrent verifications serialise on that one row
  and everything else stays parallel. This is the pattern
  USP_SubmitApprovalRequest established; that procedure is the origin and is
  deliberately NOT refactored to call this one — it is covered by 30 passing
  assertions, and changing working code to share a helper is risk with no
  product change.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_AllocateReceiptNo
    @ActorUserId bigint        = NULL,
    @ReceiptNo   varchar(30)   OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    /*
      🔴 The IST year, not the UTC one (2.28). A verification at 01:00 IST on
      1 January is still 31 December in UTC, and numbering it into the old year
      would show up on the first receipt of every year.
    */
    DECLARE @Year smallint = YEAR(dbo.fn_IstToday());
    DECLARE @Now  datetime2 = SYSUTCDATETIME();

    IF NOT EXISTS (SELECT 1 FROM dbo.t_mdm_receipt_number_series
                   WHERE SeriesYear = @Year AND Is_Deleted = 0)
    BEGIN
        /*
          Two sessions can both reach here for the first receipt of a year. The
          unique index makes one of them lose; that one specific collision is
          swallowed and both carry on to the UPDATE, which is what both
          actually need.
        */
        BEGIN TRY
            INSERT INTO dbo.t_mdm_receipt_number_series (SeriesYear, LastNumber, CreatedBy)
            VALUES (@Year, 0, @ActorUserId);
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() NOT IN (2601, 2627) THROW;
        END CATCH
    END

    DECLARE @Seq TABLE (NextNumber int);

    UPDATE s
       SET LastNumber = s.LastNumber + 1,
           ModifiedOn = @Now,
           ModifiedBy = @ActorUserId
    OUTPUT inserted.LastNumber INTO @Seq (NextNumber)
    FROM dbo.t_mdm_receipt_number_series AS s WITH (UPDLOCK, ROWLOCK)
    WHERE s.SeriesYear = @Year AND s.Is_Deleted = 0;

    DECLARE @NextNumber int = (SELECT TOP (1) NextNumber FROM @Seq);

    IF @NextNumber IS NULL
        THROW 50061, 'Could not allocate a receipt number.', 1;

    SET @ReceiptNo = 'RCP-' + CAST(@Year AS varchar(4)) + '-'
                   + RIGHT('00000' + CAST(@NextNumber AS varchar(10)), 5);
END
GO

/*==============================================================================
  USP_GetPlanCatalog — what this kind of account may buy.

  ---------------------------------------------------------------------------
  ⚠️ TODAY THIS RETURNS ONE ROW PER USER TYPE, AND THAT IS CORRECT
  ---------------------------------------------------------------------------
  Only the free plans are seeded. 008_seed_plans.sql forbids seeding paid tiers
  because pricing is not finalised and a number we ship gets quoted back — so
  a school sees a catalog containing "Free" and nothing to request. That is the
  same shape as 2.64 shipping an engine where nothing is gated: the mechanism
  is complete and the data is the client's (2.7).

  🔴 SCOPED BY UserTypeId, and the caller does not choose it. The API reads the
  user type from the token (2.39) — a teacher cannot ask for school plans, and
  the verification forces that negative.

  ⚠️ Two result sets: the plans, then their feature mappings. "What the plan
  maps to" is the half a customer actually compares, and one row per
  plan-feature is the honest shape for it — a concatenated string would be a
  display decision made in SQL.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetPlanCatalog
    @UserTypeId int
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        p.PlanId,
        p.PlanCode,
        p.Name,
        p.UserTypeId,
        p.DurationDays,
        p.Price,
        p.IsDefault,
        p.DisplayOrder,

        -- 🔴 Aliased for Dapper (2.61) — G25 is exactly this bug.
        p.Is_Active AS IsActive
    FROM dbo.m_mdm_plans p
    WHERE p.UserTypeId = @UserTypeId
      AND p.IsPublic   = 1
      AND p.Is_Active  = 1
      AND p.Is_Deleted = 0
    ORDER BY p.DisplayOrder, p.PlanId;

    /*
      The mappings, for the same plans only. A quota of NULL on an included
      feature means unlimited within the plan — the same convention
      USP_ConsumeFeatureCore's @QuotaPerPeriod uses, so the screen and the
      engine cannot disagree about what NULL means.
    */
    SELECT
        pf.PlanId,
        pf.FeatureId,
        f.FeatureCode,
        f.Name AS FeatureName,
        pf.IsIncluded,
        pf.QuotaPerPeriod
    FROM dbo.m_mdm_plan_features pf
    INNER JOIN dbo.m_mdm_features f ON f.FeatureId = pf.FeatureId
    INNER JOIN dbo.m_mdm_plans    p ON p.PlanId    = pf.PlanId
    WHERE p.UserTypeId = @UserTypeId
      AND p.IsPublic   = 1
      AND p.Is_Active  = 1
      AND p.Is_Deleted = 0
      AND pf.Is_Deleted = 0
      AND f.Is_Deleted  = 0
    ORDER BY pf.PlanId, f.DisplayOrder, f.FeatureId;
END
GO

/*==============================================================================
  USP_RequestPlanChange — the request, and the pending payment, atomically.

  ---------------------------------------------------------------------------
  🔴 ONE PROCEDURE BECAUSE BOTH ROWS ARE IN THIS DATABASE
  ---------------------------------------------------------------------------
  A request with no payment row is a dead request; a payment with no request
  violates its FK. Both tables are in jp_mdm, so atomicity is FREE — and this
  project's stated principle is that where an atomic guarantee is free, taking
  it is the difference between "the payment was recorded" and "the payment was
  probably recorded".

  ⚠️ Which is why it allocates the RequestNo itself rather than EXEC-ing
  USP_SubmitApprovalRequest: that procedure ends with a Status/Code/Message
  result set, and an EXEC'd procedure emits its result sets to the client
  FIRST — Dapper would read the wrong row with no error. The alternative,
  calling it from the service and then inserting the payment separately, gives
  up the free atomicity and leaves orphan PENDING requests behind every failed
  second call.

  ---------------------------------------------------------------------------
  🔴 ONE OPEN REQUEST PER OWNER
  ---------------------------------------------------------------------------
  Refused rather than allowed: a school with three pending plan-change requests
  gives the admin queue three rows for one intention and no way to know which
  one the school thinks it is paying for. Changing one's mind is handled by
  replacing the open request, not by stacking.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_RequestPlanChange
    @EntityUid        uniqueidentifier,
    @OrganizationUid  uniqueidentifier = NULL,
    @RequestorUserId  bigint,
    @UserTypeId       int,
    @PlanId           int,
    @PaymentModeId    int = 2               -- NEFT. The default the screen offers.
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now        datetime2 = SYSUTCDATETIME(),
            @Status     tinyint = 0,
            @Code       varchar(50) = NULL,
            @Message    nvarchar(400) = NULL,
            @RequestId  bigint = NULL,
            @RequestNo  varchar(30) = NULL,
            @PaymentId  bigint = NULL,
            @PaymentUid uniqueidentifier = NULL,
            @Price      decimal(10, 2) = NULL,
            @PlanName   nvarchar(100) = NULL,
            @PlanUserTypeId int = NULL,
            @PLAN_CHANGE int = 5,
            @PENDING     int = 1;

    -- ---- the plan must exist, be public, and belong to this user type -----
    SELECT @Price          = p.Price,
           @PlanName       = p.Name,
           @PlanUserTypeId = p.UserTypeId
      FROM dbo.m_mdm_plans p
     WHERE p.PlanId    = @PlanId
       AND p.IsPublic  = 1
       AND p.Is_Active = 1
       AND p.Is_Deleted = 0;

    IF @PlanName IS NULL
    BEGIN
        SELECT Status = 0, Code = 'NOT_FOUND',
               [Message] = N'That plan was not found.',
               RequestId = NULL, RequestNo = NULL, PaymentId = NULL,
               PaymentUid = NULL, PriceQuoted = NULL;
        RETURN;
    END

    /*
      🔴 A teacher cannot request a school plan (2.39 — the user type comes
      from the token, never from the request body).

      NOT_FOUND rather than FORBIDDEN, deliberately: 2.6 says a refusal must
      not confirm that something exists. A teacher probing plan ids learns
      nothing about the school tier line-up.
    */
    IF @PlanUserTypeId <> @UserTypeId
    BEGIN
        SELECT Status = 0, Code = 'NOT_FOUND',
               [Message] = N'That plan was not found.',
               RequestId = NULL, RequestNo = NULL, PaymentId = NULL,
               PaymentUid = NULL, PriceQuoted = NULL;
        RETURN;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        -- ---- one open request per owner -----------------------------------
        IF EXISTS (SELECT 1
                     FROM dbo.t_mdm_approval_requests r
                    WHERE r.RequestTypeId = @PLAN_CHANGE
                      AND r.EntityUid     = @EntityUid
                      AND r.StatusId      = @PENDING
                      AND r.Is_Deleted    = 0)
        BEGIN
        /*
          🔴 COMMIT, NOT ROLLBACK — AND THE REASON IS TWO REASONS.

          1. NOTHING HAS BEEN WRITTEN. This branch has taken locks and read;
             rolling back implies work was undone, which is a lie told in code
             to whoever reads it next.

          2. ROLLBACK makes this procedure unusable under INSERT ... EXEC,
             which fails with Msg 3915 — "Cannot use the ROLLBACK statement
             within an INSERT-EXEC statement". Found by running the real path:
             the first smoke test captured this procedure's result set that way
             and died on the refusal branch, not the happy one. A verification
             suite capturing results is the normal caller shape here, so a
             refusal path that only works when nobody is looking at it is not a
             refusal path.
        */
            COMMIT TRANSACTION;

            SELECT Status = 0, Code = 'ALREADY_REQUESTED',
                   [Message] = N'A plan change is already awaiting payment for this account.',
                   RequestId = NULL, RequestNo = NULL, PaymentId = NULL,
                   PaymentUid = NULL, PriceQuoted = NULL;
            RETURN;
        END

        -- ---- RequestNo, under the series row lock (2.46) -------------------
        DECLARE @Year smallint = YEAR(dbo.fn_IstToday());

        IF NOT EXISTS (SELECT 1 FROM dbo.t_mdm_request_number_series
                       WHERE RequestTypeId = @PLAN_CHANGE AND SeriesYear = @Year)
        BEGIN
            BEGIN TRY
                INSERT INTO dbo.t_mdm_request_number_series
                    (RequestTypeId, SeriesYear, LastNumber, CreatedBy)
                VALUES (@PLAN_CHANGE, @Year, 0, @RequestorUserId);
            END TRY
            BEGIN CATCH
                IF ERROR_NUMBER() NOT IN (2601, 2627) THROW;
            END CATCH
        END

        DECLARE @Seq TABLE (NextNumber int);

        UPDATE s
           SET LastNumber = s.LastNumber + 1,
               ModifiedOn = @Now,
               ModifiedBy = @RequestorUserId
        OUTPUT inserted.LastNumber INTO @Seq (NextNumber)
        FROM dbo.t_mdm_request_number_series AS s WITH (UPDLOCK, ROWLOCK)
        WHERE s.RequestTypeId = @PLAN_CHANGE AND s.SeriesYear = @Year;

        DECLARE @NextNumber int = (SELECT TOP (1) NextNumber FROM @Seq);

        IF @NextNumber IS NULL
            THROW 50062, 'Could not allocate a request number.', 1;

        DECLARE @Prefix varchar(10) =
            (SELECT RequestNoPrefix FROM dbo.m_mdm_request_types
              WHERE RequestTypeId = @PLAN_CHANGE);

        SET @RequestNo = @Prefix + '-' + CAST(@Year AS varchar(4)) + '-'
                       + RIGHT('00000' + CAST(@NextNumber AS varchar(10)), 5);

        -- ---- the request header -------------------------------------------
        INSERT INTO dbo.t_mdm_approval_requests
            (RequestNo, RequestTypeId, StatusId, CurrentApprovalLevel,
             EntityUid, OrganizationUid, RequestorUserId, SubmittedOn, CreatedBy)
        VALUES
            (@RequestNo, @PLAN_CHANGE, @PENDING, 1,
             @EntityUid, @OrganizationUid, @RequestorUserId, @Now, @RequestorUserId);

        SET @RequestId = CAST(SCOPE_IDENTITY() AS bigint);

        /*
          ---- the PENDING payment ----------------------------------------

          🔴 Amount starts at the plan's price — the amount EXPECTED. The admin
          overwrites it with what actually arrived (6.5-B), and PriceQuoted
          keeps the quoted figure so a later price change cannot restate this
          agreement (2.7).

          ⚠️ PaidOn stays NULL. Nothing has been paid; a date here would make
          an intention look like a transaction.
        */
        SET @PaymentUid = NEWID();

        INSERT INTO dbo.t_mdm_request_payments
            (RequestId, PlanId, Amount, PaymentModeId, PaymentStatusId,
             PriceQuoted, PaymentUid, CreatedBy)
        VALUES
            (@RequestId, @PlanId, @Price, @PaymentModeId, 1,
             @Price, @PaymentUid, @RequestorUserId);

        SET @PaymentId = CAST(SCOPE_IDENTITY() AS bigint);

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'Your request has been recorded.';
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        EXEC dbo.USP_LogError
            @ProcedureName = 'USP_RequestPlanChange',
            @UserId        = @RequestorUserId;

        THROW;
    END CATCH

    SELECT Status = @Status, Code = @Code, [Message] = @Message,
           RequestId = @RequestId, RequestNo = @RequestNo,
           PaymentId = @PaymentId, PaymentUid = @PaymentUid,
           PriceQuoted = @Price;
END
GO

/*==============================================================================
  USP_GetPendingPayments — the admin queue.

  ⚠️ Every alias here is for Dapper (2.61). The queue screen renders them.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetPendingPayments
    @PageNumber int = 1,
    @PageSize   int = 25
AS
BEGIN
    SET NOCOUNT ON;

    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize   IS NULL OR @PageSize   < 1 SET @PageSize   = 25;
    IF @PageSize > 100 SET @PageSize = 100;

    SELECT
        pay.PaymentId,
        pay.PaymentUid,
        pay.RequestId,
        r.RequestNo,
        r.EntityUid,
        r.OrganizationUid,
        r.RequestorUserId,
        r.SubmittedOn,
        pay.PlanId,
        pl.PlanCode,
        pl.Name         AS PlanName,
        pl.UserTypeId,
        pl.DurationDays,
        pay.Amount,
        pay.PriceQuoted,
        pay.PaymentModeId,
        pm.Name         AS PaymentModeName,
        pay.GatewayRefNo,
        pay.Remarks,
        pay.CreatedOn,

        /*
          🔴 The difference, computed here rather than on the screen.

          6.5-B: the amount recorded is what was RECEIVED, and a mismatch is
          shown rather than refused. Two screens computing this subtraction
          themselves is two chances to get the sign backwards — and a bill
          dispute is the worst place to discover which way round it was.

          Positive = short. Negative = overpaid.
        */
        CAST(ISNULL(pay.PriceQuoted, 0) - pay.Amount AS decimal(18, 2)) AS ShortBy,

        CAST(CASE WHEN pay.PriceQuoted IS NOT NULL AND pay.Amount <> pay.PriceQuoted
                  THEN 1 ELSE 0 END AS bit) AS AmountDiffers,

        TotalRecords = COUNT(*) OVER ()
    FROM dbo.t_mdm_request_payments pay
    INNER JOIN dbo.t_mdm_approval_requests r  ON r.RequestId      = pay.RequestId
    INNER JOIN dbo.m_mdm_payment_modes    pm  ON pm.PaymentModeId = pay.PaymentModeId
    LEFT  JOIN dbo.m_mdm_plans            pl  ON pl.PlanId        = pay.PlanId
    WHERE pay.PaymentStatusId = 1          -- PENDING
      AND pay.Is_Deleted      = 0
      AND r.Is_Deleted        = 0
    ORDER BY pay.CreatedOn DESC, pay.PaymentId DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END
GO

/*==============================================================================
  USP_GetPaymentForVerify — one payment, with everything the form needs.

  ⚠️ Shares the ShortBy / AmountDiffers shape with the queue above, on purpose:
  the form and the queue must not describe the same money differently.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetPaymentForVerify
    @PaymentId bigint
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        pay.PaymentId,
        pay.PaymentUid,
        pay.RequestId,
        r.RequestNo,
        r.EntityUid,
        r.OrganizationUid,
        r.StatusId      AS RequestStatusId,
        pay.PlanId,
        pl.PlanCode,
        pl.Name         AS PlanName,
        pl.UserTypeId,
        pl.DurationDays,
        pay.Amount,
        pay.PriceQuoted,
        pay.PaymentModeId,
        pm.Name         AS PaymentModeName,
        pay.GatewayRefNo,
        pay.Remarks,
        pay.PaymentStatusId,
        ps.Code         AS PaymentStatusCode,
        pay.PaidOn,
        pay.VerifiedByUserId,
        pay.CreatedOn,

        CAST(ISNULL(pay.PriceQuoted, 0) - pay.Amount AS decimal(18, 2)) AS ShortBy,
        CAST(CASE WHEN pay.PriceQuoted IS NOT NULL AND pay.Amount <> pay.PriceQuoted
                  THEN 1 ELSE 0 END AS bit) AS AmountDiffers,

        rcp.ReceiptNo,
        rcp.IssuedOn    AS ReceiptIssuedOn
    FROM dbo.t_mdm_request_payments pay
    INNER JOIN dbo.t_mdm_approval_requests r  ON r.RequestId        = pay.RequestId
    INNER JOIN dbo.m_mdm_payment_status   ps  ON ps.PaymentStatusId = pay.PaymentStatusId
    INNER JOIN dbo.m_mdm_payment_modes    pm  ON pm.PaymentModeId   = pay.PaymentModeId
    LEFT  JOIN dbo.m_mdm_plans            pl  ON pl.PlanId          = pay.PlanId
    LEFT  JOIN dbo.t_mdm_payment_receipts rcp ON rcp.PaymentId      = pay.PaymentId
                                             AND rcp.Is_Deleted     = 0
    WHERE pay.PaymentId  = @PaymentId
      AND pay.Is_Deleted = 0;
END
GO

/*==============================================================================
  USP_VerifyPayment — the verify half of the seam (6.5-A).

  ---------------------------------------------------------------------------
  🔴 IT DOES NOT ACTIVATE ANYTHING, AND CANNOT
  ---------------------------------------------------------------------------
  The subscription is in jp_app and no query may cross (2.2). This procedure
  records that money arrived and returns everything the activation half needs
  — owner, plan, duration — so the SERVICE can call USP_ActivateSubscription
  next (2.48: two transactions, and the truth about the handoff is reported
  rather than smoothed over).

  ---------------------------------------------------------------------------
  🔴 IDEMPOTENT, AND THE ALREADY-DONE PATH RETURNS THE SAME PAYLOAD
  ---------------------------------------------------------------------------
  Verifying twice must produce one receipt and one activation. The second call
  reports Status 1 and returns the SAME owner/plan/duration — which is what
  lets a retry after a half-completed verification finish the activation
  instead of reporting success and doing nothing.

  ⚠️ The guard is on PaymentStatusId, and the receipt's own
  UQ_t_mdm_payment_receipts_PaymentId is the structural half: a race that got
  two sessions past the status read resolves to one receipt number.

  ---------------------------------------------------------------------------
  🔴 NO PRICE ENFORCEMENT (6.5-B)
  ---------------------------------------------------------------------------
  @Amount is recorded as given. A school that transferred less than the price
  HAS paid that amount, and a procedure that refused to record it would not
  prevent an underpayment — it would make the real state of the world
  unrepresentable, and the correction would happen in SSMS with no trail.

  The "a mismatch needs a remark" rule is an API-layer rule, because the
  GATEWAY caller has nobody to ask for one (6.5-A). Putting it here would make
  the seam a hope.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_VerifyPayment
    @PaymentId        bigint,
    @Amount           decimal(18, 2) = NULL,
    @PaymentModeId    int            = NULL,
    @GatewayRefNo     varchar(100)   = NULL,
    @Remarks          nvarchar(500)  = NULL,
    @PaidOn           datetime2      = NULL,
    @VerifiedByUserId bigint         = NULL,
    @VerifiedVia      varchar(10)    = 'ADMIN'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now       datetime2 = SYSUTCDATETIME(),
            @Status    tinyint = 0,
            @Code      varchar(50) = NULL,
            @Message   nvarchar(400) = NULL,
            @ReceiptNo varchar(30) = NULL,
            @Already   bit = 0,
            @RequestId bigint = NULL,
            @EntityUid uniqueidentifier = NULL,
            @PlanId    int = NULL,
            @PlanName  nvarchar(100) = NULL,
            @Duration  int = NULL,
            @PaymentUid uniqueidentifier = NULL,
            @PriceQuoted decimal(10, 2) = NULL,
            @ModeId    int = NULL,
            @CurrentStatusId int = NULL,
            @ExistingReceipt varchar(30) = NULL;

    /*
      🔴 The CHECK constraint on the receipt says an ADMIN verification must
      name the admin. Refusing here as well gives the caller a readable answer
      instead of a constraint violation — and the constraint remains, because a
      message is not a guard (2.36).
    */
    IF @VerifiedVia NOT IN ('ADMIN', 'GATEWAY')
       OR (@VerifiedVia = 'ADMIN' AND @VerifiedByUserId IS NULL)
    BEGIN
        SELECT Status = 0, Code = 'VALIDATION_FAILED',
               [Message] = N'An admin verification must record which admin verified it.',
               ReceiptNo = NULL, AlreadyVerified = CAST(0 AS bit),
               EntityUid = NULL, PlanId = NULL, PlanName = NULL,
               DurationDays = NULL, PaymentUid = NULL, RequestId = NULL;
        RETURN;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        /*
          The payment row, locked. UPDLOCK so two admins verifying the same
          payment serialise here rather than both reading PENDING.
        */
        SELECT @CurrentStatusId = pay.PaymentStatusId,
               @RequestId       = pay.RequestId,
               @PlanId          = pay.PlanId,
               @PaymentUid      = pay.PaymentUid,
               @PriceQuoted     = pay.PriceQuoted,
               @ModeId          = pay.PaymentModeId
          FROM dbo.t_mdm_request_payments pay WITH (UPDLOCK, ROWLOCK)
         WHERE pay.PaymentId  = @PaymentId
           AND pay.Is_Deleted = 0;

        IF @CurrentStatusId IS NULL
        BEGIN
            /* COMMIT, not ROLLBACK — see USP_RequestPlanChange's note. Nothing
               was written, and ROLLBACK here would break INSERT ... EXEC. */
            COMMIT TRANSACTION;

            SELECT Status = 0, Code = 'NOT_FOUND',
                   [Message] = N'That payment was not found.',
                   ReceiptNo = NULL, AlreadyVerified = CAST(0 AS bit),
                   EntityUid = NULL, PlanId = NULL, PlanName = NULL,
                   DurationDays = NULL, PaymentUid = NULL, RequestId = NULL;
            RETURN;
        END

        SELECT @EntityUid = r.EntityUid FROM dbo.t_mdm_approval_requests r
         WHERE r.RequestId = @RequestId;

        SELECT @PlanName = p.Name, @Duration = p.DurationDays
          FROM dbo.m_mdm_plans p WHERE p.PlanId = @PlanId;

        /*
          ---- already verified? -------------------------------------------

          Status 2 = SUCCESS. Returns the SAME payload as a first verification,
          so the caller can carry on to activation — which is exactly how a
          retry of a half-completed verification completes.
        */
        IF @CurrentStatusId = 2
        BEGIN
            SELECT @ExistingReceipt = rcp.ReceiptNo
              FROM dbo.t_mdm_payment_receipts rcp
             WHERE rcp.PaymentId = @PaymentId AND rcp.Is_Deleted = 0;

            COMMIT TRANSACTION;

            SELECT Status = 1, Code = NULL,
                   [Message] = N'This payment was already verified.',
                   ReceiptNo = @ExistingReceipt, AlreadyVerified = CAST(1 AS bit),
                   EntityUid = @EntityUid, PlanId = @PlanId, PlanName = @PlanName,
                   DurationDays = @Duration, PaymentUid = @PaymentUid,
                   RequestId = @RequestId;
            RETURN;
        END

        -- ---- record what arrived ------------------------------------------
        UPDATE dbo.t_mdm_request_payments
           SET Amount           = ISNULL(@Amount, Amount),
               PaymentModeId    = ISNULL(@PaymentModeId, PaymentModeId),
               GatewayRefNo     = ISNULL(@GatewayRefNo, GatewayRefNo),
               Remarks          = ISNULL(@Remarks, Remarks),
               PaymentStatusId  = 2,
               PaidOn           = ISNULL(@PaidOn, @Now),
               VerifiedByUserId = @VerifiedByUserId,
               ModifiedOn       = @Now,
               ModifiedBy       = @VerifiedByUserId
         WHERE PaymentId = @PaymentId;

        -- ---- the receipt number, from the counter (2.46) ------------------
        EXEC dbo.USP_AllocateReceiptNo
             @ActorUserId = @VerifiedByUserId,
             @ReceiptNo   = @ReceiptNo OUTPUT;

        /*
          The receipt itself. Amounts DENORMALISED on purpose — see the table's
          header: a receipt states what was true when it was issued, and one
          that joined out for its own numbers would restate history whenever a
          price changed.

          ⚠️ PeriodStartsOn is @Now and PeriodEndsOn is computed the same way
          the activation computes EndsOn, because the receipt must say the same
          thing as the subscription it pays for. It is NOT read back from
          jp_app — that would be a cross-database read (2.2).
        */
        DECLARE @PeriodEnds datetime2 = CASE
            WHEN @Duration IS NULL THEN NULL
            ELSE dbo.fn_IstDateToUtc(DATEADD(day, @Duration, CAST(dbo.fn_ToIst(@Now) AS date)))
        END;

        INSERT INTO dbo.t_mdm_payment_receipts
            (ReceiptNo, PaymentId, Amount, PriceQuoted, PaymentModeId, PaymentRefNo,
             PlanId, PlanName, PeriodStartsOn, PeriodEndsOn,
             VerifiedByUserId, VerifiedVia, IssuedOn, CreatedBy)
        VALUES
            (@ReceiptNo, @PaymentId, ISNULL(@Amount, @PriceQuoted), @PriceQuoted,
             ISNULL(@PaymentModeId, @ModeId), @GatewayRefNo,
             @PlanId, @PlanName, @Now, @PeriodEnds,
             @VerifiedByUserId, @VerifiedVia, @Now, @VerifiedByUserId);

        /*
          ---- and the request is done -------------------------------------

          StatusId 3 = APPROVED. This type has one final level and the payment
          verification IS its decision, so there is no second level to walk.
        */
        UPDATE dbo.t_mdm_approval_requests
           SET StatusId      = 3,
               ApproverUserId = @VerifiedByUserId,
               CompletedOn   = @Now,
               ModifiedOn    = @Now,
               ModifiedBy    = @VerifiedByUserId
         WHERE RequestId = @RequestId;

        COMMIT TRANSACTION;

        SET @Status  = 1;
        SET @Message = N'The payment is verified.';
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        /*
          🔴 2601/2627 = the race, not a bug: two sessions got past the status
          read and one lost on UQ_t_mdm_payment_receipts_PaymentId. The loser
          is told the truth and handed the winner's receipt, so its caller can
          still go on to activate (which is itself idempotent).
        */
        IF ERROR_NUMBER() IN (2601, 2627)
        BEGIN
            SELECT @ExistingReceipt = rcp.ReceiptNo
              FROM dbo.t_mdm_payment_receipts rcp
             WHERE rcp.PaymentId = @PaymentId AND rcp.Is_Deleted = 0;

            SELECT Status = 1, Code = NULL,
                   [Message] = N'This payment was already verified.',
                   ReceiptNo = @ExistingReceipt, AlreadyVerified = CAST(1 AS bit),
                   EntityUid = @EntityUid, PlanId = @PlanId, PlanName = @PlanName,
                   DurationDays = @Duration, PaymentUid = @PaymentUid,
                   RequestId = @RequestId;
            RETURN;
        END

        EXEC dbo.USP_LogError
            @ProcedureName = 'USP_VerifyPayment',
            @UserId        = @VerifiedByUserId;

        THROW;
    END CATCH

    SELECT Status = @Status, Code = @Code, [Message] = @Message,
           ReceiptNo = @ReceiptNo, AlreadyVerified = CAST(0 AS bit),
           EntityUid = @EntityUid, PlanId = @PlanId, PlanName = @PlanName,
           DurationDays = @Duration, PaymentUid = @PaymentUid,
           RequestId = @RequestId;
END
GO

/*==============================================================================
  BUILD GUARDS
==============================================================================*/
DECLARE @missing nvarchar(400) = N'';

IF OBJECT_ID('dbo.USP_AllocateReceiptNo', 'P') IS NULL SET @missing = @missing + N'USP_AllocateReceiptNo ';
IF OBJECT_ID('dbo.USP_GetPlanCatalog',    'P') IS NULL SET @missing = @missing + N'USP_GetPlanCatalog ';
IF OBJECT_ID('dbo.USP_RequestPlanChange', 'P') IS NULL SET @missing = @missing + N'USP_RequestPlanChange ';
IF OBJECT_ID('dbo.USP_GetPendingPayments','P') IS NULL SET @missing = @missing + N'USP_GetPendingPayments ';
IF OBJECT_ID('dbo.USP_GetPaymentForVerify','P') IS NULL SET @missing = @missing + N'USP_GetPaymentForVerify ';
IF OBJECT_ID('dbo.USP_VerifyPayment',     'P') IS NULL SET @missing = @missing + N'USP_VerifyPayment ';

IF @missing <> N''
    RAISERROR('010_billing: missing after run: %s', 16, 1, @missing);
GO

/*==============================================================================
  🔴 THE ALLOCATOR MUST HAND ITS ANSWER BACK AS A PARAMETER, NOT A ROW.

  The trap: an EXEC'd procedure emits its result sets to the CLIENT first, so
  an allocator that returned its number as a row would make
  USP_VerifyPayment's caller silently read a receipt number where it expected
  Status/Code/Message — with no error anywhere. This project has made that
  exact mistake, so it is checked rather than trusted.

  ⚠️ CHECKED STRUCTURALLY, and the first version was not.

  That version grepped sys.sql_modules.definition for the forbidden statement
  — and definition INCLUDES comments, so it matched the paragraph in this
  file's own header that EXPLAINS the rule, and failed the build on a correct
  procedure. The lesson is general: a text guard over a module body cannot
  distinguish code from prose about code.

  So the real assertion is the one that cannot be fooled: the procedure HAS an
  output parameter. The text check is kept as a second line, narrowed to a
  pattern that only executable code produces.
==============================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.parameters
               WHERE object_id = OBJECT_ID('dbo.USP_AllocateReceiptNo')
                 AND name = '@ReceiptNo'
                 AND is_output = 1)
    RAISERROR('010_billing: USP_AllocateReceiptNo has no @ReceiptNo OUTPUT parameter. It is EXEC''d by USP_VerifyPayment, and an allocator that returns its number as a ROW hands Dapper the wrong row with no error.', 16, 1);
GO

/*
  The narrowed text check: a terminating SELECT of the number would be written
  as its own statement. 'SELECT @ReceiptNo;' and 'SELECT @ReceiptNo AS' are
  code; neither reads naturally in a sentence.
*/
IF EXISTS (SELECT 1 FROM sys.sql_modules
           WHERE object_id = OBJECT_ID('dbo.USP_AllocateReceiptNo')
             AND (definition LIKE '%SELECT @ReceiptNo;%'
               OR definition LIKE '%SELECT @ReceiptNo AS%'
               OR definition LIKE '%SELECT ReceiptNo = @ReceiptNo%'))
    RAISERROR('010_billing: USP_AllocateReceiptNo returns its number as a row. Use the OUTPUT parameter — see this file''s guard header.', 16, 1);
GO

/*
  🔴 NEVER MAX()+1 (2.46). Both allocators checked — the receipt one and the
  request-number one inside USP_RequestPlanChange.
*/
IF EXISTS (SELECT 1 FROM sys.sql_modules
           WHERE object_id IN (OBJECT_ID('dbo.USP_AllocateReceiptNo'),
                               OBJECT_ID('dbo.USP_RequestPlanChange'))
             AND (definition LIKE '%MAX(LastNumber)%'
               OR definition LIKE '%MAX(ReceiptNo)%'
               OR definition LIKE '%MAX(RequestNo)%'))
    RAISERROR('010_billing: a number is being allocated with MAX(...). Two sessions read the same maximum and both win — silently (2.46). Use the counter row under UPDLOCK.', 16, 1);
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
     WHERE d.referencing_id IN (OBJECT_ID('dbo.USP_VerifyPayment'),
                             OBJECT_ID('dbo.USP_RequestPlanChange'),
                             OBJECT_ID('dbo.USP_GetPlanCatalog'),
                             OBJECT_ID('dbo.USP_GetPendingPayments'),
                             OBJECT_ID('dbo.USP_GetPaymentForVerify'))
       AND d.referenced_entity_name IN ('fn_TeacherContactUnlocked',
                                        'fn_TeacherContactUnlockedForSchool')
)
    RAISERROR('010_billing: a billing object DEPENDS ON the contact-unlock function. A payment buys capability, never a teacher''s contact details. Decision 2.56 is LOCKED.', 16, 1);
GO

/*
  🔴 NO REFUSAL PATH MAY ROLLBACK A TRANSACTION IT DID NOT WRITE IN.

  ROLLBACK inside a procedure called via INSERT ... EXEC fails with Msg 3915,
  and a refusal branch is the least-exercised code in any procedure — so it is
  exactly where that lands unnoticed. Found by running the real path, not by
  reading.

  ⚠️ This counts ROLLBACKs and expects them ONLY in CATCH blocks, where there
  genuinely is work to undo. Both procedures have exactly one each.
*/
DECLARE @rollbacks int;

SELECT @rollbacks = (LEN(m.definition) - LEN(REPLACE(m.definition, 'ROLLBACK TRANSACTION', ''))) / LEN('ROLLBACK TRANSACTION')
  FROM sys.sql_modules m WHERE m.object_id = OBJECT_ID('dbo.USP_RequestPlanChange');

IF @rollbacks <> 1
    RAISERROR('010_billing: USP_RequestPlanChange has %d ROLLBACKs; it should have exactly one, in its CATCH. A refusal path that rolls back breaks INSERT ... EXEC (Msg 3915).', 16, 1, @rollbacks);

SELECT @rollbacks = (LEN(m.definition) - LEN(REPLACE(m.definition, 'ROLLBACK TRANSACTION', ''))) / LEN('ROLLBACK TRANSACTION')
  FROM sys.sql_modules m WHERE m.object_id = OBJECT_ID('dbo.USP_VerifyPayment');

IF @rollbacks <> 1
    RAISERROR('010_billing: USP_VerifyPayment has %d ROLLBACKs; it should have exactly one, in its CATCH.', 16, 1, @rollbacks);
GO

PRINT '    Billing procedures ready (catalog, request, queue, verify, receipts).';
GO
