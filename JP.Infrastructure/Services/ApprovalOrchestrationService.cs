using JP.Core.Constants;
using JP.Core.Enums;
using JP.Domain.Approvals;
using JP.Infrastructure.Email;
using JP.Infrastructure.Repositories;
using Microsoft.Extensions.Logging;

namespace JP.Infrastructure.Services;

/// <summary>
/// What happened to the cross-database work that follows a completed approval.
/// </summary>
internal sealed record OrchestrationOutcome
{
    public bool Succeeded { get; init; }

    /// <summary>Null on success. Set to something an admin can act on otherwise.</summary>
    public string? Error { get; init; }

    public static OrchestrationOutcome Ok() => new() { Succeeded = true };
    public static OrchestrationOutcome Fail(string error) => new() { Succeeded = false, Error = error };
}

internal interface IApprovalOrchestrationService
{
    Task<OrchestrationOutcome> RunAsync(
        ApprovalRequestDetailDto detail,
        long actionByUserId,
        CancellationToken cancellationToken);
}

/// <summary>
/// The cross-database work that follows an approval — and the honest handling
/// of it failing halfway.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 THERE IS NO DISTRIBUTED TRANSACTION, AND THERE NEVER WILL BE.
/// </para>
/// <para>
/// Decision 2.2 keeps cross-database writes in the API layer, one committed
/// transaction per database. That is the right trade — MSDTC across three
/// databases would couple their deployments permanently — but it has a
/// consequence that must be handled rather than hoped away: step 1 can succeed
/// and step 2 fail, leaving an Active user with no profile. That account signs
/// in successfully and lands on an empty shell.
/// </para>
/// <para>
/// Three things make that survivable:
/// </para>
/// <list type="number">
///   <item>
///     <b>Ordering.</b> The user is activated BEFORE the school is created. If
///     the order were reversed, a failure would leave a school nobody can sign
///     in to — invisible from both sides. This way the failure is at least
///     reachable: the user exists and can complain.
///   </item>
///   <item>
///     <b>Idempotency.</b> Every step can be run again. Provisioning keys on
///     SourceRequestUid, activation is a state transition to a fixed value, and
///     the email is queued rather than sent inline. A retry after a partial
///     failure converges instead of duplicating.
///   </item>
///   <item>
///     <b>Loud failure.</b> On a step-2 failure this logs at Error with the
///     RequestId and RequestNo, and returns a failed outcome the caller
///     surfaces to the admin. It never reports success for work that did not
///     happen — see the teacher branch for why that rule is absolute.
///   </item>
/// </list>
/// <para>
/// The safety net is <c>USP_FindOrphanedApprovals</c>: completed approvals with
/// no school. Phase 8 schedules it; until then it is run by hand.
/// </para>
/// </remarks>
internal sealed class ApprovalOrchestrationService : IApprovalOrchestrationService
{
    // m_mdm_request_types. Contract values (decision 2.47).
    private const int RequestTypeSchoolRegistration = 1;
    private const int RequestTypeTeacherVerification = 2;
    private const int RequestTypeBranchAdd = 3;

    // m_sso_user_status. Active.
    private const int UserStatusActive = 2;

    // m_mdm_approval_status. Approved — the only status that provisions anything.
    private const int StatusApproved = 3;

    private readonly IUserRepository _users;
    private readonly IProvisioningRepository _provisioning;
    private readonly IEmailDispatchQueue _emailQueue;
    private readonly ILogger<ApprovalOrchestrationService> _logger;

    public ApprovalOrchestrationService(
        IUserRepository users,
        IProvisioningRepository provisioning,
        IEmailDispatchQueue emailQueue,
        ILogger<ApprovalOrchestrationService> logger)
    {
        _users = users;
        _provisioning = provisioning;
        _emailQueue = emailQueue;
        _logger = logger;
    }

