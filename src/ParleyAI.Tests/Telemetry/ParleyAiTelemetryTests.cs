using System;
using System.Linq;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using ParleyAI.Abstractions;
using ParleyAI.Providers.Anthropic;
using ParleyAI.Providers.OpenAi;
using ParleyAI.Telemetry;
using Xunit;
using AnthropicFake = ParleyAI.Tests.Anthropic.FakeHttpMessageHandler;
using OpenAiFake = ParleyAI.Tests.OpenAi.FakeHttpMessageHandler;

namespace ParleyAI.Tests.Telemetry;

/// <summary>
/// Asserts the library-side OpenTelemetry GenAI contract (R6): both providers emit <c>gen_ai.*</c>
/// spans on the named <see cref="ParleyAiTelemetry.ActivitySource"/>, the two PINNED metric instruments
/// (exact names + units) on the named <see cref="ParleyAiTelemetry.Meter"/>, and message-content capture
/// is gated by the options flag (default OFF). Exercised over the in-process fakes (no network / no
/// fn-3) used by the provider tests.
/// </summary>
/// <remarks>
/// The <see cref="ParleyAiTelemetry.ActivitySource"/> / <see cref="ParleyAiTelemetry.Meter"/> are
/// process-global, and EVERY provider call (across the whole suite) now emits on them — so a
/// <see cref="TelemetryCollector"/> listening by name would cross-capture spans/measurements from other
/// concurrently-running test classes. <see cref="TelemetryCollector"/> therefore records ONLY what is
/// emitted inside its own <c>using</c> scope on the current async-flow (an <c>AsyncLocal</c> gate), so
/// these assertions see exactly this test's telemetry regardless of cross-class parallelism.
/// </remarks>
public sealed class ParleyAiTelemetryTests
{
    private static OpenAiChatClient OpenAiClient(OpenAiFake handler, ParleyAiTelemetryOptions? telemetry = null)
    {
        var httpClient = new HttpClient(handler);
        var settings = new OpenAiChatClientSettings { ApiKey = "sk-test", BaseUrl = "http://localhost:4010/v1" };
        return new OpenAiChatClient(settings, httpClient, telemetry);
    }

    private static AnthropicChatClient AnthropicClient(AnthropicFake fake, ParleyAiTelemetryOptions? telemetry = null)
    {
        var rewrite = new AnthropicOriginRewriteHandler("http://localhost:4010") { InnerHandler = fake };
        var httpClient = new HttpClient(rewrite);
        var settings = new AnthropicChatClientSettings { ApiKey = "sk-ant-test", BaseUrl = "http://localhost:4010" };
        return new AnthropicChatClient(settings, httpClient, telemetry);
    }

    private static ChatRequest Request(string model) => new(
        model,
        new[]
        {
            new ChatMessage(Role.System, "be terse"),
            new ChatMessage(Role.User, "hello there"),
        })
        {
            MaxTokens = 64,
            Temperature = 0.5,
        };

    [Fact]
    public void Source_and_meter_names_are_the_documented_public_constant()
    {
        // The exact names fn-4.9 registers (AddSource / AddMeter). A drift here silently no-ops the
        // consumer's exporter, so the contract is asserted explicitly.
        Assert.Equal("ParleyAI", ParleyAiTelemetry.ActivitySourceName);
        Assert.Equal("ParleyAI", ParleyAiTelemetry.MeterName);
        Assert.Equal("ParleyAI", ParleyAiTelemetry.ActivitySource.Name);
        Assert.Equal("ParleyAI", ParleyAiTelemetry.Meter.Name);
    }

    [Fact]
    public async Task OpenAi_success_emits_chat_span_with_gen_ai_attributes()
    {
        using var collector = new TelemetryCollector();
        var handler = new OpenAiFake(_ => OpenAiFake.Completion());
        OpenAiChatClient client = OpenAiClient(handler);

        await client.CompleteChatAsync(Request("gpt-4o"));

        var activity = Assert.Single(collector.Activities);
        Assert.Equal("chat gpt-4o", activity.DisplayName);
        Assert.Equal("chat", GetTag(activity, "gen_ai.operation.name"));
        Assert.Equal("openai", GetTag(activity, "gen_ai.provider.name"));
        Assert.Equal("gpt-4o", GetTag(activity, "gen_ai.request.model"));
        Assert.Equal(System.Diagnostics.ActivityStatusCode.Ok, activity.Status);
        // finish_reasons is an array of strings per semconv.
        var finishReasons = Assert.IsType<string[]>(activity.GetTagItem("gen_ai.response.finish_reasons"));
        Assert.Equal(new[] { "stop" }, finishReasons);
    }

    [Fact]
    public async Task Anthropic_success_emits_chat_span_with_anthropic_provider_name()
    {
        using var collector = new TelemetryCollector();
        var fake = new AnthropicFake(_ => AnthropicFake.Completion());
        AnthropicChatClient client = AnthropicClient(fake);

        await client.CompleteChatAsync(Request("claude-3-5-sonnet"));

        var activity = Assert.Single(collector.Activities);
        Assert.Equal("chat claude-3-5-sonnet", activity.DisplayName);
        Assert.Equal("anthropic", GetTag(activity, "gen_ai.provider.name"));
        Assert.Equal("claude-3-5-sonnet", GetTag(activity, "gen_ai.request.model"));
    }

