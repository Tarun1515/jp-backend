/*==============================================================================
  East and North-East India — districts and their headquarters towns.

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
      Assam — units merged and split since 2022
      Nagaland — several districts created since 2021

  ---------------------------------------------------------------------------
  CONTENTS: 12 states/UTs, 244 districts, 244 towns
  (one town per district: its headquarters).

  IDEMPOTENT. Every row is guarded on Code, so re-running changes nothing.
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

PRINT '  Seeding geography — East and North-East India ...';
GO

/*--------------------------------------------------------------------------
  Bihar (BR) — StateId 4, 38 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_BR int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'BR' AND Is_Deleted = 0);

IF @StateId_BR IS NULL
    THROW 50001, '015_seed_geography_east: the state BR is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_BR <> 4
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      4 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_BR nvarchar(400) = N'015_seed_geography_east: BR is StateId '
        + CAST(@StateId_BR AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 4.';

    RAISERROR('%s', 16, 1, @wrong_BR);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (401, 'BR_ARARIA', N'Araria', 10),
    (402, 'BR_ARWAL', N'Arwal', 20),
    (403, 'BR_AURANGABAD', N'Aurangabad', 30),
    (404, 'BR_BANKA', N'Banka', 40),
    (405, 'BR_BEGUSARAI', N'Begusarai', 50),
    (406, 'BR_BHAGALPUR', N'Bhagalpur', 60),
    (407, 'BR_BHOJPUR', N'Bhojpur', 70),
    (408, 'BR_BUXAR', N'Buxar', 80),
    (409, 'BR_DARBHANGA', N'Darbhanga', 90),
    (410, 'BR_EASTCHAMPARAN', N'East Champaran', 100),
    (411, 'BR_GAYA', N'Gaya', 110),
    (412, 'BR_GOPALGANJ', N'Gopalganj', 120),
    (413, 'BR_JAMUI', N'Jamui', 130),
    (414, 'BR_JEHANABAD', N'Jehanabad', 140),
    (415, 'BR_KAIMUR', N'Kaimur', 150),
    (416, 'BR_KATIHAR', N'Katihar', 160),
    (417, 'BR_KHAGARIA', N'Khagaria', 170),
    (418, 'BR_KISHANGANJ', N'Kishanganj', 180),
    (419, 'BR_LAKHISARAI', N'Lakhisarai', 190),
    (420, 'BR_MADHEPURA', N'Madhepura', 200),
    (421, 'BR_MADHUBANI', N'Madhubani', 210),
    (422, 'BR_MUNGER', N'Munger', 220),
    (423, 'BR_MUZAFFARPUR', N'Muzaffarpur', 230),
    (424, 'BR_NALANDA', N'Nalanda', 240),
    (425, 'BR_NAWADA', N'Nawada', 250),
    (426, 'BR_PATNA', N'Patna', 260),
    (427, 'BR_PURNIA', N'Purnia', 270),
    (428, 'BR_ROHTAS', N'Rohtas', 280),
    (429, 'BR_SAHARSA', N'Saharsa', 290),
    (430, 'BR_SAMASTIPUR', N'Samastipur', 300),
    (431, 'BR_SARAN', N'Saran', 310),
    (432, 'BR_SHEIKHPURA', N'Sheikhpura', 320),
    (433, 'BR_SHEOHAR', N'Sheohar', 330),
    (434, 'BR_SITAMARHI', N'Sitamarhi', 340),
    (435, 'BR_SIWAN', N'Siwan', 350),
    (436, 'BR_SUPAUL', N'Supaul', 360),
    (437, 'BR_VAISHALI', N'Vaishali', 370),
    (438, 'BR_WESTCHAMPARAN', N'West Champaran', 380)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_BR, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (40001, 401, 'BR_ARARIA', N'Araria', 10),
    (40002, 402, 'BR_ARWAL', N'Arwal', 20),
    (40003, 403, 'BR_AURANGABAD', N'Aurangabad', 30),
    (40004, 404, 'BR_BANKA', N'Banka', 40),
    (40005, 405, 'BR_BEGUSARAI', N'Begusarai', 50),
    (40006, 406, 'BR_BHAGALPUR', N'Bhagalpur', 60),
    (40007, 407, 'BR_BHOJPUR', N'Bhojpur', 70),
    (40008, 408, 'BR_BUXAR', N'Buxar', 80),
    (40009, 409, 'BR_DARBHANGA', N'Darbhanga', 90),
    (40010, 410, 'BR_EASTCHAMPARAN', N'East Champaran', 100),
    (40011, 411, 'BR_GAYA', N'Gaya', 110),
    (40012, 412, 'BR_GOPALGANJ', N'Gopalganj', 120),
    (40013, 413, 'BR_JAMUI', N'Jamui', 130),
    (40014, 414, 'BR_JEHANABAD', N'Jehanabad', 140),
    (40015, 415, 'BR_KAIMUR', N'Kaimur', 150),
    (40016, 416, 'BR_KATIHAR', N'Katihar', 160),
    (40017, 417, 'BR_KHAGARIA', N'Khagaria', 170),
    (40018, 418, 'BR_KISHANGANJ', N'Kishanganj', 180),
    (40019, 419, 'BR_LAKHISARAI', N'Lakhisarai', 190),
    (40020, 420, 'BR_MADHEPURA', N'Madhepura', 200),
    (40021, 421, 'BR_MADHUBANI', N'Madhubani', 210),
    (40022, 422, 'BR_MUNGER', N'Munger', 220),
    (40023, 423, 'BR_MUZAFFARPUR', N'Muzaffarpur', 230),
    (40024, 424, 'BR_NALANDA', N'Nalanda', 240),
    (40025, 425, 'BR_NAWADA', N'Nawada', 250),
    (40026, 426, 'BR_PATNA', N'Patna', 260),
    (40027, 427, 'BR_PURNIA', N'Purnia', 270),
    (40028, 428, 'BR_ROHTAS', N'Rohtas', 280),
    (40029, 429, 'BR_SAHARSA', N'Saharsa', 290),
    (40030, 430, 'BR_SAMASTIPUR', N'Samastipur', 300),
    (40031, 431, 'BR_SARAN', N'Saran', 310),
    (40032, 432, 'BR_SHEIKHPURA', N'Sheikhpura', 320),
    (40033, 433, 'BR_SHEOHAR', N'Sheohar', 330),
    (40034, 434, 'BR_SITAMARHI', N'Sitamarhi', 340),
    (40035, 435, 'BR_SIWAN', N'Siwan', 350),
    (40036, 436, 'BR_SUPAUL', N'Supaul', 360),
    (40037, 437, 'BR_VAISHALI', N'Vaishali', 370),
    (40038, 438, 'BR_WESTCHAMPARAN', N'West Champaran', 380)
) AS src (CityId, DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CityId, DistrictId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.CityId, src.DistrictId, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());
GO

/*--------------------------------------------------------------------------
  Jharkhand (JH) — StateId 10, 24 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_JH int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'JH' AND Is_Deleted = 0);

IF @StateId_JH IS NULL
    THROW 50001, '015_seed_geography_east: the state JH is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_JH <> 10
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      10 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_JH nvarchar(400) = N'015_seed_geography_east: JH is StateId '
        + CAST(@StateId_JH AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 10.';

    RAISERROR('%s', 16, 1, @wrong_JH);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (1001, 'JH_BOKARO', N'Bokaro', 10),
    (1002, 'JH_CHATRA', N'Chatra', 20),
    (1003, 'JH_DEOGHAR', N'Deoghar', 30),
    (1004, 'JH_DHANBAD', N'Dhanbad', 40),
    (1005, 'JH_DUMKA', N'Dumka', 50),
    (1006, 'JH_EASTSINGHBHUM', N'East Singhbhum', 60),
    (1007, 'JH_GARHWA', N'Garhwa', 70),
    (1008, 'JH_GIRIDIH', N'Giridih', 80),
    (1009, 'JH_GODDA', N'Godda', 90),
    (1010, 'JH_GUMLA', N'Gumla', 100),
    (1011, 'JH_HAZARIBAGH', N'Hazaribagh', 110),
    (1012, 'JH_JAMTARA', N'Jamtara', 120),
    (1013, 'JH_KHUNTI', N'Khunti', 130),
    (1014, 'JH_KODERMA', N'Koderma', 140),
    (1015, 'JH_LATEHAR', N'Latehar', 150),
    (1016, 'JH_LOHARDAGA', N'Lohardaga', 160),
    (1017, 'JH_PAKUR', N'Pakur', 170),
    (1018, 'JH_PALAMU', N'Palamu', 180),
    (1019, 'JH_RAMGARH', N'Ramgarh', 190),
    (1020, 'JH_RANCHI', N'Ranchi', 200),
    (1021, 'JH_SAHEBGANJ', N'Sahebganj', 210),
    (1022, 'JH_SERAIKELAKHARSAWAN', N'Seraikela Kharsawan', 220),
    (1023, 'JH_SIMDEGA', N'Simdega', 230),
    (1024, 'JH_WESTSINGHBHUM', N'West Singhbhum', 240)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_JH, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (100001, 1001, 'JH_BOKARO', N'Bokaro', 10),
    (100002, 1002, 'JH_CHATRA', N'Chatra', 20),
    (100003, 1003, 'JH_DEOGHAR', N'Deoghar', 30),
    (100004, 1004, 'JH_DHANBAD', N'Dhanbad', 40),
    (100005, 1005, 'JH_DUMKA', N'Dumka', 50),
    (100006, 1006, 'JH_EASTSINGHBHUM', N'East Singhbhum', 60),
    (100007, 1007, 'JH_GARHWA', N'Garhwa', 70),
    (100008, 1008, 'JH_GIRIDIH', N'Giridih', 80),
    (100009, 1009, 'JH_GODDA', N'Godda', 90),
    (100010, 1010, 'JH_GUMLA', N'Gumla', 100),
    (100011, 1011, 'JH_HAZARIBAGH', N'Hazaribagh', 110),
    (100012, 1012, 'JH_JAMTARA', N'Jamtara', 120),
    (100013, 1013, 'JH_KHUNTI', N'Khunti', 130),
    (100014, 1014, 'JH_KODERMA', N'Koderma', 140),
    (100015, 1015, 'JH_LATEHAR', N'Latehar', 150),
    (100016, 1016, 'JH_LOHARDAGA', N'Lohardaga', 160),
    (100017, 1017, 'JH_PAKUR', N'Pakur', 170),
    (100018, 1018, 'JH_PALAMU', N'Palamu', 180),
    (100019, 1019, 'JH_RAMGARH', N'Ramgarh', 190),
    (100020, 1020, 'JH_RANCHI', N'Ranchi', 200),
    (100021, 1021, 'JH_SAHEBGANJ', N'Sahebganj', 210),
    (100022, 1022, 'JH_SERAIKELAKHARSAWAN', N'Seraikela Kharsawan', 220),
    (100023, 1023, 'JH_SIMDEGA', N'Simdega', 230),
    (100024, 1024, 'JH_WESTSINGHBHUM', N'West Singhbhum', 240)
) AS src (CityId, DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CityId, DistrictId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.CityId, src.DistrictId, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());
GO

/*--------------------------------------------------------------------------
  Odisha (OD) — StateId 19, 30 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_OD int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'OD' AND Is_Deleted = 0);

IF @StateId_OD IS NULL
    THROW 50001, '015_seed_geography_east: the state OD is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_OD <> 19
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      19 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_OD nvarchar(400) = N'015_seed_geography_east: OD is StateId '
        + CAST(@StateId_OD AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 19.';

    RAISERROR('%s', 16, 1, @wrong_OD);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (1901, 'OD_ANGUL', N'Angul', 10),
    (1902, 'OD_BALANGIR', N'Balangir', 20),
    (1903, 'OD_BALASORE', N'Balasore', 30),
    (1904, 'OD_BARGARH', N'Bargarh', 40),
    (1905, 'OD_BHADRAK', N'Bhadrak', 50),
    (1906, 'OD_BOUDH', N'Boudh', 60),
    (1907, 'OD_CUTTACK', N'Cuttack', 70),
    (1908, 'OD_DEOGARH', N'Deogarh', 80),
    (1909, 'OD_DHENKANAL', N'Dhenkanal', 90),
    (1910, 'OD_GAJAPATI', N'Gajapati', 100),
    (1911, 'OD_GANJAM', N'Ganjam', 110),
    (1912, 'OD_JAGATSINGHPUR', N'Jagatsinghpur', 120),
    (1913, 'OD_JAJPUR', N'Jajpur', 130),
    (1914, 'OD_JHARSUGUDA', N'Jharsuguda', 140),
    (1915, 'OD_KALAHANDI', N'Kalahandi', 150),
    (1916, 'OD_KANDHAMAL', N'Kandhamal', 160),
    (1917, 'OD_KENDRAPARA', N'Kendrapara', 170),
    (1918, 'OD_KENDUJHAR', N'Kendujhar', 180),
    (1919, 'OD_KHORDHA', N'Khordha', 190),
    (1920, 'OD_KORAPUT', N'Koraput', 200),
    (1921, 'OD_MALKANGIRI', N'Malkangiri', 210),
    (1922, 'OD_MAYURBHANJ', N'Mayurbhanj', 220),
    (1923, 'OD_NABARANGPUR', N'Nabarangpur', 230),
    (1924, 'OD_NAYAGARH', N'Nayagarh', 240),
    (1925, 'OD_NUAPADA', N'Nuapada', 250),
    (1926, 'OD_PURI', N'Puri', 260),
    (1927, 'OD_RAYAGADA', N'Rayagada', 270),
    (1928, 'OD_SAMBALPUR', N'Sambalpur', 280),
    (1929, 'OD_SUBARNAPUR', N'Subarnapur', 290),
    (1930, 'OD_SUNDARGARH', N'Sundargarh', 300)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_OD, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (190001, 1901, 'OD_ANGUL', N'Angul', 10),
    (190002, 1902, 'OD_BALANGIR', N'Balangir', 20),
    (190003, 1903, 'OD_BALASORE', N'Balasore', 30),
    (190004, 1904, 'OD_BARGARH', N'Bargarh', 40),
    (190005, 1905, 'OD_BHADRAK', N'Bhadrak', 50),
    (190006, 1906, 'OD_BOUDH', N'Boudh', 60),
    (190007, 1907, 'OD_CUTTACK', N'Cuttack', 70),
    (190008, 1908, 'OD_DEOGARH', N'Deogarh', 80),
    (190009, 1909, 'OD_DHENKANAL', N'Dhenkanal', 90),
    (190010, 1910, 'OD_GAJAPATI', N'Gajapati', 100),
    (190011, 1911, 'OD_GANJAM', N'Ganjam', 110),
    (190012, 1912, 'OD_JAGATSINGHPUR', N'Jagatsinghpur', 120),
    (190013, 1913, 'OD_JAJPUR', N'Jajpur', 130),
    (190014, 1914, 'OD_JHARSUGUDA', N'Jharsuguda', 140),
    (190015, 1915, 'OD_KALAHANDI', N'Kalahandi', 150),
    (190016, 1916, 'OD_KANDHAMAL', N'Kandhamal', 160),
    (190017, 1917, 'OD_KENDRAPARA', N'Kendrapara', 170),
    (190018, 1918, 'OD_KENDUJHAR', N'Kendujhar', 180),
    (190019, 1919, 'OD_KHORDHA', N'Khordha', 190),
    (190020, 1920, 'OD_KORAPUT', N'Koraput', 200),
    (190021, 1921, 'OD_MALKANGIRI', N'Malkangiri', 210),
    (190022, 1922, 'OD_MAYURBHANJ', N'Mayurbhanj', 220),
    (190023, 1923, 'OD_NABARANGPUR', N'Nabarangpur', 230),
    (190024, 1924, 'OD_NAYAGARH', N'Nayagarh', 240),
    (190025, 1925, 'OD_NUAPADA', N'Nuapada', 250),
    (190026, 1926, 'OD_PURI', N'Puri', 260),
    (190027, 1927, 'OD_RAYAGADA', N'Rayagada', 270),
    (190028, 1928, 'OD_SAMBALPUR', N'Sambalpur', 280),
    (190029, 1929, 'OD_SUBARNAPUR', N'Subarnapur', 290),
    (190030, 1930, 'OD_SUNDARGARH', N'Sundargarh', 300)
) AS src (CityId, DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CityId, DistrictId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.CityId, src.DistrictId, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());
GO

/*--------------------------------------------------------------------------
  West Bengal (WB) — StateId 28, 23 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_WB int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'WB' AND Is_Deleted = 0);

IF @StateId_WB IS NULL
    THROW 50001, '015_seed_geography_east: the state WB is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_WB <> 28
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      28 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_WB nvarchar(400) = N'015_seed_geography_east: WB is StateId '
        + CAST(@StateId_WB AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 28.';

    RAISERROR('%s', 16, 1, @wrong_WB);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (2801, 'WB_ALIPURDUAR', N'Alipurduar', 10),
    (2802, 'WB_BANKURA', N'Bankura', 20),
    (2803, 'WB_BIRBHUM', N'Birbhum', 30),
    (2804, 'WB_COOCHBEHAR', N'Cooch Behar', 40),
    (2805, 'WB_DAKSHINDINAJPUR', N'Dakshin Dinajpur', 50),
    (2806, 'WB_DARJEELING', N'Darjeeling', 60),
    (2807, 'WB_HOOGHLY', N'Hooghly', 70),
    (2808, 'WB_HOWRAH', N'Howrah', 80),
    (2809, 'WB_JALPAIGURI', N'Jalpaiguri', 90),
    (2810, 'WB_JHARGRAM', N'Jhargram', 100),
    (2811, 'WB_KALIMPONG', N'Kalimpong', 110),
    (2812, 'WB_KOLKATA', N'Kolkata', 120),
    (2813, 'WB_MALDA', N'Malda', 130),
    (2814, 'WB_MURSHIDABAD', N'Murshidabad', 140),
    (2815, 'WB_NADIA', N'Nadia', 150),
    (2816, 'WB_NORTH24PARGANAS', N'North 24 Parganas', 160),
    (2817, 'WB_PASCHIMBARDHAMAN', N'Paschim Bardhaman', 170),
    (2818, 'WB_PASCHIMMEDINIPUR', N'Paschim Medinipur', 180),
    (2819, 'WB_PURBABARDHAMAN', N'Purba Bardhaman', 190),
    (2820, 'WB_PURBAMEDINIPUR', N'Purba Medinipur', 200),
    (2821, 'WB_PURULIA', N'Purulia', 210),
    (2822, 'WB_SOUTH24PARGANAS', N'South 24 Parganas', 220),
    (2823, 'WB_UTTARDINAJPUR', N'Uttar Dinajpur', 230)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_WB, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (280001, 2801, 'WB_ALIPURDUAR', N'Alipurduar', 10),
    (280002, 2802, 'WB_BANKURA', N'Bankura', 20),
    (280003, 2803, 'WB_BIRBHUM', N'Birbhum', 30),
    (280004, 2804, 'WB_COOCHBEHAR', N'Cooch Behar', 40),
    (280005, 2805, 'WB_DAKSHINDINAJPUR', N'Dakshin Dinajpur', 50),
    (280006, 2806, 'WB_DARJEELING', N'Darjeeling', 60),
    (280007, 2807, 'WB_HOOGHLY', N'Hooghly', 70),
    (280008, 2808, 'WB_HOWRAH', N'Howrah', 80),
    (280009, 2809, 'WB_JALPAIGURI', N'Jalpaiguri', 90),
    (280010, 2810, 'WB_JHARGRAM', N'Jhargram', 100),
    (280011, 2811, 'WB_KALIMPONG', N'Kalimpong', 110),
    (280012, 2812, 'WB_KOLKATA', N'Kolkata', 120),
    (280013, 2813, 'WB_MALDA', N'Malda', 130),
    (280014, 2814, 'WB_MURSHIDABAD', N'Murshidabad', 140),
    (280015, 2815, 'WB_NADIA', N'Nadia', 150),
    (280016, 2816, 'WB_NORTH24PARGANAS', N'North 24 Parganas', 160),
    (280017, 2817, 'WB_PASCHIMBARDHAMAN', N'Paschim Bardhaman', 170),
    (280018, 2818, 'WB_PASCHIMMEDINIPUR', N'Paschim Medinipur', 180),
    (280019, 2819, 'WB_PURBABARDHAMAN', N'Purba Bardhaman', 190),
    (280020, 2820, 'WB_PURBAMEDINIPUR', N'Purba Medinipur', 200),
    (280021, 2821, 'WB_PURULIA', N'Purulia', 210),
    (280022, 2822, 'WB_SOUTH24PARGANAS', N'South 24 Parganas', 220),
    (280023, 2823, 'WB_UTTARDINAJPUR', N'Uttar Dinajpur', 230)
) AS src (CityId, DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CityId, DistrictId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.CityId, src.DistrictId, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());
GO

/*--------------------------------------------------------------------------
  Assam (AS) — StateId 3, 35 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_AS int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'AS' AND Is_Deleted = 0);

IF @StateId_AS IS NULL
    THROW 50001, '015_seed_geography_east: the state AS is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_AS <> 3
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      3 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_AS nvarchar(400) = N'015_seed_geography_east: AS is StateId '
        + CAST(@StateId_AS AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 3.';

    RAISERROR('%s', 16, 1, @wrong_AS);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (301, 'AS_BAKSA', N'Baksa', 10),
    (302, 'AS_BARPETA', N'Barpeta', 20),
    (303, 'AS_BISWANATH', N'Biswanath', 30),
    (304, 'AS_BONGAIGAON', N'Bongaigaon', 40),
    (305, 'AS_CACHAR', N'Cachar', 50),
    (306, 'AS_CHARAIDEO', N'Charaideo', 60),
    (307, 'AS_CHIRANG', N'Chirang', 70),
    (308, 'AS_DARRANG', N'Darrang', 80),
    (309, 'AS_DHEMAJI', N'Dhemaji', 90),
    (310, 'AS_DHUBRI', N'Dhubri', 100),
    (311, 'AS_DIBRUGARH', N'Dibrugarh', 110),
    (312, 'AS_DIMAHASAO', N'Dima Hasao', 120),
    (313, 'AS_GOALPARA', N'Goalpara', 130),
    (314, 'AS_GOLAGHAT', N'Golaghat', 140),
    (315, 'AS_HAILAKANDI', N'Hailakandi', 150),
    (316, 'AS_HOJAI', N'Hojai', 160),
    (317, 'AS_JORHAT', N'Jorhat', 170),
    (318, 'AS_KAMRUP', N'Kamrup', 180),
    (319, 'AS_KAMRUPMETROPOLITAN', N'Kamrup Metropolitan', 190),
    (320, 'AS_KARBIANGLONG', N'Karbi Anglong', 200),
    (321, 'AS_KARIMGANJ', N'Karimganj', 210),
    (322, 'AS_KOKRAJHAR', N'Kokrajhar', 220),
    (323, 'AS_LAKHIMPUR', N'Lakhimpur', 230),
    (324, 'AS_MAJULI', N'Majuli', 240),
    (325, 'AS_MORIGAON', N'Morigaon', 250),
    (326, 'AS_NAGAON', N'Nagaon', 260),
    (327, 'AS_NALBARI', N'Nalbari', 270),
    (328, 'AS_SIVASAGAR', N'Sivasagar', 280),
    (329, 'AS_SONITPUR', N'Sonitpur', 290),
    (330, 'AS_SOUTHSALMARAMANKACHAR', N'South Salmara-Mankachar', 300),
    (331, 'AS_TINSUKIA', N'Tinsukia', 310),
    (332, 'AS_UDALGURI', N'Udalguri', 320),
    (333, 'AS_WESTKARBIANGLONG', N'West Karbi Anglong', 330),
    (334, 'AS_BAJALI', N'Bajali', 340),
    (335, 'AS_TAMULPUR', N'Tamulpur', 350)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_AS, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (30001, 301, 'AS_BAKSA', N'Baksa', 10),
    (30002, 302, 'AS_BARPETA', N'Barpeta', 20),
    (30003, 303, 'AS_BISWANATH', N'Biswanath', 30),
    (30004, 304, 'AS_BONGAIGAON', N'Bongaigaon', 40),
    (30005, 305, 'AS_CACHAR', N'Cachar', 50),
    (30006, 306, 'AS_CHARAIDEO', N'Charaideo', 60),
    (30007, 307, 'AS_CHIRANG', N'Chirang', 70),
    (30008, 308, 'AS_DARRANG', N'Darrang', 80),
    (30009, 309, 'AS_DHEMAJI', N'Dhemaji', 90),
    (30010, 310, 'AS_DHUBRI', N'Dhubri', 100),
    (30011, 311, 'AS_DIBRUGARH', N'Dibrugarh', 110),
    (30012, 312, 'AS_DIMAHASAO', N'Dima Hasao', 120),
    (30013, 313, 'AS_GOALPARA', N'Goalpara', 130),
    (30014, 314, 'AS_GOLAGHAT', N'Golaghat', 140),
    (30015, 315, 'AS_HAILAKANDI', N'Hailakandi', 150),
    (30016, 316, 'AS_HOJAI', N'Hojai', 160),
    (30017, 317, 'AS_JORHAT', N'Jorhat', 170),
    (30018, 318, 'AS_KAMRUP', N'Kamrup', 180),
    (30019, 319, 'AS_KAMRUPMETROPOLITAN', N'Kamrup Metropolitan', 190),
    (30020, 320, 'AS_KARBIANGLONG', N'Karbi Anglong', 200),
    (30021, 321, 'AS_KARIMGANJ', N'Karimganj', 210),
    (30022, 322, 'AS_KOKRAJHAR', N'Kokrajhar', 220),
    (30023, 323, 'AS_LAKHIMPUR', N'Lakhimpur', 230),
    (30024, 324, 'AS_MAJULI', N'Majuli', 240),
    (30025, 325, 'AS_MORIGAON', N'Morigaon', 250),
    (30026, 326, 'AS_NAGAON', N'Nagaon', 260),
    (30027, 327, 'AS_NALBARI', N'Nalbari', 270),
    (30028, 328, 'AS_SIVASAGAR', N'Sivasagar', 280),
    (30029, 329, 'AS_SONITPUR', N'Sonitpur', 290),
    (30030, 330, 'AS_SOUTHSALMARAMANKACHAR', N'South Salmara-Mankachar', 300),
    (30031, 331, 'AS_TINSUKIA', N'Tinsukia', 310),
    (30032, 332, 'AS_UDALGURI', N'Udalguri', 320),
    (30033, 333, 'AS_WESTKARBIANGLONG', N'West Karbi Anglong', 330),
    (30034, 334, 'AS_BAJALI', N'Bajali', 340),
    (30035, 335, 'AS_TAMULPUR', N'Tamulpur', 350)
) AS src (CityId, DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CityId, DistrictId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.CityId, src.DistrictId, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());
GO

/*--------------------------------------------------------------------------
  Arunachal Pradesh (AR) — StateId 2, 25 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_AR int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'AR' AND Is_Deleted = 0);

IF @StateId_AR IS NULL
    THROW 50001, '015_seed_geography_east: the state AR is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_AR <> 2
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      2 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_AR nvarchar(400) = N'015_seed_geography_east: AR is StateId '
        + CAST(@StateId_AR AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 2.';

    RAISERROR('%s', 16, 1, @wrong_AR);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (201, 'AR_TAWANG', N'Tawang', 10),
    (202, 'AR_WESTKAMENG', N'West Kameng', 20),
    (203, 'AR_EASTKAMENG', N'East Kameng', 30),
    (204, 'AR_PAKKEKESSANG', N'Pakke-Kessang', 40),
    (205, 'AR_PAPUMPARE', N'Papum Pare', 50),
    (206, 'AR_KURUNGKUMEY', N'Kurung Kumey', 60),
    (207, 'AR_KRADAADI', N'Kra Daadi', 70),
    (208, 'AR_LOWERSUBANSIRI', N'Lower Subansiri', 80),
    (209, 'AR_UPPERSUBANSIRI', N'Upper Subansiri', 90),
    (210, 'AR_KEYIPANYOR', N'Keyi Panyor', 100),
    (211, 'AR_WESTSIANG', N'West Siang', 110),
    (212, 'AR_SHIYOMI', N'Shi Yomi', 120),
    (213, 'AR_LEPARADA', N'Lepa Rada', 130),
    (214, 'AR_LOWERSIANG', N'Lower Siang', 140),
    (215, 'AR_EASTSIANG', N'East Siang', 150),
    (216, 'AR_SIANG', N'Siang', 160),
    (217, 'AR_UPPERSIANG', N'Upper Siang', 170),
    (218, 'AR_DIBANGVALLEY', N'Dibang Valley', 180),
    (219, 'AR_LOWERDIBANGVALLEY', N'Lower Dibang Valley', 190),
    (220, 'AR_ANJAW', N'Anjaw', 200),
    (221, 'AR_LOHIT', N'Lohit', 210),
    (222, 'AR_NAMSAI', N'Namsai', 220),
    (223, 'AR_CHANGLANG', N'Changlang', 230),
    (224, 'AR_TIRAP', N'Tirap', 240),
    (225, 'AR_LONGDING', N'Longding', 250)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_AR, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (20001, 201, 'AR_TAWANG', N'Tawang', 10),
    (20002, 202, 'AR_WESTKAMENG', N'West Kameng', 20),
    (20003, 203, 'AR_EASTKAMENG', N'East Kameng', 30),
    (20004, 204, 'AR_PAKKEKESSANG', N'Pakke-Kessang', 40),
    (20005, 205, 'AR_PAPUMPARE', N'Papum Pare', 50),
    (20006, 206, 'AR_KURUNGKUMEY', N'Kurung Kumey', 60),
    (20007, 207, 'AR_KRADAADI', N'Kra Daadi', 70),
    (20008, 208, 'AR_LOWERSUBANSIRI', N'Lower Subansiri', 80),
    (20009, 209, 'AR_UPPERSUBANSIRI', N'Upper Subansiri', 90),
    (20010, 210, 'AR_KEYIPANYOR', N'Keyi Panyor', 100),
    (20011, 211, 'AR_WESTSIANG', N'West Siang', 110),
    (20012, 212, 'AR_SHIYOMI', N'Shi Yomi', 120),
    (20013, 213, 'AR_LEPARADA', N'Lepa Rada', 130),
    (20014, 214, 'AR_LOWERSIANG', N'Lower Siang', 140),
    (20015, 215, 'AR_EASTSIANG', N'East Siang', 150),
    (20016, 216, 'AR_SIANG', N'Siang', 160),
    (20017, 217, 'AR_UPPERSIANG', N'Upper Siang', 170),
    (20018, 218, 'AR_DIBANGVALLEY', N'Dibang Valley', 180),
    (20019, 219, 'AR_LOWERDIBANGVALLEY', N'Lower Dibang Valley', 190),
    (20020, 220, 'AR_ANJAW', N'Anjaw', 200),
    (20021, 221, 'AR_LOHIT', N'Lohit', 210),
    (20022, 222, 'AR_NAMSAI', N'Namsai', 220),
    (20023, 223, 'AR_CHANGLANG', N'Changlang', 230),
    (20024, 224, 'AR_TIRAP', N'Tirap', 240),
    (20025, 225, 'AR_LONGDING', N'Longding', 250)
) AS src (CityId, DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CityId, DistrictId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.CityId, src.DistrictId, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());
GO

/*--------------------------------------------------------------------------
  Manipur (MN) — StateId 15, 16 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_MN int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'MN' AND Is_Deleted = 0);

IF @StateId_MN IS NULL
    THROW 50001, '015_seed_geography_east: the state MN is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_MN <> 15
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      15 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_MN nvarchar(400) = N'015_seed_geography_east: MN is StateId '
        + CAST(@StateId_MN AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 15.';

    RAISERROR('%s', 16, 1, @wrong_MN);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (1501, 'MN_BISHNUPUR', N'Bishnupur', 10),
    (1502, 'MN_CHANDEL', N'Chandel', 20),
    (1503, 'MN_CHURACHANDPUR', N'Churachandpur', 30),
    (1504, 'MN_IMPHALEAST', N'Imphal East', 40),
    (1505, 'MN_IMPHALWEST', N'Imphal West', 50),
    (1506, 'MN_JIRIBAM', N'Jiribam', 60),
    (1507, 'MN_KAKCHING', N'Kakching', 70),
    (1508, 'MN_KAMJONG', N'Kamjong', 80),
    (1509, 'MN_KANGPOKPI', N'Kangpokpi', 90),
    (1510, 'MN_NONEY', N'Noney', 100),
    (1511, 'MN_PHERZAWL', N'Pherzawl', 110),
    (1512, 'MN_SENAPATI', N'Senapati', 120),
    (1513, 'MN_TAMENGLONG', N'Tamenglong', 130),
    (1514, 'MN_TENGNOUPAL', N'Tengnoupal', 140),
    (1515, 'MN_THOUBAL', N'Thoubal', 150),
    (1516, 'MN_UKHRUL', N'Ukhrul', 160)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_MN, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (150001, 1501, 'MN_BISHNUPUR', N'Bishnupur', 10),
    (150002, 1502, 'MN_CHANDEL', N'Chandel', 20),
    (150003, 1503, 'MN_CHURACHANDPUR', N'Churachandpur', 30),
    (150004, 1504, 'MN_IMPHALEAST', N'Imphal East', 40),
    (150005, 1505, 'MN_IMPHALWEST', N'Imphal West', 50),
    (150006, 1506, 'MN_JIRIBAM', N'Jiribam', 60),
    (150007, 1507, 'MN_KAKCHING', N'Kakching', 70),
    (150008, 1508, 'MN_KAMJONG', N'Kamjong', 80),
    (150009, 1509, 'MN_KANGPOKPI', N'Kangpokpi', 90),
    (150010, 1510, 'MN_NONEY', N'Noney', 100),
    (150011, 1511, 'MN_PHERZAWL', N'Pherzawl', 110),
    (150012, 1512, 'MN_SENAPATI', N'Senapati', 120),
    (150013, 1513, 'MN_TAMENGLONG', N'Tamenglong', 130),
    (150014, 1514, 'MN_TENGNOUPAL', N'Tengnoupal', 140),
    (150015, 1515, 'MN_THOUBAL', N'Thoubal', 150),
    (150016, 1516, 'MN_UKHRUL', N'Ukhrul', 160)
) AS src (CityId, DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CityId, DistrictId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.CityId, src.DistrictId, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());
GO

/*--------------------------------------------------------------------------
  Meghalaya (ML) — StateId 16, 12 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_ML int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'ML' AND Is_Deleted = 0);

IF @StateId_ML IS NULL
    THROW 50001, '015_seed_geography_east: the state ML is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_ML <> 16
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      16 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_ML nvarchar(400) = N'015_seed_geography_east: ML is StateId '
        + CAST(@StateId_ML AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 16.';

    RAISERROR('%s', 16, 1, @wrong_ML);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (1601, 'ML_EASTGAROHILLS', N'East Garo Hills', 10),
    (1602, 'ML_EASTJAINTIAHILLS', N'East Jaintia Hills', 20),
    (1603, 'ML_EASTKHASIHILLS', N'East Khasi Hills', 30),
    (1604, 'ML_EASTERNWESTKHASIHILLS', N'Eastern West Khasi Hills', 40),
    (1605, 'ML_NORTHGAROHILLS', N'North Garo Hills', 50),
    (1606, 'ML_RIBHOI', N'Ri Bhoi', 60),
    (1607, 'ML_SOUTHGAROHILLS', N'South Garo Hills', 70),
    (1608, 'ML_SOUTHWESTGAROHILLS', N'South West Garo Hills', 80),
    (1609, 'ML_SOUTHWESTKHASIHILLS', N'South West Khasi Hills', 90),
    (1610, 'ML_WESTGAROHILLS', N'West Garo Hills', 100),
    (1611, 'ML_WESTJAINTIAHILLS', N'West Jaintia Hills', 110),
    (1612, 'ML_WESTKHASIHILLS', N'West Khasi Hills', 120)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_ML, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (160001, 1601, 'ML_EASTGAROHILLS', N'East Garo Hills', 10),
    (160002, 1602, 'ML_EASTJAINTIAHILLS', N'East Jaintia Hills', 20),
    (160003, 1603, 'ML_EASTKHASIHILLS', N'East Khasi Hills', 30),
    (160004, 1604, 'ML_EASTERNWESTKHASIHILLS', N'Eastern West Khasi Hills', 40),
    (160005, 1605, 'ML_NORTHGAROHILLS', N'North Garo Hills', 50),
    (160006, 1606, 'ML_RIBHOI', N'Ri Bhoi', 60),
    (160007, 1607, 'ML_SOUTHGAROHILLS', N'South Garo Hills', 70),
    (160008, 1608, 'ML_SOUTHWESTGAROHILLS', N'South West Garo Hills', 80),
    (160009, 1609, 'ML_SOUTHWESTKHASIHILLS', N'South West Khasi Hills', 90),
    (160010, 1610, 'ML_WESTGAROHILLS', N'West Garo Hills', 100),
    (160011, 1611, 'ML_WESTJAINTIAHILLS', N'West Jaintia Hills', 110),
    (160012, 1612, 'ML_WESTKHASIHILLS', N'West Khasi Hills', 120)
) AS src (CityId, DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CityId, DistrictId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.CityId, src.DistrictId, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());
GO

/*--------------------------------------------------------------------------
  Mizoram (MZ) — StateId 17, 11 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_MZ int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'MZ' AND Is_Deleted = 0);

IF @StateId_MZ IS NULL
    THROW 50001, '015_seed_geography_east: the state MZ is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_MZ <> 17
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      17 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_MZ nvarchar(400) = N'015_seed_geography_east: MZ is StateId '
        + CAST(@StateId_MZ AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 17.';

    RAISERROR('%s', 16, 1, @wrong_MZ);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (1701, 'MZ_AIZAWL', N'Aizawl', 10),
    (1702, 'MZ_CHAMPHAI', N'Champhai', 20),
    (1703, 'MZ_HNAHTHIAL', N'Hnahthial', 30),
    (1704, 'MZ_KHAWZAWL', N'Khawzawl', 40),
    (1705, 'MZ_KOLASIB', N'Kolasib', 50),
    (1706, 'MZ_LAWNGTLAI', N'Lawngtlai', 60),
    (1707, 'MZ_LUNGLEI', N'Lunglei', 70),
    (1708, 'MZ_MAMIT', N'Mamit', 80),
    (1709, 'MZ_SAIHA', N'Saiha', 90),
    (1710, 'MZ_SAITUAL', N'Saitual', 100),
    (1711, 'MZ_SERCHHIP', N'Serchhip', 110)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_MZ, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (170001, 1701, 'MZ_AIZAWL', N'Aizawl', 10),
    (170002, 1702, 'MZ_CHAMPHAI', N'Champhai', 20),
    (170003, 1703, 'MZ_HNAHTHIAL', N'Hnahthial', 30),
    (170004, 1704, 'MZ_KHAWZAWL', N'Khawzawl', 40),
    (170005, 1705, 'MZ_KOLASIB', N'Kolasib', 50),
    (170006, 1706, 'MZ_LAWNGTLAI', N'Lawngtlai', 60),
    (170007, 1707, 'MZ_LUNGLEI', N'Lunglei', 70),
    (170008, 1708, 'MZ_MAMIT', N'Mamit', 80),
    (170009, 1709, 'MZ_SAIHA', N'Saiha', 90),
    (170010, 1710, 'MZ_SAITUAL', N'Saitual', 100),
    (170011, 1711, 'MZ_SERCHHIP', N'Serchhip', 110)
) AS src (CityId, DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CityId, DistrictId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.CityId, src.DistrictId, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());
GO

/*--------------------------------------------------------------------------
  Nagaland (NL) — StateId 18, 16 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_NL int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'NL' AND Is_Deleted = 0);

IF @StateId_NL IS NULL
    THROW 50001, '015_seed_geography_east: the state NL is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_NL <> 18
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      18 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_NL nvarchar(400) = N'015_seed_geography_east: NL is StateId '
        + CAST(@StateId_NL AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 18.';

    RAISERROR('%s', 16, 1, @wrong_NL);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (1801, 'NL_CHUMOUKEDIMA', N'Chumoukedima', 10),
    (1802, 'NL_DIMAPUR', N'Dimapur', 20),
    (1803, 'NL_KIPHIRE', N'Kiphire', 30),
    (1804, 'NL_KOHIMA', N'Kohima', 40),
    (1805, 'NL_LONGLENG', N'Longleng', 50),
    (1806, 'NL_MOKOKCHUNG', N'Mokokchung', 60),
    (1807, 'NL_MON', N'Mon', 70),
    (1808, 'NL_NIULAND', N'Niuland', 80),
    (1809, 'NL_NOKLAK', N'Noklak', 90),
    (1810, 'NL_PEREN', N'Peren', 100),
    (1811, 'NL_PHEK', N'Phek', 110),
    (1812, 'NL_SHAMATOR', N'Shamator', 120),
    (1813, 'NL_TSEMINYU', N'Tseminyu', 130),
    (1814, 'NL_TUENSANG', N'Tuensang', 140),
    (1815, 'NL_WOKHA', N'Wokha', 150),
    (1816, 'NL_ZUNHEBOTO', N'Zunheboto', 160)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_NL, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (180001, 1801, 'NL_CHUMOUKEDIMA', N'Chumoukedima', 10),
    (180002, 1802, 'NL_DIMAPUR', N'Dimapur', 20),
    (180003, 1803, 'NL_KIPHIRE', N'Kiphire', 30),
    (180004, 1804, 'NL_KOHIMA', N'Kohima', 40),
    (180005, 1805, 'NL_LONGLENG', N'Longleng', 50),
    (180006, 1806, 'NL_MOKOKCHUNG', N'Mokokchung', 60),
    (180007, 1807, 'NL_MON', N'Mon', 70),
    (180008, 1808, 'NL_NIULAND', N'Niuland', 80),
    (180009, 1809, 'NL_NOKLAK', N'Noklak', 90),
    (180010, 1810, 'NL_PEREN', N'Peren', 100),
    (180011, 1811, 'NL_PHEK', N'Phek', 110),
    (180012, 1812, 'NL_SHAMATOR', N'Shamator', 120),
    (180013, 1813, 'NL_TSEMINYU', N'Tseminyu', 130),
    (180014, 1814, 'NL_TUENSANG', N'Tuensang', 140),
    (180015, 1815, 'NL_WOKHA', N'Wokha', 150),
    (180016, 1816, 'NL_ZUNHEBOTO', N'Zunheboto', 160)
) AS src (CityId, DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CityId, DistrictId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.CityId, src.DistrictId, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());
GO

/*--------------------------------------------------------------------------
  Sikkim (SK) — StateId 22, 6 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_SK int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'SK' AND Is_Deleted = 0);

IF @StateId_SK IS NULL
    THROW 50001, '015_seed_geography_east: the state SK is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_SK <> 22
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      22 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_SK nvarchar(400) = N'015_seed_geography_east: SK is StateId '
        + CAST(@StateId_SK AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 22.';

    RAISERROR('%s', 16, 1, @wrong_SK);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (2201, 'SK_GANGTOK', N'Gangtok', 10),
    (2202, 'SK_GYALSHING', N'Gyalshing', 20),
    (2203, 'SK_MANGAN', N'Mangan', 30),
    (2204, 'SK_NAMCHI', N'Namchi', 40),
    (2205, 'SK_PAKYONG', N'Pakyong', 50),
    (2206, 'SK_SORENG', N'Soreng', 60)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_SK, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (220001, 2201, 'SK_GANGTOK', N'Gangtok', 10),
    (220002, 2202, 'SK_GYALSHING', N'Gyalshing', 20),
    (220003, 2203, 'SK_MANGAN', N'Mangan', 30),
    (220004, 2204, 'SK_NAMCHI', N'Namchi', 40),
    (220005, 2205, 'SK_PAKYONG', N'Pakyong', 50),
    (220006, 2206, 'SK_SORENG', N'Soreng', 60)
) AS src (CityId, DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (CityId, DistrictId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.CityId, src.DistrictId, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());
GO

/*--------------------------------------------------------------------------
  Tripura (TR) — StateId 25, 8 districts
--------------------------------------------------------------------------*/
DECLARE @StateId_TR int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'TR' AND Is_Deleted = 0);

