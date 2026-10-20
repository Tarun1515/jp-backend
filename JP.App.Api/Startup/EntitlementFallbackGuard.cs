using System.Reflection;

namespace JP.App.Api.Startup;

/// <summary>
/// Refuses to start if a consuming path can reach the entitlement core without
/// carrying the free-plan fallback. G38.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 THE GUARD THAT EXISTS BECAUSE THE COMMENTS DID NOT HOLD.
/// </para>
/// <para>
/// 6.5-C removed a cliff: a subscription past <c>EndsOn</c> drops to the
/// default plan's entitlements instead of being refused. It works by carrying
/// a FALLBACK plan and its mapping into <c>USP_ConsumeFeatureCore</c>, resolved
/// in the same query as the primary mapping so the two cannot disagree.
/// </para>
/// <para>
/// G38 recorded the risk that "some future procedure or service might forget
/// the fallback". Phase 8-0 went looking and found that two shipped procedures
/// already had — <c>USP_PublishJob</c> and <c>USP_SendInvite</c>, which are the
/// only two consuming actions in the product (2.64). Measured on a lapsed owner
/// and a FREE feature: <c>Status 0 SUBSCRIPTION_INACTIVE</c> without the
/// fallback, <c>Status 1</c> with it. A school whose paid plan had lapsed could
/// not publish a job even though publishing costs nothing, while a school that
/// had never paid could.
/// </para>
/// <para>
/// ⚠️ SO THE SHAPE, NOT THE INTENTION, IS WHAT IS CHECKED HERE. Three
/// invariants, each of which was false somewhere before 8-0:
/// </para>
/// <list type="number">
/// <item>
/// The service's public <c>ConsumeAsync</c> has NO fallback parameter, so no
/// caller can pass null for one. The fallback is resolved inside, from the
/// resolution read. A caller cannot forget what it cannot say.
/// </item>
/// <item>
/// The ledger repository's <c>ConsumeAsync</c> HAS the fallback parameters and
/// none of them is optional. A default here is what made the omission silent
/// in SQL, and it would do the same in C#.
/// </item>
/// <item>
/// The two consuming repositories — publish and invite — have a
/// <c>fallbackPlanId</c> parameter, and it is not optional either. These are
/// the exact two methods that were missing it.
/// </item>
/// </list>
/// <para>
/// 🔴 A SUBJECT THAT CANNOT BE FOUND IS A FAILURE, NOT A PASS. If a method is
/// renamed, this guard says so and stops the API rather than quietly checking
/// nothing — which is the failure mode of every string-based check that treats
/// "not found" as "fine".
/// </para>
/// <para>
/// The complementary check is in SQL, at the foot of
/// <c>013_entitlement.sql</c>: every procedure that references the core must
/// declare <c>@FallbackPlanId</c> itself. That one catches a new procedure;
/// this one catches a new service or repository method.
/// </para>
/// </remarks>
internal static class EntitlementFallbackGuard
{
    private const string Fallback = "fallback";

    /// <summary>Throws if any consuming path can omit the fallback.</summary>
    /// <exception cref="InvalidOperationException">
    /// A shape that would re-open the 6.5-C cliff. The message names the
    /// method and what is wrong with it.
    /// </exception>
    public static void Verify()
    {
        var infrastructure = typeof(JP.Infrastructure.DependencyInjection).Assembly;
        var problems = new List<string>();

        // ---- 1. the service's public surface cannot express "no fallback" ---
        var service = Find(infrastructure, "JP.Infrastructure.Services.IEntitlementService", problems);
        var consume = Method(service, "ConsumeAsync", problems);

        if (consume is not null
            && consume.GetParameters().Any(p => Mentions(p.Name)))
        {
            problems.Add(
                "IEntitlementService.ConsumeAsync takes a fallback parameter. It must not: the fallback is "
                + "resolved inside the service from the same read as the primary mapping, so no caller can "
                + "forget it. A parameter here is a parameter somebody will pass null for.");
        }

        // ---- 2. the ledger repository's fallback arguments are mandatory ----
        var ledger = Find(infrastructure, "JP.Infrastructure.Repositories.IEntitlementLedgerRepository", problems);
        Require(Method(ledger, "ConsumeAsync", problems), "IEntitlementLedgerRepository.ConsumeAsync", problems);

        // ---- 3. and so are the two consuming paths G38 found broken --------
        var jobs = Find(infrastructure, "JP.Infrastructure.Repositories.IJobRepository", problems);
        Require(Method(jobs, "PublishAsync", problems), "IJobRepository.PublishAsync", problems);

        var invites = Find(infrastructure, "JP.Infrastructure.Repositories.IInviteRepository", problems);
        Require(Method(invites, "SendAsync", problems), "IInviteRepository.SendAsync", problems);

        if (problems.Count == 0)
        {
            return;
        }

        throw new InvalidOperationException(
            "ENTITLEMENT FALLBACK GUARD (G38): "
            + string.Join(" | ", problems)
            + " — a consuming path that reaches USP_ConsumeFeatureCore without a fallback refuses a lapsed "
            + "account with SUBSCRIPTION_INACTIVE instead of dropping it to the free plan's allowance "
            + "(MONETIZATION_DESIGN 6.5-C). This check lives in "
            + "JP.App.Api/Startup/EntitlementFallbackGuard.cs.");
    }

    private static bool Mentions(string? name) =>
        name is not null && name.Contains(Fallback, StringComparison.OrdinalIgnoreCase);

    private static Type? Find(Assembly assembly, string fullName, List<string> problems)
    {
        var type = assembly.GetType(fullName, throwOnError: false);

        if (type is null)
        {
            problems.Add($"{fullName} was not found — renamed or moved, so this guard is checking nothing");
        }

        return type;
    }

    private static MethodInfo? Method(Type? type, string name, List<string> problems)
    {
        if (type is null)
        {
            return null;
        }

        var method = type.GetMethods(BindingFlags.Public | BindingFlags.Instance)
            .FirstOrDefault(m => m.Name == name);

        if (method is null)
        {
            problems.Add($"{type.Name}.{name} was not found — renamed, so this guard is checking nothing");
        }

        return method;
    }

    /// <summary>
    /// The fallback must be present, and it must be impossible to omit.
    /// </summary>
    private static void Require(MethodInfo? method, string label, List<string> problems)
    {
        if (method is null)
        {
            return;
        }

        var fallbacks = method.GetParameters().Where(p => Mentions(p.Name)).ToList();

        if (fallbacks.Count == 0)
        {
            problems.Add($"{label} has no fallback parameter at all — this is the exact shape that made a "
                + "lapsed account unable to publish");

            return;
        }

        var optional = fallbacks.Where(p => p.IsOptional).Select(p => p.Name).ToList();

        if (optional.Count > 0)
        {
            problems.Add($"{label} makes {string.Join(", ", optional)} optional — a default is what let the "
                + "omission happen silently in SQL");
        }
    }
}
