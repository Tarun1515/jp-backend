/*
================================================================================
  PHASE 6C — NOTIFICATIONS

    USP_CreateNotification          one recipient, one row
    USP_CreateSchoolNotifications   fan out to a school's team, branch-scoped
    USP_NotifyApplicationStatus     one place that knows which stages notify
    USP_NotifyOffer                 offers, both directions
    USP_NotifyInvite                invitations, both directions
    USP_GetMyNotifications          the caller's own, newest first, paged
    USP_GetUnreadNotificationCount  the badge
    USP_MarkNotificationRead        one row, the caller's own or nothing
    USP_MarkAllNotificationsRead    everything unread of the caller's
    USP_GetPendingNotificationEmails / USP_MarkNotificationEmailSent

--------------------------------------------------------------------------------
  🔴 THE CREATORS RUN INSIDE THE EVENT'S OWN TRANSACTION
--------------------------------------------------------------------------------
  Both creators are written to be called from USP_ApplyToJob, USP_SendOffer,
  USP_RespondToInvite and the rest — same database, same transaction. So an
  application that exists always has its notification, and a rolled-back
  application has none.

  ⚠️ This is NOT a contradiction of 2.48. That decision is about CROSS-DATABASE
  orchestration having no distributed transaction, and notifications live in
  jp_app alongside every event that creates them. Where an atomic guarantee is
  available for free, taking it is not over-engineering — it is the difference
  between "the teacher was told" and "the teacher was probably told".

  🔴 Email is the opposite case and is deliberately NOT here. Sending mail
  inside a transaction means holding locks on an SMTP round trip, and a failed
  send would roll back the event that caused it. The dispatcher polls
  USP_GetPendingNotificationEmails afterwards and stamps EmailSentOn.

--------------------------------------------------------------------------------
  🔒 SCOPE — RecipientUserUid, every time
--------------------------------------------------------------------------------
  Every read and every write takes @UserUid and filters by it. There is no
  @NotificationId-only path, no admin override, and no "for this school"
  listing — 030's header explains why the column that would allow one does not
  exist.

  ⚠️ Reading somebody else's id gives the 404 shape (2.6), never a 403: a 403
  would confirm the row exists.

--------------------------------------------------------------------------------
  🔴 THE TWO CREATORS RETURN NO RESULT SET, AND THAT IS NOT TIDINESS
--------------------------------------------------------------------------------
  They use an OUTPUT parameter instead of the Status/Code/Message/Id SELECT that
  every other procedure here ends with (2.21). The reason is a trap that would
  have broken working endpoints silently.

  A procedure called with EXEC from inside another procedure emits its result
  sets to the CLIENT, in execution order. So this:

      USP_ApplyToJob
        … INSERT the application …
        EXEC USP_CreateSchoolNotifications   -- would emit result set #1
        SELECT @Status, @Code, @Message, @Id -- the real answer, result set #2

  …hands Dapper's QueryFirstOrDefault the NOTIFICATION's row. Apply would
  return "Notifications created." with the recipient count as its Id, and
  nothing would error: the shapes are identical, because 2.21 made them
  identical.

  ⚠️ Writing a notification must never be able to change what the event it
  belongs to says. An OUTPUT parameter cannot reach the wire, so it cannot.
================================================================================
*/
USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*==============================================================================
  USP_CreateNotification — one person is told one thing.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_CreateNotification
    @RecipientUserUid   uniqueidentifier,
    @NotificationTypeId int,
    @Title              nvarchar(200),
    @Body               nvarchar(1000) = NULL,
    @ActionUrl          nvarchar(300)  = NULL,
    @RefEntityTypeId    tinyint        = NULL,
    @RefEntityUid       uniqueidentifier = NULL,

    /** See the header: an OUTPUT parameter, never a result set. */
    @NotificationId     bigint         = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    /*
      ⚠️ A NULL recipient is a caller bug, not a condition to handle. Silently
      skipping would mean an event that quietly notifies nobody — the failure
      mode is a support call six months later, so it fails here instead.
    */
    IF @RecipientUserUid IS NULL
    BEGIN
        RAISERROR(N'USP_CreateNotification: @RecipientUserUid is required.', 16, 1);

        RETURN;
    END

    INSERT INTO dbo.t_app_notifications
        (RecipientUserUid, NotificationTypeId, Title, Body, ActionUrl, RefEntityTypeId, RefEntityUid)
    VALUES
        (@RecipientUserUid, @NotificationTypeId, @Title, @Body, @ActionUrl, @RefEntityTypeId, @RefEntityUid);

    SET @NotificationId = CAST(SCOPE_IDENTITY() AS bigint);
