using System.Security.Claims;
using JP.Core.Constants;
using JP.Core.Exceptions;
using JP.Core.Extensions;
using JP.Domain.Applications;
using JP.Infrastructure.Repositories;
using JP.Infrastructure.Storage;
using Microsoft.Extensions.Logging;

namespace JP.Infrastructure.Services;

public interface IApplicantService
{
    Task<IReadOnlyList<ApplicantListItemDto>> GetListAsync(
        ClaimsPrincipal caller, long? jobId, int? statusId, long? branchId,
        CancellationToken cancellationToken);

    Task<ApplicantDetailDto> GetByIdAsync(
        ClaimsPrincipal caller, long applicationId, CancellationToken cancellationToken);

    Task<(Stream Content, string ContentType)> OpenResumeAsync(
        ClaimsPrincipal caller, long applicationId, CancellationToken cancellationToken);

    Task SetStatusAsync(
        ClaimsPrincipal caller, long applicationId, SetApplicationStatusRequest request,
        CancellationToken cancellationToken);

    Task<SchoolApplicantStatsDto> GetStatsAsync(ClaimsPrincipal caller, CancellationToken cancellationToken);
}

/// <summary>
/// The school's side of an application.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 PERMISSIONS COME FROM THE SEED, NOT FROM THIS FILE'S OPINION — and the
/// seed is not what the role names suggest. It grants:
/// </para>
/// <code>
///   SCHOOL_OWNER   VIEW · SHORTLIST · REJECT · RESUME.DOWNLOAD
///   SENIOR_HR      VIEW · SHORTLIST · REJECT · RESUME.DOWNLOAD
///   HR             VIEW · SHORTLIST ·          RESUME.DOWNLOAD     🔴 no REJECT
///   SCHOOL_VIEWER  VIEW                                            🔴 no download
/// </code>
/// <para>
/// So an HR screens and shortlists, and somebody senior turns people down; a
/// Viewer sees that a resume exists and cannot open it. Nothing here re-decides
/// either — a hard-coded role check would be a second answer to a question the
/// database already answers, and the day the seed changes the two would
/// silently disagree.
/// </para>
/// <para>
/// 🔴 SCOPE IS RESOLVED FROM THE TOKEN, EVERY TIME (2.39). SchoolId comes from
/// the caller's membership and the procedures join through
/// <c>fn_VisibleBranches</c>, so a branch-bound HR acts only on their campuses
/// — and anything outside that scope answers NOT_FOUND, never FORBIDDEN (2.6).
/// </para>
/// <para>
/// ⚠️ THERE IS NO ENTITLEMENT CALL IN THIS FILE. Reading and moving applicants
/// costs nothing; the consuming action is the school's publish (2.64).
/// </para>
/// </remarks>
internal sealed class ApplicantService : IApplicantService
{
    private readonly IApplicationRepository _applications;
    private readonly ISchoolProfileService _schools;
    private readonly IFileStorageService _storage;
    private readonly ILogger<ApplicantService> _logger;

    public ApplicantService(
        IApplicationRepository applications,
        ISchoolProfileService schools,
        IFileStorageService storage,
        ILogger<ApplicantService> logger)
    {
        _applications = applications;
        _schools = schools;
        _storage = storage;
        _logger = logger;
    }

    public async Task<IReadOnlyList<ApplicantListItemDto>> GetListAsync(
        ClaimsPrincipal caller, long? jobId, int? statusId, long? branchId,
        CancellationToken cancellationToken)
    {
        Require(caller, AppConstants.PermissionCodes.ApplicantView);

        var schoolId = await _schools.ResolveSchoolIdAsync(caller, cancellationToken).ConfigureAwait(false);

        return await _applications
            .GetApplicantListAsync(schoolId, caller.GetUserUid(), jobId, statusId, branchId, cancellationToken)
            .ConfigureAwait(false);
    }

    /// <summary>
    /// One applicant, and the Applied → Viewed stamp that opening one means.
    /// </summary>
    /// <remarks>
    /// <para>
    /// ⚠️ THE ONE READ THAT WRITES, AND IT IS DELIBERATE. Opening an
    /// application is how a school "sees" it, and the teacher's own list says
    /// "Seen by the school" on the strength of that. Making it an explicit
    /// button would mean the flag reported whether somebody remembered to press
    /// it.
    /// </para>
    /// <para>
    /// It is idempotent by construction — <c>USP_MarkApplicationViewed</c> moves
    /// only an application still at Applied — so opening it twenty times writes
    /// one history row.
    /// </para>
    /// <para>
    /// 🔴 THE STAMP HAPPENS AFTER THE READ, AND ITS FAILURE NEVER FAILS THE
    /// READ. A school being unable to look at an applicant because a status
    /// write hiccuped would be a far worse outcome than a missing timestamp,
    /// and the log carries the miss.
    /// </para>
    /// </remarks>
    public async Task<ApplicantDetailDto> GetByIdAsync(
        ClaimsPrincipal caller, long applicationId, CancellationToken cancellationToken)
    {
        Require(caller, AppConstants.PermissionCodes.ApplicantView);

        var schoolId = await _schools.ResolveSchoolIdAsync(caller, cancellationToken).ConfigureAwait(false);
        var userUid = caller.GetUserUid();

        var detail = await _applications
            .GetApplicantByIdAsync(schoolId, userUid, applicationId, cancellationToken).ConfigureAwait(false)
            // NOT_FOUND, never FORBIDDEN (2.6). An application at a campus the
            // caller cannot see does not exist as far as they are concerned.
            ?? throw new NotFoundException("That application was not found.");

        if (detail.ApplicationStatusId == ApplicationStatus.Applied)
        {
            try
            {
                await _applications
                    .MarkViewedAsync(schoolId, userUid, applicationId, caller.GetUserId(), cancellationToken)
                    .ConfigureAwait(false);

                // What was returned above is what the caller asked for; the
                // stamp has moved it on, so say so rather than leaving the
                // screen one refresh behind its own action.
                detail.ApplicationStatusId = ApplicationStatus.Viewed;
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                _logger.LogWarning(ex,
                    "Application {ApplicationId} was opened by school {SchoolId} but could not be stamped "
                    + "as viewed. The read is unaffected.", applicationId, schoolId);
            }
        }

        return detail;
    }

