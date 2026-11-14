using System.ComponentModel.DataAnnotations;

namespace JP.Infrastructure.Address;

/// <summary>
/// How far a campus pin may sit from the geocoded point of its own stated
/// address before an administrator is asked to look at it. Bound from the
/// <c>CampusPinReview</c> section.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 THIS NUMBER IS CONFIGURATION, NOT A CONSTANT, AND THE REASON IS THAT
/// NOBODY KNOWS IT YET. Three kilometres is a starting guess. The right value
/// is whatever leaves a queue an administrator can actually work: too tight and
/// every rural campus with a village address is on it, too loose and the ones
/// that matter are not. That is discovered by looking at a real queue, which
/// means it has to be changeable without a deployment.
/// </para>
/// <para>
/// ⚠️ SO THERE IS NO DEFAULT IN SQL. <c>USP_SearchCampusPinReview</c> requires
/// <c>@ThresholdKm</c> and has no fallback — a default there would be a second
/// answer to the question this class answers, and the day the two disagree the
/// SQL wins silently and nobody can see why the queue changed. The procedure's
/// header says the same thing from the other side.
/// </para>
/// <para>
/// 🔴 AND IT IS RETURNED ON EVERY ROW as <c>thresholdKm</c>. The admin client
/// keeps no copy: a client copy of a server setting is silently wrong the day
/// the server is configured to anything else, and the screen would then explain
/// a queue using the wrong number — "4.1 km, over the 3 km limit" beside a row
/// that is on the list because the limit is now 4.
/// </para>
/// <para>
/// ⚠️ KILOMETRES, EVERYWHERE EXCEPT ONE LINE. This value, the procedure
/// parameter and the <c>CampusPinReview</c> contract are all km, because that
/// is what a person types and reads. <c>STDistance</c> returns METRES, so the
/// ×1000 happens once, inside the procedure, at the only place that knows
/// STDistance's unit.
/// </para>
/// </remarks>
public sealed class CampusPinReviewOptions
{
    public const string SectionName = "CampusPinReview";

    /// <summary>
    /// The review threshold, in kilometres. Default 3.
    /// </summary>
    /// <remarks>
    /// <para>
    /// ⚠️ decimal, not double. It is a configured quantity that gets compared
    /// and displayed, and 0.1 is not representable in binary floating point —
    /// a threshold set to 0.1 and shown back as 0.1000000000000000055 is the
    /// kind of thing that makes an operator distrust the screen. The same
    /// reasoning the coordinate columns get in 036.
    /// </para>
    /// <para>
    /// 🔴 THE RANGE IS VALIDATED AT STARTUP, WITH ValidateOnStart, so a typo
    /// fails the process rather than the first admin who opens the desk. The
    /// floor is 50 metres because anything tighter is inside the error of
    /// consumer GPS and would flag every campus on the platform; the ceiling is
    /// 500km because a threshold that large cannot flag anything in a single
    /// state and is therefore a configuration mistake, not a loose policy.
    /// </para>
    /// <para>
    /// ⚠️ The procedure ALSO floors a zero or negative value at one metre. That
    /// is not a duplicate of this rule — it is what happens to a hand-run EXEC
    /// that never passed through this class, and it fails safe (as tight as
    /// possible) rather than flagging nothing.
    /// </para>
    /// </remarks>
    [Range(0.05, 500.0)]
    public decimal MaxDistanceKm { get; set; } = 3m;
}
