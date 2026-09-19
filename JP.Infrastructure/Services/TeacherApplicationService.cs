using System.Security.Claims;
using JP.Core.Constants;
using JP.Core.Enums;
using JP.Core.Exceptions;
using JP.Core.Extensions;
using JP.Domain.Applications;
using JP.Domain.Common;
using JP.Infrastructure.Repositories;
using Microsoft.Extensions.Logging;

namespace JP.Infrastructure.Services;

public interface ITeacherApplicationService
{
    Task<PagedResult<JobBrowseItemDto>> BrowseJobsAsync(
        ClaimsPrincipal caller, JobBrowseFilter filter, CancellationToken cancellationToken);

    Task<JobForTeacherDto> GetJobAsync(ClaimsPrincipal caller, long jobId, CancellationToken cancellationToken);

    Task<ApplyResultDto> ApplyAsync(
        ClaimsPrincipal caller, ApplyToJobRequest request, CancellationToken cancellationToken);

    Task<IReadOnlyList<MyApplicationListItemDto>> GetMyApplicationsAsync(
        ClaimsPrincipal caller, int? statusId, CancellationToken cancellationToken);

    Task<MyApplicationDetailDto> GetMyApplicationAsync(
        ClaimsPrincipal caller, long applicationId, CancellationToken cancellationToken);

    Task<ToggleSavedJobResultDto> ToggleSavedJobAsync(
        ClaimsPrincipal caller, long jobId, CancellationToken cancellationToken);

    Task<IReadOnlyList<SavedJobDto>> GetSavedJobsAsync(
        ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task<TeacherApplicationStatsDto> GetStatsAsync(
        ClaimsPrincipal caller, CancellationToken cancellationToken);
}

/// <summary>
/// The teacher's side: browsing jobs, applying, and their own list.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 APPLYING IS FREE, AND THERE IS NO ENTITLEMENT CALL ANYWHERE IN THIS FILE.
/// Not a ConsumeAsync, not a quota read, not a plan check. The consuming action
/// in this product is the SCHOOL'S PUBLISH (2.64) — charging a teacher to look
/// for work is not a pricing decision this product will ever take, and a
/// QUOTA_EXHAUSTED reaching an apply would be the sign it had.
/// </para>
/// <para>
/// 🔴 THE TEACHER COMES FROM THE TOKEN. Every read passes the caller's own Uid
/// and the procedure resolves the teacher itself; the two writes take an id
/// that <see cref="IApplicationRepository.ResolveTeacherAsync"/> produced from
/// that same Uid. No request type in <c>JP.Domain.Applications</c> carries a
/// teacher id, so applying on somebody else's behalf cannot be expressed —
/// the property 3D established for the profile, carried into this phase.
/// </para>
/// <para>
/// 🔴 AN APPLICATION IS CONSENT (2.56, LOCKED). A successful apply is what
/// opens this teacher's phone number and email to ONE school. That is why the
/// refusals here are careful and why nothing in this file writes an application
/// by any route other than <c>USP_ApplyToJob</c>.
/// </para>
/// <para>
/// ⚠️ VERIFICATION IS NOT CHECKED, ANYWHERE. An UNVERIFIED teacher may apply.
/// Soft verification is a locked stance (2.9): the badge is a signal to schools,
/// never a gate on the teacher, and gating applications on our own queue length
/// would punish people for how busy we are.
/// </para>
/// </remarks>
internal sealed class TeacherApplicationService : ITeacherApplicationService
{
    private readonly IApplicationRepository _applications;
    private readonly ILogger<TeacherApplicationService> _logger;

    public TeacherApplicationService(
        IApplicationRepository applications,
        ILogger<TeacherApplicationService> logger)
    {
        _applications = applications;
        _logger = logger;
    }

    /// <summary>
    /// The job market, ACTIVE postings only.
    /// </summary>
    /// <remarks>
    /// 🔴 JOB.VIEW, which the seed grants TEACHER. Using the seeded grant
    /// rather than inventing a rule here keeps the one answer in one place —
    /// and the type check keeps a school account out of a teacher's screen even
    /// though it holds the same permission.
    /// </remarks>
    public async Task<PagedResult<JobBrowseItemDto>> BrowseJobsAsync(
        ClaimsPrincipal caller, JobBrowseFilter filter, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(filter);

        EnsureTeacher(caller);
        Require(caller, AppConstants.PermissionCodes.JobView);

        var (rows, total) = await _applications
            .BrowseJobsAsync(caller.GetUserUid(), filter, cancellationToken).ConfigureAwait(false);

        return new PagedResult<JobBrowseItemDto>(rows, total, filter.PageNumber, filter.PageSize);
    }

