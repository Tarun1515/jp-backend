/*
================================================================================
  PHASE 6C — m_app_notification_type

  Every notification the product can send, as rows rather than as a C# enum
  (2.7, 2.47). The id is the contract, the Code is stable, the Name is editable.

  🔴 EVERY SEEDED TYPE HAS A PROCEDURE THAT CREATES IT, and a guard at the
  bottom of this file fails the build if one does not. That is G32's lesson made
  structural: a row that looks like a feature and has no consumer is worse than
  a missing row, because nobody can tell by looking.

--------------------------------------------------------------------------------
  🔴 WHY THE TYPE CARRIES SendEmail AND THE CALLER DOES NOT DECIDE
--------------------------------------------------------------------------------
  "Also send this one by email" is a product decision about a KIND of event, not
  about one occurrence of it. Put it on the call site and it drifts: the same
  event emails from one code path and not from another, and nobody can say which
  is right. Put it here and the answer is one row, visible, changeable without a
  deploy.

  ⚠️ An email is interruptive in a way an in-portal row is not, so the default
  is 0 and each 1 is argued in its own comment below.

--------------------------------------------------------------------------------
  ⚠️ AUDIENCE IS A FACT ABOUT THE TYPE, AND IT IS WRITTEN DOWN
--------------------------------------------------------------------------------
  Each type names who it reaches — the teacher, or the school's team. It is
  documentation rather than enforcement, because enforcement lives where the
  recipient is resolved (021's two creators). But a type whose audience is
  unclear is a type somebody will send to the wrong person, so it is stated.
================================================================================
*/
USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF OBJECT_ID('dbo.m_app_notification_type', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.m_app_notification_type
    (
        NotificationTypeId  int             NOT NULL,
        Code                varchar(40)     NOT NULL,
        Name                nvarchar(100)   NOT NULL,
        Description         nvarchar(300)   NULL,

        /*
          🔴 1 = the teacher, 2 = the school's team. Documentation, not a gate —
          see the header. Stored as a tinyint rather than text so a typo cannot
          invent a third audience.
        */
        AudienceId          tinyint         NOT NULL,

        /** Does this kind of event also leave the product as an email? */
        SendEmail           bit             NOT NULL CONSTRAINT DF_m_app_notification_type_SendEmail DEFAULT (0),

        DisplayOrder        int             NOT NULL CONSTRAINT DF_m_app_notification_type_DisplayOrder DEFAULT (0),
        Is_Active           tinyint         NOT NULL CONSTRAINT DF_m_app_notification_type_IsActive DEFAULT (1),
        Is_Deleted          tinyint         NOT NULL CONSTRAINT DF_m_app_notification_type_IsDeleted DEFAULT (0),
        CreatedOn           datetime2(3)    NOT NULL CONSTRAINT DF_m_app_notification_type_CreatedOn DEFAULT (SYSUTCDATETIME()),
        ModifiedOn          datetime2(3)    NULL,

        CONSTRAINT PK_m_app_notification_type PRIMARY KEY CLUSTERED (NotificationTypeId),
        CONSTRAINT UQ_m_app_notification_type_Code UNIQUE (Code),
        CONSTRAINT CK_m_app_notification_type_Audience CHECK (AudienceId IN (1, 2))
    );
END
GO

/*
  SEED — ids are the contract (2.47), so they are written, never generated.

  ⚠️ Codes group by subject (APPLICATION_*, OFFER_*, INVITE_*) because that is
  how a screen filters them and how a human reads a list of them.
*/
MERGE dbo.m_app_notification_type AS target
USING (VALUES
    /* ---- applications (5A) ------------------------------------------- */
    (1,  'APPLICATION_RECEIVED',  N'New application',        N'A teacher applied to one of your jobs.',               2, 0, 1),
    (2,  'APPLICATION_VIEWED',    N'Application opened',      N'A school opened your application.',                    1, 0, 2),
    (3,  'APPLICATION_SHORTLIST', N'Shortlisted',             N'A school shortlisted you.',                            1, 0, 3),
    (4,  'APPLICATION_REJECTED',  N'Not selected',            N'A school has decided not to proceed.',                 1, 0, 4),

    /* ---- offers (6A) -------------------------------------------------- */
    /*
      🔴 SendEmail = 1, and this is the clearest case for it. An offer has
      salary, a joining date and a reporting time in it, and a teacher who does
      not open the portal for a week should not discover it late. It is also the
      one notification a teacher may need to show somebody.
    */
    (5,  'OFFER_SENT',            N'You have an offer',       N'A school sent you an offer.',                          1, 1, 5),
    (6,  'OFFER_ACCEPTED',        N'Offer accepted',          N'A teacher accepted your offer.',                       2, 1, 6),
    (7,  'OFFER_DECLINED',        N'Offer declined',          N'A teacher declined your offer.',                        2, 1, 7),
    (8,  'OFFER_WITHDRAWN',       N'Offer withdrawn',         N'A school withdrew an offer.',                          1, 1, 8),
    (9,  'HIRED',                 N'Hire confirmed',          N'A hire was confirmed.',                                 1, 1, 9),

    /* ---- invitations (6B) --------------------------------------------- */
    /*
      🔴 SendEmail = 1 for the invitation itself. An invitation is the one event
      that reaches somebody who has no reason to be looking — the whole point is
      that a school found them. 🔒 It carries no contact detail in either
      direction: the email tells the teacher a school wants to talk, and the
      school learns nothing until the teacher accepts (2.56).
    */
    (10, 'INVITE_RECEIVED',       N'A school invited you',    N'A school would like you to apply.',                    1, 1, 10),
    (11, 'INVITE_ACCEPTED',       N'Invitation accepted',     N'A teacher accepted your invitation.',                  2, 0, 11),
    (12, 'INVITE_IGNORED',        N'Invitation declined',     N'A teacher passed on your invitation.',                 2, 0, 12)

    /* ---- verification (3x) — DELIBERATELY NOT SEEDED YET ---------------
      🔴 VERIFICATION_APPROVED and VERIFICATION_REJECTED are missing on
      purpose, and leaving them out cost more thought than putting them in.

      Every type above has a live consumer: a procedure that creates it inside
      its own event's transaction, proven by notifications.mjs. A verification
      outcome cannot work that way — it is decided by the approval engine in
      jp_mdm, and 2.2 forbids that transaction reaching into jp_app — so it
      needs API-layer orchestration, with 2.48's caveat that the HTTP 200 would
      mean the approval succeeded and not that the notification did.

      ⚠️ And underneath it sits something worse, found while wiring this:
      NOTHING IN THE PRODUCT SETS t_app_teachers.IsVerified.
      ApprovalOrchestrationService.RunTeacherVerification returns a FAILED
      outcome whose message says "setting IsVerified requires t_app_teachers,
      which is Phase 3" — and Phase 3 shipped. The four verified teachers in
      this database are seed rows. See the gap note in PROJECT_MEMORY.

      🔴 So seeding these two would have been exactly the shape G32 was given a
      number for: config present, consumer absent. Two rows that look like a
      feature and are not. They arrive in the same commit as their consumer.
    */
) AS source (NotificationTypeId, Code, Name, Description, AudienceId, SendEmail, DisplayOrder)
ON target.NotificationTypeId = source.NotificationTypeId
WHEN MATCHED THEN
    UPDATE SET
        target.Code         = source.Code,
        target.Name         = source.Name,
        target.Description  = source.Description,
        target.AudienceId   = source.AudienceId,
        target.SendEmail    = source.SendEmail,
        target.DisplayOrder = source.DisplayOrder,
        target.Is_Deleted   = 0,
        target.ModifiedOn   = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (NotificationTypeId, Code, Name, Description, AudienceId, SendEmail, DisplayOrder)
    VALUES (source.NotificationTypeId, source.Code, source.Name, source.Description,
            source.AudienceId, source.SendEmail, source.DisplayOrder);
GO

/*
  🔴 BUILD-TIME GUARDS, NOT COMMENTS (2.36).

  027 took this shape for the IsConsent row and it is the right shape here too:
  a rule that only exists in prose is a rule the next seed breaks.
*/
IF EXISTS (SELECT 1 FROM dbo.m_app_notification_type
           WHERE Is_Deleted = 0 AND AudienceId NOT IN (1, 2))
    RAISERROR(N'6C VIOLATION: a notification type has an audience that is neither the teacher (1) nor the school (2).', 16, 1);
GO

/*
  ⚠️ An audience-2 type reaching a teacher would be a privacy question, not a
  cosmetic one — the school-facing wording says things like "a teacher declined
  your offer". So the pairing of code prefix to audience is asserted: every
  INVITE_RECEIVED-shaped type that names the teacher must be audience 1.
*/
IF EXISTS (SELECT 1 FROM dbo.m_app_notification_type
           WHERE Is_Deleted = 0
             AND Code IN ('APPLICATION_RECEIVED', 'OFFER_ACCEPTED', 'OFFER_DECLINED',
                          'INVITE_ACCEPTED', 'INVITE_IGNORED')
             AND AudienceId <> 2)
    RAISERROR(N'6C VIOLATION: a school-facing notification type is not marked audience 2.', 16, 1);
GO

/*
  ⚠️ The verification codes stay in this list even though they are not seeded.
  The guard is written as "IF EXISTS … AND AudienceId <> 1", so a code that is
  absent simply does not match — and on the day somebody seeds them, the guard
  is already waiting. A list that only names what exists today is a list that
  has to be remembered later.
*/
IF EXISTS (SELECT 1 FROM dbo.m_app_notification_type
           WHERE Is_Deleted = 0
             AND Code IN ('APPLICATION_VIEWED', 'APPLICATION_SHORTLIST', 'APPLICATION_REJECTED',
                          'OFFER_SENT', 'OFFER_WITHDRAWN', 'HIRED', 'INVITE_RECEIVED',
                          'VERIFICATION_APPROVED', 'VERIFICATION_REJECTED')
             AND AudienceId <> 1)
    RAISERROR(N'6C VIOLATION: a teacher-facing notification type is not marked audience 1.', 16, 1);
GO

/*
  🔴 AND A GUARD THAT EVERY SEEDED TYPE HAS A CONSUMER.

  This is the G32 lesson turned into something that fails the build. Each code
  below is produced by a named procedure; if a type is seeded with no procedure
  creating it, it is config pretending to be a feature.

  ⚠️ Deliberately a list of CODES rather than a count, so adding a type forces
  somebody to come here and say which procedure writes it.
*/
IF EXISTS (SELECT 1 FROM dbo.m_app_notification_type
           WHERE Is_Deleted = 0
             AND Code NOT IN (
                 'APPLICATION_RECEIVED',   -- USP_ApplyToJob
                 'APPLICATION_VIEWED',     -- USP_NotifyApplicationStatus (2)
                 'APPLICATION_SHORTLIST',  -- USP_NotifyApplicationStatus (3)
                 'APPLICATION_REJECTED',   -- USP_NotifyApplicationStatus (6)
                 'OFFER_SENT',             -- USP_NotifyOffer  SENT
                 'OFFER_ACCEPTED',         -- USP_NotifyOffer  ACCEPTED
                 'OFFER_DECLINED',         -- USP_NotifyOffer  DECLINED
                 'OFFER_WITHDRAWN',        -- USP_NotifyOffer  WITHDRAWN
                 'HIRED',                  -- USP_NotifyOffer  HIRED
                 'INVITE_RECEIVED',        -- USP_NotifyInvite RECEIVED
                 'INVITE_ACCEPTED',        -- USP_NotifyInvite ACCEPTED
                 'INVITE_IGNORED'          -- USP_NotifyInvite IGNORED
             ))
    RAISERROR(N'6C VIOLATION: a notification type is seeded with no procedure that creates it (the G32 shape).', 16, 1);
GO

PRINT '  m_app_notification_type ready';
GO
