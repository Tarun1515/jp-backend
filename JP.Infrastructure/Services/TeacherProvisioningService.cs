using JP.Infrastructure.Repositories;
using Microsoft.Extensions.Logging;

namespace JP.Infrastructure.Services;

internal interface ITeacherProvisioningService
{
    Task ProvisionAsync(Guid userUid, string? fullName, CancellationToken cancellationToken);
}

/// <summary>
/// Creates the jp_app half of a teacher account.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 THE FIX FOR G21, AT THE SOURCE.
/// </para>
/// <para>
/// Teacher signup created an account in jp_sso and nothing in jp_app. Phase 3B
/// backfilled the accounts that already existed, and every teacher registering
/// after it fell straight back into the same hole — one at a time, so the next
/// backfill would simply have been a bigger version of the last one. A backfill
/// that has to be repeated is not a fix, it is a schedule.
/// </para>
/// <para>
/// ⚠️ THIS IS A CROSS-DATABASE WRITE, and it follows the shape decision 2.48
/// settled on rather than inventing a second one:
/// </para>
/// <list type="number">
///   <item>
///     <b>Ordering.</b> The account is created FIRST, in jp_sso, and this runs
///     after it. Reversed, a failure would leave a profile belonging to no
///     account — invisible from both sides. This way the failure is reachable:
///     the person exists, can sign in, and can complain.
///   </item>
///   <item>
///     <b>Idempotency.</b> Keyed on UserUid, which carries a filtered unique
///     index. Called twice, the procedure returns ALREADY_PROVISIONED rather
///     than failing, so a retry converges.
///   </item>
///   <item>
///     <b>Loud failure.</b> A failure here is logged at Error with the UserUid.
///     It does NOT fail the registration — see below.
///   </item>
/// </list>
/// <para>
/// 🔴 WHY A FAILURE HERE DOES NOT FAIL THE SIGNUP.
/// </para>
/// <para>
/// The account is already committed in another database and cannot be
/// un-created. Throwing would show the person "registration failed" for an
/// account that exists — so their retry hits a duplicate-email error, and they
/// have an account they have been told they do not have. That is a worse
/// outcome than a missing profile row, which the verification query finds and
/// this service repairs on the next call.
/// </para>
/// <para>
/// The safety net is
/// <c>database/jp_app/90_ops/001_verify_account_completeness.sql</c>, check A.
/// Phase 8 schedules it.
/// </para>
/// </remarks>
internal sealed class TeacherProvisioningService : ITeacherProvisioningService
{
    /// <summary>m_sso_user_types. Teacher.</summary>
    private const int UserTypeTeacher = 3;

    private readonly IPlanRepository _plans;
    private readonly IAppProvisioningRepository _provisioning;
    private readonly ILogger<TeacherProvisioningService> _logger;

    public TeacherProvisioningService(
        IPlanRepository plans,
        IAppProvisioningRepository provisioning,
        ILogger<TeacherProvisioningService> logger)
    {
        _plans = plans;
        _provisioning = provisioning;
        _logger = logger;
    }

    public async Task ProvisionAsync(Guid userUid, string? fullName, CancellationToken cancellationToken)
    {
        try
        {
            /*
              The plan is read from jp_mdm and passed into jp_app, because
              neither database can see the other (2.2). Same handoff as the
              school side (2.50).

              No default plan means no provisioning — a teacher with a profile
              and no plan is the "no subscription" state the design exists to
              prevent, and accepting NULL here would make it reachable by
              forgetting one seed script.
            */
            var plan = await _plans.GetDefaultPlanAsync(UserTypeTeacher, cancellationToken)
                .ConfigureAwait(false);

            if (plan is null)
            {
                _logger.LogError(
                    "🔴 Teacher {UserUid} was registered but no default plan is configured for a teacher, " +
                    "so no profile was created. Seed m_mdm_plans — TEACHER_FREE with IsDefault = 1 — then run " +
                    "90_ops/001_verify_account_completeness.sql to find every account in this state.",
                    userUid);

                return;
            }

            var result = await _provisioning
                .ProvisionTeacherProfileAsync(userUid, fullName, plan.PlanId, cancellationToken)
                .ConfigureAwait(false);

            if (!result.Succeeded)
            {
                _logger.LogError(
                    "🔴 Teacher {UserUid} was registered but their profile could not be created: {Code} — {Message}. " +
                    "The account exists and can sign in with nothing behind it. " +
                    "Run 90_ops/001_verify_account_completeness.sql to list every account in this state.",
                    userUid, result.Code, result.Message);

                return;
            }

            _logger.LogInformation(
                "Teacher {UserUid} provisioned: profile {TeacherId}, plan {PlanCode}.",
                userUid, result.Id, plan.PlanCode);
        }
        catch (Exception ex)
        {
            /*
              🔴 Swallowed on purpose, and loudly.

              The account is committed in jp_sso. Letting this bubble would turn
              a missing profile row into "registration failed" for an account
              that exists — and the person's retry then hits a duplicate-email
              error, leaving them with an account they have been told they do
              not have.

              A missing profile is recoverable and detectable. A person who
              cannot register and cannot retry is neither.
            */
            _logger.LogError(
                ex,
                "🔴 Teacher {UserUid} was registered but provisioning their profile threw. The account exists " +
                "with nothing behind it. Run 90_ops/001_verify_account_completeness.sql.",
                userUid);
        }
    }
}
