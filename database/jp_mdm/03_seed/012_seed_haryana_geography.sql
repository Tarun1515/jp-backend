/*==============================================================================
  jp_mdm — 012_seed_haryana_geography.sql

  SCHOOL REVAMP (SR-1). Haryana: districts, tehsils and the towns under them.

  ---------------------------------------------------------------------------
  🔴 SOURCE, AND THE DATE IT WAS READ
  ---------------------------------------------------------------------------
  Transcribed 2026-10-25 from:

    Districts  — Wikipedia, "List of districts of Haryana"
                 https://en.wikipedia.org/wiki/List_of_districts_of_Haryana
    Tehsils    — Wikipedia, "List of tehsils of Haryana"
                 https://en.wikipedia.org/wiki/List_of_tehsils_of_Haryana
    Rohtak's tehsils — Wikipedia, "Rohtak district", because the tehsil list
                 page omits them

  ⚠️ PROVISIONAL, exactly as 2.47's masters are. This is a named public source
  read on a stated date, not the client's list and not a government gazette.
  The client confirms Haryana before any other state is seeded, and the
  confirmation is a Name edit at worst — Code never changes (2.47).

  ---------------------------------------------------------------------------
  🔴 WHAT THIS SEED CONTAINS, AND WHAT IT DELIBERATELY DOES NOT
  ---------------------------------------------------------------------------
  CONTAINS   23 districts · 94 revenue tehsils · 49 sub-tehsils
             and one city row per tehsil, which is its headquarters town.

  DOES NOT   Haryana's ~6,800 villages.

  ⚠️ AND THAT IS THE SAME ARGUMENT G40 MAKES, NOT A SHORTCUT. G40 refused to
  invent a city list from memory because half a list is worse than none: a
  visitor from a missing town reads an empty page as "no jobs here". Villages
  are not enumerable from any source we can cite today, so they are not a
  dropdown. They are AreaOrVillage free text beside the tehsil, plus the
  coordinates Google Places returns — which is a complete, honest address for a
  village school, and is why ADDRESS_DESIGN.md put that column in before this
  file existed.

  ---------------------------------------------------------------------------
  ⚠️ THREE PLACES THE SOURCE IS MID-TRANSITION, AND WHAT WAS DONE
  ---------------------------------------------------------------------------
  1. HANSI became Haryana's 23rd district on 16 Dec 2025, carved out of Hisar.
     The tehsil page still lists "Hansi" as a tehsil OF Hisar while also
     listing Hansi district with tehsils "Hansi 1" and "Hansi 2". Seeded as
     the district page has it: Hansi is its own district, and the stale Hansi
     row under Hisar is NOT seeded. So Hisar has 5 tehsils here, not 6.

  2. LAKHAN MAJRA is a sub-tehsil of Rohtak on the tehsil page and a
     community-development block under Meham elsewhere. Seeded as a Rohtak
     sub-tehsil, which is the revenue view this table is about.

  3. SUB-TEHSILS ARE SEEDED AS TEHSIL ROWS, flagged IsSubTehsil = 1. A person
     typing their address does not know or care which kind their place is;
     they know its name. Keeping them out would mean a school in Uklana cannot
     find Uklana.

  ---------------------------------------------------------------------------
  CODES (2.47)
  ---------------------------------------------------------------------------
      district  HR_<NAME>            e.g. HR_HISAR
      tehsil    HR_<DISTRICT>_<NAME> e.g. HR_HISAR_NARNAUND
      city      HR_<DISTRICT>_<NAME> e.g. HR_HISAR_NARNAUND  (city table)

  Codes are ASCII, uppercase, punctuation removed. They are generated from the
  names ONCE, here, and are then fixed for ever — a code is an identifier, not
  a slug that may be regenerated.

  ---------------------------------------------------------------------------
  IDEMPOTENT. Every insert is guarded on Code, so re-running changes nothing.
  Names are NOT overwritten on re-run: once live, the Name belongs to the
  client (2.47), and a re-run of this file must not quietly undo their edit.
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

PRINT '  Seeding Haryana geography ...';
GO

DECLARE @StateId int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'HR' AND Is_Deleted = 0);

IF @StateId IS NULL
    THROW 50001, '012_seed_haryana_geography: the state HR is not seeded. 003_seed_geography.sql must run first.', 1;

IF @StateId <> 8
BEGIN
    /*
      🔴 THE ID NAMESPACE IS DERIVED FROM THE STATE ID, so if HR is not 8
      on this machine, every id below belongs to a different state's range.
      Better to refuse than to seed Haryana into Punjab's numbers.
    */
    DECLARE @wrong nvarchar(400) = N'012_seed_haryana_geography: HR is StateId '
        + CAST(@StateId AS nvarchar(10)) + N' here, but the ids in this file are namespaced for StateId 8. '
        + N'Re-generate the file for this machine''s StateId, or fix 003_seed_geography.sql.';

    RAISERROR('%s', 16, 1, @wrong);
