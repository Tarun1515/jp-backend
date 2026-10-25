/*==============================================================================
  jp_mdm — 039_m_mdm_tehsil.sql

  SCHOOL REVAMP (SR-1). The level between district and city, plus the columns
  that let an address carry a place no master row contains.

  Designed in ADDRESS_DESIGN.md (SR-0). The short version:

    Country -> State -> District -> Tehsil (optional) -> City/Village

  ---------------------------------------------------------------------------
  🔴 WHY TEHSIL IS A MASTER AND "AREA" IS NOT
  ---------------------------------------------------------------------------
  A tehsil is an administrative unit: enumerable, stable, published by the
  state, and two people naming one write the same word. That is what a master
  table is for.

  An area, mohalla, colony or village name is none of those. No authoritative
  list exists, new colonies appear constantly, and the same place is written
  five ways. A master there would be a table we are permanently behind on and
  a dropdown that never holds what the user wants — G40's "half a list is
  worse than no list", one level down. So area is free text on the address.

  ---------------------------------------------------------------------------
  ⚠️ CITY KEEPS ITS DistrictId. THE TEHSIL DOES NOT REPLACE IT.
  ---------------------------------------------------------------------------
  It is tempting to reach the district through the tehsil and drop the column.
  Two reasons not to:

    1. Tehsil is OPTIONAL on a city. A city whose tehsil we do not know would
       then have no district either — and district is the level the product
       actually filters on.
    2. Every existing read joins city to district today. Removing the column
       turns a data addition into a rewrite of working, tested code.

  The cost is one denormalised relationship, and the rule that pays for it is
  the build guard at the bottom: a city's tehsil, when set, MUST belong to that
  city's district. Asserted, not hoped for.
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'm_mdm_tehsil' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [m_mdm_tehsil] ...';

    CREATE TABLE dbo.m_mdm_tehsil
    (
        /*
          🔴 NOT AN IDENTITY — the same rule m_mdm_state, m_mdm_district and
          m_mdm_city follow, and for a reason that bites across databases.

          jp_app stores TehsilId with no foreign key (2.2: the databases are
          not joined). If this id were generated, a fresh build could assign
          different numbers from the ones a live jp_app already points at, and
          every stored address would silently move to another tehsil. Seeds
          assign the id explicitly so it is the same on every machine.
        */
        TehsilId        int             NOT NULL,

        /*
          🔴 THE CONTRACT (2.47). FKs and seeds resolve by this and it never
          changes on a live row. Name is display text the client may edit.
        */
        Code            varchar(60)     NOT NULL,
        Name            nvarchar(300)   NOT NULL,

        DistrictId      int             NOT NULL,

        /*
          A revenue tehsil and a sub-tehsil are both places a school will say
          it is in, and the distinction does not matter to the person typing an
          address. Both are rows here; this records which is which so the
          client can see what they are approving, and so DisplayOrder can put
          full tehsils first.
        */
        IsSubTehsil     tinyint         NOT NULL
            CONSTRAINT DF_m_mdm_tehsil_IsSubTehsil DEFAULT (0),

        DisplayOrder    int             NOT NULL
            CONSTRAINT DF_m_mdm_tehsil_DisplayOrder DEFAULT (0),

        Is_Active       tinyint         NOT NULL CONSTRAINT DF_m_mdm_tehsil_Is_Active  DEFAULT (1),
        Is_Deleted      tinyint         NOT NULL CONSTRAINT DF_m_mdm_tehsil_Is_Deleted DEFAULT (0),
        CreatedOn       datetime2       NOT NULL CONSTRAINT DF_m_mdm_tehsil_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy       bigint          NULL,
        ModifiedOn      datetime2       NULL,
        ModifiedBy      bigint          NULL,

        CONSTRAINT PK_m_mdm_tehsil PRIMARY KEY CLUSTERED (TehsilId),
        CONSTRAINT FK_m_mdm_tehsil_District
            FOREIGN KEY (DistrictId) REFERENCES dbo.m_mdm_district (DistrictId),
        CONSTRAINT CK_m_mdm_tehsil_IsSubTehsil CHECK (IsSubTehsil IN (0, 1)),
        CONSTRAINT CK_m_mdm_tehsil_Is_Active   CHECK (Is_Active   IN (0, 1)),
        CONSTRAINT CK_m_mdm_tehsil_Is_Deleted  CHECK (Is_Deleted  IN (0, 1))
    );

    PRINT '    [m_mdm_tehsil] created.';
