using System.Collections.Generic;
using Anthropic.SDK.Messaging;
using ParleyAI.Abstractions;
using ParleyAI.Providers.Anthropic;
using Xunit;

namespace ParleyAI.Tests.Anthropic;

/// <summary>
/// Unit tests for <see cref="AnthropicMessageMapper"/> response mapping — in particular that a
/// multi-text-block Anthropic response is aggregated in order (not truncated to the first block).
/// </summary>
public sealed class AnthropicMessageMapperTests
{
    [Fact]
    public void MapResponse_concatenates_all_text_blocks_in_order()
    {
        var response = new MessageResponse
        {
            StopReason = "end_turn",
            Usage = new Usage { InputTokens = 7, OutputTokens = 9 },
            Content = new List<ContentBase>
            {
                new TextContent { Text = "Hello, " },
                new TextContent { Text = "world" },
                new TextContent { Text = "!" },
            },
        };

        ChatResponse mapped = AnthropicMessageMapper.MapResponse(response);

        Assert.Equal("Hello, world!", mapped.Content);
        Assert.Equal(7, mapped.Usage.InputTokens);
        Assert.Equal(9, mapped.Usage.OutputTokens);
        Assert.Equal(FinishReason.Stop, mapped.FinishReason);
    }

    [Fact]
    public void MapResponse_ignores_non_text_blocks_when_aggregating()
    {
        var response = new MessageResponse
        {
            StopReason = "max_tokens",
            Usage = new Usage { InputTokens = 1, OutputTokens = 2 },
            Content = new List<ContentBase>
            {
                new TextContent { Text = "answer" },
                new RedactedThinkingContent { Data = "opaque" },
            },
        };

        ChatResponse mapped = AnthropicMessageMapper.MapResponse(response);

        Assert.Equal("answer", mapped.Content);
        Assert.Equal(FinishReason.Length, mapped.FinishReason);
    }

    [Fact]
    public void MapResponse_empty_content_yields_empty_string()
    {
        var response = new MessageResponse
        {
            StopReason = "end_turn",
            Usage = new Usage { InputTokens = 0, OutputTokens = 0 },
            Content = new List<ContentBase>(),
        };

        ChatResponse mapped = AnthropicMessageMapper.MapResponse(response);

        Assert.Equal(string.Empty, mapped.Content);
    }
}
