/*==============================================================================
  jp_mdm — 03_seed / 009_seed_languages.sql

  m_mdm_language.

  ⚠️ THE TABLE WAS EMPTY. Phase 2B seeded eighteen masters and this was not one
  of them — noticed in Phase 3B, when teacher profiles needed languages and the
  bridge had nothing to point at.

  ---------------------------------------------------------------------------
  NOT MARKED PROVISIONAL, UNLIKE THE FIVE 2B FLAGGED
  ---------------------------------------------------------------------------
  Decision 2.47 marks a master provisional when we invented a list the client
  will eventually have opinions about — rejection reasons, document types.

  This is not that. The languages Indian schools teach in are a matter of fact,
  and the 22 scheduled languages plus English are the obvious set. A client
  might ADD one; they are not going to disagree that Marathi belongs.

  The medium of instruction is frequently the deciding fact in a hire — a school
  teaching in Marathi needs somebody who can, whatever their subject — so the
  list leads with the languages that are actually used as a medium rather than
  with an alphabetical dump.

  Re-runnable: MERGE on the id, so running twice changes nothing (2.47).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

PRINT '  Seeding languages ...';
GO

MERGE dbo.m_mdm_language AS tgt
USING (VALUES
        -- The two that appear in almost every school in the country.
        ( 1, 'ENGLISH',   N'English',   1),
        ( 2, 'HINDI',     N'Hindi',     2),

        -- Widely used as a medium of instruction, roughly by number of schools.
        ( 3, 'MARATHI',   N'Marathi',   3),
        ( 4, 'BENGALI',   N'Bengali',   4),
        ( 5, 'TAMIL',     N'Tamil',     5),
        ( 6, 'TELUGU',    N'Telugu',    6),
        ( 7, 'KANNADA',   N'Kannada',   7),
        ( 8, 'MALAYALAM', N'Malayalam', 8),
        ( 9, 'GUJARATI',  N'Gujarati',  9),
        (10, 'PUNJABI',   N'Punjabi',  10),
        (11, 'ODIA',      N'Odia',     11),
        (12, 'ASSAMESE',  N'Assamese', 12),
        (13, 'URDU',      N'Urdu',     13),

        -- Taught as subjects far more often than used as a medium, so they sit
        -- below the block above rather than being sorted in alphabetically.
        (20, 'SANSKRIT',  N'Sanskrit', 20),
        (21, 'FRENCH',    N'French',   21),
        (22, 'GERMAN',    N'German',   22),
        (23, 'SPANISH',   N'Spanish',  23),

        -- The remaining scheduled languages. Present so a school in Manipur or
        -- Kashmir is not told its medium of instruction is not on our list.
        (30, 'KASHMIRI',  N'Kashmiri', 30),
        (31, 'KONKANI',   N'Konkani',  31),
        (32, 'MAITHILI',  N'Maithili', 32),
        (33, 'MANIPURI',  N'Manipuri', 33),
        (34, 'NEPALI',    N'Nepali',   34),
        (35, 'SINDHI',    N'Sindhi',   35),
        (36, 'BODO',      N'Bodo',     36),
        (37, 'DOGRI',     N'Dogri',    37),
        (38, 'SANTALI',   N'Santali',  38)
      ) AS src (LanguageId, Code, Name, DisplayOrder)
    ON tgt.LanguageId = src.LanguageId
WHEN MATCHED AND (tgt.Code <> src.Code OR tgt.Name <> src.Name OR tgt.DisplayOrder <> src.DisplayOrder)
    THEN UPDATE SET tgt.Code = src.Code, tgt.Name = src.Name,
                    tgt.DisplayOrder = src.DisplayOrder, tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (LanguageId, Code, Name, DisplayOrder)
         VALUES (src.LanguageId, src.Code, src.Name, src.DisplayOrder);
GO

PRINT '    Languages ready.';
GO
