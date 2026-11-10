/*==============================================================================
  North India and the northern UTs — districts and their headquarters towns.

  ---------------------------------------------------------------------------
  🔴 GENERATED. Do not hand-edit — change scripts/gen-geography.mjs in jp-docs
  and regenerate, or the next regeneration silently reverts the edit.
  ---------------------------------------------------------------------------

  Ids are EXPLICIT and namespaced off the state id, exactly as 012 does:

      district   StateId * 100   + n
      town       StateId * 10000 + n

  jp_app stores these ids with NO foreign key (2.2). If a fresh build ever
  assigned different numbers from the ones a live jp_app points at, every
  stored address would quietly point somewhere else — so each file asserts
  its states' ids before writing a single row.

  ---------------------------------------------------------------------------
  ⚠️ TEHSILS ARE NOT SEEDED HERE, AND THAT IS DELIBERATE
  ---------------------------------------------------------------------------
  Only Haryana has tehsils (012), from a named source read on a stated date.
  India has roughly six thousand, they change often, and no list we can cite
  today is both complete and current. A half-remembered one would put wrong
  names in front of the client wearing the authority of a master table.

  The form already handles their absence: hasTehsils() hides the control for
  a state with none, so the address degrades to state → district → town with
  nothing broken and nothing empty on screen.

  ---------------------------------------------------------------------------
  🔴 NAMES ARE PROVISIONAL AND BELONG TO THE CLIENT (2.47)
  ---------------------------------------------------------------------------
  The MERGE has NO `WHEN MATCHED THEN UPDATE`. Once a row is live its Name is
  the client's; if they correct one, a re-run must not undo the correction.

  ⚠️ IN THIS FILE, THESE LISTS ARE KNOWN TO BE IN MOTION:
      Rajasthan — reorganised in 2023 and revised again in 2024 — the newest districts are the ones to confirm
      Ladakh — expanded from two districts to seven in 2024

  ---------------------------------------------------------------------------
  CONTENTS: 9 states/UTs, 203 districts, 203 towns
  (one town per district: its headquarters).

  IDEMPOTENT. Every row is guarded on Code, so re-running changes nothing.
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

PRINT '  Seeding geography — North India and the northern UTs ...';
GO

/*--------------------------------------------------------------------------
  Himachal Pradesh (HP) — StateId 9, 12 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_HP int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'HP' AND Is_Deleted = 0);

IF @StateId_HP IS NULL
    THROW 50001, '014_seed_geography_north: the state HP is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_HP <> 9
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      9 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_HP nvarchar(400) = N'014_seed_geography_north: HP is StateId '
        + CAST(@StateId_HP AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 9.';

    RAISERROR('%s', 16, 1, @wrong_HP);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (901, 'HP_BILASPUR', N'Bilaspur', 10),
    (902, 'HP_CHAMBA', N'Chamba', 20),
    (903, 'HP_HAMIRPUR', N'Hamirpur', 30),
    (904, 'HP_KANGRA', N'Kangra', 40),
    (905, 'HP_KINNAUR', N'Kinnaur', 50),
    (906, 'HP_KULLU', N'Kullu', 60),
    (907, 'HP_LAHAULANDSPITI', N'Lahaul and Spiti', 70),
    (908, 'HP_MANDI', N'Mandi', 80),
    (909, 'HP_SHIMLA', N'Shimla', 90),
    (910, 'HP_SIRMAUR', N'Sirmaur', 100),
    (911, 'HP_SOLAN', N'Solan', 110),
    (912, 'HP_UNA', N'Una', 120)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_HP, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (90001, 901, 'HP_BILASPUR', N'Bilaspur', 10),
    (90002, 902, 'HP_CHAMBA', N'Chamba', 20),
    (90003, 903, 'HP_HAMIRPUR', N'Hamirpur', 30),
    (90004, 904, 'HP_KANGRA', N'Kangra', 40),
    (90005, 905, 'HP_KINNAUR', N'Kinnaur', 50),
    (90006, 906, 'HP_KULLU', N'Kullu', 60),
    (90007, 907, 'HP_LAHAULANDSPITI', N'Lahaul and Spiti', 70),
    (90008, 908, 'HP_MANDI', N'Mandi', 80),
    (90009, 909, 'HP_SHIMLA', N'Shimla', 90),
    (90010, 910, 'HP_SIRMAUR', N'Sirmaur', 100),
    (90011, 911, 'HP_SOLAN', N'Solan', 110),
    (90012, 912, 'HP_UNA', N'Una', 120)
) AS src (CityId, DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CityId, DistrictId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.CityId, src.DistrictId, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());
GO

/*--------------------------------------------------------------------------
  Punjab (PB) — StateId 20, 23 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_PB int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'PB' AND Is_Deleted = 0);

IF @StateId_PB IS NULL
    THROW 50001, '014_seed_geography_north: the state PB is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_PB <> 20
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      20 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_PB nvarchar(400) = N'014_seed_geography_north: PB is StateId '
        + CAST(@StateId_PB AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 20.';

    RAISERROR('%s', 16, 1, @wrong_PB);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (2001, 'PB_AMRITSAR', N'Amritsar', 10),
    (2002, 'PB_BARNALA', N'Barnala', 20),
    (2003, 'PB_BATHINDA', N'Bathinda', 30),
    (2004, 'PB_FARIDKOT', N'Faridkot', 40),
    (2005, 'PB_FATEHGARHSAHIB', N'Fatehgarh Sahib', 50),
    (2006, 'PB_FAZILKA', N'Fazilka', 60),
    (2007, 'PB_FEROZEPUR', N'Ferozepur', 70),
    (2008, 'PB_GURDASPUR', N'Gurdaspur', 80),
    (2009, 'PB_HOSHIARPUR', N'Hoshiarpur', 90),
    (2010, 'PB_JALANDHAR', N'Jalandhar', 100),
    (2011, 'PB_KAPURTHALA', N'Kapurthala', 110),
    (2012, 'PB_LUDHIANA', N'Ludhiana', 120),
    (2013, 'PB_MALERKOTLA', N'Malerkotla', 130),
    (2014, 'PB_MANSA', N'Mansa', 140),
    (2015, 'PB_MOGA', N'Moga', 150),
    (2016, 'PB_PATHANKOT', N'Pathankot', 160),
    (2017, 'PB_PATIALA', N'Patiala', 170),
    (2018, 'PB_RUPNAGAR', N'Rupnagar', 180),
    (2019, 'PB_SAHIBZADAAJITSINGHNAGAR', N'Sahibzada Ajit Singh Nagar', 190),
    (2020, 'PB_SANGRUR', N'Sangrur', 200),
    (2021, 'PB_SHAHIDBHAGATSINGHNAGAR', N'Shahid Bhagat Singh Nagar', 210),
    (2022, 'PB_SRIMUKTSARSAHIB', N'Sri Muktsar Sahib', 220),
    (2023, 'PB_TARNTARAN', N'Tarn Taran', 230)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_PB, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (200001, 2001, 'PB_AMRITSAR', N'Amritsar', 10),
    (200002, 2002, 'PB_BARNALA', N'Barnala', 20),
    (200003, 2003, 'PB_BATHINDA', N'Bathinda', 30),
    (200004, 2004, 'PB_FARIDKOT', N'Faridkot', 40),
    (200005, 2005, 'PB_FATEHGARHSAHIB', N'Fatehgarh Sahib', 50),
    (200006, 2006, 'PB_FAZILKA', N'Fazilka', 60),
    (200007, 2007, 'PB_FEROZEPUR', N'Ferozepur', 70),
    (200008, 2008, 'PB_GURDASPUR', N'Gurdaspur', 80),
    (200009, 2009, 'PB_HOSHIARPUR', N'Hoshiarpur', 90),
    (200010, 2010, 'PB_JALANDHAR', N'Jalandhar', 100),
    (200011, 2011, 'PB_KAPURTHALA', N'Kapurthala', 110),
    (200012, 2012, 'PB_LUDHIANA', N'Ludhiana', 120),
    (200013, 2013, 'PB_MALERKOTLA', N'Malerkotla', 130),
    (200014, 2014, 'PB_MANSA', N'Mansa', 140),
    (200015, 2015, 'PB_MOGA', N'Moga', 150),
    (200016, 2016, 'PB_PATHANKOT', N'Pathankot', 160),
    (200017, 2017, 'PB_PATIALA', N'Patiala', 170),
    (200018, 2018, 'PB_RUPNAGAR', N'Rupnagar', 180),
    (200019, 2019, 'PB_SAHIBZADAAJITSINGHNAGAR_MOHALI', N'Mohali', 190),
    (200020, 2020, 'PB_SANGRUR', N'Sangrur', 200),
    (200021, 2021, 'PB_SHAHIDBHAGATSINGHNAGAR_NAWANSHAHR', N'Nawanshahr', 210),
    (200022, 2022, 'PB_SRIMUKTSARSAHIB', N'Sri Muktsar Sahib', 220),
    (200023, 2023, 'PB_TARNTARAN', N'Tarn Taran', 230)
) AS src (CityId, DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CityId, DistrictId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.CityId, src.DistrictId, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());
GO

/*--------------------------------------------------------------------------
  Rajasthan (RJ) — StateId 21, 41 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_RJ int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'RJ' AND Is_Deleted = 0);

IF @StateId_RJ IS NULL
    THROW 50001, '014_seed_geography_north: the state RJ is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_RJ <> 21
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      21 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_RJ nvarchar(400) = N'014_seed_geography_north: RJ is StateId '
        + CAST(@StateId_RJ AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 21.';

    RAISERROR('%s', 16, 1, @wrong_RJ);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (2101, 'RJ_AJMER', N'Ajmer', 10),
    (2102, 'RJ_ALWAR', N'Alwar', 20),
    (2103, 'RJ_BANSWARA', N'Banswara', 30),
    (2104, 'RJ_BARAN', N'Baran', 40),
    (2105, 'RJ_BARMER', N'Barmer', 50),
    (2106, 'RJ_BHARATPUR', N'Bharatpur', 60),
    (2107, 'RJ_BHILWARA', N'Bhilwara', 70),
    (2108, 'RJ_BIKANER', N'Bikaner', 80),
    (2109, 'RJ_BUNDI', N'Bundi', 90),
    (2110, 'RJ_CHITTORGARH', N'Chittorgarh', 100),
    (2111, 'RJ_CHURU', N'Churu', 110),
    (2112, 'RJ_DAUSA', N'Dausa', 120),
    (2113, 'RJ_DHOLPUR', N'Dholpur', 130),
    (2114, 'RJ_DUNGARPUR', N'Dungarpur', 140),
    (2115, 'RJ_HANUMANGARH', N'Hanumangarh', 150),
    (2116, 'RJ_JAIPUR', N'Jaipur', 160),
    (2117, 'RJ_JAISALMER', N'Jaisalmer', 170),
    (2118, 'RJ_JALORE', N'Jalore', 180),
    (2119, 'RJ_JHALAWAR', N'Jhalawar', 190),
    (2120, 'RJ_JHUNJHUNU', N'Jhunjhunu', 200),
    (2121, 'RJ_JODHPUR', N'Jodhpur', 210),
    (2122, 'RJ_KARAULI', N'Karauli', 220),
    (2123, 'RJ_KOTA', N'Kota', 230),
    (2124, 'RJ_NAGAUR', N'Nagaur', 240),
    (2125, 'RJ_PALI', N'Pali', 250),
    (2126, 'RJ_PRATAPGARH', N'Pratapgarh', 260),
    (2127, 'RJ_RAJSAMAND', N'Rajsamand', 270),
    (2128, 'RJ_SAWAIMADHOPUR', N'Sawai Madhopur', 280),
    (2129, 'RJ_SIKAR', N'Sikar', 290),
    (2130, 'RJ_SIROHI', N'Sirohi', 300),
    (2131, 'RJ_SRIGANGANAGAR', N'Sri Ganganagar', 310),
    (2132, 'RJ_TONK', N'Tonk', 320),
    (2133, 'RJ_UDAIPUR', N'Udaipur', 330),
    (2134, 'RJ_BALOTRA', N'Balotra', 340),
    (2135, 'RJ_BEAWAR', N'Beawar', 350),
    (2136, 'RJ_DEEG', N'Deeg', 360),
    (2137, 'RJ_DIDWANAKUCHAMAN', N'Didwana-Kuchaman', 370),
    (2138, 'RJ_KOTPUTLIBEHROR', N'Kotputli-Behror', 380),
    (2139, 'RJ_KHAIRTHALTIJARA', N'Khairthal-Tijara', 390),
    (2140, 'RJ_PHALODI', N'Phalodi', 400),
    (2141, 'RJ_SALUMBAR', N'Salumbar', 410)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_RJ, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (210001, 2101, 'RJ_AJMER', N'Ajmer', 10),
    (210002, 2102, 'RJ_ALWAR', N'Alwar', 20),
    (210003, 2103, 'RJ_BANSWARA', N'Banswara', 30),
    (210004, 2104, 'RJ_BARAN', N'Baran', 40),
    (210005, 2105, 'RJ_BARMER', N'Barmer', 50),
    (210006, 2106, 'RJ_BHARATPUR', N'Bharatpur', 60),
    (210007, 2107, 'RJ_BHILWARA', N'Bhilwara', 70),
    (210008, 2108, 'RJ_BIKANER', N'Bikaner', 80),
    (210009, 2109, 'RJ_BUNDI', N'Bundi', 90),
    (210010, 2110, 'RJ_CHITTORGARH', N'Chittorgarh', 100),
    (210011, 2111, 'RJ_CHURU', N'Churu', 110),
    (210012, 2112, 'RJ_DAUSA', N'Dausa', 120),
    (210013, 2113, 'RJ_DHOLPUR', N'Dholpur', 130),
    (210014, 2114, 'RJ_DUNGARPUR', N'Dungarpur', 140),
    (210015, 2115, 'RJ_HANUMANGARH', N'Hanumangarh', 150),
    (210016, 2116, 'RJ_JAIPUR', N'Jaipur', 160),
    (210017, 2117, 'RJ_JAISALMER', N'Jaisalmer', 170),
    (210018, 2118, 'RJ_JALORE', N'Jalore', 180),
    (210019, 2119, 'RJ_JHALAWAR', N'Jhalawar', 190),
    (210020, 2120, 'RJ_JHUNJHUNU', N'Jhunjhunu', 200),
    (210021, 2121, 'RJ_JODHPUR', N'Jodhpur', 210),
    (210022, 2122, 'RJ_KARAULI', N'Karauli', 220),
    (210023, 2123, 'RJ_KOTA', N'Kota', 230),
    (210024, 2124, 'RJ_NAGAUR', N'Nagaur', 240),
    (210025, 2125, 'RJ_PALI', N'Pali', 250),
    (210026, 2126, 'RJ_PRATAPGARH', N'Pratapgarh', 260),
    (210027, 2127, 'RJ_RAJSAMAND', N'Rajsamand', 270),
    (210028, 2128, 'RJ_SAWAIMADHOPUR', N'Sawai Madhopur', 280),
    (210029, 2129, 'RJ_SIKAR', N'Sikar', 290),
    (210030, 2130, 'RJ_SIROHI', N'Sirohi', 300),
    (210031, 2131, 'RJ_SRIGANGANAGAR', N'Sri Ganganagar', 310),
    (210032, 2132, 'RJ_TONK', N'Tonk', 320),
    (210033, 2133, 'RJ_UDAIPUR', N'Udaipur', 330),
    (210034, 2134, 'RJ_BALOTRA', N'Balotra', 340),
    (210035, 2135, 'RJ_BEAWAR', N'Beawar', 350),
    (210036, 2136, 'RJ_DEEG', N'Deeg', 360),
    (210037, 2137, 'RJ_DIDWANAKUCHAMAN', N'Didwana-Kuchaman', 370),
    (210038, 2138, 'RJ_KOTPUTLIBEHROR', N'Kotputli-Behror', 380),
    (210039, 2139, 'RJ_KHAIRTHALTIJARA', N'Khairthal-Tijara', 390),
    (210040, 2140, 'RJ_PHALODI', N'Phalodi', 400),
    (210041, 2141, 'RJ_SALUMBAR', N'Salumbar', 410)
) AS src (CityId, DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CityId, DistrictId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.CityId, src.DistrictId, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());
GO

/*--------------------------------------------------------------------------
  Uttar Pradesh (UP) — StateId 26, 75 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_UP int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'UP' AND Is_Deleted = 0);

IF @StateId_UP IS NULL
    THROW 50001, '014_seed_geography_north: the state UP is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_UP <> 26
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      26 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_UP nvarchar(400) = N'014_seed_geography_north: UP is StateId '
        + CAST(@StateId_UP AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 26.';

    RAISERROR('%s', 16, 1, @wrong_UP);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (2601, 'UP_AGRA', N'Agra', 10),
    (2602, 'UP_ALIGARH', N'Aligarh', 20),
    (2603, 'UP_AMBEDKARNAGAR', N'Ambedkar Nagar', 30),
    (2604, 'UP_AMETHI', N'Amethi', 40),
    (2605, 'UP_AMROHA', N'Amroha', 50),
    (2606, 'UP_AURAIYA', N'Auraiya', 60),
    (2607, 'UP_AYODHYA', N'Ayodhya', 70),
    (2608, 'UP_AZAMGARH', N'Azamgarh', 80),
    (2609, 'UP_BAGHPAT', N'Baghpat', 90),
    (2610, 'UP_BAHRAICH', N'Bahraich', 100),
    (2611, 'UP_BALLIA', N'Ballia', 110),
    (2612, 'UP_BALRAMPUR', N'Balrampur', 120),
    (2613, 'UP_BANDA', N'Banda', 130),
    (2614, 'UP_BARABANKI', N'Barabanki', 140),
    (2615, 'UP_BAREILLY', N'Bareilly', 150),
    (2616, 'UP_BASTI', N'Basti', 160),
    (2617, 'UP_BHADOHI', N'Bhadohi', 170),
    (2618, 'UP_BIJNOR', N'Bijnor', 180),
    (2619, 'UP_BUDAUN', N'Budaun', 190),
    (2620, 'UP_BULANDSHAHR', N'Bulandshahr', 200),
    (2621, 'UP_CHANDAULI', N'Chandauli', 210),
    (2622, 'UP_CHITRAKOOT', N'Chitrakoot', 220),
    (2623, 'UP_DEORIA', N'Deoria', 230),
    (2624, 'UP_ETAH', N'Etah', 240),
    (2625, 'UP_ETAWAH', N'Etawah', 250),
    (2626, 'UP_FARRUKHABAD', N'Farrukhabad', 260),
    (2627, 'UP_FATEHPUR', N'Fatehpur', 270),
    (2628, 'UP_FIROZABAD', N'Firozabad', 280),
    (2629, 'UP_GAUTAMBUDDHANAGAR', N'Gautam Buddha Nagar', 290),
    (2630, 'UP_GHAZIABAD', N'Ghaziabad', 300),
    (2631, 'UP_GHAZIPUR', N'Ghazipur', 310),
    (2632, 'UP_GONDA', N'Gonda', 320),
    (2633, 'UP_GORAKHPUR', N'Gorakhpur', 330),
    (2634, 'UP_HAMIRPUR', N'Hamirpur', 340),
    (2635, 'UP_HAPUR', N'Hapur', 350),
    (2636, 'UP_HARDOI', N'Hardoi', 360),
    (2637, 'UP_HATHRAS', N'Hathras', 370),
    (2638, 'UP_JALAUN', N'Jalaun', 380),
    (2639, 'UP_JAUNPUR', N'Jaunpur', 390),
    (2640, 'UP_JHANSI', N'Jhansi', 400),
    (2641, 'UP_KANNAUJ', N'Kannauj', 410),
    (2642, 'UP_KANPURDEHAT', N'Kanpur Dehat', 420),
    (2643, 'UP_KANPURNAGAR', N'Kanpur Nagar', 430),
    (2644, 'UP_KASGANJ', N'Kasganj', 440),
    (2645, 'UP_KAUSHAMBI', N'Kaushambi', 450),
    (2646, 'UP_KHERI', N'Kheri', 460),
    (2647, 'UP_KUSHINAGAR', N'Kushinagar', 470),
    (2648, 'UP_LALITPUR', N'Lalitpur', 480),
    (2649, 'UP_LUCKNOW', N'Lucknow', 490),
    (2650, 'UP_MAHARAJGANJ', N'Maharajganj', 500),
    (2651, 'UP_MAHOBA', N'Mahoba', 510),
    (2652, 'UP_MAINPURI', N'Mainpuri', 520),
    (2653, 'UP_MATHURA', N'Mathura', 530),
    (2654, 'UP_MAU', N'Mau', 540),
    (2655, 'UP_MEERUT', N'Meerut', 550),
    (2656, 'UP_MIRZAPUR', N'Mirzapur', 560),
    (2657, 'UP_MORADABAD', N'Moradabad', 570),
    (2658, 'UP_MUZAFFARNAGAR', N'Muzaffarnagar', 580),
    (2659, 'UP_PILIBHIT', N'Pilibhit', 590),
    (2660, 'UP_PRATAPGARH', N'Pratapgarh', 600),
    (2661, 'UP_PRAYAGRAJ', N'Prayagraj', 610),
    (2662, 'UP_RAEBARELI', N'Raebareli', 620),
    (2663, 'UP_RAMPUR', N'Rampur', 630),
    (2664, 'UP_SAHARANPUR', N'Saharanpur', 640),
    (2665, 'UP_SAMBHAL', N'Sambhal', 650),
    (2666, 'UP_SANTKABIRNAGAR', N'Sant Kabir Nagar', 660),
    (2667, 'UP_SHAHJAHANPUR', N'Shahjahanpur', 670),
    (2668, 'UP_SHAMLI', N'Shamli', 680),
    (2669, 'UP_SHRAVASTI', N'Shravasti', 690),
    (2670, 'UP_SIDDHARTHNAGAR', N'Siddharthnagar', 700),
    (2671, 'UP_SITAPUR', N'Sitapur', 710),
    (2672, 'UP_SONBHADRA', N'Sonbhadra', 720),
    (2673, 'UP_SULTANPUR', N'Sultanpur', 730),
    (2674, 'UP_UNNAO', N'Unnao', 740),
    (2675, 'UP_VARANASI', N'Varanasi', 750)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_UP, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (260001, 2601, 'UP_AGRA', N'Agra', 10),
    (260002, 2602, 'UP_ALIGARH', N'Aligarh', 20),
    (260003, 2603, 'UP_AMBEDKARNAGAR', N'Ambedkar Nagar', 30),
    (260004, 2604, 'UP_AMETHI', N'Amethi', 40),
    (260005, 2605, 'UP_AMROHA', N'Amroha', 50),
    (260006, 2606, 'UP_AURAIYA', N'Auraiya', 60),
    (260007, 2607, 'UP_AYODHYA', N'Ayodhya', 70),
    (260008, 2608, 'UP_AZAMGARH', N'Azamgarh', 80),
    (260009, 2609, 'UP_BAGHPAT', N'Baghpat', 90),
    (260010, 2610, 'UP_BAHRAICH', N'Bahraich', 100),
    (260011, 2611, 'UP_BALLIA', N'Ballia', 110),
    (260012, 2612, 'UP_BALRAMPUR', N'Balrampur', 120),
    (260013, 2613, 'UP_BANDA', N'Banda', 130),
    (260014, 2614, 'UP_BARABANKI', N'Barabanki', 140),
    (260015, 2615, 'UP_BAREILLY', N'Bareilly', 150),
    (260016, 2616, 'UP_BASTI', N'Basti', 160),
    (260017, 2617, 'UP_BHADOHI', N'Bhadohi', 170),
    (260018, 2618, 'UP_BIJNOR', N'Bijnor', 180),
    (260019, 2619, 'UP_BUDAUN', N'Budaun', 190),
    (260020, 2620, 'UP_BULANDSHAHR', N'Bulandshahr', 200),
    (260021, 2621, 'UP_CHANDAULI', N'Chandauli', 210),
    (260022, 2622, 'UP_CHITRAKOOT', N'Chitrakoot', 220),
    (260023, 2623, 'UP_DEORIA', N'Deoria', 230),
    (260024, 2624, 'UP_ETAH', N'Etah', 240),
    (260025, 2625, 'UP_ETAWAH', N'Etawah', 250),
    (260026, 2626, 'UP_FARRUKHABAD', N'Farrukhabad', 260),
    (260027, 2627, 'UP_FATEHPUR', N'Fatehpur', 270),
    (260028, 2628, 'UP_FIROZABAD', N'Firozabad', 280),
    (260029, 2629, 'UP_GAUTAMBUDDHANAGAR_NOIDA', N'Noida', 290),
    (260030, 2630, 'UP_GHAZIABAD', N'Ghaziabad', 300),
    (260031, 2631, 'UP_GHAZIPUR', N'Ghazipur', 310),
    (260032, 2632, 'UP_GONDA', N'Gonda', 320),
    (260033, 2633, 'UP_GORAKHPUR', N'Gorakhpur', 330),
    (260034, 2634, 'UP_HAMIRPUR', N'Hamirpur', 340),
    (260035, 2635, 'UP_HAPUR', N'Hapur', 350),
    (260036, 2636, 'UP_HARDOI', N'Hardoi', 360),
    (260037, 2637, 'UP_HATHRAS', N'Hathras', 370),
    (260038, 2638, 'UP_JALAUN', N'Jalaun', 380),
    (260039, 2639, 'UP_JAUNPUR', N'Jaunpur', 390),
    (260040, 2640, 'UP_JHANSI', N'Jhansi', 400),
    (260041, 2641, 'UP_KANNAUJ', N'Kannauj', 410),
    (260042, 2642, 'UP_KANPURDEHAT', N'Kanpur Dehat', 420),
    (260043, 2643, 'UP_KANPURNAGAR', N'Kanpur Nagar', 430),
    (260044, 2644, 'UP_KASGANJ', N'Kasganj', 440),
    (260045, 2645, 'UP_KAUSHAMBI', N'Kaushambi', 450),
    (260046, 2646, 'UP_KHERI', N'Kheri', 460),
    (260047, 2647, 'UP_KUSHINAGAR', N'Kushinagar', 470),
    (260048, 2648, 'UP_LALITPUR', N'Lalitpur', 480),
    (260049, 2649, 'UP_LUCKNOW', N'Lucknow', 490),
    (260050, 2650, 'UP_MAHARAJGANJ', N'Maharajganj', 500),
    (260051, 2651, 'UP_MAHOBA', N'Mahoba', 510),
    (260052, 2652, 'UP_MAINPURI', N'Mainpuri', 520),
    (260053, 2653, 'UP_MATHURA', N'Mathura', 530),
    (260054, 2654, 'UP_MAU', N'Mau', 540),
    (260055, 2655, 'UP_MEERUT', N'Meerut', 550),
    (260056, 2656, 'UP_MIRZAPUR', N'Mirzapur', 560),
    (260057, 2657, 'UP_MORADABAD', N'Moradabad', 570),
    (260058, 2658, 'UP_MUZAFFARNAGAR', N'Muzaffarnagar', 580),
    (260059, 2659, 'UP_PILIBHIT', N'Pilibhit', 590),
    (260060, 2660, 'UP_PRATAPGARH', N'Pratapgarh', 600),
    (260061, 2661, 'UP_PRAYAGRAJ', N'Prayagraj', 610),
    (260062, 2662, 'UP_RAEBARELI', N'Raebareli', 620),
    (260063, 2663, 'UP_RAMPUR', N'Rampur', 630),
    (260064, 2664, 'UP_SAHARANPUR', N'Saharanpur', 640),
    (260065, 2665, 'UP_SAMBHAL', N'Sambhal', 650),
    (260066, 2666, 'UP_SANTKABIRNAGAR', N'Sant Kabir Nagar', 660),
    (260067, 2667, 'UP_SHAHJAHANPUR', N'Shahjahanpur', 670),
    (260068, 2668, 'UP_SHAMLI', N'Shamli', 680),
    (260069, 2669, 'UP_SHRAVASTI', N'Shravasti', 690),
    (260070, 2670, 'UP_SIDDHARTHNAGAR', N'Siddharthnagar', 700),
    (260071, 2671, 'UP_SITAPUR', N'Sitapur', 710),
    (260072, 2672, 'UP_SONBHADRA', N'Sonbhadra', 720),
    (260073, 2673, 'UP_SULTANPUR', N'Sultanpur', 730),
    (260074, 2674, 'UP_UNNAO', N'Unnao', 740),
    (260075, 2675, 'UP_VARANASI', N'Varanasi', 750)
) AS src (CityId, DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CityId, DistrictId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.CityId, src.DistrictId, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());
GO

/*--------------------------------------------------------------------------
  Uttarakhand (UK) — StateId 27, 13 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_UK int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'UK' AND Is_Deleted = 0);

IF @StateId_UK IS NULL
    THROW 50001, '014_seed_geography_north: the state UK is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_UK <> 27
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      27 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_UK nvarchar(400) = N'014_seed_geography_north: UK is StateId '
        + CAST(@StateId_UK AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 27.';

    RAISERROR('%s', 16, 1, @wrong_UK);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (2701, 'UK_ALMORA', N'Almora', 10),
    (2702, 'UK_BAGESHWAR', N'Bageshwar', 20),
    (2703, 'UK_CHAMOLI', N'Chamoli', 30),
    (2704, 'UK_CHAMPAWAT', N'Champawat', 40),
    (2705, 'UK_DEHRADUN', N'Dehradun', 50),
    (2706, 'UK_HARIDWAR', N'Haridwar', 60),
    (2707, 'UK_NAINITAL', N'Nainital', 70),
    (2708, 'UK_PAURIGARHWAL', N'Pauri Garhwal', 80),
    (2709, 'UK_PITHORAGARH', N'Pithoragarh', 90),
    (2710, 'UK_RUDRAPRAYAG', N'Rudraprayag', 100),
    (2711, 'UK_TEHRIGARHWAL', N'Tehri Garhwal', 110),
    (2712, 'UK_UDHAMSINGHNAGAR', N'Udham Singh Nagar', 120),
    (2713, 'UK_UTTARKASHI', N'Uttarkashi', 130)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_UK, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (270001, 2701, 'UK_ALMORA', N'Almora', 10),
    (270002, 2702, 'UK_BAGESHWAR', N'Bageshwar', 20),
    (270003, 2703, 'UK_CHAMOLI', N'Chamoli', 30),
    (270004, 2704, 'UK_CHAMPAWAT', N'Champawat', 40),
    (270005, 2705, 'UK_DEHRADUN', N'Dehradun', 50),
    (270006, 2706, 'UK_HARIDWAR', N'Haridwar', 60),
    (270007, 2707, 'UK_NAINITAL', N'Nainital', 70),
    (270008, 2708, 'UK_PAURIGARHWAL', N'Pauri Garhwal', 80),
    (270009, 2709, 'UK_PITHORAGARH', N'Pithoragarh', 90),
    (270010, 2710, 'UK_RUDRAPRAYAG', N'Rudraprayag', 100),
    (270011, 2711, 'UK_TEHRIGARHWAL', N'Tehri Garhwal', 110),
    (270012, 2712, 'UK_UDHAMSINGHNAGAR', N'Udham Singh Nagar', 120),
    (270013, 2713, 'UK_UTTARKASHI', N'Uttarkashi', 130)
) AS src (CityId, DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CityId, DistrictId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.CityId, src.DistrictId, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());
GO

/*--------------------------------------------------------------------------
  Jammu and Kashmir (JK) — StateId 33, 20 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_JK int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'JK' AND Is_Deleted = 0);

IF @StateId_JK IS NULL
    THROW 50001, '014_seed_geography_north: the state JK is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_JK <> 33
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      33 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_JK nvarchar(400) = N'014_seed_geography_north: JK is StateId '
        + CAST(@StateId_JK AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 33.';

    RAISERROR('%s', 16, 1, @wrong_JK);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (3301, 'JK_ANANTNAG', N'Anantnag', 10),
    (3302, 'JK_BANDIPORA', N'Bandipora', 20),
    (3303, 'JK_BARAMULLA', N'Baramulla', 30),
    (3304, 'JK_BUDGAM', N'Budgam', 40),
    (3305, 'JK_DODA', N'Doda', 50),
    (3306, 'JK_GANDERBAL', N'Ganderbal', 60),
    (3307, 'JK_JAMMU', N'Jammu', 70),
    (3308, 'JK_KATHUA', N'Kathua', 80),
    (3309, 'JK_KISHTWAR', N'Kishtwar', 90),
    (3310, 'JK_KULGAM', N'Kulgam', 100),
    (3311, 'JK_KUPWARA', N'Kupwara', 110),
    (3312, 'JK_POONCH', N'Poonch', 120),
    (3313, 'JK_PULWAMA', N'Pulwama', 130),
    (3314, 'JK_RAJOURI', N'Rajouri', 140),
    (3315, 'JK_RAMBAN', N'Ramban', 150),
    (3316, 'JK_REASI', N'Reasi', 160),
    (3317, 'JK_SAMBA', N'Samba', 170),
    (3318, 'JK_SHOPIAN', N'Shopian', 180),
    (3319, 'JK_SRINAGAR', N'Srinagar', 190),
    (3320, 'JK_UDHAMPUR', N'Udhampur', 200)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_JK, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (330001, 3301, 'JK_ANANTNAG', N'Anantnag', 10),
    (330002, 3302, 'JK_BANDIPORA', N'Bandipora', 20),
    (330003, 3303, 'JK_BARAMULLA', N'Baramulla', 30),
    (330004, 3304, 'JK_BUDGAM', N'Budgam', 40),
    (330005, 3305, 'JK_DODA', N'Doda', 50),
    (330006, 3306, 'JK_GANDERBAL', N'Ganderbal', 60),
    (330007, 3307, 'JK_JAMMU', N'Jammu', 70),
    (330008, 3308, 'JK_KATHUA', N'Kathua', 80),
    (330009, 3309, 'JK_KISHTWAR', N'Kishtwar', 90),
    (330010, 3310, 'JK_KULGAM', N'Kulgam', 100),
    (330011, 3311, 'JK_KUPWARA', N'Kupwara', 110),
    (330012, 3312, 'JK_POONCH', N'Poonch', 120),
    (330013, 3313, 'JK_PULWAMA', N'Pulwama', 130),
    (330014, 3314, 'JK_RAJOURI', N'Rajouri', 140),
    (330015, 3315, 'JK_RAMBAN', N'Ramban', 150),
    (330016, 3316, 'JK_REASI', N'Reasi', 160),
    (330017, 3317, 'JK_SAMBA', N'Samba', 170),
    (330018, 3318, 'JK_SHOPIAN', N'Shopian', 180),
    (330019, 3319, 'JK_SRINAGAR', N'Srinagar', 190),
    (330020, 3320, 'JK_UDHAMPUR', N'Udhampur', 200)
) AS src (CityId, DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CityId, DistrictId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.CityId, src.DistrictId, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());
GO

/*--------------------------------------------------------------------------
  Ladakh (LA) — StateId 34, 7 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_LA int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'LA' AND Is_Deleted = 0);

IF @StateId_LA IS NULL
    THROW 50001, '014_seed_geography_north: the state LA is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_LA <> 34
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      34 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_LA nvarchar(400) = N'014_seed_geography_north: LA is StateId '
        + CAST(@StateId_LA AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 34.';

    RAISERROR('%s', 16, 1, @wrong_LA);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (3401, 'LA_KARGIL', N'Kargil', 10),
    (3402, 'LA_LEH', N'Leh', 20),
    (3403, 'LA_NUBRA', N'Nubra', 30),
    (3404, 'LA_CHANGTHANG', N'Changthang', 40),
    (3405, 'LA_SHAM', N'Sham', 50),
    (3406, 'LA_ZANSKAR', N'Zanskar', 60),
    (3407, 'LA_DRASS', N'Drass', 70)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_LA, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (340001, 3401, 'LA_KARGIL', N'Kargil', 10),
    (340002, 3402, 'LA_LEH', N'Leh', 20),
    (340003, 3403, 'LA_NUBRA', N'Nubra', 30),
    (340004, 3404, 'LA_CHANGTHANG', N'Changthang', 40),
    (340005, 3405, 'LA_SHAM', N'Sham', 50),
    (340006, 3406, 'LA_ZANSKAR', N'Zanskar', 60),
    (340007, 3407, 'LA_DRASS', N'Drass', 70)
) AS src (CityId, DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CityId, DistrictId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.CityId, src.DistrictId, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());
GO

/*--------------------------------------------------------------------------
  Chandigarh (CH) — StateId 30, 1 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_CH int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'CH' AND Is_Deleted = 0);

IF @StateId_CH IS NULL
    THROW 50001, '014_seed_geography_north: the state CH is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_CH <> 30
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      30 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_CH nvarchar(400) = N'014_seed_geography_north: CH is StateId '
        + CAST(@StateId_CH AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 30.';

    RAISERROR('%s', 16, 1, @wrong_CH);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (3001, 'CH_CHANDIGARH', N'Chandigarh', 10)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_CH, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (300001, 3001, 'CH_CHANDIGARH', N'Chandigarh', 10)
) AS src (CityId, DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CityId, DistrictId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.CityId, src.DistrictId, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());
GO

/*--------------------------------------------------------------------------
  Delhi (DL) — StateId 32, 11 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_DL int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'DL' AND Is_Deleted = 0);

IF @StateId_DL IS NULL
    THROW 50001, '014_seed_geography_north: the state DL is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_DL <> 32
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      32 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_DL nvarchar(400) = N'014_seed_geography_north: DL is StateId '
        + CAST(@StateId_DL AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 32.';

    RAISERROR('%s', 16, 1, @wrong_DL);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (3201, 'DL_CENTRALDELHI', N'Central Delhi', 10),
    (3202, 'DL_EASTDELHI', N'East Delhi', 20),
    (3203, 'DL_NEWDELHI', N'New Delhi', 30),
    (3204, 'DL_NORTHDELHI', N'North Delhi', 40),
    (3205, 'DL_NORTHEASTDELHI', N'North East Delhi', 50),
    (3206, 'DL_NORTHWESTDELHI', N'North West Delhi', 60),
    (3207, 'DL_SHAHDARA', N'Shahdara', 70),
    (3208, 'DL_SOUTHDELHI', N'South Delhi', 80),
    (3209, 'DL_SOUTHEASTDELHI', N'South East Delhi', 90),
    (3210, 'DL_SOUTHWESTDELHI', N'South West Delhi', 100),
    (3211, 'DL_WESTDELHI', N'West Delhi', 110)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_DL, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (320001, 3201, 'DL_CENTRALDELHI', N'Central Delhi', 10),
    (320002, 3202, 'DL_EASTDELHI', N'East Delhi', 20),
    (320003, 3203, 'DL_NEWDELHI', N'New Delhi', 30),
    (320004, 3204, 'DL_NORTHDELHI', N'North Delhi', 40),
    (320005, 3205, 'DL_NORTHEASTDELHI', N'North East Delhi', 50),
    (320006, 3206, 'DL_NORTHWESTDELHI', N'North West Delhi', 60),
    (320007, 3207, 'DL_SHAHDARA', N'Shahdara', 70),
    (320008, 3208, 'DL_SOUTHDELHI', N'South Delhi', 80),
    (320009, 3209, 'DL_SOUTHEASTDELHI', N'South East Delhi', 90),
    (320010, 3210, 'DL_SOUTHWESTDELHI', N'South West Delhi', 100),
    (320011, 3211, 'DL_WESTDELHI', N'West Delhi', 110)
) AS src (CityId, DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CityId, DistrictId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.CityId, src.DistrictId, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());
GO

/*==============================================================================
  EXIT ASSERTIONS — the counts this file promises

  🔴 COUNTS ASSERTED, NOT PRINTED AND HOPED FOR. A seed that silently inserts
  most of its rows leaves a product where some districts do not exist and
  nothing is red.
==============================================================================*/
DECLARE @d_HP int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'HP' AND d.Is_Deleted = 0);
IF @d_HP <> 12
BEGIN
    DECLARE @m_HP nvarchar(400) = N'014_seed_geography_north: Himachal Pradesh has ' + CAST(@d_HP AS nvarchar(10))
        + N' districts, expected 12. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_HP);
