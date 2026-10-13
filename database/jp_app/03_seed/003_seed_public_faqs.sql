/*==============================================================================
  jp_app — 03_seed / 003_seed_public_faqs.sql

  PHASE 7A — the FAQ copy, moved from the prerendered page into the database.

  ---------------------------------------------------------------------------
  🔴 WHY THIS EXISTS
  ---------------------------------------------------------------------------
  2.44 shipped /faq as a PRERENDERED page with its twelve questions written
  into faq.component.ts as a TypeScript array. 2.81 decided FAQs are one of the
  two things an admin may edit without a deploy (the other being designated
  content blocks), so the copy has to live here instead.

  These are the SAME twelve questions, with one answer corrected — see below.
  Moving copy and rewriting it in the same step makes a diff nobody can read.

  ---------------------------------------------------------------------------
  🔴 THE ONE ANSWER THAT CHANGED, AND WHY IT HAD TO
  ---------------------------------------------------------------------------
  The shipped page answered "Can I search for jobs without an account?" with:

      "Not yet. Public job search is being built and will arrive in a later
       release. For now, create a profile and you will be ready to apply as
       soon as listings are live."

  Phase 7A IS that release. Seeding that sentence would have published a page
  that tells visitors the feature they are looking at does not exist — so the
  answer is corrected HERE, in the same commit that builds the thing it
  describes. The old wording was true when it was written; a statement about
  shipped behaviour rots, and this is the commit where it rotted.

  ⚠️ The component's hardcoded array is deleted in the same commit. Two copies
  of this text, one of them unreachable, is how the next person ends up editing
  the wrong one.

  ---------------------------------------------------------------------------
  🔴 INSERT-IF-ABSENT, NEVER OVERWRITE — AND THAT IS NOT LAZINESS
  ---------------------------------------------------------------------------
  An admin can edit these rows from 7B onward. A seed that re-asserted its own
  text on every deploy would silently destroy their edits, and the symptom
  would be "the FAQ keeps reverting" reported weeks later by somebody who never
  saw this file.

  So the match is on Question within Category, and an existing row is LEFT
  ALONE — including one an admin has rewritten. The cost is that fixing a typo
  in this file does not reach a database that already has the row; the fix for
  that is to edit it as an admin, which is the whole point of 2.81's decision.

  ⚠️ Deliberately NOT a MERGE. MERGE's WHEN MATCHED THEN UPDATE is exactly the
  overwrite this must not do, and a MERGE with only WHEN NOT MATCHED is a
  verbose INSERT ... WHERE NOT EXISTS with worse locking.
==============================================================================*/

USE jp_app;
GO

SET NOCOUNT ON;
GO

/*----------------------------------------------------------------------------
  The copy. Ordered as the page ordered it, because the page's order was
  chosen — cost first, then privacy, then the mechanics.
----------------------------------------------------------------------------*/
DECLARE @Faqs TABLE
(
    Category     varchar(10)    NOT NULL,
    DisplayOrder int            NOT NULL,
    Question     nvarchar(600)  NOT NULL,
    Answer       nvarchar(4000) NOT NULL
);