END
GO

/*----------------------------------------------------------------- districts */
DECLARE @StateId int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'HR' AND Is_Deleted = 0);

MERGE dbo.m_mdm_district AS tgt
USING (VALUES
    (801, 'HR_AMBALA', N'Ambala', 10),
    (802, 'HR_KURUKSHETRA', N'Kurukshetra', 20),
    (803, 'HR_PANCHKULA', N'Panchkula', 30),
    (804, 'HR_YAMUNANAGAR', N'Yamunanagar', 40),
    (805, 'HR_FARIDABAD', N'Faridabad', 50),
    (806, 'HR_NUH', N'Nuh', 60),
    (807, 'HR_PALWAL', N'Palwal', 70),
    (808, 'HR_GURUGRAM', N'Gurugram', 80),
    (809, 'HR_MAHENDRAGARH', N'Mahendragarh', 90),
    (810, 'HR_REWARI', N'Rewari', 100),
    (811, 'HR_HISAR', N'Hisar', 110),
    (812, 'HR_FATEHABAD', N'Fatehabad', 120),
    (813, 'HR_HANSI', N'Hansi', 130),
    (814, 'HR_JIND', N'Jind', 140),
    (815, 'HR_SIRSA', N'Sirsa', 150),
    (816, 'HR_KARNAL', N'Karnal', 160),
    (817, 'HR_KAITHAL', N'Kaithal', 170),
    (818, 'HR_PANIPAT', N'Panipat', 180),
    (819, 'HR_ROHTAK', N'Rohtak', 190),
    (820, 'HR_BHIWANI', N'Bhiwani', 200),
    (821, 'HR_CHARKHIDADRI', N'Charkhi Dadri', 210),
    (822, 'HR_JHAJJAR', N'Jhajjar', 220),
    (823, 'HR_SONIPAT', N'Sonipat', 230)
) AS src (DistrictId, Code, Name, DisplayOrder)
   ON tgt.DistrictId = src.DistrictId
/*
  ⚠️ NO "WHEN MATCHED THEN UPDATE". Once a row is live its Name belongs to the
  client (2.47) — "State Board" may have become "State Education Board" by
  their decision, and a re-run of this file must not quietly undo that.
*/
WHEN NOT MATCHED BY TARGET
    THEN INSERT (DistrictId, Code, Name, DisplayOrder, StateId)
         VALUES (src.DistrictId, src.Code, src.Name, src.DisplayOrder, @StateId);

DECLARE @dcount int = (SELECT COUNT(*) FROM dbo.m_mdm_district WHERE StateId = @StateId AND Is_Deleted = 0);

PRINT '    districts: ' + CAST(@dcount AS varchar(6));
GO

