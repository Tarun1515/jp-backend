using System.Security.Claims;
using JP.Core.Constants;
using JP.Core.Exceptions;
using JP.Core.Extensions;
using JP.Domain.Admin;
using JP.Infrastructure.Repositories;
using JP.Core.Enums;

namespace JP.Infrastructure.Services;

/// <summary>
/// The admin analytics screen's one read. Phase 8-0.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 THREE DATABASES, ASSEMBLED HERE AND NOWHERE ELSE (2.2).
/// </para>
/// <para>
/// Registrations are jp_sso, approvals are jp_mdm, jobs and applications are
/// jp_app. Each repository is bound to exactly one database by
/// <c>BaseRepository.Database</c>, so there is no object in this product that
/// could join them even by accident — this service calls three and puts the
/// answers in one envelope, the shape provisioning has used since 2F.
/// </para>
/// <para>
/// ⚠️ THREE SEQUENTIAL READS, NOT PARALLEL. They are cheap, they are counts,
/// and running them concurrently would open three connections to satisfy one
/// screen that nobody is waiting on. If this ever becomes slow the answer is
/// an index, measured first.
/// </para>
/// <para>
/// 🔒 REPORT.VIEW, AND IT IS NOT USER.MANAGE. A person who may read the
/// platform's totals is not thereby trusted with the people in them. Both
/// identity databases' procedures carry a build guard that fails if an email,
/// a uid, a requestor or a request number appears in them, so this surface
/// cannot quietly become an identity read.
/// </para>
/// </remarks>
public interface IAdminAnalyticsService
{
    Task<AdminAnalyticsDto> GetAsync(ClaimsPrincipal caller, CancellationToken cancellationToken);
}

internal sealed class AdminAnalyticsService : IAdminAnalyticsService
{
    private readonly IUserRepository _users;
    private readonly IApprovalRepository _approvals;
    private readonly IAdminDeskRepository _desk;

    public AdminAnalyticsService(
        IUserRepository users,
        IApprovalRepository approvals,
        IAdminDeskRepository desk)
    {
        _users = users;
        _approvals = approvals;
        _desk = desk;
    }

    public async Task<AdminAnalyticsDto> GetAsync(
        ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        EnsureCanRead(caller);

        var (registrations, identity) = await _users
            .GetIdentityAnalyticsAsync(cancellationToken).ConfigureAwait(false);

        var approvals = await _approvals
            .GetApprovalAnalyticsAsync(cancellationToken).ConfigureAwait(false);

        var app = await _desk
            .GetAppAnalyticsAsync(cancellationToken).ConfigureAwait(false);

        return new AdminAnalyticsDto
        {
            Registrations = registrations,
            Identity = identity,

            Approvals = approvals.Counts,
            Waits = approvals.Waits,
            ApprovalTotals = approvals.Totals,

            Jobs = app.Jobs,
            Applications = app.Applications,
            Invites = app.Invites,
            AppTotals = app.Totals,
        };
    }

    /// <summary>
    /// 🔒 REPORT.VIEW. The seeded menu row carries the same code.
    /// </summary>
    /// <remarks>
    /// ⚠️ A SCHOOL HOLDS REPORT.VIEW TOO — a school Viewer has it, for its own
    /// reports. So the permission alone is not the gate here: the controller is
    /// admin-only by its route and this check is the second half, exactly as
    /// the desk's four Ensure* gates are. A school reaching this would see
    /// platform-wide totals, which is nobody's business but ours.
    /// </remarks>
    private static void EnsureCanRead(ClaimsPrincipal caller)
    {
        if (caller.GetUserType() != UserType.Admin)
        {
            throw new ForbiddenException(
                "Platform analytics are an administrator's view. A school's own reports are "
                + "on its dashboard.");
        }

        if (!caller.HasPermission(AppConstants.PermissionCodes.ReportView))
        {
            throw new ForbiddenException(
                $"{AppConstants.PermissionCodes.ReportView} is required to read platform analytics.");
        }
    }
}
