/*==============================================================================
  jp_mdm — 04_procedures / 009_entitlement_catalog.sql

  The consume path's resolution query, and the admin plan × feature screen.
  Phase 2.5.

  ---------------------------------------------------------------------------
  🔴 THE PROHIBITION THIS ENGINE CARRIES EVERYWHERE (2.56 — LOCKED)
  ---------------------------------------------------------------------------
  The entitlement engine and contact unlock never reference each other, in
  either direction. A subscription buys the school's CAPABILITY — whether it
  may search at all, how many invites it may send — never a teacher's contact
  details. Nothing here may appear in fn_TeacherContactUnlocked, and its two
  consent paths may never appear here.

  ---------------------------------------------------------------------------
  🔴 USP_ResolveEntitlement IS NEVER SERVED FROM THE MASTER CACHE
  ---------------------------------------------------------------------------
  Features and gating modes are master data by every structural test — m_mdm_*
  tables, pure reference data, read constantly, changed almost never. Everything
  about them says "put them behind IMasterService", and IMasterService is the
  most obvious place in this codebase to add an IMemoryCache.

  If that ever happens and gating is on that path, the kill switch engages up to
  an hour after the operator flips it — during exactly the incident it was
  flipped for — and a FREE -> METERED change keeps serving free until the cache
  turns. Both fail silently, with the admin screen showing the new value the
  whole time.

  So the consume path has its OWN repository (IEntitlementRepository) which
  never touches IMasterService and is never given a cache. Phase 2.5's
  verification greps for that and shows the output.

  ⚠️ A stale subject name for an hour is cosmetic. A stale entitlement for an
  hour is an unsellable kill switch and unbilled usage. Same storage, same
  access pattern, completely different tolerance.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  USP_ResolveEntitlement — one query, one round trip, on every consume.

  ---------------------------------------------------------------------------
  🔴 ONE QUERY, NOT TWO — AND THAT IS A CORRECTNESS PROPERTY
  ---------------------------------------------------------------------------
  The feature's mode and the plan's quota come back together. Read separately,
  an admin flip landing between the two reads could hand the engine a
  combination that never existed in the database — say METERED from the first
  read with a quota row that had just been deleted by the second.

  ⚠️ The LEFT JOIN is the point. A missing mapping must be distinguishable from
  a mapping with a zero quota, so HasMapping is returned explicitly rather than
  being inferred from a NULL. Absence of a row is absence of a decision, and the
  engine refuses on it (PLAN_LACKS_FEATURE).

  Returns AT MOST one row. No row at all means the feature code is unknown,
  which the service treats as FEATURE_DISABLED — the same answer as a switched
  off feature, deliberately: an operator asking "why did that stop working"
  should get one answer, not two that mean the same thing to them.

  ⚠️ An INACTIVE feature still returns its row. The service needs to tell "no
  such feature" from "switched off" in its LOGS even though the caller is told
  the same thing.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_ResolveEntitlement
    @FeatureCode varchar(50),
    @PlanId      int
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        f.FeatureId,
        f.FeatureCode,
        f.Name,
        f.GatingModeId,
        f.AppliesToUserTypeId,

        /*
          🔴 Aliased. Dapper does not strip underscores, so Is_Active would
          never reach an IsActive property and would arrive as false with
          nothing failing (2.61, incident G25).

          ⚠️ On THIS column the silent-false failure is the worst possible one:
          every feature would read as switched off and the engine would refuse
          everything, everywhere. Phase 2.5's HTTP verification reads the row
          and the JSON for exactly this column and asserts both are TRUE.
        */
        f.Is_Active AS IsActive,

        CASE WHEN pf.PlanFeatureId IS NULL THEN CAST(0 AS tinyint) ELSE CAST(1 AS tinyint) END AS HasMapping,
        ISNULL(pf.IsIncluded, CAST(0 AS tinyint))                                              AS IsIncluded,
        pf.QuotaPerPeriod
    FROM dbo.m_mdm_features f
        LEFT JOIN dbo.m_mdm_plan_features pf
               ON pf.FeatureId  = f.FeatureId
              AND pf.PlanId     = @PlanId
              AND pf.Is_Active  = 1
              AND pf.Is_Deleted = 0
    WHERE f.FeatureCode = @FeatureCode
      AND f.Is_Deleted  = 0;
END
GO


