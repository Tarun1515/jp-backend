/*==============================================================================
  jp_app — 04_procedures / 011_school_team.sql

  USP_GetSchoolUserList          who is on this school, with role and scope
  USP_ProvisionSchoolUser        the jp_app half of an invitation — idempotent
  USP_SaveSchoolUserRole         change RoleInSchool (and the person's details)
  USP_SaveSchoolUserBranches     bridge sync, the 3C/3D pattern
  USP_DeactivateSchoolUser       soft — revoke access, keep the history

  ---------------------------------------------------------------------------
  🔴 THE FOUR RULES THIS FILE ENFORCES, AND WHY THEY ARE HERE AND NOT IN THE UI
  ---------------------------------------------------------------------------
  1. THE OWNER CANNOT BE DEMOTED OR DEACTIVATED, BY ANYONE, INCLUDING
     THEMSELVES. A school with no owner is a school nobody can administer, and
     recovering one means somebody editing the database by hand at a time when
     the school is already unable to work.

  2. NOBODY CAN BE PROMOTED TO OWNER EITHER. See the note on
     USP_SaveSchoolUserRole — a second owner is a one-way ratchet under rule 1.

  3. AN OWNER HAS NO LINK ROWS. RoleInSchool = 1 is implicitly every campus and
     fn_VisibleBranches (2.53) already reads it that way. Rows that exist but
     are never read are rows that will disagree with the function one day, and
     the disagreement will be discovered as "an owner cannot see a campus".

  4. DEACTIVATION IS Is_Active = 0, NEVER Is_Deleted = 1 AND NEVER A DELETE.
     Who verified which document has to stay true after they leave.

  A UI can enforce all four and would be right to grey the buttons out. It
  cannot be the place they LIVE: the API is reachable without it, and the day
  somebody writes a second screen — or a script, or a support tool — the rules
  do not travel with it.

  ---------------------------------------------------------------------------
  ⚠️ WHAT THIS FILE DELIBERATELY DOES NOT CHECK: PERMISSIONS
  ---------------------------------------------------------------------------
  Whether the caller may manage users at all is USER.MANAGE, which lives in
  jp_sso and is checked in the controller. These procedures check the two things
  only the database can know: that the caller belongs to this school, and that
  the target does too.

  That division is the one t_app_school_users states in its own header —
  RoleInSchool describes what somebody IS to a school, never what they may DO.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*------------------------------------------------------------------------------
  Branch ids are bigint, so the int list type the facility and subject syncs use
  will not do.

  ⚠️ Guarded, and for the usual reason: a table type cannot be altered, only
  dropped and recreated, and the drop fails while any procedure references it.
------------------------------------------------------------------------------*/
IF TYPE_ID(N'dbo.BigIntIdList') IS NULL
BEGIN
    PRINT '    Creating table type [BigIntIdList] ...';

    CREATE TYPE dbo.BigIntIdList AS TABLE
    (
        Id bigint NOT NULL PRIMARY KEY
    );
END
GO