    [Fact]
    public async Task Pinned_metric_instruments_have_exact_names_and_units()
    {
        using var collector = new TelemetryCollector();
        var handler = new OpenAiFake(_ => OpenAiFake.Completion());
        OpenAiChatClient client = OpenAiClient(handler);

        await client.CompleteChatAsync(Request("gpt-4o"));

        // Operation-duration histogram: exact name, unit "s".
        TelemetryCollector.RecordedMeasurement duration = Assert.Single(
            collector.Measurements, m => m.InstrumentName == "gen_ai.client.operation.duration");
        Assert.Equal("s", duration.Unit);
        Assert.Equal("chat", duration.Tags["gen_ai.operation.name"]);
        Assert.Equal("openai", duration.Tags["gen_ai.provider.name"]);

        // Token-usage histogram: exact name, unit "{token}", one input + one output measurement.
        var tokenMeasurements = collector.Measurements
            .Where(m => m.InstrumentName == "gen_ai.client.token.usage")
            .ToList();
        Assert.Equal(2, tokenMeasurements.Count);
        Assert.All(tokenMeasurements, m => Assert.Equal("{token}", m.Unit));

        TelemetryCollector.RecordedMeasurement input = Assert.Single(
            tokenMeasurements, m => Equals(m.Tags["gen_ai.token.type"], "input"));
        TelemetryCollector.RecordedMeasurement output = Assert.Single(
            tokenMeasurements, m => Equals(m.Tags["gen_ai.token.type"], "output"));
        // The OpenAI fake reports usage { prompt:7, completion:5 } (see the fixture).
        Assert.True(input.Value > 0);
        Assert.True(output.Value > 0);
    }

    [Fact]
    public async Task Content_capture_is_off_by_default_no_message_attributes()
    {
        using var collector = new TelemetryCollector();
        var handler = new OpenAiFake(_ => OpenAiFake.Completion());
        OpenAiChatClient client = OpenAiClient(handler, telemetry: null); // default options

        await client.CompleteChatAsync(Request("gpt-4o"));

        var activity = Assert.Single(collector.Activities);
        Assert.Null(activity.GetTagItem("gen_ai.input.messages"));
        Assert.Null(activity.GetTagItem("gen_ai.output.messages"));
    }

    [Fact]
    public async Task Content_capture_when_enabled_records_input_and_output_messages()
    {
        using var collector = new TelemetryCollector();
        var handler = new OpenAiFake(_ => OpenAiFake.Completion());
        OpenAiChatClient client = OpenAiClient(handler, new ParleyAiTelemetryOptions { CaptureMessageContent = true });

        await client.CompleteChatAsync(Request("gpt-4o"));

        var activity = Assert.Single(collector.Activities);
        var input = Assert.IsType<string>(activity.GetTagItem("gen_ai.input.messages"));
        Assert.Contains("hello there", input);
        var output = Assert.IsType<string>(activity.GetTagItem("gen_ai.output.messages"));
        Assert.Equal("hello from fake", output);
    }

    [Fact]
    public async Task Failed_call_records_error_type_on_span_and_duration_metric()
    {
        using var collector = new TelemetryCollector();
        // A 429 request-rate limit → RateLimit category → error.type "rate_limit".
        var handler = new OpenAiFake(_ => ParleyAI.Tests.OpenAi.OpenAiErrorFixtures.Openai429Rpm());
        OpenAiChatClient client = OpenAiClient(handler);

        await Assert.ThrowsAsync<ParleyAIException>(() => client.CompleteChatAsync(Request("gpt-4o")));

        var activity = Assert.Single(collector.Activities);
        Assert.Equal(System.Diagnostics.ActivityStatusCode.Error, activity.Status);
        Assert.Equal("rate_limit", GetTag(activity, "error.type"));

        // The duration metric is still recorded for the failed call, dimensioned by error.type.
        TelemetryCollector.RecordedMeasurement duration = Assert.Single(
            collector.Measurements, m => m.InstrumentName == "gen_ai.client.operation.duration");
        Assert.Equal("rate_limit", duration.Tags["error.type"]);
        // No token-usage measurement on a failed call (no response).
        Assert.DoesNotContain(collector.Measurements, m => m.InstrumentName == "gen_ai.client.token.usage");
    }

    [Fact]
    public async Task Cancellation_records_cancelled_error_type_and_rethrows_unwrapped()
    {
        using var collector = new TelemetryCollector();
        var handler = new OpenAiFake(_ => OpenAiFake.Completion());
        OpenAiChatClient client = OpenAiClient(handler);

        using var cts = new CancellationTokenSource();
        cts.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => client.CompleteChatAsync(Request("gpt-4o"), cts.Token));

        var activity = Assert.Single(collector.Activities);
        Assert.Equal(System.Diagnostics.ActivityStatusCode.Error, activity.Status);
        Assert.Equal("cancelled", GetTag(activity, "error.type"));
    }

    [Fact]
    public void Semconv_constants_are_pinned_in_one_source()
    {
        // The pinned semconv version + the well-known attribute keys live in one constants source.
        Assert.Equal("1.30.0", GenAiAttributes.SemanticConventionsVersion);
        Assert.Equal("gen_ai.client.operation.duration", GenAiAttributes.OperationDurationMetric);
        Assert.Equal("s", GenAiAttributes.OperationDurationUnit);
        Assert.Equal("gen_ai.client.token.usage", GenAiAttributes.TokenUsageMetric);
        Assert.Equal("{token}", GenAiAttributes.TokenUsageUnit);
        Assert.Equal("gen_ai.token.type", GenAiAttributes.TokenType);
        // The provider attribute was renamed gen_ai.system → gen_ai.provider.name; both are recorded.
        Assert.Equal("gen_ai.provider.name", GenAiAttributes.ProviderName);
        Assert.Equal("gen_ai.system", GenAiAttributes.LegacyProviderSystemKey);
    }

    private static object? GetTag(System.Diagnostics.Activity activity, string key) => activity.GetTagItem(key);
}
