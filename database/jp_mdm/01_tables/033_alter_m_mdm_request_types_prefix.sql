/*==============================================================================
  jp_mdm — 033_alter_m_mdm_request_types_prefix.sql

  Adds RequestNoPrefix to m_mdm_request_types.

  Introduced by Phase 2C. A request number looks like REG-SCH-2026-00001, and
  the SCH part has to come from somewhere. The alternative — a CASE on
  RequestTypeId inside USP_SubmitApprovalRequest — would put the mapping in
  code, where adding a fifth request type means editing a procedure rather than
  a row. Decision 2.13: no hardcoding.

  Block D of _TEMPLATE_table.sql: a deployed table is never edited in place.
  This is a separate numbered script with its own column guard, so run_all.sql
  stays replayable from scratch AND applies cleanly to an existing database.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.m_mdm_request_types') AND name = 'RequestNoPrefix')
BEGIN
    PRINT '    Adding column [m_mdm_request_types].[RequestNoPrefix] ...';

    -- Nullable: the seed fills it immediately, but a NOT NULL column added to a
    -- table that already has rows needs a default, and a default here would be
    -- a guess that silently survives.
    ALTER TABLE dbo.m_mdm_request_types
        ADD RequestNoPrefix varchar(10) NULL;
END
ELSE
BEGIN
    PRINT '    Column [m_mdm_request_types].[RequestNoPrefix] already exists — skipped.';
END
GO