    /// <summary>
    /// One posting.
    /// </summary>
    /// <remarks>
    /// 🔴 An EXPIRED or CLOSED job answers 404 here, the same as one that never
    /// existed. This is the URL somebody bookmarks or is sent a month later, and
    /// a page with an Apply button the server will refuse is worse than an
    /// honest "this posting has gone".
    /// </remarks>
    public async Task<JobForTeacherDto> GetJobAsync(
        ClaimsPrincipal caller, long jobId, CancellationToken cancellationToken)
    {
        EnsureTeacher(caller);
        Require(caller, AppConstants.PermissionCodes.JobView);

        return await _applications.GetJobForTeacherAsync(jobId, caller.GetUserUid(), cancellationToken)
            .ConfigureAwait(false)
            ?? throw new NotFoundException("That job was not found, or it is no longer open.");
    }

    /// <summary>
    /// Apply. 🔴 This is consent path 1 (2.56).
    /// </summary>
    /// <remarks>
    /// <para>
    /// No permission is required beyond being a teacher. The seed grants TEACHER
    /// no APPLICANT.* permission and should not: those describe what a SCHOOL
    /// may do to applicants. A teacher acting on their own data needs a grant
    /// as little as they need one to edit their own profile.
    /// </para>
    /// <para>
    /// ⚠️ ALREADY_APPLIED IS A SUCCESS, and it is returned as one — HTTP 200
    /// with the code set. The teacher wanted to have applied, and they have.
    /// Turning a double-tap into an error sends somebody to support over a
    /// working application, and it is also what the loser of a genuinely
    /// parallel double-apply receives.
    /// </para>
    /// </remarks>
    public async Task<ApplyResultDto> ApplyAsync(
        ClaimsPrincipal caller, ApplyToJobRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        EnsureTeacher(caller);

        var teacher = await ResolveTeacherAsync(caller, cancellationToken).ConfigureAwait(false);

        var result = await _applications.ApplyAsync(
            teacher.TeacherId, request.JobId, request.CoverNote, caller.GetUserId(), cancellationToken)
            .ConfigureAwait(false);

        if (!result.Succeeded)
        {
            throw ToRefusal(result.Code, result.Message);
        }

        var already = string.Equals(result.Code, ErrorCodes.AlreadyApplied, StringComparison.Ordinal);

        if (!already)
        {
            /*
              Worth a log line on its own: this is the moment a teacher's
              contact details became visible to one school, and the audit
              question "when did this school get this number" is answered by the
              application row plus this.
            */
            _logger.LogInformation(
                "Teacher {TeacherUid} applied to job {JobId} (application {ApplicationId}). "
                + "Contact is now unlocked for that school (2.56 path 1).",
                teacher.TeacherUid, request.JobId, result.Id);
        }

        return new ApplyResultDto
        {
            ApplicationId = result.Id ?? 0,
            Code = result.Code,          // ⚠️ may be ALREADY_APPLIED — a success
            Created = !already,
        };
    }

    public async Task<IReadOnlyList<MyApplicationListItemDto>> GetMyApplicationsAsync(
        ClaimsPrincipal caller, int? statusId, CancellationToken cancellationToken)
    {
        EnsureTeacher(caller);

        return await _applications.GetMyApplicationsAsync(caller.GetUserUid(), statusId, cancellationToken)
            .ConfigureAwait(false);
    }

    /// <summary>
    /// One of the caller's own applications.
    /// </summary>
    /// <remarks>
    /// ⚠️ Another teacher's application id resolves to nothing — the procedure
    /// matches the row against the teacher the TOKEN resolves to — and becomes a
    /// 404, the same answer an id that never existed gets. A 403 would confirm
    /// it exists (2.6).
    /// </remarks>
    public async Task<MyApplicationDetailDto> GetMyApplicationAsync(
        ClaimsPrincipal caller, long applicationId, CancellationToken cancellationToken)
    {
        EnsureTeacher(caller);

        return await _applications
            .GetMyApplicationByIdAsync(caller.GetUserUid(), applicationId, cancellationToken)
            .ConfigureAwait(false)
            ?? throw new NotFoundException("That application was not found.");
    }