END
GO

/*==============================================================================
  USP_CreateSchoolNotifications — the school's team is told one thing.

  🔴 FAN-OUT, AND THE RECIPIENT SET IS THE BRANCH SCOPE.

  One row per user, because "read" belongs to a person. The set comes from
  fn_VisibleBranches (3G), which already answers "which campuses can this user
  see" — an owner sees all of them, a campus-scoped viewer sees one.

  ⚠️ So a viewer scoped to the Kalyan Road campus is not told about an
  application to the North Wing. That is the same answer the applicant list
  gives them, and a notification that leads to a 404 is worse than no
  notification.

  ⚠️ @BranchId may be NULL for a school-wide event. Then everybody on the team
  is told, because there is no campus to scope by.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_CreateSchoolNotifications
    @SchoolId           bigint,
    @BranchId           bigint = NULL,
    @NotificationTypeId int,
    @Title              nvarchar(200),
    @Body               nvarchar(1000) = NULL,
    @ActionUrl          nvarchar(300)  = NULL,
    @RefEntityTypeId    tinyint        = NULL,
    @RefEntityUid       uniqueidentifier = NULL,

    /*
      ⚠️ The person who caused the event does not need telling about it. Passing
      their uid here keeps "you shortlisted somebody" out of your own list.
    */
    @ExcludeUserUid     uniqueidentifier = NULL,

    /** How many people were told. See the header for why this is not a SELECT. */
    @RecipientCount     int            = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.t_app_notifications
        (RecipientUserUid, NotificationTypeId, Title, Body, ActionUrl, RefEntityTypeId, RefEntityUid)
    SELECT su.UserUid, @NotificationTypeId, @Title, @Body, @ActionUrl, @RefEntityTypeId, @RefEntityUid
    FROM dbo.t_app_school_users su
    WHERE su.SchoolId   = @SchoolId
      AND su.Is_Active  = 1
      AND su.Is_Deleted = 0
      AND (@ExcludeUserUid IS NULL OR su.UserUid <> @ExcludeUserUid)
      AND (
            @BranchId IS NULL
            OR EXISTS (SELECT 1 FROM dbo.fn_VisibleBranches(@SchoolId, su.UserUid) vb
                       WHERE vb.BranchId = @BranchId)
          );

    SET @RecipientCount = @@ROWCOUNT;

    /*
      ⚠️ ZERO IS NOT AN ERROR HERE, and it is worth saying why. A school whose
      only user is scoped away from this campus has nobody to tell, and the
      event still happened. The caller gets the count and can log it; refusing
      the event because nobody was listening would be absurd.
    */
END
GO

