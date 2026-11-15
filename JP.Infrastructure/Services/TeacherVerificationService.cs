using System.Security.Claims;
using JP.Core.Constants;
using JP.Core.Exceptions;
using JP.Core.Extensions;
using JP.Domain.Approvals;
using JP.Domain.Teachers;
using JP.Infrastructure.Repositories;
using Microsoft.Extensions.Logging;

namespace JP.Infrastructure.Services;

/// <summary>
/// A teacher asking to be verified.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 WHY THIS CLASS EXISTS — THE TEACHER COULD NOT ASK.
/// </para>
/// <para>
/// Measured 15 Nov 2026: calls to <c>approvals/submit</c> across all three
/// authenticated apps came to ZERO, and nothing in the product ever created a
/// <c>TEACHER_VERIFY</c> approval request. The type-2 rows in the admin queue
/// were seed rows. Everything downstream was built and reachable only by hand —
/// <c>USP_SetTeacherVerified</c> stamps the badge, the queue renders the
/// documents, the orchestration outcome has its own branch for this case — with
/// no way in. The teacher uploaded documents to their profile, a "needed" chip
/// was drawn beside the mandatory ones, and there it stopped.
/// </para>
/// <para>
/// ⚠️ THE ORCHESTRATION IS HERE BECAUSE IT HAS TO BE (2.2, 2.48). The two halves
/// of the rule live in different databases: which documents are mandatory is
/// <c>jp_mdm.m_mdm_document_types</c>, which documents this teacher has is
/// <c>jp_app.t_app_teacher_documents</c>, and the request itself is written to
/// <c>jp_mdm.t_mdm_approval_requests</c>. jp_app reads jp_mdm masters in five
/// procedures; searching jp_mdm for a jp_app three-part name returns ZERO, and
/// jp_app writes into jp_mdm in ZERO places. Keeping both numbers at zero is
/// worth more than putting this method in a procedure, and 2.2 already says
/// cross-database work belongs in this layer rather than in MSDTC.
/// </para>
/// <para>
/// 🔒 NO AADHAAR OR PAN NUMBER PASSES THROUGH HERE, OR ANYWHERE (2.50). The
/// readiness row carries a document type's NAME and a count. Nothing reads,
/// parses, derives, logs or stores either number, and no table has a column that
/// could hold one. The document is the record; an admin's eyes verify it.
/// </para>
/// <para>
/// ⚠️ VERIFICATION IS NOT A GATE (2.9). Being unverified costs a teacher
/// nothing: the account is Active from signup, the profile is searchable, and
/// applying works. This asks for a badge — which is why refusing for a missing
/// document is safe here. Nobody is locked out of the product, only out of the
/// badge.
/// </para>
/// </remarks>
public interface ITeacherVerificationService
{
    /// <summary>
    /// Submits this teacher's verification request, or refuses naming the one
    /// document that is missing.
    /// </summary>
    Task<SubmitApprovalResponse> RequestAsync(
        ClaimsPrincipal caller, string? ipAddress, CancellationToken cancellationToken);

    /// <summary>
    /// What the profile screen needs to decide whether to offer the button, and
    /// what to say when it cannot.
    /// </summary>
    Task<TeacherVerificationReadinessDto> GetReadinessAsync(
        ClaimsPrincipal caller, CancellationToken cancellationToken);
}

internal sealed class TeacherVerificationService : ITeacherVerificationService
{
    /// <summary>TEACHER_VERIFY — m_mdm_request_types.RequestTypeId (2.47).</summary>
    private const int RequestTypeTeacherVerification = 2;

    private readonly ITeacherRepository _teachers;
    private readonly IApprovalService _approvals;
    private readonly ILogger<TeacherVerificationService> _logger;

    public TeacherVerificationService(
        ITeacherRepository teachers,
        IApprovalService approvals,
        ILogger<TeacherVerificationService> logger)
    {
        _teachers = teachers;
        _approvals = approvals;
        _logger = logger;
    }

