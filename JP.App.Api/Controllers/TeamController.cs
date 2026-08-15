using JP.Core.Common;
using JP.Core.Exceptions;
using JP.Core.Extensions;
using JP.Domain.Schools;
using JP.Infrastructure.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace JP.App.Api.Controllers;

/// <summary>
/// A school's own team: who is on it, what they may do, and which campuses they
/// can see.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 NO ENDPOINT HERE TAKES A SCHOOL ID. The school comes from the caller's
/// membership, resolved in the service (2.39, 2.57). The route parameter is the
/// TARGET's UserUid, and the procedures resolve that through the caller's own
/// school — so naming another school's colleague returns 404, not 403.
/// </para>
/// <para>
/// ⚠️ USER.MANAGE IS REQUIRED ON ALL FOUR WRITES, INCLUDING CAMPUS SCOPE AND
/// REMOVAL. The phase brief attached it only to the invite and the role change;
/// this controller applies it to every write, because deciding which campuses a
/// colleague can see IS a permission change — it is the difference between an HR
/// who can read one campus's applicants and one who can read all of them.
/// Removing somebody's access is plainly one too.
/// </para>
/// <para>
/// Reading the team needs no permission beyond membership. Who your colleagues
/// are is not a secret from them.
/// </para>
/// </remarks>
[ApiController]
[Route("api/school/team")]
[Authorize]
public sealed class TeamController : ControllerBase
{
    private readonly ISchoolTeamService _team;

    public TeamController(ISchoolTeamService team)
    {
        _team = team;
    }

    private string? ClientIp => HttpContext.Connection.RemoteIpAddress?.ToString();

    private string? ClientUserAgent =>
        Request.Headers.UserAgent.ToString() is { Length: > 0 } ua ? ua[..Math.Min(ua.Length, 400)] : null;

    /// <summary>Everyone on this school's team, with their role and campus scope.</summary>
    /// <remarks>
    /// The campuses in the response are the CALLER's visible set, and so are the
    /// campus ids on each member. <c>BranchCount</c> is the true total, which is
    /// how the screen can say "1 campus, and 2 more you cannot see" rather than
    /// under-reporting a colleague's access.
    /// </remarks>
    [HttpGet]
    [ProducesResponseType(typeof(Response<SchoolTeamDto>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> GetTeam(CancellationToken cancellationToken)
    {
        var team = await _team.GetTeamAsync(User, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success(team));
    }

    /// <summary>
    /// Invites a colleague onto the team.
    /// </summary>
    /// <remarks>
    /// <para>
    /// 🔴 TWO DATABASES, NO DISTRIBUTED TRANSACTION (2.2, 2.48). The account is
    /// created in jp_sso and the membership in jp_app. If the second fails, the
    /// response says so and says what to do — sending the invitation again
    /// attaches the account that already exists rather than making a second one.
    /// </para>
    /// <para>
    /// ⚠️ Re-inviting somebody who is already on the team is not an error. The
    /// response comes back with <c>alreadyOnTeam</c> and nothing is changed —
    /// in particular their role is NOT overwritten, because an invite must not
    /// be a way around the role endpoint and its owner guard.
    /// </para>
    /// </remarks>
    [HttpPost("invite")]
    [ProducesResponseType(typeof(Response<InviteTeamMemberResponse>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> Invite(
        [FromBody] InviteTeamMemberRequest request, CancellationToken cancellationToken)
    {
        RequirePermission("USER.MANAGE");

        var result = await _team
            .InviteAsync(request, User, ClientIp, ClientUserAgent, cancellationToken)
            .ConfigureAwait(false);

        var message = result switch
        {
            { AlreadyOnTeam: true } => "That person is already on your team — nothing was changed.",

            // No second email goes out on this path: only the hash of the first
            // invite token was stored, so it cannot be reissued.
            { ExistingAccountAttached: true } =>
                "That account already existed and is now on your team. If they never received the original " +
                "invitation, they can set a password with 'forgot password'.",

            _ => "Invitation sent.",
        };

        return Ok(ApiResponse.Success(result, message));
    }

    /// <summary>
    /// Changes what somebody is to this school, and what they are called on it.
    /// </summary>
    /// <remarks>
    /// 🔴 The owner cannot be demoted and nobody can be promoted into the role —
    /// both refused by the procedure with their own message (400). The owner's
    /// NAME can still be edited, which matters because provisioning never
    /// recorded one.
    /// </remarks>
    [HttpPut("{uid:guid}/role")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> SaveRole(
        Guid uid, [FromBody] SaveTeamMemberRoleRequest request, CancellationToken cancellationToken)
    {
        RequirePermission("USER.MANAGE");

        await _team.SaveRoleAsync(uid, request, User, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success("Saved."));
    }

    /// <summary>
    /// 🔴 SEND THE COMPLETE SET OF CAMPUSES, NOT JUST THE NEW ONE.
    /// </summary>
    /// <remarks>
    /// <para>
    /// A full-set sync, like every other bridge in this API (2.53). Sending
    /// <c>[3]</c> when they already have <c>[1, 3]</c> REMOVES campus 1.
    /// </para>
    /// <para>
    /// ⚠️ With one exception, and it is there to prevent a silent revocation:
    /// campuses the CALLER cannot see are never removed, whatever this list
    /// says. Otherwise a branch HR — who can only ever be shown their own
    /// campuses — would strip a colleague of every campus they had not been
    /// shown, and it would look like a successful save.
    /// </para>
    /// <para>
    /// The owner is refused outright: they see every campus by definition and
    /// are never enumerated against one (rule 3).
    /// </para>
    /// </remarks>
    [HttpPut("{uid:guid}/branches")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> SaveBranches(
        Guid uid, [FromBody] SaveTeamMemberBranchesRequest request, CancellationToken cancellationToken)
    {
        RequirePermission("USER.MANAGE");

        await _team.SaveBranchesAsync(uid, request, User, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success("Campus access saved."));
    }

    /// <summary>
    /// Removes somebody's access. Soft — the record of what they did stays.
    /// </summary>
    /// <remarks>
    /// <para>
    /// ⚠️ DELETE is the verb; deletion is not what happens. The membership is
    /// marked inactive, which closes every school screen for them immediately,
    /// and their sessions are revoked. The row, their campus links and every
    /// "verified by" and "posted by" they left behind are untouched — an HR
    /// leaving a school does not un-verify the documents they checked.
    /// </para>
    /// <para>
    /// 🔴 The owner cannot be removed, and nobody can remove themselves. Both
    /// refused by the procedure with their own message.
    /// </para>
    /// <para>
    /// Re-inviting them is the undo, and it restores the campuses they had.
    /// </para>
    /// </remarks>
    [HttpDelete("{uid:guid}")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> Deactivate(Guid uid, CancellationToken cancellationToken)
    {
        RequirePermission("USER.MANAGE");

        await _team.DeactivateAsync(uid, User, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success("Access removed."));
    }

    /// <summary>Refuses the request unless the caller holds the permission.</summary>
    /// <remarks>
    /// ForbiddenException carries the FORBIDDEN code through the global handler,
    /// so a client handles it like every other refusal.
    /// </remarks>
    private void RequirePermission(string permissionCode)
    {
        if (!User.HasPermission(permissionCode))
        {
            throw new ForbiddenException(
                "You do not have permission to manage this school's team.");
        }
    }
}
