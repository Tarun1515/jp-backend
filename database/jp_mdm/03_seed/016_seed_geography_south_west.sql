/*==============================================================================
  South and West India and the island UTs — districts and their headquarters towns.

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
      Madhya Pradesh — three districts created in 2023
      Chhattisgarh — three districts created in 2022

  ---------------------------------------------------------------------------
  CONTENTS: 14 states/UTs, 312 districts, 312 towns
  (one town per district: its headquarters).

  IDEMPOTENT. Every row is guarded on Code, so re-running changes nothing.
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

PRINT '  Seeding geography — South and West India and the island UTs ...';
GO

/*--------------------------------------------------------------------------
  Gujarat (GJ) — StateId 7, 33 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_GJ int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'GJ' AND Is_Deleted = 0);

IF @StateId_GJ IS NULL
    THROW 50001, '016_seed_geography_south_west: the state GJ is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_GJ <> 7
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      7 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_GJ nvarchar(400) = N'016_seed_geography_south_west: GJ is StateId '
        + CAST(@StateId_GJ AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 7.';

    RAISERROR('%s', 16, 1, @wrong_GJ);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (701, 'GJ_AHMEDABAD', N'Ahmedabad', 10),
    (702, 'GJ_AMRELI', N'Amreli', 20),
    (703, 'GJ_ANAND', N'Anand', 30),
    (704, 'GJ_ARAVALLI', N'Aravalli', 40),
    (705, 'GJ_BANASKANTHA', N'Banaskantha', 50),
    (706, 'GJ_BHARUCH', N'Bharuch', 60),
    (707, 'GJ_BHAVNAGAR', N'Bhavnagar', 70),
    (708, 'GJ_BOTAD', N'Botad', 80),
    (709, 'GJ_CHHOTAUDAIPUR', N'Chhota Udaipur', 90),
    (710, 'GJ_DAHOD', N'Dahod', 100),
    (711, 'GJ_DANG', N'Dang', 110),
    (712, 'GJ_DEVBHOOMIDWARKA', N'Devbhoomi Dwarka', 120),
    (713, 'GJ_GANDHINAGAR', N'Gandhinagar', 130),
    (714, 'GJ_GIRSOMNATH', N'Gir Somnath', 140),
    (715, 'GJ_JAMNAGAR', N'Jamnagar', 150),
    (716, 'GJ_JUNAGADH', N'Junagadh', 160),
    (717, 'GJ_KHEDA', N'Kheda', 170),
    (718, 'GJ_KUTCH', N'Kutch', 180),
    (719, 'GJ_MAHISAGAR', N'Mahisagar', 190),
    (720, 'GJ_MEHSANA', N'Mehsana', 200),
    (721, 'GJ_MORBI', N'Morbi', 210),
    (722, 'GJ_NARMADA', N'Narmada', 220),
    (723, 'GJ_NAVSARI', N'Navsari', 230),
    (724, 'GJ_PANCHMAHAL', N'Panchmahal', 240),
    (725, 'GJ_PATAN', N'Patan', 250),
    (726, 'GJ_PORBANDAR', N'Porbandar', 260),
    (727, 'GJ_RAJKOT', N'Rajkot', 270),
    (728, 'GJ_SABARKANTHA', N'Sabarkantha', 280),
    (729, 'GJ_SURAT', N'Surat', 290),
    (730, 'GJ_SURENDRANAGAR', N'Surendranagar', 300),
    (731, 'GJ_TAPI', N'Tapi', 310),
    (732, 'GJ_VADODARA', N'Vadodara', 320),
    (733, 'GJ_VALSAD', N'Valsad', 330)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_GJ, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (70001, 701, 'GJ_AHMEDABAD', N'Ahmedabad', 10),
    (70002, 702, 'GJ_AMRELI', N'Amreli', 20),
    (70003, 703, 'GJ_ANAND', N'Anand', 30),
    (70004, 704, 'GJ_ARAVALLI', N'Aravalli', 40),
    (70005, 705, 'GJ_BANASKANTHA', N'Banaskantha', 50),
    (70006, 706, 'GJ_BHARUCH', N'Bharuch', 60),
    (70007, 707, 'GJ_BHAVNAGAR', N'Bhavnagar', 70),
    (70008, 708, 'GJ_BOTAD', N'Botad', 80),
    (70009, 709, 'GJ_CHHOTAUDAIPUR', N'Chhota Udaipur', 90),
    (70010, 710, 'GJ_DAHOD', N'Dahod', 100),
    (70011, 711, 'GJ_DANG', N'Dang', 110),
    (70012, 712, 'GJ_DEVBHOOMIDWARKA', N'Devbhoomi Dwarka', 120),
    (70013, 713, 'GJ_GANDHINAGAR', N'Gandhinagar', 130),
    (70014, 714, 'GJ_GIRSOMNATH', N'Gir Somnath', 140),
    (70015, 715, 'GJ_JAMNAGAR', N'Jamnagar', 150),
    (70016, 716, 'GJ_JUNAGADH', N'Junagadh', 160),
    (70017, 717, 'GJ_KHEDA', N'Kheda', 170),
    (70018, 718, 'GJ_KUTCH', N'Kutch', 180),
    (70019, 719, 'GJ_MAHISAGAR', N'Mahisagar', 190),
    (70020, 720, 'GJ_MEHSANA', N'Mehsana', 200),
    (70021, 721, 'GJ_MORBI', N'Morbi', 210),
    (70022, 722, 'GJ_NARMADA', N'Narmada', 220),
    (70023, 723, 'GJ_NAVSARI', N'Navsari', 230),
    (70024, 724, 'GJ_PANCHMAHAL', N'Panchmahal', 240),
    (70025, 725, 'GJ_PATAN', N'Patan', 250),
    (70026, 726, 'GJ_PORBANDAR', N'Porbandar', 260),
    (70027, 727, 'GJ_RAJKOT', N'Rajkot', 270),
    (70028, 728, 'GJ_SABARKANTHA', N'Sabarkantha', 280),
    (70029, 729, 'GJ_SURAT', N'Surat', 290),
    (70030, 730, 'GJ_SURENDRANAGAR', N'Surendranagar', 300),
    (70031, 731, 'GJ_TAPI', N'Tapi', 310),
    (70032, 732, 'GJ_VADODARA', N'Vadodara', 320),
    (70033, 733, 'GJ_VALSAD', N'Valsad', 330)
) AS src (CityId, DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CityId, DistrictId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.CityId, src.DistrictId, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());
GO

/*--------------------------------------------------------------------------
  Maharashtra (MH) — StateId 14, 36 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_MH int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'MH' AND Is_Deleted = 0);

IF @StateId_MH IS NULL
    THROW 50001, '016_seed_geography_south_west: the state MH is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_MH <> 14
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      14 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_MH nvarchar(400) = N'016_seed_geography_south_west: MH is StateId '
        + CAST(@StateId_MH AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 14.';

    RAISERROR('%s', 16, 1, @wrong_MH);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (1401, 'MH_AHMEDNAGAR', N'Ahmednagar', 10),
    (1402, 'MH_AKOLA', N'Akola', 20),
    (1403, 'MH_AMRAVATI', N'Amravati', 30),
    (1404, 'MH_BEED', N'Beed', 40),
    (1405, 'MH_BHANDARA', N'Bhandara', 50),
    (1406, 'MH_BULDHANA', N'Buldhana', 60),
    (1407, 'MH_CHANDRAPUR', N'Chandrapur', 70),
    (1408, 'MH_CHHATRAPATISAMBHAJINAGAR', N'Chhatrapati Sambhajinagar', 80),
    (1409, 'MH_DHULE', N'Dhule', 90),
    (1410, 'MH_GADCHIROLI', N'Gadchiroli', 100),
    (1411, 'MH_GONDIA', N'Gondia', 110),
    (1412, 'MH_HINGOLI', N'Hingoli', 120),
    (1413, 'MH_JALGAON', N'Jalgaon', 130),
    (1414, 'MH_JALNA', N'Jalna', 140),
    (1415, 'MH_KOLHAPUR', N'Kolhapur', 150),
    (1416, 'MH_LATUR', N'Latur', 160),
    (1417, 'MH_MUMBAICITY', N'Mumbai City', 170),
    (1418, 'MH_MUMBAISUBURBAN', N'Mumbai Suburban', 180),
    (1419, 'MH_NAGPUR', N'Nagpur', 190),
    (1420, 'MH_NANDED', N'Nanded', 200),
    (1421, 'MH_NANDURBAR', N'Nandurbar', 210),
    (1422, 'MH_NASHIK', N'Nashik', 220),
    (1423, 'MH_OSMANABAD', N'Osmanabad', 230),
    (1424, 'MH_PALGHAR', N'Palghar', 240),
    (1425, 'MH_PARBHANI', N'Parbhani', 250),
    (1426, 'MH_PUNE', N'Pune', 260),
    (1427, 'MH_RAIGAD', N'Raigad', 270),
    (1428, 'MH_RATNAGIRI', N'Ratnagiri', 280),
    (1429, 'MH_SANGLI', N'Sangli', 290),
    (1430, 'MH_SATARA', N'Satara', 300),
    (1431, 'MH_SINDHUDURG', N'Sindhudurg', 310),
    (1432, 'MH_SOLAPUR', N'Solapur', 320),
    (1433, 'MH_THANE', N'Thane', 330),
    (1434, 'MH_WARDHA', N'Wardha', 340),
    (1435, 'MH_WASHIM', N'Washim', 350),
    (1436, 'MH_YAVATMAL', N'Yavatmal', 360)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_MH, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (140001, 1401, 'MH_AHMEDNAGAR', N'Ahmednagar', 10),
    (140002, 1402, 'MH_AKOLA', N'Akola', 20),
    (140003, 1403, 'MH_AMRAVATI', N'Amravati', 30),
    (140004, 1404, 'MH_BEED', N'Beed', 40),
    (140005, 1405, 'MH_BHANDARA', N'Bhandara', 50),
    (140006, 1406, 'MH_BULDHANA', N'Buldhana', 60),
    (140007, 1407, 'MH_CHANDRAPUR', N'Chandrapur', 70),
    (140008, 1408, 'MH_CHHATRAPATISAMBHAJINAGAR', N'Chhatrapati Sambhajinagar', 80),
    (140009, 1409, 'MH_DHULE', N'Dhule', 90),
    (140010, 1410, 'MH_GADCHIROLI', N'Gadchiroli', 100),
    (140011, 1411, 'MH_GONDIA', N'Gondia', 110),
    (140012, 1412, 'MH_HINGOLI', N'Hingoli', 120),
    (140013, 1413, 'MH_JALGAON', N'Jalgaon', 130),
    (140014, 1414, 'MH_JALNA', N'Jalna', 140),
    (140015, 1415, 'MH_KOLHAPUR', N'Kolhapur', 150),
    (140016, 1416, 'MH_LATUR', N'Latur', 160),
    (140017, 1417, 'MH_MUMBAICITY_MUMBAI', N'Mumbai', 170),
    (140018, 1418, 'MH_MUMBAISUBURBAN_BANDRA', N'Bandra', 180),
    (140019, 1419, 'MH_NAGPUR', N'Nagpur', 190),
    (140020, 1420, 'MH_NANDED', N'Nanded', 200),
    (140021, 1421, 'MH_NANDURBAR', N'Nandurbar', 210),
    (140022, 1422, 'MH_NASHIK', N'Nashik', 220),
    (140023, 1423, 'MH_OSMANABAD', N'Osmanabad', 230),
    (140024, 1424, 'MH_PALGHAR', N'Palghar', 240),
    (140025, 1425, 'MH_PARBHANI', N'Parbhani', 250),
    (140026, 1426, 'MH_PUNE', N'Pune', 260),
    (140027, 1427, 'MH_RAIGAD', N'Raigad', 270),
    (140028, 1428, 'MH_RATNAGIRI', N'Ratnagiri', 280),
    (140029, 1429, 'MH_SANGLI', N'Sangli', 290),
    (140030, 1430, 'MH_SATARA', N'Satara', 300),
    (140031, 1431, 'MH_SINDHUDURG', N'Sindhudurg', 310),
    (140032, 1432, 'MH_SOLAPUR', N'Solapur', 320),
    (140033, 1433, 'MH_THANE', N'Thane', 330),
    (140034, 1434, 'MH_WARDHA', N'Wardha', 340),
    (140035, 1435, 'MH_WASHIM', N'Washim', 350),
    (140036, 1436, 'MH_YAVATMAL', N'Yavatmal', 360)
) AS src (CityId, DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CityId, DistrictId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.CityId, src.DistrictId, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());
GO

/*--------------------------------------------------------------------------
  Goa (GA) — StateId 6, 2 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_GA int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'GA' AND Is_Deleted = 0);

IF @StateId_GA IS NULL
    THROW 50001, '016_seed_geography_south_west: the state GA is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_GA <> 6
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      6 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_GA nvarchar(400) = N'016_seed_geography_south_west: GA is StateId '
        + CAST(@StateId_GA AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 6.';

    RAISERROR('%s', 16, 1, @wrong_GA);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (601, 'GA_NORTHGOA', N'North Goa', 10),
    (602, 'GA_SOUTHGOA', N'South Goa', 20)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_GA, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (60001, 601, 'GA_NORTHGOA', N'North Goa', 10),
    (60002, 602, 'GA_SOUTHGOA', N'South Goa', 20)
) AS src (CityId, DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CityId, DistrictId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.CityId, src.DistrictId, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());
GO

/*--------------------------------------------------------------------------
  Madhya Pradesh (MP) — StateId 13, 55 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_MP int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'MP' AND Is_Deleted = 0);

IF @StateId_MP IS NULL
    THROW 50001, '016_seed_geography_south_west: the state MP is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_MP <> 13
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      13 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_MP nvarchar(400) = N'016_seed_geography_south_west: MP is StateId '
        + CAST(@StateId_MP AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 13.';

    RAISERROR('%s', 16, 1, @wrong_MP);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (1301, 'MP_AGARMALWA', N'Agar Malwa', 10),
    (1302, 'MP_ALIRAJPUR', N'Alirajpur', 20),
    (1303, 'MP_ANUPPUR', N'Anuppur', 30),
    (1304, 'MP_ASHOKNAGAR', N'Ashoknagar', 40),
    (1305, 'MP_BALAGHAT', N'Balaghat', 50),
    (1306, 'MP_BARWANI', N'Barwani', 60),
    (1307, 'MP_BETUL', N'Betul', 70),
    (1308, 'MP_BHIND', N'Bhind', 80),
    (1309, 'MP_BHOPAL', N'Bhopal', 90),
    (1310, 'MP_BURHANPUR', N'Burhanpur', 100),
    (1311, 'MP_CHHATARPUR', N'Chhatarpur', 110),
    (1312, 'MP_CHHINDWARA', N'Chhindwara', 120),
    (1313, 'MP_DAMOH', N'Damoh', 130),
    (1314, 'MP_DATIA', N'Datia', 140),
    (1315, 'MP_DEWAS', N'Dewas', 150),
    (1316, 'MP_DHAR', N'Dhar', 160),
    (1317, 'MP_DINDORI', N'Dindori', 170),
    (1318, 'MP_GUNA', N'Guna', 180),
    (1319, 'MP_GWALIOR', N'Gwalior', 190),
    (1320, 'MP_HARDA', N'Harda', 200),
    (1321, 'MP_INDORE', N'Indore', 210),
    (1322, 'MP_JABALPUR', N'Jabalpur', 220),
    (1323, 'MP_JHABUA', N'Jhabua', 230),
    (1324, 'MP_KATNI', N'Katni', 240),
    (1325, 'MP_KHANDWA', N'Khandwa', 250),
    (1326, 'MP_KHARGONE', N'Khargone', 260),
    (1327, 'MP_MANDLA', N'Mandla', 270),
    (1328, 'MP_MANDSAUR', N'Mandsaur', 280),
    (1329, 'MP_MORENA', N'Morena', 290),
    (1330, 'MP_NARMADAPURAM', N'Narmadapuram', 300),
    (1331, 'MP_NARSINGHPUR', N'Narsinghpur', 310),
    (1332, 'MP_NEEMUCH', N'Neemuch', 320),
    (1333, 'MP_NIWARI', N'Niwari', 330),
    (1334, 'MP_PANNA', N'Panna', 340),
    (1335, 'MP_RAISEN', N'Raisen', 350),
    (1336, 'MP_RAJGARH', N'Rajgarh', 360),
    (1337, 'MP_RATLAM', N'Ratlam', 370),
    (1338, 'MP_REWA', N'Rewa', 380),
    (1339, 'MP_SAGAR', N'Sagar', 390),
    (1340, 'MP_SATNA', N'Satna', 400),
    (1341, 'MP_SEHORE', N'Sehore', 410),
    (1342, 'MP_SEONI', N'Seoni', 420),
    (1343, 'MP_SHAHDOL', N'Shahdol', 430),
    (1344, 'MP_SHAJAPUR', N'Shajapur', 440),
    (1345, 'MP_SHEOPUR', N'Sheopur', 450),
    (1346, 'MP_SHIVPURI', N'Shivpuri', 460),
    (1347, 'MP_SIDHI', N'Sidhi', 470),
    (1348, 'MP_SINGRAULI', N'Singrauli', 480),
    (1349, 'MP_TIKAMGARH', N'Tikamgarh', 490),
    (1350, 'MP_UJJAIN', N'Ujjain', 500),
    (1351, 'MP_UMARIA', N'Umaria', 510),
    (1352, 'MP_VIDISHA', N'Vidisha', 520),
    (1353, 'MP_MAIHAR', N'Maihar', 530),
    (1354, 'MP_PANDHURNA', N'Pandhurna', 540),
    (1355, 'MP_MAUGANJ', N'Mauganj', 550)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_MP, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (130001, 1301, 'MP_AGARMALWA', N'Agar Malwa', 10),
    (130002, 1302, 'MP_ALIRAJPUR', N'Alirajpur', 20),
    (130003, 1303, 'MP_ANUPPUR', N'Anuppur', 30),
    (130004, 1304, 'MP_ASHOKNAGAR', N'Ashoknagar', 40),
    (130005, 1305, 'MP_BALAGHAT', N'Balaghat', 50),
    (130006, 1306, 'MP_BARWANI', N'Barwani', 60),
    (130007, 1307, 'MP_BETUL', N'Betul', 70),
    (130008, 1308, 'MP_BHIND', N'Bhind', 80),
    (130009, 1309, 'MP_BHOPAL', N'Bhopal', 90),
    (130010, 1310, 'MP_BURHANPUR', N'Burhanpur', 100),
    (130011, 1311, 'MP_CHHATARPUR', N'Chhatarpur', 110),
    (130012, 1312, 'MP_CHHINDWARA', N'Chhindwara', 120),
    (130013, 1313, 'MP_DAMOH', N'Damoh', 130),
    (130014, 1314, 'MP_DATIA', N'Datia', 140),
    (130015, 1315, 'MP_DEWAS', N'Dewas', 150),
    (130016, 1316, 'MP_DHAR', N'Dhar', 160),
    (130017, 1317, 'MP_DINDORI', N'Dindori', 170),
    (130018, 1318, 'MP_GUNA', N'Guna', 180),
    (130019, 1319, 'MP_GWALIOR', N'Gwalior', 190),
    (130020, 1320, 'MP_HARDA', N'Harda', 200),
    (130021, 1321, 'MP_INDORE', N'Indore', 210),
    (130022, 1322, 'MP_JABALPUR', N'Jabalpur', 220),
    (130023, 1323, 'MP_JHABUA', N'Jhabua', 230),
    (130024, 1324, 'MP_KATNI', N'Katni', 240),
    (130025, 1325, 'MP_KHANDWA', N'Khandwa', 250),
    (130026, 1326, 'MP_KHARGONE', N'Khargone', 260),
    (130027, 1327, 'MP_MANDLA', N'Mandla', 270),
    (130028, 1328, 'MP_MANDSAUR', N'Mandsaur', 280),
    (130029, 1329, 'MP_MORENA', N'Morena', 290),
    (130030, 1330, 'MP_NARMADAPURAM', N'Narmadapuram', 300),
    (130031, 1331, 'MP_NARSINGHPUR', N'Narsinghpur', 310),
    (130032, 1332, 'MP_NEEMUCH', N'Neemuch', 320),
    (130033, 1333, 'MP_NIWARI', N'Niwari', 330),
    (130034, 1334, 'MP_PANNA', N'Panna', 340),
    (130035, 1335, 'MP_RAISEN', N'Raisen', 350),
    (130036, 1336, 'MP_RAJGARH', N'Rajgarh', 360),
    (130037, 1337, 'MP_RATLAM', N'Ratlam', 370),
    (130038, 1338, 'MP_REWA', N'Rewa', 380),
    (130039, 1339, 'MP_SAGAR', N'Sagar', 390),
    (130040, 1340, 'MP_SATNA', N'Satna', 400),
    (130041, 1341, 'MP_SEHORE', N'Sehore', 410),
    (130042, 1342, 'MP_SEONI', N'Seoni', 420),
    (130043, 1343, 'MP_SHAHDOL', N'Shahdol', 430),
    (130044, 1344, 'MP_SHAJAPUR', N'Shajapur', 440),
    (130045, 1345, 'MP_SHEOPUR', N'Sheopur', 450),
    (130046, 1346, 'MP_SHIVPURI', N'Shivpuri', 460),
    (130047, 1347, 'MP_SIDHI', N'Sidhi', 470),
    (130048, 1348, 'MP_SINGRAULI', N'Singrauli', 480),
    (130049, 1349, 'MP_TIKAMGARH', N'Tikamgarh', 490),
    (130050, 1350, 'MP_UJJAIN', N'Ujjain', 500),
    (130051, 1351, 'MP_UMARIA', N'Umaria', 510),
    (130052, 1352, 'MP_VIDISHA', N'Vidisha', 520),
    (130053, 1353, 'MP_MAIHAR', N'Maihar', 530),
    (130054, 1354, 'MP_PANDHURNA', N'Pandhurna', 540),
    (130055, 1355, 'MP_MAUGANJ', N'Mauganj', 550)
) AS src (CityId, DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CityId, DistrictId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.CityId, src.DistrictId, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());
GO

/*--------------------------------------------------------------------------
  Chhattisgarh (CG) — StateId 5, 33 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_CG int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'CG' AND Is_Deleted = 0);

IF @StateId_CG IS NULL
    THROW 50001, '016_seed_geography_south_west: the state CG is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_CG <> 5
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      5 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_CG nvarchar(400) = N'016_seed_geography_south_west: CG is StateId '
        + CAST(@StateId_CG AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 5.';

    RAISERROR('%s', 16, 1, @wrong_CG);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (501, 'CG_BALOD', N'Balod', 10),
    (502, 'CG_BALODABAZAR', N'Baloda Bazar', 20),
    (503, 'CG_BALRAMPUR', N'Balrampur', 30),
    (504, 'CG_BASTAR', N'Bastar', 40),
    (505, 'CG_BEMETARA', N'Bemetara', 50),
    (506, 'CG_BIJAPUR', N'Bijapur', 60),
    (507, 'CG_BILASPUR', N'Bilaspur', 70),
    (508, 'CG_DANTEWADA', N'Dantewada', 80),
    (509, 'CG_DHAMTARI', N'Dhamtari', 90),
    (510, 'CG_DURG', N'Durg', 100),
    (511, 'CG_GARIABAND', N'Gariaband', 110),
    (512, 'CG_GAURELAPENDRAMARWAHI', N'Gaurela-Pendra-Marwahi', 120),
    (513, 'CG_JANJGIRCHAMPA', N'Janjgir-Champa', 130),
    (514, 'CG_JASHPUR', N'Jashpur', 140),
    (515, 'CG_KABIRDHAM', N'Kabirdham', 150),
    (516, 'CG_KANKER', N'Kanker', 160),
    (517, 'CG_KONDAGAON', N'Kondagaon', 170),
    (518, 'CG_KORBA', N'Korba', 180),
    (519, 'CG_KORIYA', N'Koriya', 190),
    (520, 'CG_MAHASAMUND', N'Mahasamund', 200),
    (521, 'CG_MANENDRAGARHCHIRMIRIBHARATPUR', N'Manendragarh-Chirmiri-Bharatpur', 210),
    (522, 'CG_MOHLAMANPURAMBAGARHCHOWKI', N'Mohla-Manpur-Ambagarh Chowki', 220),
    (523, 'CG_MUNGELI', N'Mungeli', 230),
    (524, 'CG_NARAYANPUR', N'Narayanpur', 240),
    (525, 'CG_RAIGARH', N'Raigarh', 250),
    (526, 'CG_RAIPUR', N'Raipur', 260),
    (527, 'CG_RAJNANDGAON', N'Rajnandgaon', 270),
    (528, 'CG_SAKTI', N'Sakti', 280),
    (529, 'CG_SARANGARHBILAIGARH', N'Sarangarh-Bilaigarh', 290),
    (530, 'CG_SUKMA', N'Sukma', 300),
    (531, 'CG_SURAJPUR', N'Surajpur', 310),
    (532, 'CG_SURGUJA', N'Surguja', 320),
    (533, 'CG_KHAIRAGARHCHHUIKHADANGANDAI', N'Khairagarh-Chhuikhadan-Gandai', 330)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_CG, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (50001, 501, 'CG_BALOD', N'Balod', 10),
    (50002, 502, 'CG_BALODABAZAR', N'Baloda Bazar', 20),
    (50003, 503, 'CG_BALRAMPUR', N'Balrampur', 30),
    (50004, 504, 'CG_BASTAR', N'Bastar', 40),
    (50005, 505, 'CG_BEMETARA', N'Bemetara', 50),
    (50006, 506, 'CG_BIJAPUR', N'Bijapur', 60),
    (50007, 507, 'CG_BILASPUR', N'Bilaspur', 70),
    (50008, 508, 'CG_DANTEWADA', N'Dantewada', 80),
    (50009, 509, 'CG_DHAMTARI', N'Dhamtari', 90),
    (50010, 510, 'CG_DURG', N'Durg', 100),
    (50011, 511, 'CG_GARIABAND', N'Gariaband', 110),
    (50012, 512, 'CG_GAURELAPENDRAMARWAHI', N'Gaurela-Pendra-Marwahi', 120),
    (50013, 513, 'CG_JANJGIRCHAMPA', N'Janjgir-Champa', 130),
    (50014, 514, 'CG_JASHPUR', N'Jashpur', 140),
    (50015, 515, 'CG_KABIRDHAM', N'Kabirdham', 150),
    (50016, 516, 'CG_KANKER', N'Kanker', 160),
    (50017, 517, 'CG_KONDAGAON', N'Kondagaon', 170),
    (50018, 518, 'CG_KORBA', N'Korba', 180),
    (50019, 519, 'CG_KORIYA', N'Koriya', 190),
    (50020, 520, 'CG_MAHASAMUND', N'Mahasamund', 200),
    (50021, 521, 'CG_MANENDRAGARHCHIRMIRIBHARATPUR', N'Manendragarh-Chirmiri-Bharatpur', 210),
    (50022, 522, 'CG_MOHLAMANPURAMBAGARHCHOWKI', N'Mohla-Manpur-Ambagarh Chowki', 220),
    (50023, 523, 'CG_MUNGELI', N'Mungeli', 230),
    (50024, 524, 'CG_NARAYANPUR', N'Narayanpur', 240),
    (50025, 525, 'CG_RAIGARH', N'Raigarh', 250),
    (50026, 526, 'CG_RAIPUR', N'Raipur', 260),
    (50027, 527, 'CG_RAJNANDGAON', N'Rajnandgaon', 270),
    (50028, 528, 'CG_SAKTI', N'Sakti', 280),
    (50029, 529, 'CG_SARANGARHBILAIGARH', N'Sarangarh-Bilaigarh', 290),
    (50030, 530, 'CG_SUKMA', N'Sukma', 300),
    (50031, 531, 'CG_SURAJPUR', N'Surajpur', 310),
    (50032, 532, 'CG_SURGUJA', N'Surguja', 320),
    (50033, 533, 'CG_KHAIRAGARHCHHUIKHADANGANDAI', N'Khairagarh-Chhuikhadan-Gandai', 330)
) AS src (CityId, DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CityId, DistrictId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.CityId, src.DistrictId, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());
GO

/*--------------------------------------------------------------------------
  Andhra Pradesh (AP) — StateId 1, 26 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_AP int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'AP' AND Is_Deleted = 0);

IF @StateId_AP IS NULL
    THROW 50001, '016_seed_geography_south_west: the state AP is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_AP <> 1
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      1 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_AP nvarchar(400) = N'016_seed_geography_south_west: AP is StateId '
        + CAST(@StateId_AP AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 1.';

    RAISERROR('%s', 16, 1, @wrong_AP);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (101, 'AP_SRIKAKULAM', N'Srikakulam', 10),
    (102, 'AP_VIZIANAGARAM', N'Vizianagaram', 20),
    (103, 'AP_PARVATHIPURAMMANYAM', N'Parvathipuram Manyam', 30),
    (104, 'AP_ALLURISITHARAMARAJU', N'Alluri Sitharama Raju', 40),
    (105, 'AP_VISAKHAPATNAM', N'Visakhapatnam', 50),
    (106, 'AP_ANAKAPALLI', N'Anakapalli', 60),
    (107, 'AP_KAKINADA', N'Kakinada', 70),
    (108, 'AP_EASTGODAVARI', N'East Godavari', 80),
    (109, 'AP_KONASEEMA', N'Konaseema', 90),
    (110, 'AP_WESTGODAVARI', N'West Godavari', 100),
    (111, 'AP_ELURU', N'Eluru', 110),
    (112, 'AP_KRISHNA', N'Krishna', 120),
    (113, 'AP_NTR', N'NTR', 130),
    (114, 'AP_GUNTUR', N'Guntur', 140),
    (115, 'AP_PALNADU', N'Palnadu', 150),
    (116, 'AP_BAPATLA', N'Bapatla', 160),
    (117, 'AP_PRAKASAM', N'Prakasam', 170),
    (118, 'AP_SRIPOTTISRIRAMULUNELLORE', N'Sri Potti Sriramulu Nellore', 180),
    (119, 'AP_KURNOOL', N'Kurnool', 190),
    (120, 'AP_NANDYAL', N'Nandyal', 200),
    (121, 'AP_ANANTAPUR', N'Anantapur', 210),
    (122, 'AP_SRISATHYASAI', N'Sri Sathya Sai', 220),
    (123, 'AP_YSRKADAPA', N'YSR Kadapa', 230),
    (124, 'AP_ANNAMAYYA', N'Annamayya', 240),
    (125, 'AP_CHITTOOR', N'Chittoor', 250),
    (126, 'AP_TIRUPATI', N'Tirupati', 260)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_AP, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (10001, 101, 'AP_SRIKAKULAM', N'Srikakulam', 10),
    (10002, 102, 'AP_VIZIANAGARAM', N'Vizianagaram', 20),
    (10003, 103, 'AP_PARVATHIPURAMMANYAM', N'Parvathipuram Manyam', 30),
    (10004, 104, 'AP_ALLURISITHARAMARAJU', N'Alluri Sitharama Raju', 40),
    (10005, 105, 'AP_VISAKHAPATNAM', N'Visakhapatnam', 50),
    (10006, 106, 'AP_ANAKAPALLI', N'Anakapalli', 60),
    (10007, 107, 'AP_KAKINADA', N'Kakinada', 70),
    (10008, 108, 'AP_EASTGODAVARI', N'East Godavari', 80),
    (10009, 109, 'AP_KONASEEMA_AMALAPURAM', N'Amalapuram', 90),
    (10010, 110, 'AP_WESTGODAVARI', N'West Godavari', 100),
    (10011, 111, 'AP_ELURU', N'Eluru', 110),
    (10012, 112, 'AP_KRISHNA', N'Krishna', 120),
    (10013, 113, 'AP_NTR_VIJAYAWADA', N'Vijayawada', 130),
    (10014, 114, 'AP_GUNTUR', N'Guntur', 140),
    (10015, 115, 'AP_PALNADU', N'Palnadu', 150),
    (10016, 116, 'AP_BAPATLA', N'Bapatla', 160),
    (10017, 117, 'AP_PRAKASAM', N'Prakasam', 170),
    (10018, 118, 'AP_SRIPOTTISRIRAMULUNELLORE_NELLORE', N'Nellore', 180),
    (10019, 119, 'AP_KURNOOL', N'Kurnool', 190),
    (10020, 120, 'AP_NANDYAL', N'Nandyal', 200),
    (10021, 121, 'AP_ANANTAPUR', N'Anantapur', 210),
    (10022, 122, 'AP_SRISATHYASAI', N'Sri Sathya Sai', 220),
    (10023, 123, 'AP_YSRKADAPA', N'YSR Kadapa', 230),
    (10024, 124, 'AP_ANNAMAYYA', N'Annamayya', 240),
    (10025, 125, 'AP_CHITTOOR', N'Chittoor', 250),
    (10026, 126, 'AP_TIRUPATI', N'Tirupati', 260)
) AS src (CityId, DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CityId, DistrictId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.CityId, src.DistrictId, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());
GO

/*--------------------------------------------------------------------------
  Telangana (TS) — StateId 24, 33 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_TS int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'TS' AND Is_Deleted = 0);

IF @StateId_TS IS NULL
    THROW 50001, '016_seed_geography_south_west: the state TS is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_TS <> 24
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      24 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_TS nvarchar(400) = N'016_seed_geography_south_west: TS is StateId '
        + CAST(@StateId_TS AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 24.';

    RAISERROR('%s', 16, 1, @wrong_TS);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (2401, 'TS_ADILABAD', N'Adilabad', 10),
    (2402, 'TS_BHADRADRIKOTHAGUDEM', N'Bhadradri Kothagudem', 20),
    (2403, 'TS_HANAMKONDA', N'Hanamkonda', 30),
    (2404, 'TS_HYDERABAD', N'Hyderabad', 40),
    (2405, 'TS_JAGTIAL', N'Jagtial', 50),
    (2406, 'TS_JANGAON', N'Jangaon', 60),
    (2407, 'TS_JAYASHANKARBHUPALPALLY', N'Jayashankar Bhupalpally', 70),
    (2408, 'TS_JOGULAMBAGADWAL', N'Jogulamba Gadwal', 80),
    (2409, 'TS_KAMAREDDY', N'Kamareddy', 90),
    (2410, 'TS_KARIMNAGAR', N'Karimnagar', 100),
    (2411, 'TS_KHAMMAM', N'Khammam', 110),
    (2412, 'TS_KOMARAMBHEEMASIFABAD', N'Komaram Bheem Asifabad', 120),
    (2413, 'TS_MAHABUBABAD', N'Mahabubabad', 130),
    (2414, 'TS_MAHABUBNAGAR', N'Mahabubnagar', 140),
    (2415, 'TS_MANCHERIAL', N'Mancherial', 150),
    (2416, 'TS_MEDAK', N'Medak', 160),
    (2417, 'TS_MEDCHALMALKAJGIRI', N'Medchal-Malkajgiri', 170),
    (2418, 'TS_MULUGU', N'Mulugu', 180),
    (2419, 'TS_NAGARKURNOOL', N'Nagarkurnool', 190),
    (2420, 'TS_NALGONDA', N'Nalgonda', 200),
    (2421, 'TS_NARAYANPET', N'Narayanpet', 210),
    (2422, 'TS_NIRMAL', N'Nirmal', 220),
    (2423, 'TS_NIZAMABAD', N'Nizamabad', 230),
    (2424, 'TS_PEDDAPALLI', N'Peddapalli', 240),
    (2425, 'TS_RAJANNASIRCILLA', N'Rajanna Sircilla', 250),
    (2426, 'TS_RANGAREDDY', N'Rangareddy', 260),
    (2427, 'TS_SANGAREDDY', N'Sangareddy', 270),
    (2428, 'TS_SIDDIPET', N'Siddipet', 280),
    (2429, 'TS_SURYAPET', N'Suryapet', 290),
    (2430, 'TS_VIKARABAD', N'Vikarabad', 300),
    (2431, 'TS_WANAPARTHY', N'Wanaparthy', 310),
    (2432, 'TS_WARANGAL', N'Warangal', 320),
    (2433, 'TS_YADADRIBHUVANAGIRI', N'Yadadri Bhuvanagiri', 330)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_TS, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (240001, 2401, 'TS_ADILABAD', N'Adilabad', 10),
    (240002, 2402, 'TS_BHADRADRIKOTHAGUDEM', N'Bhadradri Kothagudem', 20),
    (240003, 2403, 'TS_HANAMKONDA', N'Hanamkonda', 30),
    (240004, 2404, 'TS_HYDERABAD', N'Hyderabad', 40),
    (240005, 2405, 'TS_JAGTIAL', N'Jagtial', 50),
    (240006, 2406, 'TS_JANGAON', N'Jangaon', 60),
    (240007, 2407, 'TS_JAYASHANKARBHUPALPALLY', N'Jayashankar Bhupalpally', 70),
    (240008, 2408, 'TS_JOGULAMBAGADWAL', N'Jogulamba Gadwal', 80),
    (240009, 2409, 'TS_KAMAREDDY', N'Kamareddy', 90),
    (240010, 2410, 'TS_KARIMNAGAR', N'Karimnagar', 100),
    (240011, 2411, 'TS_KHAMMAM', N'Khammam', 110),
    (240012, 2412, 'TS_KOMARAMBHEEMASIFABAD', N'Komaram Bheem Asifabad', 120),
    (240013, 2413, 'TS_MAHABUBABAD', N'Mahabubabad', 130),
    (240014, 2414, 'TS_MAHABUBNAGAR', N'Mahabubnagar', 140),
    (240015, 2415, 'TS_MANCHERIAL', N'Mancherial', 150),
    (240016, 2416, 'TS_MEDAK', N'Medak', 160),
    (240017, 2417, 'TS_MEDCHALMALKAJGIRI', N'Medchal-Malkajgiri', 170),
    (240018, 2418, 'TS_MULUGU', N'Mulugu', 180),
    (240019, 2419, 'TS_NAGARKURNOOL', N'Nagarkurnool', 190),
    (240020, 2420, 'TS_NALGONDA', N'Nalgonda', 200),
    (240021, 2421, 'TS_NARAYANPET', N'Narayanpet', 210),
    (240022, 2422, 'TS_NIRMAL', N'Nirmal', 220),
    (240023, 2423, 'TS_NIZAMABAD', N'Nizamabad', 230),
    (240024, 2424, 'TS_PEDDAPALLI', N'Peddapalli', 240),
    (240025, 2425, 'TS_RAJANNASIRCILLA', N'Rajanna Sircilla', 250),
    (240026, 2426, 'TS_RANGAREDDY', N'Rangareddy', 260),
    (240027, 2427, 'TS_SANGAREDDY', N'Sangareddy', 270),
    (240028, 2428, 'TS_SIDDIPET', N'Siddipet', 280),
    (240029, 2429, 'TS_SURYAPET', N'Suryapet', 290),
    (240030, 2430, 'TS_VIKARABAD', N'Vikarabad', 300),
    (240031, 2431, 'TS_WANAPARTHY', N'Wanaparthy', 310),
    (240032, 2432, 'TS_WARANGAL', N'Warangal', 320),
    (240033, 2433, 'TS_YADADRIBHUVANAGIRI', N'Yadadri Bhuvanagiri', 330)
) AS src (CityId, DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CityId, DistrictId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.CityId, src.DistrictId, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());
GO

/*--------------------------------------------------------------------------
  Karnataka (KA) — StateId 11, 31 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_KA int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'KA' AND Is_Deleted = 0);

IF @StateId_KA IS NULL
    THROW 50001, '016_seed_geography_south_west: the state KA is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_KA <> 11
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      11 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_KA nvarchar(400) = N'016_seed_geography_south_west: KA is StateId '
        + CAST(@StateId_KA AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 11.';

    RAISERROR('%s', 16, 1, @wrong_KA);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (1101, 'KA_BAGALKOT', N'Bagalkot', 10),
    (1102, 'KA_BALLARI', N'Ballari', 20),
    (1103, 'KA_BELAGAVI', N'Belagavi', 30),
    (1104, 'KA_BENGALURURURAL', N'Bengaluru Rural', 40),
    (1105, 'KA_BENGALURUURBAN', N'Bengaluru Urban', 50),
    (1106, 'KA_BIDAR', N'Bidar', 60),
    (1107, 'KA_CHAMARAJANAGAR', N'Chamarajanagar', 70),
    (1108, 'KA_CHIKKABALLAPUR', N'Chikkaballapur', 80),
    (1109, 'KA_CHIKKAMAGALURU', N'Chikkamagaluru', 90),
    (1110, 'KA_CHITRADURGA', N'Chitradurga', 100),
    (1111, 'KA_DAKSHINAKANNADA', N'Dakshina Kannada', 110),
    (1112, 'KA_DAVANAGERE', N'Davanagere', 120),
    (1113, 'KA_DHARWAD', N'Dharwad', 130),
    (1114, 'KA_GADAG', N'Gadag', 140),
    (1115, 'KA_HASSAN', N'Hassan', 150),
    (1116, 'KA_HAVERI', N'Haveri', 160),
    (1117, 'KA_KALABURAGI', N'Kalaburagi', 170),
    (1118, 'KA_KODAGU', N'Kodagu', 180),
    (1119, 'KA_KOLAR', N'Kolar', 190),
    (1120, 'KA_KOPPAL', N'Koppal', 200),
    (1121, 'KA_MANDYA', N'Mandya', 210),
    (1122, 'KA_MYSURU', N'Mysuru', 220),
    (1123, 'KA_RAICHUR', N'Raichur', 230),
    (1124, 'KA_RAMANAGARA', N'Ramanagara', 240),
    (1125, 'KA_SHIVAMOGGA', N'Shivamogga', 250),
    (1126, 'KA_TUMAKURU', N'Tumakuru', 260),
    (1127, 'KA_UDUPI', N'Udupi', 270),
    (1128, 'KA_UTTARAKANNADA', N'Uttara Kannada', 280),
    (1129, 'KA_VIJAYANAGARA', N'Vijayanagara', 290),
    (1130, 'KA_VIJAYAPURA', N'Vijayapura', 300),
    (1131, 'KA_YADGIR', N'Yadgir', 310)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_KA, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (110001, 1101, 'KA_BAGALKOT', N'Bagalkot', 10),
    (110002, 1102, 'KA_BALLARI', N'Ballari', 20),
    (110003, 1103, 'KA_BELAGAVI', N'Belagavi', 30),
    (110004, 1104, 'KA_BENGALURURURAL', N'Bengaluru Rural', 40),
    (110005, 1105, 'KA_BENGALURUURBAN', N'Bengaluru Urban', 50),
    (110006, 1106, 'KA_BIDAR', N'Bidar', 60),
    (110007, 1107, 'KA_CHAMARAJANAGAR', N'Chamarajanagar', 70),
    (110008, 1108, 'KA_CHIKKABALLAPUR', N'Chikkaballapur', 80),
    (110009, 1109, 'KA_CHIKKAMAGALURU', N'Chikkamagaluru', 90),
    (110010, 1110, 'KA_CHITRADURGA', N'Chitradurga', 100),
    (110011, 1111, 'KA_DAKSHINAKANNADA', N'Dakshina Kannada', 110),
    (110012, 1112, 'KA_DAVANAGERE', N'Davanagere', 120),
    (110013, 1113, 'KA_DHARWAD', N'Dharwad', 130),
    (110014, 1114, 'KA_GADAG', N'Gadag', 140),
    (110015, 1115, 'KA_HASSAN', N'Hassan', 150),
    (110016, 1116, 'KA_HAVERI', N'Haveri', 160),
    (110017, 1117, 'KA_KALABURAGI', N'Kalaburagi', 170),
    (110018, 1118, 'KA_KODAGU', N'Kodagu', 180),
    (110019, 1119, 'KA_KOLAR', N'Kolar', 190),
    (110020, 1120, 'KA_KOPPAL', N'Koppal', 200),
    (110021, 1121, 'KA_MANDYA', N'Mandya', 210),
    (110022, 1122, 'KA_MYSURU', N'Mysuru', 220),
    (110023, 1123, 'KA_RAICHUR', N'Raichur', 230),
    (110024, 1124, 'KA_RAMANAGARA', N'Ramanagara', 240),
    (110025, 1125, 'KA_SHIVAMOGGA', N'Shivamogga', 250),
    (110026, 1126, 'KA_TUMAKURU', N'Tumakuru', 260),
    (110027, 1127, 'KA_UDUPI', N'Udupi', 270),
    (110028, 1128, 'KA_UTTARAKANNADA', N'Uttara Kannada', 280),
    (110029, 1129, 'KA_VIJAYANAGARA', N'Vijayanagara', 290),
    (110030, 1130, 'KA_VIJAYAPURA', N'Vijayapura', 300),
    (110031, 1131, 'KA_YADGIR', N'Yadgir', 310)
) AS src (CityId, DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CityId, DistrictId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.CityId, src.DistrictId, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());
GO

/*--------------------------------------------------------------------------
  Kerala (KL) — StateId 12, 14 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_KL int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'KL' AND Is_Deleted = 0);

IF @StateId_KL IS NULL
    THROW 50001, '016_seed_geography_south_west: the state KL is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_KL <> 12
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      12 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_KL nvarchar(400) = N'016_seed_geography_south_west: KL is StateId '
        + CAST(@StateId_KL AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 12.';

    RAISERROR('%s', 16, 1, @wrong_KL);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (1201, 'KL_ALAPPUZHA', N'Alappuzha', 10),
    (1202, 'KL_ERNAKULAM', N'Ernakulam', 20),
    (1203, 'KL_IDUKKI', N'Idukki', 30),
    (1204, 'KL_KANNUR', N'Kannur', 40),
    (1205, 'KL_KASARAGOD', N'Kasaragod', 50),
    (1206, 'KL_KOLLAM', N'Kollam', 60),
    (1207, 'KL_KOTTAYAM', N'Kottayam', 70),
    (1208, 'KL_KOZHIKODE', N'Kozhikode', 80),
    (1209, 'KL_MALAPPURAM', N'Malappuram', 90),
    (1210, 'KL_PALAKKAD', N'Palakkad', 100),
    (1211, 'KL_PATHANAMTHITTA', N'Pathanamthitta', 110),
    (1212, 'KL_THIRUVANANTHAPURAM', N'Thiruvananthapuram', 120),
    (1213, 'KL_THRISSUR', N'Thrissur', 130),
    (1214, 'KL_WAYANAD', N'Wayanad', 140)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_KL, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (120001, 1201, 'KL_ALAPPUZHA', N'Alappuzha', 10),
    (120002, 1202, 'KL_ERNAKULAM', N'Ernakulam', 20),
    (120003, 1203, 'KL_IDUKKI', N'Idukki', 30),
    (120004, 1204, 'KL_KANNUR', N'Kannur', 40),
    (120005, 1205, 'KL_KASARAGOD', N'Kasaragod', 50),
    (120006, 1206, 'KL_KOLLAM', N'Kollam', 60),
    (120007, 1207, 'KL_KOTTAYAM', N'Kottayam', 70),
    (120008, 1208, 'KL_KOZHIKODE', N'Kozhikode', 80),
    (120009, 1209, 'KL_MALAPPURAM', N'Malappuram', 90),
    (120010, 1210, 'KL_PALAKKAD', N'Palakkad', 100),
    (120011, 1211, 'KL_PATHANAMTHITTA', N'Pathanamthitta', 110),
    (120012, 1212, 'KL_THIRUVANANTHAPURAM', N'Thiruvananthapuram', 120),
    (120013, 1213, 'KL_THRISSUR', N'Thrissur', 130),
    (120014, 1214, 'KL_WAYANAD', N'Wayanad', 140)
) AS src (CityId, DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CityId, DistrictId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.CityId, src.DistrictId, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());
GO

/*--------------------------------------------------------------------------
  Tamil Nadu (TN) — StateId 23, 38 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_TN int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'TN' AND Is_Deleted = 0);

IF @StateId_TN IS NULL
    THROW 50001, '016_seed_geography_south_west: the state TN is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_TN <> 23
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      23 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_TN nvarchar(400) = N'016_seed_geography_south_west: TN is StateId '
        + CAST(@StateId_TN AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 23.';

    RAISERROR('%s', 16, 1, @wrong_TN);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (2301, 'TN_ARIYALUR', N'Ariyalur', 10),
    (2302, 'TN_CHENGALPATTU', N'Chengalpattu', 20),
    (2303, 'TN_CHENNAI', N'Chennai', 30),
    (2304, 'TN_COIMBATORE', N'Coimbatore', 40),
    (2305, 'TN_CUDDALORE', N'Cuddalore', 50),
    (2306, 'TN_DHARMAPURI', N'Dharmapuri', 60),
    (2307, 'TN_DINDIGUL', N'Dindigul', 70),
    (2308, 'TN_ERODE', N'Erode', 80),
    (2309, 'TN_KALLAKURICHI', N'Kallakurichi', 90),
    (2310, 'TN_KANCHIPURAM', N'Kanchipuram', 100),
    (2311, 'TN_KANYAKUMARI', N'Kanyakumari', 110),
    (2312, 'TN_KARUR', N'Karur', 120),
    (2313, 'TN_KRISHNAGIRI', N'Krishnagiri', 130),
    (2314, 'TN_MADURAI', N'Madurai', 140),
    (2315, 'TN_MAYILADUTHURAI', N'Mayiladuthurai', 150),
    (2316, 'TN_NAGAPATTINAM', N'Nagapattinam', 160),
    (2317, 'TN_NAMAKKAL', N'Namakkal', 170),
    (2318, 'TN_NILGIRIS', N'Nilgiris', 180),
    (2319, 'TN_PERAMBALUR', N'Perambalur', 190),
    (2320, 'TN_PUDUKKOTTAI', N'Pudukkottai', 200),
    (2321, 'TN_RAMANATHAPURAM', N'Ramanathapuram', 210),
    (2322, 'TN_RANIPET', N'Ranipet', 220),
    (2323, 'TN_SALEM', N'Salem', 230),
    (2324, 'TN_SIVAGANGA', N'Sivaganga', 240),
    (2325, 'TN_TENKASI', N'Tenkasi', 250),
    (2326, 'TN_THANJAVUR', N'Thanjavur', 260),
    (2327, 'TN_THENI', N'Theni', 270),
    (2328, 'TN_THOOTHUKUDI', N'Thoothukudi', 280),
    (2329, 'TN_TIRUCHIRAPPALLI', N'Tiruchirappalli', 290),
    (2330, 'TN_TIRUNELVELI', N'Tirunelveli', 300),
    (2331, 'TN_TIRUPATHUR', N'Tirupathur', 310),
    (2332, 'TN_TIRUPPUR', N'Tiruppur', 320),
    (2333, 'TN_TIRUVALLUR', N'Tiruvallur', 330),
    (2334, 'TN_TIRUVANNAMALAI', N'Tiruvannamalai', 340),
    (2335, 'TN_TIRUVARUR', N'Tiruvarur', 350),
    (2336, 'TN_VELLORE', N'Vellore', 360),
    (2337, 'TN_VILUPPURAM', N'Viluppuram', 370),
    (2338, 'TN_VIRUDHUNAGAR', N'Virudhunagar', 380)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_TN, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (230001, 2301, 'TN_ARIYALUR', N'Ariyalur', 10),
    (230002, 2302, 'TN_CHENGALPATTU', N'Chengalpattu', 20),
    (230003, 2303, 'TN_CHENNAI', N'Chennai', 30),
    (230004, 2304, 'TN_COIMBATORE', N'Coimbatore', 40),
    (230005, 2305, 'TN_CUDDALORE', N'Cuddalore', 50),
    (230006, 2306, 'TN_DHARMAPURI', N'Dharmapuri', 60),
    (230007, 2307, 'TN_DINDIGUL', N'Dindigul', 70),
    (230008, 2308, 'TN_ERODE', N'Erode', 80),
    (230009, 2309, 'TN_KALLAKURICHI', N'Kallakurichi', 90),
    (230010, 2310, 'TN_KANCHIPURAM', N'Kanchipuram', 100),
    (230011, 2311, 'TN_KANYAKUMARI', N'Kanyakumari', 110),
    (230012, 2312, 'TN_KARUR', N'Karur', 120),
    (230013, 2313, 'TN_KRISHNAGIRI', N'Krishnagiri', 130),
    (230014, 2314, 'TN_MADURAI', N'Madurai', 140),
    (230015, 2315, 'TN_MAYILADUTHURAI', N'Mayiladuthurai', 150),
    (230016, 2316, 'TN_NAGAPATTINAM', N'Nagapattinam', 160),
    (230017, 2317, 'TN_NAMAKKAL', N'Namakkal', 170),
    (230018, 2318, 'TN_NILGIRIS', N'Nilgiris', 180),
    (230019, 2319, 'TN_PERAMBALUR', N'Perambalur', 190),
    (230020, 2320, 'TN_PUDUKKOTTAI', N'Pudukkottai', 200),
    (230021, 2321, 'TN_RAMANATHAPURAM', N'Ramanathapuram', 210),
    (230022, 2322, 'TN_RANIPET', N'Ranipet', 220),
    (230023, 2323, 'TN_SALEM', N'Salem', 230),
    (230024, 2324, 'TN_SIVAGANGA', N'Sivaganga', 240),
    (230025, 2325, 'TN_TENKASI', N'Tenkasi', 250),
    (230026, 2326, 'TN_THANJAVUR', N'Thanjavur', 260),
    (230027, 2327, 'TN_THENI', N'Theni', 270),
    (230028, 2328, 'TN_THOOTHUKUDI', N'Thoothukudi', 280),
    (230029, 2329, 'TN_TIRUCHIRAPPALLI', N'Tiruchirappalli', 290),
    (230030, 2330, 'TN_TIRUNELVELI', N'Tirunelveli', 300),
    (230031, 2331, 'TN_TIRUPATHUR', N'Tirupathur', 310),
    (230032, 2332, 'TN_TIRUPPUR', N'Tiruppur', 320),
    (230033, 2333, 'TN_TIRUVALLUR', N'Tiruvallur', 330),
    (230034, 2334, 'TN_TIRUVANNAMALAI', N'Tiruvannamalai', 340),
    (230035, 2335, 'TN_TIRUVARUR', N'Tiruvarur', 350),
    (230036, 2336, 'TN_VELLORE', N'Vellore', 360),
    (230037, 2337, 'TN_VILUPPURAM', N'Viluppuram', 370),
    (230038, 2338, 'TN_VIRUDHUNAGAR', N'Virudhunagar', 380)
) AS src (CityId, DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CityId, DistrictId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.CityId, src.DistrictId, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());
GO

/*--------------------------------------------------------------------------
  Andaman and Nicobar Islands (AN) — StateId 29, 3 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_AN int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'AN' AND Is_Deleted = 0);

IF @StateId_AN IS NULL
    THROW 50001, '016_seed_geography_south_west: the state AN is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_AN <> 29
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      29 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_AN nvarchar(400) = N'016_seed_geography_south_west: AN is StateId '
        + CAST(@StateId_AN AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 29.';

    RAISERROR('%s', 16, 1, @wrong_AN);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (2901, 'AN_NICOBAR', N'Nicobar', 10),
    (2902, 'AN_NORTHANDMIDDLEANDAMAN', N'North and Middle Andaman', 20),
    (2903, 'AN_SOUTHANDAMAN', N'South Andaman', 30)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_AN, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (290001, 2901, 'AN_NICOBAR', N'Nicobar', 10),
    (290002, 2902, 'AN_NORTHANDMIDDLEANDAMAN', N'North and Middle Andaman', 20),
    (290003, 2903, 'AN_SOUTHANDAMAN', N'South Andaman', 30)
) AS src (CityId, DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CityId, DistrictId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.CityId, src.DistrictId, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());
GO

/*--------------------------------------------------------------------------
  Dadra and Nagar Haveli and Daman and Diu (DH) — StateId 31, 3 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_DH int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'DH' AND Is_Deleted = 0);

IF @StateId_DH IS NULL
    THROW 50001, '016_seed_geography_south_west: the state DH is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_DH <> 31
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      31 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_DH nvarchar(400) = N'016_seed_geography_south_west: DH is StateId '
        + CAST(@StateId_DH AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 31.';

    RAISERROR('%s', 16, 1, @wrong_DH);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (3101, 'DH_DADRAANDNAGARHAVELI', N'Dadra and Nagar Haveli', 10),
    (3102, 'DH_DAMAN', N'Daman', 20),
    (3103, 'DH_DIU', N'Diu', 30)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_DH, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (310001, 3101, 'DH_DADRAANDNAGARHAVELI', N'Dadra and Nagar Haveli', 10),
    (310002, 3102, 'DH_DAMAN', N'Daman', 20),
    (310003, 3103, 'DH_DIU', N'Diu', 30)
) AS src (CityId, DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CityId, DistrictId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.CityId, src.DistrictId, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());
GO

/*--------------------------------------------------------------------------
  Lakshadweep (LD) — StateId 35, 1 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_LD int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'LD' AND Is_Deleted = 0);

IF @StateId_LD IS NULL
    THROW 50001, '016_seed_geography_south_west: the state LD is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_LD <> 35
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      35 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_LD nvarchar(400) = N'016_seed_geography_south_west: LD is StateId '
        + CAST(@StateId_LD AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 35.';

    RAISERROR('%s', 16, 1, @wrong_LD);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (3501, 'LD_LAKSHADWEEP', N'Lakshadweep', 10)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_LD, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (350001, 3501, 'LD_LAKSHADWEEP_KAVARATTI', N'Kavaratti', 10)
) AS src (CityId, DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CityId, DistrictId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.CityId, src.DistrictId, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());
GO

/*--------------------------------------------------------------------------
  Puducherry (PY) — StateId 36, 4 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_PY int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'PY' AND Is_Deleted = 0);

IF @StateId_PY IS NULL
    THROW 50001, '016_seed_geography_south_west: the state PY is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_PY <> 36
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      36 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_PY nvarchar(400) = N'016_seed_geography_south_west: PY is StateId '
        + CAST(@StateId_PY AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 36.';

    RAISERROR('%s', 16, 1, @wrong_PY);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (3601, 'PY_KARAIKAL', N'Karaikal', 10),
    (3602, 'PY_MAHE', N'Mahe', 20),
    (3603, 'PY_PUDUCHERRY', N'Puducherry', 30),
    (3604, 'PY_YANAM', N'Yanam', 40)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_PY, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (360001, 3601, 'PY_KARAIKAL', N'Karaikal', 10),
    (360002, 3602, 'PY_MAHE', N'Mahe', 20),
    (360003, 3603, 'PY_PUDUCHERRY', N'Puducherry', 30),
    (360004, 3604, 'PY_YANAM', N'Yanam', 40)
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
DECLARE @d_GJ int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'GJ' AND d.Is_Deleted = 0);
IF @d_GJ <> 33
BEGIN
    DECLARE @m_GJ nvarchar(400) = N'016_seed_geography_south_west: Gujarat has ' + CAST(@d_GJ AS nvarchar(10))
        + N' districts, expected 33. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_GJ);
END

DECLARE @d_MH int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'MH' AND d.Is_Deleted = 0);
IF @d_MH <> 36
BEGIN
    DECLARE @m_MH nvarchar(400) = N'016_seed_geography_south_west: Maharashtra has ' + CAST(@d_MH AS nvarchar(10))
        + N' districts, expected 36. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_MH);
END

DECLARE @d_GA int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'GA' AND d.Is_Deleted = 0);
IF @d_GA <> 2
BEGIN
    DECLARE @m_GA nvarchar(400) = N'016_seed_geography_south_west: Goa has ' + CAST(@d_GA AS nvarchar(10))
        + N' districts, expected 2. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_GA);
END

DECLARE @d_MP int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'MP' AND d.Is_Deleted = 0);
IF @d_MP <> 55
BEGIN
    DECLARE @m_MP nvarchar(400) = N'016_seed_geography_south_west: Madhya Pradesh has ' + CAST(@d_MP AS nvarchar(10))
        + N' districts, expected 55. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_MP);
END

DECLARE @d_CG int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'CG' AND d.Is_Deleted = 0);
IF @d_CG <> 33
BEGIN
    DECLARE @m_CG nvarchar(400) = N'016_seed_geography_south_west: Chhattisgarh has ' + CAST(@d_CG AS nvarchar(10))
        + N' districts, expected 33. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_CG);
END

DECLARE @d_AP int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'AP' AND d.Is_Deleted = 0);
IF @d_AP <> 26
BEGIN
    DECLARE @m_AP nvarchar(400) = N'016_seed_geography_south_west: Andhra Pradesh has ' + CAST(@d_AP AS nvarchar(10))
        + N' districts, expected 26. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_AP);
END

DECLARE @d_TS int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'TS' AND d.Is_Deleted = 0);
IF @d_TS <> 33
BEGIN
    DECLARE @m_TS nvarchar(400) = N'016_seed_geography_south_west: Telangana has ' + CAST(@d_TS AS nvarchar(10))
        + N' districts, expected 33. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_TS);
END

DECLARE @d_KA int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'KA' AND d.Is_Deleted = 0);
IF @d_KA <> 31
BEGIN
    DECLARE @m_KA nvarchar(400) = N'016_seed_geography_south_west: Karnataka has ' + CAST(@d_KA AS nvarchar(10))
        + N' districts, expected 31. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_KA);
END

DECLARE @d_KL int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'KL' AND d.Is_Deleted = 0);
IF @d_KL <> 14
BEGIN
    DECLARE @m_KL nvarchar(400) = N'016_seed_geography_south_west: Kerala has ' + CAST(@d_KL AS nvarchar(10))
        + N' districts, expected 14. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_KL);
END

DECLARE @d_TN int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'TN' AND d.Is_Deleted = 0);
IF @d_TN <> 38
BEGIN
    DECLARE @m_TN nvarchar(400) = N'016_seed_geography_south_west: Tamil Nadu has ' + CAST(@d_TN AS nvarchar(10))
        + N' districts, expected 38. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_TN);
END

DECLARE @d_AN int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'AN' AND d.Is_Deleted = 0);
IF @d_AN <> 3
BEGIN
    DECLARE @m_AN nvarchar(400) = N'016_seed_geography_south_west: Andaman and Nicobar Islands has ' + CAST(@d_AN AS nvarchar(10))
        + N' districts, expected 3. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_AN);
END

DECLARE @d_DH int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'DH' AND d.Is_Deleted = 0);
IF @d_DH <> 3
BEGIN
    DECLARE @m_DH nvarchar(400) = N'016_seed_geography_south_west: Dadra and Nagar Haveli and Daman and Diu has ' + CAST(@d_DH AS nvarchar(10))
        + N' districts, expected 3. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_DH);
END

DECLARE @d_LD int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'LD' AND d.Is_Deleted = 0);
IF @d_LD <> 1
BEGIN
    DECLARE @m_LD nvarchar(400) = N'016_seed_geography_south_west: Lakshadweep has ' + CAST(@d_LD AS nvarchar(10))
        + N' districts, expected 1. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_LD);
END

DECLARE @d_PY int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'PY' AND d.Is_Deleted = 0);
IF @d_PY <> 4
BEGIN
    DECLARE @m_PY nvarchar(400) = N'016_seed_geography_south_west: Puducherry has ' + CAST(@d_PY AS nvarchar(10))
        + N' districts, expected 4. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_PY);
END

PRINT '    South and West India and the island UTs ready — 312 districts, 312 towns.';
GO