IF @StateId_TR IS NULL
    THROW 50001, '015_seed_geography_east: the state TR is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId_TR <> 25
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID. If this state is not
      25 on this machine, every id below belongs to another state's range.
      Refusing beats seeding one state into another's numbers.
    */
    DECLARE @wrong_TR nvarchar(400) = N'015_seed_geography_east: TR is StateId '
        + CAST(@StateId_TR AS nvarchar(10)) + N' here, but this file''s ids are namespaced for StateId 25.';

    RAISERROR('%s', 16, 1, @wrong_TR);
END

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (2501, 'TR_DHALAI', N'Dhalai', 10),
    (2502, 'TR_GOMATI', N'Gomati', 20),
    (2503, 'TR_KHOWAI', N'Khowai', 30),
    (2504, 'TR_NORTHTRIPURA', N'North Tripura', 40),
    (2505, 'TR_SEPAHIJALA', N'Sepahijala', 50),
    (2506, 'TR_SOUTHTRIPURA', N'South Tripura', 60),
    (2507, 'TR_UNAKOTI', N'Unakoti', 70),
    (2508, 'TR_WESTTRIPURA', N'West Tripura', 80)
) AS src (DistrictId, Code, Name, DisplayOrder)
    ON tgt.Code = src.Code
WHEN NOT MATCHED BY TARGET THEN
    INSERT (DistrictId, StateId, Code, Name, DisplayOrder, Is_Active, Is_Deleted, CreatedOn)
    VALUES (src.DistrictId, @StateId_TR, src.Code, src.Name, src.DisplayOrder, 1, 0, SYSUTCDATETIME());

