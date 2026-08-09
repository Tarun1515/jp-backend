/*==============================================================================
  jp_mdm — 03_seed / 006_seed_provisional_masters.sql

  School type · Skill · Facility

  ============================================================================
  ⚠️⚠️  PROVISIONAL — WE CHOSE THESE, THE CLIENT HAS NOT  ⚠️⚠️
  ============================================================================

  The client's lists had not arrived and staying blocked was costing more than
  guessing. Everything in THIS file is our judgement and the client may
  reasonably disagree with any of it.

  WHAT WE GUESSED, AND WHY IT MIGHT BE WRONG:

  m_mdm_school_type  (6 rows)
      Guessed the ownership categories used in Indian schooling. "Private
      Unaided" vs plain "Private" is the split we chose; a client thinking in
      terms of CBSE affiliation categories may want different buckets entirely.
      "Minority Institution" is a legal status rather than an ownership type,
      so it may belong on its own flag instead of in this list.

  m_mdm_skill  (20 rows)
      Entirely our invention. There is no standard list of teaching skills in
      Indian schooling, so this is a plausible set rather than a correct one.
      Expect the client to add, remove and rename freely. If they want skills
      grouped (classroom / digital / pastoral) that is a new column, not a
      rename.

  m_mdm_facility  (12 rows)
      The facilities a school would advertise. Straightforward, but the
      granularity is a guess: we split "Science Lab" and "Computer Lab" rather
      than having one "Laboratory", and a client may want the opposite.

  HOW TO RECONCILE WHEN THE REAL LIST ARRIVES:
      Match on Code. Rename freely — Name is display text.
      A row they do not want: Is_Active = 0, never DELETE (decision 2.5).
      A row they add: new Code, next free Id, do not renumber anything.
      🔴 NEVER change a Code that is already live. FKs resolve through it.

  Tracked in PROJECT_MEMORY open question #5.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

PRINT '    Seeding PROVISIONAL masters (school type, skill, facility) ...';
GO

/*------------------------------------------------------------------------------
  m_mdm_school_type — PROVISIONAL.
  Order: commonest first, so the most-picked option is the shortest reach.
------------------------------------------------------------------------------*/
MERGE dbo.m_mdm_school_type AS tgt
USING (VALUES
        (1, 'PRIVATE_UNAIDED', N'Private Unaided',       1),
        (2, 'GOVERNMENT',      N'Government',            2),
        (3, 'GOVT_AIDED',      N'Government Aided',      3),
        (4, 'INTERNATIONAL',   N'International',         4),
        (5, 'CONVENT',         N'Convent',               5),
        (6, 'MINORITY',        N'Minority Institution',  6)
      ) AS src (SchoolTypeId, Code, Name, DisplayOrder)
    ON tgt.SchoolTypeId = src.SchoolTypeId
WHEN MATCHED AND (tgt.Code <> src.Code OR tgt.Name <> src.Name OR tgt.DisplayOrder <> src.DisplayOrder)
    THEN UPDATE SET tgt.Code = src.Code, tgt.Name = src.Name,
                    tgt.DisplayOrder = src.DisplayOrder, tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (SchoolTypeId, Code, Name, DisplayOrder)
         VALUES (src.SchoolTypeId, src.Code, src.Name, src.DisplayOrder);
GO

/*------------------------------------------------------------------------------
  m_mdm_skill — PROVISIONAL, and the most speculative list in this file.
  Grouped: classroom practice, then digital, then pastoral, then admin.
------------------------------------------------------------------------------*/
MERGE dbo.m_mdm_skill AS tgt
USING (VALUES
        -- classroom practice
        ( 1, 'CLASSROOM_MGMT',   N'Classroom Management',         1),
        ( 2, 'LESSON_PLANNING',  N'Lesson Planning',              2),
        ( 3, 'CURRICULUM_DEV',   N'Curriculum Development',       3),
        ( 4, 'ASSESSMENT',       N'Assessment and Evaluation',    4),
        ( 5, 'DIFFERENTIATED',   N'Differentiated Instruction',   5),
        ( 6, 'PHONICS',          N'Phonics',                      6),
        ( 7, 'REMEDIAL',         N'Remedial Teaching',            7),
        -- digital
        (10, 'SMART_BOARD',      N'Smart Board',                 10),
        (11, 'ONLINE_TEACHING',  N'Online Teaching',             11),
        (12, 'MS_OFFICE',        N'MS Office',                   12),
        (13, 'LMS',              N'Learning Management Systems', 13),
        (14, 'EDU_APPS',         N'Educational Apps and Tools',  14),
        -- pastoral
        (20, 'COUNSELLING',      N'Student Counselling',         20),
        (21, 'SPECIAL_NEEDS',    N'Special Needs Support',       21),
        (22, 'PARENT_COMM',      N'Parent Communication',        22),
        (23, 'BEHAVIOUR_MGMT',   N'Behaviour Management',        23),
        -- wider school life
        (30, 'EXTRA_CURRICULAR', N'Extra-Curricular Activities', 30),
        (31, 'EVENT_MGMT',       N'Event Management',            31),
        (32, 'SPORTS_COACHING',  N'Sports Coaching',             32),
        (33, 'EXAM_ADMIN',       N'Examination Administration',  33)
      ) AS src (SkillId, Code, Name, DisplayOrder)
    ON tgt.SkillId = src.SkillId
WHEN MATCHED AND (tgt.Code <> src.Code OR tgt.Name <> src.Name OR tgt.DisplayOrder <> src.DisplayOrder)
    THEN UPDATE SET tgt.Code = src.Code, tgt.Name = src.Name,
                    tgt.DisplayOrder = src.DisplayOrder, tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (SkillId, Code, Name, DisplayOrder)
         VALUES (src.SkillId, src.Code, src.Name, src.DisplayOrder);
GO

/*------------------------------------------------------------------------------
  m_mdm_facility — PROVISIONAL.
------------------------------------------------------------------------------*/
MERGE dbo.m_mdm_facility AS tgt
USING (VALUES
        ( 1, 'LIBRARY',        N'Library',              1),
        ( 2, 'SCIENCE_LAB',    N'Science Laboratory',   2),
        ( 3, 'COMPUTER_LAB',   N'Computer Laboratory',  3),
        ( 4, 'PLAYGROUND',     N'Playground',           4),
        ( 5, 'SPORTS_COMPLEX', N'Sports Complex',       5),
        ( 6, 'TRANSPORT',      N'Transport',            6),
        ( 7, 'HOSTEL',         N'Hostel',               7),
        ( 8, 'SMART_CLASS',    N'Smart Classrooms',     8),
        ( 9, 'AC_CLASSROOM',   N'Air-Conditioned Classrooms', 9),
        (10, 'CANTEEN',        N'Canteen',             10),
        (11, 'MEDICAL_ROOM',   N'Medical Room',        11),
        (12, 'CCTV',           N'CCTV Security',       12)
      ) AS src (FacilityId, Code, Name, DisplayOrder)
    ON tgt.FacilityId = src.FacilityId
WHEN MATCHED AND (tgt.Code <> src.Code OR tgt.Name <> src.Name OR tgt.DisplayOrder <> src.DisplayOrder)
    THEN UPDATE SET tgt.Code = src.Code, tgt.Name = src.Name,
                    tgt.DisplayOrder = src.DisplayOrder, tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (FacilityId, Code, Name, DisplayOrder)
         VALUES (src.FacilityId, src.Code, src.Name, src.DisplayOrder);
GO

PRINT '    PROVISIONAL masters seeded — see the header before treating these as final.';
GO