/*-------------------------------------------------------------------- tehsils */
MERGE dbo.m_mdm_tehsil AS tgt
USING (VALUES
    (80001, 'HR_AMBALA_AMBALA', N'Ambala', 801, 0, 10),
    (80002, 'HR_AMBALA_AMBALACANTT', N'Ambala Cantt', 801, 0, 20),
    (80003, 'HR_AMBALA_BARARA', N'Barara', 801, 0, 30),
    (80004, 'HR_AMBALA_NARAINGARH', N'Naraingarh', 801, 0, 40),
    (80005, 'HR_AMBALA_SAHA', N'Saha', 801, 1, 1010),
    (80006, 'HR_AMBALA_MULLANA', N'Mullana', 801, 1, 1020),
    (80007, 'HR_AMBALA_SHEHZADPUR', N'Shehzadpur', 801, 1, 1030),
    (80008, 'HR_KURUKSHETRA_THANESAR', N'Thanesar', 802, 0, 10),
    (80009, 'HR_KURUKSHETRA_LADWA', N'Ladwa', 802, 0, 20),
    (80010, 'HR_KURUKSHETRA_SHAHABAD', N'Shahabad', 802, 0, 30),
    (80011, 'HR_KURUKSHETRA_PEHOWA', N'Pehowa', 802, 0, 40),
    (80012, 'HR_KURUKSHETRA_BABAIN', N'Babain', 802, 1, 1010),
    (80013, 'HR_KURUKSHETRA_ISMAILABAD', N'Ismailabad', 802, 1, 1020),
    (80014, 'HR_PANCHKULA_PANCHKULA', N'Panchkula', 803, 0, 10),
    (80015, 'HR_PANCHKULA_KALKA', N'Kalka', 803, 0, 20),
    (80016, 'HR_PANCHKULA_RAIPURRANI', N'Raipur Rani', 803, 0, 30),
    (80017, 'HR_PANCHKULA_BARWALA', N'Barwala', 803, 1, 1010),
    (80018, 'HR_PANCHKULA_MORNI', N'Morni', 803, 1, 1020),
    (80019, 'HR_YAMUNANAGAR_JAGADHRI', N'Jagadhri', 804, 0, 10),
    (80020, 'HR_YAMUNANAGAR_RADAUR', N'Radaur', 804, 0, 20),
    (80021, 'HR_YAMUNANAGAR_BILASPUR', N'Bilaspur', 804, 0, 30),
    (80022, 'HR_YAMUNANAGAR_CHHACHHRAULI', N'Chhachhrauli', 804, 0, 40),
    (80023, 'HR_YAMUNANAGAR_SARASWATINAGAR', N'Saraswati Nagar', 804, 1, 1010),
    (80024, 'HR_YAMUNANAGAR_SADHAURA', N'Sadhaura', 804, 1, 1020),
    (80025, 'HR_YAMUNANAGAR_KHIZRABAD', N'Khizrabad', 804, 1, 1030),
    (80026, 'HR_FARIDABAD_FARIDABAD', N'Faridabad', 805, 0, 10),
    (80027, 'HR_FARIDABAD_BALLABGARH', N'Ballabgarh', 805, 0, 20),
    (80028, 'HR_FARIDABAD_BADKHAL', N'Badkhal', 805, 0, 30),
    (80029, 'HR_FARIDABAD_MOHANA', N'Mohana', 805, 1, 1010),
    (80030, 'HR_FARIDABAD_TIGAON', N'Tigaon', 805, 1, 1020),
    (80031, 'HR_FARIDABAD_DHAUJ', N'Dhauj', 805, 1, 1030),
    (80032, 'HR_FARIDABAD_DAYALPUR', N'Dayalpur', 805, 1, 1040),
    (80033, 'HR_FARIDABAD_GAUNCHI', N'Gaunchi', 805, 1, 1050),
    (80034, 'HR_NUH_NUH', N'Nuh', 806, 0, 10),
    (80035, 'HR_NUH_FEROZEPURJHIRKA', N'Ferozepur Jhirka', 806, 0, 20),
    (80036, 'HR_NUH_PUNHANA', N'Punhana', 806, 0, 30),
    (80037, 'HR_NUH_TAURU', N'Tauru', 806, 0, 40),
    (80038, 'HR_NUH_NAGINA', N'Nagina', 806, 1, 1010),
    (80039, 'HR_PALWAL_PALWAL', N'Palwal', 807, 0, 10),
    (80040, 'HR_PALWAL_HATHIN', N'Hathin', 807, 0, 20),
    (80041, 'HR_PALWAL_HODAL', N'Hodal', 807, 0, 30),
    (80042, 'HR_PALWAL_HASANPUR', N'Hasanpur', 807, 1, 1010),
    (80043, 'HR_PALWAL_BAHIN', N'Bahin', 807, 1, 1020),
    (80044, 'HR_GURUGRAM_GURUGRAM', N'Gurugram', 808, 0, 10),
    (80045, 'HR_GURUGRAM_SOHNA', N'Sohna', 808, 0, 20),
    (80046, 'HR_GURUGRAM_PATAUDI', N'Pataudi', 808, 0, 30),
    (80047, 'HR_GURUGRAM_FARRUKHNAGAR', N'Farrukh Nagar', 808, 0, 40),
    (80048, 'HR_GURUGRAM_MANESAR', N'Manesar', 808, 0, 50),
    (80049, 'HR_GURUGRAM_WAZIRABAD', N'Wazirabad', 808, 1, 1010),
    (80050, 'HR_GURUGRAM_BADSHAHPUR', N'Badshahpur', 808, 1, 1020),
    (80051, 'HR_GURUGRAM_KADIPUR', N'Kadipur', 808, 1, 1030),
    (80052, 'HR_GURUGRAM_HARSARU', N'Harsaru', 808, 1, 1040),
    (80053, 'HR_MAHENDRAGARH_MAHENDRAGARH', N'Mahendragarh', 809, 0, 10),
    (80054, 'HR_MAHENDRAGARH_NARNAUL', N'Narnaul', 809, 0, 20),
    (80055, 'HR_MAHENDRAGARH_NANGALCHAUDHARY', N'Nangal Chaudhary', 809, 0, 30),
    (80056, 'HR_MAHENDRAGARH_ATELI', N'Ateli', 809, 0, 40),
    (80057, 'HR_MAHENDRAGARH_KANINA', N'Kanina', 809, 0, 50),
    (80058, 'HR_MAHENDRAGARH_SATNALI', N'Satnali', 809, 1, 1010),
    (80059, 'HR_REWARI_REWARI', N'Rewari', 810, 0, 10),
    (80060, 'HR_REWARI_KOSLI', N'Kosli', 810, 0, 20),
    (80061, 'HR_REWARI_BAWAL', N'Bawal', 810, 0, 30),
    (80062, 'HR_REWARI_DHARUHERA', N'Dharuhera', 810, 1, 1010),
    (80063, 'HR_REWARI_DAHINA', N'Dahina', 810, 1, 1020),
    (80064, 'HR_REWARI_MANETHI', N'Manethi', 810, 1, 1030),
    (80065, 'HR_REWARI_NAHAR', N'Nahar', 810, 1, 1040),
    (80066, 'HR_REWARI_PALHAWAS', N'Palhawas', 810, 1, 1050),
    (80067, 'HR_HISAR_HISAR', N'Hisar', 811, 0, 10),
    (80068, 'HR_HISAR_NARNAUND', N'Narnaund', 811, 0, 20),
    (80069, 'HR_HISAR_BARWALA', N'Barwala', 811, 0, 30),
    (80070, 'HR_HISAR_BASS', N'Bass', 811, 0, 40),
    (80071, 'HR_HISAR_ADAMPUR', N'Adampur', 811, 0, 50),
    (80072, 'HR_HISAR_BALSAMAND', N'Balsamand', 811, 1, 1010),
    (80073, 'HR_HISAR_UKLANA', N'Uklana', 811, 1, 1020),
    (80074, 'HR_HISAR_KHERIJALAB', N'Kheri Jalab', 811, 1, 1030),
    (80075, 'HR_FATEHABAD_FATEHABAD', N'Fatehabad', 812, 0, 10),
    (80076, 'HR_FATEHABAD_TOHANA', N'Tohana', 812, 0, 20),
    (80077, 'HR_FATEHABAD_RATIA', N'Ratia', 812, 0, 30),
    (80078, 'HR_FATEHABAD_BHATTUKALAN', N'Bhattu Kalan', 812, 1, 1010),
    (80079, 'HR_FATEHABAD_BHUNA', N'Bhuna', 812, 1, 1020),
    (80080, 'HR_FATEHABAD_KULLAN', N'Kullan', 812, 1, 1030),
    (80081, 'HR_FATEHABAD_JAKHAL', N'Jakhal', 812, 1, 1040),
    (80082, 'HR_HANSI_HANSI1', N'Hansi 1', 813, 0, 10),
    (80083, 'HR_HANSI_HANSI2', N'Hansi 2', 813, 0, 20),
    (80084, 'HR_JIND_JIND', N'Jind', 814, 0, 10),
    (80085, 'HR_JIND_NARWANA', N'Narwana', 814, 0, 20),
    (80086, 'HR_JIND_SAFIDON', N'Safidon', 814, 0, 30),
    (80087, 'HR_JIND_JULANA', N'Julana', 814, 0, 40),
    (80088, 'HR_JIND_UCHANA', N'Uchana', 814, 0, 50),
    (80089, 'HR_JIND_ALEWA', N'Alewa', 814, 0, 60),
    (80090, 'HR_JIND_PILLUKHERA', N'Pillu Khera', 814, 1, 1010),
    (80091, 'HR_SIRSA_SIRSA', N'Sirsa', 815, 0, 10),
    (80092, 'HR_SIRSA_RANIA', N'Rania', 815, 0, 20),
    (80093, 'HR_SIRSA_DABWALI', N'Dabwali', 815, 0, 30),
    (80094, 'HR_SIRSA_ELLENABAD', N'Ellenabad', 815, 0, 40),
    (80095, 'HR_SIRSA_NATHUSARICHOPTA', N'Nathusari Chopta', 815, 0, 50),
    (80096, 'HR_SIRSA_KALANWALI', N'Kalanwali', 815, 0, 60),
    (80097, 'HR_SIRSA_GORIWALA', N'Goriwala', 815, 1, 1010),
    (80098, 'HR_KARNAL_KARNAL', N'Karnal', 816, 0, 10),
    (80099, 'HR_KARNAL_ASSANDH', N'Assandh', 816, 0, 20),
    (80100, 'HR_KARNAL_GHARAUNDA', N'Gharaunda', 816, 0, 30),
    (80101, 'HR_KARNAL_INDRI', N'Indri', 816, 0, 40),
    (80102, 'HR_KARNAL_NILOKHERI', N'Nilokheri', 816, 0, 50),
    (80103, 'HR_KARNAL_NISSING', N'Nissing', 816, 1, 1010),
    (80104, 'HR_KARNAL_KAIMLA', N'Kaimla', 816, 1, 1020),
    (80105, 'HR_KARNAL_NIGDHU', N'Nigdhu', 816, 1, 1030),
    (80106, 'HR_KAITHAL_KAITHAL', N'Kaithal', 817, 0, 10),
    (80107, 'HR_KAITHAL_GUHLA', N'Guhla', 817, 0, 20),
    (80108, 'HR_KAITHAL_FATEHPURPUNDRI', N'Fatehpur Pundri', 817, 0, 30),
    (80109, 'HR_KAITHAL_KALAYAT', N'Kalayat', 817, 0, 40),
    (80110, 'HR_KAITHAL_SIWAN', N'Siwan', 817, 1, 1010),
    (80111, 'HR_KAITHAL_RAJOUND', N'Rajound', 817, 1, 1020),
    (80112, 'HR_KAITHAL_DHAND', N'Dhand', 817, 1, 1030),
    (80113, 'HR_PANIPAT_PANIPAT', N'Panipat', 818, 0, 10),
    (80114, 'HR_PANIPAT_SAMALKHA', N'Samalkha', 818, 0, 20),
    (80115, 'HR_PANIPAT_ISRANA', N'Israna', 818, 0, 30),
    (80116, 'HR_PANIPAT_BAPOULI', N'Bapouli', 818, 0, 40),
    (80117, 'HR_PANIPAT_MADLAUDA', N'Madlauda', 818, 0, 50),
    (80118, 'HR_ROHTAK_ROHTAK', N'Rohtak', 819, 0, 10),
    (80119, 'HR_ROHTAK_MEHAM', N'Meham', 819, 0, 20),
    (80120, 'HR_ROHTAK_KALANAUR', N'Kalanaur', 819, 0, 30),
    (80121, 'HR_ROHTAK_SAMPLA', N'Sampla', 819, 0, 40),
    (80122, 'HR_ROHTAK_LAKHANMAJRA', N'Lakhan Majra', 819, 1, 1010),
    (80123, 'HR_BHIWANI_BHIWANI', N'Bhiwani', 820, 0, 10),
    (80124, 'HR_BHIWANI_BAWANIKHERA', N'Bawani Khera', 820, 0, 20),
    (80125, 'HR_BHIWANI_LOHARU', N'Loharu', 820, 0, 30),
    (80126, 'HR_BHIWANI_TOSHAM', N'Tosham', 820, 0, 40),
    (80127, 'HR_BHIWANI_SIWANI', N'Siwani', 820, 0, 50),
    (80128, 'HR_BHIWANI_BEHAL', N'Behal', 820, 1, 1010),
    (80129, 'HR_CHARKHIDADRI_CHARKHIDADRI', N'Charkhi Dadri', 821, 0, 10),
    (80130, 'HR_CHARKHIDADRI_BADHRA', N'Badhra', 821, 0, 20),
    (80131, 'HR_CHARKHIDADRI_BAUNDKALAN', N'Baund Kalan', 821, 1, 1010),
    (80132, 'HR_JHAJJAR_BADLI', N'Badli', 822, 0, 10),
    (80133, 'HR_JHAJJAR_BAHADURGARH', N'Bahadurgarh', 822, 0, 20),
    (80134, 'HR_JHAJJAR_BERI', N'Beri', 822, 0, 30),
    (80135, 'HR_JHAJJAR_JHAJJAR', N'Jhajjar', 822, 0, 40),
    (80136, 'HR_JHAJJAR_MATANHAIL', N'Matanhail', 822, 0, 50),
    (80137, 'HR_JHAJJAR_SALHAWAS', N'Salhawas', 822, 1, 1010),
    (80138, 'HR_SONIPAT_SONIPAT', N'Sonipat', 823, 0, 10),
    (80139, 'HR_SONIPAT_GOHANA', N'Gohana', 823, 0, 20),
    (80140, 'HR_SONIPAT_GANAUR', N'Ganaur', 823, 0, 30),
    (80141, 'HR_SONIPAT_KHARKHODA', N'Kharkhoda', 823, 0, 40),
    (80142, 'HR_SONIPAT_KHANPURKALAN', N'Khanpur Kalan', 823, 1, 1010),
    (80143, 'HR_SONIPAT_RAI', N'Rai', 823, 1, 1020)
) AS src (TehsilId, Code, Name, DistrictId, IsSubTehsil, DisplayOrder)
   ON tgt.TehsilId = src.TehsilId
