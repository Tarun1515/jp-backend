using System.Security.Claims;
using JP.Core.Constants;
using JP.Core.Exceptions;
using JP.Core.Extensions;
using JP.Domain.Jobs;
using JP.Infrastructure.Repositories;
using Microsoft.Extensions.Logging;

namespace JP.Infrastructure.Services;

public interface IJobService
{
    Task<IReadOnlyList<JobListItemDto>> GetListAsync(
        ClaimsPrincipal caller, int? statusId, long? branchId, CancellationToken cancellationToken);

    Task<JobDetailDto> GetByIdAsync(ClaimsPrincipal caller, long jobId, CancellationToken cancellationToken);

    Task<long> SaveAsync(ClaimsPrincipal caller, SaveJobRequest request, CancellationToken cancellationToken);

    Task<PublishJobResultDto> PublishAsync(ClaimsPrincipal caller, long jobId, CancellationToken cancellationToken);

    Task CloseAsync(ClaimsPrincipal caller, long jobId, CancellationToken cancellationToken);

    Task<SchoolJobStatsDto> GetStatsAsync(ClaimsPrincipal caller, CancellationToken cancellationToken);
}

/// <summary>
/// School-side jobs, and the entitlement engine's first real caller.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 PERMISSIONS COME FROM THE SEED, NOT FROM THIS FILE'S OPINION. The
/// seeded grants say: HR may create and edit, and may NOT publish or close;
/// Owner and Senior HR may do all five; Viewer may only view. Nothing here
/// re-decides that — it checks the permission the token carries.
/// </para>
/// <para>
/// 🔴 SCOPE IS RESOLVED FROM THE TOKEN, EVERY TIME (2.39). SchoolId comes from
/// the caller's membership, never from the request; BranchId comes from the
/// request and is validated inside the procedure against fn_VisibleBranches.
/// </para>
/// </remarks>
internal sealed class JobService : IJobService
{
    private readonly IJobRepository _jobs;
    private readonly ISchoolProfileService _schools;
    private readonly IEntitlementRepository _catalog;
    private readonly ISubscriptionRepository _subscriptions;
    private readonly ILogger<JobService> _logger;

    /// <summary>The feature a publish spends. Resolved by code, never by id.</summary>
    private const string JobPostFeature = "JOB_POST";

    public JobService(
        IJobRepository jobs,
        ISchoolProfileService schools,
        IEntitlementRepository catalog,
        ISubscriptionRepository subscriptions,
        ILogger<JobService> logger)
    {
        _jobs = jobs;
        _schools = schools;
        _catalog = catalog;
        _subscriptions = subscriptions;
        _logger = logger;
    }

    public async Task<IReadOnlyList<JobListItemDto>> GetListAsync(
        ClaimsPrincipal caller, int? statusId, long? branchId, CancellationToken cancellationToken)
    {
        Require(caller, AppConstants.PermissionCodes.JobView);

        var schoolId = await _schools.ResolveSchoolIdAsync(caller, cancellationToken).ConfigureAwait(false);

        return await _jobs.GetListAsync(schoolId, caller.GetUserUid(), statusId, branchId, cancellationToken)
            .ConfigureAwait(false);
    }

    public async Task<JobDetailDto> GetByIdAsync(
        ClaimsPrincipal caller, long jobId, CancellationToken cancellationToken)
    {
        Require(caller, AppConstants.PermissionCodes.JobView);

        var schoolId = await _schools.ResolveSchoolIdAsync(caller, cancellationToken).ConfigureAwait(false);

        return await _jobs.GetByIdAsync(schoolId, caller.GetUserUid(), jobId, cancellationToken)
            .ConfigureAwait(false)
            // NOT_FOUND, never FORBIDDEN — see 2.6. A job at a campus the caller
            // cannot see does not exist as far as they are concerned.
            ?? throw new NotFoundException("That job was not found.");
    }

