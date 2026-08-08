using JP.Core.Common;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace JP.Sso.Api.Controllers;

/// <summary>
/// Liveness probe. Anonymous by design — a load balancer has no token.
/// </summary>
/// <remarks>
/// Reports that the process is up and answering. It deliberately does not
/// touch the database: a health check that fails whenever SQL Server hiccups
/// causes the orchestrator to recycle a perfectly healthy API.
/// </remarks>
[ApiController]
[Route("api/[controller]")]
[AllowAnonymous]
public sealed class HealthController : ControllerBase
{
    private readonly IWebHostEnvironment _environment;

    public HealthController(IWebHostEnvironment environment)
    {
        _environment = environment;
    }

    /// <summary>Returns basic liveness information.</summary>
    [HttpGet]
    public ActionResult<Response<object>> Get()
    {
        return Ok(ApiResponse.Success(new
        {
            Service = "JP.Sso.Api",
            Status = "Healthy",
            Environment = _environment.EnvironmentName,
            UtcNow = DateTime.UtcNow,
        }));
    }
}