    /// <summary>
    /// Save or unsave a job.
    /// </summary>
    /// <remarks>
    /// 🔴 SAVING IS NOT APPLYING AND MUST NEVER UNLOCK CONTACT. The school is
    /// told nothing by this, and <c>fn_TeacherContactUnlocked</c> does not read
    /// <c>t_app_saved_jobs</c> (024). Saving is interest; applying is consent.
    /// </remarks>
    public async Task<ToggleSavedJobResultDto> ToggleSavedJobAsync(
        ClaimsPrincipal caller, long jobId, CancellationToken cancellationToken)
    {
        EnsureTeacher(caller);

        var teacher = await ResolveTeacherAsync(caller, cancellationToken).ConfigureAwait(false);

        var result = await _applications
            .ToggleSavedAsync(teacher.TeacherId, jobId, caller.GetUserId(), cancellationToken)
            .ConfigureAwait(false);

        result.EnsureSuccess();

        return new ToggleSavedJobResultDto { JobId = jobId, IsSaved = result.IsSaved == 1 };
    }

    public async Task<IReadOnlyList<SavedJobDto>> GetSavedJobsAsync(
        ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        EnsureTeacher(caller);

        return await _applications.GetMySavedJobsAsync(caller.GetUserUid(), cancellationToken)
            .ConfigureAwait(false);
    }

    public async Task<TeacherApplicationStatsDto> GetStatsAsync(
        ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        EnsureTeacher(caller);

        return await _applications.GetTeacherStatsAsync(caller.GetUserUid(), cancellationToken)
            .ConfigureAwait(false);
    }

    /// <summary>
    /// The teacher behind the token — the mirror of ResolveSchoolIdAsync.
    /// </summary>
    /// <remarks>
    /// ⚠️ A teacher account with no profile row, or a SUSPENDED one, resolves
    /// to nothing and is refused here with a message written for a teacher. The
    /// alternative — passing a null id down to the procedure — surfaces as a
    /// foreign-key violation, which is a 400 with nothing useful in it. The 3E
    /// lesson: the refusal was right and the reason was written for the wrong
    /// kind of user.
    /// </remarks>
    private async Task<TeacherIdentityRow> ResolveTeacherAsync(
        ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        return await _applications.ResolveTeacherAsync(caller.GetUserUid(), cancellationToken)
            .ConfigureAwait(false)
            ?? throw new ForbiddenException(
                "Your teacher profile is not available. Sign out and back in — if that does not help, contact us.");
    }

    /// <summary>
    /// The refusal codes, mapped to the statuses they deserve.
    /// </summary>
    /// <remarks>
    /// ⚠️ Each keeps its own Code so a screen can branch on it (2.12 / 2.21):
    /// RESUME_REQUIRED becomes a link to the resume section, JOB_EXPIRED becomes
    /// "applications have closed", NOT_FOUND becomes a 404, and APPLY_CONFLICT
    /// becomes a retry. Collapsing any two would make one of those screens
    /// wrong.
    /// </remarks>
    private static Exception ToRefusal(string? code, string message)
    {
        if (string.IsNullOrWhiteSpace(message))
        {
            message = "That application could not be submitted.";
        }

        return code switch
        {
            ErrorCodes.NotFound => new NotFoundException(message),

            // Retryable, and nothing about the person. 409 says so.
            ErrorCodes.ApplyConflict => new AppException(message, code, System.Net.HttpStatusCode.Conflict),

            _ => new BusinessRuleException(message, code ?? ErrorCodes.BusinessRuleViolated),
        };
    }

    /// <summary>
    /// Only a teacher applies.
    /// </summary>
    /// <remarks>
    /// ⚠️ Checked BEFORE anything else, so the refusal is honest. A school
    /// account reaching a teacher endpoint should be told it is not a teacher
    /// account — not told its profile is missing, which is the 3E bug in
    /// mirror image.
    /// </remarks>
    private static void EnsureTeacher(ClaimsPrincipal caller)
    {
        ArgumentNullException.ThrowIfNull(caller);

        if (caller.GetUserType() != UserType.Teacher)
        {
            throw new ForbiddenException("This is a teacher area. Your account is not a teacher account.");
        }
    }

    private static void Require(ClaimsPrincipal caller, string permission)
    {
        if (!caller.HasPermission(permission))
        {
            throw new ForbiddenException("You do not have permission to do that.");
        }
    }
}