/*==============================================================================
  USP_NotifyApplicationStatus — a teacher is told their application moved.

  🔴 ONE PLACE, BECAUSE TWO PATHS PRODUCE THE SAME MOVE.

  An application reaches stage 2 either because the school set it explicitly
  (USP_SetApplicationStatus) or because somebody OPENED it
  (USP_MarkApplicationViewed, which is how it actually happens). Writing the
  notification at both call sites would mean two copies of the same decision,
  and the first time one was edited the teacher would be told different things
  depending on which path the school happened to take.

  ⚠️ Which stages notify is decided HERE, not by the caller. 2, 3 and 6 — the
  school looked, shortlisted, or decided not to proceed. The silences are
  argued in 016 at the call site, and the important one is 5 Selected: that is
  the school's internal decision, and what reaches the teacher is the OFFER
  (2.73's two machines).

  ⚠️ No @Remarks parameter, deliberately. On a rejection that field is the
  school's private note and 016's header says it never reaches the teacher. A
  procedure that cannot accept it cannot leak it.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_NotifyApplicationStatus
    @ApplicationId bigint,
    @ToStatusId    int
AS
BEGIN
    SET NOCOUNT ON;

    IF @ToStatusId NOT IN (2, 3, 6) RETURN;

    DECLARE @TypeId int =
        CASE @ToStatusId WHEN 2 THEN 2      -- APPLICATION_VIEWED
                         WHEN 3 THEN 3      -- APPLICATION_SHORTLIST
                         ELSE 4 END;        -- APPLICATION_REJECTED

    DECLARE @Recipient uniqueidentifier,
            @JobTitle  nvarchar(200),
            @School    nvarchar(200),
            @AppUid    uniqueidentifier;

    SELECT @Recipient = t.UserUid,
           @JobTitle  = j.JobTitle,
           @School    = sc.SchoolName,
           @AppUid    = a.ApplicationUid
    FROM dbo.t_app_applications a
        INNER JOIN dbo.t_app_teachers t ON t.TeacherId = a.TeacherId
        INNER JOIN dbo.t_app_jobs     j ON j.JobId     = a.JobId
        INNER JOIN dbo.t_app_schools sc ON sc.SchoolId = a.SchoolId
    WHERE a.ApplicationId = @ApplicationId;

    IF @Recipient IS NULL RETURN;   -- the row went away under us; nothing to say

    /*
      ⚠️ The title is the stage's own TEACHER-FACING word, read from the master
      rather than written here. 5B's lesson: a filter must never say "Rejected"
      above a row that says "Not selected", and a notification sitting beside
      that row is held to the same standard.
    */
    DECLARE @Title nvarchar(200) =
        (SELECT TeacherFacingName FROM dbo.m_app_application_status
         WHERE ApplicationStatusId = @ToStatusId);

    DECLARE @Body nvarchar(1000) = @School + N' — ' + @JobTitle;

    EXEC dbo.USP_CreateNotification
         @RecipientUserUid   = @Recipient,
         @NotificationTypeId = @TypeId,
         @Title              = @Title,
         @Body               = @Body,
         @ActionUrl          = N'/applications',
         @RefEntityTypeId    = 1,
         @RefEntityUid       = @AppUid;
END
GO

