/*==============================================================================
  jp_mdm — 036_entitlement_catalog.sql

  The entitlement catalog: gating modes, features, and the plan × feature
  mapping. Phase 2.5.

  Governed by jp-docs/MONETIZATION_DESIGN.md — Decisions 1, 2 and 3.

  ---------------------------------------------------------------------------
  🔴 THE PROHIBITION THIS ENGINE CARRIES EVERYWHERE (2.56 — LOCKED)
  ---------------------------------------------------------------------------
  The entitlement engine and contact unlock never reference each other, in
  either direction.

  A subscription buys the school's CAPABILITY — whether it may search the
  teacher database at all, how many invitations it may send, whether it may
  post a job. It never buys a teacher's phone number or email.
  fn_TeacherContactUnlocked returns true on exactly two paths: the teacher
  applied to this school, or accepted its invitation.

  If a future requirement seems to need a plan check inside contact unlock, or
  a contact check inside this engine, the requirement is being described
  wrongly: what is sold is reach, and reach is invites.

  ⚠️ Phase 2.5's verification greps both directions and shows the output.

  ---------------------------------------------------------------------------
  ⚠️ NOTHING HERE CHANGES m_mdm_plans
  ---------------------------------------------------------------------------
  2F pulled plans and subscriptions forward and said in as many words that
  monetization proper "is NOT here and should not be added here". This is that
  monetization, and it arrives as new tables BESIDE m_mdm_plans — not a column
  on it. m_mdm_plans is untouched by this phase.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  m_mdm_gating_modes

  Labels for the admin dropdown. Three rows, and a fourth is a code change.

  ---------------------------------------------------------------------------
  🔴 WHY THIS IS A MASTER **AND** A CHECK CONSTRAINT — BOTH
  ---------------------------------------------------------------------------
  The master exists so the admin dropdown is data rather than a hardcoded list
  (2.7). The CHECK on m_mdm_features.GatingModeId exists so a fourth row here
  cannot silently start being used by a procedure that only understands three.

  This is the precedent t_app_school_users.RoleInSchool set in 2.51: values
  that are STRUCTURAL to the product and branched on in code get both. Adding
  a mode means writing the branch that handles it, and the CHECK is what makes
  that non-optional.

  ⚠️ DISABLED IS NOT ONE OF THESE. The kill switch is m_mdm_features.Is_Active,
  which is orthogonal to mode — see that table's header for why.
==============================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'm_mdm_gating_modes' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [m_mdm_gating_modes] ...';

    CREATE TABLE dbo.m_mdm_gating_modes
    (
        -- tinyint to match m_mdm_features.GatingModeId, which the design fixes
        -- as tinyint. A FK cannot span two widths, and the narrower one is the
        -- one that has to be right — three values will never need more.
        GatingModeId  tinyint        NOT NULL,
        Code          varchar(30)    NOT NULL,
        Name          nvarchar(100)  NOT NULL,
        Description   nvarchar(300)  NULL,
        DisplayOrder  int            NOT NULL CONSTRAINT DF_m_mdm_gating_modes_DisplayOrder DEFAULT (0),

        Is_Active     tinyint        NOT NULL CONSTRAINT DF_m_mdm_gating_modes_Is_Active  DEFAULT (1),
        Is_Deleted    tinyint        NOT NULL CONSTRAINT DF_m_mdm_gating_modes_Is_Deleted DEFAULT (0),
        CreatedOn     datetime2      NOT NULL CONSTRAINT DF_m_mdm_gating_modes_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy     bigint         NULL,
        ModifiedOn    datetime2      NULL,
        ModifiedBy    bigint         NULL,

        CONSTRAINT PK_m_mdm_gating_modes PRIMARY KEY CLUSTERED (GatingModeId),
        CONSTRAINT CK_m_mdm_gating_modes_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_m_mdm_gating_modes_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [m_mdm_gating_modes] already exists — skipped.';
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_m_mdm_gating_modes_Code' AND object_id = OBJECT_ID('dbo.m_mdm_gating_modes'))
BEGIN
    PRINT '    Creating index [UQ_m_mdm_gating_modes_Code] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_m_mdm_gating_modes_Code
        ON dbo.m_mdm_gating_modes (Code)
        WHERE Is_Deleted = 0;
END
GO


/*==============================================================================
  m_mdm_features

  One row per capability a plan could plausibly sell separately.

  ---------------------------------------------------------------------------
  GRANULARITY IS A COMMERCIAL TEST, NOT A TECHNICAL ONE
  ---------------------------------------------------------------------------
  If two actions would always be sold together, they are one feature. Splitting
  them costs a mapping row per plan forever and buys nothing.

  ---------------------------------------------------------------------------
  🔴 Is_Active = 0 IS THE KILL SWITCH, AND IT IS NOT A MODE
  ---------------------------------------------------------------------------
  A kill switch must be reversible WITHOUT DATA LOSS. If "disabled" were a
  fourth GatingModeId, then switching off a metered feature would overwrite the
  fact that it was metered:

      JOB_POST: mode = METERED  ->  incident  ->  mode = DISABLED
                                             ->  ...restore to what?

  Somebody would have to remember it was Metered, from a chat message, while
  already handling an incident. With Is_Active the mode is never touched:

      JOB_POST: mode = METERED, Is_Active = 1  ->  Is_Active = 0  ->  Is_Active = 1

  It is also this schema's existing vocabulary (2.47: a row you do not want is
  Is_Active = 0, never DELETE). GatingModeId answers "how is access decided";
  Is_Active answers "does this feature exist right now". Two questions, two
  columns.

  ⚠️ Is_Active = 0 outranks EVERYTHING in the precedence order — a kill switch
  that could be defeated by holding the right plan is not a kill switch.

  ---------------------------------------------------------------------------
  ⚠️ FeatureCode IS THE CONTRACT (2.47)
  ---------------------------------------------------------------------------
  Code is stable and never changes on a live row: procedures, seeds and Phase 4
  onward resolve by it. Name is display text the client may rewrite freely.
==============================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'm_mdm_features' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [m_mdm_features] ...';

    CREATE TABLE dbo.m_mdm_features
    (
        FeatureId            int             IDENTITY(1,1) NOT NULL,
        FeatureCode          varchar(50)     NOT NULL,
        Name                 nvarchar(100)   NOT NULL,
        Description          nvarchar(400)   NULL,

        /*
          1 = FREE, 2 = BOOLEAN, 3 = METERED.

          The CHECK is deliberate and is the point of the pairing described in
          m_mdm_gating_modes' header: a fourth mode cannot arrive as data,
          because no procedure would know what to do with it.
        */
        GatingModeId         tinyint         NOT NULL CONSTRAINT DF_m_mdm_features_GatingModeId DEFAULT (1),

        /*
          ⚠️ CROSS-DATABASE MEANING — m_sso_user_types in jp_sso. No foreign key
          and never one (2.2). 2 = School, 3 = Teacher.

          Mirrors m_mdm_plans.UserTypeId for exactly the same reason: a school
          feature mapped to a teacher plan is not a pricing mistake, it is a
          mapping whose limits mean nothing. The admin screen filters on this so
          that combination cannot be built by accident.
        */
        AppliesToUserTypeId  int             NOT NULL,

        DisplayOrder         int             NOT NULL CONSTRAINT DF_m_mdm_features_DisplayOrder DEFAULT (0),

        Is_Active            tinyint         NOT NULL CONSTRAINT DF_m_mdm_features_Is_Active  DEFAULT (1),
        Is_Deleted           tinyint         NOT NULL CONSTRAINT DF_m_mdm_features_Is_Deleted DEFAULT (0),
        CreatedOn            datetime2       NOT NULL CONSTRAINT DF_m_mdm_features_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy            bigint          NULL,
        ModifiedOn           datetime2       NULL,
        ModifiedBy           bigint          NULL,

        CONSTRAINT PK_m_mdm_features PRIMARY KEY CLUSTERED (FeatureId),
        CONSTRAINT FK_m_mdm_features_GatingMode
            FOREIGN KEY (GatingModeId) REFERENCES dbo.m_mdm_gating_modes (GatingModeId),
        CONSTRAINT CK_m_mdm_features_GatingModeId CHECK (GatingModeId IN (1, 2, 3)),
        CONSTRAINT CK_m_mdm_features_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_m_mdm_features_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [m_mdm_features] already exists — skipped.';
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_m_mdm_features_FeatureCode' AND object_id = OBJECT_ID('dbo.m_mdm_features'))
BEGIN
    PRINT '    Creating index [UQ_m_mdm_features_FeatureCode] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_m_mdm_features_FeatureCode
        ON dbo.m_mdm_features (FeatureCode)
        WHERE Is_Deleted = 0;
