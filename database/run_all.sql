/*==============================================================================
  run_all.sql
  Teacher Recruitment Portal — full database build orchestrator.

  Builds all three databases in dependency order:
      jp_sso  (identity)  ->  jp_mdm  (masters + approval)  ->  jp_app (business)

  Each database is built in the fixed order:
      00_create_database  ->  01_tables  ->  02_indexes  ->  03_seed  ->  04_procedures

  ----------------------------------------------------------------------------
  SQLCMD MODE IS REQUIRED. This script uses :setvar, :r and :on error.
  ----------------------------------------------------------------------------

  Run from the REPOSITORY ROOT (paths below are relative to it):

      sqlcmd -S localhost\TARUN -E -b -f 65001 -i database\run_all.sql

  Or with SQL authentication:

      sqlcmd -S localhost\TARUN -U jp_user -P $env:SQL_PASSWORD -b -f 65001 -i database\run_all.sql

  Flags that matter:
      -b          stop on error. Without it sqlcmd reports a failure and then
                  cheerfully carries on running the remaining scripts.
      -f 65001    read the input as UTF-8. These files contain non-ASCII
                  characters; without this sqlcmd decodes them as ANSI and
                  mangles anything outside 7-bit ASCII.

  To run from somewhere else, override DbRoot on the command line
  (a -v value takes precedence over the :setvar default below):

      sqlcmd -S localhost\TARUN -E -v DbRoot="D:\Projects\TeacherRecruitmentPortal\database" -i run_all.sql

  In SSMS / Azure Data Studio: Query -> "SQLCMD Mode" must be enabled first,
  otherwise every ':' line is reported as a syntax error.

  ----------------------------------------------------------------------------
  IDEMPOTENT. Every referenced script guards its own object, so re-running this
  file is safe and is the normal way to apply new scripts to an existing dev DB.
  ----------------------------------------------------------------------------

  PHASE 0 NOTE
  Only the database-creation scripts exist so far. The :r include lines for
  tables / indexes / seed / procedures are stubbed out below and get uncommented
  as Phase 1 onward lands. Keep every new script listed here, in order — this
  file is the authoritative build order.
==============================================================================*/

:on error exit

:setvar DbRoot "database"

SET NOCOUNT ON;
GO

/*
  Filtered indexes REQUIRE QUOTED_IDENTIFIER ON, both to CREATE them and for
  any later INSERT/UPDATE on the table. sqlcmd defaults it to OFF while SSMS
  defaults it ON, which is why a script can work in SSMS and fail from the
  command line with Msg 1934.

  Set here for the whole session, and repeated at the top of every individual
  script so they also work when run standalone.
*/
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

PRINT '';
PRINT '===============================================================================';
PRINT ' TEACHER RECRUITMENT PORTAL — DATABASE BUILD';
PRINT ' Server   : ' + @@SERVERNAME;
PRINT ' Started  : ' + CONVERT(varchar(30), SYSUTCDATETIME(), 126) + ' (UTC)';
PRINT '===============================================================================';
GO


/*==============================================================================
  DB 1 — jp_sso  (identity: users, credentials, tokens, roles, permissions)
==============================================================================*/
PRINT '';
PRINT '--- jp_sso -------------------------------------------------------------------';
GO

:r $(DbRoot)\jp_sso\00_create_database.sql