/*==============================================================================
  USP_NotifyOffer — one side of an offer tells the other.

  🔴 THE EVENT IS NAMED, NOT INFERRED FROM THE ROW'S CURRENT STATUS.

  It would be shorter to read OfferStatusId and decide from that. It would also
  be wrong: 2.73 allows a declined offer to be followed by a NEW one on the same
  application, so by the time anything reads the row the status may already
  describe a later event. The caller knows which thing just happened; the row
  only knows where it ended up.

  ⚠️ Direction follows the event, and it is not symmetric. Sending, withdrawing
  and confirming a hire are things a SCHOOL does, so the teacher is told.
  Accepting and declining are things a TEACHER does, so the school's team is.
  029's AudienceId records the same fact for each type, and the two must agree —
  notifications.mjs asserts that they do.

  🔒 Salary is NOT in the body. It is in the offer, and the offer is one tap
  away; putting it in a notification puts it in an email (type 5 sends one) and
  into whatever notification history a shared screen is left open on.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_NotifyOffer
    @OfferId bigint,
    @Event   varchar(20),          -- SENT · ACCEPTED · DECLINED · WITHDRAWN · HIRED
    @ActorUserUid uniqueidentifier = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TypeId int =
        CASE @Event WHEN 'SENT'      THEN 5
                    WHEN 'ACCEPTED'  THEN 6
                    WHEN 'DECLINED'  THEN 7
                    WHEN 'WITHDRAWN' THEN 8
                    WHEN 'HIRED'     THEN 9
                    ELSE NULL END;

    /*
      ⚠️ An unknown event is a caller bug and fails loudly. Returning quietly
      would mean a new offer action that silently tells nobody — and the symptom
      would be a teacher who was never informed, months later.
    */
    IF @TypeId IS NULL
    BEGIN
        RAISERROR(N'USP_NotifyOffer: unknown event ''%s''.', 16, 1, @Event);

        RETURN;
    END

    DECLARE @TeacherUserUid uniqueidentifier, @TeacherName nvarchar(150),
            @SchoolId bigint, @BranchId bigint, @SchoolName nvarchar(200),
            @JobTitle nvarchar(200), @OfferUid uniqueidentifier;

    SELECT @TeacherUserUid = t.UserUid,
           @TeacherName    = t.FullName,
           @SchoolId       = o.SchoolId,
           @BranchId       = o.BranchId,
           @SchoolName     = sc.SchoolName,
           @JobTitle       = j.JobTitle,
           @OfferUid       = o.OfferUid
    FROM dbo.t_app_offers o
        INNER JOIN dbo.t_app_teachers     t ON t.TeacherId = o.TeacherId
        INNER JOIN dbo.t_app_schools     sc ON sc.SchoolId = o.SchoolId
        INNER JOIN dbo.t_app_applications a ON a.ApplicationId = o.ApplicationId
        INNER JOIN dbo.t_app_jobs         j ON j.JobId = a.JobId
    WHERE o.OfferId = @OfferId;

    IF @OfferUid IS NULL RETURN;

    DECLARE @Title nvarchar(200) =
        (SELECT Name FROM dbo.m_app_notification_type WHERE NotificationTypeId = @TypeId);

    IF @Event IN ('SENT', 'WITHDRAWN', 'HIRED')
    BEGIN
        DECLARE @TeacherBody nvarchar(1000) = @SchoolName + N' — ' + @JobTitle;

        EXEC dbo.USP_CreateNotification
             @RecipientUserUid   = @TeacherUserUid,
             @NotificationTypeId = @TypeId,
             @Title              = @Title,
             @Body               = @TeacherBody,
             @ActionUrl          = N'/offers',
             @RefEntityTypeId    = 3,
             @RefEntityUid       = @OfferUid;

        RETURN;
    END

    /* ACCEPTED / DECLINED — the school's team, branch-scoped. */
    DECLARE @SchoolBody nvarchar(1000) = @TeacherName + N' — ' + @JobTitle;

    EXEC dbo.USP_CreateSchoolNotifications
         @SchoolId           = @SchoolId,
         @BranchId           = @BranchId,
         @NotificationTypeId = @TypeId,
         @Title              = @Title,
         @Body               = @SchoolBody,
         @ActionUrl          = N'/applicants',
         @RefEntityTypeId    = 3,
         @RefEntityUid       = @OfferUid,
         @ExcludeUserUid     = @ActorUserUid;
END
GO

/*==============================================================================
  USP_NotifyInvite — an invitation, and the answer to one.

  🔒 THE CONTACT RULE IS WHY THIS PROCEDURE IS WORTH READING CAREFULLY.

  An invitation reaches somebody who has no relationship with the school yet.
  So the teacher's notification names the SCHOOL and carries the school's own
  message, and the school's notification names the TEACHER — whose name the
  school already had from the search results that let it invite them (019
  returns the name and never the contact).

  ⚠️ Nothing here is unlocked by being notified. Consent is the ACCEPTED row
  (2.56, 027's IsConsent) and nothing else; a notification is a sentence, not a
  grant.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_NotifyInvite
    @InviteId bigint,
    @Event    varchar(20),         -- RECEIVED · ACCEPTED · IGNORED
    @ActorUserUid uniqueidentifier = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TypeId int =
        CASE @Event WHEN 'RECEIVED' THEN 10
                    WHEN 'ACCEPTED' THEN 11
                    WHEN 'IGNORED'  THEN 12
                    ELSE NULL END;

    IF @TypeId IS NULL
    BEGIN
        RAISERROR(N'USP_NotifyInvite: unknown event ''%s''.', 16, 1, @Event);

        RETURN;
    END

    DECLARE @TeacherUserUid uniqueidentifier, @TeacherName nvarchar(150),
            @SchoolId bigint, @BranchId bigint, @SchoolName nvarchar(200),
            @InviteUid uniqueidentifier, @InviteMessage nvarchar(1000);

    SELECT @TeacherUserUid = t.UserUid,
           @TeacherName    = t.FullName,
           @SchoolId       = i.SchoolId,
           @BranchId       = i.BranchId,
           @SchoolName     = sc.SchoolName,
           @InviteUid      = i.InviteUid,
           @InviteMessage  = i.[Message]
    FROM dbo.t_app_teacher_invites i
        INNER JOIN dbo.t_app_teachers t ON t.TeacherId = i.TeacherId
        INNER JOIN dbo.t_app_schools sc ON sc.SchoolId = i.SchoolId
    WHERE i.InviteId = @InviteId;

    IF @InviteUid IS NULL RETURN;

    DECLARE @Title nvarchar(200) =
        (SELECT Name FROM dbo.m_app_notification_type WHERE NotificationTypeId = @TypeId);

    IF @Event = 'RECEIVED'
    BEGIN
        /*
          ⚠️ The school's own message is the body when there is one, because a
          school that took the trouble to write something deserves to have it
          read. Falling back to the school's name keeps the notification
          meaningful when they did not.
        */
        DECLARE @InviteBody nvarchar(1000) =
            @SchoolName + CASE WHEN @InviteMessage IS NULL THEN N'' ELSE N' — ' + @InviteMessage END;

        EXEC dbo.USP_CreateNotification
             @RecipientUserUid   = @TeacherUserUid,
             @NotificationTypeId = @TypeId,
             @Title              = @Title,
             @Body               = @InviteBody,
             @ActionUrl          = N'/invitations',
             @RefEntityTypeId    = 2,
             @RefEntityUid       = @InviteUid;

        RETURN;
    END

    /* ACCEPTED / IGNORED — the school's team. */
    EXEC dbo.USP_CreateSchoolNotifications
         @SchoolId           = @SchoolId,
         @BranchId           = @BranchId,
         @NotificationTypeId = @TypeId,
         @Title              = @Title,
         @Body               = @TeacherName,
         @ActionUrl          = N'/teacher-search/invites',
         @RefEntityTypeId    = 2,
         @RefEntityUid       = @InviteUid,
         @ExcludeUserUid     = @ActorUserUid;
