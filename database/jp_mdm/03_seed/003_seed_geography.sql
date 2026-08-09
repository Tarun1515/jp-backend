/*==============================================================================
  jp_mdm — 03_seed / 003_seed_geography.sql

  India, and all 36 states and union territories.

  ---------------------------------------------------------------------------
  🔴 DISTRICTS AND CITIES ARE DELIBERATELY EMPTY
  ---------------------------------------------------------------------------
  India has 800+ districts and thousands of towns. That is a dataset, not a
  list somebody types — and a guessed one is worse than none, because every row
  seeded here becomes a foreign key target that a correction later has to
  migrate rather than replace.

  Consequence, confirmed before Phase 2F builds the registration form:

      t_mdm_school_registration_details.CityId       NULL
      t_mdm_school_registration_details.DistrictId   NULL
      t_mdm_school_registration_details.StateId      NULL
      t_mdm_teacher_registration_details.CurrentCityId  NULL
      t_mdm_teacher_registration_details.CurrentStateId NULL

  All nullable. The forms degrade to state-only selection with no schema change
  at all. See PROJECT_MEMORY for the dataset source and the import plan.

  ---------------------------------------------------------------------------
  CODE IS STABLE, NAME IS EDITABLE
  ---------------------------------------------------------------------------
  Codes are the standard two-letter Indian state codes — MH, TN, KA. They are
  the stable identifier: FKs resolve through them and this script matches on
  them. Names are display text the client may change whenever they like, and
  changing one is an UPDATE to a single column, not a migration.

  DisplayOrder: states alphabetically, then union territories. Alphabetical is
  wrong for a career ladder and right here — there is no meaningful order to a
  list of states, and a person scanning for "Maharashtra" expects it under M.

  Re-runnable. MERGE on the natural key, never deletes.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

PRINT '    Seeding geography (country + states) ...';
GO

/*------------------------------------------------------------------------------
  m_mdm_country — one row for now.

  The platform is India-only. The table exists because the state hierarchy needs
  a parent and because "we will never expand" is not a thing to bake into a
  schema, not because a second country is planned.
------------------------------------------------------------------------------*/
MERGE dbo.m_mdm_country AS tgt
USING (VALUES (1, 'IN', N'India', 1)) AS src (CountryId, Code, Name, DisplayOrder)
    ON tgt.CountryId = src.CountryId
WHEN MATCHED AND (tgt.Code <> src.Code OR tgt.Name <> src.Name OR tgt.DisplayOrder <> src.DisplayOrder)
    THEN UPDATE SET tgt.Code = src.Code, tgt.Name = src.Name,
                    tgt.DisplayOrder = src.DisplayOrder, tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (CountryId, Code, Name, DisplayOrder)
         VALUES (src.CountryId, src.Code, src.Name, src.DisplayOrder);
GO

/*------------------------------------------------------------------------------
  m_mdm_state — 28 states + 8 union territories = 36.

  🔴 CountryId is resolved by Code, not hardcoded to 1. A typo in the country
  code must abort the seed rather than quietly insert rows under the wrong
  parent — the same rule the menu seed follows (decision 2.37).
------------------------------------------------------------------------------*/
DECLARE @CountryId int = (SELECT CountryId FROM dbo.m_mdm_country WHERE Code = 'IN' AND Is_Deleted = 0);

IF @CountryId IS NULL
    THROW 50031, 'Country code IN was not found. Geography seed aborted rather than inserting states with no parent.', 1;

MERGE dbo.m_mdm_state AS tgt
USING (VALUES
        -- ---- states, alphabetical (1-28) --------------------------------
        ( 1, 'AP', N'Andhra Pradesh',                1),
        ( 2, 'AR', N'Arunachal Pradesh',             2),
        ( 3, 'AS', N'Assam',                         3),
        ( 4, 'BR', N'Bihar',                         4),
        ( 5, 'CG', N'Chhattisgarh',                  5),
        ( 6, 'GA', N'Goa',                           6),
        ( 7, 'GJ', N'Gujarat',                       7),
        ( 8, 'HR', N'Haryana',                       8),
        ( 9, 'HP', N'Himachal Pradesh',              9),
        (10, 'JH', N'Jharkhand',                    10),
        (11, 'KA', N'Karnataka',                    11),
        (12, 'KL', N'Kerala',                       12),
        (13, 'MP', N'Madhya Pradesh',               13),
        (14, 'MH', N'Maharashtra',                  14),
        (15, 'MN', N'Manipur',                      15),
        (16, 'ML', N'Meghalaya',                    16),
        (17, 'MZ', N'Mizoram',                      17),
        (18, 'NL', N'Nagaland',                     18),
        (19, 'OD', N'Odisha',                       19),
        (20, 'PB', N'Punjab',                       20),
        (21, 'RJ', N'Rajasthan',                    21),
        (22, 'SK', N'Sikkim',                       22),
        (23, 'TN', N'Tamil Nadu',                   23),
        (24, 'TS', N'Telangana',                    24),
        (25, 'TR', N'Tripura',                      25),
        (26, 'UP', N'Uttar Pradesh',                26),
        (27, 'UK', N'Uttarakhand',                  27),
        (28, 'WB', N'West Bengal',                  28),

        -- ---- union territories, alphabetical (29-36) --------------------
        -- After the states rather than merged in: a UT is a different kind of
        -- thing, and someone looking for Delhi finds it faster in a short
        -- second group than buried between Chhattisgarh and Goa.
        (29, 'AN', N'Andaman and Nicobar Islands',  29),
        (30, 'CH', N'Chandigarh',                   30),
        (31, 'DH', N'Dadra and Nagar Haveli and Daman and Diu', 31),
        (32, 'DL', N'Delhi',                        32),
        (33, 'JK', N'Jammu and Kashmir',            33),
        (34, 'LA', N'Ladakh',                       34),
        (35, 'LD', N'Lakshadweep',                  35),
        (36, 'PY', N'Puducherry',                   36)
      ) AS src (StateId, Code, Name, DisplayOrder)
    ON tgt.StateId = src.StateId
WHEN MATCHED AND (tgt.Code <> src.Code OR tgt.Name <> src.Name
                  OR tgt.DisplayOrder <> src.DisplayOrder OR tgt.CountryId <> @CountryId)
    THEN UPDATE SET tgt.Code = src.Code, tgt.Name = src.Name,
                    tgt.DisplayOrder = src.DisplayOrder, tgt.CountryId = @CountryId,
                    tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (StateId, Code, Name, DisplayOrder, CountryId)
         VALUES (src.StateId, src.Code, src.Name, src.DisplayOrder, @CountryId);
GO

/*==============================================================================
  ⚠️ m_mdm_district AND m_mdm_city ARE INTENTIONALLY NOT SEEDED HERE.

  See the header. When the dataset arrives it goes in its own numbered script,
  and it must resolve StateId by Code exactly as this file resolves CountryId.
==============================================================================*/

PRINT '    Geography seeded — 1 country, 36 states/UTs. Districts and cities left empty.';
GO