INSERT INTO @Faqs (Category, DisplayOrder, Question, Answer)
VALUES
    ('TEACHER', 10, N'Does it cost anything?',
     N'No. Creating a profile and applying for jobs is free for teachers, and there is no paid tier that moves your application up a list.'),

    ('TEACHER', 20, N'What can a school see about me?',
     N'The profile you filled in — your subjects, levels, experience and preferred locations — and the fact that you applied. Schools you have not applied to cannot see your application history.'),

    ('TEACHER', 30, N'What does "verified school" actually mean?',
     N'Before a school can publish a vacancy, we confirm the school exists and that the person posting is connected to it. It does not mean we have inspected the school or endorse it as an employer.'),

    ('TEACHER', 40, N'How do I know if my application was read?',
     N'Every application shows a stage — applied, viewed, shortlisted, interview, offer. When a school moves you, the stage changes, including when the outcome is a rejection.'),

    ('TEACHER', 50, N'Can I apply for more than one job at the same school?',
     N'Yes. Each vacancy is a separate application and is treated separately.'),

    /*
      🔴 THE CORRECTED ONE. Phase 7A built public job search, so the previous
      answer ("Not yet...") became false the moment this phase shipped.
    */
    ('TEACHER', 60, N'Can I search for jobs without an account?',
     N'Yes. Every published vacancy is on the public jobs page, and you can search and filter it without signing in. You need an account only when you want to apply — and for teachers that is free.'),

    ('SCHOOL', 10, N'What does verification involve?',
     N'We check that the school exists and that the person registering is connected to it. It happens once, before your first vacancy is published, and not again for each job you post.'),

    ('SCHOOL', 20, N'How long does verification take?',
     N'It is a manual review, so it is not instant. You can fill in your school profile and prepare a vacancy while it is in progress — the job simply will not be visible to teachers until the review is done.'),

    ('SCHOOL', 30, N'Can more than one person from my school use the account?',
     N'Yes. The person who registers can invite colleagues, and what each of them can do depends on the role they are given — not everyone needs to be able to post jobs or make offers.'),

    ('SCHOOL', 40, N'Can we manage more than one branch?',
     N'Yes. Branches sit under one school, and a vacancy belongs to a specific branch, so applicants know where the job actually is.'),

    ('SCHOOL', 50, N'What does it cost?',
     N'Pricing is not finalised. If you are registering now, talk to us first so there are no surprises later.'),

    ('SCHOOL', 60, N'Do you write the job advert for us?',
     N'No. You describe the subject, level and terms. Being specific is what stops unsuitable applications arriving, and nobody knows the role better than the school.');

INSERT INTO dbo.t_app_faqs (Category, Question, Answer, DisplayOrder)
SELECT f.Category, f.Question, f.Answer, f.DisplayOrder
  FROM @Faqs AS f
 WHERE NOT EXISTS (SELECT 1
                     FROM dbo.t_app_faqs AS existing
                    WHERE existing.Category = f.Category
                      AND existing.Question = f.Question);

PRINT CONCAT('003_seed_public_faqs: ', @@ROWCOUNT, ' FAQ row(s) inserted (0 on a re-run is correct).');
GO

/*----------------------------------------------------------------------------
  🔴 GUARDS. Proven to fire by being broken on purpose before shipping:
  a 'GENERAL' category smuggled past the CHECK fails the first; deleting a
  TEACHER row fails the second.
----------------------------------------------------------------------------*/
IF EXISTS (SELECT 1 FROM dbo.t_app_faqs WHERE Category NOT IN ('TEACHER', 'SCHOOL', 'GENERAL'))
    RAISERROR('003_seed_public_faqs: a FAQ has a category outside TEACHER/SCHOOL/GENERAL. The public page groups by category and would silently drop it.', 16, 1);
GO

/*
  ⚠️ The floor, not the exact count — an admin ADDING a FAQ must not fail a
  deploy. What this catches is the seed having run against the wrong database,
  or somebody emptying the table.
*/
IF (SELECT COUNT(*) FROM dbo.t_app_faqs WHERE Category = 'TEACHER' AND Is_Active = 1 AND Is_Deleted = 0) < 6
    RAISERROR('003_seed_public_faqs: fewer than the six seeded TEACHER FAQs are live. /faq renders from this table — an empty section is a blank page.', 16, 1);
GO

IF (SELECT COUNT(*) FROM dbo.t_app_faqs WHERE Category = 'SCHOOL' AND Is_Active = 1 AND Is_Deleted = 0) < 6
    RAISERROR('003_seed_public_faqs: fewer than the six seeded SCHOOL FAQs are live. /faq renders from this table — an empty section is a blank page.', 16, 1);
GO

/*
  🔒 AND THE ONE THAT MATTERS MOST: the stale answer must not come back.

  If somebody restores the component's old array into this seed, or a merge
  resurrects it, the public page starts telling visitors that the feature they
  are using does not exist.
*/
IF EXISTS (SELECT 1 FROM dbo.t_app_faqs
            WHERE Question = N'Can I search for jobs without an account?'
              AND Answer LIKE N'%Not yet%')
    RAISERROR('003_seed_public_faqs: the public-search FAQ still answers "Not yet" — Phase 7A built public job search, so that answer is false.', 16, 1);
GO

SELECT Category, DisplayOrder, LEFT(Question, 52) AS Question
  FROM dbo.t_app_faqs
 WHERE Is_Active = 1 AND Is_Deleted = 0
 ORDER BY Category, DisplayOrder;
GO
