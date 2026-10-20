namespace JP.Domain.Admin;

/*==============================================================================
  ADMIN ANALYTICS. Phase 8-0.

  §3 lists "Reports/dashboard" in the MVP. This is the honest version of it:
  every figure is counted from rows that exist, and nothing here is a stored
  counter.

  ----------------------------------------------------------------------------
  🔴 WHY THAT SENTENCE IS THE FIRST ONE
  ----------------------------------------------------------------------------
  One phase ago the moderation queue projected t_app_jobs.ApplicationCount — a
  column the product forbids writing (016) and forbids reading (017), so
  permanently zero — and every advert showed "0 applied" on the screen where
  that number decides whether to take an advert down. A screens suite caught
  it; review had not.

  An analytics screen is where that mistake would be invisible. So the three
  procedures behind these shapes count rows, and each carries a build guard
  that fails if a counter column or an identity appears in it.

  ----------------------------------------------------------------------------
  🔒 HOW MANY, NEVER WHO
  ----------------------------------------------------------------------------
  These shapes carry no email, no uid, no request number, no school or teacher
  name. This surface is behind REPORT.VIEW, which is NOT USER.MANAGE and NOT
  VERIFICATION.*: a person who may read the platform's totals is not thereby
  trusted with the people in them. Both identity databases' procedures assert
  that in SQL.

  ----------------------------------------------------------------------------
  ⚠️ THREE DATABASES, ASSEMBLED IN THE SERVICE (2.2)
  ----------------------------------------------------------------------------
  Registrations are jp_sso, approvals are jp_mdm, jobs and applications are
  jp_app. Three procedures, three repositories, one service that puts the
  answers together — the shape provisioning has used since 2F. No cross
  database join exists in this product and this screen does not introduce one.
==============================================================================*/

/// <summary>One status, counted. Jobs, applications and invitations.</summary>
public sealed class StatusCountDto
{
    public int StatusId { get; set; }
    public string StatusName { get; set; } = string.Empty;
    public int Total { get; set; }

    /// <summary>⚠️ Thirty calendar days in IST, computed in SQL (2.28).</summary>
    public int Last30Days { get; set; }
}

/// <summary>Accounts, by user type and status.</summary>
public sealed class RegistrationCountDto
{
    public int UserTypeId { get; set; }
    public string UserTypeName { get; set; } = string.Empty;
    public int StatusId { get; set; }
    public string StatusName { get; set; } = string.Empty;
    public int Total { get; set; }
    public int Last30Days { get; set; }
}

/// <summary>Approval requests, by type and status.</summary>
public sealed class ApprovalCountDto
{
    public int RequestTypeId { get; set; }
    public string RequestTypeName { get; set; } = string.Empty;
    public int StatusId { get; set; }
    public string StatusName { get; set; } = string.Empty;
    public int Total { get; set; }
    public int Last30Days { get; set; }
}

/// <summary>
/// How long the oldest OPEN request of each type has waited.
/// </summary>
/// <remarks>
/// 🔴 THE NUMBER THIS SCREEN EXISTS FOR. A queue is judged by its worst case:
/// twelve pending verifications is fine if none is a day old and a problem if
/// one has waited three weeks. "How many" is what people ask for; "how long
/// has the oldest waited" is what tells them something.
/// </remarks>
public sealed class QueueWaitDto
{
    public int RequestTypeId { get; set; }
    public string RequestTypeName { get; set; } = string.Empty;
    public int StillOpen { get; set; }

    /// <summary>Whole days, IST. 0 when nothing is open.</summary>
    public int OldestWaitingDays { get; set; }
}

/// <summary>jp_sso's headline figures.</summary>
public sealed class IdentityTotalsDto
{
    public int Accounts { get; set; }
    public int AccountsLast30Days { get; set; }
    public int EmailVerified { get; set; }

    /// <summary>
    /// ⚠️ A live lockout row, which is NOT the same as status 5 LOCKED. A
    /// lockout expires on its own; the status is what a sign-in check reads.
    /// Both are shown because a support call starts from one or the other.
    /// </summary>
    public int LockedOut { get; set; }
    public int WithFailedAttempts { get; set; }
    public DateTime AsOfIst { get; set; }
}

/// <summary>jp_mdm's headline figures.</summary>
public sealed class ApprovalTotalsDto
{
    public int OpenRequests { get; set; }
    public int SubmittedLast30Days { get; set; }
    public int PaymentsAwaiting { get; set; }

    /// <summary>
    /// 🔴 Here on purpose. G31 closed because an ordinary concurrency race was
    /// writing an error-log row every time, and the damage was that the log
    /// filled with non-errors until nobody read it. A visible count is what
    /// makes that kind of drift noticeable next time.
    /// </summary>
    public int ErrorLogRows { get; set; }
    public DateTime AsOfIst { get; set; }
}

/// <summary>jp_app's headline figures.</summary>
public sealed class AppTotalsDto
{
    public int Schools { get; set; }
    public int SchoolsVerified { get; set; }
    public int Teachers { get; set; }
    public int Campuses { get; set; }
    public int OpenReports { get; set; }
    public int OpenEnquiries { get; set; }
    public DateTime AsOfIst { get; set; }
}

/// <summary>Everything the analytics screen renders, in one response.</summary>
public sealed class AdminAnalyticsDto
{
    public IReadOnlyList<RegistrationCountDto> Registrations { get; set; } = [];
    public IdentityTotalsDto Identity { get; set; } = new();

    public IReadOnlyList<ApprovalCountDto> Approvals { get; set; } = [];
    public IReadOnlyList<QueueWaitDto> Waits { get; set; } = [];
    public ApprovalTotalsDto ApprovalTotals { get; set; } = new();

    public IReadOnlyList<StatusCountDto> Jobs { get; set; } = [];
    public IReadOnlyList<StatusCountDto> Applications { get; set; } = [];
    public IReadOnlyList<StatusCountDto> Invites { get; set; } = [];
    public AppTotalsDto AppTotals { get; set; } = new();
}
