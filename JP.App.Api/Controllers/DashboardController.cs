using JP.Core.Common;
using JP.Domain.Dashboards;
using JP.Infrastructure.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace JP.App.Api.Controllers;

/// <summary>
/// What each app opens on.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 NEITHER ENDPOINT RETURNS A JOB COUNT OR AN APPLICATION COUNT, and that is
/// the entire point of the phase that added them.
/// </para>
/// <para>
/// Both dashboards were static mockups computing figures from a fixture file —
/// 50 applicants, a funnel, "latest applications" — with no HTTP call at all
/// (G6). They were also the two screens that looked the most finished, which is
/// the dangerous combination in front of a client.
/// </para>
/// <para>
/// Jobs are Phase 4 and applications are Phase 5. Until those tables exist the
/// honest rendering is an empty state that says what the section will be — not
/// a zero, which claims a measurement, and not a number, which invents one.
/// </para>
/// <para>
/// ⚠️ Each endpoint composes from the profile, team and subscription reads that
/// already exist rather than adding queries of its own. One place decides what a
/// school's verified badge means, and it is not the dashboard.
/// </para>
/// </remarks>
[ApiController]
[Route("api/dashboard")]
[Authorize]
public sealed class DashboardController : ControllerBase
{
    private readonly IDashboardService _dashboards;

    public DashboardController(IDashboardService dashboards)
    {
        _dashboards = dashboards;
    }

    /// <summary>The school's own dashboard, resolved from the caller's membership.</summary>
    /// <remarks>
    /// No school id anywhere — it comes from the token and the membership table
    /// (2.39), so there is no parameter pointing at somebody else's school.
    /// A teacher hitting this gets the refusal written for them, not one written
    /// for a school user with no membership.
    /// </remarks>
    [HttpGet("school")]
    [ProducesResponseType(typeof(Response<SchoolDashboardDto>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> GetSchool(CancellationToken cancellationToken)
    {
        var dashboard = await _dashboards.GetSchoolAsync(User, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success(dashboard));
    }

    /// <summary>The teacher's own dashboard.</summary>
    /// <remarks>
    /// ⚠️ The completion percentage travels; the wording does not. The screen
    /// reuses the meter from 3H, which names one next step and never prints "0%"
    /// as a verdict (2.60) — a second completeness display would be a second
    /// rule to keep in step.
    /// </remarks>
    [HttpGet("teacher")]
    [ProducesResponseType(typeof(Response<TeacherDashboardDto>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> GetTeacher(CancellationToken cancellationToken)
    {
        var dashboard = await _dashboards.GetTeacherAsync(User, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success(dashboard));
    }
}