    public async Task<long> SaveAsync(
        ClaimsPrincipal caller, SaveJobRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        // Creating and editing are separate grants in the seed, so they are
        // separate checks here.
        Require(caller, request.JobId is null
            ? AppConstants.PermissionCodes.JobCreate
            : AppConstants.PermissionCodes.JobEdit);

        var schoolId = await _schools.ResolveSchoolIdAsync(caller, cancellationToken).ConfigureAwait(false);

        var result = await _jobs
            .SaveAsync(schoolId, caller.GetUserUid(), request, caller.GetUserId(), cancellationToken)
            .ConfigureAwait(false);

        result.EnsureSuccess();

        return result.Id ?? 0;
    }

    /// <summary>
    /// Publish, and spend the entitlement — as one act.
    /// </summary>
    /// <remarks>
    /// <para>
    /// 🔴 THE SERVICE DOES NOT CONSUME AND THEN PUBLISH. It resolves the gating
    /// and hands it to ONE procedure that does both inside one transaction. Two
    /// calls from here would leave a window where a school has been charged for
    /// a job that is still a draft.
    /// </para>
    /// <para>
    /// ⚠️ The jp_mdm read is direct and never cached — <see
    /// cref="IEntitlementRepository"/>, not <c>IMasterService</c>. An hour of
    /// lag would mean a kill switch that engages an hour after it is flipped.
    /// </para>
    /// <para>
    /// PLAN_CHANGED is retried exactly once, for the same reason
    /// <c>EntitlementService</c> retries it: the plan has to be read before its
    /// mapping can be looked up, and the two reads are not under one lock.
    /// </para>
    /// </remarks>
    public async Task<PublishJobResultDto> PublishAsync(
        ClaimsPrincipal caller, long jobId, CancellationToken cancellationToken)
    {
        Require(caller, AppConstants.PermissionCodes.JobPublish);

        var schoolId = await _schools.ResolveSchoolIdAsync(caller, cancellationToken).ConfigureAwait(false);

        /*
          🔴 The subscription's owner for a school is the ORGANISATION, not the
          user (2.51). Taken from the token's orgUid claim — never a parameter.
        */
        var ownerUid = caller.RequireOrganizationUid();

        for (var attempt = 1; ; attempt++)
        {
            var subscription = await _subscriptions.GetCurrentAsync(ownerUid, cancellationToken)
                .ConfigureAwait(false);

            if (subscription is null)
            {
                // Every account holds a plan from the moment it exists (2F,
                // G21). No row means provisioning is broken, not that this
                // school is in a normal state.
                _logger.LogError(
                    "ENTITLEMENT INTEGRITY: organisation {OwnerUid} has no subscription row; "
                    + "cannot publish job {JobId}.", ownerUid, jobId);

                throw new AppException(
                    "This account has no subscription on file. Please contact support.",
                    ErrorCodes.SubscriptionMissing, System.Net.HttpStatusCode.Forbidden);
            }

            var resolution = await _catalog
                .ResolveAsync(JobPostFeature, subscription.PlanId, cancellationToken).ConfigureAwait(false);

            if (resolution is null || !resolution.IsActive)
            {
                _logger.LogInformation(
                    "JOB_POST is unavailable (missing or switched off); refusing publish of job {JobId}.", jobId);

                throw new AppException(
                    "Posting jobs is currently switched off.",
                    ErrorCodes.FeatureDisabled, System.Net.HttpStatusCode.Forbidden);
            }

            var row = await _jobs.PublishAsync(
                schoolId, caller.GetUserUid(), jobId, ownerUid,
                resolution.FeatureId, resolution.GatingModeId, resolution.HasMapping,
                resolution.IsIncluded, resolution.QuotaPerPeriod,
                subscription.PlanId, caller.GetUserId(), cancellationToken).ConfigureAwait(false);

            if (row.Code == ErrorCodes.PlanChanged && attempt < 2)
            {
                _logger.LogInformation(
                    "Publish of job {JobId} re-resolving after a plan change.", jobId);

                continue;
            }

            if (!row.Succeeded)
            {
                throw ToRefusal(row.Code, row.Message);
            }

            return new PublishJobResultDto
            {
                JobId = jobId,
                JobStatusId = JobStatus.Active,
                Consumed = row.Consumed == 1,
                Source = row.SourceId,
                EntryId = row.Id,
                Code = row.Code,      // ⚠️ may be ALREADY_CONSUMED — a success
            };
        }
    }

