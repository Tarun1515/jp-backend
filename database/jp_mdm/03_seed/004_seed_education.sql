/*==============================================================================
  jp_mdm — 03_seed / 004_seed_education.sql

  Board · Qualification · Subject · Designation · Class level · Stream

  ---------------------------------------------------------------------------
  STATUS: SEEDED FULLY, NOT PROVISIONAL
  ---------------------------------------------------------------------------
  These are standard across Indian schooling and unlikely to be disputed. The
  client may rename rows; they are unlikely to say CBSE does not exist.

  ---------------------------------------------------------------------------
  🔴 CODE IS STABLE, NAME IS EDITABLE
  ---------------------------------------------------------------------------
  Code is the identifier. FKs resolve through it, this script matches on it, and
  it must never change once live. Name is display text — when the client says
  "call it State Education Board instead", that is an UPDATE to one column.

  Codes are conventional, not generated: CBSE, PRT, TGT, PGT, PHD. Not slugs,
  not sequential numbers.

  ---------------------------------------------------------------------------
  DISPLAYORDER IS DELIBERATE, NOT ALPHABETICAL
  ---------------------------------------------------------------------------
  These appear in dropdowns hundreds of times a day. Alphabetical ordering is a
  small tax on every one of those. So: designations in career order, class
  levels in school order, qualifications grouped by kind.

  Re-runnable. MERGE, never deletes.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

PRINT '    Seeding education masters ...';
GO

/*------------------------------------------------------------------------------
  m_mdm_board — examination boards.
  Order: national boards first, then state, then international, then open.
------------------------------------------------------------------------------*/
MERGE dbo.m_mdm_board AS tgt
USING (VALUES
        (1, 'CBSE',        N'CBSE',                                     1),
        (2, 'ICSE',        N'ICSE',                                     2),
        (3, 'CISCE',       N'CISCE',                                    3),
        (4, 'STATE_BOARD', N'State Board',                              4),
        (5, 'IB',          N'IB (International Baccalaureate)',         5),
        (6, 'IGCSE',       N'IGCSE (Cambridge)',                        6),
        (7, 'NIOS',        N'NIOS (National Institute of Open Schooling)', 7)
      ) AS src (BoardId, Code, Name, DisplayOrder)
    ON tgt.BoardId = src.BoardId
WHEN MATCHED AND (tgt.Code <> src.Code OR tgt.Name <> src.Name OR tgt.DisplayOrder <> src.DisplayOrder)
    THEN UPDATE SET tgt.Code = src.Code, tgt.Name = src.Name,
                    tgt.DisplayOrder = src.DisplayOrder, tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (BoardId, Code, Name, DisplayOrder)
         VALUES (src.BoardId, src.Code, src.Name, src.DisplayOrder);
GO

/*------------------------------------------------------------------------------
  m_mdm_qualification

  Grouped, not alphabetical:
      1-10   teaching degrees and diplomas — the ones that qualify you to teach
      11-20  academic degrees, bachelor's then master's then doctorate
      21-30  eligibility tests — the ones a school filters on
------------------------------------------------------------------------------*/
MERGE dbo.m_mdm_qualification AS tgt
USING (VALUES
        -- teaching qualifications
        ( 1, 'B_ED',     N'B.Ed',                                     1),
        ( 2, 'M_ED',     N'M.Ed',                                     2),
        ( 3, 'D_EL_ED',  N'D.El.Ed',                                  3),
        ( 4, 'NTT',      N'NTT (Nursery Teacher Training)',           4),
        ( 5, 'B_P_ED',   N'B.P.Ed (Physical Education)',              5),
        -- academic degrees
        (11, 'BA',       N'B.A',                                     11),
        (12, 'B_SC',     N'B.Sc',                                    12),
        (13, 'B_COM',    N'B.Com',                                   13),
        (14, 'MA',       N'M.A',                                     14),
        (15, 'M_SC',     N'M.Sc',                                    15),
        (16, 'M_COM',    N'M.Com',                                   16),
        (17, 'PHD',      N'PhD',                                     17),
        -- eligibility tests
        (21, 'CTET',     N'CTET',                                    21),
        (22, 'STATE_TET',N'State TET',                               22),
        (23, 'NET',      N'NET',                                     23),
        (24, 'SET',      N'SET',                                     24)
      ) AS src (QualificationId, Code, Name, DisplayOrder)
    ON tgt.QualificationId = src.QualificationId