-- ---- tables: 7 masters, then 10 transactional in dependency order ----------
PRINT '  Tables ...';
GO
:r $(DbRoot)\jp_sso\01_tables\001_m_sso_user_types.sql
:r $(DbRoot)\jp_sso\01_tables\002_m_sso_user_status.sql
:r $(DbRoot)\jp_sso\01_tables\003_m_sso_hash_algorithms.sql
:r $(DbRoot)\jp_sso\01_tables\004_m_sso_token_types.sql
:r $(DbRoot)\jp_sso\01_tables\005_m_sso_otp_channels.sql
:r $(DbRoot)\jp_sso\01_tables\006_m_sso_lock_reasons.sql
:r $(DbRoot)\jp_sso\01_tables\007_m_sso_modules.sql
:r $(DbRoot)\jp_sso\01_tables\008_t_sso_users.sql
:r $(DbRoot)\jp_sso\01_tables\009_t_sso_user_credentials.sql
:r $(DbRoot)\jp_sso\01_tables\010_t_sso_user_tokens.sql
:r $(DbRoot)\jp_sso\01_tables\011_t_sso_user_otps.sql
:r $(DbRoot)\jp_sso\01_tables\012_t_sso_user_login_attempts.sql
:r $(DbRoot)\jp_sso\01_tables\013_t_sso_user_lockouts.sql
:r $(DbRoot)\jp_sso\01_tables\014_t_sso_roles.sql
:r $(DbRoot)\jp_sso\01_tables\015_t_sso_permissions.sql
:r $(DbRoot)\jp_sso\01_tables\016_t_sso_role_permissions.sql
:r $(DbRoot)\jp_sso\01_tables\017_t_sso_user_roles.sql
-- Column additions to already-deployed tables go in numbered ALTER scripts
-- (see Block D of _TEMPLATE_table.sql), never by editing the CREATE above.
:r $(DbRoot)\jp_sso\01_tables\018_alter_t_sso_user_lockouts_previous_status.sql
:r $(DbRoot)\jp_sso\01_tables\019_alter_t_sso_user_lockouts_unlockedby_check.sql
:r $(DbRoot)\jp_sso\01_tables\020_t_sso_error_log.sql
-- Navigation. Menus live in jp_sso because a menu row is gated by a permission
-- and permissions are here; any other home means a cross-database join on
-- every sign-in, which decision 2.2 forbids.
:r $(DbRoot)\jp_sso\01_tables\021_m_sso_menus.sql
:r $(DbRoot)\jp_sso\01_tables\022_t_sso_role_menus.sql

-- ---- indexes ---------------------------------------------------------------
PRINT '  Indexes ...';
GO
:r $(DbRoot)\jp_sso\02_indexes\001_ix_t_sso_users.sql
:r $(DbRoot)\jp_sso\02_indexes\002_ix_t_sso_user_credentials.sql
:r $(DbRoot)\jp_sso\02_indexes\003_ix_t_sso_user_tokens.sql
:r $(DbRoot)\jp_sso\02_indexes\004_ix_t_sso_user_otps.sql
:r $(DbRoot)\jp_sso\02_indexes\005_ix_t_sso_user_login_attempts.sql
:r $(DbRoot)\jp_sso\02_indexes\006_ix_t_sso_user_lockouts.sql
:r $(DbRoot)\jp_sso\02_indexes\007_ix_t_sso_roles.sql
:r $(DbRoot)\jp_sso\02_indexes\008_ix_t_sso_permissions.sql
:r $(DbRoot)\jp_sso\02_indexes\009_ix_t_sso_role_permissions.sql
:r $(DbRoot)\jp_sso\02_indexes\010_ix_t_sso_user_roles.sql

-- ---- seed ------------------------------------------------------------------
PRINT '  Seed ...';
GO
:r $(DbRoot)\jp_sso\03_seed\001_seed_masters.sql
:r $(DbRoot)\jp_sso\03_seed\002_seed_roles.sql
:r $(DbRoot)\jp_sso\03_seed\003_seed_permissions.sql
:r $(DbRoot)\jp_sso\03_seed\004_seed_role_permissions.sql
-- Menus AFTER permissions: the seed resolves PermissionCode -> PermissionId
-- and aborts on an unknown code, because a typo there would silently make an
-- item visible to everyone rather than to nobody.
:r $(DbRoot)\jp_sso\03_seed\005_seed_menus.sql

-- ---- programmability -------------------------------------------------------
-- Functions first: the Phase 1B procedures depend on them.
PRINT '  Functions and procedures ...';
GO
:r $(DbRoot)\jp_sso\04_procedures\000_fn_datetime_ist.sql
-- USP_LogError first: every procedure below calls it from its CATCH block.
:r $(DbRoot)\jp_sso\04_procedures\000_USP_LogError.sql
:r $(DbRoot)\jp_sso\04_procedures\001_registration.sql
:r $(DbRoot)\jp_sso\04_procedures\002_login.sql
:r $(DbRoot)\jp_sso\04_procedures\003_tokens.sql
:r $(DbRoot)\jp_sso\04_procedures\004_password.sql
:r $(DbRoot)\jp_sso\04_procedures\005_otp.sql
:r $(DbRoot)\jp_sso\04_procedures\006_admin.sql
:r $(DbRoot)\jp_sso\04_procedures\007_lists.sql
:r $(DbRoot)\jp_sso\04_procedures\008_menus.sql

-- Phase 3G. The cross-database join the team screen needs: jp_app holds the
-- membership, jp_sso holds the email, and no query may join the two (2.2).
:r $(DbRoot)\jp_sso\04_procedures\009_users_by_uid.sql
:r $(DbRoot)\jp_sso\04_procedures\009_identity_lookup.sql


