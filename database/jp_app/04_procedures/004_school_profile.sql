/*==============================================================================
  jp_app — 04_procedures / 004_school_profile.sql

  USP_GetSchoolProfile         the school's own view
  USP_GetSchoolPublicProfile   what a teacher sees — a SEPARATE procedure
  USP_UpdateSchoolProfile      RowVersion checked
  USP_SaveSchoolLogo
  USP_SaveSchoolPhotos         add, reorder, soft-delete
  USP_SaveSchoolFacilities     🔴 the bridge-sync pattern 3D follows

  Every procedure that touches one school takes @UserUid and checks membership
  through dbo.fn_IsSchoolMember. None of them take an organisation or a role
  from the caller — the API passes the Uid off the token (2.39) and this layer
  decides what it means.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  USP_GetSchoolProfile — the school's own view.

  Four result sets: the school, its branches, its photos, its facilities.
  Read procedure, so no transaction and no CATCH (Block B of the template).
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetSchoolProfile
    @SchoolId   bigint,
    @UserUid    uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;

    -- Not a member? Nothing at all, and deliberately not an error: the caller
    -- learns the same thing from a school that does not exist and one that is
    -- not theirs.
    IF dbo.fn_IsSchoolMember(@SchoolId, @UserUid) = 0
    BEGIN
        SELECT TOP (0) CAST(NULL AS bigint) AS SchoolId;
        SELECT TOP (0) CAST(NULL AS bigint) AS BranchId;
        SELECT TOP (0) CAST(NULL AS bigint) AS PhotoId;
        SELECT TOP (0) CAST(NULL AS int)    AS FacilityId;
        RETURN;
    END

    -- ---- 1. the school --------------------------------------------------
    SELECT
        s.SchoolId, s.SchoolUid, s.OrganizationUid,
        s.SchoolName, s.SchoolTypeId, s.BoardId,
        s.AffiliationNumber, s.RegistrationNo, s.PanNumber,
        s.LogoPath, s.GroupType, s.EstablishedYear, s.AboutSchool, s.Website,
        s.ContactEmail, s.ContactMobile,
        s.PrincipalName, s.HrContactName, s.HrContactMobile,
        s.AddressLine1, s.AddressLine2, s.CityId, s.DistrictId, s.StateId, s.Pincode,
        s.IsVerified, s.VerifiedOn,
        s.IsSuspended, s.SuspendedOn, s.SuspensionReason,
        s.RowVersion,
        (SELECT COUNT(*) FROM dbo.t_app_school_branches b
         WHERE b.SchoolId = s.SchoolId AND b.Is_Deleted = 0) AS BranchCount
    FROM dbo.t_app_schools s
    WHERE s.SchoolId = @SchoolId AND s.Is_Deleted = 0;

    -- ---- 2. branches, SCOPE-RESOLVED -------------------------------------
    -- 🔴 Even on the school's own profile. A branch HR opening the profile
    -- sees their campuses, not all of them.
    SELECT
        b.BranchId, b.BranchUid, b.BranchName, b.BranchCode, b.IsHeadOffice,
        b.AddressLine1, b.AddressLine2, b.CityId, b.DistrictId, b.StateId, b.Pincode,
        b.Latitude, b.Longitude, b.ContactPerson, b.ContactEmail, b.ContactMobile,
        b.Is_Active AS IsActive, b.RowVersion
    FROM dbo.t_app_school_branches b
        INNER JOIN dbo.fn_VisibleBranches(@SchoolId, @UserUid) v ON v.BranchId = b.BranchId
    WHERE b.Is_Deleted = 0
    ORDER BY b.IsHeadOffice DESC, b.BranchName;

    -- ---- 3. photos --------------------------------------------------------
    SELECT p.PhotoId, p.SchoolId, p.BranchId, p.FilePath, p.Caption, p.DisplayOrder
    FROM dbo.t_app_school_photos p
    WHERE p.SchoolId = @SchoolId AND p.Is_Deleted = 0
    ORDER BY p.DisplayOrder, p.PhotoId;

    -- ---- 4. facilities ----------------------------------------------------
    SELECT f.Id, f.SchoolId, f.BranchId, f.FacilityId
    FROM dbo.t_app_school_facilities f
    WHERE f.SchoolId = @SchoolId AND f.Is_Deleted = 0;
END
GO


/*==============================================================================
  USP_GetSchoolPublicProfile — what a TEACHER sees.

  ---------------------------------------------------------------------------
  🔴 A SEPARATE PROCEDURE, NOT A FLAG ON THE ONE ABOVE
  ---------------------------------------------------------------------------
  The obvious design is one procedure with @IsPublic and a CASE per sensitive
  column. It is one forgotten column away from a leak, and the forgetting
  happens later — when somebody adds a column to the own-view SELECT and does
  not think about the flag, because the flag is forty lines further up.

  Two procedures cannot drift that way. Adding a column here is a deliberate act
  of publishing it.

  NOT RETURNED, and each for a reason:
    PanNumber          a tax identifier. No teacher has any use for it.
    OrganizationUid    an internal key; exposing it invites enumeration.
    SuspensionReason   an administrative note about the school, written for us.
    IsSuspended        ⚠️ not hidden — ENFORCED. A suspended school returns
                       nothing at all, rather than returning a profile with a
                       flag the caller is trusted to honour.
    RowVersion         concurrency plumbing for an editor. There is no editor.
    Internal contacts  HrContactMobile and the rest are for our admins, not for
                       a teacher who has not applied yet.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetSchoolPublicProfile
    @SchoolUid  uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @SchoolId bigint;

    /*
      🔴 Looked up by Uid, not by id. A public URL carries the Uid (2.51), and
      a sequential id in a public route is an invitation to walk the range.

      Suspended and unverified schools resolve to nothing here — the filter is
      on the lookup, so every result set below is empty rather than each one
      having to remember.
    */
    SELECT @SchoolId = s.SchoolId
    FROM dbo.t_app_schools s
    WHERE s.SchoolUid    = @SchoolUid
      AND s.Is_Deleted   = 0
      AND s.Is_Active    = 1
      AND s.IsSuspended  = 0
      AND s.IsVerified   = 1;      -- an unverified school is not public yet

    -- ---- 1. the school, public columns only ------------------------------
    SELECT
        s.SchoolUid, s.SchoolName, s.SchoolTypeId, s.BoardId,
        s.LogoPath, s.EstablishedYear, s.AboutSchool, s.Website,
        s.AddressLine1, s.AddressLine2, s.CityId, s.DistrictId, s.StateId, s.Pincode,
        s.IsVerified
    FROM dbo.t_app_schools s
    WHERE s.SchoolId = @SchoolId;

    -- ---- 2. branches, public columns only --------------------------------
    -- No scope resolver: this is the public view and there is no member to
    -- resolve against. Inactive campuses are excluded instead.
    SELECT
        b.BranchUid, b.BranchName,
        b.AddressLine1, b.AddressLine2, b.CityId, b.DistrictId, b.StateId, b.Pincode,
        b.Latitude, b.Longitude
    FROM dbo.t_app_school_branches b
    WHERE b.SchoolId = @SchoolId AND b.Is_Deleted = 0 AND b.Is_Active = 1
    ORDER BY b.IsHeadOffice DESC, b.BranchName;

    -- ---- 3. photos --------------------------------------------------------
    SELECT p.FilePath, p.Caption, p.DisplayOrder
    FROM dbo.t_app_school_photos p
    WHERE p.SchoolId = @SchoolId AND p.Is_Deleted = 0 AND p.Is_Active = 1
    ORDER BY p.DisplayOrder, p.PhotoId;

    -- ---- 4. facilities ----------------------------------------------------
    SELECT DISTINCT f.FacilityId
    FROM dbo.t_app_school_facilities f
    WHERE f.SchoolId = @SchoolId AND f.Is_Deleted = 0;
