# Plugins

This repository hosts the `SoftwareAssassin2` Claude Code plugins and the **ParleyAI**
.NET NuGet package they integrate with.

## Layout

| Path | What it is |
|------|------------|
| [`src/`](./src/) | The **ParleyAI** .NET solution (`src/ParleyAI.sln`) — the publishable NuGet package and its tests. |
| `plugins/` | The Claude Code plugins, including `init-project` (the project scaffolder that consumes ParleyAI). |
| `.github/workflows/nuget.yml` | Build/test + NuGet publish CI for ParleyAI. |
| `LICENSE`, `NOTICE` | Apache-2.0 license + attribution (also packed into the NuGet package). |

## ParleyAI (`./src/`)

ParleyAI is a single, publishable .NET (net10.0) NuGet package providing a unified,
provider-agnostic non-streaming chat client over the **OpenAI** and **Anthropic**
APIs — with keyed dependency injection, OpenTelemetry GenAI telemetry, and an
adaptive AIMD rate optimizer. See [`src/ParleyAI/README.md`](./src/ParleyAI/README.md)
for the package overview and consumer API.

### Build & test

```bash
# Build + run the full test suite
dotnet test src/ParleyAI.sln --configuration Release

# Pack locally (package + symbols) into ./artifacts
dotnet pack src/ParleyAI/ParleyAI.csproj --configuration Release -o ./artifacts
ls ./artifacts/ParleyAI.*.nupkg ./artifacts/ParleyAI.*.snupkg
```

`./artifacts/` is gitignored — pack output is regenerated, never committed.

### CI

`.github/workflows/nuget.yml`:

- **`build-test`** runs on every pull request and branch push that touches `src/**`.
  It builds and tests the package; it never publishes.
- The **release path** (`pack` → publish → `verify-package-restorable`) runs **only**
  on `nuget-v*` tag pushes. Tag pushes ignore the `src/**` path filter, so a release
  tag always runs the full release path. `pack` re-runs the test suite on the tagged
  commit before packing — tests gate the release; we never publish on a successful
  `dotnet pack` alone.

All actions are pinned; `actions/setup-dotnet` is pinned to `10.0.x` in every dotnet job.

## Release procedure

The published ParleyAI version is pinned in one place — the scaffold's
`plugins/init-project/templates/Directory.Build.props` `<LlmWrapperVersion>` property.
A scaffolded project references ParleyAI at exactly that version, and the release
workflow asserts the pin equals the release tag before publishing, so the two can
never drift.

To cut a release:

1. **Bump the pin.** Edit `plugins/init-project/templates/Directory.Build.props` and
   set `<LlmWrapperVersion>` to the new version (e.g. `0.2.0`).
2. **Commit** the bump.
3. **Tag and push:**
   ```bash
   git tag nuget-v0.2.0
   git push origin nuget-v0.2.0
   ```

The workflow then:

- asserts `<LlmWrapperVersion>` == `0.2.0` (the tag minus the `nuget-v` prefix) — a
  mismatch fails the release,
- runs the test suite on the tagged commit,
- packs `ParleyAI` at `/p:Version=0.2.0` (package + symbols),
- publishes to nuget.org via a deterministic auth selector (see below), pushing both
  the `.nupkg` and `.snupkg` with `--skip-duplicate`,
- polls the nuget.org flat-container index until `ParleyAI@0.2.0` is restorable.

### Publish authentication

The release picks exactly one auth path — never both:

- **OIDC trusted publishing** (no long-lived secret) when the repo variable
  `NUGET_TRUSTED_PUBLISHING` is `'true'`. Requires the repo variable `NUGET_USER`
  (the nuget.org account configured as a trusted publisher for this repo). The
  workflow exchanges its OIDC token for a short-lived API key via `NuGet/login`.
- **Classic API key** otherwise — set the repo secret `NUGET_API_KEY`.

The unselected publish job is skipped (not failed), and `verify-package-restorable`
asserts exactly one publish job succeeded before signalling the release is done.

## Scaffold consumption

`init-project` scaffolds a project whose `Api` references the published ParleyAI at
`<PackageReference Include="ParleyAI" Version="$(LlmWrapperVersion)" />` and registers
both providers (keyed: `"openai"` / `"anthropic"`, no default) via the ParleyAI DI
extensions — pre-wired to the flat env/config contract and OpenTelemetry. The scaffold
wiring and the live published-restore verification land with `fn-4.9` / `fn-4.10`.

## License

Apache-2.0. See [`LICENSE`](./LICENSE) and [`NOTICE`](./NOTICE).
