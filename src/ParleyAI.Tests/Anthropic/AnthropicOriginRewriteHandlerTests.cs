using System;
using ParleyAI.Providers.Anthropic;
using Xunit;

namespace ParleyAI.Tests.Anthropic;

/// <summary>
/// Unit tests for the root-only base-URL validation enforced by
/// <see cref="AnthropicOriginRewriteHandler"/> (the structural-presence contract for
/// <c>ANTHROPIC_BASE_URL</c>). The wire behavior (origin rewrite, error capture) is exercised
/// end-to-end in <see cref="AnthropicChatClientTests"/>.
/// </summary>
public sealed class AnthropicOriginRewriteHandlerTests
{
    [Theory]
    [InlineData("http://localhost:4010")]
    [InlineData("https://api.example.com")]
    [InlineData("http://localhost:4010/")] // a bare trailing slash is the root
    public void Root_only_base_urls_are_accepted(string baseUrl)
    {
        Uri origin = AnthropicOriginRewriteHandler.ParseRootOnly(baseUrl);
        Assert.True(origin.IsAbsoluteUri);
    }

    [Theory]
    [InlineData("not-a-uri")]
    [InlineData("/v1/messages")]            // relative
    [InlineData("http://localhost:4010/v1")] // path beyond root (the OpenAI shape, invalid here)
    [InlineData("http://localhost:4010/v1/messages")]
    [InlineData("http://localhost:4010?x=1")] // query
    [InlineData("http://localhost:4010/#frag")] // fragment
    [InlineData("ftp://example.com/")]          // non-http(s) scheme HttpClient cannot send
    [InlineData("ws://localhost:4010")]         // non-http(s) scheme
    public void Non_root_base_urls_are_rejected(string baseUrl)
    {
        Assert.Throws<ArgumentException>(() => AnthropicOriginRewriteHandler.ParseRootOnly(baseUrl));
    }

    [Fact]
    public void Null_or_blank_base_url_makes_the_handler_a_pass_through()
    {
        // No throw: a null/blank base URL means "use the SDK default origin" (handler is inert).
        _ = new AnthropicOriginRewriteHandler(null);
        _ = new AnthropicOriginRewriteHandler("   ");
    }
}
