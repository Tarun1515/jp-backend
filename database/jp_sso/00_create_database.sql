/*==============================================================================
  jp_sso — 00_create_database.sql

  DB 1 of 3 — IDENTITY ONLY.
  Users, credentials, tokens, OTP, login attempts, lockouts, roles, permissions.

  This database knows NOTHING about schools or teachers. It sees only
  UserTypeId and an opaque OrganizationUid (uniqueidentifier).

  Idempotent — safe to re-run.
  Target: SQL Server 2019 (15.0). Compatibility level is pinned to 150 so that
  2022+ only syntax fails here instead of in production.
==============================================================================*/

IF DB_ID('jp_sso') IS NULL
BEGIN
    PRINT '  Creating database [jp_sso] ...';
    CREATE DATABASE jp_sso COLLATE SQL_Latin1_General_CP1_CI_AS;
END
ELSE
BEGIN
    PRINT '  Database [jp_sso] already exists — creation skipped.';
END
GO

-- Pin to SQL Server 2019. Guards against accidental use of 2022+ T-SQL.
ALTER DATABASE jp_sso SET COMPATIBILITY_LEVEL = 150;
GO

-- Read Committed Snapshot: readers never block writers. Standard for a web app.
-- Guarded because WITH ROLLBACK IMMEDIATE disconnects active sessions.
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = 'jp_sso' AND is_read_committed_snapshot_on = 0)
BEGIN
    PRINT '  Enabling READ_COMMITTED_SNAPSHOT on [jp_sso] ...';
    ALTER DATABASE jp_sso SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
END
GO

ALTER DATABASE jp_sso SET AUTO_CLOSE OFF;
ALTER DATABASE jp_sso SET AUTO_SHRINK OFF;
ALTER DATABASE jp_sso SET AUTO_CREATE_STATISTICS ON;
ALTER DATABASE jp_sso SET AUTO_UPDATE_STATISTICS ON;
GO

-- Development default. Production deployment must switch this to FULL and
-- configure log backups.
ALTER DATABASE jp_sso SET RECOVERY SIMPLE;
GO

USE jp_sso;
GO

-- Filtered indexes REQUIRE these. sqlcmd defaults QUOTED_IDENTIFIER to OFF
-- (SSMS defaults it ON), so without this every CREATE INDEX with a WHERE
-- clause fails with Msg 1934 — and so does any later INSERT into the table.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

PRINT '  [jp_sso] ready.';
GO
