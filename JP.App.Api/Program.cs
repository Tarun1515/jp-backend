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