WHEN NOT MATCHED BY TARGET
    THEN INSERT (TehsilId, Code, Name, DistrictId, IsSubTehsil, DisplayOrder)
         VALUES (src.TehsilId, src.Code, src.Name, src.DistrictId, src.IsSubTehsil, src.DisplayOrder);

DECLARE @StateId2 int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'HR' AND Is_Deleted = 0);

DECLARE @tehsils int = (SELECT COUNT(*) FROM dbo.m_mdm_tehsil th
                          JOIN dbo.m_mdm_district d ON d.DistrictId = th.DistrictId
                         WHERE d.StateId = @StateId2 AND th.Is_Deleted = 0);

DECLARE @subs int = (SELECT COUNT(*) FROM dbo.m_mdm_tehsil th
                       JOIN dbo.m_mdm_district d ON d.DistrictId = th.DistrictId
                      WHERE d.StateId = @StateId2 AND th.Is_Deleted = 0 AND th.IsSubTehsil = 1);

PRINT '    tehsils: ' + CAST(@tehsils AS varchar(6)) + ' (of which sub-tehsils: ' + CAST(@subs AS varchar(6)) + ')';
GO

/*--------------------------------------------------------------------- cities */
/*
  🔴 ONE CITY PER TEHSIL — ITS HEADQUARTERS TOWN, AND THE RULE IS EXACTLY THAT.

  A tehsil is named after the town it is administered from, so every tehsil
  name is also a town that exists. That gives a complete, defensible town list
  at the administrative level, from the same cited source, with nothing
  invented.

  ⚠️ IT DOES NOT PRETEND TO BE EVERY TOWN IN HARYANA. A census town with no
  tehsil of its own is not here, and a village certainly is not. What the
  product promises is: every district and every tehsil headquarters is
  selectable, and anything finer is typed into AreaOrVillage.

  The city takes the TEHSIL's id namespace deliberately — city 80001 is the
  town of tehsil 80001 — so the two can always be read against each other.
*/
MERGE dbo.m_mdm_city AS tgt
USING (SELECT th.TehsilId, th.Code, th.Name, th.DistrictId, th.DisplayOrder
         FROM dbo.m_mdm_tehsil th
         JOIN dbo.m_mdm_district d ON d.DistrictId = th.DistrictId AND d.Is_Deleted = 0
        WHERE d.StateId = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'HR' AND Is_Deleted = 0)
          AND th.Is_Deleted = 0
) AS src (TehsilId, Code, Name, DistrictId, DisplayOrder)
   ON tgt.CityId = src.TehsilId