END

DECLARE @d_PB int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'PB' AND d.Is_Deleted = 0);
IF @d_PB <> 23
BEGIN
    DECLARE @m_PB nvarchar(400) = N'014_seed_geography_north: Punjab has ' + CAST(@d_PB AS nvarchar(10))
        + N' districts, expected 23. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_PB);
END

DECLARE @d_RJ int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'RJ' AND d.Is_Deleted = 0);
IF @d_RJ <> 41
BEGIN
    DECLARE @m_RJ nvarchar(400) = N'014_seed_geography_north: Rajasthan has ' + CAST(@d_RJ AS nvarchar(10))
        + N' districts, expected 41. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_RJ);
END

DECLARE @d_UP int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'UP' AND d.Is_Deleted = 0);
IF @d_UP <> 75
BEGIN
    DECLARE @m_UP nvarchar(400) = N'014_seed_geography_north: Uttar Pradesh has ' + CAST(@d_UP AS nvarchar(10))
        + N' districts, expected 75. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_UP);
END

DECLARE @d_UK int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'UK' AND d.Is_Deleted = 0);
IF @d_UK <> 13
BEGIN
    DECLARE @m_UK nvarchar(400) = N'014_seed_geography_north: Uttarakhand has ' + CAST(@d_UK AS nvarchar(10))
        + N' districts, expected 13. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_UK);
