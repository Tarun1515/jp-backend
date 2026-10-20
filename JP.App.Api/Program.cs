using System.Reflection;
using FluentValidation;
using JP.App.Api.RateLimiting;
using JP.Core.Common;
using JP.Infrastructure;
using JP.Infrastructure.Filters;
using JP.Infrastructure.Security;
using Microsoft.AspNetCore.Mvc;
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
    /*
      Phase 7A. The FluentValidationFilter, which this API did not have.

      🔴 It is needed now because 7A adds the first ANONYMOUS WRITE here (the
      contact form). Until this phase every endpoint required a token and every
      write was checked inside its procedure, so a malformed request belonged to
      a caller we could name. An anonymous one belongs to nobody, and what it
      writes lands in a queue a person has to read.

      ⚠️ The filter produces the response itself rather than adding to
      ModelState — [ApiController]'s automatic 400 runs at Order = -2000, before
      this. Its header explains why; the shape it returns is the same envelope
      InvalidModelStateResponseFactory builds below, so a binding failure and a
      rule failure are indistinguishable to the Angular error interceptor.
    */
    .AddControllers(mvc => mvc.Filters.Add<FluentValidationFilter>())
    .ConfigureApiBehaviorOptions(options =>
    {
        // Reshape model-state failures into the Response envelope, so this API
        // never returns two different error shapes.
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
        Title = "Teacher Recruitment Portal — Application API",
        Version = "v1",
        Description = "Master data, the approval engine and business endpoints. " +
                      "Backed by the jp_mdm and jp_app databases.",
    });

    /*
      🔴 SCHEMA IDS ARE NAMESPACE-QUALIFIED, AND THIS IS A BUG FIX.

      Swashbuckle keys every schema on the SHORT type name by default, so two
      DTOs with the same name anywhere in the surface collide and the whole
      document dies with a 500:

          Can't use schemaId "PlanSummaryDto" for type
          "JP.Domain.Entitlements.PlanSummaryDto". The same schemaId is already
          used for type "JP.Domain.Dashboards.PlanSummaryDto"

      Both are legitimate and unrelated — one is the plan on a school's
      dashboard (3I), the other a plan row in the admin matrix (2.5). Renaming
      one would fix this collision and leave the NEXT one waiting, because
      nothing stops two features from naming a DTO the same thing again.

      Qualifying by the FULL namespace closes the class:
      "DomainDashboardsPlanSummaryDto" and "DomainEntitlementsPlanSummaryDto".
      They cannot collide unless two types share a namespace AND a name, which
      the compiler already forbids.

      ⚠️ Only the "JP." every type carries is dropped — a prefix on all of them
      distinguishes none of them. Trimming further (the last segment only, say)
      would read better and quietly restore the possibility of a collision,
      which is the one outcome worth avoiding here. See JP.Core SchemaIds.

      ⚠️ This changes schema NAMES in the document, not the JSON on the wire:
      property names are untouched. Nothing generates a client from this today.
    */
    swagger.CustomSchemaIds(SchemaIds.ForType);

    var bearerScheme = new OpenApiSecurityScheme
    {
        Name = "Authorization",
        Type = SecuritySchemeType.Http,
        Scheme = "bearer",
        BearerFormat = "JWT",
        In = ParameterLocation.Header,
        Description = "Paste the access token issued by the SSO API — Swagger adds the \"Bearer \" prefix.",
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

// Validates tokens issued by JP.Sso.Api. Both APIs must be configured with the
// same Jwt:Key, issuer and audience.
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

/*
  🔴 REFUSE TO START IF THE BROWSE DTO HAS GROWN A CONTACT FIELD.

  A school browsing the teacher database must never receive an email, a mobile
  number, a resume path or a date of birth (2.54, 2.56). The type says so in a
  comment; comments do not fail a build, and this does.

  Deliberately before Build() has a chance to serve anything: a school that has
  already read a teacher's phone number cannot be made to un-read it, so the
  right failure is loud, local and immediate.
*/
JP.App.Api.Startup.ContactLeakGuard.Verify();

/*
  🔴 AND THE SECOND STARTUP GUARD — G38, PHASE 8-0.

  Same family, same reasoning: a rule that only exists in comments is a rule
  that has already been broken once. This one refuses to start if a consuming
  path can reach the entitlement core without the free-plan fallback, which is
  how a lapsed school came to be refused a FREE job publish.
*/
JP.App.Api.Startup.EntitlementFallbackGuard.Verify();

// ---------------------------------------------------------------------------
// Validation — Phase 7A
// ---------------------------------------------------------------------------
/*
  Scans THIS assembly, so a validator is found by living in
  JP.App.Api/Validators — the same arrangement as the SSO API.

  ⚠️ includeInternalTypes, matching the SSO: a validator that is internal by
  habit would otherwise be skipped silently, and the symptom is an endpoint
  that accepts anything. That is precisely the defect 7A's suite caught on the
  contact form, so it is not a hypothetical.
*/
builder.Services.AddValidatorsFromAssembly(
    Assembly.GetExecutingAssembly(), includeInternalTypes: true);

// ---------------------------------------------------------------------------
// Rate limiting — Phase 7A
// ---------------------------------------------------------------------------
/*
  🔴 THIS API HAD NO RATE LIMITER UNTIL NOW, and it did not need one: every
  endpoint required a token, and a token is itself a limit — an attacker has to
  obtain an account, and the account is revocable.

  7A adds the first UNAUTHENTICATED endpoints over business data, so this is
  what stands between a scraper and the job table. Chained, per IP, with the
  numbers in configuration — the shape and reasoning of 2.35.

  ⚠️ Read eagerly at startup: the limiter is built here and lives for the
  process, so IOptionsMonitor would imply a reload that never happens.
*/
var publicRateLimits = builder.Configuration
    .GetSection(PublicRateLimitOptions.SectionName)
    .Get<PublicRateLimitOptions>() ?? new PublicRateLimitOptions();

builder.Services.AddRateLimiter(options =>
{
    options.GlobalLimiter = PublicRateLimiting.CreateChained(publicRateLimits);

    options.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
    options.OnRejected = PublicRateLimitRejection.WriteAsync;
});

var app = builder.Build();

// ---------------------------------------------------------------------------
// Pipeline
// ---------------------------------------------------------------------------
app.UseJpInfrastructure();

if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI(ui => ui.SwaggerEndpoint("/swagger/v1/swagger.json", "Application API v1"));
}
else
{
    app.UseHttpsRedirection();
    app.UseHsts();
}

