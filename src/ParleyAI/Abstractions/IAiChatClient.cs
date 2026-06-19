using System.Threading;
using System.Threading.Tasks;

namespace ParleyAI.Abstractions;

/// <summary>
/// The provider-neutral v1 non-streaming chat client surface.
/// </summary>
/// <remarks>
/// This is ParleyAI's minimal, owned abstraction (no Microsoft.Extensions.AI
/// dependency). Its public surface carries no provider-SDK types. Each provider
/// implementation, the AIMD decorator, and the DI factory all expose this single
/// interface.
/// </remarks>
public interface IAiChatClient
{
    /// <summary>
    /// Sends a non-streaming chat request and returns the completion.
    /// </summary>
    /// <param name="request">The provider-neutral chat request.</param>
    /// <param name="cancellationToken">
    /// A token to cancel the in-flight operation. Cancellation surfaces as an
    /// <see cref="System.OperationCanceledException"/> and is NOT wrapped in a
    /// <see cref="ParleyAIException"/>.
    /// </param>
    /// <returns>The provider-neutral chat response.</returns>
    /// <exception cref="ParleyAIException">
    /// Thrown for any provider/SDK failure, carrying a
    /// <see cref="ParleyAIErrorCategory"/> classification.
    /// </exception>
    Task<ChatResponse> CompleteChatAsync(
        ChatRequest request,
        CancellationToken cancellationToken = default);
}
