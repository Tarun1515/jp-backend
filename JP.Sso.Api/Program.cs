using System.Reflection;
using FluentValidation;
using JP.Core.Common;
using JP.Infrastructure;
using JP.Infrastructure.Filters;
using JP.Infrastructure.Security;
using JP.Sso.Api.RateLimiting;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.OpenApi.Models;
using Serilog;

const string CorsPolicyName = "JpPortalCors";

var builder = WebApplication.CreateBuilder(args);

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------
builder.Host.UseSerilog((context, services, configuration) => configuration
    .ReadFrom.Configuration(context.Configuration)
    .ReadFrom.Services(services)
    .Enrich.FromLogContext());

// ---------------------------------------------------------------------------
// MVC
// ---------------------------------------------------------------------------
builder.Services
    .AddControllers(mvc => mvc.Filters.Add<FluentValidationFilter>())
    .ConfigureApiBehaviorOptions(options =>
    {
        // [ApiController] answers a binding failure with a ProblemDetails body
        // by default. Every other response from this API is a Response
        // envelope, and the Angular error interceptor parses exactly one
        // shape — so model-state failures are reshaped to match.
        options.InvalidModelStateResponseFactory = context =>
        {
            var errors = context.ModelState
                .Where(entry => entry.Value is { Errors.Count: > 0 })
                .ToDictionary(
                    entry => entry.Key,
                    entry => entry.Value!.Errors.Select(error => error.ErrorMessage).ToArray(),
                    StringComparer.OrdinalIgnoreCase);

            return new BadRequestObjectResult(ApiResponse.ValidationFailure(errors));
        };
    });

// ---------------------------------------------------------------------------
// Swagger
// ---------------------------------------------------------------------------
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen(swagger =>
{
    swagger.SwaggerDoc("v1", new OpenApiInfo
    {
        Title = "Teacher Recruitment Portal — SSO API",
        Version = "v1",
        Description = "Authentication, users, roles and permissions. Backed by the jp_sso database.",
    });

    var bearerScheme = new OpenApiSecurityScheme
    {
        Name = "Authorization",
        Type = SecuritySchemeType.Http,
        Scheme = "bearer",
        BearerFormat = "JWT",
        In = ParameterLocation.Header,
        Description = "Paste the access token on its own — Swagger adds the \"Bearer \" prefix.",
        Reference = new OpenApiReference { Type = ReferenceType.SecurityScheme, Id = "Bearer" },
    };

    swagger.AddSecurityDefinition("Bearer", bearerScheme);
    swagger.AddSecurityRequirement(new OpenApiSecurityRequirement { [bearerScheme] = [] });

    var xmlPath = Path.Combine(AppContext.BaseDirectory,
        $"{Assembly.GetExecutingAssembly().GetName().Name}.xml");

    if (File.Exists(xmlPath))
    {
        swagger.IncludeXmlComments(xmlPath);
    }
});

// ---------------------------------------------------------------------------
// Application services
// ---------------------------------------------------------------------------
builder.Services.AddJpInfrastructure(builder.Configuration);
builder.Services.AddJpJwtAuthentication(builder.Configuration);

builder.Services.AddCors(cors => cors.AddPolicy(CorsPolicyName, policy =>
{
    var allowedOrigins = builder.Configuration
        .GetSection("Cors:AllowedOrigins").Get<string[]>() ?? [];

    policy.WithOrigins(allowedOrigins)
        .AllowAnyHeader()
        .AllowAnyMethod()
        .AllowCredentials();
}));

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------
// FluentValidationFilter (registered on AddControllers above) resolves an
// IValidator<T> per action argument and returns the same envelope shape that
// InvalidModelStateResponseFactory produces — so a binding failure and a rule
// failure are indistinguishable to the Angular error interceptor.
builder.Services.AddValidatorsFromAssembly(Assembly.GetExecutingAssembly(), includeInternalTypes: true);

// ---------------------------------------------------------------------------
// Rate limiting
// ---------------------------------------------------------------------------
builder.Services.AddTransient<AuthRateLimitKeyMiddleware>();

builder.Services.AddOptions<RateLimitOptions>()
    .Bind(builder.Configuration.GetSection(RateLimitOptions.SectionName))
    .ValidateDataAnnotations()
    .ValidateOnStart();

// Read once, at startup. The limiter is built here and lives for the process,
// so IOptionsMonitor would not change anything already constructed — binding
// eagerly says so plainly rather than implying a reload that never happens.
var rateLimits = builder.Configuration
    .GetSection(RateLimitOptions.SectionName)
    .Get<RateLimitOptions>() ?? new RateLimitOptions();

builder.Services.AddRateLimiter(options =>
{
    // One chained limiter rather than named policies: login needs two
    // independent limits at once, and a named policy resolves to a single
    // partition. See RateLimiting/AuthRateLimiting.cs for the full reasoning.
    options.GlobalLimiter = AuthRateLimiting.CreateChained(rateLimits);

    options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
    options.OnRejected = RateLimitRejection.WriteAsync;
});

var app = builder.Build();

// ---------------------------------------------------------------------------
// Startup checks
// ---------------------------------------------------------------------------
/*
  Constructs every validator once, at boot.

  A FluentValidation validator does all its work in its CONSTRUCTOR, and DI
  builds it on the first request that needs it — so a validator that throws is
  a runtime failure on a live request, not a compile error. This project has
  already been bitten once: an extension method named EmailAddress in the
  Validators namespace bound ahead of FluentValidation's own, including on the
  call inside its own body, and recursed until the stack died. It compiled
  cleanly and killed the process on the first registration attempt.

  Failing here instead costs a few milliseconds at startup.
*/
using (var scope = app.Services.CreateScope())
{
    var validatorTypes = Assembly.GetExecutingAssembly()
        .GetTypes()
        .Where(t => t is { IsAbstract: false, IsInterface: false } && typeof(IValidator).IsAssignableFrom(t));

    foreach (var validatorType in validatorTypes)
    {
        _ = scope.ServiceProvider.GetService(validatorType);
    }
}

// ---------------------------------------------------------------------------
// Pipeline
// ---------------------------------------------------------------------------

// First in, so it wraps everything below: request logging on the outside,
// then the exception handler that turns any failure into a Response envelope.
app.UseJpInfrastructure();

if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI(ui => ui.SwaggerEndpoint("/swagger/v1/swagger.json", "SSO API v1"));
}
else
{
    app.UseHttpsRedirection();
    app.UseHsts();
}

app.UseCors(CorsPolicyName);

// Authentication BEFORE the rate limiter: the send-otp limit partitions on the
// user's uid claim, which does not exist until the token has been validated.
app.UseAuthentication();
app.UseAuthorization();

// Buffers the body and lifts out the login identifier / email, so the limiter
// can partition on them. Must run before UseRateLimiter.
app.UseMiddleware<AuthRateLimitKeyMiddleware>();

app.UseRateLimiter();

app.MapControllers();

app.Run();

/// <summary>
/// Exposed so an integration-test host can reference this entry point.
/// </summary>
public partial class Program;
