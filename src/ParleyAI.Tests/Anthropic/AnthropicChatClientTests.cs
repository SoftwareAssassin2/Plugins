using System;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using ParleyAI.Abstractions;
using ParleyAI.Providers.Anthropic;
using Xunit;

namespace ParleyAI.Tests.Anthropic;

/// <summary>
/// Wire-level tests for <see cref="AnthropicChatClient"/> over an in-process fake transport (no real
/// network / no fn-3 container). Covers: the origin-rewrite path (final scheme+host+path proven with
/// <c>http://localhost</c>), the SDK-default origin path, base-URL path rejection, role + the
/// single-leading-System rule (→ top-level <c>system</c>), the error→category mapping contract via
/// the named fixtures, RetryAfter, single-HTTP-attempt (no SDK retry layer), and cancellation
/// pass-through.
/// </summary>
public sealed class AnthropicChatClientTests
{
    /// <summary>
    /// Builds a client whose transport pipeline mirrors the DI composition: the origin-rewrite
    /// handler (configured with <paramref name="baseUrl"/>) sits ABOVE the fake primary handler, so
    /// the URI the fake records is the FINAL rewritten URI on the wire.
    /// </summary>
    private static AnthropicChatClient ClientOver(FakeHttpMessageHandler fake, string? baseUrl)
    {
        var rewrite = new AnthropicOriginRewriteHandler(baseUrl) { InnerHandler = fake };
        var httpClient = new HttpClient(rewrite);
        var settings = new AnthropicChatClientSettings { ApiKey = "sk-ant-test", BaseUrl = baseUrl };
        return new AnthropicChatClient(settings, httpClient);
    }

    private static ChatRequest SimpleRequest() => new(
        "claude-3-5-sonnet",
        new[]
        {
            new ChatMessage(Role.System, "be terse"),
            new ChatMessage(Role.User, "hi"),
        });

    [Fact]
    public async Task Base_url_override_rewrites_full_origin_to_v1_messages_no_double_v1()
    {
        var fake = new FakeHttpMessageHandler(_ => FakeHttpMessageHandler.Completion());
        AnthropicChatClient client = ClientOver(fake, "http://localhost:4010");

        ChatResponse response = await client.CompleteChatAsync(SimpleRequest());

        Assert.Equal("hello from fake", response.Content);
        Uri uri = Assert.Single(fake.RequestUris);
        // Full origin rewritten (scheme + host + port), SDK's /v1/messages path preserved — no double /v1.
        Assert.Equal("http", uri.Scheme);
        Assert.Equal("localhost", uri.Host);
        Assert.Equal(4010, uri.Port);
        Assert.Equal("/v1/messages", uri.AbsolutePath);
    }

    [Fact]
    public async Task Env_absent_base_url_targets_the_sdk_default_origin()
    {
        var fake = new FakeHttpMessageHandler(_ => FakeHttpMessageHandler.Completion());
        AnthropicChatClient client = ClientOver(fake, baseUrl: null);

        await client.CompleteChatAsync(SimpleRequest());

        Uri uri = Assert.Single(fake.RequestUris);
        Assert.Equal("https", uri.Scheme);
        // SDK default origin (not hardcoded by ParleyAI — supplied by Anthropic.SDK).
        Assert.Equal("api.anthropic.com", uri.Host);
        Assert.Equal("/v1/messages", uri.AbsolutePath);
    }

    [Fact]
    public async Task Leading_system_message_is_hoisted_and_request_succeeds()
    {
        // Round-trips a request with a single leading System message — it must be accepted and
        // mapped to the top-level `system` field (no `system` role exists in the message list).
        var fake = new FakeHttpMessageHandler(_ => FakeHttpMessageHandler.Completion("ok"));
        AnthropicChatClient client = ClientOver(fake, "http://localhost:4010");

        ChatResponse response = await client.CompleteChatAsync(SimpleRequest());

        Assert.Equal("ok", response.Content);
        Assert.Equal(1, fake.AttemptCount);
    }