END
GO


/*==============================================================================
  USP_UpdateSchoolProfile

  ⚠️ RowVersion is re-checked INSIDE the UPDATE's WHERE clause, not only in
  validation. Checking it in validation alone leaves a window between the read
  and the write in which the other writer commits — the exact bug 2.46 records
  and 2C's suite reaches through a two-level fixture.

  The name, the verification flags and the suspension flags are NOT updatable
  here. A school renaming itself changes what was verified; suspension is an
  admin decision. Both belong to procedures an admin calls.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_UpdateSchoolProfile
    @SchoolId           bigint,
    @UserUid            uniqueidentifier,
    @RowVersion         int,
    @SchoolTypeId       int            = NULL,
    @BoardId            int            = NULL,
    @AffiliationNumber  varchar(50)    = NULL,
    @RegistrationNo     varchar(50)    = NULL,
    @PanNumber          varchar(10)    = NULL,
    @GroupType          tinyint        = NULL,
    @EstablishedYear    smallint       = NULL,
    @AboutSchool        nvarchar(max)  = NULL,
    @Website            nvarchar(255)  = NULL,
    @ContactEmail       nvarchar(150)  = NULL,
    @ContactMobile      varchar(15)    = NULL,
    @PrincipalName      nvarchar(150)  = NULL,
    @HrContactName      nvarchar(150)  = NULL,
    @HrContactMobile    varchar(15)    = NULL,
    @AddressLine1       nvarchar(250)  = NULL,
    @AddressLine2       nvarchar(250)  = NULL,
    @CityId             int            = NULL,
    @DistrictId         int            = NULL,
    @StateId            int            = NULL,
    @Pincode            varchar(10)    = NULL,
    @ActionByUserId     bigint         = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL, @Id bigint = @SchoolId,
            @Now datetime2 = SYSUTCDATETIME();

    /*==========================================================================
      SR-3 — NORMALISE THE SIX COMPULSORY FIELDS BEFORE ANYTHING LOOKS AT THEM.

      🔴 THIS BLOCK IS WHAT MAKES THE RULES BELOW SAFE FOR EXISTING SCHOOLS, and
      it is not tidying. The profile screen has FIVE section save buttons —
      basic details, about, facilities, gallery, contact — and every one of them
      posts the WHOLE row. So these six parameters arrive on a save about a
      photograph, carrying whatever the form happened to hold.

      Which means "blank" has to mean the same thing on both sides of every
      comparison, or an old school loses the ability to save anything:

          NULL        no value              -> blank
          ''          an empty box          -> blank
          '   '       an empty box, typed   -> blank
          0           an empty NUMBER box   -> blank

      🔴 THE LAST ONE IS THE TRAP, AND IT IS NOT HYPOTHETICAL. An Angular number
      input bound to a cleared field can post 0 rather than null. Without
      NULLIF(..., 0) below, an EstablishedYear of 0 is "present" — it skips the
      removal rule and then fails the 1800..this-year range, so a school with no
      established year would be refused a save of its phone number, with a
      message about a year it never typed. The id fields are the same shape and
      would additionally hit a foreign key.

      ⚠️ UPPER() ON THE PAN, DEFENSIVELY. ApprovalService has normalised it on
      the way in for a while and the school client now sends it uppercase — but
      rows written before either of those are stored as they were typed. A
      lower-case PAN from 2026 must not be refused by a rule it predates, so the
      case is fixed here rather than tested for.

      ⚠️ AND THE NORMALISED VALUE IS WHAT GETS WRITTEN, which means an unrelated
      save quietly uppercases and trims these six. That is a real side effect,
      stated: it changes no meaning, it makes the column consistent, and the
      alternative is validating one value and storing another.
    ==========================================================================*/
    SET @SchoolTypeId      = NULLIF(@SchoolTypeId, 0);
    SET @BoardId           = NULLIF(@BoardId, 0);
    SET @AffiliationNumber = NULLIF(LTRIM(RTRIM(@AffiliationNumber)), '');
    SET @RegistrationNo    = NULLIF(LTRIM(RTRIM(@RegistrationNo)), '');
    SET @PanNumber         = NULLIF(UPPER(LTRIM(RTRIM(@PanNumber))), '');
    SET @EstablishedYear   = NULLIF(@EstablishedYear, 0);

    DECLARE @CurrentRowVersion int = NULL, @IsSuspended tinyint = NULL;

    /*
      SR-3. The STORED values of the six fields that became compulsory at
      registration, read so this procedure can tell an edit OF one of them from
      an edit that merely carries one along. See the block below — without
      these, the only rules expressible here are the ones that break every
      existing school.
    */
    DECLARE @StoredSchoolTypeId      int         = NULL,
            @StoredBoardId           int         = NULL,
            @StoredAffiliationNumber varchar(50) = NULL,
            @StoredRegistrationNo    varchar(50) = NULL,
            @StoredPanNumber         varchar(10) = NULL,
            @StoredEstablishedYear   smallint    = NULL;

    /*
      🔴 NORMALISED THE SAME WAY THE INCOMING VALUES WERE, AND THAT SYMMETRY IS
      THE POINT. After this, "blank" is exactly "IS NULL" on BOTH sides, so
      every rule below is a two-term test a reader can check by eye instead of
      four nested ISNULL/LEN/LTRIM calls whose two halves could drift apart.

      ⚠️ A stored 0 or a stored '   ' is as blank as a stored NULL. Neither
      should exist — the foreign keys and the year CHECK make them nearly
      impossible — but a row that has one must not become uneditable because
      the comparison counted it as a value worth protecting.
    */
    SELECT @CurrentRowVersion        = s.RowVersion,
           @IsSuspended              = s.IsSuspended,
           @StoredSchoolTypeId       = NULLIF(s.SchoolTypeId, 0),
           @StoredBoardId            = NULLIF(s.BoardId, 0),
           @StoredAffiliationNumber  = NULLIF(LTRIM(RTRIM(s.AffiliationNumber)), ''),
           @StoredRegistrationNo     = NULLIF(LTRIM(RTRIM(s.RegistrationNo)), ''),
           @StoredPanNumber          = NULLIF(UPPER(LTRIM(RTRIM(s.PanNumber))), ''),
           @StoredEstablishedYear    = NULLIF(s.EstablishedYear, 0)
    FROM dbo.t_app_schools s
    WHERE s.SchoolId = @SchoolId AND s.Is_Deleted = 0;

    IF @CurrentRowVersion IS NULL
        SELECT @Code = 'NOT_FOUND', @Message = N'That school was not found.';
    ELSE IF dbo.fn_IsSchoolMember(@SchoolId, @UserUid) = 0
        -- Same message as a missing school. Confirming that a school exists but
        -- is not yours is itself a small disclosure.
        SELECT @Code = 'NOT_FOUND', @Message = N'That school was not found.';
    ELSE IF @IsSuspended = 1
        SELECT @Code = 'BUSINESS_RULE_VIOLATED',
               @Message = N'This school is suspended and cannot be edited.';
    ELSE IF @CurrentRowVersion <> @RowVersion
        SELECT @Code = 'CONCURRENCY_CONFLICT',
               @Message = N'Somebody else changed this school while you were editing it. Reload and try again.';

    /*==========================================================================
      SR-3 — THE SIX COMPULSORY FIELDS, ON THE **EDIT** PATH.

      ------------------------------------------------------------------------
      🔴 AN EXISTING SCHOOL WITH A BLANK PAN MUST STILL BE ABLE TO SAVE ITS
      WEBSITE. THAT CONSTRAINT DECIDES THE WHOLE SHAPE OF THESE RULES.
      ------------------------------------------------------------------------
      The six fields are required to REGISTER. Schools approved before that
      rule existed have blanks in them — legitimately, because nobody was ever
      asked (036's rule, 029's column comment: "blocking registration on a
      field an admin can chase later costs more sign-ups than it saves").

      🔴 AND THIS PROCEDURE IS A BLANKET OVERWRITE REACHED BY FIVE DIFFERENT
      BUTTONS. The school profile screen has five section saves — basic details,
      about, facilities, gallery, contact — and every one of them posts the
      WHOLE row, including the blank PAN the page loaded. Measured on the client
      side, not assumed.

      So the obvious rule — "the six fields are required here too" — would
      refuse a save of the school's PHOTOGRAPHS with a message about a PAN
      nobody touched, on a row that has been like that for a year. Every old
      school would become unable to edit ANYTHING on that page: not its about
      text, not its facilities, not its phone number. The first symptom would be
      a support ticket saying "I cannot change my phone number", and the cause
      would be the validation added to improve the data.

      ⚠️ THE CLIENT CANNOT SOLVE THIS ALONE, and it already does its half: the
      school app validates one of the six only when the value on screen differs
      from the one the page loaded. But the payload still carries the unchanged
      blanks, so only this procedure can tell an unchanged blank from a
      newly-cleared one. Both halves are needed and they state the same rule.

      ------------------------------------------------------------------------
      🔴 SO THE RULE IS: REFUSE A VALUE THAT IS WORSE THAN THE STORED ONE.
      NEVER REFUSE AN ABSENCE THAT WAS ALREADY ABSENT.
      ------------------------------------------------------------------------
      Two things are refused, and nothing else:

        1. CLEARING a compulsory field that HAS a value. That is an edit OF the
           field, and it takes a complete school and makes it incomplete.
        2. A value that is PRESENT and MALFORMED — a PAN that is not a PAN, a
           year outside 1800..this year. Also an edit OF the field.

      And the case that decides it: stored blank, submitted blank — PASSES. The
      school is no worse than it was, the edit is about something else, and the
      only thing a refusal would achieve is stopping a correction nobody asked
      them to make.

      Worked through, per field, so the claim is checkable rather than asserted:

        stored      submitted    outcome    why
        ----------- ------------ ---------- --------------------------------
        NULL        NULL         SAVES      an old row, an unrelated edit
        NULL        'ABCDE1234F' SAVES      they filled it in. The good case.
        NULL        'rubbish'    REFUSED    they filled it in wrongly
        'ABCDE1234F' same        SAVES      carried along untouched
        'ABCDE1234F' NULL        REFUSED    clearing a compulsory field
        'ABCDE1234F' 'rubbish'   REFUSED    malformed

      ⚠️ NOTHING HERE CAN REFUSE A SAVE THAT LEAVES THE SIX FIELDS AS THEY
      WERE. Every branch below is guarded on either the stored value being
      present (cases 5) or the submitted value being present (cases 3 and 6).
      An unrelated update reaches none of them.

      ------------------------------------------------------------------------
      ⚠️ SAME SIX MESSAGES AS THE TWO SUBMIT PATHS, PLUS TWO THIS PATH NEEDS
      ------------------------------------------------------------------------
      The malformed-PAN and bad-year messages are word for word 001's and
      007's. The CLEARING refusals are new sentences, because "the PAN is
      required" is not what happened — they had one and are removing it, and a
      message that does not say so sends somebody looking for an empty box that
      is not empty.

      Registration's wording is reused where the situation is the same, and not
      where it is not.
    ==========================================================================*/

    /* ----------------------------------------------------------------------
      1. CLEARING A COMPULSORY FIELD THAT HAS A VALUE.

      🔴 THIS IS THE "DIFFERS FROM STORED" RULE IN ITS REDUCED FORM, and the
      reduction is worth writing out because a reader will otherwise look for a
      comparison that is not here:

          refuse when  (incoming DIFFERS from stored)  AND  (incoming is blank)

      If the incoming value is blank, then it differs from the stored value if
      and only if the stored value is NOT blank. So the first term collapses
      into the second and the rule becomes:

          refuse when  (stored is not blank)  AND  (incoming is blank)

      which is what each branch below says. The two forms are the same test;
      this one cannot be got wrong by comparing a NULL to an empty string,
      because after the normalisation above both sides are NULL or neither is.

      ⚠️ AND THE CASE THAT MATTERS: stored blank, incoming blank — no branch
      fires, the save proceeds. That is the old school correcting its phone
      number. NULL -> '' is not an edit, because '' was normalised to NULL
      before anything compared them.
    ---------------------------------------------------------------------- */
    ELSE IF @StoredSchoolTypeId IS NOT NULL AND @SchoolTypeId IS NULL
        SELECT @Code = 'VALIDATION_FAILED',
               @Message = N'The school type cannot be removed. Choose the one that applies.';
    ELSE IF @StoredBoardId IS NOT NULL AND @BoardId IS NULL
        SELECT @Code = 'VALIDATION_FAILED',
               @Message = N'The board cannot be removed. Choose the one that applies.';
    ELSE IF @StoredAffiliationNumber IS NOT NULL AND @AffiliationNumber IS NULL
        SELECT @Code = 'VALIDATION_FAILED',
               @Message = N'The affiliation number cannot be removed.';
    ELSE IF @StoredRegistrationNo IS NOT NULL AND @RegistrationNo IS NULL
        SELECT @Code = 'VALIDATION_FAILED',
               @Message = N'The registration number cannot be removed.';
    ELSE IF @StoredPanNumber IS NOT NULL AND @PanNumber IS NULL
        SELECT @Code = 'VALIDATION_FAILED',
               @Message = N'The PAN cannot be removed.';
    ELSE IF @StoredEstablishedYear IS NOT NULL AND @EstablishedYear IS NULL
        SELECT @Code = 'VALIDATION_FAILED',
               @Message = N'The year the school was established cannot be removed.';

    /* ----------------------------------------------------------------------
      2. A VALUE THAT IS PRESENT AND MALFORMED.

      🔴 THIS ONE DOES NOT CARE WHETHER IT CHANGED. A bad PAN is a bad PAN, and
      a save that carries one along is a save that re-asserts it. The guard that
      keeps old rows editable is the PRESENCE test, not a comparison: a school
      with no PAN sends no PAN, which after normalisation is NULL, and NULL
      reaches neither branch below.

      ⚠️ Which also means a row that already holds a malformed PAN — written
      before any of this existed — becomes uneditable until the PAN is fixed or
      removed... and removing it is refused by rule 1 above, because it is
      present. Stated rather than hidden: the escape is to correct it, which is
      the right outcome, and it is reachable from the same form. There is no
      such row today (ApprovalService has format-checked every PAN on the way in
      since SR-0), so this is a dead corner rather than a live problem.
    ---------------------------------------------------------------------- */

    /*
      ⚠️ Latin1_General_BIN2, for 001's reason: under the database's default CI
      collation '[A-Z]' matches lowercase too, so the pattern alone would accept
      'abcde1234f'. The value was already uppercased by the normalisation above
      — which is what stops an old lower-case row being refused by a rule it
      predates — and BIN2 then makes the ranges mean code points.

      ⚠️ Ten single-character classes and NO wildcard, so the pattern also fixes
      the LENGTH at ten. A separate LEN() check would be a second thing to keep
      in step with it.
    */
    ELSE IF @PanNumber IS NOT NULL
        AND @PanNumber COLLATE Latin1_General_BIN2
            NOT LIKE '[A-Z][A-Z][A-Z][A-Z][A-Z][0-9][0-9][0-9][0-9][A-Z]'
        SELECT @Code = 'VALIDATION_FAILED',
               @Message = N'That does not look like a PAN. It is ten characters: five letters, four digits, then a letter — for example ABCDE1234F.';

    /*
      ⚠️ THE IST YEAR (2.28), the same as both submit paths. jp_app has its own
      copy of fn_IstToday (04_procedures\000_fn_datetime_ist.sql, the file whose
      header says all three databases' copies must agree), so this is the same
      definition of "this year" the registration used — which matters, because
      a school registered on 1 January must be able to edit itself on
      1 January.
    */
    ELSE IF @EstablishedYear IS NOT NULL
        AND (@EstablishedYear < 1800 OR @EstablishedYear > YEAR(dbo.fn_IstToday()))
        SELECT @Code = 'VALIDATION_FAILED',
               @Message = N'The year the school was established must be between 1800 and '
                        + CAST(YEAR(dbo.fn_IstToday()) AS nvarchar(4)) + N'.';

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            UPDATE dbo.t_app_schools
               SET SchoolTypeId      = @SchoolTypeId,
                   BoardId           = @BoardId,
                   AffiliationNumber = @AffiliationNumber,
                   RegistrationNo    = @RegistrationNo,
                   PanNumber         = @PanNumber,
                   GroupType         = @GroupType,
                   EstablishedYear   = @EstablishedYear,
                   AboutSchool       = @AboutSchool,
                   Website           = @Website,
                   ContactEmail      = @ContactEmail,
                   ContactMobile     = @ContactMobile,
                   PrincipalName     = @PrincipalName,
                   HrContactName     = @HrContactName,
                   HrContactMobile   = @HrContactMobile,
                   AddressLine1      = @AddressLine1,
                   AddressLine2      = @AddressLine2,
                   CityId            = @CityId,
                   DistrictId        = @DistrictId,
                   StateId           = @StateId,
                   Pincode           = @Pincode,
                   RowVersion        = RowVersion + 1,
                   ModifiedOn        = @Now,
                   ModifiedBy        = @ActionByUserId
             WHERE SchoolId    = @SchoolId
               AND Is_Deleted  = 0
               AND RowVersion  = @RowVersion;   -- 🔴 re-checked HERE

            IF @@ROWCOUNT = 0
                SELECT @Code = 'CONCURRENCY_CONFLICT',
                       @Message = N'Somebody else changed this school while you were editing it. Reload and try again.';
            ELSE
                SELECT @Status = 1, @Message = N'School profile updated.';
        END TRY
        BEGIN CATCH
            DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                    @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                    @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            DECLARE @Params nvarchar(max) = (
                SELECT @SchoolId AS schoolId, @RowVersion AS rowVersion
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
                 @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
                 @ErrorMessage = @ErrMessage, @ParametersJson = @Params,
                 @ContextInfo = N'USP_UpdateSchoolProfile', @CreatedBy = @ActionByUserId;

            THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @Id AS Id;
END
GO


/*==============================================================================
  USP_SaveSchoolLogo

  ⚠️ No RowVersion. A logo upload is not an edit of the form somebody else might
  have open — it is its own action, and making it fail because a colleague saved
  the address a minute ago would be a rule nobody could explain.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SaveSchoolLogo
    @SchoolId       bigint,
    @UserUid        uniqueidentifier,
    @LogoPath       nvarchar(500),
    @ActionByUserId bigint = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL, @Id bigint = @SchoolId;

    IF NOT EXISTS (SELECT 1 FROM dbo.t_app_schools WHERE SchoolId = @SchoolId AND Is_Deleted = 0)
        SELECT @Code = 'NOT_FOUND', @Message = N'That school was not found.';
    ELSE IF dbo.fn_IsSchoolMember(@SchoolId, @UserUid) = 0
        SELECT @Code = 'NOT_FOUND', @Message = N'That school was not found.';
    ELSE IF ISNULL(@LogoPath, N'') = N''
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The logo file is required.';

    IF @Code IS NULL
    BEGIN
        UPDATE dbo.t_app_schools
           SET LogoPath   = @LogoPath,
               ModifiedOn = SYSUTCDATETIME(),
               ModifiedBy = @ActionByUserId
         WHERE SchoolId = @SchoolId AND Is_Deleted = 0;

        SELECT @Status = 1, @Message = N'Logo updated.';
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @Id AS Id;
END
GO
