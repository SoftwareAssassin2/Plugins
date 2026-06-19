using System;
using System.Threading;
using System.Threading.Tasks;
using ParleyAI.Abstractions;

namespace ParleyAI.RateLimiting;

/// <summary>
/// An <see cref="IAiChatClient"/> decorator that paces logical calls through a per-provider
/// <see cref="AimdRateController"/>: it acquires a request permit before delegating, ramps the
/// allowed rate on success, and backs the rate off on a mapped <see cref="ParleyAIException"/> whose
/// category is <see cref="ParleyAIErrorCategory.RateLimit"/> / <see cref="ParleyAIErrorCategory.TokenLimit"/>.
/// </summary>
/// <remarks>
/// <para>
/// It sits ABOVE the HTTP/resilience pipeline (it wraps the bare concrete provider client, not an
/// <c>HttpMessageHandler</c>) so it reacts to the FINAL mapped outcome — the resilience handler has
/// already exhausted its transient retries and surfaced the rate-limit signal as a
/// <see cref="ParleyAIException"/>. There is no inside/outside-retry ambiguity.
/// </para>
/// <para>
/// <see cref="OperationCanceledException"/> passes through un-touched (cooperative cancellation is not
/// a provider fault and must not drive a back-off). A non-limit <see cref="ParleyAIException"/>
/// (Authentication / InvalidRequest / Transient / Unknown) is re-thrown WITHOUT a rate change — only
/// the two limit categories steer the pacer.
/// </para>
/// </remarks>
public sealed class AimdChatClientDecorator : IAiChatClient
{
    private readonly IAiChatClient _inner;
    private readonly AimdRateController _controller;

    /// <summary>
    /// Wraps <paramref name="inner"/> with the AIMD pacer driven by <paramref name="controller"/>.
    /// </summary>
    /// <param name="inner">The bare provider client to pace.</param>
    /// <param name="controller">The per-provider AIMD rate controller.</param>
    public AimdChatClientDecorator(IAiChatClient inner, AimdRateController controller)
    {
        ArgumentNullException.ThrowIfNull(inner);
        ArgumentNullException.ThrowIfNull(controller);

        _inner = inner;
        _controller = controller;
    }

    /// <summary>The wrapped bare provider client (exposed for assertions/diagnostics).</summary>
    public IAiChatClient Inner => _inner;

    /// <inheritdoc />
    public async Task<ChatResponse> CompleteChatAsync(
        ChatRequest request,
        CancellationToken cancellationToken = default)
    {
        await _controller.AcquireAsync(cancellationToken).ConfigureAwait(false);

        try
        {
            ChatResponse response = await _inner.CompleteChatAsync(request, cancellationToken).ConfigureAwait(false);
            _controller.OnSuccess();
            return response;
        }
        catch (ParleyAIException ex) when (
            ex.Category is ParleyAIErrorCategory.RateLimit or ParleyAIErrorCategory.TokenLimit)
        {
            // A mapped limit signal — back the pacer off (one decrease/cooldown window) and re-throw.
            _controller.OnBackoff(ex.Category, ex.RetryAfter);
            throw;
        }

        // Non-limit ParleyAIException and OperationCanceledException are NOT caught here: they
        // propagate without altering the rate (cancellation/auth/invalid-request are not pacing signals).
    }
}