    [Fact]
    public async Task Non_leading_system_message_is_rejected_before_any_http_attempt()
    {
        var fake = new FakeHttpMessageHandler(_ => FakeHttpMessageHandler.Completion());
        AnthropicChatClient client = ClientOver(fake, "http://localhost:4010");

        var bad = new ChatRequest(
            "claude-3-5-sonnet",
            new[]
            {
                new ChatMessage(Role.User, "hi"),
                new ChatMessage(Role.System, "late system"),
            });

        ParleyAIException ex = await Assert.ThrowsAsync<ParleyAIException>(
            () => client.CompleteChatAsync(bad));
        Assert.Equal(ParleyAIErrorCategory.InvalidRequest, ex.Category);
        Assert.Empty(fake.RequestUris);
    }

    [Fact]
    public async Task Error_429_token_limit_maps_to_TokenLimit_with_retry_after_seconds()
    {
        var fake = new FakeHttpMessageHandler(_ => AnthropicErrorFixtures.Anthropic429Tokens());
        AnthropicChatClient client = ClientOver(fake, "http://localhost:4010");

        ParleyAIException ex = await Assert.ThrowsAsync<ParleyAIException>(
            () => client.CompleteChatAsync(SimpleRequest()));

        Assert.Equal(ParleyAIErrorCategory.TokenLimit, ex.Category);
        Assert.Equal(System.Net.HttpStatusCode.TooManyRequests, ex.StatusCode);
        Assert.Equal(TimeSpan.FromSeconds(8), ex.RetryAfter);
        Assert.Equal(ProviderKeys.Anthropic, ex.ProviderKey);
    }

    [Fact]
    public async Task Error_429_request_limit_maps_to_RateLimit_with_retry_after()
    {
        var fake = new FakeHttpMessageHandler(_ => AnthropicErrorFixtures.Anthropic429Requests());
        AnthropicChatClient client = ClientOver(fake, "http://localhost:4010");

        ParleyAIException ex = await Assert.ThrowsAsync<ParleyAIException>(
            () => client.CompleteChatAsync(SimpleRequest()));

        Assert.Equal(ParleyAIErrorCategory.RateLimit, ex.Category);
        Assert.Equal(TimeSpan.FromSeconds(3), ex.RetryAfter);
    }

    [Fact]
    public async Task Error_401_maps_to_Authentication()
    {
        var fake = new FakeHttpMessageHandler(_ => AnthropicErrorFixtures.Anthropic401());
        AnthropicChatClient client = ClientOver(fake, "http://localhost:4010");

        ParleyAIException ex = await Assert.ThrowsAsync<ParleyAIException>(
            () => client.CompleteChatAsync(SimpleRequest()));

        Assert.Equal(ParleyAIErrorCategory.Authentication, ex.Category);
        Assert.Equal(System.Net.HttpStatusCode.Unauthorized, ex.StatusCode);
    }

    [Fact]
    public async Task Error_400_maps_to_InvalidRequest()
    {
        var fake = new FakeHttpMessageHandler(_ => AnthropicErrorFixtures.Anthropic400());
        AnthropicChatClient client = ClientOver(fake, "http://localhost:4010");

        ParleyAIException ex = await Assert.ThrowsAsync<ParleyAIException>(
            () => client.CompleteChatAsync(SimpleRequest()));

        Assert.Equal(ParleyAIErrorCategory.InvalidRequest, ex.Category);
        Assert.Equal(System.Net.HttpStatusCode.BadRequest, ex.StatusCode);
    }

    [Fact]
    public async Task Error_529_overloaded_maps_to_Transient_and_makes_exactly_one_http_attempt()
    {
        var fake = new FakeHttpMessageHandler(_ => AnthropicErrorFixtures.Anthropic529());
        AnthropicChatClient client = ClientOver(fake, "http://localhost:4010");

        ParleyAIException ex = await Assert.ThrowsAsync<ParleyAIException>(
            () => client.CompleteChatAsync(SimpleRequest()));

        Assert.Equal(ParleyAIErrorCategory.Transient, ex.Category);
        // The non-standard 529 (overloaded) status is preserved verbatim — not nulled — even though
        // it is not a defined HttpStatusCode member.
        Assert.Equal(529, (int)ex.StatusCode!.Value);
        // SINGLE attempt: Anthropic.SDK adds no retry layer and there is no resilience handler at
        // this task (fn-4.3). The resilience-on-vs-off test lives in fn-4.4.
        Assert.Equal(1, fake.AttemptCount);
    }