END
GO

/*==============================================================================
  USP_GetMyNotifications — the caller's own list.

  ⚠️ Returns the TYPE's code and name alongside each row so a screen can group them
  and pick an icon without a second call, and TotalRecords via COUNT(*) OVER () so the
  pager is server-side from day one (G29's lesson).
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetMyNotifications
    @UserUid    uniqueidentifier,
    @UnreadOnly bit = 0,
    @PageNumber int = 1,
    @PageSize   int = 20
AS
BEGIN
    SET NOCOUNT ON;

    /* Clamped here, not trusted from the wire — same as 019's search. */
    IF @PageSize IS NULL OR @PageSize < 1  SET @PageSize = 20;
    IF @PageSize > 100                     SET @PageSize = 100;
    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;

    SELECT
        n.NotificationId,
        n.NotificationUid,
        nt.Code             AS TypeCode,
        nt.Name             AS TypeName,
        n.Title,
        n.Body,
        n.ActionUrl,
        n.RefEntityTypeId,
        n.RefEntityUid,

        /*
          ⚠️ 2.61 — the underscore columns never reach a DTO under their storage
          name. IsRead is already camel-safe; Is_Deleted does not leave here at
          all, because a deleted notification is not a notification.
        */
        n.IsRead,
        n.ReadOn,
        n.CreatedOn,
        COUNT(*) OVER ()    AS TotalRecords
    FROM dbo.t_app_notifications n
        INNER JOIN dbo.m_app_notification_type nt ON nt.NotificationTypeId = n.NotificationTypeId
    WHERE n.RecipientUserUid = @UserUid        -- 🔒 the only scope there is
      AND n.Is_Deleted = 0
      AND (@UnreadOnly = 0 OR n.IsRead = 0)
    ORDER BY n.CreatedOn DESC, n.NotificationId DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END
GO