/*==============================================================================
  USP_GetSchoolUserList

  Two result sets: the people, then the user-to-branch links behind them.

  ---------------------------------------------------------------------------
  ⚠️ NO NAME AND NO EMAIL COME OUT OF HERE — EXCEPT THE ONE THE SCHOOL TYPED
  ---------------------------------------------------------------------------
  The email address lives in jp_sso.t_sso_users, and no query in this database
  may join to it (2.2). The API does that join, in memory, from the UserUids
  this returns.

  FullName is different: it is on the membership because it is what the SCHOOL
  calls this person, and it is NULL for every row provisioning created. The API
  falls back to the email when it is missing.

  ---------------------------------------------------------------------------
  🔴 THE LINKS ARE SCOPED TO THE CALLER, THE COUNT IS NOT
  ---------------------------------------------------------------------------
  Result set 2 passes through fn_VisibleBranches for the CALLER, so an HR at one
  campus does not learn the ids of campuses they were never given.

  But BranchCount on result set 1 is the TRUE number of campuses that person is
  scoped to. Those two disagreeing on purpose is what lets the screen say
  "1 campus, and 2 more you cannot see" instead of quietly under-reporting a
  colleague's access — which would read as "they only have one campus" and is a
  lie the screen would be telling with a straight face.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetSchoolUserList
    @SchoolId        bigint,
    @UserUid         uniqueidentifier,
    @IncludeInactive bit = 1
AS
BEGIN
    SET NOCOUNT ON;

    /*
      A non-member gets two empty result sets rather than an error, exactly as
      the branch list does. The API turns "no rows" into whatever it should
      mean; the procedure's job is to not hand anything over.
    */
    DECLARE @IsMember bit = dbo.fn_IsSchoolMember(@SchoolId, @UserUid);

    -- ---- result set 1: the team -------------------------------------------
    SELECT
        su.SchoolUserId,
        su.UserUid,
        su.FullName,
        su.DesignationText,
        su.RoleInSchool,
        su.Is_Active,
        su.CreatedOn,
        su.ModifiedOn,

        -- The true count, unfiltered. See the header.
        (SELECT COUNT(*)
         FROM dbo.t_app_school_user_branches ub
             INNER JOIN dbo.t_app_school_branches b
                 ON b.BranchId = ub.BranchId AND b.Is_Deleted = 0
         WHERE ub.SchoolUserId = su.SchoolUserId
           AND ub.Is_Active = 1
           AND ub.Is_Deleted = 0) AS BranchCount
    FROM dbo.t_app_school_users su
    WHERE @IsMember = 1
      AND su.SchoolId = @SchoolId
      AND su.Is_Deleted = 0
      AND (@IncludeInactive = 1 OR su.Is_Active = 1)
    /*
      Owners first, then everyone by role, then by name — and FullName is
      nullable, so the rows with no name sort last rather than to the top where
      they would look like the most important people on the team.
    */
    ORDER BY su.RoleInSchool,
             CASE WHEN su.FullName IS NULL THEN 1 ELSE 0 END,
             su.FullName,
             su.SchoolUserId;

    -- ---- result set 2: the branch links, through the caller's scope --------
    SELECT
        ub.SchoolUserId,
        ub.BranchId
    FROM dbo.t_app_school_users su
        INNER JOIN dbo.t_app_school_user_branches ub
            ON ub.SchoolUserId = su.SchoolUserId
           AND ub.Is_Active    = 1
           AND ub.Is_Deleted   = 0
        -- 🔴 THE SCOPE GATE, joined rather than checked, so it cannot be
        -- forgotten without deleting the table the query reads from (2.53).
        INNER JOIN dbo.fn_VisibleBranches(@SchoolId, @UserUid) v
            ON v.BranchId = ub.BranchId
    WHERE @IsMember = 1
      AND su.SchoolId  = @SchoolId
      AND su.Is_Deleted = 0
      AND (@IncludeInactive = 1 OR su.Is_Active = 1);
END
GO