    public async Task<TeacherVerificationReadinessDto> GetReadinessAsync(
        ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        var row = await ReadAsync(caller, cancellationToken).ConfigureAwait(false);

        return new TeacherVerificationReadinessDto
        {
            IsVerified = row.IsVerified,
            DocumentCount = row.DocumentCount,
            MissingDocument = row.MissingDocument,
            CanRequest = !row.IsVerified && row.MissingDocument is null,
        };
    }

    public async Task<SubmitApprovalResponse> RequestAsync(
        ClaimsPrincipal caller, string? ipAddress, CancellationToken cancellationToken)
    {
        var row = await ReadAsync(caller, cancellationToken).ConfigureAwait(false);

        /*
          ⚠️ ALREADY VERIFIED IS REFUSED, NOT SILENTLY ACCEPTED.

          Letting it through would put a second request in the admin queue for a
          badge that is already granted, and USP_SetTeacherVerified is guarded
          on IsVerified = 0 — so approving it would report success and change
          nothing. A queue row whose approval does nothing is worse than a
          refusal that explains itself.
        */
        if (row.IsVerified)
        {
            throw new BusinessRuleException(
                "Your profile is already verified.", ErrorCodes.AlreadyVerified);
        }

        /*
          🔴 THE REFUSAL, NAMING THE DOCUMENT (2.21).

          The list comes from jp_mdm.dbo.fn_MandatoryDocumentTypes — the one
          definition of "mandatory" in the system, shared with the school side's
          USP_SubmitRegistrationDraft. When the client corrects IsMandatory
          (CLIENT_ASKS 1.4), this refusal changes with it and this file is not
          touched.

          ⚠️ IT NAMES THE DOCUMENT RATHER THAN COUNTING. "We still need your
          Aadhaar card" is a sentence somebody can act on without re-reading a
          list of five upload slots looking for an empty one.
        */
        if (row.MissingDocument is { } missing)
        {
            throw new BusinessRuleException(
                $"We still need your {missing}. Upload it on your profile and ask again.",
                ErrorCodes.DocumentRequired);
        }

        /*
          ⚠️ SubmitTeacherVerificationAsync, NOT SubmitAsync.

          🔴 The generic SubmitAsync now REFUSES request type 2, because leaving
          it open would be a second door past the check above: same teacher
          token, type 2, no documents, accepted. The rule cannot move into
          USP_SubmitApprovalRequest — the documents are in jp_app and jp_mdm
          must not read jp_app — so it lives here, and the generic entry point
          is closed rather than left as a bypass of it.

          ⚠️ The teacher uid comes from the row this method already read, never
          from a payload. "The thing being approved" (025), and the uid
          USP_SetTeacherVerified resolves the teacher by when the badge is
          stamped. The endpoint takes no body at all, so there is nothing to
          substitute.

          ⚠️ IDEMPOTENCY IS NOT REIMPLEMENTED HERE. USP_SubmitApprovalRequest
          returns an existing Pending request as ALREADY_PENDING rather than
          creating a second, and ApprovalService surfaces that as
          AlreadyPending = true. A double-tapped button is not an error.
        */
        var response = await _approvals
            .SubmitTeacherVerificationAsync(
                row.TeacherUid, row.FullName, caller, ipAddress, cancellationToken)
            .ConfigureAwait(false);

        _logger.LogInformation(
            "Teacher verification requested for {TeacherUid}: {RequestNo} " +
            "(alreadyPending={AlreadyPending}, documents={DocumentCount})",
            row.TeacherUid, response.RequestNo, response.AlreadyPending, row.DocumentCount);

        return response;
    }

    /*
      The procedure returns NO ROWS when the uid is not a teacher's. That is a
      404 and it is this layer's to raise — an admin or a school owner calling a
      teacher endpoint is not a teacher with a problem, it is the wrong caller.
    */
    private async Task<TeacherVerificationReadinessRow> ReadAsync(
        ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(caller);

        var row = await _teachers
            .GetVerificationReadinessAsync(caller.GetUserUid(), cancellationToken)
            .ConfigureAwait(false);

        return row ?? throw new NotFoundException("That teacher profile was not found.");
    }
}
