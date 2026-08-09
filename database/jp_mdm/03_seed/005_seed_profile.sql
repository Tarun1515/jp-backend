/*==============================================================================
  jp_mdm — 03_seed / 005_seed_profile.sql

  Gender · Experience range

  STATUS: SEEDED FULLY, NOT PROVISIONAL.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

PRINT '    Seeding profile masters ...';
GO

/*------------------------------------------------------------------------------
  m_mdm_gender

  "Prefer not to say" is a real option, not padding. The alternative is people
  picking something untrue to get past a required field, which makes the column
  worse than useless — it looks like data and is not.
------------------------------------------------------------------------------*/
MERGE dbo.m_mdm_gender AS tgt
USING (VALUES
        (1, 'MALE',         N'Male',              1),
        (2, 'FEMALE',       N'Female',            2),
        (3, 'OTHER',        N'Other',             3),
        (4, 'NOT_DISCLOSED',N'Prefer not to say', 4)
      ) AS src (GenderId, Code, Name, DisplayOrder)
    ON tgt.GenderId = src.GenderId
WHEN MATCHED AND (tgt.Code <> src.Code OR tgt.Name <> src.Name OR tgt.DisplayOrder <> src.DisplayOrder)
    THEN UPDATE SET tgt.Code = src.Code, tgt.Name = src.Name,
                    tgt.DisplayOrder = src.DisplayOrder, tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (GenderId, Code, Name, DisplayOrder)
         VALUES (src.GenderId, src.Code, src.Name, src.DisplayOrder);
GO

/*------------------------------------------------------------------------------
  m_mdm_experience_range — the search filter buckets.

  🔴 MinMonths / MaxMonths are what the filter actually uses.
  t_mdm_teacher_registration_details stores TotalExperienceMonths, so a search
  is a plain integer comparison against these bounds — never a parse of the
  string "5-10" at query time.

  Bounds are [MinMonths, MaxMonths] INCLUSIVE in months, and MaxMonths NULL
  means open-ended. The ranges are contiguous with no gap and no overlap:

      EXP_0_1     0 .. 11     under a year
      EXP_1_3    12 .. 35
      EXP_3_5    36 .. 59
      EXP_5_10   60 .. 119
      EXP_10_PLUS 120 .. NULL

  ⚠️ The display names say "0-1 years" while the bounds are months. That is
  deliberate: a person picks a year band, the query compares months.
------------------------------------------------------------------------------*/
MERGE dbo.m_mdm_experience_range AS tgt
USING (VALUES
        (1, 'EXP_0_1',     N'Less than 1 year',  1,   0,   11),
        (2, 'EXP_1_3',     N'1 - 3 years',       2,  12,   35),
        (3, 'EXP_3_5',     N'3 - 5 years',       3,  36,   59),
        (4, 'EXP_5_10',    N'5 - 10 years',      4,  60,  119),
        (5, 'EXP_10_PLUS', N'10+ years',         5, 120, NULL)
      ) AS src (ExperienceRangeId, Code, Name, DisplayOrder, MinMonths, MaxMonths)
    ON tgt.ExperienceRangeId = src.ExperienceRangeId
WHEN MATCHED AND (tgt.Code <> src.Code OR tgt.Name <> src.Name
                  OR tgt.DisplayOrder <> src.DisplayOrder
                  OR tgt.MinMonths <> src.MinMonths
                  OR ISNULL(tgt.MaxMonths, -1) <> ISNULL(src.MaxMonths, -1))
    THEN UPDATE SET tgt.Code = src.Code, tgt.Name = src.Name,
                    tgt.DisplayOrder = src.DisplayOrder,
                    tgt.MinMonths = src.MinMonths, tgt.MaxMonths = src.MaxMonths,
                    tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (ExperienceRangeId, Code, Name, DisplayOrder, MinMonths, MaxMonths)
         VALUES (src.ExperienceRangeId, src.Code, src.Name, src.DisplayOrder,
                 src.MinMonths, src.MaxMonths);
GO

PRINT '    Profile masters seeded.';
GO
