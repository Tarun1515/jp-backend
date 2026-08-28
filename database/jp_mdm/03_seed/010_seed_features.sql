/*==============================================================================
  jp_mdm — 03_seed / 010_seed_features.sql

  Gating modes, and the initial feature catalog. Phase 2.5.

  ---------------------------------------------------------------------------
  🔴 EVERY FEATURE SEEDS **FREE**, AND NO PLAN MAPPINGS ARE CREATED
  ---------------------------------------------------------------------------
  Shipping Phase 2.5 changes NOTHING a user can see. Every feature is ungated,
  no endpoint calls the consume path yet, and the ledger stays empty.

  This is deliberate, not timidity. Shipping the engine and the gating together
  would mean that on the day something stops working, TWO new things are under
  suspicion at once. Separated, the first gate is a data change — one row, one
  column — and undoing it is another data change (2.7).

  ⚠️ So there are no plan-feature rows in this file at all. A mapping is a
  commercial decision about what a plan includes, and no such decision has been
  made: pricing is not finalised, which is the same reason 2F seeded no paid
  tiers. The admin screen is where the first one gets made, by a person.

  The first non-free mode is set in Phase 6.5. The first real consume is
  written with job posting in Phase 4.

  Re-runnable: MERGE on the stable code, so running this twice changes nothing.

  ⚠️ MERGE deliberately does NOT touch GatingModeId or Is_Active on an existing
  row. Both are operational state an admin owns — re-running the seed after
  someone has set JOB_POST to METERED must not quietly put it back to FREE, and
  re-running it during an incident must not undo a kill switch. Only naming and
  ordering are reconciled. See the WHEN MATCHED clause.
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

PRINT '  Seeding gating modes ...';
GO

/*
  Three rows. A fourth needs the code that understands it — CK_m_mdm_features_
  GatingModeId is what makes that non-optional (2.51's RoleInSchool precedent).

  ⚠️ "Disabled" is NOT here. The kill switch is m_mdm_features.Is_Active,
  orthogonal to mode, so that switching a feature off does not destroy the
  record of how it was gated.
*/
MERGE dbo.m_mdm_gating_modes AS tgt
USING (VALUES
        (1, 'FREE',    N'Free',    N'Ungated. Any account with a usable subscription may use it. No plan mapping is read.', 1),
        (2, 'BOOLEAN', N'Boolean', N'Included in the plan, or not. No count is kept and nothing is written to the ledger.', 2),
        (3, 'METERED', N'Metered', N'Quota per calendar month, then credits, then refusal. Every use writes a ledger row.', 3)
      ) AS src (GatingModeId, Code, Name, Description, DisplayOrder)
    ON tgt.GatingModeId = src.GatingModeId
WHEN MATCHED AND (tgt.Code <> src.Code OR tgt.Name <> src.Name OR tgt.DisplayOrder <> src.DisplayOrder)
    THEN UPDATE SET tgt.Code = src.Code, tgt.Name = src.Name,
                    tgt.Description = src.Description,
                    tgt.DisplayOrder = src.DisplayOrder, tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (GatingModeId, Code, Name, Description, DisplayOrder)
         VALUES (src.GatingModeId, src.Code, src.Name, src.Description, src.DisplayOrder);
GO

PRINT '  Seeding feature catalog ...';
GO

/*
  FeatureId is IDENTITY, so the MERGE keys on FeatureCode — the stable
  identifier (2.47).

  🔴 GatingModeId is set to 1 (FREE) on INSERT ONLY. See the file header: the
  UPDATE branch below never touches it, because a re-run must not undo an
  operator's change.

  AppliesToUserTypeId: 2 = School, 3 = Teacher. Cross-database meaning, no FK
  (2.2), mirroring m_mdm_plans.UserTypeId.
*/
MERGE dbo.m_mdm_features AS tgt
USING (VALUES
        ('JOB_POST',              N'Post a job',            N'Publish a job opening on a campus.',                                 2, 1),
        ('JOB_FEATURED',          N'Feature a job',         N'Promote a job to the top of search results.',                        2, 2),
        ('TEACHER_SEARCH',        N'Search teachers',       N'Search the teacher database. Looking, not reaching — contact stays closed (2.56).', 2, 3),
        ('TEACHER_INVITE',        N'Invite a teacher',      N'Invite a specific teacher to apply. This is the reach that is sold.', 2, 4),
        ('APPLICATION_VIEW',      N'View applications',     N'Open an application a teacher has submitted.',                        2, 5),
        ('TEACHER_PROFILE_BOOST', N'Boost profile',         N'Raise a teacher profile in school search results.',                   3, 6)
      ) AS src (FeatureCode, Name, Description, AppliesToUserTypeId, DisplayOrder)
    ON tgt.FeatureCode = src.FeatureCode AND tgt.Is_Deleted = 0
/*
  ⚠️ Naming and ordering only. GatingModeId and Is_Active are ABSENT from this
  SET list on purpose — they are operator state, and a seed re-run is not an
  operator decision.
*/
WHEN MATCHED AND (tgt.Name <> src.Name
               OR tgt.AppliesToUserTypeId <> src.AppliesToUserTypeId
               OR tgt.DisplayOrder <> src.DisplayOrder)
    THEN UPDATE SET tgt.Name = src.Name,
                    tgt.Description = src.Description,
                    tgt.AppliesToUserTypeId = src.AppliesToUserTypeId,
                    tgt.DisplayOrder = src.DisplayOrder,
                    tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (FeatureCode, Name, Description, AppliesToUserTypeId, DisplayOrder, GatingModeId, Is_Active)
         VALUES (src.FeatureCode, src.Name, src.Description, src.AppliesToUserTypeId, src.DisplayOrder, 1, 1);
GO

PRINT '    Feature catalog ready — all FREE, no plan mappings.';
GO
