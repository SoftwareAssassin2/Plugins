using System.Collections.Generic;
using OpenAI.Chat;
using ParleyAI.Abstractions;
using OpenAiChatMessage = OpenAI.Chat.ChatMessage;
using ParleyChatMessage = ParleyAI.Abstractions.ChatMessage;

namespace ParleyAI.Providers.OpenAi;

/// <summary>
/// Maps ParleyAI's provider-neutral chat shape onto the OpenAI SDK wire types and back.
/// </summary>
internal static class OpenAiMessageMapper
{
    /// <summary>
    /// Maps the neutral messages onto OpenAI SDK messages, enforcing the
    /// single-leading-<see cref="Role.System"/> rule.
    /// </summary>
    /// <exception cref="ParleyAIException">
    /// <see cref="ParleyAIErrorCategory.InvalidRequest"/> when a system message appears more
    /// than once or in any non-leading position.
    /// </exception>
    public static List<OpenAiChatMessage> MapMessages(IReadOnlyList<ParleyChatMessage> messages)
    {
        ValidateSingleLeadingSystem(messages);

        var mapped = new List<OpenAiChatMessage>(messages.Count);
        foreach (ParleyChatMessage message in messages)
        {
            mapped.Add(message.Role switch
            {
                Role.System => new SystemChatMessage(message.Content),
                Role.User => new UserChatMessage(message.Content),
                Role.Assistant => new AssistantChatMessage(message.Content),
                _ => throw new ParleyAIException(
                    $"Unsupported role '{message.Role}'.",
                    ParleyAIErrorCategory.InvalidRequest,
                    ProviderKeys.OpenAi),
            });
        }

        return mapped;
    }

    /// <summary>Maps the OpenAI SDK completion onto the neutral response shape.</summary>
    public static ChatResponse MapResponse(ChatCompletion completion)
    {
        string content = completion.Content.Count > 0 ? completion.Content[0].Text ?? string.Empty : string.Empty;

        var usage = new TokenUsage(
            completion.Usage?.InputTokenCount ?? 0,
            completion.Usage?.OutputTokenCount ?? 0);

        return new ChatResponse(content, usage, MapFinishReason(completion.FinishReason));
    }

    internal static FinishReason MapFinishReason(ChatFinishReason reason) => reason switch
    {
        ChatFinishReason.Stop => FinishReason.Stop,
        ChatFinishReason.Length => FinishReason.Length,
        ChatFinishReason.ContentFilter => FinishReason.ContentFilter,
        _ => FinishReason.Unknown,
    };

    private static void ValidateSingleLeadingSystem(IReadOnlyList<ParleyChatMessage> messages)
    {
        for (int i = 0; i < messages.Count; i++)
        {
            if (messages[i].Role == Role.System && i != 0)
            {
                throw new ParleyAIException(
                    "A System message must be the single leading message; a System message was found in a non-leading position.",
                    ParleyAIErrorCategory.InvalidRequest,
                    ProviderKeys.OpenAi);
            }
        }
    }
}