END
ELSE
BEGIN
    PRINT '    [m_mdm_tehsil] already exists.';
END
GO

/* Code is the identifier, so it is unique among live rows. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'UQ_m_mdm_tehsil_Code' AND object_id = OBJECT_ID('dbo.m_mdm_tehsil'))
BEGIN
    CREATE UNIQUE NONCLUSTERED INDEX UQ_m_mdm_tehsil_Code
        ON dbo.m_mdm_tehsil (Code)
        WHERE Is_Deleted = 0;

    PRINT '    UQ_m_mdm_tehsil_Code created.';
END
GO

/* The only read pattern: the tehsils of one district, in display order. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'IX_m_mdm_tehsil_District' AND object_id = OBJECT_ID('dbo.m_mdm_tehsil'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_m_mdm_tehsil_District
        ON dbo.m_mdm_tehsil (DistrictId, DisplayOrder)
        INCLUDE (Code, Name, IsSubTehsil)
        WHERE Is_Deleted = 0;

    PRINT '    IX_m_mdm_tehsil_District created.';
END
GO

/*==============================================================================
  m_mdm_city gains a tehsil
==============================================================================*/

IF NOT EXISTS (SELECT 1 FROM sys.columns
                WHERE object_id = OBJECT_ID('dbo.m_mdm_city') AND name = 'TehsilId')
BEGIN
    PRINT '    Adding [m_mdm_city].TehsilId ...';

    /*
      NULLABLE, and it stays that way. A city whose tehsil we have not mapped
      is a city that still works — it has a district, which is what the
      product filters on.
    */
    ALTER TABLE dbo.m_mdm_city ADD TehsilId int NULL;
END
ELSE
BEGIN
    PRINT '    [m_mdm_city].TehsilId already present.';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_m_mdm_city_Tehsil')
BEGIN
    ALTER TABLE dbo.m_mdm_city
        ADD CONSTRAINT FK_m_mdm_city_Tehsil
            FOREIGN KEY (TehsilId) REFERENCES dbo.m_mdm_tehsil (TehsilId);

    PRINT '    FK_m_mdm_city_Tehsil created.';
END
GO

/*==============================================================================
  m_mdm_city.Code has to hold a district-qualified name
==============================================================================*/

/*
  🔴 varchar(30) WAS TOO NARROW, AND THE SEED IS WHAT PROVED IT.

  City codes are district-qualified so that two towns of the same name in two
  districts cannot collide — `HR_HISAR_BARWALA` and `HR_PANCHKULA_BARWALA`
  are genuinely different places, and Haryana has that exact pair.

  The longest Haryana code is 31 characters (HR_MAHENDRAGARH_NANGALCHAUDHARY),
  and the column was varchar(30). The seed failed with "String or binary data
  would be truncated", which is the good outcome: the alternative, on an older
  server, is a SILENTLY TRUNCATED code — and a truncated code is a permanent
  wrong identifier (2.47), not a display glitch.

  Widened to 60 to match m_mdm_tehsil.Code, which was written for the same
  shape. 60 holds a state prefix, a long district and a long town with room
  left; it is not an invitation to put sentences in a code.

  ⚠️ BOTH INDEXES ARE DROPPED AND REBUILT. SQL Server will not alter a column
  that an index depends on, and m_mdm_city has two on Code.
*/
IF EXISTS (SELECT 1 FROM sys.columns
            WHERE object_id = OBJECT_ID('dbo.m_mdm_city') AND name = 'Code' AND max_length < 60)
