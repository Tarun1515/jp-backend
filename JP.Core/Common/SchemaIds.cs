using System.Reflection;

namespace JP.Core.Common;

/// <summary>
/// Namespace-qualified OpenAPI schema ids.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 THIS EXISTS BECAUSE A DUPLICATE SHORT NAME TOOK THE WHOLE DOCUMENT DOWN.
/// </para>
/// <para>
/// Swashbuckle keys every schema on the short type name by default. Two DTOs
/// called <c>PlanSummaryDto</c> — one for the school dashboard (Phase 3I), one
/// for the admin plan matrix (Phase 2.5) — collided, and
/// <c>/swagger/v1/swagger.json</c> answered 500 for EVERY endpoint, not just
/// the one that tripped it.
/// </para>
/// <para>
/// Renaming one of them would have fixed that collision and left the next one
/// waiting: nothing prevents two features from choosing the same DTO name
/// again, and the failure is total rather than local.
/// </para>
/// <para>
/// ⚠️ THE TRADE, STATED: schema ids get long —
/// <c>DomainEntitlementsPlanSummaryDto</c> rather than <c>PlanSummaryDto</c>.
/// That is deliberate. The full namespace is what makes a collision
/// impossible: two types can only clash now if they share a namespace AND a
/// name, which the compiler already forbids. Shortening it — the last segment
/// only, say — would restore the possibility quietly, which is the one outcome
/// worth avoiding.
/// </para>
/// <para>
/// It changes schema NAMES in the document, never the JSON on the wire:
/// property names are untouched, and nothing generates a client from this yet.
/// </para>
/// </remarks>
public static class SchemaIds
{
    /// <summary>The schema id for a type, qualified by its namespace.</summary>
    public static string ForType(Type type)
    {
        ArgumentNullException.ThrowIfNull(type);

        if (!type.IsGenericType)
        {
            return Qualify(type) + type.Name;
        }

        /*
          Generics need their arguments folded in, or every closed form of
          Response<T> would claim the same id and we would be back where we
          started — with a subtler version of the same bug.

          Response<EntitlementMatrixDto> -> CoreCommonResponseOfDomainEntitlementsEntitlementMatrixDto
        */
        var tick = type.Name.IndexOf('`', StringComparison.Ordinal);
        var bare = tick < 0 ? type.Name : type.Name[..tick];
        var args = string.Concat(type.GetGenericArguments().Select(ForType));

        return $"{Qualify(type)}{bare}Of{args}";
    }

    /// <summary>
    /// The namespace as a prefix: dots removed, the shared "JP." dropped.
    /// </summary>
    /// <remarks>
    /// Only "JP." is stripped, and only because every type in this solution
    /// carries it — a prefix present on all of them distinguishes none of them.
    /// Nothing else is trimmed: each remaining segment is doing real work.
    /// </remarks>
    private static string Qualify(Type type)
    {
        var ns = type.Namespace ?? string.Empty;

        if (ns.StartsWith("JP.", StringComparison.Ordinal))
        {
            ns = ns[3..];
        }

        return ns.Replace(".", string.Empty, StringComparison.Ordinal);
    }
}
