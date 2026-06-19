using System;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using ParleyAI.Abstractions;
using ParleyAI.Providers.OpenAi;
using Xunit;

namespace ParleyAI.Tests.OpenAi;

/// <summary>
/// Wire-level tests for <see cref="OpenAiChatClient"/> over an in-process fake transport
/// (no real network / no fn-3 container). Covers: the base-URL override path (final scheme+path),
/// the SDK-default path, role + single-leading-System, the error→category mapping contract via the
/// named fixtures, RetryAfter, single-HTTP-attempt (SDK retry disabled), and cancellation pass-through.
/// </summary>
public sealed class OpenAiChatClientTests
{
    private static OpenAiChatClient ClientOver(FakeHttpMessageHandler handler, string? baseUrl)
    {
        var httpClient = new HttpClient(handler);
        var settings = new OpenAiChatClientSettings { ApiKey = "sk-test", BaseUrl = baseUrl };
        return new OpenAiChatClient(settings, httpClient);
    }

    private static ChatRequest SimpleRequest() => new(
        "gpt-4o",
        new[]
        {
            new ChatMessage(Role.System, "be terse"),
            new ChatMessage(Role.User, "hi"),
        });

    [Fact]
    public async Task Base_url_override_is_used_verbatim_with_v1_chat_completions_no_double_v1()
    {
        var handler = new FakeHttpMessageHandler(_ => FakeHttpMessageHandler.Completion());
        OpenAiChatClient client = ClientOver(handler, "http://localhost:4010/v1");

        ChatResponse response = await client.CompleteChatAsync(SimpleRequest());

        Assert.Equal("hello from fake", response.Content);
        Uri uri = Assert.Single(handler.RequestUris);
        Assert.Equal("http", uri.Scheme);
        Assert.Equal("localhost", uri.Host);
        Assert.Equal(4010, uri.Port);
        // No double /v1 — the verbatim base URL already carries /v1.
        Assert.Equal("/v1/chat/completions", uri.AbsolutePath);
    }

    [Fact]
    public async Task Env_absent_base_url_targets_the_sdk_default_host()
    {
        var handler = new FakeHttpMessageHandler(_ => FakeHttpMessageHandler.Completion());
        OpenAiChatClient client = ClientOver(handler, baseUrl: null);

        await client.CompleteChatAsync(SimpleRequest());

        Uri uri = Assert.Single(handler.RequestUris);
        Assert.Equal("https", uri.Scheme);
        // SDK default host (not hardcoded by ParleyAI — supplied by the OpenAI SDK).
        Assert.Equal("api.openai.com", uri.Host);
        Assert.Equal("/v1/chat/completions", uri.AbsolutePath);
    }

    [Fact]
    public async Task Single_leading_system_is_allowed_but_non_leading_system_is_rejected()
    {
        var handler = new FakeHttpMessageHandler(_ => FakeHttpMessageHandler.Completion());
        OpenAiChatClient client = ClientOver(handler, "http://localhost:4010/v1");

        var bad = new ChatRequest(
            "gpt-4o",
            new[]
            {
                new ChatMessage(Role.User, "hi"),
                new ChatMessage(Role.System, "late system"),
            });

        ParleyAIException ex = await Assert.ThrowsAsync<ParleyAIException>(
            () => client.CompleteChatAsync(bad));
        Assert.Equal(ParleyAIErrorCategory.InvalidRequest, ex.Category);
        // Rejected before any HTTP attempt.
        Assert.Empty(handler.RequestUris);
    }

    [Fact]
    public async Task Error_429_token_limit_maps_to_TokenLimit_with_retry_after_seconds()
    {
        var handler = new FakeHttpMessageHandler(_ => OpenAiErrorFixtures.Openai429Tpm());
        OpenAiChatClient client = ClientOver(handler, "http://localhost:4010/v1");

        ParleyAIException ex = await Assert.ThrowsAsync<ParleyAIException>(
            () => client.CompleteChatAsync(SimpleRequest()));

        Assert.Equal(ParleyAIErrorCategory.TokenLimit, ex.Category);
        Assert.Equal(System.Net.HttpStatusCode.TooManyRequests, ex.StatusCode);
        Assert.Equal(TimeSpan.FromSeconds(8), ex.RetryAfter);
        Assert.Equal(ProviderKeys.OpenAi, ex.ProviderKey);
    }

    [Fact]
    public async Task Error_429_token_limit_via_error_code_maps_to_TokenLimit()
    {
        // No x-ratelimit-remaining-tokens header — only a machine code variant in the body.
        var handler = new FakeHttpMessageHandler(_ => OpenAiErrorFixtures.Openai429TpmCodeOnly());
        OpenAiChatClient client = ClientOver(handler, "http://localhost:4010/v1");

        ParleyAIException ex = await Assert.ThrowsAsync<ParleyAIException>(
            () => client.CompleteChatAsync(SimpleRequest()));

        Assert.Equal(ParleyAIErrorCategory.TokenLimit, ex.Category);
    }