MERGE dbo.m_mdm_city AS tgt
USING (VALUES
    (250001, 2501, 'TR_DHALAI', N'Dhalai', 10),
    (250002, 2502, 'TR_GOMATI', N'Gomati', 20),
    (250003, 2503, 'TR_KHOWAI', N'Khowai', 30),
    (250004, 2504, 'TR_NORTHTRIPURA', N'North Tripura', 40),
    (250005, 2505, 'TR_SEPAHIJALA', N'Sepahijala', 50),
    (250006, 2506, 'TR_SOUTHTRIPURA', N'South Tripura', 60),
    (250007, 2507, 'TR_UNAKOTI', N'Unakoti', 70),
    (250008, 2508, 'TR_WESTTRIPURA', N'West Tripura', 80)
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
DECLARE @d_BR int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'BR' AND d.Is_Deleted = 0);
IF @d_BR <> 38
BEGIN
    DECLARE @m_BR nvarchar(400) = N'015_seed_geography_east: Bihar has ' + CAST(@d_BR AS nvarchar(10))
        + N' districts, expected 38. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_BR);
END

DECLARE @d_JH int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'JH' AND d.Is_Deleted = 0);
IF @d_JH <> 24
BEGIN
    DECLARE @m_JH nvarchar(400) = N'015_seed_geography_east: Jharkhand has ' + CAST(@d_JH AS nvarchar(10))
        + N' districts, expected 24. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_JH);