END
GO


/*==============================================================================
  m_mdm_plan_features

  What a plan includes. Both sides live in jp_mdm, so this is a plain
  foreign-keyed bridge with no cross-database anything.

  ---------------------------------------------------------------------------
  🔴 A MISSING ROW MEANS DENIED — FOR BOOLEAN AND METERED BOTH
  ---------------------------------------------------------------------------
  Inclusion is an explicit statement. Absence of a row is absence of a
  decision, and a system that reads "nobody said anything" as "yes" grants
  capability nobody sold.

  Failing closed is also the only safe default for a table an admin edits by
  hand: a mis-click that DELETES a mapping row removes access from one plan,
  rather than granting it to everyone.

  ⚠️ The consequence, accepted: adding a feature to the catalog grants it to
  nobody until it is mapped. The admin screen must therefore render an unmapped
  combination as explicitly UNMAPPED — not as a blank cell, which reads as
  "zero" or as "nothing to see here".

  FREE features never read this table at all: the mode is the grant.
==============================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'm_mdm_plan_features' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [m_mdm_plan_features] ...';

    CREATE TABLE dbo.m_mdm_plan_features
    (
        PlanFeatureId    int         IDENTITY(1,1) NOT NULL,
        PlanId           int         NOT NULL,
        FeatureId        int         NOT NULL,

        /*
          BOOLEAN mode only. 1 = the plan grants it.

          A row with IsIncluded = 0 is a deliberate "this plan does NOT include
          it" — different from no row at all in intent, identical in effect.
          Both are refused. Keeping the distinction lets an admin record a
          decision rather than express it by absence.
        */
        IsIncluded       tinyint     NOT NULL CONSTRAINT DF_m_mdm_plan_features_IsIncluded DEFAULT (0),

        /*
          METERED mode only.

          NULL = unlimited within the plan.  0 = explicitly none.
          ⚠️ These are NOT the same and the procedure must not conflate them:
          NULL skips the quota comparison entirely, 0 fails it immediately and
          falls through to credits.
        */
        QuotaPerPeriod   int         NULL,

        Is_Active        tinyint     NOT NULL CONSTRAINT DF_m_mdm_plan_features_Is_Active  DEFAULT (1),
        Is_Deleted       tinyint     NOT NULL CONSTRAINT DF_m_mdm_plan_features_Is_Deleted DEFAULT (0),
        CreatedOn        datetime2   NOT NULL CONSTRAINT DF_m_mdm_plan_features_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy        bigint      NULL,
        ModifiedOn       datetime2   NULL,
        ModifiedBy       bigint      NULL,

        CONSTRAINT PK_m_mdm_plan_features PRIMARY KEY CLUSTERED (PlanFeatureId),
        CONSTRAINT FK_m_mdm_plan_features_Plan
            FOREIGN KEY (PlanId)    REFERENCES dbo.m_mdm_plans (PlanId),
        CONSTRAINT FK_m_mdm_plan_features_Feature
            FOREIGN KEY (FeatureId) REFERENCES dbo.m_mdm_features (FeatureId),
        CONSTRAINT CK_m_mdm_plan_features_IsIncluded CHECK (IsIncluded IN (0, 1)),
        CONSTRAINT CK_m_mdm_plan_features_Quota      CHECK (QuotaPerPeriod IS NULL OR QuotaPerPeriod >= 0),
        CONSTRAINT CK_m_mdm_plan_features_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_m_mdm_plan_features_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [m_mdm_plan_features] already exists — skipped.';