    [Fact]
    public async Task Error_429_request_limit_maps_to_RateLimit_with_retry_after_ms()
    {
        var handler = new FakeHttpMessageHandler(_ => OpenAiErrorFixtures.Openai429Rpm());
        OpenAiChatClient client = ClientOver(handler, "http://localhost:4010/v1");

        ParleyAIException ex = await Assert.ThrowsAsync<ParleyAIException>(
            () => client.CompleteChatAsync(SimpleRequest()));

        Assert.Equal(ParleyAIErrorCategory.RateLimit, ex.Category);
        Assert.Equal(TimeSpan.FromMilliseconds(1500), ex.RetryAfter);
    }

    [Fact]
    public async Task Error_401_maps_to_Authentication()
    {
        var handler = new FakeHttpMessageHandler(_ => OpenAiErrorFixtures.Openai401());
        OpenAiChatClient client = ClientOver(handler, "http://localhost:4010/v1");

        ParleyAIException ex = await Assert.ThrowsAsync<ParleyAIException>(
            () => client.CompleteChatAsync(SimpleRequest()));

        Assert.Equal(ParleyAIErrorCategory.Authentication, ex.Category);
        Assert.Equal(System.Net.HttpStatusCode.Unauthorized, ex.StatusCode);
    }

    [Fact]
    public async Task Error_400_maps_to_InvalidRequest()
    {
        var handler = new FakeHttpMessageHandler(_ => OpenAiErrorFixtures.Openai400());
        OpenAiChatClient client = ClientOver(handler, "http://localhost:4010/v1");

        ParleyAIException ex = await Assert.ThrowsAsync<ParleyAIException>(
            () => client.CompleteChatAsync(SimpleRequest()));

        Assert.Equal(ParleyAIErrorCategory.InvalidRequest, ex.Category);
    }

    [Fact]
    public async Task Error_500_maps_to_Transient_and_makes_exactly_one_http_attempt()
    {
        var handler = new FakeHttpMessageHandler(_ => OpenAiErrorFixtures.Openai500());
        OpenAiChatClient client = ClientOver(handler, "http://localhost:4010/v1");

        ParleyAIException ex = await Assert.ThrowsAsync<ParleyAIException>(
            () => client.CompleteChatAsync(SimpleRequest()));

        Assert.Equal(ParleyAIErrorCategory.Transient, ex.Category);
        // SINGLE attempt: the SDK-native retry of 5xx is disabled and there is no resilience
        // handler at this task (fn-4.2). The resilience-on-vs-off test lives in fn-4.4.
        Assert.Equal(1, handler.AttemptCount);
    }

    [Fact]
    public async Task Retryable_429_makes_exactly_one_http_attempt()
    {
        var handler = new FakeHttpMessageHandler(_ => OpenAiErrorFixtures.Openai429Rpm());
        OpenAiChatClient client = ClientOver(handler, "http://localhost:4010/v1");

        await Assert.ThrowsAsync<ParleyAIException>(() => client.CompleteChatAsync(SimpleRequest()));

        Assert.Equal(1, handler.AttemptCount);
    }

    [Fact]
    public async Task Cancellation_propagates_unwrapped()
    {
        var handler = new FakeHttpMessageHandler(_ => FakeHttpMessageHandler.Completion());
        OpenAiChatClient client = ClientOver(handler, "http://localhost:4010/v1");

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
        var handler = new FakeHttpMessageHandler(_ =>
            throw new TaskCanceledException("The request was canceled due to the configured HttpClient.Timeout."));
        OpenAiChatClient client = ClientOver(handler, "http://localhost:4010/v1");

        ParleyAIException ex = await Assert.ThrowsAsync<ParleyAIException>(
            () => client.CompleteChatAsync(SimpleRequest(), CancellationToken.None));

        Assert.Equal(ParleyAIErrorCategory.Transient, ex.Category);
        Assert.Equal(ProviderKeys.OpenAi, ex.ProviderKey);
    }

    [Fact]
    public async Task Missing_api_key_throws_at_construction()
    {
        var handler = new FakeHttpMessageHandler(_ => FakeHttpMessageHandler.Completion());
        var httpClient = new HttpClient(handler);

        Assert.Throws<ArgumentException>(() =>
            new OpenAiChatClient(new OpenAiChatClientSettings { ApiKey = "  " }, httpClient));
    }

    [Fact]
    public void Non_absolute_base_url_throws_at_construction()
    {
        var handler = new FakeHttpMessageHandler(_ => FakeHttpMessageHandler.Completion());
        var httpClient = new HttpClient(handler);

        Assert.Throws<ArgumentException>(() =>
            new OpenAiChatClient(
                new OpenAiChatClientSettings { ApiKey = "sk-test", BaseUrl = "not-a-uri/v1" },
                httpClient));
    }
}