    /// <summary>
    /// The resume the school was given — the SNAPSHOT.
    /// </summary>
    /// <remarks>
    /// <para>
    /// 🔴 TWO PERMISSIONS, AND THE SECOND IS THE POINT. APPLICANT.VIEW gets
    /// somebody to the applicant; RESUME.DOWNLOAD gets them the file. A
    /// SCHOOL_VIEWER holds the first and not the second, so a read-only account
    /// can see that a resume exists and cannot open a document carrying a
    /// teacher's phone number and home address (2.56 — the resume IS a contact
    /// detail).
    /// </para>
    /// <para>
    /// 🔴 The path comes from <c>t_app_applications.ResumePathSnapshot</c> and
    /// never from the teacher's live profile. A school that shortlisted
    /// somebody re-reads what it shortlisted, whatever the teacher has uploaded
    /// since.
    /// </para>
    /// </remarks>
    public async Task<(Stream Content, string ContentType)> OpenResumeAsync(
        ClaimsPrincipal caller, long applicationId, CancellationToken cancellationToken)
    {
        Require(caller, AppConstants.PermissionCodes.ApplicantView);
        Require(caller, AppConstants.PermissionCodes.ResumeDownload);

        var schoolId = await _schools.ResolveSchoolIdAsync(caller, cancellationToken).ConfigureAwait(false);

        var path = await _applications
            .GetResumeSnapshotPathAsync(schoolId, caller.GetUserUid(), applicationId, cancellationToken)
            .ConfigureAwait(false)
            ?? throw new NotFoundException("That resume was not found.");

        return (await _storage.OpenReadAsync(path, cancellationToken).ConfigureAwait(false), "application/pdf");
    }

    /// <summary>
    /// Move an application along.
    /// </summary>
    /// <remarks>
    /// <para>
    /// 🔴 WHICH PERMISSION IS REQUIRED DEPENDS ON WHERE IT IS BEING MOVED TO,
    /// because the seed draws the line there: rejecting is APPLICANT.REJECT and
    /// everything else on the pipeline is APPLICANT.SHORTLIST. HR holds the
    /// second and not the first.
    /// </para>
    /// <para>
    /// ⚠️ The permission is checked BEFORE the transition map, so somebody
    /// without the grant is told they may not do it rather than being told the
    /// move is illegal — two different problems, and telling somebody the wrong
    /// one sends them to support.
    /// </para>
    /// <para>
    /// 🔴 The map itself lives in <c>fn_ApplicationTransitionAllowed</c> and
    /// nothing here duplicates it. Rejected is terminal; 7–10 are Phase 6 and
    /// refuse with their own code.
    /// </para>
    /// </remarks>
    public async Task SetStatusAsync(
        ClaimsPrincipal caller, long applicationId, SetApplicationStatusRequest request,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        Require(caller, request.ToStatusId == ApplicationStatus.Rejected
            ? AppConstants.PermissionCodes.ApplicantReject
            : AppConstants.PermissionCodes.ApplicantShortlist);

        var schoolId = await _schools.ResolveSchoolIdAsync(caller, cancellationToken).ConfigureAwait(false);

        var result = await _applications.SetStatusAsync(
            schoolId, caller.GetUserUid(), applicationId, request.ToStatusId, request.Remarks,
            caller.GetUserId(), cancellationToken).ConfigureAwait(false);

        /*
          ⚠️ NO_CHANGE arrives with Status = 1 — asking for the state it is
          already in is not an error (2.48) — so EnsureSuccess lets it through
          untouched, which is the intended behaviour.
        */
        result.EnsureSuccess();
    }

    /// <summary>
    /// The dashboard's applicants area: counts and the five most recent.
    /// </summary>
    /// <remarks>
    /// <para>
    /// 🔴 APPLICANT.VIEW ONLY. Reading how many applicants exist is a read, and
    /// a Viewer sees the dashboard — so a Viewer sees the counts. Gating this on
    /// SHORTLIST would blank the tile for the exact people it is written for.
    /// The same reasoning JobService.GetStatsAsync records for JOB.VIEW.
    /// </para>
    /// <para>
    /// 🔴 No parameters, here or on the endpoint. SchoolId comes from the
    /// caller's membership (2.39), so there is nothing to forge.
    /// </para>
    /// </remarks>
    public async Task<SchoolApplicantStatsDto> GetStatsAsync(
        ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        Require(caller, AppConstants.PermissionCodes.ApplicantView);

        var schoolId = await _schools.ResolveSchoolIdAsync(caller, cancellationToken).ConfigureAwait(false);

        return await _applications.GetSchoolStatsAsync(schoolId, caller.GetUserUid(), cancellationToken)
            .ConfigureAwait(false);
    }

    /// <summary>The seeded permission decides, not this file.</summary>
    private static void Require(ClaimsPrincipal caller, string permission)
    {
        if (!caller.HasPermission(permission))
        {
            throw new ForbiddenException("You do not have permission to do that.");
        }
    }
}