    public async Task<OrchestrationOutcome> RunAsync(
        ApprovalRequestDetailDto detail,
        long actionByUserId,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(detail);

        /*
          🔴 SECOND GATE, ON PURPOSE.

          The caller already checks this. It is repeated here because the cost
          of getting it wrong is not an error message — it is a school that was
          REJECTED being created and activated anyway, silently, with the
          rejection sitting in the trail next to it.

          That happened: an earlier version orchestrated whenever the request
          was "completed", and a rejection completes a request. Two gates
          because one of them was already missed once, and because every future
          caller of this method inherits the check rather than having to
          remember it.
        */
        if (detail.Header.StatusId != StatusApproved)
        {
            _logger.LogError(
                "Orchestration was asked to run for approval {RequestNo} (RequestId {RequestId}), which is " +
                "{Status}, not approved. Nothing was provisioned.",
                detail.Header.RequestNo, detail.Header.RequestId, detail.Header.StatusName);

            return OrchestrationOutcome.Fail(
                "Nothing was provisioned: this request was not approved.");
        }

        return detail.Header.RequestTypeId switch
        {
            RequestTypeSchoolRegistration or RequestTypeBranchAdd =>
                await RunSchoolAsync(detail, actionByUserId, cancellationToken).ConfigureAwait(false),

            RequestTypeTeacherVerification =>
                RunTeacherVerification(detail),

            _ => OrchestrationOutcome.Fail(
                $"No orchestration is defined for request type {detail.Header.RequestTypeId}."),
        };
    }

