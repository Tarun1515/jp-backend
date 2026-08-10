using System.Security.Claims;
using JP.Core.Constants;
using JP.Core.Enums;
using JP.Core.Exceptions;
using JP.Core.Extensions;
using JP.Domain.Approvals;
using JP.Domain.Common;
using JP.Infrastructure.Repositories;
using Microsoft.Extensions.Logging;

namespace JP.Infrastructure.Services;

public interface IApprovalService
{
    Task<SubmitApprovalResponse> SubmitAsync(SubmitApprovalRequest request, ClaimsPrincipal caller, string? ipAddress, CancellationToken cancellationToken);

    Task<PagedResult<ApprovalRequestListItemDto>> ListAsync(ApprovalRequestFilter filter, ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task<ApprovalRequestDetailDto> GetByIdAsync(long requestId, ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task<ProcessActionResponse> ProcessActionAsync(long requestId, ProcessActionRequest request, ClaimsPrincipal caller, string? ipAddress, CancellationToken cancellationToken);

    Task<long> ResubmitAsync(long requestId, ResubmitRequest request, ClaimsPrincipal caller, string? ipAddress, CancellationToken cancellationToken);

    Task<IReadOnlyList<PendingCountDto>> GetPendingCountsAsync(ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task<IReadOnlyList<OrphanedApprovalDto>> GetOrphanedAsync(int sinceDays, ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task<ProcessActionResponse> RetryOrchestrationAsync(long requestId, ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task<SaveDraftResponse> SaveDraftAsync(SaveDraftRequest request, ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task<ApprovalRequestDetailDto?> GetDraftAsync(ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task<SubmitApprovalResponse> SubmitDraftAsync(long requestId, ClaimsPrincipal caller, string? ipAddress, CancellationToken cancellationToken);
}

/// <summary>
/// The approval engine's service layer, including who is allowed to see what.
/// </summary>
/// <remarks>
/// 🔴 EVERY scope value comes from the caller's own token (decision 2.39).
/// <see cref="SubmitApprovalRequest"/> carries no OrganizationUid and no
/// RequestorUserId — not even optionally — so there is no field for a client to
/// populate and no code path that would read it if they did.
/// </remarks>
internal sealed class ApprovalService : IApprovalService
{
    private const int RequestTypeTeacherVerification = 2;
    private const int ActionApprove = 1;
    private const int ActionReject = 2;

    /// <summary>m_mdm_approval_status. Approved.</summary>
    private const int StatusApproved = 3;

    /// <summary>Five letters, four digits, one letter. Compiled once.</summary>
    private static readonly System.Text.RegularExpressions.Regex PanFormat =
        new("^[A-Z]{5}[0-9]{4}[A-Z]$", System.Text.RegularExpressions.RegexOptions.Compiled);

    private readonly IApprovalRepository _repository;
    private readonly IProvisioningRepository _provisioning;
    private readonly IApprovalOrchestrationService _orchestration;
    private readonly ILogger<ApprovalService> _logger;

    public ApprovalService(
        IApprovalRepository repository,
        IProvisioningRepository provisioning,
        IApprovalOrchestrationService orchestration,
        ILogger<ApprovalService> logger)
    {
        _repository = repository;
        _provisioning = provisioning;
        _orchestration = orchestration;
        _logger = logger;
    }

    public async Task<SubmitApprovalResponse> SubmitAsync(
        SubmitApprovalRequest request,
        ClaimsPrincipal caller,
        string? ipAddress,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(caller);

        // 🔴 Both from the token. Never from the payload.
        var requestorUserId = caller.GetUserId();
        var organizationUid = caller.GetOrganizationUid();

        // Same rule on both paths into a registration. A form posted straight
        // through must not be able to store a PAN the draft path would refuse.
        request = request with { PanNumber = NormalisePan(request.PanNumber) };

        var result = await _repository
            .SubmitAsync(request, organizationUid, requestorUserId, ipAddress, cancellationToken)
            .ConfigureAwait(false);

        result.EnsureSuccess();

        var alreadyPending = string.Equals(result.Code, "ALREADY_PENDING", StringComparison.Ordinal);

        // The request number is not on the envelope, so read it back. Cheap,
        // and it means the caller always gets the number to quote.
        var detail = result.Id is { } id
            ? await _repository.GetByIdAsync(id, cancellationToken).ConfigureAwait(false)
            : null;

        return new SubmitApprovalResponse
        {
            RequestId = result.Id ?? 0,
            RequestNo = detail?.Header.RequestNo ?? string.Empty,
            AlreadyPending = alreadyPending,
            Message = result.Message,
        };
    }

    public async Task<PagedResult<ApprovalRequestListItemDto>> ListAsync(
        ApprovalRequestFilter filter,
        ClaimsPrincipal caller,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(filter);
        ArgumentNullException.ThrowIfNull(caller);

        /*
          🔴 THE IDOR BOUNDARY.

          An administrator passes null and sees every organisation's requests.
          Anyone else is pinned to their own — read from the token, so a school
          cannot widen its own view by any parameter it controls.
        */
        var scope = caller.GetUserType() == UserType.Admin
            ? null
            : (Guid?)caller.RequireOrganizationUid();

        var (rows, total) = await _repository.ListAsync(filter, scope, cancellationToken)
            .ConfigureAwait(false);

        return new PagedResult<ApprovalRequestListItemDto>(
            rows.Select(ApprovalRepository.ToDto).ToList(),
            total,
            filter.PageNumber,
            filter.PageSize);
    }

    public async Task<ApprovalRequestDetailDto> GetByIdAsync(
        long requestId,
        ClaimsPrincipal caller,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(caller);

        var detail = await _repository.GetByIdAsync(requestId, cancellationToken).ConfigureAwait(false)
            ?? throw new NotFoundException("That request was not found.");

        EnsureCanRead(detail.Header, caller);

        return detail;
    }

    public async Task<ProcessActionResponse> ProcessActionAsync(
        long requestId,
        ProcessActionRequest request,
        ClaimsPrincipal caller,
        string? ipAddress,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(caller);

        // Read first: the orchestration needs the payload, and the permission
        // check needs the request type.
        var detail = await _repository.GetByIdAsync(requestId, cancellationToken).ConfigureAwait(false)
            ?? throw new NotFoundException("That request was not found.");

        EnsureCanAct(detail.Header, caller);

        if (request.ActionTypeId == ActionReject && request.RejectionReasonId is null)
        {
            throw new BusinessRuleException(
                "A reason is required when rejecting a request.",
                ErrorCodes.ValidationFailed);
        }

        var actionByUserId = caller.GetUserId();

        var result = await _repository.ProcessActionAsync(
            requestId,
            request.ActionTypeId,
            actionByUserId,
            request.RowVersion,
            request.RejectionReasonId,
            request.Remarks,
            ipAddress,

            // The procedure cannot join to jp_sso for roles (decision 2.2), so
            // the caller's roles travel with the call. They come from the token.
            actorRoleIds: null,
            cancellationToken).ConfigureAwait(false);

        result.EnsureSuccess();

        /*
          🔴 COMPLETED IS NOT THE SAME AS APPROVED.

          A rejection also completes a request — it is finished, it just
          finished badly — and an earlier version orchestrated on IsCompleted
          alone. That meant REJECTING a school registration activated the
          account and created the school: the exact outcome the rejection
          existed to prevent, with nothing on any screen to show it had
          happened.

          Found in Phase 2E, by rejecting a request in the admin UI and then
          finding the school sitting in jp_app.

          So the gate is the resulting STATUS, not whether the request stopped
          moving. Nothing downstream runs unless the answer was yes.
        */
        var hasDownstreamWork = result.IsCompleted && result.NewStatusId == StatusApproved;

        var response = new ProcessActionResponse
        {
            RequestId = requestId,
            NewStatusId = result.NewStatusId ?? 0,
            CurrentApprovalLevel = result.CurrentApprovalLevel,
            IsCompleted = result.IsCompleted,
            Message = result.Message,

            /*
              Reads as "nothing is left undone", which is what every caller
              actually branches on.

              A rejection and a level advance both have no downstream work, so
              both are true here. Reporting false for them would light up the
              partial-completion warning on a screen where nothing is wrong —
              and a warning that cries wolf is a warning that gets dismissed on
              the day it is real.
            */
            OrchestrationCompleted = !hasDownstreamWork,
        };

        if (!hasDownstreamWork)
        {
            return response;
        }

        /*
          🔴 THE CROSS-DATABASE HANDOFF.

          The approval is committed. Everything from here is a separate database
          with a separate transaction, and any of it can fail. The orchestration
          service owns that problem; this method's job is to report the truth
          about it rather than smoothing it over.

          Note what is NOT done here: the approval is not rolled back if
          orchestration fails. It cannot be — it is already committed in another
          database — and pretending otherwise would be worse than saying so.
        */
        var fresh = await _repository.GetByIdAsync(requestId, cancellationToken).ConfigureAwait(false)
            ?? detail;

        var outcome = await _orchestration.RunAsync(fresh, actionByUserId, cancellationToken)
            .ConfigureAwait(false);

        return response with
        {
            OrchestrationCompleted = outcome.Succeeded,
            OrchestrationError = outcome.Error,
            Message = outcome.Succeeded
                ? result.Message
                : $"{result.Message} {outcome.Error}",
        };
    }

    public async Task<long> ResubmitAsync(
        long requestId,
        ResubmitRequest request,
        ClaimsPrincipal caller,
        string? ipAddress,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(caller);

        var detail = await _repository.GetByIdAsync(requestId, cancellationToken).ConfigureAwait(false)
            ?? throw new NotFoundException("That request was not found.");

        /*
          🔴 REQUESTOR ONLY. Not "anyone in the organisation", and certainly not
          an admin: a resubmission is the applicant's answer to a rejection, and
          it must be theirs.
        */
        if (detail.Header.RequestorUserId != caller.GetUserId())
        {
            throw new ForbiddenException("Only the person who submitted this request can resubmit it.");
        }

        var result = await _repository.ResubmitAsync(
            requestId, caller.GetUserId(), request.Remarks, request.RowVersion, ipAddress, cancellationToken)
            .ConfigureAwait(false);

        result.EnsureSuccess();

        return requestId;
    }

    public Task<IReadOnlyList<PendingCountDto>> GetPendingCountsAsync(
        ClaimsPrincipal caller,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(caller);

        var scope = caller.GetUserType() == UserType.Admin
            ? null
            : (Guid?)caller.RequireOrganizationUid();

        return _repository.GetPendingCountsAsync(scope, cancellationToken);
    }

    /// <summary>
    /// Saves the registration form as it currently stands.
    /// </summary>
    /// <remarks>
    /// <para>
    /// 🔴 SERVER-SIDE, NOT localStorage.
    /// </para>
    /// <para>
    /// The form is six steps plus documents. Somebody will start it on a laptop
    /// during the working day and finish it on a phone that evening, and a
    /// draft that exists in one browser is a draft they lose — along with the
    /// documents they had already uploaded, which is the point at which they do
    /// not come back.
    /// </para>
    /// <para>
    /// PAN is validated here rather than only on the client, for the ordinary
    /// reason: the client is a convenience and the server is the rule.
    /// </para>
    /// </remarks>
    public async Task<SaveDraftResponse> SaveDraftAsync(
        SaveDraftRequest request,
        ClaimsPrincipal caller,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(caller);

        request = request with { PanNumber = NormalisePan(request.PanNumber) };

        var result = await _repository
            .SaveDraftAsync(request, caller.GetOrganizationUid(), caller.GetUserId(), cancellationToken)
            .ConfigureAwait(false);

        result.EnsureSuccess();

        return new SaveDraftResponse
        {
            RequestId = result.Id ?? 0,
            EntityUid = result.EntityUid ?? Guid.Empty,
            Message = result.Message,
        };
    }

    /// <summary>The caller's draft, if they have one.</summary>
    /// <remarks>
    /// Returns null rather than 404 when there is no draft: not having started
    /// is the normal case, and an error status for it would make every first
    /// visit to the form look like a failure in the network tab.
    /// </remarks>
    public async Task<ApprovalRequestDetailDto?> GetDraftAsync(
        ClaimsPrincipal caller,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(caller);

        var requestId = await _repository.GetDraftIdAsync(caller.GetUserId(), cancellationToken)
            .ConfigureAwait(false);

        if (requestId is null)
        {
            return null;
        }

        var detail = await _repository.GetByIdAsync(requestId.Value, cancellationToken)
            .ConfigureAwait(false);

        // The draft was found by the caller's own id, so this is belt and
        // braces — but it is the check that would matter if that lookup ever
        // grew a parameter.
        if (detail is not null)
        {
            EnsureCanRead(detail.Header, caller);
        }

        return detail;
    }

    /// <summary>
    /// Turns the caller's draft into a request the admin queue can see.
    /// </summary>
    /// <remarks>
    /// The real request number is allocated here rather than at draft time, so
    /// an abandoned draft leaves no hole in a sequence people read as complete.
    /// </remarks>
    public async Task<SubmitApprovalResponse> SubmitDraftAsync(
        long requestId,
        ClaimsPrincipal caller,
        string? ipAddress,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(caller);

        var result = await _repository
            .SubmitDraftAsync(requestId, caller.GetUserId(), ipAddress, cancellationToken)
            .ConfigureAwait(false);

        result.EnsureSuccess();

        var detail = await _repository.GetByIdAsync(requestId, cancellationToken).ConfigureAwait(false);

        return new SubmitApprovalResponse
        {
            RequestId = requestId,
            RequestNo = detail?.Header.RequestNo ?? string.Empty,
            AlreadyPending = false,
            Message = result.Message,
        };
    }

    /// <summary>
    /// Uppercases a PAN and rejects one that is not shaped like a PAN.
    /// </summary>
    /// <remarks>
    /// ⚠️ Empty stays empty. The field is optional on purpose — see the comment
    /// on the column — so "no PAN" is a valid answer and only a MALFORMED one
    /// is an error.
    ///
    /// This checks the shape, not the existence of the number: verifying a PAN
    /// against the income tax department is not something this system does, and
    /// the uploaded PAN document is what an admin actually checks it against.
    /// </remarks>
    private static string? NormalisePan(string? pan)
    {
        if (string.IsNullOrWhiteSpace(pan))
        {
            return null;
        }

        var normalised = pan.Trim().ToUpperInvariant();

        if (!PanFormat.IsMatch(normalised))
        {
            throw new BusinessRuleException(
                "That does not look like a PAN. It is ten characters: five letters, four digits, then a letter — for example ABCDE1234F.",
                ErrorCodes.ValidationFailed);
        }

        return normalised;
    }

    /// <summary>
    /// Approvals that completed but never provisioned.
    /// </summary>
    /// <remarks>
    /// <para>
    /// 🔴 Runs the reconciliation across two databases without joining them.
    /// jp_mdm answers what SHOULD have been provisioned, jp_app answers what
    /// was, and the pairing happens here — which is the same shape as the
    /// orchestration itself, for the same reason (decision 2.2).
    /// </para>
    /// <para>
    /// Admin only. This is an operational report about a failure, not
    /// something a school should read about its own registration; the school's
    /// answer to "did my approval work" is its own account, and if that is
    /// broken it needs a person, not a report.
    /// </para>
    /// </remarks>
    public async Task<IReadOnlyList<OrphanedApprovalDto>> GetOrphanedAsync(
        int sinceDays,
        ClaimsPrincipal caller,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(caller);

        if (caller.GetUserType() != UserType.Admin)
        {
            throw new ForbiddenException("You do not have permission to view the reconciliation report.");
        }

        var completed = await _repository
            .GetCompletedForReconciliationAsync(sinceDays, cancellationToken)
            .ConfigureAwait(false);

        if (completed.Count == 0)
        {
            return [];
        }

        var orphaned = await _provisioning
            .FindOrphanedAsync(
                completed
                    .Select(c => (c.RequestUid, c.RequestNo, c.OrganizationUid, c.CompletedOn))
                    .ToList(),
                cancellationToken)
            .ConfigureAwait(false);

        if (orphaned.Count == 0)
        {
            return [];
        }

        // RequestUid is the only key that crossed the boundary, so it is the
        // only key that can bring the answer back.
        var byUid = completed.ToDictionary(c => c.RequestUid);

        var result = new List<OrphanedApprovalDto>(orphaned.Count);

        foreach (var row in orphaned)
        {
            if (!byUid.TryGetValue(row.RequestUid, out var source))
            {
                // jp_app answered about a request jp_mdm did not send. Not
                // possible today, and worth a line in the log rather than a
                // silent skip if it ever becomes possible.
                _logger.LogWarning(
                    "Reconciliation returned request {RequestUid}, which was not in the list sent to jp_app.",
                    row.RequestUid);
                continue;
            }

            result.Add(new OrphanedApprovalDto
            {
                RequestId = source.RequestId,
                RequestUid = source.RequestUid,
                RequestNo = source.RequestNo,
                RequestTypeId = source.RequestTypeId,
                RequestTypeName = source.RequestTypeName,
                OrganizationUid = source.OrganizationUid,
                RequestorUserId = source.RequestorUserId,
                EntityName = source.EntityName,
                CompletedOn = row.CompletedOn,
                HoursSinceCompleted = row.HoursSinceCompleted,
                Reason =
                    "Approved, but no school record was ever created. The account may be active with nothing " +
                    "behind it — signing in would show an empty workspace.",
            });
        }

        if (result.Count > 0)
        {
            _logger.LogWarning(
                "Reconciliation found {Count} completed approval(s) with no school. Oldest completed {Hours}h ago.",
                result.Count,
                result.Max(r => r.HoursSinceCompleted));
        }

        return result;
    }

    /// <summary>
    /// Runs the cross-database work again for an approval that already
    /// completed.
    /// </summary>
    /// <remarks>
    /// <para>
    /// 🔴 THE FIX FOR A PARTIAL COMPLETION, AND THE REASON IT IS SAFE.
    /// </para>
    /// <para>
    /// Every step of the orchestration is idempotent: provisioning keys on
    /// SourceRequestUid, and activation treats an already-Active user as
    /// success rather than a rule violation. That second part is what makes
    /// this endpoint work at all — before it, a retry stopped at step 1
    /// reporting "already active" and never reached the provisioning that was
    /// the entire reason for retrying.
    /// </para>
    /// <para>
    /// This does NOT re-run the approval. The approval is committed and is not
    /// touched here: no action row, no status change, no RowVersion bump. Only
    /// the work that follows it is repeated, which is why there is no
    /// concurrency parameter — there is nothing here for two admins to
    /// overwrite. Both pressing retry means the work runs twice and converges,
    /// which is exactly what idempotent means.
    /// </para>
    /// </remarks>
    public async Task<ProcessActionResponse> RetryOrchestrationAsync(
        long requestId,
        ClaimsPrincipal caller,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(caller);

        var detail = await _repository.GetByIdAsync(requestId, cancellationToken).ConfigureAwait(false)
            ?? throw new NotFoundException("That request was not found.");

        // Same gate as actioning it. Retrying provisioning IS the approval's
        // effect, so it cannot need less permission than the approval did.
        EnsureCanAct(detail.Header, caller);

        /*
          🔴 APPROVED ONLY.

          A Pending request has nothing to retry — its orchestration has not
          run and should not, because the decision has not been made. A
          Rejected one provisions nothing by definition. Allowing either would
          turn this into a way to provision a school that was never approved.
        */
        if (detail.Header.StatusId != StatusApproved)
        {
            throw new BusinessRuleException(
                $"Only an approved request can be retried. This one is {detail.Header.StatusName.ToLowerInvariant()}.");
        }

        var actionByUserId = caller.GetUserId();

        _logger.LogInformation(
            "Retrying orchestration for approval {RequestNo} (RequestId {RequestId}), requested by user {UserId}.",
            detail.Header.RequestNo, requestId, actionByUserId);

        var outcome = await _orchestration.RunAsync(detail, actionByUserId, cancellationToken)
            .ConfigureAwait(false);

        return new ProcessActionResponse
        {
            RequestId = requestId,
            NewStatusId = detail.Header.StatusId,
            CurrentApprovalLevel = detail.Header.CurrentApprovalLevel,
            IsCompleted = true,
            OrchestrationCompleted = outcome.Succeeded,
            OrchestrationError = outcome.Error,
            Message = outcome.Succeeded
                ? "The outstanding work for this approval has now completed."
                : outcome.Error ?? "The retry did not complete.",
        };
    }

    /// <summary>
    /// A school may read only its own requests. An admin may read any.
    /// </summary>
    internal static void EnsureCanRead(ApprovalRequestListItemDto header, ClaimsPrincipal caller)
    {
        if (caller.GetUserType() == UserType.Admin)
        {
            return;
        }

        // The requestor can always see their own, organisation or not — a
        // teacher's verification request has no organisation at all.
        if (header.RequestorUserId == caller.GetUserId())
        {
            return;
        }

        var scope = caller.GetOrganizationUid();

        if (scope is null || header.OrganizationUid != scope)
        {
            // Deliberately the same message a missing request would produce.
            // Confirming that a request exists but is not yours is itself a
            // small leak.
            throw new NotFoundException("That request was not found.");
        }
    }

    /// <summary>
    /// Only an admin holding the verification permission for THIS request type
    /// may action it.
    /// </summary>
    private static void EnsureCanAct(ApprovalRequestListItemDto header, ClaimsPrincipal caller)
    {
        var required = header.RequestTypeId == RequestTypeTeacherVerification
            ? AppConstants.PermissionCodes.VerificationTeacher
            : AppConstants.PermissionCodes.VerificationSchool;

        if (caller.GetUserType() != UserType.Admin || !caller.HasPermission(required))
        {
            throw new ForbiddenException("You do not have permission to action this request.");
        }
    }
}
