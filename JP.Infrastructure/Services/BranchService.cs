using System.Security.Claims;
using JP.Core.Exceptions;
using JP.Core.Extensions;
using JP.Domain.Schools;
using JP.Infrastructure.Repositories;

namespace JP.Infrastructure.Services;

public interface IBranchService
{
    Task<IReadOnlyList<BranchDto>> ListAsync(string? search, int? stateId, bool includeInactive, ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task<BranchDto> GetByIdAsync(long branchId, ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task<SaveBranchResponse> SaveAsync(long? branchId, SaveBranchRequest request, ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task DeleteAsync(long branchId, DeleteBranchRequest request, ClaimsPrincipal caller, CancellationToken cancellationToken);
}

/// <summary>
/// Branches, scope-resolved by the database.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 A BRANCH OUTSIDE THE CALLER'S SCOPE IS A 404, NOT A 403.
/// </para>
/// <para>
/// <c>dbo.fn_VisibleBranches</c> returns nothing for it, so the procedure
/// returns nothing, so this throws <see cref="NotFoundException"/>. That is
/// deliberate and matches the document download (decision 2.48): confirming a
/// branch exists but belongs to another school is itself a disclosure, and a
/// 403 confirms it.
/// </para>
/// <para>
/// ⚠️ This service does NOT re-check scope. One gate, in the database (2.53).
/// A second check here would be a second rule to keep in step, and the day they
/// disagree one of them is wrong.
/// </para>
/// </remarks>
internal sealed class BranchService : IBranchService
{
    private readonly IBranchRepository _branches;
    private readonly ISchoolProfileService _schools;

    public BranchService(IBranchRepository branches, ISchoolProfileService schools)
    {
        _branches = branches;
        _schools = schools;
    }

    public async Task<IReadOnlyList<BranchDto>> ListAsync(
        string? search, int? stateId, bool includeInactive,
        ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        var schoolId = await _schools.ResolveSchoolIdAsync(caller, cancellationToken).ConfigureAwait(false);

        return await _branches
            .ListAsync(schoolId, caller.GetUserUid(), search, stateId, includeInactive, cancellationToken)
            .ConfigureAwait(false);
    }

    public async Task<BranchDto> GetByIdAsync(
        long branchId, ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(caller);

        /*
          🔴 No school resolution needed, and none done. The procedure looks the
          branch's own school up and then gates it through fn_VisibleBranches
          against this caller — so a branch id from another school resolves to
          nothing without this layer ever learning that it exists.
        */
        return await _branches.GetByIdAsync(branchId, caller.GetUserUid(), cancellationToken)
                   .ConfigureAwait(false)
               ?? throw new NotFoundException("That campus was not found.");
    }

    public async Task<SaveBranchResponse> SaveAsync(
        long? branchId, SaveBranchRequest request, ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        var schoolId = await _schools.ResolveSchoolIdAsync(caller, cancellationToken).ConfigureAwait(false);

        var result = await _branches
            .SaveAsync(schoolId, caller.GetUserUid(), branchId, request, caller.GetUserId(), cancellationToken)
            .ConfigureAwait(false);

        result.EnsureSuccess();

        return new SaveBranchResponse
        {
            BranchId = result.Id ?? 0,
            BranchUid = result.BranchUid ?? Guid.Empty,
            Message = result.Message,
        };
    }

    public async Task DeleteAsync(
        long branchId, DeleteBranchRequest request, ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        var schoolId = await _schools.ResolveSchoolIdAsync(caller, cancellationToken).ConfigureAwait(false);

        /*
          The procedure refuses a head office and a stale RowVersion with their
          own codes and their own messages (2.53), and EnsureSuccess turns each
          into the right status — BUSINESS_RULE_VIOLATED to 400,
          CONCURRENCY_CONFLICT to 409, NOT_FOUND to 404.

          ⚠️ The "has jobs or applications" refusal is written into the
          procedure and currently unreachable; Phase 4 makes it live. Nothing
          here needs to change when it does.
        */
        var result = await _branches
            .DeleteAsync(branchId, schoolId, caller.GetUserUid(), request.RowVersion, caller.GetUserId(), cancellationToken)
            .ConfigureAwait(false);

        result.EnsureSuccess();
    }
}
