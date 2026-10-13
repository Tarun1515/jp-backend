/*==============================================================================
  jp_app — 033_public_content.sql

  The three tables the PUBLIC surface needs. Phase 7A.

    t_app_faqs                 the FAQ page's content, admin-editable
    t_app_cms_content_blocks   designated blocks on otherwise-static pages
    t_app_contact_enquiries    what the contact form writes

  ---------------------------------------------------------------------------
  🔴 WHY t_app_cms_pages IS NOT HERE
  ---------------------------------------------------------------------------
  DB_TABLE_STRUCTURE lists it; decision 2.81 (7A-0) decided against building it
  now, and the reasoning is worth repeating where somebody will look for the
  table and not find it.

  The legal and static pages stay PRERENDERED and are NOT CMS-editable (2.44:
  "client ko final wording deni ya approve karni hogi launch se pehle"). An
  admin able to edit enforceable Terms without legal review is the specific
  thing 2.44 protects against. So in MVP no page comes from the CMS — and a
  table whose only consumer would be a feature nobody is building is a half
  feature (029's consumer guard).

  ⚠️ 2.37 took the OPPOSITE decision for t_sso_role_menus — built it empty
  because "khaali table ka koi cost nahi" and retrofitting later would mean a
  migration plus a procedure rewrite on a live database. The difference is the
  RETROFIT COST: adding cms_pages later is a new table with no data to migrate
  and no procedure to rewrite, so 2.37's argument does not apply and 029's
  does.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*==============================================================================
  t_app_faqs — the FAQ page, from the database.

  ---------------------------------------------------------------------------
  🔴 WHY THIS ONE PAGE STOPS BEING PRERENDERED
  ---------------------------------------------------------------------------
  FAQ copy is operational: it changes when support answers the same question
  three times, and it carries no legal weight. That is exactly the content an
  admin should be able to fix without a deployment (2.7's spirit), and it is
  why /faq becomes RenderMode.Server while /terms and /privacy do not.

  ⚠️ Category is a CODE, not a free string: the page groups by audience and
  the group headings are the product's words, not an editor's. A free-text
  category would let a typo create a fourth, empty group.
==============================================================================*/
IF OBJECT_ID('dbo.t_app_faqs', 'U') IS NULL
BEGIN
    PRINT '    Creating table [t_app_faqs] ...';

    CREATE TABLE dbo.t_app_faqs
    (
        FaqId        int            IDENTITY(1, 1) NOT NULL,

        /* TEACHER · SCHOOL · GENERAL. Checked, not free text. */
        Category     varchar(10)    NOT NULL,

        Question     nvarchar(300)  NOT NULL,
        Answer       nvarchar(2000) NOT NULL,
        DisplayOrder int            NOT NULL
                     CONSTRAINT DF_t_app_faqs_DisplayOrder DEFAULT (0),

        Is_Active    tinyint        NOT NULL
                     CONSTRAINT DF_t_app_faqs_Is_Active  DEFAULT (1),
        Is_Deleted   tinyint        NOT NULL
                     CONSTRAINT DF_t_app_faqs_Is_Deleted DEFAULT (0),
        CreatedOn    datetime2      NOT NULL
                     CONSTRAINT DF_t_app_faqs_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy    bigint         NULL,
        ModifiedOn   datetime2      NULL,
        ModifiedBy   bigint         NULL,

        CONSTRAINT PK_t_app_faqs PRIMARY KEY CLUSTERED (FaqId),

        CONSTRAINT CK_t_app_faqs_Category
            CHECK (Category IN ('TEACHER', 'SCHOOL', 'GENERAL')),
        CONSTRAINT CK_t_app_faqs_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_app_faqs_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
    PRINT '    Table [t_app_faqs] already exists — skipped.';
GO

/*
  The public read asks for live rows in display order, per category. Filtered,
  because a soft-deleted FAQ is never wanted by the only consumer there is.
*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID('dbo.t_app_faqs')
                 AND name = 'IX_t_app_faqs_Live')
BEGIN
    PRINT '    Creating IX_t_app_faqs_Live ...';

    CREATE INDEX IX_t_app_faqs_Live
        ON dbo.t_app_faqs (Category, DisplayOrder, FaqId)
        WHERE Is_Active = 1 AND Is_Deleted = 0;
END
ELSE
    PRINT '    IX_t_app_faqs_Live already exists — skipped.';
GO

/*==============================================================================
  t_app_cms_content_blocks — designated blocks, by KEY.

  ---------------------------------------------------------------------------
  🔴 KEYED, AND THE KEY SET IS CLOSED
  ---------------------------------------------------------------------------
  A block is addressed by a BlockKey the TEMPLATE names — the page asks for
  'home.hero.subtitle' and renders whatever it gets. That is the only shape in
  which admin-editable copy inside a designed page is safe: the designer
  decides WHERE copy goes and the admin decides WHAT it says.

  ⚠️ Without PageId. DB_TABLE_STRUCTURE pairs blocks with cms_pages, and
  cms_pages is not being built (see this file's header) — so a nullable FK to a
  table that does not exist would be a column that can only ever be NULL. The
  key is globally unique instead, which is what the template needs anyway: a
  template asks for a key, not for a page's third block.

  🔴 NOT a route whitelist, and not a page. A key that no template references
  renders nowhere — so an admin cannot create content, only change copy the
  design already has a place for. That is deliberate: the alternative is an
  editor who can add a block and then wonder why it is invisible.
==============================================================================*/
IF OBJECT_ID('dbo.t_app_cms_content_blocks', 'U') IS NULL
BEGIN
    PRINT '    Creating table [t_app_cms_content_blocks] ...';

    CREATE TABLE dbo.t_app_cms_content_blocks
    (
        BlockId      int            IDENTITY(1, 1) NOT NULL,

        /* e.g. 'jobs.empty.message'. The template names it. */
        BlockKey     varchar(100)   NOT NULL,

        BlockTitle   nvarchar(200)  NULL,
        BlockContent nvarchar(2000) NOT NULL,
        ImagePath    nvarchar(500)  NULL,
        DisplayOrder int            NOT NULL
                     CONSTRAINT DF_t_app_cms_content_blocks_DisplayOrder DEFAULT (0),

        Is_Active    tinyint        NOT NULL
                     CONSTRAINT DF_t_app_cms_content_blocks_Is_Active  DEFAULT (1),
        Is_Deleted   tinyint        NOT NULL
                     CONSTRAINT DF_t_app_cms_content_blocks_Is_Deleted DEFAULT (0),
        CreatedOn    datetime2      NOT NULL
                     CONSTRAINT DF_t_app_cms_content_blocks_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy    bigint         NULL,
        ModifiedOn   datetime2      NULL,
        ModifiedBy   bigint         NULL,

        CONSTRAINT PK_t_app_cms_content_blocks PRIMARY KEY CLUSTERED (BlockId),
        CONSTRAINT CK_t_app_cms_content_blocks_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_app_cms_content_blocks_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
    PRINT '    Table [t_app_cms_content_blocks] already exists — skipped.';
GO

/*
  One LIVE block per key. Two rows answering to one key would make the page's
  content depend on which row the reader happened to pick — and the template
  asks for a key expecting one answer.
*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID('dbo.t_app_cms_content_blocks')
                 AND name = 'UQ_t_app_cms_content_blocks_Key')
BEGIN
    PRINT '    Creating UQ_t_app_cms_content_blocks_Key ...';

    CREATE UNIQUE INDEX UQ_t_app_cms_content_blocks_Key
        ON dbo.t_app_cms_content_blocks (BlockKey)
        WHERE Is_Deleted = 0;
END
ELSE
    PRINT '    UQ_t_app_cms_content_blocks_Key already exists — skipped.';
GO

/*==============================================================================
  t_app_contact_enquiries — what the contact form writes.

  ---------------------------------------------------------------------------
  🔴 THE FORM HAS BEEN TELLING THE TRUTH SINCE 2.44, AND THIS ENDS THAT
  ---------------------------------------------------------------------------
  2.44 shipped the form validating and then SAYING it had not sent anything,
  with a mailto: fallback — because "nakli 'thanks, we'll be in touch' ka matlab
  hota uski enquiry gayab aur wo kabhi dobara koshish nahi karta". This table
  is what makes the honest message unnecessary.

  ---------------------------------------------------------------------------
  🔒 WRITTEN BY AN ANONYMOUS CALLER — WHICH SHAPES EVERY COLUMN
  ---------------------------------------------------------------------------
  This is the first table in the product an UNAUTHENTICATED request inserts
  into. So:

    · no UserUid, no OrganizationUid — there is no caller identity to record,
      and a nullable one would invite somebody to "enrich" it later from a
      cookie the public endpoints deliberately never read;
    · lengths are tight, because the only protection against a megabyte of
      prose is the column;
    · CreatedBy stays NULL, always. It is here because every table has it, and
      a trigger-happy future edit filling it with a system user id would make
      an anonymous enquiry look attributed.

  ⚠️ NO honeypot column. A bot that fills the hidden field gets a 200 and NO
  ROW (2.81 / the brief): storing the attempt would mean a table that fills
  with bots, and a queue an admin has to triage. Telling the bot nothing and
  keeping nothing are the same decision.
==============================================================================*/
IF OBJECT_ID('dbo.t_app_contact_enquiries', 'U') IS NULL
BEGIN
    PRINT '    Creating table [t_app_contact_enquiries] ...';

    CREATE TABLE dbo.t_app_contact_enquiries
    (
        EnquiryId        bigint         IDENTITY(1, 1) NOT NULL,

        Name             nvarchar(100)  NOT NULL,
        Email            nvarchar(256)  NOT NULL,
        Mobile           varchar(15)    NULL,
        Subject          nvarchar(200)  NOT NULL,
        [Message]        nvarchar(2000) NOT NULL,

        /*
          The admin queue's state. A resolved enquiry keeps its remarks — the
          next person asking "did anybody answer this?" needs the answer, not
          an empty flag.
        */
        IsResolved       tinyint        NOT NULL
                         CONSTRAINT DF_t_app_contact_enquiries_IsResolved DEFAULT (0),
        ResolvedByUserId bigint         NULL,
        ResolvedOn       datetime2      NULL,
        ResolutionRemarks nvarchar(1000) NULL,

        Is_Deleted       tinyint        NOT NULL
                         CONSTRAINT DF_t_app_contact_enquiries_Is_Deleted DEFAULT (0),
        CreatedOn        datetime2      NOT NULL
                         CONSTRAINT DF_t_app_contact_enquiries_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy        bigint         NULL,

        CONSTRAINT PK_t_app_contact_enquiries PRIMARY KEY CLUSTERED (EnquiryId),

        CONSTRAINT CK_t_app_contact_enquiries_IsResolved CHECK (IsResolved IN (0, 1)),
        CONSTRAINT CK_t_app_contact_enquiries_Is_Deleted CHECK (Is_Deleted IN (0, 1)),

        /*
          🔴 RESOLVED MEANS SOMEBODY RESOLVED IT, AT A TIME.

          A resolved row with no resolver and no timestamp is a queue nobody
          can audit — and the shape that produces it is an UPDATE that sets the
          flag and forgets the rest. Structural, not a comment (2.36), and the
          same argument 038's CK_AdminHasUser makes for a receipt.
        */
        CONSTRAINT CK_t_app_contact_enquiries_ResolvedTrail
            CHECK (IsResolved = 0
                   OR (ResolvedByUserId IS NOT NULL AND ResolvedOn IS NOT NULL))
    );
END
ELSE
    PRINT '    Table [t_app_contact_enquiries] already exists — skipped.';
GO

/*
  The admin queue: unresolved first, oldest first. Filtered on the status the
  queue actually asks for.
*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID('dbo.t_app_contact_enquiries')
                 AND name = 'IX_t_app_contact_enquiries_Open')
BEGIN
    PRINT '    Creating IX_t_app_contact_enquiries_Open ...';

    CREATE INDEX IX_t_app_contact_enquiries_Open
        ON dbo.t_app_contact_enquiries (CreatedOn)
        INCLUDE ([Subject], Email, Name)
        WHERE IsResolved = 0 AND Is_Deleted = 0;
END
ELSE
    PRINT '    IX_t_app_contact_enquiries_Open already exists — skipped.';
GO

/*==============================================================================
  BUILD GUARDS — shape, and the two CHECKs that carry a decision.
==============================================================================*/
DECLARE @missing nvarchar(400) = N'';

IF OBJECT_ID('dbo.t_app_faqs', 'U') IS NULL
    SET @missing = @missing + N't_app_faqs ';

IF OBJECT_ID('dbo.t_app_cms_content_blocks', 'U') IS NULL
    SET @missing = @missing + N't_app_cms_content_blocks ';

IF OBJECT_ID('dbo.t_app_contact_enquiries', 'U') IS NULL
    SET @missing = @missing + N't_app_contact_enquiries ';

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
               WHERE name = 'CK_t_app_contact_enquiries_ResolvedTrail')
    SET @missing = @missing + N'CK_ResolvedTrail ';

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
               WHERE name = 'CK_t_app_faqs_Category')
    SET @missing = @missing + N'CK_Faq_Category ';

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID('dbo.t_app_cms_content_blocks')
                 AND name = 'UQ_t_app_cms_content_blocks_Key')
    SET @missing = @missing + N'UQ_BlockKey ';

IF @missing <> N''
    RAISERROR('033_public_content: missing after run: %s', 16, 1, @missing);
GO

/*
  🔒 NO IDENTITY COLUMN ON THE ENQUIRY TABLE, asserted.

  The contact form is written by an anonymous caller and there is no caller to
  record. A UserUid or OrganizationUid appearing here later would mean somebody
  had started reading a cookie on an endpoint that is specified never to read
  one — so the build fails and says so, rather than the column quietly
  appearing and being filled.
*/
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID('dbo.t_app_contact_enquiries')
             AND name IN ('UserUid', 'UserId', 'OrganizationUid', 'SchoolId', 'TeacherId'))
    RAISERROR('033_public_content: 🔒 t_app_contact_enquiries has gained a CALLER IDENTITY column. The contact form is anonymous and the public endpoints read no cookie or token — see 2.81. If an identity is genuinely needed, that is a different, authenticated feature.', 16, 1);
GO

PRINT '    Public content tables ready (faqs, content blocks, contact enquiries).';
GO