WHEN MATCHED AND (tgt.Code <> src.Code OR tgt.Name <> src.Name OR tgt.DisplayOrder <> src.DisplayOrder)
    THEN UPDATE SET tgt.Code = src.Code, tgt.Name = src.Name,
                    tgt.DisplayOrder = src.DisplayOrder, tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (QualificationId, Code, Name, DisplayOrder)
         VALUES (src.QualificationId, src.Code, src.Name, src.DisplayOrder);
GO

/*------------------------------------------------------------------------------
  m_mdm_subject — the standard school set.

  Grouped by faculty rather than alphabetically, because that is how a teacher
  thinks about what they teach and how a school thinks about what it needs:
      1-9    core / sciences
      10-19  languages
      20-29  humanities and commerce
      30-39  practical and co-curricular
------------------------------------------------------------------------------*/
MERGE dbo.m_mdm_subject AS tgt
USING (VALUES
        -- core and sciences
        ( 1, 'MATHS',        N'Mathematics',            1),
        ( 2, 'PHYSICS',      N'Physics',                2),
        ( 3, 'CHEMISTRY',    N'Chemistry',              3),
        ( 4, 'BIOLOGY',      N'Biology',                4),
        ( 5, 'SCIENCE',      N'Science (general)',      5),
        ( 6, 'ENV_STUDIES',  N'Environmental Studies',  6),
        -- languages
        (10, 'ENGLISH',      N'English',               10),
        (11, 'HINDI',        N'Hindi',                 11),
        (12, 'SANSKRIT',     N'Sanskrit',              12),
        (13, 'URDU',         N'Urdu',                  13),
        (14, 'PUNJABI',      N'Punjabi',               14),
        (15, 'MARATHI',      N'Marathi',               15),
        (16, 'BENGALI',      N'Bengali',               16),
        (17, 'TAMIL',        N'Tamil',                 17),
        (18, 'TELUGU',       N'Telugu',                18),
        (19, 'FRENCH',       N'French',                19),
        (20, 'GERMAN',       N'German',                20),
        -- humanities and commerce
        (25, 'SOCIAL_STUD',  N'Social Studies',        25),
        (26, 'HISTORY',      N'History',               26),
        (27, 'GEOGRAPHY',    N'Geography',             27),
        (28, 'CIVICS',       N'Civics / Political Science', 28),
        (29, 'ECONOMICS',    N'Economics',             29),
        (30, 'ACCOUNTANCY',  N'Accountancy',           30),
        (31, 'BUSINESS_STD', N'Business Studies',      31),
        (32, 'PSYCHOLOGY',   N'Psychology',            32),
        (33, 'SOCIOLOGY',    N'Sociology',             33),
        -- practical and co-curricular
        (40, 'COMPUTER_SCI', N'Computer Science',      40),
        (41, 'INFO_TECH',    N'Information Technology',41),
        (42, 'PHYSICAL_ED',  N'Physical Education',    42),
        (43, 'ART',          N'Art and Craft',         43),
        (44, 'MUSIC',        N'Music',                 44),
        (45, 'DANCE',        N'Dance',                 45),
        (46, 'HOME_SCIENCE', N'Home Science',          46),
        (47, 'GEN_KNOWLEDGE',N'General Knowledge',     47)
      ) AS src (SubjectId, Code, Name, DisplayOrder)
    ON tgt.SubjectId = src.SubjectId
WHEN MATCHED AND (tgt.Code <> src.Code OR tgt.Name <> src.Name OR tgt.DisplayOrder <> src.DisplayOrder)
    THEN UPDATE SET tgt.Code = src.Code, tgt.Name = src.Name,
                    tgt.DisplayOrder = src.DisplayOrder, tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (SubjectId, Code, Name, DisplayOrder)
         VALUES (src.SubjectId, src.Code, src.Name, src.DisplayOrder);
GO