/*==============================================================================
  DB 2 — jp_mdm  (master data + approval engine + registration payload)
==============================================================================*/
PRINT '';
PRINT '--- jp_mdm -------------------------------------------------------------------';
GO

:r $(DbRoot)\jp_mdm\00_create_database.sql

-- ---- tables: 23 masters, then 8 transactional in dependency order, the error
-- ---- log, and the two tables Phase 2C added (the RequestNo prefix column and
-- ---- the per-type-per-year counter). Order matters — a FK cannot reference a
-- ---- table that does not exist yet, and geography is a four-level hierarchy.
PRINT '  Tables ...';
GO
:r $(DbRoot)\jp_mdm\01_tables\001_m_mdm_country.sql
:r $(DbRoot)\jp_mdm\01_tables\002_m_mdm_state.sql
:r $(DbRoot)\jp_mdm\01_tables\003_m_mdm_district.sql
:r $(DbRoot)\jp_mdm\01_tables\004_m_mdm_city.sql
:r $(DbRoot)\jp_mdm\01_tables\005_m_mdm_board.sql
:r $(DbRoot)\jp_mdm\01_tables\006_m_mdm_school_type.sql
:r $(DbRoot)\jp_mdm\01_tables\007_m_mdm_qualification.sql
:r $(DbRoot)\jp_mdm\01_tables\008_m_mdm_subject.sql
:r $(DbRoot)\jp_mdm\01_tables\009_m_mdm_designation.sql
:r $(DbRoot)\jp_mdm\01_tables\010_m_mdm_class_level.sql
:r $(DbRoot)\jp_mdm\01_tables\011_m_mdm_stream.sql
:r $(DbRoot)\jp_mdm\01_tables\012_m_mdm_gender.sql
:r $(DbRoot)\jp_mdm\01_tables\013_m_mdm_skill.sql
:r $(DbRoot)\jp_mdm\01_tables\014_m_mdm_language.sql
:r $(DbRoot)\jp_mdm\01_tables\015_m_mdm_facility.sql
:r $(DbRoot)\jp_mdm\01_tables\016_m_mdm_experience_range.sql
:r $(DbRoot)\jp_mdm\01_tables\017_m_mdm_request_types.sql
:r $(DbRoot)\jp_mdm\01_tables\018_m_mdm_approval_status.sql
:r $(DbRoot)\jp_mdm\01_tables\019_m_mdm_action_types.sql
:r $(DbRoot)\jp_mdm\01_tables\020_m_mdm_document_types.sql
:r $(DbRoot)\jp_mdm\01_tables\021_m_mdm_rejection_reasons.sql
:r $(DbRoot)\jp_mdm\01_tables\022_m_mdm_payment_modes.sql
:r $(DbRoot)\jp_mdm\01_tables\023_m_mdm_payment_status.sql
:r $(DbRoot)\jp_mdm\01_tables\024_t_mdm_request_levels.sql
:r $(DbRoot)\jp_mdm\01_tables\025_t_mdm_approval_requests.sql
:r $(DbRoot)\jp_mdm\01_tables\026_t_mdm_request_approvals.sql
:r $(DbRoot)\jp_mdm\01_tables\027_t_mdm_request_documents.sql
:r $(DbRoot)\jp_mdm\01_tables\028_t_mdm_request_payments.sql
:r $(DbRoot)\jp_mdm\01_tables\029_t_mdm_school_registration_details.sql
:r $(DbRoot)\jp_mdm\01_tables\030_t_mdm_teacher_registration_details.sql
:r $(DbRoot)\jp_mdm\01_tables\031_t_mdm_teacher_registration_subjects.sql
:r $(DbRoot)\jp_mdm\01_tables\032_t_mdm_error_log.sql
:r $(DbRoot)\jp_mdm\01_tables\033_alter_m_mdm_request_types_prefix.sql
:r $(DbRoot)\jp_mdm\01_tables\034_t_mdm_request_number_series.sql
:r $(DbRoot)\jp_mdm\01_tables\035_m_mdm_plans.sql

-- Phase 2.5 — the entitlement catalog. New tables BESIDE m_mdm_plans; 035 said
-- monetization "is NOT here and should not be added here", and this is it.
:r $(DbRoot)\jp_mdm\01_tables\036_entitlement_catalog.sql

-- ---- indexes: access paths only. Business-key uniques live beside their table
-- ---- in 01_tables, because a business key is part of what the table means
-- ---- rather than a performance decision.
PRINT '  Indexes ...';
GO
:r $(DbRoot)\jp_mdm\02_indexes\001_ix_jp_mdm_foreign_keys.sql

