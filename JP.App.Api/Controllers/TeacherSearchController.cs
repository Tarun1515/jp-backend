using JP.Core.Common;
using JP.Domain.Invites;
using JP.Domain.Teachers;
using JP.Infrastructure.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace JP.App.Api.Controllers;

/// <summary>
/// 🔒 Teacher search and invitations — the school's side. Phase 6B.
/// </summary>
/// <remarks>
/// <para>
/// 🔒 NO ROUTE ON THIS CONTROLLER RETURNS A TEACHER'S CONTACT DETAILS, for any
/// plan, any flag, any role. Search is a browse surface over the whole teacher
/// base — almost nobody in a result has consented to anything — so a contact
/// field here would leak every teacher on the platform to any school that typed
/// a filter. Contact lives on <c>GET /api/teachers/{uid}/contact</c>, which
/// asks <c>fn_TeacherContactUnlocked</c> (2.56, LOCKED).
/// </para>
/// <para>
/// ⚠️ <see cref="TeacherSearchResultDto"/> and <see cref="SchoolInviteDto"/> are
/// both checked by <c>ContactLeakGuard</c> at startup: adding a contact-shaped
/// property to either takes the API down immediately, on the developer's own
/// machine.
/// </para>
/// <para>
/// 🔴 TWO FEATURES, TWO MODES. TEACHER_SEARCH is Boolean — included or not, and
/// nothing is written to the ledger. TEACHER_INVITE is metered, and the
/// invitation's own Uid is the reference, so a retry resolves to
/// ALREADY_CONSUMED rather than charging twice.
/// </para>
/// <para>
/// 🔴 NO SchoolId ANYWHERE. Resolved from the token's OrganizationUid (2.39).
/// </para>
/// </remarks>
[ApiController]
[Route("api/teacher-search")]
[Authorize]
[Produces("application/json")]
public sealed class TeacherSearchController : ControllerBase
{
    private readonly IInviteService _invites;

    public TeacherSearchController(IInviteService invites)
    {
        _invites = invites;
    }

