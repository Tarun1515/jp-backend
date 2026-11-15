/*==============================================================================
  jp_app — 039_alter_teacher_address_columns.sql

  THE TEACHER'S OWN LOCATION GETS THE SAME CHAIN THE SCHOOL HAS.

  Client instruction, 15 November 2026: a teacher's address must offer
  State -> District -> City/Town -> Tehsil/Sub-tehsil -> Area or village,
  exactly as the school registration form does.

  ---------------------------------------------------------------------------
  🔴 WHAT WAS THERE, AND WHY THE TEACHER WAS LEFT OUT OF 036
  ---------------------------------------------------------------------------
  Measured before writing this file:

      t_app_schools    AddressLine1, AddressLine2, StateId, DistrictId,
                       CityId, TehsilId, AreaOrVillage, Pincode   (8)
      t_app_teachers   CurrentStateId, CurrentCityId              (2)

  036_alter_address_columns.sql gave the chain to schools, to branches and to
  teacher PREFERRED LOCATIONS, and deliberately not to the teacher row. Its own
  header says every table carrying an address "gains the same facts, so that one
  address shape exists rather than two" — and then the teacher's own address was
  the one table that did not.

  The consequence reached the screen. The teacher profile's cascade rendered
  State -> District -> City and stopped, with DISTRICT NOT STORED AT ALL: it was
  reconstructed from the saved city on every re-open (`districtOfCity`), which
  works only because a city has exactly one district. A tehsil picker was then
  added to the preferred-location rows, where the column did exist — and the
  table type that carries the save did not, so the value was accepted on screen
  and dropped silently. That is the failure this file closes properly rather
  than by deleting the control.

  ---------------------------------------------------------------------------
  🔴 THREE COLUMNS, AND DISTRICT IS ONE OF THEM
  ---------------------------------------------------------------------------
      CurrentDistrictId     stored, not derived
      CurrentTehsilId       the new level
      CurrentAreaOrVillage  free text, for places in no list

  ⚠️ DISTRICT IS STORED EVEN THOUGH IT COULD STILL BE DERIVED. Deriving it was
  defensible while the chain ended at the town; it is not defensible under a
  tehsil, because the tehsil is the level BETWEEN them and a derived parent
  cannot be checked against a stored child. Storing it also makes the teacher's
  address the same shape as the school's, which is the whole instruction.

  ⚠️ NOT ADDED, AND SAID SO PLAINLY: Pincode and AddressLine1/2. The client
  asked for "state district city tehsil area". A teacher's street address and
  pincode are a different and more sensitive fact than a school's — a school
  address is published on every job advert, a teacher's home address is not —
  and nothing in the product searches on them. If they are wanted, they are one
  more migration of exactly this shape.

  ---------------------------------------------------------------------------
  🔴 EVERY COLUMN NULLABLE, NOTHING BACKFILLED
  ---------------------------------------------------------------------------
  Same reasoning as 036: an existing teacher has no tehsil because nobody ever
  asked them. NULL says that. A backfill would have to invent it.

  ⚠️ AND CurrentDistrictId IS NOT BACKFILLED FROM CurrentCityId EITHER, even
  though that derivation is exactly what the screen has been doing. The screen
  may derive for display; the column must mean "what the teacher told us". A
  backfill would make a value nobody entered indistinguishable from one they
  did, and the first time a city's district is corrected in the master, the
  backfilled rows would be silently wrong.

  ---------------------------------------------------------------------------
  🔴 NO FOREIGN KEYS INTO jp_mdm — 2.2, NOT AN OVERSIGHT
  ---------------------------------------------------------------------------
  The district and tehsil masters live in jp_mdm. CurrentCityId and
  CurrentStateId on this same table have no foreign keys either, for the same
  reason: the databases are separate and not joined across. The ids are
  validated by the procedure that writes them.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*
  ⚠️ GUARDED PER COLUMN, NOT PER TABLE. 020_m_mdm_document_types.sql records
  what a table-level guard costs: a table was created, its index failed, and on
  re-run the exists-check skipped the whole block, leaving it permanently
  unindexed (2.29). Three separate guards means a half-applied run completes
  itself on the next pass.
*/
IF NOT EXISTS (SELECT 1 FROM sys.columns
                WHERE object_id = OBJECT_ID('dbo.t_app_teachers') AND name = 'CurrentDistrictId')
BEGIN
    PRINT '    Adding [CurrentDistrictId] to [t_app_teachers] ...';

    ALTER TABLE dbo.t_app_teachers ADD CurrentDistrictId int NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns
                WHERE object_id = OBJECT_ID('dbo.t_app_teachers') AND name = 'CurrentTehsilId')
BEGIN
    PRINT '    Adding [CurrentTehsilId] to [t_app_teachers] ...';

    ALTER TABLE dbo.t_app_teachers ADD CurrentTehsilId int NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns
                WHERE object_id = OBJECT_ID('dbo.t_app_teachers') AND name = 'CurrentAreaOrVillage')
BEGIN
    PRINT '    Adding [CurrentAreaOrVillage] to [t_app_teachers] ...';

    /*
      nvarchar(200) — the same width as t_app_schools.AreaOrVillage and
      t_mdm_school_registration_details.AreaOrVillage. One fact, one width:
      a narrower column here would truncate a place name that the school side
      accepts, which is the kind of difference nobody discovers until a village
      name is cut in half on somebody's profile.
    */
    ALTER TABLE dbo.t_app_teachers ADD CurrentAreaOrVillage nvarchar(200) NULL;
END
GO

PRINT '    Teacher address columns ready.';
GO