    /// <summary>
    /// School registration: approval GATES activation, so the profile is
    /// created here (decision 2.9).
    /// </summary>
    private async Task<OrchestrationOutcome> RunSchoolAsync(
        ApprovalRequestDetailDto detail,
        long actionByUserId,
        CancellationToken cancellationToken)
    {
        var header = detail.Header;
        var school = detail.SchoolDetail;

        if (school is null)
        {
            // The approval completed but its payload row is missing. Nothing
            // downstream can be built from nothing, and pretending otherwise
            // would create exactly the orphan this class exists to prevent.
            _logger.LogError(
                "Approval {RequestNo} (RequestId {RequestId}) completed with no school detail row. " +
                "Provisioning skipped — this request needs manual investigation.",
                header.RequestNo, header.RequestId);

            return OrchestrationOutcome.Fail(
                "The approval completed but its registration payload is missing. It has been logged for investigation.");
        }

        if (header.OrganizationUid is not { } organizationUid)
        {
            _logger.LogError(
                "Approval {RequestNo} (RequestId {RequestId}) has no OrganizationUid. Provisioning skipped.",
                header.RequestNo, header.RequestId);

            return OrchestrationOutcome.Fail(
                "The approval has no organisation attached. It has been logged for investigation.");
        }

        // ---- STEP 1: jp_sso — activate the user and grant the role ---------
        //
        // First on purpose. A failure here leaves nothing created anywhere,
        // which is the cleanest possible failure: the approval is committed but
        // the world is otherwise untouched, and a retry starts from scratch.
        try
        {
            var status = await _users
                .UpdateUserStatusForApprovalAsync(header.RequestorUserId, UserStatusActive, actionByUserId, cancellationToken)
                .ConfigureAwait(false);

            if (!status.Succeeded)
            {
                _logger.LogError(
                    "Approval {RequestNo}: activating user {UserId} failed with {Code} — {Message}. Nothing was provisioned.",
                    header.RequestNo, header.RequestorUserId, status.Code, status.Message);

                return OrchestrationOutcome.Fail(
                    $"The approval was recorded but the account could not be activated: {status.Message}");
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(
                ex,
                "Approval {RequestNo} (RequestId {RequestId}): activating user {UserId} threw. Nothing was provisioned.",
                header.RequestNo, header.RequestId, header.RequestorUserId);

            return OrchestrationOutcome.Fail(
                "The approval was recorded but the account could not be activated. It has been logged for investigation.");
        }

        // ---- STEP 2: jp_app — create the school ----------------------------
        //
        // 🔴 This is the step that can leave an Active user with no profile.
        // It is idempotent on SourceRequestUid, so re-running is safe, and a
        // failure is logged loudly with everything needed to find it again.
        try
        {
            var provisioned = await _provisioning
                .ProvisionSchoolAsync(header.RequestUid, organizationUid, school, actionByUserId, cancellationToken)
                .ConfigureAwait(false);

            if (!provisioned.Succeeded)
            {
                _logger.LogError(
                    "🔴 PARTIAL COMPLETION. Approval {RequestNo} (RequestId {RequestId}): user {UserId} is ACTIVE " +
                    "but provisioning failed with {Code} — {Message}. This account can sign in with no school. " +
                    "Run USP_FindOrphanedApprovals to list every request in this state.",
                    header.RequestNo, header.RequestId, header.RequestorUserId, provisioned.Code, provisioned.Message);

                return OrchestrationOutcome.Fail(
                    $"The account was activated but the school record could not be created: {provisioned.Message}. " +
                    "This has been logged and needs to be retried.");
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(
                ex,
                "🔴 PARTIAL COMPLETION. Approval {RequestNo} (RequestId {RequestId}): user {UserId} is ACTIVE but " +
                "provisioning threw. This account can sign in with no school. " +
                "Run USP_FindOrphanedApprovals to list every request in this state.",
                header.RequestNo, header.RequestId, header.RequestorUserId);

            return OrchestrationOutcome.Fail(
                "The account was activated but the school record could not be created. " +
                "This has been logged and needs to be retried.");
        }

        // ---- STEP 3: queue the email ---------------------------------------
        //
        // Last, and never fatal. The account works and the school exists; a
        // failed notification is not a reason to tell the admin the approval
        // did not happen. Queued rather than sent inline (decision 2.33), so a
        // slow SMTP server cannot hold the request open.
        try
        {
            _emailQueue.Enqueue(new EmailDispatchRequest(
                TemplateName: "school-approved",
                Recipient: school.ContactEmail ?? string.Empty,
                Subject: "Your school has been verified",
                Tokens: new Dictionary<string, string>
                {
                    ["schoolName"] = school.SchoolName,
                    ["requestNo"] = header.RequestNo,
                }));
        }
        catch (Exception ex)
        {
            _logger.LogWarning(
                ex,
                "Approval {RequestNo} completed successfully but the notification email could not be queued.",
                header.RequestNo);
        }

        _logger.LogInformation(
            "Approval {RequestNo} (RequestId {RequestId}) orchestrated: user {UserId} active, school provisioned.",
            header.RequestNo, header.RequestId, header.RequestorUserId);

        return OrchestrationOutcome.Ok();
    }

    /// <summary>
    /// Teacher verification: structurally different, and deliberately does NOT
    /// provision anything.
    /// </summary>
    /// <remarks>
    /// <para>
    /// 🔴 Per decision 2.9, a teacher's account is Active from signup.
    /// Verification is a BADGE on a profile that already exists — it is not a
    /// gate, and approving it creates nothing. The correct effect is
    /// <c>IsVerified = 1</c> on an existing <c>t_app_teachers</c> row.
    /// </para>
    /// <para>
    /// That table does not exist yet, and neither does the signup-time creation
    /// of teacher profiles. Both are Phase 3.
    /// </para>
    /// <para>
    /// So this branch returns a FAILED outcome saying exactly that, rather than
    /// returning success. Reporting success for work that did not happen is how
    /// the orphan problem <c>USP_FindOrphanedApprovals</c> exists to catch gets
    /// recreated one layer up — invisible, and this time with nothing to
    /// reconcile against.
    /// </para>
    /// <para>
    /// It also must not fall through to the school path. A teacher approval has
    /// no school payload and no organisation; provisioning one would be
    /// nonsense that happened to compile.
    /// </para>
    /// </remarks>
    private OrchestrationOutcome RunTeacherVerification(ApprovalRequestDetailDto detail)
    {
        var header = detail.Header;

        _logger.LogWarning(
            "Approval {RequestNo} (RequestId {RequestId}) is a teacher verification. The approval itself is " +
            "recorded, but setting IsVerified requires t_app_teachers, which is Phase 3. " +
            "No profile was created and none should be — a teacher account is already Active from signup (2.9).",
            header.RequestNo, header.RequestId);

        return OrchestrationOutcome.Fail(
            "The verification decision was recorded. Marking the teacher profile as verified is not available yet " +
            "(teacher profiles arrive in Phase 3), so no profile was updated.");
    }
}
