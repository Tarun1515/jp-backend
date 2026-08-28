using System.Reflection;
using JP.Core.Common;
using JP.Infrastructure;
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
    .AddControllers()
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

app.UseCors(CorsPolicyName);

app.UseAuthentication();
app.UseAuthorization();

app.MapControllers();

app.Run();
