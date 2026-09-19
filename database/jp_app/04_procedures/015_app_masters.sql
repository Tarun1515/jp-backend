/*==============================================================================
  jp_app — 04_procedures / 015_app_masters.sql

  USP_GetAppMaster          generic, whitelist-driven master fetch for the
                            masters that live in jp_app rather than jp_mdm

  Target: SQL Server 2019 (15.0).

  ---------------------------------------------------------------------------
  🔴 WHY THERE IS A SECOND ONE OF THESE AT ALL (G26)
  ---------------------------------------------------------------------------
  `USP_GetMaster` lives in jp_mdm and reads jp_mdm tables. Six masters do not
  live there:

      m_app_employment_types   m_app_job_status    m_app_application_status
      m_app_ledger_entry_types m_app_ledger_sources m_app_ref_entity_types

  They are in jp_app because `t_app_jobs`, `t_app_applications` and
  `t_app_feature_ledger` carry PHYSICAL foreign keys to them, and decision 2.2
  forbids a physical FK across databases. So the master had to follow the table
  that points at it.

  ⚠️ The alternatives were considered and rejected:

    * A SYNONYM in jp_mdm pointing at jp_app. 2.2 endorses synonyms in the
      OTHER direction (jp_app → jp_mdm masters). Pointing jp_mdm at jp_app
      inverts the build order — run_all builds sso → mdm → app — so jp_mdm
      would name objects that do not exist yet on a fresh machine.
    * Copying the five tables into jp_mdm. 2.2's first rule: "masters ki copy
      mat banao". Two rows that must agree is how they stop agreeing.

  So: one procedure per database, each its own gate, and NO list in C# that
  says which key belongs to which. See the API note below.

  ---------------------------------------------------------------------------
  🔴 THESE ARE TRUE MASTERS. THE GATING PROHIBITION DOES NOT APPLY HERE.
  ---------------------------------------------------------------------------
  MONETIZATION_DESIGN.md and `EntitlementRepository` forbid gating reads from
  ever coming off the master cache. That prohibition is about exactly two
  tables — `m_mdm_features` and `m_mdm_plan_features` — because a FREE→METERED
  flip or a kill switch that takes an hour to land is not a switch at all.

  Nothing in this file is either of those tables, and nothing in it ever may
  be. Employment types are ordinary reference data: a school picks one from a
  dropdown, the client renames one when it feels like it, nobody's entitlement
  turns on it. The normal 1-hour master cache (2.48) applies to them exactly as
  it applies to subjects and boards.

  ⚠️ `m_app_ledger_*` here are the ledger's own vocabulary (Grant, Consume,
  Reversal, Expiry) — the NAMES of entry kinds, not anybody's quota. The engine
  never reads them through this path; it joins them inside its own procedures.

  ---------------------------------------------------------------------------
  🔴 WHITELIST, NOT DYNAMIC SQL ON THE PARAMETER
  ---------------------------------------------------------------------------
  Same rule and same reason as jp_mdm's `USP_GetMaster`: @MasterCode arrives
  from a query string and only ever selects a branch of a CASE this file wrote.
  A master not listed here returns an empty set. Adding one is a deliberate
  edit, which is the point — what an authenticated caller may enumerate should
  be readable in one place.

  ⚠️ NO KEY MAY APPEAR IN BOTH PROCEDURES. The API asks jp_mdm first and only
  falls through to this one when jp_mdm says it did not recognise the key
  (see MasterService). A key claimed by both would be answered by jp_mdm and
  this branch would never run — silently, with a 200 either way. The two key
  sets are disjoint today, and `jp-docs/scripts/verify/jobs-screens.mjs` reads
  BOTH procedure bodies out of sys.sql_modules and asserts the intersection is
  empty, so the day somebody adds an overlapping branch the suite says so.
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  USP_GetAppMaster — one procedure for every jp_app master lookup.

  The result-set SHAPE is identical to jp_mdm's USP_GetMaster (Id, Code, Name,
  DisplayOrder [, ParentId]) because one C# row type maps both. A column added
  to one and not the other is a null nobody notices.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetAppMaster
    @MasterCode varchar(50),
    @ParentId   int = NULL,    -- accepted for shape parity; no jp_app master is scoped yet

    /*
      🔴 1 when the key matched a branch, 0 when it did not. Same contract as
      jp_mdm's, and the flag carries more weight here: the API uses it to
      decide whether a key was genuinely unknown or merely not ours.

      The RESPONSE is unchanged either way — an unknown key still returns an
      empty set, because a caller probing for table names should learn nothing
      from the difference. We learn; they do not.
    */
    @Recognised bit = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @Recognised = 1;

    /*
      ⚠️ Normalised for the same reason jp_mdm's is: the branch names below are
      SQL-ish (EMPLOYMENT_TYPE) and the client sends a URL segment, which is
      kebab (/api/masters/employment-type). Uppercasing alone gives
      EMPLOYMENT-TYPE, which matches nothing and returns a permanently blank
      dropdown with a 200 and no error to explain it. That exact bug cost weeks
      in Phase 2E.
    */
    SET @MasterCode = UPPER(REPLACE(LTRIM(RTRIM(@MasterCode)), '-', '_'));

    IF @MasterCode = 'EMPLOYMENT_TYPE'
        SELECT EmploymentTypeId AS Id, Code, Name, DisplayOrder
        FROM dbo.m_app_employment_types
        WHERE Is_Deleted = 0 AND Is_Active = 1 ORDER BY DisplayOrder, Name;

    /*
      ⚠️ Returns all four INCLUDING Expired, which is derived and never stored
      (see 021_job_masters.sql). That is correct for a master read: a filter
      dropdown must offer Expired, because jobs genuinely are in that state —
      it is simply computed by fn_EffectiveJobStatusId rather than written.
    */
    ELSE IF @MasterCode = 'JOB_STATUS'
        SELECT JobStatusId AS Id, Code, Name, DisplayOrder
        FROM dbo.m_app_job_status
        WHERE Is_Deleted = 0 AND Is_Active = 1 ORDER BY DisplayOrder, Name;

    /*
      🔴 REACHABLE ROWS ONLY — IsReachable = 1 (Phase 5).

      The master holds ten statuses and the transition map can produce six.
      Seven to ten are the offer chain: they are seeded so their ids never move
      (2.47), `fn_ApplicationTransitionAllowed` refuses all four, and Phase 6
      is what makes them reachable.

      ⚠️ A filter dropdown offering "Offer sent" today would be a filter that
      can only ever return nothing — the person picks it, sees an empty list,
      and has no way to tell a working filter from a broken screen. That is the
      opposite of the JOB_STATUS branch above, which deliberately DOES offer
      Expired: jobs genuinely are expired, the status is merely computed rather
      than stored. Reachable-but-derived and unreachable-until-Phase-6 are
      different things and the dropdown has to tell them apart.

      🔴 st.Name, NEVER st.TeacherFacingName. This key feeds the SCHOOL's
      filter. The two vocabularies differ where it matters most — the school
      says "Rejected", the teacher is shown "Not selected" — and the teacher
      screens never need this list: every teacher-facing row already carries
      its own TeacherFacingName from the read procedures (017).
    */
    ELSE IF @MasterCode = 'APPLICATION_STATUS'
        SELECT ApplicationStatusId AS Id, Code, Name, DisplayOrder
        FROM dbo.m_app_application_status
        WHERE Is_Deleted = 0 AND Is_Active = 1 AND IsReachable = 1
        ORDER BY DisplayOrder, Name;

    ELSE IF @MasterCode = 'LEDGER_ENTRY_TYPE'
        SELECT EntryTypeId AS Id, Code, Name, DisplayOrder
        FROM dbo.m_app_ledger_entry_types
        WHERE Is_Deleted = 0 AND Is_Active = 1 ORDER BY DisplayOrder, Name;

    ELSE IF @MasterCode = 'LEDGER_SOURCE'
        SELECT SourceId AS Id, Code, Name, DisplayOrder
        FROM dbo.m_app_ledger_sources
        WHERE Is_Deleted = 0 AND Is_Active = 1 ORDER BY DisplayOrder, Name;

    ELSE IF @MasterCode = 'REF_ENTITY_TYPE'
        SELECT RefEntityTypeId AS Id, Code, Name, DisplayOrder
        FROM dbo.m_app_ref_entity_types
        WHERE Is_Deleted = 0 AND Is_Active = 1 ORDER BY DisplayOrder, Name;

    ELSE
    BEGIN
        /*
          An unknown code returns nothing at all — not an error, because the
          caller cannot fix it, and not a guess.

          🔴 This is ALSO the path every jp_mdm key takes. The API asks jp_mdm
          first, so 'SUBJECT' never reaches here; but a key that IS unknown
          everywhere lands here with @Recognised = 0, and that is what makes
          the API's warning trustworthy.
        */
        SET @Recognised = 0;

        SELECT TOP (0) CAST(NULL AS int) AS Id, CAST(NULL AS varchar(30)) AS Code,
                       CAST(NULL AS nvarchar(150)) AS Name, CAST(NULL AS int) AS DisplayOrder;
    END

END
GO

PRINT '    jp_app master procedure ready.';
GO
