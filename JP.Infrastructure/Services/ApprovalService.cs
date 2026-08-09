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

    private readonly IApprovalRepository _repository;
    private readonly IApprovalOrchestrationService _orchestration;
    private readonly ILogger<ApprovalService> _logger;

    public ApprovalService(
        IApprovalRepository repository,
        IApprovalOrchestrationService orchestration,
        ILogger<ApprovalService> logger)
    {
        _repository = repository;
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
            request.Remarks,
            ipAddress,

            // The procedure cannot join to jp_sso for roles (decision 2.2), so
            // the caller's roles travel with the call. They come from the token.
            actorRoleIds: null,
            cancellationToken).ConfigureAwait(false);

        result.EnsureSuccess();

        var response = new ProcessActionResponse
        {
            RequestId = requestId,
            NewStatusId = result.NewStatusId ?? 0,
            CurrentApprovalLevel = result.CurrentApprovalLevel,
            IsCompleted = result.IsCompleted,
            Message = result.Message,

            // Nothing to orchestrate unless the action finished the request.
            OrchestrationCompleted = !result.IsCompleted,
        };

        if (!result.IsCompleted)
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