WHEN NOT MATCHED BY TARGET
    THEN INSERT (CityId, Code, Name, DistrictId, TehsilId, DisplayOrder)
         VALUES (src.TehsilId, src.Code, src.Name, src.DistrictId, src.TehsilId, src.DisplayOrder);

DECLARE @StateId3 int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'HR' AND Is_Deleted = 0);

DECLARE @cities int = (SELECT COUNT(*) FROM dbo.m_mdm_city c
                         JOIN dbo.m_mdm_district d ON d.DistrictId = c.DistrictId
                        WHERE d.StateId = @StateId3 AND c.Is_Deleted = 0);

PRINT '    cities (tehsil headquarters): ' + CAST(@cities AS varchar(6));
GO

/*==============================================================================
  EXIT ASSERTIONS — the counts this file promises
==============================================================================*/

/*
  🔴 COUNTS ASSERTED, NOT PRINTED AND HOPED FOR.

  A seed that silently inserts 20 of 23 districts leaves a product where three
  districts do not exist and nothing is red. The numbers below are the ones in
  this file's header, so the header cannot drift from the data without the
  build failing.
*/
DECLARE @StateId int = (SELECT StateId FROM dbo.m_mdm_state WHERE Code = 'HR' AND Is_Deleted = 0);

DECLARE @d int = (SELECT COUNT(*) FROM dbo.m_mdm_district WHERE StateId = @StateId AND Is_Deleted = 0);