END

DECLARE @d_JK int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'JK' AND d.Is_Deleted = 0);
IF @d_JK <> 20
BEGIN
    DECLARE @m_JK nvarchar(400) = N'014_seed_geography_north: Jammu and Kashmir has ' + CAST(@d_JK AS nvarchar(10))
        + N' districts, expected 20. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_JK);
END

DECLARE @d_LA int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'LA' AND d.Is_Deleted = 0);
IF @d_LA <> 7
BEGIN
    DECLARE @m_LA nvarchar(400) = N'014_seed_geography_north: Ladakh has ' + CAST(@d_LA AS nvarchar(10))
        + N' districts, expected 7. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_LA);
END

DECLARE @d_CH int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'CH' AND d.Is_Deleted = 0);
IF @d_CH <> 1
BEGIN
    DECLARE @m_CH nvarchar(400) = N'014_seed_geography_north: Chandigarh has ' + CAST(@d_CH AS nvarchar(10))
        + N' districts, expected 1. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_CH);
END

DECLARE @d_DL int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'DL' AND d.Is_Deleted = 0);
IF @d_DL <> 11
BEGIN
    DECLARE @m_DL nvarchar(400) = N'014_seed_geography_north: Delhi has ' + CAST(@d_DL AS nvarchar(10))
        + N' districts, expected 11. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_DL);
END

PRINT '    North India and the northern UTs ready — 203 districts, 203 towns.';
GO