/*
  🔴 FORWARDED HEADERS FIRST, AND BEFORE THE RATE LIMITER — G42, PHASE 8-0.

  Behind a reverse proxy every request arrives from the proxy, so a per-IP
  limit becomes a per-SITE limit: the fourth visitor to use the contact form in
  an hour is refused because the first three shared the proxy's address. G42
  recorded that as the cost of not reading X-Forwarded-For.

  This reads it — but only from addresses the configuration names. That
  distinction is the whole point: an unlisted peer's X-Forwarded-For is
  ignored, so a client cannot hand itself a fresh budget by inventing a header.

  ⚠️ ORDER IS LOAD-BEARING. UseForwardedHeaders rewrites
  Connection.RemoteIpAddress; the limiter partitions on that value. Placed
  after UseRateLimiter it would rewrite the address AFTER the decision that
  needed it, and nothing would fail — the limits would simply go on being
  per-site. A verification asserts this ordering for that reason.

  ⚠️ OFF BY DEFAULT. Enabling it without a KnownProxies list is how a
  deployment starts trusting a header from anybody; the shipped posture is to
  see the immediate peer and say so.
*/
var forwarded = builder.Configuration.GetSection("ForwardedHeaders");

if (forwarded.GetValue("Enabled", false))
{
    var options = new Microsoft.AspNetCore.Builder.ForwardedHeadersOptions
    {
        ForwardedHeaders = Microsoft.AspNetCore.HttpOverrides.ForwardedHeaders.XForwardedFor
            | Microsoft.AspNetCore.HttpOverrides.ForwardedHeaders.XForwardedProto,
        ForwardLimit = forwarded.GetValue("ForwardLimit", 1),
    };

    /*
      ⚠️ The defaults are CLEARED first. ForwardedHeadersOptions ships with
      loopback already trusted, so leaving them in place would mean a locally
      running client is trusted to set its own address — in development that is
      every browser on the machine.
    */
    options.KnownProxies.Clear();
    options.KnownNetworks.Clear();

    foreach (var proxy in forwarded.GetSection("KnownProxies").Get<string[]>() ?? [])
    {
        if (System.Net.IPAddress.TryParse(proxy, out var address))
        {
            options.KnownProxies.Add(address);
        }
        else
        {
            throw new InvalidOperationException(
                $"ForwardedHeaders:KnownProxies contains '{proxy}', which is not an IP address. "
                + "A typo here silently trusts nothing, so it fails loudly instead.");
        }
    }

    app.UseForwardedHeaders(options);

    app.Logger.LogInformation(
        "Forwarded headers ON — trusting X-Forwarded-For from {Count} proxy address(es), {Limit} hop(s). "
        + "Rate limits partition on the forwarded client address.",
        options.KnownProxies.Count, options.ForwardLimit);
}
else
{
    app.Logger.LogInformation(
        "Forwarded headers OFF — rate limits partition on the immediate peer address. "
        + "Behind a reverse proxy that is ONE bucket for the whole site (G42).");
}

app.UseCors(CorsPolicyName);

/*
  🔴 BEFORE authentication, deliberately.

  An anonymous flood must be refused without this process doing any work on it
  — and validating a JWT is work. Placed after UseAuthentication, every
  rejected request would still have had its token parsed first, which is the
  cost the limit exists to avoid.
*/
app.UseRateLimiter();

app.UseAuthentication();
app.UseAuthorization();

app.MapControllers();

app.Run();
