/*==============================================================================
  jp_app — 016_t_app_teacher_preferred_locations.sql

  Where a teacher is willing to work.

  ---------------------------------------------------------------------------
  ⚠️ CityId IS NULLABLE, AND THAT IS NOT A COMPROMISE
  ---------------------------------------------------------------------------
  The city dataset has not been imported (decision 2.47), and the registration
  forms already degrade to state-only because of it. A teacher today can say
  "anywhere in Maharashtra" and nothing more precise, so a NOT NULL CityId would
  make this table unusable on the day it ships.

  It stays nullable afterwards too: "anywhere in this state" is a real
  preference and not a placeholder for one, and a teacher who genuinely means it
  should not have to name twelve cities to say so.

  StateId is NOT NULL — a preference with neither a state nor a city says
  nothing at all.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_app_teacher_preferred_locations' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_app_teacher_preferred_locations] ...';

    CREATE TABLE dbo.t_app_teacher_preferred_locations
    (
        Id              bigint      IDENTITY(1,1) NOT NULL,
        TeacherId       bigint      NOT NULL,

        /*
          ⚠️ CROSS-DATABASE — m_mdm_city and m_mdm_state in jp_mdm. No foreign
          keys (decision 2.2); both int, verified against the live columns.
        */
        CityId          int         NULL,
        StateId         int         NOT NULL,

        /*
          1 is the first choice. Not unique per teacher on purpose: two equally
          acceptable cities are a real answer, and forcing a strict ranking
          would make somebody invent a preference they do not have.
        */
        PreferenceOrder int         NOT NULL CONSTRAINT DF_t_app_teacher_preferred_locations_PreferenceOrder DEFAULT (0),

        -- ---- standard columns -------------------------------------------------
        Is_Active       tinyint     NOT NULL CONSTRAINT DF_t_app_teacher_preferred_locations_Is_Active  DEFAULT (1),
        Is_Deleted      tinyint     NOT NULL CONSTRAINT DF_t_app_teacher_preferred_locations_Is_Deleted DEFAULT (0),
        CreatedOn       datetime2   NOT NULL CONSTRAINT DF_t_app_teacher_preferred_locations_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy       bigint      NULL,
        ModifiedOn      datetime2   NULL,
        ModifiedBy      bigint      NULL,

        CONSTRAINT PK_t_app_teacher_preferred_locations PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_t_app_teacher_preferred_locations_t_app_teachers
            FOREIGN KEY (TeacherId) REFERENCES dbo.t_app_teachers (TeacherId),
        CONSTRAINT CK_t_app_teacher_preferred_locations_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_app_teacher_preferred_locations_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [t_app_teacher_preferred_locations] already exists — skipped.';
END
GO
/*------------------------------------------------------------------------------
  🔴 ONE PLACE, ONCE PER TEACHER.

  Three columns rather than two, because a "place" here is a state OR a city
  within one.

  ⚠️ SQL Server treats NULLs as EQUAL inside a unique index, which is what is
  wanted: (TeacherId, NULL, Maharashtra) can appear only once, so "anywhere in
  Maharashtra" cannot be recorded twice — while Pune and Nagpur under the same
  state remain two distinct rows.

  PreferenceOrder is deliberately NOT part of the key. It is how the teacher
  ranks the list, and including it would let the same city be added twice with
  different ranks.

  🔴 Guarded separately from the table (decision 2.29).
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_app_teacher_preferred_locations_TeacherId_CityId_StateId'
                 AND object_id = OBJECT_ID('dbo.t_app_teacher_preferred_locations'))
BEGIN
    PRINT '    Creating index [UQ_t_app_teacher_preferred_locations_TeacherId_CityId_StateId] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_app_teacher_preferred_locations_TeacherId_CityId_StateId
        ON dbo.t_app_teacher_preferred_locations (TeacherId, CityId, StateId)
        WHERE Is_Deleted = 0;
END
GO
/*------------------------------------------------------------------------------
  🔴 The match that makes this table worth having: "which teachers would work
  here" when a school posts a job.

  State first because it is the column that is always populated — a
  city-leading index would skip every teacher who only named a state, which is
  currently all of them.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_teacher_preferred_locations_StateId_CityId'
                 AND object_id = OBJECT_ID('dbo.t_app_teacher_preferred_locations'))
BEGIN
    PRINT '    Creating index [IX_t_app_teacher_preferred_locations_StateId_CityId] ...';

    CREATE NONCLUSTERED INDEX IX_t_app_teacher_preferred_locations_StateId_CityId
        ON dbo.t_app_teacher_preferred_locations (StateId, CityId)
        INCLUDE (TeacherId, PreferenceOrder)
        WHERE Is_Deleted = 0;
END
GO
/*------------------------------------------------------------------------------
  The teacher's own list, in the order they put it in.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_teacher_preferred_locations_TeacherId'
                 AND object_id = OBJECT_ID('dbo.t_app_teacher_preferred_locations'))
BEGIN
    PRINT '    Creating index [IX_t_app_teacher_preferred_locations_TeacherId] ...';

    CREATE NONCLUSTERED INDEX IX_t_app_teacher_preferred_locations_TeacherId
        ON dbo.t_app_teacher_preferred_locations (TeacherId, PreferenceOrder)
        INCLUDE (CityId, StateId)
        WHERE Is_Deleted = 0;
END
GO
