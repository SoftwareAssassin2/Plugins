using System.Diagnostics.CodeAnalysis;
using Api;
using Api.Auth;
using DataAccess;
using DataAccess.Rls;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.EntityFrameworkCore;
using OpenTelemetry.Metrics;
using OpenTelemetry.Trace;
using ParleyAI.Abstractions;
using ParleyAI.DependencyInjection;
using ParleyAI.Telemetry;

// Bootstrap/startup wiring — excluded from the coverage gate per docs/tdd.md §5.
// Keep this thin: validate, delegate into BusinessLogic, shape the response
// (docs/architecture.md). The decision-bearing auth/session-context logic lives in
// testable units (Api.Auth.SessionContextFactory / SessionUnitOfWorkMiddleware,
// DataAccess.Rls.SessionUnitOfWork) — this file only composes them. See
// docs/keycloak.md §4 and docs/config-management.md §4 for the env-var contract.

var builder = WebApplication.CreateBuilder(args);

// Runtime DB connection: the least-privilege `api` role (NEVER owner/migrator/
// superuser). API_CONNECTION_STRING is assembled by `system.sh build-config` into
// src/Api/.env (loaded into the environment by docker compose).
var apiConnectionString = builder.Configuration["API_CONNECTION_STRING"]
    ?? Environment.GetEnvironmentVariable("API_CONNECTION_STRING");
builder.Services.AddDbContext<PlatformDbContext>(options =>
    options.UseNpgsql(apiConnectionString));

// Per-request session-context unit of work (transaction-first, then SET LOCAL).
builder.Services.AddScoped<IDbSession, EfDbSession>();
builder.Services.AddScoped<ISessionUnitOfWork, SessionUnitOfWork>();

// Keycloak JWT bearer validation. Authority is the realm issuer; the Api is the
// confidential client whose tokens we accept (KEYCLOAK_* from src/Api/.env).
var keycloakPublicUrl = builder.Configuration["KEYCLOAK_PUBLIC_URL"]
    ?? Environment.GetEnvironmentVariable("KEYCLOAK_PUBLIC_URL");
var keycloakRealm = builder.Configuration["KEYCLOAK_REALM"]
    ?? Environment.GetEnvironmentVariable("KEYCLOAK_REALM");
var apiClientId = builder.Configuration["KEYCLOAK_API_CLIENT_ID"]
    ?? Environment.GetEnvironmentVariable("KEYCLOAK_API_CLIENT_ID");

builder.Services
    .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(options =>
    {
        if (!string.IsNullOrWhiteSpace(keycloakPublicUrl) && !string.IsNullOrWhiteSpace(keycloakRealm))
        {
            options.Authority = $"{keycloakPublicUrl!.TrimEnd('/')}/realms/{keycloakRealm}";
        }

        options.Audience = apiClientId;
        // Map the subject onto the claim type SessionContextFactory reads. Roles
        // live in Keycloak's `realm_access.roles` JSON array, NOT as individual
        // role claims — setting RoleClaimType alone would NOT expand them, so we
        // flatten them into ClaimTypes.Role claims on validation (see
        // KeycloakRoleClaims) and point RoleClaimType at that standard type.
        options.TokenValidationParameters.NameClaimType = SessionContextFactory.SubjectClaimType;
        options.TokenValidationParameters.RoleClaimType = SessionContextFactory.RoleClaimType;
        options.Events = new JwtBearerEvents
        {
            OnTokenValidated = context =>
            {
                KeycloakRoleClaims.PopulateRoleClaims(context.Principal?.Identity as System.Security.Claims.ClaimsIdentity);
                return Task.CompletedTask;
            },
        };
    });
builder.Services.AddAuthorization();

// Unified OpenAI/Anthropic chat client (ParleyAI). One no-glue call registers BOTH
// providers as KEYED IAiChatClient ("openai" / "anthropic") — there is NO unkeyed
// default, so a consumer must name the provider. AddParleyAi reads the flat env-var
// contract `system.sh build-config` emits into src/Api/.env (OPENAI_BASE_URL/
// OPENAI_API_KEY/ANTHROPIC_BASE_URL/ANTHROPIC_API_KEY) straight off IConfiguration —
// no section binding, no caller glue. When a *_BASE_URL is absent the provider SDK
// default applies; the keys are required. Per-provider validation is LAZY (at
// resolve, not here), so a fresh scaffold boots even if a provider is never used.
builder.Services.AddParleyAi(builder.Configuration);

// Example usage — inject (or resolve) BOTH providers in the SAME method; pick per
// call. Keyed injection in a controller/minimal-API handler:
//
//     app.MapPost("/chat", async (
//         [FromKeyedServices(ProviderKeys.OpenAi)]    IAiChatClient openai,
//         [FromKeyedServices(ProviderKeys.Anthropic)] IAiChatClient anthropic,
//         ChatRequest request,
//         CancellationToken ct) =>
//     {
//         var a = await openai.CompleteChatAsync(request, ct);
//         var b = await anthropic.CompleteChatAsync(request, ct);
//         return Results.Ok(new { openai = a, anthropic = b });
//     });
//
// Or select at runtime via the factory:
//     IAiChatClient client = factory.Create(ProviderKeys.OpenAi);

// OpenTelemetry: register ParleyAI's GenAI ActivitySource (tracing) + Meter (metrics)
// and export BOTH over OTLP. ParleyAI takes no exporter dependency itself — wiring the
// exporter is this app's job. The source/meter names are referenced via the PUBLIC
// constants (ParleyAiTelemetry.ActivitySourceName / .MeterName) — NEVER the literal
// string — because a name mismatch silently no-ops all ParleyAI telemetry.
//
// NO explicit OTLP endpoint: the SDK default (http://localhost:4317) is correct. The
// Api runs as a process (`dotnet run`) in the SAME place the compose stacks run — the
// host, or inside the dev container via docker-in-docker — and the otel-collector
// publishes its gRPC port to that loopback (127.0.0.1:4317), so a dev-container-run Api
// reaches it at localhost:4317 too. IF a deployment instead puts the Api in a SEPARATE
// container from the collector, set the standard OTEL_EXPORTER_OTLP_ENDPOINT
// (e.g. http://otel-collector:4317) — but containerizing the Api is OUT OF SCOPE here
// (no env emission, no build-config change); the env var is the override mechanism.
builder.Services.AddOpenTelemetry()
    .WithTracing(tracing => tracing
        .AddSource(ParleyAiTelemetry.ActivitySourceName)
        .AddOtlpExporter())
    .WithMetrics(metrics => metrics
        .AddMeter(ParleyAiTelemetry.MeterName)
        .AddOtlpExporter());

var app = builder.Build();

app.UseAuthentication();

// Opens the per-request unit of work for authenticated requests (transaction +
// SET LOCAL app.user_id) so row-level security scopes every query. It MUST sit
// AFTER authentication (it reads the validated principal) and BEFORE
// authorization + endpoints, so any DB-backed authorization policy and all
// request work run inside the session-context transaction.
app.UseMiddleware<SessionUnitOfWorkMiddleware>();

app.UseAuthorization();

app.MapGet("/health", () => HealthStatus.Live());

app.Run();

// Exposed so a future WebApplicationFactory-based integration test can reference
// the entry-point assembly; the partial Program type is the conventional handle.
[ExcludeFromCodeCoverage]
public partial class Program;