END
GO
/*------------------------------------------------------------------------------
  One mapping per plan per feature.

  Filtered on Is_Deleted = 0 so a soft-deleted mapping can be re-created (2.4)
  — the same shape every other unique business key in this system uses.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_m_mdm_plan_features_PlanFeature' AND object_id = OBJECT_ID('dbo.m_mdm_plan_features'))
BEGIN
    PRINT '    Creating index [UQ_m_mdm_plan_features_PlanFeature] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_m_mdm_plan_features_PlanFeature
        ON dbo.m_mdm_plan_features (PlanId, FeatureId)
        WHERE Is_Deleted = 0;
END
GO
/*------------------------------------------------------------------------------
  The consume path's index.

  🔴 IEntitlementRepository resolves the feature AND its mapping in ONE query
  (MONETIZATION_DESIGN.md — "Gating reads never come from the master cache").
  That query seeks m_mdm_features by FeatureCode and left-joins here by
  (FeatureId, PlanId); this covers the join side so the whole resolution is two
  seeks.

  ⚠️ Column order is (FeatureId, PlanId) — the opposite of the unique index
  above, deliberately. The admin screen reads a plan's whole row (PlanId
  leading); the consume path knows the feature first.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_m_mdm_plan_features_FeaturePlan' AND object_id = OBJECT_ID('dbo.m_mdm_plan_features'))
BEGIN
    PRINT '    Creating index [IX_m_mdm_plan_features_FeaturePlan] ...';

    CREATE NONCLUSTERED INDEX IX_m_mdm_plan_features_FeaturePlan
        ON dbo.m_mdm_plan_features (FeatureId, PlanId)
        INCLUDE (IsIncluded, QuotaPerPeriod)
        WHERE Is_Deleted = 0;
END
GO

PRINT '    Entitlement catalog tables ready.';
GO
