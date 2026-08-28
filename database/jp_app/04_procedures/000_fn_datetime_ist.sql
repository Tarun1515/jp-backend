/*==============================================================================
  jp_app — 000_fn_datetime_ist.sql

  IST/UTC helper functions — jp_app's OWN copies.

  ⚠️ THIS IS A COPY. The master is:

      database/jp_sso/04_procedures/000_fn_datetime_ist.sql

  jp_mdm carries the second copy. All three hold byte-identical function
  bodies; only the header and the USE line differ, and Phase 2.5's
  verification diffs the definitions out of sys.sql_modules to prove it. If
  one of these ever needs to change, all three change in the same commit.

  Duplicated from jp_sso deliberately. A function cannot be called across a
  database boundary without a three-part name, which couples the databases and
  breaks independent deployment (decisions 2.1 and 2.2). Four small
  deterministic functions are the cheaper half of that trade.

  ---------------------------------------------------------------------------
  WHY jp_app FINALLY NEEDS THEM — PHASE 2.5
  ---------------------------------------------------------------------------
  The entitlement ledger lives in this database and its quota periods are IST
  calendar months (MONETIZATION_DESIGN.md, Decision 6). Quota use is DERIVED by
  counting consumes inside a period window rather than reset by a scheduled
  job, so the window arithmetic runs on every consume — and it cannot call
  jp_sso's copy without a three-part name.

  jp_app has not needed these until now, which is why it did not have them.
  That absence was found while writing the design doc, not while debugging a
  wrong month boundary at runtime — which is the cheaper of the two ways.

  See PROJECT_MEMORY.md decision 2.28.

  Storage is UTC everywhere. Business rules and filters are evaluated in IST,
  because every user is in India and a UTC day boundary falls at 05:30 IST —
  so anything created after 18:30 IST would otherwise be counted as the
  following day.

  IST is UTC+05:30 with NO daylight saving, ever. The offset is therefore a
  constant 330 minutes, which is why plain DATEADD is used rather than
  AT TIME ZONE: it is exact, it is cheaper, and — critically — it lets the
  caller compute boundaries into variables so the actual filter stays a plain
  column comparison that can still seek an index.

  These are created BEFORE the stored procedures that use them.
  CREATE OR ALTER (SQL Server 2016+) makes the script re-runnable.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

-- Filtered indexes REQUIRE these. sqlcmd defaults QUOTED_IDENTIFIER to OFF
-- (SSMS defaults it ON), so without this every CREATE INDEX with a WHERE
-- clause fails with Msg 1934 — and so does any later INSERT into the table.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*------------------------------------------------------------------------------
  fn_ToIst — a UTC instant as IST wall-clock time.

  For deriving an IST calendar date from a stored UTC value, and for report
  output. Do NOT use it inside a WHERE clause against a stored column: that
  wraps the column in a function and kills the index seek. Convert the
  BOUNDARIES instead (fn_IstDateToUtc).
------------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION dbo.fn_ToIst (@utc datetime2)
RETURNS datetime2
WITH SCHEMABINDING
AS
BEGIN
    RETURN DATEADD(MINUTE, 330, @utc);
END
GO


/*------------------------------------------------------------------------------
  fn_IstToday — today's calendar date in IST.

  Use in place of CAST(SYSUTCDATETIME() AS date), which is wrong for 5.5 hours
  of every day.
------------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION dbo.fn_IstToday ()
RETURNS date
AS
BEGIN
    RETURN CAST(DATEADD(MINUTE, 330, SYSUTCDATETIME()) AS date);
END
GO


/*------------------------------------------------------------------------------
  fn_IstDateToUtc — the UTC instant at which an IST calendar day begins.

  This is the workhorse. An IST day runs from 18:30 UTC the previous day to
  18:30 UTC on the day itself:

      fn_IstDateToUtc('2026-08-08') = 2026-08-07 18:30:00

  Build a half-open range from it and the filter stays sargable:

      DECLARE @FromUtc datetime2 = dbo.fn_IstDateToUtc(@FromDate);
      DECLARE @ToUtc   datetime2 = dbo.fn_IstDateToUtc(DATEADD(DAY, 1, @ToDate));
      ... WHERE AppliedOn >= @FromUtc AND AppliedOn < @ToUtc
------------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION dbo.fn_IstDateToUtc (@istDate date)
RETURNS datetime2
WITH SCHEMABINDING
AS
BEGIN
    RETURN DATEADD(MINUTE, -330, CAST(@istDate AS datetime2));
END
GO


/*------------------------------------------------------------------------------
  fn_IstDayRangeUtc — half-open UTC range covering a span of IST days.

  Inline table-valued function, so it expands into the calling query with no
  execution overhead at all.

  ToUtc is EXCLUSIVE. Always filter `>= FromUtc AND < ToUtc`; BETWEEN on a
  datetime2 silently drops everything after 00:00:00 on the final day.

      SELECT ...
      FROM dbo.t_app_applications a
      CROSS APPLY dbo.fn_IstDayRangeUtc(@FromDate, @ToDate) r
      WHERE a.AppliedOn >= r.FromUtc AND a.AppliedOn < r.ToUtc;
------------------------------------------------------------------------------*/
CREATE OR ALTER FUNCTION dbo.fn_IstDayRangeUtc (@fromIst date, @toIst date)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN
    SELECT
        DATEADD(MINUTE, -330, CAST(@fromIst AS datetime2))                     AS FromUtc,
        DATEADD(MINUTE, -330, CAST(DATEADD(DAY, 1, @toIst) AS datetime2))      AS ToUtc;
GO

PRINT '    IST/UTC helper functions ready.';
GO