/*==============================================================================
  USP_GetUnreadNotificationCount — the badge, and nothing else.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetUnreadNotificationCount
    @UserUid uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;

    SELECT COUNT(*) AS UnreadCount
    FROM dbo.t_app_notifications
    WHERE RecipientUserUid = @UserUid
      AND IsRead = 0
      AND Is_Deleted = 0;
END
GO

/*==============================================================================
  USP_MarkNotificationRead — one row, the caller's own or nothing.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_MarkNotificationRead
    @UserUid        uniqueidentifier,
    @NotificationId bigint
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now datetime2(3) = SYSUTCDATETIME();

    UPDATE dbo.t_app_notifications
       SET IsRead     = 1,
           ReadOn     = @Now,
           RowVersion = RowVersion + 1,
           ModifiedOn = @Now
    WHERE NotificationId   = @NotificationId
      AND RecipientUserUid = @UserUid       -- 🔒 somebody else's id updates nothing
      AND IsRead           = 0
      AND Is_Deleted       = 0;

    DECLARE @Touched int = @@ROWCOUNT;

    /*
      🔴 ALREADY READ IS A SUCCESS, NOT AN ERROR (2.48's shape).

      A list that marks rows read as they scroll past will send the same id
      twice, and the second call is not a mistake. So the distinction drawn here
      is "does this row belong to you", not "did you change anything".

      ⚠️ Which means @@ROWCOUNT = 0 cannot be read as "not found" — it is also
      what an already-read row returns. The existence check is separate and it
      is the one that decides 404 (2.6).
    */
    IF @Touched = 0
       AND NOT EXISTS (SELECT 1 FROM dbo.t_app_notifications
                       WHERE NotificationId = @NotificationId
                         AND RecipientUserUid = @UserUid
                         AND Is_Deleted = 0)
    BEGIN
        SELECT 0 AS [Status], 'NOT_FOUND' AS Code,
               N'That notification was not found.' AS [Message], NULL AS Id;

        RETURN;
    END

    SELECT 1 AS [Status], NULL AS Code, N'Marked as read.' AS [Message], @NotificationId AS Id;
END
GO

/*==============================================================================
  USP_MarkAllNotificationsRead — everything of the caller's that is unread.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_MarkAllNotificationsRead
    @UserUid uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now datetime2(3) = SYSUTCDATETIME();

    UPDATE dbo.t_app_notifications
       SET IsRead     = 1,
           ReadOn     = @Now,
           RowVersion = RowVersion + 1,
           ModifiedOn = @Now
    WHERE RecipientUserUid = @UserUid
      AND IsRead     = 0
      AND Is_Deleted = 0;

    /* Nothing unread is a success — the user's intent is already satisfied. */
    SELECT 1 AS [Status], NULL AS Code, N'All caught up.' AS [Message],
           CAST(@@ROWCOUNT AS bigint) AS Id;
END
GO

/*==============================================================================
  USP_GetPendingNotificationEmails — what the dispatcher still owes.

  🔴 The recipient's ADDRESS is deliberately absent. Users live in jp_sso and
  2.2 forbids the join, so this returns the uid and the API resolves the address
  — which also means this procedure cannot become a way to read a mailing list
  out of jp_app.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetPendingNotificationEmails
    @MaxRows int = 50
AS
BEGIN
    SET NOCOUNT ON;

    IF @MaxRows IS NULL OR @MaxRows < 1 SET @MaxRows = 50;
    IF @MaxRows > 200                   SET @MaxRows = 200;

    SELECT TOP (@MaxRows)
        n.NotificationId,
        n.RecipientUserUid,
        nt.Code AS TypeCode,
        n.Title,
        n.Body,
        n.CreatedOn
    FROM dbo.t_app_notifications n
        INNER JOIN dbo.m_app_notification_type nt ON nt.NotificationTypeId = n.NotificationTypeId
    WHERE nt.SendEmail    = 1          -- the TYPE decides, not the caller (029)
      AND n.EmailSentOn IS NULL
      AND n.Is_Deleted    = 0
    ORDER BY n.NotificationId;
END
GO

/*==============================================================================
  USP_MarkNotificationEmailSent

  ⚠️ Stamped only when the send succeeded. A row left unstamped is retried,
  which is the right failure mode for mail: a duplicate email is a nuisance, a
  silently dropped offer notification is not.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_MarkNotificationEmailSent
    @NotificationId bigint
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.t_app_notifications
       SET EmailSentOn = SYSUTCDATETIME(),
           RowVersion  = RowVersion + 1,
           ModifiedOn  = SYSUTCDATETIME()
    WHERE NotificationId = @NotificationId
      AND EmailSentOn IS NULL;

    SELECT 1 AS [Status], NULL AS Code, N'Stamped.' AS [Message], @NotificationId AS Id;
END
GO

PRINT '  notifications procedures ready';
GO
