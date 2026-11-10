/*==============================================================================
  m_mdm_district.Code — widen varchar(30) to varchar(60).

  ---------------------------------------------------------------------------
  🔴 WHY, AND WHY IT ONLY SURFACED NOW
  ---------------------------------------------------------------------------
  SR-1 widened m_mdm_city.Code to 60 (039) because Haryana's town codes carry
  the district name as well as the town's. m_mdm_district.Code was left at 30
  because Haryana's longest district code, HR_MAHENDRAGARH, is fifteen
  characters and nothing in that state came close.

  The rest of India does. Chhattisgarh created districts in 2022 whose names
  are three towns joined:

      Manendragarh-Chirmiri-Bharatpur   -> CG_MANENDRAGARHCHIRMIRIBHARATPUR  (32)
      Khairagarh-Chhuikhadan-Gandai     -> CG_KHAIRAGARHCHHUIKHADANGANDAI    (30)
      Mohla-Manpur-Ambagarh Chowki      -> CG_MOHLAMANPURAMBAGARHCHOWKI      (28)

  The first of those is what failed the seed:

      Msg 2628 — String or binary data would be truncated in table
      'jp_mdm.dbo.m_mdm_district', column 'Code'.

  ⚠️ THE ERROR IS THE GOOD OUTCOME HERE. The column refused the row rather than
  silently storing a truncated code — and a truncated code is the worst case
  available, because Codes are the contract (2.47): jp_app and every seed guard
  match on them, and two districts truncated to the same thirty characters
  would collide on a unique index that is supposed to keep them apart.

  Sixty matches m_mdm_city, which is the number this family of tables already
  uses, and leaves room for the next reorganisation.

  ⚠️ BOTH INDEXES ARE DROPPED AND REBUILT. SQL Server will not alter a column an
  index depends on, and m_mdm_district has two that touch Code.

  IDEMPOTENT — guarded on the current width, so a re-run does nothing.
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF EXISTS (SELECT 1 FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.m_mdm_district') AND name = 'Code' AND max_length < 60)
BEGIN
    PRINT '    Widening [m_mdm_district].Code to varchar(60) ...';

    DECLARE @uq sysname = (SELECT name FROM sys.indexes
                            WHERE object_id = OBJECT_ID('dbo.m_mdm_district') AND name = 'UQ_m_mdm_district_Code');

    DECLARE @ix sysname = (SELECT name FROM sys.indexes
                            WHERE object_id = OBJECT_ID('dbo.m_mdm_district') AND name = 'IX_m_mdm_district_StateId');

    IF @uq IS NOT NULL DROP INDEX UQ_m_mdm_district_Code ON dbo.m_mdm_district;
    IF @ix IS NOT NULL DROP INDEX IX_m_mdm_district_StateId ON dbo.m_mdm_district;

    ALTER TABLE dbo.m_mdm_district ALTER COLUMN Code varchar(60) NOT NULL;

    /*
      ⚠️ REBUILT WITH THEIR ORIGINAL SHAPE, filtered on Is_Deleted = 0, which is
      how every other unique Code index in this database is defined — a
      soft-deleted row must not keep its code reserved for ever.
    */
    IF @uq IS NOT NULL
        CREATE UNIQUE NONCLUSTERED INDEX UQ_m_mdm_district_Code
            ON dbo.m_mdm_district (Code) WHERE Is_Deleted = 0;

    IF @ix IS NOT NULL
        CREATE NONCLUSTERED INDEX IX_m_mdm_district_StateId
            ON dbo.m_mdm_district (StateId, DisplayOrder) INCLUDE (Code, Name) WHERE Is_Deleted = 0;

    PRINT '    [m_mdm_district].Code is varchar(60).';
END
ELSE
    PRINT '    [m_mdm_district].Code already varchar(60) — nothing to do.';
GO

/*------------------------------------------------------------------ assertion */
/*
  🔴 ASSERTED, not printed and hoped for. A widening that silently did not
  happen would fail again at seed time, a hundred files later, with an error
  that names the seed rather than this.
*/
DECLARE @w int = (SELECT max_length FROM sys.columns
                   WHERE object_id = OBJECT_ID('dbo.m_mdm_district') AND name = 'Code');

IF @w < 60
BEGIN
    DECLARE @msg nvarchar(400) = N'040_alter_m_mdm_district_code_width: Code is still varchar('
        + CAST(@w AS nvarchar(10)) + N'). The widening did not apply.';

    RAISERROR('%s', 16, 1, @msg);
END
GO