-- ---- seed: the five masters that are ours to define, then the approval level
-- ---- configuration. Geography, education and profile are Phase 2B.
-- ---- Levels come AFTER the masters: they reference RequestTypeId.
PRINT '  Seed ...';
GO
:r $(DbRoot)\jp_mdm\03_seed\001_seed_approval_masters.sql
:r $(DbRoot)\jp_mdm\03_seed\002_seed_request_levels.sql
:r $(DbRoot)\jp_mdm\03_seed\003_seed_geography.sql
:r $(DbRoot)\jp_mdm\03_seed\004_seed_education.sql
:r $(DbRoot)\jp_mdm\03_seed\005_seed_profile.sql
:r $(DbRoot)\jp_mdm\03_seed\006_seed_provisional_masters.sql
:r $(DbRoot)\jp_mdm\03_seed\007_seed_provisional_documents.sql
:r $(DbRoot)\jp_mdm\03_seed\008_seed_plans.sql
:r $(DbRoot)\jp_mdm\03_seed\009_seed_languages.sql

-- Phase 2.5. 🔴 Every feature seeds FREE and NO plan mappings are created, so
-- shipping the engine changes nothing anyone can see.
:r $(DbRoot)\jp_mdm\03_seed\010_seed_features.sql

-- ---- programmability: IST functions first, then USP_LogError which every
-- ---- other procedure calls from its CATCH block, then the approval engine.
PRINT '  Functions and procedures ...';
GO
:r $(DbRoot)\jp_mdm\04_procedures\000_USP_LogError.sql
:r $(DbRoot)\jp_mdm\04_procedures\000_fn_datetime_ist.sql
:r $(DbRoot)\jp_mdm\04_procedures\001_approval_submit.sql
:r $(DbRoot)\jp_mdm\04_procedures\002_approval_action.sql
:r $(DbRoot)\jp_mdm\04_procedures\003_approval_reads.sql
:r $(DbRoot)\jp_mdm\04_procedures\004_documents_masters.sql
:r $(DbRoot)\jp_mdm\04_procedures\005_document_lookup.sql
:r $(DbRoot)\jp_mdm\04_procedures\006_reconciliation.sql
:r $(DbRoot)\jp_mdm\04_procedures\007_registration_drafts.sql
:r $(DbRoot)\jp_mdm\04_procedures\008_plans.sql

-- Phase 2.5 — the consume path's resolution query, and the admin matrix.
:r $(DbRoot)\jp_mdm\04_procedures\009_entitlement_catalog.sql


/*==============================================================================
  DB 3 — jp_app  (business: schools, teachers, jobs, applications, CMS)
==============================================================================*/
PRINT '';
PRINT '--- jp_app -------------------------------------------------------------------';
GO

:r $(DbRoot)\jp_app\00_create_database.sql

-- ⚠️ PHASE 2D pulled two of these forward from Phase 3: the cross-database
-- step after an approval needs a real place to write. Phase 3 adds the rest.
PRINT '  Tables ...';
GO
:r $(DbRoot)\jp_app\01_tables\001_t_app_schools.sql
:r $(DbRoot)\jp_app\01_tables\002_t_app_error_log.sql
:r $(DbRoot)\jp_app\01_tables\003_t_app_school_branches.sql
:r $(DbRoot)\jp_app\01_tables\004_t_app_subscriptions.sql

-- PHASE 3A — the deferred columns on the two tables 2D and 2F pulled forward.
-- The CREATE scripts above are NOT edited (Block D of _TEMPLATE_table.sql):
-- editing them would erase the record of what was pulled forward and why.
:r $(DbRoot)\jp_app\01_tables\005_alter_t_app_schools_suspension.sql
:r $(DbRoot)\jp_app\01_tables\006_alter_t_app_school_branches_deferred.sql

-- PHASE 3A — school side. Photos and facilities reference branches, so they
-- come after 003.
:r $(DbRoot)\jp_app\01_tables\007_t_app_school_photos.sql
:r $(DbRoot)\jp_app\01_tables\008_t_app_school_facilities.sql
:r $(DbRoot)\jp_app\01_tables\009_t_app_school_users.sql
:r $(DbRoot)\jp_app\01_tables\010_t_app_school_user_branches.sql

