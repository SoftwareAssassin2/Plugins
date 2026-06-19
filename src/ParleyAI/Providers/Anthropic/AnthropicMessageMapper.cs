using System.Collections.Generic;
using Anthropic.SDK.Messaging;
using ParleyAI.Abstractions;
using ParleyChatMessage = ParleyAI.Abstractions.ChatMessage;

namespace ParleyAI.Providers.Anthropic;

/// <summary>
/// Maps ParleyAI's provider-neutral chat shape onto the Anthropic SDK wire types and back.
/// </summary>
/// <remarks>
/// Anthropic's wire model has no <c>system</c> role inside the message list — a system instruction
/// is a top-level <c>system</c> field on <see cref="MessageParameters"/>. The
/// single-leading-<see cref="Role.System"/> rule is enforced and, when present, the leading system
/// message is hoisted to that top-level field while User/Assistant turns map to <see cref="RoleType"/>
/// entries in the SDK message list.
/// </remarks>
internal static class AnthropicMessageMapper
{
    /// <summary>The Anthropic API requires a positive <c>max_tokens</c>; used when the caller omits one.</summary>
    internal const int DefaultMaxTokens = 1024;

    /// <summary>
    /// Builds the SDK <see cref="MessageParameters"/> from the neutral request, enforcing the
    /// single-leading-<see cref="Role.System"/> rule and hoisting a leading system message to the
    /// top-level <c>system</c> field.
    /// </summary>
    /// <exception cref="ParleyAIException">
    /// <see cref="ParleyAIErrorCategory.InvalidRequest"/> when a system message appears more than
    /// once or in any non-leading position.
    /// </exception>
    public static MessageParameters MapRequest(ChatRequest request)
    {
        ValidateSingleLeadingSystem(request.Messages);

        var parameters = new MessageParameters
        {
            Model = request.Model,
            MaxTokens = request.MaxTokens ?? DefaultMaxTokens,
            Messages = new List<Message>(request.Messages.Count),
        };

        if (request.Temperature is double temperature)
        {
            parameters.Temperature = (decimal)temperature;
        }

        foreach (ParleyChatMessage message in request.Messages)
        {
            switch (message.Role)
            {
                case Role.System:
                    // Single, leading (validated above) → top-level `system`.
                    parameters.System = new List<SystemMessage> { new(message.Content, null) };
                    break;
                case Role.User:
                    parameters.Messages.Add(new Message(RoleType.User, message.Content, null));
                    break;
                case Role.Assistant:
                    parameters.Messages.Add(new Message(RoleType.Assistant, message.Content, null));
                    break;
                default:
                    throw new ParleyAIException(
                        $"Unsupported role '{message.Role}'.",
                        ParleyAIErrorCategory.InvalidRequest,
                        ProviderKeys.Anthropic);
            }
        }

        return parameters;
    }

    /// <summary>Maps the Anthropic SDK response onto the neutral response shape.</summary>
    public static ChatResponse MapResponse(MessageResponse response)
    {
        string content = response.FirstMessage?.Text ?? ExtractFirstText(response) ?? string.Empty;

        var usage = new TokenUsage(
            response.Usage?.InputTokens ?? 0,
            response.Usage?.OutputTokens ?? 0);

        return new ChatResponse(content, usage, MapFinishReason(response.StopReason));
    }

    internal static FinishReason MapFinishReason(string? stopReason) => stopReason switch
    {
        "end_turn" => FinishReason.Stop,
        "stop_sequence" => FinishReason.Stop,
        "tool_use" => FinishReason.Stop,
        "max_tokens" => FinishReason.Length,
        "refusal" => FinishReason.ContentFilter,
        _ => FinishReason.Unknown,
    };

    private static string? ExtractFirstText(MessageResponse response)
    {
        if (response.Content is null)
        {
            return null;
        }

        foreach (ContentBase block in response.Content)
        {
            if (block is TextContent text)
            {
                return text.Text;
            }
        }

        return null;
    }

    private static void ValidateSingleLeadingSystem(IReadOnlyList<ParleyChatMessage> messages)
    {
        for (int i = 0; i < messages.Count; i++)
        {
            if (messages[i].Role == Role.System && i != 0)
            {
                throw new ParleyAIException(
                    "A System message must be the single leading message; a System message was found in a non-leading position.",
                    ParleyAIErrorCategory.InvalidRequest,
                    ProviderKeys.Anthropic);
            }
        }
    }
}