    /// <summary>
    /// Find teachers. Requires TEACHER_SEARCH.VIEW and the TEACHER_SEARCH feature.
    /// </summary>
    /// <remarks>
    /// <para>
    /// 🔴 PAGED AND FILTERED ON THE SERVER, from the first commit. This is the
    /// one place in the product where volume is real — a school searches the
    /// whole platform — and "fetch everything, filter in the browser" would
    /// ship the entire teacher base to a laptop to render twenty rows. G29
    /// recorded the opposite trade-off on the applicant list and said exactly
    /// where it would stop applying.
    /// </para>
    /// <para>
    /// ⚠️ Experience is an <c>experienceRangeId</c> from
    /// <c>m_mdm_experience_range</c>, not a pair of month numbers — the
    /// boundaries are the client's to change without a deployment (2.7).
    /// </para>
    /// <para>
    /// ⚠️ Suspended teachers are excluded server-side. An administrative
    /// decision has to reach the listing or it is cosmetic.
    /// </para>
    /// </remarks>
    [HttpGet]
    [ProducesResponseType(typeof(Response<IReadOnlyList<TeacherSearchResultDto>>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> Search(
        [FromQuery] TeacherSearchFilter filter, CancellationToken cancellationToken)
    {
        var (rows, total) = await _invites.SearchAsync(User, filter, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Paged(rows, total));
    }

    /// <summary>
    /// Invite a teacher. Requires TEACHER_SEARCH.INVITE, and costs one
    /// TEACHER_INVITE.
    /// </summary>
    /// <remarks>
    /// <para>
    /// 🔒 SENDING THIS UNLOCKS NOTHING. The teacher's contact details open only
    /// when they ACCEPT — which is consent path 2, the second and last one
    /// (2.56, LOCKED). A school may invite every teacher on the platform and
    /// learn nothing about any of them.
    /// </para>
    /// <para>
    /// ⚠️ <c>jobId</c> is optional, and its absence is the point of the feature:
    /// a school may invite somebody without having posted a job. With one, the
    /// teacher gets a third option — apply to that job instead — and the
    /// invitation then records APPLIED while the unlock comes from the
    /// application (path 1).
    /// </para>
    /// <para>
    /// ⚠️ <c>ALREADY_INVITED</c> comes back on a 200 with <c>created: false</c>
    /// and <c>consumed: false</c>. The insert runs before the meter, so a
    /// double-click costs nothing.
    /// </para>
    /// </remarks>
    [HttpPost("invites")]
    [ProducesResponseType(typeof(Response<SendInviteResultDto>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> SendInvite(
        [FromBody] SendInviteRequest request, CancellationToken cancellationToken)
    {
        var result = await _invites.SendAsync(User, request, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success(result));
    }

    /// <summary>
    /// The school's own outbox. Requires TEACHER_SEARCH.VIEW.
    /// </summary>
    /// <remarks>
    /// 🔴 NO ENTITLEMENT CHECK, deliberately. A school whose plan stopped
    /// including search must still see the invitations it already sent — using
    /// entitlement to erase a school's own record is not what a plan sells.
    /// </remarks>
    [HttpGet("invites")]
    [ProducesResponseType(typeof(Response<IReadOnlyList<SchoolInviteDto>>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> GetInvites(
        [FromQuery] int? inviteStatusId, CancellationToken cancellationToken)
    {
        var invites = await _invites.GetForSchoolAsync(User, inviteStatusId, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success(invites));
    }
}

/// <summary>
/// 🔒 Invitations — the teacher's side, and consent path 2. Phase 6B.
/// </summary>
/// <remarks>
/// <para>
/// 🔒 ACCEPTING IS THE SECOND AND FINAL CONSENT PATH (2.56, LOCKED). One
/// UPDATE, and this school — and only this school — can see the teacher's
/// contact details.
/// </para>
/// <para>
/// ⚠️ Viewing unlocks nothing. Ignoring unlocks nothing. The school's payment
/// status unlocks nothing, ever.
/// </para>
/// </remarks>
[ApiController]
[Route("api/teacher/invites")]
[Authorize]
[Produces("application/json")]
public sealed class TeacherInvitesController : ControllerBase
{
    private readonly IInviteService _invites;

    public TeacherInvitesController(IInviteService invites)
    {
        _invites = invites;
    }

    /// <summary>The teacher's inbox. <paramref name="openOnly"/> keeps the unanswered ones.</summary>
    [HttpGet]
    [ProducesResponseType(typeof(Response<IReadOnlyList<MyInviteDto>>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> GetMine(
        [FromQuery] bool openOnly, CancellationToken cancellationToken)
    {
        var invites = await _invites.GetMineAsync(User, openOnly, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success(invites));
    }

    /// <summary>
    /// Mark an invitation as opened.
    /// </summary>
    /// <remarks>
    /// 🔒 UNLOCKS NOTHING — reading a message is not answering it, and that
    /// difference is why <c>fn_TeacherContactUnlocked</c> names one status and
    /// not two. Idempotent: only an invitation still at Sent moves (2.48).
    /// </remarks>
    [HttpPost("{inviteId:long}/viewed")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> MarkViewed(long inviteId, CancellationToken cancellationToken)
    {
        await _invites.MarkViewedAsync(User, inviteId, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success("Seen."));
    }

    /// <summary>
    /// 🔒 Accept or pass. ACCEPTING IS CONSENT PATH 2.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Accepting opens this teacher's contact details to that school and to no
    /// other. Passing records an explicit no, which a school can see — so it
    /// stops following up — and which unlocks nothing, forever.
    /// </para>
    /// <para>
    /// ⚠️ Another teacher's invitation id answers 404, never "not yours" (2.6).
    /// </para>
    /// </remarks>
    [HttpPost("{inviteId:long}/respond")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> Respond(
        long inviteId, [FromBody] RespondToInviteRequest request, CancellationToken cancellationToken)
    {
        await _invites.RespondAsync(User, inviteId, request, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success(request?.Accept == true ? "Invitation accepted." : "Invitation declined."));
    }
}