-- PHASE 3A — teacher side. The header first: every table below it has a
-- foreign key to t_app_teachers, so dependency order is not optional here.
:r $(DbRoot)\jp_app\01_tables\011_t_app_teachers.sql
:r $(DbRoot)\jp_app\01_tables\012_t_app_teacher_subjects.sql
:r $(DbRoot)\jp_app\01_tables\013_t_app_teacher_class_levels.sql
:r $(DbRoot)\jp_app\01_tables\014_t_app_teacher_skills.sql
:r $(DbRoot)\jp_app\01_tables\015_t_app_teacher_languages.sql
:r $(DbRoot)\jp_app\01_tables\016_t_app_teacher_preferred_locations.sql
:r $(DbRoot)\jp_app\01_tables\017_t_app_teacher_documents.sql
:r $(DbRoot)\jp_app\01_tables\018_t_app_teacher_experiences.sql

-- Phase 3G. A team list identified only by email address is unreadable.
:r $(DbRoot)\jp_app\01_tables\019_alter_t_app_school_users_fullname.sql

-- Phase 2.5 — the append-only entitlement ledger and its three masters.
:r $(DbRoot)\jp_app\01_tables\020_entitlement_ledger.sql

-- ---- seed / backfill --------------------------------------------------------
-- ⚠️ The Phase 3B backfill is a ONE-TIME migration rather than a seed that
-- shapes the schema. It is listed here so a database rebuilt from scratch ends
-- up in the same state, and it is safe to replay: a second pass reports
-- 0 created in every category.
PRINT '  Backfill ...';
GO
:r $(DbRoot)\jp_app\03_seed\001_backfill_phase3b.sql
-- PHASE 3C — the school owner rows nothing ever wrote (2.53).
-- ⚠️ NOT run from here: it EXECs USP_ProvisionSchoolOwner, which is created in
-- the 04_procedures section below. On a database built from scratch this line
-- would fail on a procedure that does not exist yet.
-- Run it by hand after a full rebuild:
--   sqlcmd -S localhost\TARUN -E -I -i database\jp_app\03_seed\002_backfill_phase3c_owners.sql
-- :r $(DbRoot)\jp_app\03_seed\002_backfill_phase3c_owners.sql

PRINT '  Functions and procedures ...';
GO
-- Phase 2.5. 🔴 FIRST — fn_QuotaPeriodForUtc is SCHEMABOUND to fn_IstDateToUtc.
-- A copy of jp_sso's file; the master lives there and all three must agree.
:r $(DbRoot)\jp_app\04_procedures\000_fn_datetime_ist.sql
:r $(DbRoot)\jp_app\04_procedures\000_USP_LogError.sql
:r $(DbRoot)\jp_app\04_procedures\001_provisioning.sql

-- PHASE 3C. The scope resolver first: everything below joins to it.
:r $(DbRoot)\jp_app\04_procedures\002_provisioning_accounts.sql
:r $(DbRoot)\jp_app\04_procedures\003_scope_resolver.sql
:r $(DbRoot)\jp_app\04_procedures\004_school_profile.sql
:r $(DbRoot)\jp_app\04_procedures\005_school_photos_facilities.sql
:r $(DbRoot)\jp_app\04_procedures\006_branches.sql

-- PHASE 3D — teacher side. The profile file first: the bridges and the
-- experience procedures all EXEC USP_RecalculateTeacherProfile, which lives
-- in it, and fn_TeacherIdForUser is what every one of them resolves through.
:r $(DbRoot)\jp_app\04_procedures\007_teacher_profile.sql
:r $(DbRoot)\jp_app\04_procedures\008_teacher_bridges.sql
:r $(DbRoot)\jp_app\04_procedures\009_teacher_experiences_documents.sql
:r $(DbRoot)\jp_app\04_procedures\010_teacher_public_profile.sql

-- Phase 3G — school team management.
:r $(DbRoot)\jp_app\04_procedures\011_school_team.sql

-- Phase 3I. The one thing neither dashboard could read from anywhere else.
:r $(DbRoot)\jp_app\04_procedures\012_subscription.sql

-- Phase 2.5 — the entitlement engine. Reads the subscription 012 exposes, and
-- locks the same row to make the consume atomic.
:r $(DbRoot)\jp_app\04_procedures\013_entitlement.sql


/*==============================================================================
  DONE
==============================================================================*/
PRINT '';
PRINT '===============================================================================';
PRINT ' BUILD COMPLETE — ' + CONVERT(varchar(30), SYSUTCDATETIME(), 126) + ' (UTC)';
PRINT '===============================================================================';
PRINT '';
GO
