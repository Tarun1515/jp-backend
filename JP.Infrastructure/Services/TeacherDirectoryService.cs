using System.Security.Claims;
using JP.Core.Enums;
using JP.Core.Exceptions;
using JP.Core.Extensions;
using JP.Domain.Teachers;
using JP.Infrastructure.Repositories;
using Microsoft.Extensions.Logging;

namespace JP.Infrastructure.Services;

public interface ITeacherDirectoryService
{
    Task<TeacherBrowseDto> BrowseAsync(Guid teacherUid, ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task<TeacherContactDto> GetContactAsync(Guid teacherUid, ClaimsPrincipal caller, CancellationToken cancellationToken);
}

/// <summary>
/// What a school can see of a teacher.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 THIS CLASS IS THE SECURITY SURFACE OF PHASE 3E.
/// </para>
/// <para>
/// Two methods, two procedures, two DTOs, and NO path between them. The browse
/// DTO has no contact properties to be populated with; the contact procedure's
/// result is never mapped into it. That separation is not defensive style — it
/// is the whole reason Phase 3D wrote two procedures rather than one with a
/// flag (2.54), and it only survives if this layer keeps them apart too.
/// </para>
/// <para>
/// If you find yourself wanting a single method that returns "the profile, with
/// contact if allowed", stop: that is the shape that leaks. The caller asks for
/// what it is entitled to, and finds out separately whether it may have more.
/// </para>
/// </remarks>
internal sealed class TeacherDirectoryService : ITeacherDirectoryService
{
    private readonly ITeacherRepository _teachers;
    private readonly ISchoolProfileService _schools;
    private readonly ILogger<TeacherDirectoryService> _logger;

    public TeacherDirectoryService(
        ITeacherRepository teachers,
        ISchoolProfileService schools,
        ILogger<TeacherDirectoryService> logger)
    {
        _teachers = teachers;
        _schools = schools;
        _logger = logger;
    }

    /// <summary>
    /// The browse view: everything a school needs to decide, and no way to make
    /// contact off-platform.
    /// </summary>
    /// <remarks>
    /// ⚠️ Maps <c>USP_GetTeacherPublicProfile</c> into
    /// <see cref="TeacherBrowseDto"/>, and nothing else ever does. A suspended
    /// or deleted teacher comes back null and becomes a 404 — not a 403, because
    /// confirming that a profile exists but is hidden is itself a disclosure.
    /// </remarks>
    public async Task<TeacherBrowseDto> BrowseAsync(
        Guid teacherUid, ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(caller);

        EnsureSchool(caller);

        return await _teachers.GetBrowseProfileAsync(teacherUid, cancellationToken).ConfigureAwait(false)
               ?? throw new NotFoundException("That teacher was not found.");
    }

    /// <summary>
    /// Contact details, when the teacher has consented.
    /// </summary>
    /// <remarks>
    /// <para>
    /// 🔴 The gate is <c>fn_TeacherContactUnlocked</c>, which is true only when
    /// the teacher APPLIED to this school or ACCEPTED its invite (2.56, LOCKED).
    /// It returns 0 for everybody today because neither table exists yet, and
    /// that is the correct answer rather than a placeholder.
    /// </para>
    /// <para>
    /// 🔴 The viewing school comes from the CALLER'S OWN MEMBERSHIP, never from
    /// the request. A school naming another school's id would otherwise unlock
    /// everything that school had earned.
    /// </para>
    /// <para>
    /// ⚠️ A refusal is a 403 carrying the procedure's own message, not a bare
    /// status. A school needs to know the path exists — invite them, and they
    /// may reply — rather than only that the door is shut.
    /// </para>
    /// </remarks>
    public async Task<TeacherContactDto> GetContactAsync(
        Guid teacherUid, ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(caller);

        EnsureSchool(caller);

        var viewerSchoolId = await _schools.ResolveSchoolIdAsync(caller, cancellationToken).ConfigureAwait(false);

        var row = await _teachers.GetContactAsync(teacherUid, viewerSchoolId, cancellationToken)
            .ConfigureAwait(false);

        if (row.Status != 1)
        {
            if (string.Equals(row.Code, "NOT_FOUND", StringComparison.Ordinal))
            {
                throw new NotFoundException(row.Message);
            }

            _logger.LogInformation(
                "School {SchoolId} asked for teacher {TeacherUid}'s contact details and is not unlocked ({Code}).",
                viewerSchoolId, teacherUid, row.Code);

            /*
              🔴 403 with the reason, not a bare refusal.

              The message is the procedure's own (2.56): it tells the school what
              WOULD unlock this — the teacher applying, or accepting an invite —
              and points at the invite as the thing they can actually do. A
              refusal that only says "no" gets read as a bug or a paywall, and
              this is neither.
            */
            throw new ForbiddenException(row.Message);
        }

        return new TeacherContactDto
        {
            TeacherUid = teacherUid,
            FullName = string.Empty,
            ContactEmail = row.ContactEmail,
            ContactMobile = row.ContactMobile,
            ResumePath = row.ResumePath,
        };
    }

    /// <summary>
    /// Only a school browses the teacher directory.
    /// </summary>
    /// <remarks>
    /// ⚠️ An admin is deliberately NOT allowed through here. An administrator
    /// looking at a teacher does it from the verification queue, where the
    /// action is recorded — this endpoint has no audit trail and is not the
    /// place to grant a back door to every profile in the system.
    /// </remarks>
    private static void EnsureSchool(ClaimsPrincipal caller)
    {
        if (caller.GetUserType() != UserType.School)
        {
            throw new ForbiddenException("Only a school can browse teacher profiles.");
        }
    }
}