/*==============================================================================
  USP_GetEntitlementMatrix — everything the admin screen draws, in four sets.

  ---------------------------------------------------------------------------
  ⚠️ FOUR RESULT SETS RATHER THAN ONE PRE-JOINED GRID
  ---------------------------------------------------------------------------
  A cross-joined grid would have to invent a row for every plan × feature pair
  and mark most of them "unmapped" — and then the client could not tell an
  invented row from a real one carrying zeros.

  Sending the three real tables and letting the client compose the grid keeps
  UNMAPPED as what it actually is: the absence of a row. That is exactly the
  distinction the engine refuses on, so the screen and the engine agree by
  construction rather than by two separate implementations of the same rule.

    1. plans          — the columns
    2. features       — the rows, with mode and the kill switch
    3. mappings       — the cells that exist. Everything else is UNMAPPED.
    4. gating modes   — the dropdown, from data (2.7)
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetEntitlementMatrix
AS
BEGIN
    SET NOCOUNT ON;

    -- 1. Plans.
    SELECT
        p.PlanId,
        p.PlanCode,
        p.Name,
        p.UserTypeId,
        p.Price,
        p.IsDefault,
        p.Is_Active AS IsActive      -- 🔴 2.61
    FROM dbo.m_mdm_plans p
    WHERE p.Is_Deleted = 0
    ORDER BY p.UserTypeId, p.DisplayOrder, p.PlanId;

    -- 2. Features.
    SELECT
        f.FeatureId,
        f.FeatureCode,
        f.Name,
        f.Description,
        f.GatingModeId,
        gm.Code     AS GatingModeCode,
        gm.Name     AS GatingModeName,
        f.AppliesToUserTypeId,
        f.DisplayOrder,
        f.Is_Active AS IsActive      -- 🔴 2.61 — this is the kill switch
    FROM dbo.m_mdm_features f
        INNER JOIN dbo.m_mdm_gating_modes gm ON gm.GatingModeId = f.GatingModeId
    WHERE f.Is_Deleted = 0
    ORDER BY f.AppliesToUserTypeId, f.DisplayOrder, f.FeatureId;

    -- 3. Mappings that exist. Absence here is UNMAPPED, and that is a decision.
    SELECT
        pf.PlanFeatureId,
        pf.PlanId,
        pf.FeatureId,
        pf.IsIncluded,
        pf.QuotaPerPeriod,
        pf.Is_Active AS IsActive     -- 🔴 2.61
    FROM dbo.m_mdm_plan_features pf
    WHERE pf.Is_Deleted = 0
    ORDER BY pf.PlanId, pf.FeatureId;

    -- 4. Gating modes — the dropdown is data, never a hardcoded list (2.7).
    SELECT
        gm.GatingModeId,
        gm.Code,
        gm.Name,
        gm.Description,
        gm.DisplayOrder
    FROM dbo.m_mdm_gating_modes gm
    WHERE gm.Is_Deleted = 0 AND gm.Is_Active = 1
    ORDER BY gm.DisplayOrder;
END
GO


/*==============================================================================
  USP_SaveFeatureGating — set a feature's mode, or work its kill switch.

  ⚠️ ONE PROCEDURE, TWO INDEPENDENT COLUMNS, AND THAT IS THE POINT.

  GatingModeId answers "how is access decided". Is_Active answers "does this
  feature exist right now". Switching a feature off must not disturb how it was
  gated, or restoring it depends on somebody remembering — during an incident.

  Both are passed on every call because the screen holds both; passing them
  separately would need two round trips for what an operator experiences as one
  edit.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SaveFeatureGating
    @FeatureId    int,
    @GatingModeId tinyint,
    @IsActive     tinyint,
    @ActorUserId  bigint = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL, @Message nvarchar(400) = NULL;

    IF NOT EXISTS (SELECT 1 FROM dbo.m_mdm_features WHERE FeatureId = @FeatureId AND Is_Deleted = 0)
    BEGIN
        SELECT 0 AS [Status], 'NOT_FOUND' AS Code,
               N'That feature does not exist.' AS [Message], NULL AS Id;
        RETURN;
    END

    /*
      The CHECK constraint would catch this too, but as a 547 that reaches the
      client as an unhandled failure. A refusal the caller can branch on is the
      contract (2.21) — and this one carries the actual reason, which the
      constraint violation would not.
    */
    IF @GatingModeId NOT IN (1, 2, 3)
    BEGIN
        SELECT 0 AS [Status], 'BUSINESS_RULE_VIOLATED' AS Code,
               N'That gating mode does not exist in this build.' AS [Message], NULL AS Id;
        RETURN;
    END

    IF @IsActive NOT IN (0, 1)
    BEGIN
        SELECT 0 AS [Status], 'VALIDATION_FAILED' AS Code,
               N'The kill switch must be on or off.' AS [Message], NULL AS Id;
        RETURN;
    END

    BEGIN TRY
        UPDATE dbo.m_mdm_features
        SET GatingModeId = @GatingModeId,
            Is_Active    = @IsActive,
            ModifiedOn   = SYSUTCDATETIME(),
            ModifiedBy   = @ActorUserId
        WHERE FeatureId = @FeatureId
          AND Is_Deleted = 0;

        SET @Status = 1;
    END TRY
    BEGIN CATCH
        DECLARE @E int = ERROR_NUMBER(), @S int = ERROR_SEVERITY(), @T int = ERROR_STATE(),
                @P sysname = ERROR_PROCEDURE(), @L int = ERROR_LINE(),
                @M nvarchar(4000) = ERROR_MESSAGE();

        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        DECLARE @Params nvarchar(max) = (
            SELECT @FeatureId AS featureId, @GatingModeId AS gatingModeId, @IsActive AS isActive
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC dbo.USP_LogError @ErrorNumber = @E, @ErrorSeverity = @S, @ErrorState = @T,
             @ErrorProcedure = @P, @ErrorLine = @L, @ErrorMessage = @M,
             @ParametersJson = @Params, @ContextInfo = N'USP_SaveFeatureGating',
             @CreatedBy = @ActorUserId;

        THROW;
    END CATCH

    SELECT @Status AS [Status], @Code AS Code, @Message AS [Message],
           CAST(@FeatureId AS bigint) AS Id;
END
GO


/*==============================================================================
  USP_SavePlanFeature — map a feature to a plan, or unmap it.

  @Action = 'MAP'   — create or update the cell
  @Action = 'UNMAP' — soft-delete it, returning the cell to UNMAPPED

  ---------------------------------------------------------------------------
  🔴 UNMAP IS A SOFT DELETE, AND UNMAPPED MEANS DENIED
  ---------------------------------------------------------------------------
  Removing a mapping removes access from that plan. That is the safe direction
  for a screen an administrator edits by hand: the destructive mis-click takes
  capability away from one plan rather than granting it to everybody.

  The row survives with Is_Deleted = 1, so the filtered unique index lets the
  same pair be mapped again later (2.4) and the history of what was once
  included stays readable.

  ---------------------------------------------------------------------------
  ⚠️ A SCHOOL FEATURE CANNOT BE MAPPED TO A TEACHER PLAN
  ---------------------------------------------------------------------------
  Not a pricing mistake — a mapping whose limits mean nothing, because no
  teacher account will ever consume JOB_POST. Refused here rather than filtered
  only in the UI, because a rule that lives in a screen is a rule the next
  screen will not have.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SavePlanFeature
    @PlanId          int,
    @FeatureId       int,
    @Action          varchar(10),          -- MAP | UNMAP
    @IsIncluded      tinyint = 0,
    @QuotaPerPeriod  int     = NULL,
    @ActorUserId     bigint  = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL, @Message nvarchar(400) = NULL,
            @Id bigint = NULL,
            @PlanUserType int, @FeatureUserType int, @ExistingId int;

    SELECT @PlanUserType = p.UserTypeId
    FROM dbo.m_mdm_plans p
    WHERE p.PlanId = @PlanId AND p.Is_Deleted = 0;

    SELECT @FeatureUserType = f.AppliesToUserTypeId
    FROM dbo.m_mdm_features f
    WHERE f.FeatureId = @FeatureId AND f.Is_Deleted = 0;

    IF @PlanUserType IS NULL OR @FeatureUserType IS NULL
    BEGIN
        SELECT 0 AS [Status], 'NOT_FOUND' AS Code,
               N'That plan or feature does not exist.' AS [Message], NULL AS Id;
        RETURN;
    END

    IF @Action NOT IN ('MAP', 'UNMAP')
    BEGIN
        SELECT 0 AS [Status], 'VALIDATION_FAILED' AS Code,
               N'Unknown action.' AS [Message], NULL AS Id;
        RETURN;
    END

    IF @Action = 'MAP' AND @PlanUserType <> @FeatureUserType
    BEGIN
        SELECT 0 AS [Status], 'BUSINESS_RULE_VIOLATED' AS Code,
               N'That feature belongs to a different kind of account than this plan.' AS [Message], NULL AS Id;
        RETURN;
    END

    IF @Action = 'MAP' AND @QuotaPerPeriod IS NOT NULL AND @QuotaPerPeriod < 0
    BEGIN
        SELECT 0 AS [Status], 'VALIDATION_FAILED' AS Code,
               N'A quota cannot be negative. Leave it empty for unlimited.' AS [Message], NULL AS Id;
        RETURN;
    END

    BEGIN TRY
        SELECT @ExistingId = pf.PlanFeatureId
        FROM dbo.m_mdm_plan_features pf
        WHERE pf.PlanId = @PlanId AND pf.FeatureId = @FeatureId AND pf.Is_Deleted = 0;

        IF @Action = 'UNMAP'
        BEGIN
            IF @ExistingId IS NULL
            BEGIN
                -- Already unmapped. Asking twice is not an error (2.48).
                SELECT @Status = 1, @Code = 'ALREADY_UNMAPPED',
                       @Message = N'That combination was already unmapped.';
            END
            ELSE
            BEGIN
                UPDATE dbo.m_mdm_plan_features
                SET Is_Deleted = 1,
                    ModifiedOn = SYSUTCDATETIME(),
                    ModifiedBy = @ActorUserId
                WHERE PlanFeatureId = @ExistingId;

                SELECT @Status = 1, @Id = @ExistingId;
            END
        END
        ELSE IF @ExistingId IS NOT NULL
        BEGIN
            UPDATE dbo.m_mdm_plan_features
            SET IsIncluded     = @IsIncluded,
                QuotaPerPeriod = @QuotaPerPeriod,
                Is_Active      = 1,
                ModifiedOn     = SYSUTCDATETIME(),
                ModifiedBy     = @ActorUserId
            WHERE PlanFeatureId = @ExistingId;

            SELECT @Status = 1, @Id = @ExistingId;
        END
        ELSE
        BEGIN
            INSERT INTO dbo.m_mdm_plan_features
                (PlanId, FeatureId, IsIncluded, QuotaPerPeriod, CreatedBy)
            VALUES
                (@PlanId, @FeatureId, @IsIncluded, @QuotaPerPeriod, @ActorUserId);

            SELECT @Status = 1, @Id = CAST(SCOPE_IDENTITY() AS bigint);
        END
    END TRY
    BEGIN CATCH
        DECLARE @E int = ERROR_NUMBER(), @S int = ERROR_SEVERITY(), @T int = ERROR_STATE(),
                @P sysname = ERROR_PROCEDURE(), @L int = ERROR_LINE(),
                @M nvarchar(4000) = ERROR_MESSAGE();

        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        /*
          ⚠️ 2601 here means a concurrent save mapped the same pair first —
          which is what this caller wanted (2.48). Reported as done, but only
          after RE-READING the row.
        */
        IF @E IN (2601, 2627)
        BEGIN
            SELECT @Id = pf.PlanFeatureId
            FROM dbo.m_mdm_plan_features pf
            WHERE pf.PlanId = @PlanId AND pf.FeatureId = @FeatureId AND pf.Is_Deleted = 0;

            IF @Id IS NOT NULL
                SELECT @Status = 1, @Code = 'ALREADY_MAPPED',
                       @Message = N'That combination was already mapped.';
        END

        IF @Status = 0
        BEGIN
            DECLARE @Params nvarchar(max) = (
                SELECT @PlanId AS planId, @FeatureId AS featureId, @Action AS action
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @E, @ErrorSeverity = @S, @ErrorState = @T,
                 @ErrorProcedure = @P, @ErrorLine = @L, @ErrorMessage = @M,
                 @ParametersJson = @Params, @ContextInfo = N'USP_SavePlanFeature',
                 @CreatedBy = @ActorUserId;

            THROW;
        END
    END CATCH

    SELECT @Status AS [Status], @Code AS Code, @Message AS [Message], @Id AS Id;
END
GO

PRINT '    Entitlement catalog procedures ready.';
GO