DECLARE @t int = (SELECT COUNT(*) FROM dbo.m_mdm_tehsil th
                    JOIN dbo.m_mdm_district dd ON dd.DistrictId = th.DistrictId
                   WHERE dd.StateId = @StateId AND th.Is_Deleted = 0);

DECLARE @c int = (SELECT COUNT(*) FROM dbo.m_mdm_city ct
                    JOIN dbo.m_mdm_district dd ON dd.DistrictId = ct.DistrictId
                   WHERE dd.StateId = @StateId AND ct.Is_Deleted = 0);

IF @d <> 23 OR @t <> 143 OR @c <> 143
BEGIN
    DECLARE @msg nvarchar(1000) =
        N'012_seed_haryana_geography: the seeded counts do not match this file''s header. '
        + N'districts ' + CAST(@d AS nvarchar(10)) + N' (expected 23), '
        + N'tehsils ' + CAST(@t AS nvarchar(10)) + N' (expected 143 = 94 tehsils + 49 sub-tehsils), '
        + N'cities ' + CAST(@c AS nvarchar(10)) + N' (expected 143, one per tehsil). '
        + N'If the source list genuinely changed, change the numbers HERE in the same commit as the data, with the date it was re-read.';

    RAISERROR('%s', 16, 1, @msg);
END

PRINT '    Haryana geography ready — ' + CAST(@d AS varchar(6)) + ' districts, '
    + CAST(@t AS varchar(6)) + ' tehsils, ' + CAST(@c AS varchar(6)) + ' cities.';
GO
