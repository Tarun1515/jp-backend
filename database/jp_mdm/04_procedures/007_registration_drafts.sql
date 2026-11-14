/*==============================================================================
  jp_mdm — 04_procedures / 007_registration_drafts.sql

  USP_SaveSchoolRegistrationDraft   upsert the draft
  USP_GetSchoolRegistrationDraftId  which draft belongs to this user
  USP_SubmitRegistrationDraft       promote a draft to Pending

  ---------------------------------------------------------------------------
  🔴 A DRAFT IS A REQUEST IN DRAFT STATUS, NOT A SEPARATE TABLE
  ---------------------------------------------------------------------------
  The registration form is six steps plus document uploads. A school MUST be
  able to leave and come back — losing a half-filled form with documents
  already attached means they do not come back at all.

  The obvious design is a drafts table holding a JSON blob. It does not work,
  and the reason is documents: an upload is attached to a RequestId, so there
  has to be a request row before the first file can be stored. A JSON draft
  would need its own parallel document store, and then a migration of those
  documents onto the real request at submit — a step that can fail after the
  school has been told it succeeded.

  So the draft IS the request, sitting in StatusId 8 (DRAFT), which
  m_mdm_approval_status has always carried and nothing has used until now.
  Documents attach to it from the first upload and never move.

  ⚠️ The one-pending-per-entity index is filtered on StatusId = 1, so drafts
  do not collide with it. That is what makes this work without touching the
  index.

  ---------------------------------------------------------------------------
  WHY A DRAFT DOES NOT GET A REAL REQUEST NUMBER
  ---------------------------------------------------------------------------
  RequestNo is NOT NULL and unique, and the real one comes from a per-type,
  per-year counter. Allocating from that counter at draft time would burn a
  number every time somebody opened the form and wandered off, leaving
  permanent holes in a sequence people read as complete.

  So a draft carries `DRAFT-000123` from its own sequence, and the real number
  is allocated at submit — the moment the request actually exists as far as
  anybody outside is concerned.

  ---------------------------------------------------------------------------
  🔴 THE DRAFT ALSO CARRIES THE PLAN THE SCHOOL ASKED FOR, AND NOTHING ELSE
  ---------------------------------------------------------------------------
  RequestedPlanCode (041) is saved with the rest of the form. It grants
  nothing: the account is provisioned on the DEFAULT plan exactly as before,
  and a paid choice becomes a PENDING PLAN_CHANGE request through
  USP_RequestPlanChange — the machinery 011_seed_plan_change_request.sql
  configured, not a second mechanism beside it.

  ⚠️ SUBMIT DOES NOT RE-VALIDATE THE PLAN, deliberately. A plan withdrawn
  between draft and submit must not block a registration: the plan is a
  commercial preference and the registration is the school's application to
  exist on the platform. An unresolvable code is handled at provisioning —
  the school is still created, still on Free, and the orchestration logs it
  loudly rather than inventing a request for a plan that is gone.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*------------------------------------------------------------------------------
  The draft numbering. Separate from the real series on purpose — an abandoned
  draft must not leave a gap in the numbers a school can quote.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.sequences WHERE name = 'seq_mdm_draft_no' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating sequence [seq_mdm_draft_no] ...';

    CREATE SEQUENCE dbo.seq_mdm_draft_no AS int START WITH 1 INCREMENT BY 1;
END
GO


/*==============================================================================
  USP_SaveSchoolRegistrationDraft

  Called on every step change. Creates the draft on the first call and updates
  it thereafter, so the school's work survives a closed tab, a flat battery, or
  finishing on a different device.

  Returns the RequestId and the EntityUid, both of which the client needs: the
  first to upload documents against, the second so a resumed draft keeps
  identifying the same school rather than inventing a new one each save.

  ---------------------------------------------------------------------------
  🔴 SR-3's SIX COMPULSORY FIELDS ARE **NOT** ENFORCED HERE, AND THAT IS THE
  DECISION — NOT AN OVERSIGHT
  ---------------------------------------------------------------------------
  School type, board, affiliation number, registration number, PAN and
  established year are required to SUBMIT a registration.
  USP_SubmitRegistrationDraft refuses each of them by name, and so does
  USP_SubmitApprovalRequest. This procedure refuses none of them.

  Because of when it is called. Read the first line of this header again: ON
  EVERY STEP CHANGE. The PAN is asked for on a later step than the school
  name, so enforcing a PAN here would make it impossible to save step one at
  all — and this procedure is the only thing standing between a half-filled
  six-step form and a school that closes the tab and does not come back. That
  is the exact failure the draft mechanism exists to prevent, and it would be
  caused by the validation meant to improve the data.

  ⚠️ IT WOULD ALSO BE UNRECOVERABLE IN A PARTICULAR WAY. The UPDATE below is a
  blanket overwrite — the client sends the whole form every time — so a refusal
  here does not reject one field, it discards the whole save. A school that
  typed three paragraphs about itself on step five and had not yet reached the
  PAN box would lose all of it, and the screen would say the PAN is required.

  🔴 SO THE RULE IS: A DRAFT ACCEPTS ANYTHING; A SUBMIT ACCEPTS ONLY WHAT IS
  COMPLETE. A draft is a record of what somebody has typed SO FAR, and the
  honest shape for "so far" is NULL. Submit is the moment the school asserts
  the form is finished, which is the only moment a missing field is a mistake
  rather than a step not yet reached.

  ⚠️ THE ONE THING THAT IS STILL REFUSED HERE IS AN UNKNOWN PLAN CODE, and the
  distinction is worth stating because it looks inconsistent. An absent field
  is incompleteness; a plan code that matches no plan is a value the client
  INVENTED, and storing it would be the silent-drop failure SR-0 found with
  PrincipalMobile. Nothing legitimate sends it.

  ⚠️ AND THE COST, STATED: a school can fill a draft with six blanks and only
  discover at submit that it cannot finish. The client's step validation is
  what makes that rare; the server's job is to make it impossible to get
  further, which is what submit does. The alternative — telling them at step
  one — costs the draft mechanism its entire purpose.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SaveSchoolRegistrationDraft
    @RequestorUserId    bigint,
    @OrganizationUid    uniqueidentifier = NULL,

    /*
      NULL on the first save; the caller sends back what it was given after
      that. Generated here rather than by the client so two tabs cannot create
      two entities for one school.
    */
    @EntityUid          uniqueidentifier = NULL,

    @SchoolName         nvarchar(200)  = NULL,
    @SchoolTypeId       int            = NULL,
    @BoardId            int            = NULL,
    @AffiliationNumber  varchar(50)    = NULL,
    @RegistrationNo     varchar(50)    = NULL,
    @PanNumber          varchar(10)    = NULL,
    @LogoPath           nvarchar(500)  = NULL,
    @GroupType          tinyint        = NULL,
    @EstablishedYear    smallint       = NULL,
    @AddressLine1       nvarchar(250)  = NULL,
    @AddressLine2       nvarchar(250)  = NULL,
    @CityId             int            = NULL,
    @DistrictId         int            = NULL,
    @StateId            int            = NULL,
    @Pincode            varchar(10)    = NULL,

    /*
      SR-1's address columns. All nullable: tehsil and area are optional by
      design (ADDRESS_DESIGN §2), and the coordinates only exist when the
      address came through Places.
    */
    @TehsilId           int            = NULL,
    @AreaOrVillage      nvarchar(200)  = NULL,
    @Latitude           decimal(9, 6)  = NULL,
    @Longitude          decimal(9, 6)  = NULL,
    @GooglePlaceId      varchar(120)   = NULL,
    @PrincipalName      nvarchar(150)  = NULL,
    @PrincipalMobile    varchar(15)    = NULL,
    @HrContactName      nvarchar(150)  = NULL,
    @HrContactMobile    varchar(15)    = NULL,
    @ContactEmail       nvarchar(150)  = NULL,
    @ContactMobile      varchar(15)    = NULL,
    @Website            nvarchar(255)  = NULL,
    @AboutSchool        nvarchar(max)  = NULL,

    /*
      🔴 THE PLAN THE SCHOOL ASKED FOR. A PREFERENCE, NOT A PURCHASE.

      041_alter_school_registration_requested_plan.sql has the long version.
      The short one: this is carried on the draft, it grants nothing, and the
      account still starts on the default plan when it is approved. A paid
      choice becomes a PENDING PLAN_CHANGE request at provisioning, through
      USP_RequestPlanChange — the mechanism 011_seed_plan_change_request.sql
      configured. There is no second path.

      ⚠️ A CODE, never an id (2.47). The API resolves it to an id at the one
      moment an id is needed.

      ⚠️ NULL is a real value and means "not asked, or not answered yet" —
      which is NOT the same as 'SCHOOL_FREE', meaning "asked, chose free".
    */
    @RequestedPlanCode  varchar(30)    = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL, @Id bigint = NULL,
            @Now datetime2 = SYSUTCDATETIME();

    DECLARE @DRAFT_STATUS int = 8, @SCHOOL_REG int = 1;

    /* m_sso_user_types. School — the only user type this form registers. */
    DECLARE @USER_TYPE_SCHOOL int = 2;

    IF @RequestorUserId IS NULL
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The requestor is required.';

    /*
      🔴 AN UNKNOWN PLAN CODE IS REFUSED HERE, BECAUSE THERE IS NO FK TO DO IT.

      m_mdm_plans.PlanCode is unique through a FILTERED index, which SQL Server
      will not let a foreign key reference (see 041's header). So the rule lives
      in one named place rather than nowhere.

      ⚠️ REFUSED, not quietly nulled. Silently dropping a field registration
      collected is precisely what SR-0 found USP_ProvisionSchoolFromApproval
      doing with PrincipalMobile — the school typed something, the software
      agreed, and the value was gone. A loud refusal is recoverable; a silent
      one is not.

      ⚠️ Scoped to SCHOOL and to IsPublic: a school cannot register itself onto
      a teacher plan or onto a private one by sending its code, and the only
      codes a legitimate client can send are the ones USP_GetPlanCatalog gave
      it. Is_Active is checked too — a withdrawn plan is not something new
      accounts may still join.
    */
    IF @Code IS NULL AND @RequestedPlanCode IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM dbo.m_mdm_plans p
                        WHERE p.PlanCode   = @RequestedPlanCode
                          AND p.UserTypeId = @USER_TYPE_SCHOOL
                          AND p.IsPublic   = 1
                          AND p.Is_Active  = 1
                          AND p.Is_Deleted = 0)
        SELECT @Code = 'INVALID_PLAN',
               @Message = N'That plan is not one a school can register on. '
                        + N'Reload the form and choose again — your other answers are saved.';

    /*
      🔴 A school that already has a request in flight must not start a second
      one. Checked here rather than left to the unique index, because the index
      only covers Pending — a school with a Pending request could otherwise
      build a whole second draft and only discover the problem at submit, with
      the documents already uploaded.
    */
    IF @Code IS NULL AND @EntityUid IS NOT NULL
       AND EXISTS (SELECT 1 FROM dbo.t_mdm_approval_requests
                   WHERE RequestTypeId = @SCHOOL_REG AND EntityUid = @EntityUid
                     AND StatusId = 1 AND Is_Deleted = 0)
        SELECT @Code = 'ALREADY_PENDING',
               @Message = N'This registration has already been submitted and is being reviewed.';

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            -- The caller's existing draft, if there is one. One per user:
            -- a school registers itself once.
            SELECT @Id = RequestId, @EntityUid = COALESCE(@EntityUid, EntityUid)
            FROM dbo.t_mdm_approval_requests
            WHERE RequestorUserId = @RequestorUserId
              AND RequestTypeId   = @SCHOOL_REG
              AND StatusId        = @DRAFT_STATUS
              AND Is_Deleted      = 0;

            IF @Id IS NULL
            BEGIN
                SET @EntityUid = COALESCE(@EntityUid, NEWID());

                DECLARE @DraftNo varchar(30) =
                    'DRAFT-' + RIGHT('000000' + CAST(NEXT VALUE FOR dbo.seq_mdm_draft_no AS varchar(10)), 6);

                INSERT INTO dbo.t_mdm_approval_requests
                    (RequestNo, RequestTypeId, StatusId, CurrentApprovalLevel,
                     EntityUid, OrganizationUid, RequestorUserId, SubmittedOn, CreatedBy)
                VALUES
                    (@DraftNo, @SCHOOL_REG, @DRAFT_STATUS, 1,
                     @EntityUid, @OrganizationUid, @RequestorUserId, @Now, @RequestorUserId);

                SET @Id = SCOPE_IDENTITY();

                INSERT INTO dbo.t_mdm_school_registration_details
                    (RequestId, SchoolName, SchoolTypeId, BoardId, AffiliationNumber,
                     RegistrationNo, PanNumber, LogoPath, GroupType, EstablishedYear,
                     AddressLine1, AddressLine2, CityId, DistrictId, StateId, Pincode,
                     TehsilId, AreaOrVillage, Latitude, Longitude, GooglePlaceId,
                     PrincipalName, PrincipalMobile, HrContactName, HrContactMobile,
                     ContactEmail, ContactMobile, Website, AboutSchool,
                     RequestedPlanCode, CreatedBy)
                VALUES
                    (@Id, ISNULL(@SchoolName, N''), @SchoolTypeId, @BoardId, @AffiliationNumber,
                     @RegistrationNo, @PanNumber, @LogoPath, @GroupType, @EstablishedYear,
                     @AddressLine1, @AddressLine2, @CityId, @DistrictId, @StateId, @Pincode,
                     @TehsilId, @AreaOrVillage, @Latitude, @Longitude, @GooglePlaceId,
                     @PrincipalName, @PrincipalMobile, @HrContactName, @HrContactMobile,
                     @ContactEmail, @ContactMobile, @Website, @AboutSchool,
                     @RequestedPlanCode, @RequestorUserId);
            END
            ELSE
            BEGIN
                /*
                  A blanket overwrite, deliberately: the client sends the whole
                  form on every save, so a field cleared on screen has to clear
                  here. COALESCE-ing to the stored value would make deleting
                  anything impossible — the field would reappear on reload and
                  read as the save having failed.
                */
                UPDATE dbo.t_mdm_school_registration_details
                   SET SchoolName        = ISNULL(@SchoolName, N''),
                       SchoolTypeId      = @SchoolTypeId,
                       BoardId           = @BoardId,
                       AffiliationNumber = @AffiliationNumber,
                       RegistrationNo    = @RegistrationNo,
                       PanNumber         = @PanNumber,
                       LogoPath          = @LogoPath,
                       GroupType         = @GroupType,
                       EstablishedYear   = @EstablishedYear,
                       AddressLine1      = @AddressLine1,
                       AddressLine2      = @AddressLine2,
                       CityId            = @CityId,
                       DistrictId        = @DistrictId,
                       StateId           = @StateId,
                       Pincode           = @Pincode,
                       TehsilId          = @TehsilId,
                       AreaOrVillage     = @AreaOrVillage,
                       Latitude          = @Latitude,
                       Longitude         = @Longitude,
                       GooglePlaceId     = @GooglePlaceId,
                       PrincipalName     = @PrincipalName,
                       PrincipalMobile   = @PrincipalMobile,
                       HrContactName     = @HrContactName,
                       HrContactMobile   = @HrContactMobile,
                       ContactEmail      = @ContactEmail,
                       ContactMobile     = @ContactMobile,
                       Website           = @Website,
                       AboutSchool       = @AboutSchool,

                       /*
                         ⚠️ Overwritten like every other field, including back
                         to NULL. The client sends the whole form on every
                         save, and a school that changes its mind from Standard
                         to Free must actually end up on Free — a COALESCE here
                         would make the paid choice unretractable, which is the
                         single most dishonest thing this feature could do.
                       */
                       RequestedPlanCode = @RequestedPlanCode,
                       ModifiedOn        = @Now,
                       ModifiedBy        = @RequestorUserId
                 WHERE RequestId = @Id;

                UPDATE dbo.t_mdm_approval_requests
                   SET OrganizationUid = COALESCE(@OrganizationUid, OrganizationUid),
                       ModifiedOn      = @Now,
                       ModifiedBy      = @RequestorUserId
                 WHERE RequestId = @Id;
            END

            COMMIT TRANSACTION;

            SELECT @Status = 1, @Message = N'Draft saved.';
        END TRY
        BEGIN CATCH
            DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                    @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                    @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            DECLARE @Params nvarchar(max) = (
                SELECT @RequestorUserId AS requestorUserId, @EntityUid AS entityUid
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
                 @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
                 @ErrorMessage = @ErrMessage, @ParametersJson = @Params,
                 @ContextInfo = N'USP_SaveSchoolRegistrationDraft', @CreatedBy = @RequestorUserId;

            THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @Id AS Id,
           @EntityUid AS EntityUid;
END
GO


/*==============================================================================
  USP_GetSchoolRegistrationDraftId

  Which draft, if any, belongs to this user. Returns the id only — the caller
  then reads it through USP_GetApprovalRequestById, so there is one procedure
  that knows how to assemble a request and not two that must agree.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetSchoolRegistrationDraftId
    @RequestorUserId bigint
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP (1) RequestId
    FROM dbo.t_mdm_approval_requests
    WHERE RequestorUserId = @RequestorUserId
      AND RequestTypeId   = 1
      AND StatusId        = 8      -- DRAFT
      AND Is_Deleted      = 0
    ORDER BY RequestId DESC;
END
GO


/*==============================================================================
  USP_SubmitRegistrationDraft

  Promotes a draft to Pending: allocates the real request number, stamps the
  submission time, and writes the SUBMIT trail row.

  ⚠️ The number allocation is the SAME pattern as USP_SubmitApprovalRequest —
  an UPDATE with UPDLOCK and OUTPUT, never MAX()+1 — because two schools can
  submit in the same second and the counter is the only thing standing between
  that and two requests sharing a number.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SubmitRegistrationDraft
    @RequestId          bigint,
    @RequestorUserId    bigint,
    @IpAddress          varchar(45) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL, @Id bigint = @RequestId,
            @Now datetime2 = SYSUTCDATETIME();

    DECLARE @DRAFT_STATUS int = 8, @PENDING_STATUS int = 1, @ACTION_SUBMIT int = 4;

    DECLARE @RequestTypeId int = NULL, @EntityUid uniqueidentifier = NULL,
            @OwnerUserId bigint = NULL, @StatusId int = NULL, @Prefix varchar(10) = NULL;

    SELECT @RequestTypeId = r.RequestTypeId,
           @EntityUid     = r.EntityUid,
           @OwnerUserId   = r.RequestorUserId,
           @StatusId      = r.StatusId,
           @Prefix        = rt.RequestNoPrefix
    FROM dbo.t_mdm_approval_requests r
        INNER JOIN dbo.m_mdm_request_types rt ON rt.RequestTypeId = r.RequestTypeId
    WHERE r.RequestId = @RequestId AND r.Is_Deleted = 0;

    /*
      SR-3. The six fields the validation chain below now requires, read once
      into variables rather than as six EXISTS subqueries against the same
      indexed row.

      ⚠️ READ UNCONDITIONALLY, before the chain, and it costs one clustered-key
      seek. The alternative — reading it only once the chain has decided the
      draft is real — would mean six near-identical subqueries each repeating
      "RequestId = @RequestId AND Is_Deleted = 0", which is six places for that
      predicate to drift.
    */
    DECLARE @SchoolName        nvarchar(200) = NULL,
            @SchoolTypeId      int           = NULL,
            @BoardId           int           = NULL,
            @AffiliationNumber varchar(50)   = NULL,
            @RegistrationNo    varchar(50)   = NULL,
            @PanNumber         varchar(10)   = NULL,
            @EstablishedYear   smallint      = NULL,
            @HasDetail         bit           = 0;

    SELECT @SchoolName        = d.SchoolName,
           @SchoolTypeId      = d.SchoolTypeId,
           @BoardId           = d.BoardId,
           @AffiliationNumber = d.AffiliationNumber,
           @RegistrationNo    = d.RegistrationNo,
           @PanNumber         = d.PanNumber,
           @EstablishedYear   = d.EstablishedYear,
           @HasDetail         = 1
      FROM dbo.t_mdm_school_registration_details d
     WHERE d.RequestId = @RequestId
       AND d.Is_Deleted = 0;

    IF @RequestTypeId IS NULL
        SELECT @Code = 'NOT_FOUND', @Message = N'That draft was not found.';

    /*
      🔴 The draft belongs to whoever started it, and nobody else — not another
      user in the same organisation, not an administrator. A registration is
      the applicant's statement about themselves.
    */
    ELSE IF @OwnerUserId <> @RequestorUserId
        SELECT @Code = 'FORBIDDEN', @Message = N'That draft belongs to someone else.';

    ELSE IF @StatusId <> @DRAFT_STATUS
        SELECT @Code = 'INVALID_STATUS',
               @Message = N'This registration has already been submitted.';

    -- The name is the one field with no sensible empty value: a request the
    -- admin cannot identify is one that sits in the queue being skipped.
    ELSE IF @HasDetail = 0 OR ISNULL(@SchoolName, N'') = N''
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The school name is required.';

    /*==========================================================================
      SR-3 — SIX REGISTRATION FIELDS BECOME COMPULSORY.

      School type · Board · Affiliation number · Registration number · PAN ·
      Established year.

      ------------------------------------------------------------------------
      🔴 THIS IS THE PATH THE PRODUCT ACTUALLY USES, AND IT HAD ONE CHECK
      ------------------------------------------------------------------------
      The six rules are specified against "the submit path", which
      001_approval_submit.sql's USP_SubmitApprovalRequest is — the form posted
      straight through. But the registration form ships as a DRAFT: six steps
      plus documents, saved on every step change, promoted to Pending here.
      ApprovalRepository calls both.

      So enforcing in 001 alone would have left every message there unreachable
      in production: a school could save a draft with all six blank and submit
      it through this procedure, which checked the school name and nothing
      else. Measured, not assumed — the chain above is what it was.

      ⚠️ THE SAME SIX RULES, THE SAME SIX MESSAGES, WORD FOR WORD as 001's. Two
      submit paths answering the same refusal differently is worse than either
      of them being wrong, because the client's copy can only match one.

      ⚠️ AGAINST THE STORED ROW, NOT AGAINST PARAMETERS. This procedure takes
      a RequestId; the values were written by the draft saves. That is also why
      this is the right place for the rules rather than the draft save — see
      USP_SaveSchoolRegistrationDraft's header note.

      ⚠️ SCOPED TO THE SCHOOL REQUEST TYPES. The detail row only exists for 1
      and 3, and a teacher draft reaching this procedure must not be refused
      for lacking a board.
    ==========================================================================*/
    ELSE IF @RequestTypeId IN (1, 3) AND ISNULL(@SchoolTypeId, 0) <= 0
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The school type is required.';
    ELSE IF @RequestTypeId IN (1, 3) AND ISNULL(@BoardId, 0) <= 0
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The board is required.';
    ELSE IF @RequestTypeId IN (1, 3) AND LEN(LTRIM(RTRIM(ISNULL(@AffiliationNumber, '')))) = 0
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The affiliation number is required.';
    ELSE IF @RequestTypeId IN (1, 3) AND LEN(LTRIM(RTRIM(ISNULL(@RegistrationNo, '')))) = 0
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The registration number is required.';
    ELSE IF @RequestTypeId IN (1, 3) AND LEN(LTRIM(RTRIM(ISNULL(@PanNumber, '')))) = 0
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The PAN is required.';

    /*
      🔴 FIVE LETTERS, FOUR DIGITS, ONE LETTER — AAAAA9999A.

      ⚠️ UPPER() FIRST, THEN A BIN2 PATTERN, for 001's reason: under the
      database's default CI collation '[A-Z]' matches lowercase too, so the
      pattern alone would accept 'abcde1234f'. Ten single-character classes
      and no wildcard also fix the LENGTH at ten.

      ⚠️ CHECKED AT SUBMIT EVEN THOUGH THE DRAFT SAVE STORED IT. The column is
      varchar(10) and accepts any ten characters; ApprovalService uppercases
      and checks the format on the way IN, but a draft saved before this rule
      existed — or by anything that bypassed the service — has whatever is
      there. Submit is the gate, so submit re-reads it.
    */
    ELSE IF @RequestTypeId IN (1, 3)
        AND UPPER(LTRIM(RTRIM(@PanNumber))) COLLATE Latin1_General_BIN2
            NOT LIKE '[A-Z][A-Z][A-Z][A-Z][A-Z][0-9][0-9][0-9][0-9][A-Z]'
        SELECT @Code = 'VALIDATION_FAILED',
               @Message = N'That does not look like a PAN. It is ten characters: five letters, four digits, then a letter — for example ABCDE1234F.';

    ELSE IF @RequestTypeId IN (1, 3) AND @EstablishedYear IS NULL
        SELECT @Code = 'VALIDATION_FAILED',
               @Message = N'The year the school was established is required.';

    /*
      🔴 1800 TO THIS YEAR, AND "THIS YEAR" IS THE IST YEAR (2.28).

      dbo.fn_IstToday() — the helper this procedure already uses to number the
      request below, for the same reason. YEAR(GETUTCDATE()) would refuse a
      school founded this year for the first five and a half hours of every
      January.
    */
    ELSE IF @RequestTypeId IN (1, 3)
        AND (@EstablishedYear < 1800 OR @EstablishedYear > YEAR(dbo.fn_IstToday()))
        SELECT @Code = 'VALIDATION_FAILED',
               @Message = N'The year the school was established must be between 1800 and '
                        + CAST(YEAR(dbo.fn_IstToday()) AS nvarchar(4)) + N'.';

    ELSE IF EXISTS (SELECT 1 FROM dbo.t_mdm_approval_requests
                    WHERE RequestTypeId = @RequestTypeId AND EntityUid = @EntityUid
                      AND StatusId = @PENDING_STATUS AND Is_Deleted = 0)
        SELECT @Code = 'ALREADY_PENDING',
               @Message = N'This registration is already being reviewed.';

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            DECLARE @Year smallint = YEAR(dbo.fn_IstToday());   -- same helper the submit proc uses

            IF NOT EXISTS (SELECT 1 FROM dbo.t_mdm_request_number_series
                           WHERE RequestTypeId = @RequestTypeId AND SeriesYear = @Year)
            BEGIN
                BEGIN TRY
                    INSERT INTO dbo.t_mdm_request_number_series
                        (RequestTypeId, SeriesYear, LastNumber, CreatedBy)
                    VALUES (@RequestTypeId, @Year, 0, @RequestorUserId);
                END TRY
                BEGIN CATCH
                    -- Two first-of-the-year submissions racing. One loses the
                    -- insert; both need the UPDATE below.
                    IF ERROR_NUMBER() NOT IN (2601, 2627) THROW;
                END CATCH
            END

            DECLARE @Seq TABLE (NextNumber int);

            UPDATE s
               SET LastNumber = s.LastNumber + 1,
                   ModifiedOn = @Now,
                   ModifiedBy = @RequestorUserId
            OUTPUT inserted.LastNumber INTO @Seq (NextNumber)
            FROM dbo.t_mdm_request_number_series AS s WITH (UPDLOCK, ROWLOCK)
            WHERE s.RequestTypeId = @RequestTypeId AND s.SeriesYear = @Year;

            DECLARE @NextNumber int = (SELECT TOP (1) NextNumber FROM @Seq);

            IF @NextNumber IS NULL
                THROW 50021, 'Could not allocate a request number.', 1;

            DECLARE @RequestNo varchar(30) =
                @Prefix + '-' + CAST(@Year AS varchar(4)) + '-'
                + RIGHT('00000' + CAST(@NextNumber AS varchar(10)), 5);

            UPDATE dbo.t_mdm_approval_requests
               SET RequestNo            = @RequestNo,
                   StatusId             = @PENDING_STATUS,
                   CurrentApprovalLevel = 1,
                   SubmittedOn          = @Now,
                   RowVersion           = RowVersion + 1,
                   ModifiedOn           = @Now,
                   ModifiedBy           = @RequestorUserId
             WHERE RequestId = @RequestId AND StatusId = @DRAFT_STATUS;

            IF @@ROWCOUNT = 0
                THROW 50022, 'The draft changed while it was being submitted.', 1;

            INSERT INTO dbo.t_mdm_request_approvals
                (RequestId, LevelNumber, ActionTypeId, ActionByUserId,
                 Remarks, ActionOn, IpAddress, CreatedBy)
            VALUES
                (@RequestId, 1, @ACTION_SUBMIT, @RequestorUserId,
                 NULL, @Now, @IpAddress, @RequestorUserId);

            COMMIT TRANSACTION;

            SELECT @Status = 1, @Message = N'Your registration has been submitted for review.';
        END TRY
        BEGIN CATCH
            DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                    @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                    @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            DECLARE @Params nvarchar(max) = (
                SELECT @RequestId AS requestId, @RequestorUserId AS requestorUserId
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
                 @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
                 @ErrorMessage = @ErrMessage, @ParametersJson = @Params,
                 @ContextInfo = N'USP_SubmitRegistrationDraft', @CreatedBy = @RequestorUserId;

            THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @Id AS Id;
END
GO

PRINT '    Registration draft procedures ready.';
GO