    public async Task CloseAsync(ClaimsPrincipal caller, long jobId, CancellationToken cancellationToken)
    {
        Require(caller, AppConstants.PermissionCodes.JobClose);

        var schoolId = await _schools.ResolveSchoolIdAsync(caller, cancellationToken).ConfigureAwait(false);

        var result = await _jobs
            .CloseAsync(schoolId, caller.GetUserUid(), jobId, caller.GetUserId(), cancellationToken)
            .ConfigureAwait(false);

        result.EnsureSuccess();
    }

    /// <summary>
    /// The dashboard's jobs area: counts and the five most recent.
    /// </summary>
    /// <remarks>
    /// <para>
    /// 🔴 JOB.VIEW ONLY. Reading how many jobs exist is a read, and a Viewer
    /// sees the dashboard — so a Viewer sees the counts. Requiring publish or
    /// close here would blank the tile for the exact people it is written for.
    /// </para>
    /// <para>
    /// ⚠️ This check was MISSING until Phase 4B. The method was built in Phase
    /// 4 and nothing called it, so nothing exercised its authorization — which
    /// is its own small lesson: an unreachable method is an unverified one.
    /// </para>
    /// <para>
    /// 🔴 There is no school parameter, here or on the endpoint. SchoolId comes
    /// from the caller's membership (2.39) and there is deliberately nothing to
    /// forge — see JobsController.GetStats.
    /// </para>
    /// </remarks>
    public async Task<SchoolJobStatsDto> GetStatsAsync(
        ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        Require(caller, AppConstants.PermissionCodes.JobView);

        var schoolId = await _schools.ResolveSchoolIdAsync(caller, cancellationToken).ConfigureAwait(false);

        return await _jobs.GetStatsAsync(schoolId, caller.GetUserUid(), cancellationToken)
            .ConfigureAwait(false);
    }

    /// <summary>
    /// The entitlement codes, mapped to the statuses they deserve.
    /// </summary>
    /// <remarks>
    /// ⚠️ Publish can refuse for two unrelated families of reason — the job
    /// (NOT_FOUND, JOB_ALREADY_ACTIVE, LAST_DATE_IN_PAST) and the entitlement
    /// (QUOTA_EXHAUSTED, PLAN_LACKS_FEATURE, …). They keep distinct codes so a
    /// screen can offer "change the date" for one and "upgrade" for the other.
    /// </remarks>
    private static Exception ToRefusal(string? code, string message)
    {
        if (string.IsNullOrWhiteSpace(message))
        {
            message = "That job could not be published.";
        }

        return code switch
        {
            ErrorCodes.NotFound => new NotFoundException(message),

            ErrorCodes.FeatureDisabled or ErrorCodes.SubscriptionInactive
                or ErrorCodes.SubscriptionMissing
                => new AppException(message, code, System.Net.HttpStatusCode.Forbidden),

            ErrorCodes.ConsumeConflict or ErrorCodes.PlanChanged
                => new AppException(message, code, System.Net.HttpStatusCode.Conflict),

            _ => new BusinessRuleException(message, code ?? ErrorCodes.BusinessRuleViolated),
        };
    }

    /// <summary>
    /// The seeded permission decides, not this file.
    /// </summary>
    /// <remarks>
    /// 🔴 Whether HR can publish is a question with an answer already in the
    /// database: the seed grants HR JOB.CREATE, JOB.EDIT and JOB.VIEW and does
    /// NOT grant JOB.PUBLISH or JOB.CLOSE. Hard-coding a role check here would
    /// be a second answer to the same question, and the day somebody changes
    /// the seed the two would disagree silently.
    /// </remarks>
    private static void Require(ClaimsPrincipal caller, string permission)
    {
        if (!caller.HasPermission(permission))
        {
            throw new ForbiddenException("You do not have permission to do that.");
        }
    }
}