END

DECLARE @d_OD int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'OD' AND d.Is_Deleted = 0);
IF @d_OD <> 30
BEGIN
    DECLARE @m_OD nvarchar(400) = N'015_seed_geography_east: Odisha has ' + CAST(@d_OD AS nvarchar(10))
        + N' districts, expected 30. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_OD);
END

DECLARE @d_WB int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'WB' AND d.Is_Deleted = 0);
IF @d_WB <> 23
BEGIN
    DECLARE @m_WB nvarchar(400) = N'015_seed_geography_east: West Bengal has ' + CAST(@d_WB AS nvarchar(10))
        + N' districts, expected 23. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_WB);
END

DECLARE @d_AS int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'AS' AND d.Is_Deleted = 0);
IF @d_AS <> 35
BEGIN
    DECLARE @m_AS nvarchar(400) = N'015_seed_geography_east: Assam has ' + CAST(@d_AS AS nvarchar(10))
        + N' districts, expected 35. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_AS);
END

DECLARE @d_AR int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'AR' AND d.Is_Deleted = 0);
IF @d_AR <> 25
BEGIN
    DECLARE @m_AR nvarchar(400) = N'015_seed_geography_east: Arunachal Pradesh has ' + CAST(@d_AR AS nvarchar(10))
        + N' districts, expected 25. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_AR);