BEGIN
    PRINT '    Widening [m_mdm_city].Code to varchar(60) ...';

    DECLARE @uq sysname = (SELECT name FROM sys.indexes
                            WHERE object_id = OBJECT_ID('dbo.m_mdm_city') AND name = 'UQ_m_mdm_city_Code');

    DECLARE @ix sysname = (SELECT name FROM sys.indexes
                            WHERE object_id = OBJECT_ID('dbo.m_mdm_city') AND name = 'IX_m_mdm_city_DistrictId');

    IF @uq IS NOT NULL DROP INDEX UQ_m_mdm_city_Code ON dbo.m_mdm_city;
    IF @ix IS NOT NULL DROP INDEX IX_m_mdm_city_DistrictId ON dbo.m_mdm_city;

    ALTER TABLE dbo.m_mdm_city ALTER COLUMN Code varchar(60) NOT NULL;

    IF @uq IS NOT NULL
        CREATE UNIQUE NONCLUSTERED INDEX UQ_m_mdm_city_Code
            ON dbo.m_mdm_city (Code) WHERE Is_Deleted = 0;

    IF @ix IS NOT NULL
        CREATE NONCLUSTERED INDEX IX_m_mdm_city_DistrictId
            ON dbo.m_mdm_city (DistrictId, DisplayOrder) INCLUDE (Code, Name) WHERE Is_Deleted = 0;

    PRINT '    [m_mdm_city].Code widened, both indexes rebuilt.';
END
ELSE
BEGIN
    PRINT '    [m_mdm_city].Code is already wide enough.';
END
GO

/*==============================================================================
  The registration's own copy of the address
==============================================================================*/

/*
  t_mdm_school_registration_details holds what the school typed BEFORE
  approval. It gets the same five new facts as the live school, so that
  approval copies rather than invents.
*/
IF NOT EXISTS (SELECT 1 FROM sys.columns
                WHERE object_id = OBJECT_ID('dbo.t_mdm_school_registration_details') AND name = 'TehsilId')
BEGIN
    PRINT '    Adding address columns to [t_mdm_school_registration_details] ...';

    ALTER TABLE dbo.t_mdm_school_registration_details ADD
        TehsilId        int             NULL,
        AreaOrVillage   nvarchar(200)   NULL,
        Latitude        decimal(9, 6)   NULL,
        Longitude       decimal(9, 6)   NULL,
        GooglePlaceId   varchar(120)    NULL;
END
ELSE
BEGIN
    PRINT '    [t_mdm_school_registration_details] address columns already present.';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_t_mdm_school_registration_details_Tehsil')
BEGIN
    ALTER TABLE dbo.t_mdm_school_registration_details
        ADD CONSTRAINT FK_t_mdm_school_registration_details_Tehsil
            FOREIGN KEY (TehsilId) REFERENCES dbo.m_mdm_tehsil (TehsilId);

    PRINT '    FK_t_mdm_school_registration_details_Tehsil created.';
END
GO

/*==============================================================================
  BUILD GUARD — a city's tehsil must be in that city's district
==============================================================================*/

/*
  🔴 THE PRICE OF KEEPING DistrictId ON THE CITY.

  Two paths to the same district now exist: city -> district, and
  city -> tehsil -> district. The moment they disagree, the product has a city
  that is in two districts, and which one a reader gets depends on which join
  it happened to use. That is not a data-quality nicety; it is a city that
  appears under one district in search and another on the school's own page.

  Checked as DATA rather than enforced as a constraint, because a composite FK
  would require a unique index on (TehsilId, DistrictId) in the tehsil table —
  a second index whose only purpose is the constraint, on a table that is read
  constantly and written once a year.

  Proven to fire: pointing any Haryana city at a tehsil from another district
  fails this with both names.
*/
DECLARE @mismatch nvarchar(1000) = N'';

SELECT @mismatch = STRING_AGG(
           CAST(c.Name AS nvarchar(100)) + N' (city district ' + CAST(c.DistrictId AS nvarchar(10))
         + N', tehsil district ' + CAST(t.DistrictId AS nvarchar(10)) + N')', N', ')
  FROM dbo.m_mdm_city c
  JOIN dbo.m_mdm_tehsil t ON t.TehsilId = c.TehsilId
 WHERE c.Is_Deleted = 0
   AND t.Is_Deleted = 0
   AND c.DistrictId <> t.DistrictId;

IF ISNULL(@mismatch, N'') <> N''
BEGIN
    DECLARE @msg nvarchar(1400) =
        N'039_m_mdm_tehsil: 🔴 A CITY POINTS AT A TEHSIL IN A DIFFERENT DISTRICT: '
        + @mismatch
        + N'. The city keeps its own DistrictId on purpose (see the header), which means the two paths to a district must agree. If they do not, the same city appears under one district in search and another on the school''s page, and which one a reader sees depends on which join ran.';

    RAISERROR('%s', 16, 1, @msg);
END
GO

PRINT '    m_mdm_tehsil ready.';
GO