/*==============================================================================
  USP_ProvisionSchoolUser — the jp_app half of an invitation.

  ---------------------------------------------------------------------------
  🔴 IDEMPOTENT ON UserUid, BECAUSE THE OTHER HALF IS IN ANOTHER DATABASE
  ---------------------------------------------------------------------------
  Inviting a colleague writes to two databases with no distributed transaction
  (2.2, 2.48): USP_InviteSchoolUser creates the account in jp_sso, and this
  creates the membership in jp_app. Step 1 can succeed and step 2 fail.

  What that leaves behind is precise and nasty: a person with a working account,
  a working invitation email, and no membership — who signs in and is told
  "your account is not linked to a school yet, sign out and back in", which is
  the exact confusion 3E went and fixed for teachers.

  So the retry has to work, which means this procedure has to be safe to run
  again with the same arguments:

      already an ACTIVE member  ->  Status 1, ALREADY_A_MEMBER, nothing written
      a removed member          ->  revived, with the role and details just sent
      no row at all             ->  inserted

  ⚠️ The already-a-member path deliberately does NOT update the role. An invite
  must not be a back door for changing a colleague's role — that is
  USP_SaveSchoolUserRole, which has the owner guard on it. Re-inviting the owner
  therefore does nothing at all, which is the correct amount.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_ProvisionSchoolUser
    @SchoolId        bigint,
    @UserUid         uniqueidentifier,          -- the CALLER
    @NewUserUid      uniqueidentifier,          -- the person being added
    @RoleInSchool    tinyint,
    @FullName        nvarchar(150)      = NULL,
    @DesignationText nvarchar(150)      = NULL,
    @BranchIds       dbo.BigIntIdList   READONLY,
    @ActionByUserId  bigint             = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL, @Message nvarchar(400) = NULL,
            @Id bigint = NULL, @Now datetime2 = SYSUTCDATETIME(),
            @branchesLinked int = 0;

    SET @FullName        = NULLIF(LTRIM(RTRIM(@FullName)), N'');
    SET @DesignationText = NULLIF(LTRIM(RTRIM(@DesignationText)), N'');

    DECLARE @existingId bigint = NULL, @existingActive tinyint = NULL;

    SELECT @existingId = SchoolUserId, @existingActive = Is_Active
    FROM dbo.t_app_school_users
    WHERE SchoolId = @SchoolId AND UserUid = @NewUserUid AND Is_Deleted = 0;

    IF dbo.fn_IsSchoolMember(@SchoolId, @UserUid) = 0
        SELECT @Code = 'NOT_FOUND', @Message = N'That school was not found.';

    /*
      🔴 RULE 2 — NO SECOND OWNER, EVER, NOT EVEN BY INVITATION.

      Rule 1 says an owner can never be demoted or deactivated. Adding a second
      one is therefore permanent: two people who can never be removed from a
      school neither of them may still work at. The ratchet only turns one way,
      and every school that discovers this discovers it too late.

      Ownership MOVES; it does not accumulate. The procedure that moves it does
      not exist yet, and when it does it must do both halves in one transaction:
      promote the new owner, DELETE their link rows (rule 3), and demote the old
      one to Senior HR. Written down here rather than left to be rediscovered by
      whoever first needs it.
    */
    ELSE IF @RoleInSchool = 1
        SELECT @Code = 'BUSINESS_RULE_VIOLATED',
               @Message = N'A school has exactly one owner and it cannot be given away by invitation. '
                        + N'Invite them as Senior HR — they will be able to do everything except manage the owner.';

    ELSE IF @RoleInSchool NOT IN (2, 3, 4)
        SELECT @Code = 'VALIDATION_FAILED',
               @Message = N'Choose a role: Senior HR, HR or Viewer.';

    ELSE IF @NewUserUid IS NULL
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The account to add is missing.';

    /*
      🔴 A CAMPUS THE CALLER CANNOT SEE CANNOT BE GRANTED.

      Refused rather than silently dropped. Silently dropping it means somebody
      ticks three campuses, sees "invitation sent", and their colleague can
      reach one — a bug reported weeks later as "the checkboxes do not save".

      This also closes self-escalation without a separate rule: a branch HR
      cannot grant anybody — themselves included — a campus they were never
      given, because fn_VisibleBranches does not return it for them.
    */
    ELSE IF EXISTS (SELECT 1 FROM @BranchIds i
                    WHERE NOT EXISTS (SELECT 1
                                      FROM dbo.fn_VisibleBranches(@SchoolId, @UserUid) v
                                      WHERE v.BranchId = i.Id))
        SELECT @Code = 'VALIDATION_FAILED',
               @Message = N'One of those campuses is not one you can assign.';

    IF @Code IS NULL AND @existingId IS NOT NULL AND @existingActive = 1
    BEGIN
        -- Already done. The retry path lands here, and so does re-inviting a
        -- colleague somebody forgot they had already added.
        SELECT @Status = 1, @Code = 'ALREADY_A_MEMBER', @Id = @existingId,
               @Message = N'That person is already on your team.';
    END
    ELSE IF @Code IS NULL
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            IF @existingId IS NOT NULL
            BEGIN
                /*
                  Somebody who was removed, coming back. Revived in place rather
                  than inserted beside: the filtered unique index would reject
                  the insert, and the SchoolUserId their history hangs off is
                  this one.
                */
                UPDATE dbo.t_app_school_users
                   SET Is_Active       = 1,
                       RoleInSchool    = @RoleInSchool,
                       FullName        = ISNULL(@FullName, FullName),
                       DesignationText = ISNULL(@DesignationText, DesignationText),
                       ModifiedOn      = @Now,
                       ModifiedBy      = @ActionByUserId
                 WHERE SchoolUserId = @existingId;

                SET @Id = @existingId;
                SET @Message = N'Access restored.';
            END
            ELSE
            BEGIN
                INSERT INTO dbo.t_app_school_users
                    (SchoolId, UserUid, RoleInSchool, FullName, DesignationText, CreatedBy)
                VALUES
                    (@SchoolId, @NewUserUid, @RoleInSchool, @FullName, @DesignationText, @ActionByUserId);

                SET @Id = SCOPE_IDENTITY();
                SET @Message = N'Invitation sent.';
            END

            /*
              The campuses, in the same transaction. A membership with no scope
              is a person who signs in and sees nothing, so this is not a
              follow-up call the caller could skip or fail halfway through.

              Revive-then-insert rather than insert alone: this person may have
              been scoped to these campuses before they were removed.
            */
            UPDATE ub
               SET ub.Is_Deleted = 0, ub.Is_Active = 1,
                   ub.ModifiedOn = @Now, ub.ModifiedBy = @ActionByUserId
            FROM dbo.t_app_school_user_branches ub
                INNER JOIN @BranchIds i ON i.Id = ub.BranchId
            WHERE ub.SchoolUserId = @Id AND ub.Is_Deleted = 1;

            INSERT INTO dbo.t_app_school_user_branches (SchoolUserId, BranchId, CreatedBy)
            SELECT @Id, i.Id, @ActionByUserId
            FROM @BranchIds i
            WHERE NOT EXISTS (SELECT 1 FROM dbo.t_app_school_user_branches ub
                              WHERE ub.SchoolUserId = @Id AND ub.BranchId = i.Id);

            SELECT @branchesLinked = COUNT(*) FROM @BranchIds;

            COMMIT TRANSACTION;

            SET @Status = 1;
        END TRY
        BEGIN CATCH
            DECLARE @E1 int = ERROR_NUMBER(), @S1 int = ERROR_SEVERITY(), @T1 int = ERROR_STATE(),
                    @P1 sysname = ERROR_PROCEDURE(), @L1 int = ERROR_LINE(),
                    @M1 nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            /*
              ⚠️ 2601 / 2627 here means a concurrent invitation for the same
              person won the race — the membership exists, which is what the
              caller wanted (2.48). Reported as already-done rather than as a
              failure, but only after RE-READING the row: "the index says it is
              there" is not the same as having seen it.
            */
            IF @E1 IN (2601, 2627)
            BEGIN
                SELECT @Id = SchoolUserId
                FROM dbo.t_app_school_users
                WHERE SchoolId = @SchoolId AND UserUid = @NewUserUid AND Is_Deleted = 0;

                IF @Id IS NOT NULL
                    SELECT @Status = 1, @Code = 'ALREADY_A_MEMBER',
                           @Message = N'That person is already on your team.';
            END

            IF @Status = 0
            BEGIN
                DECLARE @Params1 nvarchar(max) = (
                    SELECT @SchoolId AS schoolId, @NewUserUid AS newUserUid, @RoleInSchool AS roleInSchool
                    FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

                EXEC dbo.USP_LogError @ErrorNumber = @E1, @ErrorSeverity = @S1, @ErrorState = @T1,
                     @ErrorProcedure = @P1, @ErrorLine = @L1, @ErrorMessage = @M1,
                     @ParametersJson = @Params1, @ContextInfo = N'USP_ProvisionSchoolUser',
                     @CreatedBy = @ActionByUserId;

                THROW;
            END
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @Id AS Id,
           @branchesLinked AS BranchesLinked;
END
GO


/*==============================================================================
  USP_SaveSchoolUserRole — the role, and the details on the same card.

  ---------------------------------------------------------------------------
  WHY THE NAME AND DESIGNATION RIDE ALONG
  ---------------------------------------------------------------------------
  They are one dialog, one row and one edit as far as the person doing it is
  concerned. Splitting them into two procedures would mean two round trips, two
  ModifiedOn stamps for a single save, and a half-applied edit whenever the
  second one failed.

  🔴 THE OWNER'S NAME IS EDITABLE. THEIR ROLE IS NOT.

  That distinction matters more than it looks: every membership row that exists
  today has FullName NULL, including every owner's, because provisioning had no
  name to record and inventing one was refused (see 019_alter). If the guard
  were "the owner row cannot be touched", no owner could ever put their own name
  on their own team screen.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SaveSchoolUserRole
    @SchoolId        bigint,
    @UserUid         uniqueidentifier,      -- the CALLER
    @TargetUserUid   uniqueidentifier,      -- whose row is being changed
    @RoleInSchool    tinyint,
    @FullName        nvarchar(150) = NULL,
    @DesignationText nvarchar(150) = NULL,
    @ActionByUserId  bigint        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL, @Message nvarchar(400) = NULL,
            @Id bigint = NULL, @Now datetime2 = SYSUTCDATETIME(), @Changed bit = 0;

    SET @FullName        = NULLIF(LTRIM(RTRIM(@FullName)), N'');
    SET @DesignationText = NULLIF(LTRIM(RTRIM(@DesignationText)), N'');

    DECLARE @currentRole tinyint = NULL, @currentName nvarchar(150) = NULL,
            @currentDesignation nvarchar(150) = NULL;

    /*
      🔴 THE TARGET IS RESOLVED THROUGH @SchoolId, WHICH THE API TOOK FROM THE
      CALLER'S OWN MEMBERSHIP.

      So a school user naming another school's member gets NOT_FOUND from the
      WHERE clause — not a 403, and not a different message. There is nothing in
      the response to tell them whether that account exists at all.
    */
    SELECT @Id = su.SchoolUserId, @currentRole = su.RoleInSchool,
           @currentName = su.FullName, @currentDesignation = su.DesignationText
    FROM dbo.t_app_school_users su
    WHERE su.SchoolId   = @SchoolId
      AND su.UserUid    = @TargetUserUid
      AND su.Is_Deleted = 0;

    IF dbo.fn_IsSchoolMember(@SchoolId, @UserUid) = 0 OR @Id IS NULL
        SELECT @Code = 'NOT_FOUND', @Message = N'That team member was not found.';

    ELSE IF @RoleInSchool NOT IN (1, 2, 3, 4)
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'Choose a role.';

    /*
      🔴 RULE 1 — THE OWNER CANNOT BE DEMOTED. BY ANYONE. INCLUDING THEMSELVES.

      There is no "are you sure" for this and no override flag. A school with no
      owner cannot administer itself, cannot invite anybody to help, and cannot
      undo the change that got it there — the only route back is somebody
      editing the database, on a day when the school is already stuck.
    */
    ELSE IF @currentRole = 1 AND @RoleInSchool <> 1
        SELECT @Code = 'BUSINESS_RULE_VIOLATED',
               @Message = N'The owner''s role cannot be changed. Every school needs exactly one owner, and a school '
                        + N'without one cannot be administered by anybody — including you.';

    -- 🔴 RULE 2 — and nobody can be promoted into it. See USP_ProvisionSchoolUser.
    ELSE IF @currentRole <> 1 AND @RoleInSchool = 1
        SELECT @Code = 'BUSINESS_RULE_VIOLATED',
               @Message = N'A school has exactly one owner, and ownership is transferred rather than granted. '
                        + N'Senior HR can do everything except manage the owner.';

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            /*
              🔴 COMPUTE, COMPARE, THEN WRITE.

              A save that changes nothing must write nothing. 3D shipped a no-op
              that still stamped ModifiedOn, and it was found by an independent
              check rather than by the suite — "somebody edited this row" is
              evidence, and evidence that fires when nobody edited anything is
              worse than none.

              Every comparison is NULL-safe, because NULL <> anything is UNKNOWN
              and "had no designation, now has one" is the commonest edit here.
            */
            IF @currentRole <> @RoleInSchool

               OR (@currentName IS NULL     AND @FullName IS NOT NULL)
               OR (@currentName IS NOT NULL AND @FullName IS NULL)
               OR (@currentName <> @FullName)

               OR (@currentDesignation IS NULL     AND @DesignationText IS NOT NULL)
               OR (@currentDesignation IS NOT NULL AND @DesignationText IS NULL)
               OR (@currentDesignation <> @DesignationText)
            BEGIN
                UPDATE dbo.t_app_school_users
                   SET RoleInSchool    = @RoleInSchool,
                       FullName        = @FullName,
                       DesignationText = @DesignationText,
                       ModifiedOn      = @Now,
                       ModifiedBy      = @ActionByUserId
                 WHERE SchoolUserId = @Id;

                SET @Changed = 1;
            END

            SELECT @Status = 1,
                   @Message = CASE WHEN @Changed = 1 THEN N'Saved.' ELSE N'Nothing to change.' END;
        END TRY
        BEGIN CATCH
            DECLARE @E2 int = ERROR_NUMBER(), @S2 int = ERROR_SEVERITY(), @T2 int = ERROR_STATE(),
                    @P2 sysname = ERROR_PROCEDURE(), @L2 int = ERROR_LINE(),
                    @M2 nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            DECLARE @Params2 nvarchar(max) = (
                SELECT @SchoolId AS schoolId, @TargetUserUid AS targetUserUid, @RoleInSchool AS roleInSchool
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @E2, @ErrorSeverity = @S2, @ErrorState = @T2,
                 @ErrorProcedure = @P2, @ErrorLine = @L2, @ErrorMessage = @M2,
                 @ParametersJson = @Params2, @ContextInfo = N'USP_SaveSchoolUserRole',
                 @CreatedBy = @ActionByUserId;

            THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @Id AS Id, @Changed AS Changed;
END
GO


/*==============================================================================
  USP_SaveSchoolUserBranches — full-set sync, the 3C/3D pattern (2.53).

  Send the whole desired set; diff against what is stored; INSERT what is new,
  SOFT-DELETE what has gone, REVIVE a tombstone rather than inserting beside it.

  ---------------------------------------------------------------------------
  🔴 THE REMOVAL STEP IS LIMITED TO CAMPUSES THE CALLER CAN SEE
  ---------------------------------------------------------------------------
  This is the one thing in this file that a careful reader should stop at.

  A full-set sync removes what is absent from the incoming set. Combined with a
  screen that only ever SHOWED the caller their own campuses, the plain pattern
  does something nobody asked for: an HR at the North campus opens a colleague's
  scope, sees one tick, saves — and silently revokes that colleague's access to
  the two southern campuses they could not see and were never shown.

  It would look exactly like a working save. The colleague would find out by
  losing a campus.

  So the GONE step joins through fn_VisibleBranches: links to campuses outside
  the caller's own scope are left completely alone. An owner sees everything, so
  for an owner this is the ordinary full-set sync with no exception at all.

  ⚠️ The consequence, stated rather than hidden: a non-owner's save is a sync
  of THEIR SLICE of somebody's access, not of all of it. The counts returned are
  the counts of what actually happened, so the screen can say so.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SaveSchoolUserBranches
    @SchoolId       bigint,
    @UserUid        uniqueidentifier,      -- the CALLER
    @TargetUserUid  uniqueidentifier,
    @BranchIds      dbo.BigIntIdList READONLY,
    @ActionByUserId bigint = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL, @Message nvarchar(400) = NULL,
            @Id bigint = NULL, @Now datetime2 = SYSUTCDATETIME(),
            @added int = 0, @restored int = 0, @removed int = 0;

    DECLARE @targetRole tinyint = NULL;

    SELECT @Id = su.SchoolUserId, @targetRole = su.RoleInSchool
    FROM dbo.t_app_school_users su
    WHERE su.SchoolId   = @SchoolId
      AND su.UserUid    = @TargetUserUid
      AND su.Is_Deleted = 0;

    IF dbo.fn_IsSchoolMember(@SchoolId, @UserUid) = 0 OR @Id IS NULL
        SELECT @Code = 'NOT_FOUND', @Message = N'That team member was not found.';

    /*
      🔴 RULE 3 — AN OWNER IS NEVER ENUMERATED.

      Refused rather than accepted-and-ignored. Accepting it would write rows
      that fn_VisibleBranches does not read, and the first time somebody debugs
      "why can the owner see campus X" they would find those rows and believe
      them. A screen that offers this control for an owner is the screen with
      the bug, and this is how it finds out.
    */
    ELSE IF @targetRole = 1
        SELECT @Code = 'BUSINESS_RULE_VIOLATED',
               @Message = N'The owner can already see every campus, so there is nothing to choose. '
                        + N'Campus access is set for the people you invite.';

    -- 🔴 The same gate as the invite: you cannot grant what you cannot see.
    ELSE IF EXISTS (SELECT 1 FROM @BranchIds i
                    WHERE NOT EXISTS (SELECT 1
                                      FROM dbo.fn_VisibleBranches(@SchoolId, @UserUid) v
                                      WHERE v.BranchId = i.Id))
        SELECT @Code = 'VALIDATION_FAILED',
               @Message = N'One of those campuses is not one you can assign.';

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            -- 1. GONE — live, absent from the incoming set, AND visible to the
            --    caller. The third condition is the whole point; see the header.
            UPDATE ub
               SET ub.Is_Deleted = 1, ub.ModifiedOn = @Now, ub.ModifiedBy = @ActionByUserId
            FROM dbo.t_app_school_user_branches ub
                INNER JOIN dbo.fn_VisibleBranches(@SchoolId, @UserUid) v ON v.BranchId = ub.BranchId
            WHERE ub.SchoolUserId = @Id
              AND ub.Is_Deleted = 0
              AND NOT EXISTS (SELECT 1 FROM @BranchIds i WHERE i.Id = ub.BranchId);
            SET @removed = @@ROWCOUNT;

            -- 2. BACK — tombstoned and wanted again. Revived in place, which
            --    keeps the original id and satisfies the filtered unique index
            --    an INSERT would collide with.
            UPDATE ub
               SET ub.Is_Deleted = 0, ub.Is_Active = 1,
                   ub.ModifiedOn = @Now, ub.ModifiedBy = @ActionByUserId
            FROM dbo.t_app_school_user_branches ub
                INNER JOIN @BranchIds i ON i.Id = ub.BranchId
            WHERE ub.SchoolUserId = @Id AND ub.Is_Deleted = 1;
            SET @restored = @@ROWCOUNT;

            -- 3. NEW — step 2 revived every tombstone, so anything still
            --    missing has genuinely never existed.
            INSERT INTO dbo.t_app_school_user_branches (SchoolUserId, BranchId, CreatedBy)
            SELECT @Id, i.Id, @ActionByUserId
            FROM @BranchIds i
            WHERE NOT EXISTS (SELECT 1 FROM dbo.t_app_school_user_branches ub
                              WHERE ub.SchoolUserId = @Id AND ub.BranchId = i.Id);
            SET @added = @@ROWCOUNT;

            /*
              ⚠️ The parent row is NOT stamped here.

              Campus access is a fact about the link rows, which carry their own
              ModifiedOn. Touching t_app_school_users as well would mean a save
              that changed nothing at all still marked the membership as edited
              — the same no-op write 3D was caught doing (2.54), one table over.
            */

            COMMIT TRANSACTION;

            SELECT @Status = 1,
                   @Message = CASE WHEN @added + @restored + @removed = 0
                                   THEN N'Nothing to change.'
                                   ELSE N'Campus access saved.' END;
        END TRY
        BEGIN CATCH
            DECLARE @E3 int = ERROR_NUMBER(), @S3 int = ERROR_SEVERITY(), @T3 int = ERROR_STATE(),
                    @P3 sysname = ERROR_PROCEDURE(), @L3 int = ERROR_LINE(),
                    @M3 nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            DECLARE @Params3 nvarchar(max) = (
                SELECT @SchoolId AS schoolId, @TargetUserUid AS targetUserUid
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @E3, @ErrorSeverity = @S3, @ErrorState = @T3,
                 @ErrorProcedure = @P3, @ErrorLine = @L3, @ErrorMessage = @M3,
                 @ParametersJson = @Params3, @ContextInfo = N'USP_SaveSchoolUserBranches',
                 @CreatedBy = @ActionByUserId;

            THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @Id AS Id,
           @added AS Added, @restored AS Restored, @removed AS Removed;
END
GO


/*==============================================================================
  USP_DeactivateSchoolUser — revoke access, keep the history.

  ---------------------------------------------------------------------------
  🔴 Is_Active = 0. NOT Is_Deleted = 1, AND NOT A DELETE.
  ---------------------------------------------------------------------------
  fn_VisibleBranches and fn_IsSchoolMember both require Is_Active = 1, so this
  single column closes every school screen for that person immediately.

  What it does NOT do is erase them. "Verified by" on a document, "posted by" on
  a job, "shortlisted by" on an application — all of those point at a person who
  has now left, and all of them must stay true. An HR leaving a school does not
  un-verify the documents they checked.

  ⚠️ THE LINK ROWS ARE LEFT ALONE, on purpose. They grant nothing while the
  membership is inactive, and keeping them means re-inviting somebody restores
  the campuses they had rather than silently giving them none. Re-invite IS the
  undo — USP_ProvisionSchoolUser revives this row.

  ⚠️ THE SSO ACCOUNT IS NOT TOUCHED. It lives in another database (2.2), and
  the API revokes their sessions as a second step. This procedure returning
  success means the membership is inactive, nothing more — which is why the
  caller reports the token revocation separately rather than folding it in.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_DeactivateSchoolUser
    @SchoolId       bigint,
    @UserUid        uniqueidentifier,      -- the CALLER
    @TargetUserUid  uniqueidentifier,
    @ActionByUserId bigint = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL, @Message nvarchar(400) = NULL,
            @Id bigint = NULL, @Now datetime2 = SYSUTCDATETIME();

    DECLARE @targetRole tinyint = NULL, @targetActive tinyint = NULL;

    SELECT @Id = su.SchoolUserId, @targetRole = su.RoleInSchool, @targetActive = su.Is_Active
    FROM dbo.t_app_school_users su
    WHERE su.SchoolId   = @SchoolId
      AND su.UserUid    = @TargetUserUid
      AND su.Is_Deleted = 0;

    IF dbo.fn_IsSchoolMember(@SchoolId, @UserUid) = 0 OR @Id IS NULL
        SELECT @Code = 'NOT_FOUND', @Message = N'That team member was not found.';

    /*
      🔴 RULE 1, THE OTHER HALF. The owner cannot be deactivated either.

      Checked BEFORE the self-check, so an owner removing themselves is told the
      real reason — that the school would be left with nobody who can administer
      it — rather than the generic "you cannot remove your own access", which
      would leave them thinking a colleague could do it for them.
    */
    ELSE IF @targetRole = 1
        SELECT @Code = 'BUSINESS_RULE_VIOLATED',
               @Message = N'The owner''s access cannot be removed. A school with no owner cannot be administered '
                        + N'by anybody, and there is no way back from it inside the product.';

    /*
      ⚠️ AND NOBODY REMOVES THEMSELVES.

      Not because it would break anything — a non-owner locking themselves out
      leaves the school perfectly administrable — but because it is always a
      mistake. The row they meant to click was the one above or below, and the
      cost of being wrong is being locked out of the screen that would let them
      undo it.
    */
    ELSE IF @TargetUserUid = @UserUid
        SELECT @Code = 'BUSINESS_RULE_VIOLATED',
               @Message = N'You cannot remove your own access. Ask a colleague who manages the team to do it.';

    ELSE IF @targetActive = 0
    BEGIN
        -- Already done. Idempotent, so a double click or a retry is not an error.
        SELECT @Status = 1, @Code = 'ALREADY_INACTIVE',
               @Message = N'That person''s access had already been removed.';
    END

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            UPDATE dbo.t_app_school_users
               SET Is_Active  = 0,
                   ModifiedOn = @Now,
                   ModifiedBy = @ActionByUserId
             WHERE SchoolUserId = @Id
               AND Is_Active    = 1;      -- lost race: somebody else did it first

            IF @@ROWCOUNT = 0
                SELECT @Status = 1, @Code = 'ALREADY_INACTIVE',
                       @Message = N'That person''s access had already been removed.';
            ELSE
                SELECT @Status = 1, @Message = N'Access removed.';
        END TRY
        BEGIN CATCH
            DECLARE @E4 int = ERROR_NUMBER(), @S4 int = ERROR_SEVERITY(), @T4 int = ERROR_STATE(),
                    @P4 sysname = ERROR_PROCEDURE(), @L4 int = ERROR_LINE(),
                    @M4 nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            DECLARE @Params4 nvarchar(max) = (
                SELECT @SchoolId AS schoolId, @TargetUserUid AS targetUserUid
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @E4, @ErrorSeverity = @S4, @ErrorState = @T4,
                 @ErrorProcedure = @P4, @ErrorLine = @L4, @ErrorMessage = @M4,
                 @ParametersJson = @Params4, @ContextInfo = N'USP_DeactivateSchoolUser',
                 @CreatedBy = @ActionByUserId;

            THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @Id AS Id;
END
GO

PRINT '    School team procedures ready.';
GO