END

DECLARE @d_MN int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'MN' AND d.Is_Deleted = 0);
IF @d_MN <> 16
BEGIN
    DECLARE @m_MN nvarchar(400) = N'015_seed_geography_east: Manipur has ' + CAST(@d_MN AS nvarchar(10))
        + N' districts, expected 16. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_MN);
END

DECLARE @d_ML int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'ML' AND d.Is_Deleted = 0);
IF @d_ML <> 12
BEGIN
    DECLARE @m_ML nvarchar(400) = N'015_seed_geography_east: Meghalaya has ' + CAST(@d_ML AS nvarchar(10))
        + N' districts, expected 12. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_ML);
END

DECLARE @d_MZ int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'MZ' AND d.Is_Deleted = 0);
IF @d_MZ <> 11
BEGIN
    DECLARE @m_MZ nvarchar(400) = N'015_seed_geography_east: Mizoram has ' + CAST(@d_MZ AS nvarchar(10))
        + N' districts, expected 11. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_MZ);
END

DECLARE @d_NL int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'NL' AND d.Is_Deleted = 0);
IF @d_NL <> 16
BEGIN
    DECLARE @m_NL nvarchar(400) = N'015_seed_geography_east: Nagaland has ' + CAST(@d_NL AS nvarchar(10))
        + N' districts, expected 16. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_NL);
END

DECLARE @d_SK int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'SK' AND d.Is_Deleted = 0);
IF @d_SK <> 6
BEGIN
    DECLARE @m_SK nvarchar(400) = N'015_seed_geography_east: Sikkim has ' + CAST(@d_SK AS nvarchar(10))
        + N' districts, expected 6. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_SK);
END

DECLARE @d_TR int = (SELECT COUNT(*) FROM dbo.m_mdm_district d
    JOIN dbo.m_mdm_state s ON s.StateId = d.StateId
   WHERE s.Code = 'TR' AND d.Is_Deleted = 0);
IF @d_TR <> 8
BEGIN
    DECLARE @m_TR nvarchar(400) = N'015_seed_geography_east: Tripura has ' + CAST(@d_TR AS nvarchar(10))
        + N' districts, expected 8. If the source list genuinely changed, change the number in gen-geography.mjs in the same commit as the data.';
    RAISERROR('%s', 16, 1, @m_TR);
END

PRINT '    East and North-East India ready — 244 districts, 244 towns.';
GO
