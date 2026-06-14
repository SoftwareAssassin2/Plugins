using System.Diagnostics.CodeAnalysis;
using Api;

// Bootstrap/startup wiring — excluded from the coverage gate per docs/tdd.md §5.
// Keep this thin: validate, delegate into BusinessLogic, shape the response
// (docs/architecture.md). JWT/Keycloak validation and the per-request
// session-context unit-of-work are wired in later work (see docs/keycloak.md).

var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

app.MapGet("/health", () => HealthStatus.Live());

app.Run();

// Exposed so a future WebApplicationFactory-based integration test can reference
// the entry-point assembly; the partial Program type is the conventional handle.
[ExcludeFromCodeCoverage]
public partial class Program;
