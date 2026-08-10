/*==============================================================================
  jp_mdm — 03_seed / 008_seed_plans.sql

  Subscription statuses, and exactly two plans.

  ---------------------------------------------------------------------------
  🔴 NO PAID TIERS, AND NOT BY OVERSIGHT
  ---------------------------------------------------------------------------
  Pricing is not finalised. The public site's FAQ says so. Anything seeded here
  with a price on it becomes a number the client read in software we delivered,
  and it will be quoted back at us.

  So: one free plan per user type, both at zero, both perpetual. Paid tiers are
  a Phase 2.5 decision made with the client, not a placeholder invented here.

  ⚠️ TEACHER_FREE exists but nothing assigns it yet — teachers have no profile
  row to hang a subscription off (G12). It is seeded now so Phase 3's backfill
  has something to point at rather than needing a data change first.

  Re-runnable: MERGE on the id, so running this twice changes nothing.
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

PRINT '  Seeding subscription statuses ...';
GO

MERGE dbo.m_mdm_subscription_status AS tgt
USING (VALUES
        (1, 'ACTIVE',    N'Active',    1),
        (2, 'EXPIRED',   N'Expired',   2),
        (3, 'CANCELLED', N'Cancelled', 3)
      ) AS src (SubscriptionStatusId, Code, Name, DisplayOrder)
    ON tgt.SubscriptionStatusId = src.SubscriptionStatusId
WHEN MATCHED AND (tgt.Code <> src.Code OR tgt.Name <> src.Name OR tgt.DisplayOrder <> src.DisplayOrder)
    THEN UPDATE SET tgt.Code = src.Code, tgt.Name = src.Name,
                    tgt.DisplayOrder = src.DisplayOrder, tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (SubscriptionStatusId, Code, Name, DisplayOrder)
         VALUES (src.SubscriptionStatusId, src.Code, src.Name, src.DisplayOrder);
GO

PRINT '  Seeding plans ...';
GO

/*
  PlanId is IDENTITY, so the MERGE keys on PlanCode — the stable identifier
  (2.47). Name is editable; the code is not.

  DurationDays NULL: neither free plan expires. Giving them an end date would
  require a renewal job in this phase for something nobody is paying for.
*/
MERGE dbo.m_mdm_plans AS tgt
USING (VALUES
        ('SCHOOL_FREE',  2, N'Free',  NULL, CAST(0 AS decimal(10,2)), 1, 1, 1),
        ('TEACHER_FREE', 3, N'Free',  NULL, CAST(0 AS decimal(10,2)), 1, 1, 1)
      ) AS src (PlanCode, UserTypeId, Name, DurationDays, Price, IsDefault, IsPublic, DisplayOrder)
    ON tgt.PlanCode = src.PlanCode AND tgt.Is_Deleted = 0
WHEN MATCHED AND (tgt.UserTypeId <> src.UserTypeId
               OR tgt.Name <> src.Name
               OR tgt.Price <> src.Price
               OR tgt.IsDefault <> src.IsDefault)
    THEN UPDATE SET tgt.UserTypeId = src.UserTypeId, tgt.Name = src.Name,
                    tgt.DurationDays = src.DurationDays, tgt.Price = src.Price,
                    tgt.IsDefault = src.IsDefault, tgt.IsPublic = src.IsPublic,
                    tgt.DisplayOrder = src.DisplayOrder, tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (PlanCode, UserTypeId, Name, DurationDays, Price, IsDefault, IsPublic, DisplayOrder)
         VALUES (src.PlanCode, src.UserTypeId, src.Name, src.DurationDays, src.Price,
                 src.IsDefault, src.IsPublic, src.DisplayOrder);
GO

PRINT '    Plans ready.';
GO
