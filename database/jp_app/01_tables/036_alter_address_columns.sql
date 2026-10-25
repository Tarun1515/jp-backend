/*==============================================================================
  jp_app — 036_alter_address_columns.sql

  SCHOOL REVAMP (SR-1). The address columns on the jp_app side.

  Designed in ADDRESS_DESIGN.md (SR-0) §3.3. Every table that carries an
  address gains the same facts, so that one address shape exists rather than
  two.

  ---------------------------------------------------------------------------
  🔴 EVERY NEW COLUMN IS NULLABLE, AND NOTHING IS BACKFILLED
  ---------------------------------------------------------------------------
  An existing school has no tehsil, no coordinates and no Google place id —
  not because the row is broken, but because nobody was ever asked. NULL says
  that honestly. A backfill would have to invent the value, and an invented
  coordinate is worse than an absent one: it puts a school on a map at a place
  it is not.

  ⚠️ AreaOrVillage is NOT derived from AddressLine2. They are different facts.
  "Near the bus stand" is an address line; "Barwala" is a place. Copying one
  into the other would put text nobody typed into a field the product will
  later search on.

  ---------------------------------------------------------------------------
  ⚠️ t_app_school_branches ALREADY HAS Latitude AND Longitude
  ---------------------------------------------------------------------------
  Since 3C, unused. This file gives them their first consumer rather than
  adding a second pair beside them — measured before writing, because two
  columns holding the same fact is how a table starts lying.

  ---------------------------------------------------------------------------
  t_app_jobs DELIBERATELY GETS NOTHING
  ---------------------------------------------------------------------------
  A job's location is its branch's location. Jobs carry CityId/StateId as a
  denormalised copy for search; coordinates there would be a third place the
  same fact lives. If map search ever needs them, they come from the branch.

  ---------------------------------------------------------------------------
  🔴 NO FOREIGN KEY ON TehsilId FROM jp_app — AND THAT IS 2.2, NOT AN OVERSIGHT
  ---------------------------------------------------------------------------
  The tehsil master lives in jp_mdm. jp_app does not have foreign keys into
  jp_mdm — CityId, DistrictId and StateId have none either, for the same
  reason: the databases are separate and are not joined across (2.2). The id
  is validated by the procedure that writes it, exactly as the existing
  geography ids are.
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*------------------------------------------------------------------ schools */
IF NOT EXISTS (SELECT 1 FROM sys.columns
                WHERE object_id = OBJECT_ID('dbo.t_app_schools') AND name = 'TehsilId')
BEGIN
    PRINT '    Adding address columns to [t_app_schools] ...';

    ALTER TABLE dbo.t_app_schools ADD
        TehsilId        int             NULL,
        AreaOrVillage   nvarchar(200)   NULL,
        Latitude        decimal(9, 6)   NULL,
        Longitude       decimal(9, 6)   NULL,
        GooglePlaceId   varchar(120)    NULL;
END
ELSE
BEGIN
    PRINT '    [t_app_schools] address columns already present.';
END
GO

/*
  🔴 AND THE PRINCIPAL'S MOBILE, WHICH WAS COLLECTED AND THROWN AWAY.

  SR-0's field matrix found it: registration asks for PrincipalMobile, the
  registration record stores it, and USP_ProvisionSchool does not have the
  parameter at all — so on approval the number is left behind in jp_mdm and
  the school's profile has no way to show it. A school approved in September
  has a principal nobody can ring.

  PrincipalName was carried across. PrincipalMobile was not. Nothing reported
  it because nothing looked.

  ⚠️ This column is the destination for the client's decision to move the
  principal's details OUT of registration and INTO the profile. The move needs
  somewhere to move TO, and that is here.
*/
IF NOT EXISTS (SELECT 1 FROM sys.columns
                WHERE object_id = OBJECT_ID('dbo.t_app_schools') AND name = 'PrincipalMobile')
BEGIN
    PRINT '    Adding [t_app_schools].PrincipalMobile (SR-0 finding) ...';

    ALTER TABLE dbo.t_app_schools ADD PrincipalMobile varchar(15) NULL;
END
ELSE
BEGIN
    PRINT '    [t_app_schools].PrincipalMobile already present.';
END
GO

/*----------------------------------------------------------------- branches */
IF NOT EXISTS (SELECT 1 FROM sys.columns
                WHERE object_id = OBJECT_ID('dbo.t_app_school_branches') AND name = 'TehsilId')
BEGIN
    PRINT '    Adding address columns to [t_app_school_branches] ...';

    /* ⚠️ No Latitude/Longitude here — the table has had them since 3C. */
    ALTER TABLE dbo.t_app_school_branches ADD
        TehsilId        int             NULL,
        AreaOrVillage   nvarchar(200)   NULL,
        GooglePlaceId   varchar(120)    NULL;
END
ELSE
BEGIN
    PRINT '    [t_app_school_branches] address columns already present.';
END
GO

/*------------------------------------------- teacher preferred locations --- */
IF NOT EXISTS (SELECT 1 FROM sys.columns
                WHERE object_id = OBJECT_ID('dbo.t_app_teacher_preferred_locations') AND name = 'TehsilId')
BEGIN
    PRINT '    Adding [t_app_teacher_preferred_locations].TehsilId ...';

    /*
      A teacher saying "anywhere in Hisar tehsil" is a narrower and more
      useful preference than "Hisar district". Nullable and unread for now —
      SR-3 lands the picker; this is the column it writes to.
    */
    ALTER TABLE dbo.t_app_teacher_preferred_locations ADD TehsilId int NULL;
END
ELSE
BEGIN
    PRINT '    [t_app_teacher_preferred_locations].TehsilId already present.';
END
GO

/*==============================================================================
  BUILD GUARD — the coordinate columns must be one shape everywhere
==============================================================================*/

/*
  🔴 A LATITUDE THAT IS decimal(9,6) IN ONE TABLE AND decimal(5,2) IN ANOTHER
  IS A ROUNDING BUG WITH A SCHEMA.

  3C's branch columns were written before this file existed. If they are a
  different precision from the ones added here, the same place stored in two
  tables comes back as two different points — and the difference shows up as a
  school being a few hundred metres from itself.

  decimal(9,6) is the shape chosen: six decimal places is about 11cm, which is
  far finer than any address needs, and 9 total digits leaves room for three
  before the point (-180 to 180).

  Proven to fire: altering the branch Latitude to decimal(8,5) fails this with
  both precisions named.
*/
DECLARE @shape nvarchar(1000) = N'';

SELECT @shape = STRING_AGG(
           CAST(OBJECT_NAME(c.object_id) AS nvarchar(128)) + N'.' + CAST(c.name AS nvarchar(128))
         + N' is decimal(' + CAST(c.precision AS nvarchar(5)) + N',' + CAST(c.scale AS nvarchar(5)) + N')', N', ')
  FROM sys.columns c
 WHERE c.name IN ('Latitude', 'Longitude')
   AND OBJECTPROPERTY(c.object_id, 'IsUserTable') = 1
   AND NOT (c.precision = 9 AND c.scale = 6);

IF ISNULL(@shape, N'') <> N''
BEGIN
    DECLARE @msg nvarchar(1400) =
        N'036_alter_address_columns: 🔴 A COORDINATE COLUMN IS NOT decimal(9,6): '
        + @shape
        + N'. The same place stored in two precisions comes back as two different points, and a school ends up a few hundred metres from itself. Every Latitude/Longitude in jp_app is decimal(9,6) — about 11cm, finer than any address needs.';

    RAISERROR('%s', 16, 1, @msg);
END
GO

PRINT '    jp_app address columns ready.';
GO
