/*==============================================================================
  jp_mdm — 00_create_database.sql

  DB 2 of 3 — MASTER DATA + APPROVAL ENGINE.
  All m_mdm_* masters, the approval request/level/action tables, registration
  payload tables, request documents and payments.

  Cross-database references are by uniqueidentifier Uid only — never a physical
  foreign key. jp_app reaches masters here via CREATE SYNONYM, never by copying.

  Idempotent — safe to re-run.
  Target: SQL Server 2019 (15.0).
==============================================================================*/

IF DB_ID('jp_mdm') IS NULL
BEGIN
    PRINT '  Creating database [jp_mdm] ...';
    CREATE DATABASE jp_mdm COLLATE SQL_Latin1_General_CP1_CI_AS;
END
ELSE
BEGIN
    PRINT '  Database [jp_mdm] already exists — creation skipped.';
END
GO

ALTER DATABASE jp_mdm SET COMPATIBILITY_LEVEL = 150;
GO

IF EXISTS (SELECT 1 FROM sys.databases WHERE name = 'jp_mdm' AND is_read_committed_snapshot_on = 0)
BEGIN
    PRINT '  Enabling READ_COMMITTED_SNAPSHOT on [jp_mdm] ...';
    ALTER DATABASE jp_mdm SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
END
GO

ALTER DATABASE jp_mdm SET AUTO_CLOSE OFF;
ALTER DATABASE jp_mdm SET AUTO_SHRINK OFF;
ALTER DATABASE jp_mdm SET AUTO_CREATE_STATISTICS ON;
ALTER DATABASE jp_mdm SET AUTO_UPDATE_STATISTICS ON;
GO

ALTER DATABASE jp_mdm SET RECOVERY SIMPLE;
GO

USE jp_mdm;
GO

PRINT '  [jp_mdm] ready.';
GO