/*------------------------------------------------------------------------------
  m_mdm_designation

  🔴 CAREER ORDER, not alphabetical. PRT -> TGT -> PGT is the ladder every
  teacher in India understands, and a dropdown that lists Coordinator, Librarian,
  PGT, PRT, Principal, TGT is one that has to be read rather than scanned.
------------------------------------------------------------------------------*/
MERGE dbo.m_mdm_designation AS tgt
USING (VALUES
        ( 1, 'PRT',          N'PRT (Primary Teacher)',           1),
        ( 2, 'TGT',          N'TGT (Trained Graduate Teacher)',  2),
        ( 3, 'PGT',          N'PGT (Post Graduate Teacher)',     3),
        ( 4, 'COORDINATOR',  N'Coordinator',                     4),
        ( 5, 'VICE_PRINCIPAL', N'Vice Principal',                5),
        ( 6, 'PRINCIPAL',    N'Principal',                       6),
        ( 7, 'LIBRARIAN',    N'Librarian',                       7),
        ( 8, 'SPORTS',       N'Sports Teacher',                  8),
        ( 9, 'COUNSELLOR',   N'Counsellor',                      9),
        (10, 'LAB_ASSISTANT',N'Lab Assistant',                  10)
      ) AS src (DesignationId, Code, Name, DisplayOrder)
    ON tgt.DesignationId = src.DesignationId
WHEN MATCHED AND (tgt.Code <> src.Code OR tgt.Name <> src.Name OR tgt.DisplayOrder <> src.DisplayOrder)
    THEN UPDATE SET tgt.Code = src.Code, tgt.Name = src.Name,
                    tgt.DisplayOrder = src.DisplayOrder, tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (DesignationId, Code, Name, DisplayOrder)
         VALUES (src.DesignationId, src.Code, src.Name, src.DisplayOrder);
GO

/*------------------------------------------------------------------------------
  m_mdm_class_level — 🔴 SCHOOL ORDER, youngest first.
------------------------------------------------------------------------------*/
MERGE dbo.m_mdm_class_level AS tgt
USING (VALUES
        (1, 'PRE_PRIMARY', N'Pre-Primary',                1),
        (2, 'PRIMARY',     N'Primary (I-V)',              2),
        (3, 'MIDDLE',      N'Middle (VI-VIII)',           3),
        (4, 'SECONDARY',   N'Secondary (IX-X)',           4),
        (5, 'SR_SECONDARY',N'Senior Secondary (XI-XII)',  5)
      ) AS src (ClassLevelId, Code, Name, DisplayOrder)
    ON tgt.ClassLevelId = src.ClassLevelId
WHEN MATCHED AND (tgt.Code <> src.Code OR tgt.Name <> src.Name OR tgt.DisplayOrder <> src.DisplayOrder)
    THEN UPDATE SET tgt.Code = src.Code, tgt.Name = src.Name,
                    tgt.DisplayOrder = src.DisplayOrder, tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (ClassLevelId, Code, Name, DisplayOrder)
         VALUES (src.ClassLevelId, src.Code, src.Name, src.DisplayOrder);
GO

/*------------------------------------------------------------------------------
  m_mdm_stream — senior secondary streams.
------------------------------------------------------------------------------*/
MERGE dbo.m_mdm_stream AS tgt
USING (VALUES
        (1, 'SCIENCE',    N'Science',    1),
        (2, 'COMMERCE',   N'Commerce',   2),
        (3, 'ARTS',       N'Arts / Humanities', 3),
        (4, 'VOCATIONAL', N'Vocational', 4)
      ) AS src (StreamId, Code, Name, DisplayOrder)
    ON tgt.StreamId = src.StreamId
WHEN MATCHED AND (tgt.Code <> src.Code OR tgt.Name <> src.Name OR tgt.DisplayOrder <> src.DisplayOrder)
    THEN UPDATE SET tgt.Code = src.Code, tgt.Name = src.Name,
                    tgt.DisplayOrder = src.DisplayOrder, tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (StreamId, Code, Name, DisplayOrder)
         VALUES (src.StreamId, src.Code, src.Name, src.DisplayOrder);
GO

PRINT '    Education masters seeded.';
GO