    [Fact]
    public async Task Error_500_maps_to_Transient()
    {
        var fake = new FakeHttpMessageHandler(_ => AnthropicErrorFixtures.Anthropic500());
        AnthropicChatClient client = ClientOver(fake, "http://localhost:4010");

        ParleyAIException ex = await Assert.ThrowsAsync<ParleyAIException>(
            () => client.CompleteChatAsync(SimpleRequest()));

        Assert.Equal(ParleyAIErrorCategory.Transient, ex.Category);
    }

    [Fact]
    public async Task Retryable_429_makes_exactly_one_http_attempt()
    {
        var fake = new FakeHttpMessageHandler(_ => AnthropicErrorFixtures.Anthropic429Requests());
        AnthropicChatClient client = ClientOver(fake, "http://localhost:4010");

        await Assert.ThrowsAsync<ParleyAIException>(() => client.CompleteChatAsync(SimpleRequest()));

        Assert.Equal(1, fake.AttemptCount);
    }

    [Fact]
    public async Task Cancellation_propagates_unwrapped()
    {
        var fake = new FakeHttpMessageHandler(_ => FakeHttpMessageHandler.Completion());
        AnthropicChatClient client = ClientOver(fake, "http://localhost:4010");

        using var cts = new CancellationTokenSource();
        cts.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(
            () => client.CompleteChatAsync(SimpleRequest(), cts.Token));
        // NOT wrapped in ParleyAIException.
    }

    [Fact]
    public async Task Transport_timeout_not_driven_by_caller_token_maps_to_Transient()
    {
        // A TaskCanceledException with NO caller cancellation = a transport timeout
        // (HttpClient.Timeout / SocketsHttpHandler), which must map to Transient — NOT pass through.
        var fake = new FakeHttpMessageHandler(_ =>
            throw new TaskCanceledException("The request was canceled due to the configured HttpClient.Timeout."));
        AnthropicChatClient client = ClientOver(fake, "http://localhost:4010");

        ParleyAIException ex = await Assert.ThrowsAsync<ParleyAIException>(
            () => client.CompleteChatAsync(SimpleRequest(), CancellationToken.None));

        Assert.Equal(ParleyAIErrorCategory.Transient, ex.Category);
        Assert.Equal(ProviderKeys.Anthropic, ex.ProviderKey);
    }

    [Fact]
    public void Missing_api_key_throws_at_construction()
    {
        var fake = new FakeHttpMessageHandler(_ => FakeHttpMessageHandler.Completion());
        var httpClient = new HttpClient(fake);

        Assert.Throws<ArgumentException>(() =>
            new AnthropicChatClient(new AnthropicChatClientSettings { ApiKey = "  " }, httpClient));
    }

    [Fact]
    public void Non_absolute_base_url_throws_at_construction()
    {
        var fake = new FakeHttpMessageHandler(_ => FakeHttpMessageHandler.Completion());
        var httpClient = new HttpClient(fake);

        Assert.Throws<ArgumentException>(() =>
            new AnthropicChatClient(
                new AnthropicChatClientSettings { ApiKey = "sk-ant", BaseUrl = "not-a-uri" },
                httpClient));
    }

    [Fact]
    public void Base_url_with_a_path_is_rejected_at_construction()
    {
        var fake = new FakeHttpMessageHandler(_ => FakeHttpMessageHandler.Completion());
        var httpClient = new HttpClient(fake);

        // Unlike OPENAI_BASE_URL, ANTHROPIC_BASE_URL must be the host ROOT — a path is rejected.
        Assert.Throws<ArgumentException>(() =>
            new AnthropicChatClient(
                new AnthropicChatClientSettings { ApiKey = "sk-ant", BaseUrl = "http://localhost:4010/v1" },
                httpClient));
    }
}
