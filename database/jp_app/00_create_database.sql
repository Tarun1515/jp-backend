/*==============================================================================
  jp_app — 00_create_database.sql

  DB 3 of 3 — BUSINESS DATA.
  Schools, branches, teachers, jobs, applications, offers, invites,
  notifications, reports/moderation, CMS and support tables.

  References jp_sso users by UserUid and jp_mdm masters by synonym.
  No physical foreign key ever crosses a database boundary.

  Idempotent — safe to re-run.
  Target: SQL Server 2019 (15.0).
==============================================================================*/

IF DB_ID('jp_app') IS NULL
BEGIN
    PRINT '  Creating database [jp_app] ...';
    CREATE DATABASE jp_app COLLATE SQL_Latin1_General_CP1_CI_AS;
END
ELSE
BEGIN
    PRINT '  Database [jp_app] already exists — creation skipped.';
END
GO

ALTER DATABASE jp_app SET COMPATIBILITY_LEVEL = 150;
GO

IF EXISTS (SELECT 1 FROM sys.databases WHERE name = 'jp_app' AND is_read_committed_snapshot_on = 0)
BEGIN
    PRINT '  Enabling READ_COMMITTED_SNAPSHOT on [jp_app] ...';
    ALTER DATABASE jp_app SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
END
GO

ALTER DATABASE jp_app SET AUTO_CLOSE OFF;
ALTER DATABASE jp_app SET AUTO_SHRINK OFF;
ALTER DATABASE jp_app SET AUTO_CREATE_STATISTICS ON;
ALTER DATABASE jp_app SET AUTO_UPDATE_STATISTICS ON;
GO

ALTER DATABASE jp_app SET RECOVERY SIMPLE;
GO

USE jp_app;
GO

PRINT '  [jp_app] ready.';
GO
