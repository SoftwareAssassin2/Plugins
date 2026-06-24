using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using ParleyAI.Abstractions;

namespace ParleyAI.Telemetry;

/// <summary>
/// Wraps a provider chat call with OpenTelemetry GenAI instrumentation: a <c>chat {model}</c> span on
/// <see cref="ParleyAiTelemetry.ActivitySource"/> carrying the <c>gen_ai.*</c> request/response
/// attributes, plus the two pinned metric instruments (operation duration + token usage).
/// </summary>
/// <remarks>
/// <para>
/// The recorder is instrumentation INSIDE the provider client (not a decorator) so it never competes
/// with the single AIMD decoration hook. It is allocated once per provider client with the provider's
/// <c>gen_ai.provider.name</c> value and the (gated, default-off) content-capture flag, and invoked per
/// call via <see cref="RecordAsync"/>.
/// </para>
/// <para>
/// Duration is ALWAYS measured (a cheap <see cref="Stopwatch"/>); the histograms/span are no-ops when
/// no listener is attached, so the wrapper is safe to run unconditionally. Cancellation
/// (<see cref="OperationCanceledException"/>) is recorded with <c>error.type=cancelled</c> and
/// re-thrown un-wrapped — it is NOT swallowed.
/// </para>
/// </remarks>
internal sealed class ChatTelemetryRecorder
{
    private readonly string _providerName;
    private readonly bool _captureContent;

    /// <summary>Creates a recorder bound to a provider's <c>gen_ai.provider.name</c> + capture policy.</summary>
    /// <param name="providerName">
    /// The <c>gen_ai.provider.name</c> value (<see cref="GenAiAttributes.ProviderOpenAi"/> /
    /// <see cref="GenAiAttributes.ProviderAnthropic"/>).
    /// </param>
    /// <param name="captureContent">
    /// Whether to capture message content as span attributes (gated; default off in the options).
    /// </param>
    internal ChatTelemetryRecorder(string providerName, bool captureContent)
    {
        _providerName = providerName;
        _captureContent = captureContent;
    }

    /// <summary>
    /// Runs <paramref name="operation"/> under a GenAI chat span + metrics. Re-throws whatever the
    /// operation throws (un-wrapped) after recording it; the recorder never changes the call's outcome.
    /// </summary>
    internal async Task<ChatResponse> RecordAsync(
        ChatRequest request,
        Func<CancellationToken, Task<ChatResponse>> operation,
        CancellationToken cancellationToken)
    {
        // The span name is `chat {model}` per the GenAI semconv. Client kind: ParleyAI is the caller of
        // the provider API.
        using Activity? activity = ParleyAiTelemetry.ActivitySource.StartActivity(
            $"{GenAiAttributes.OperationChat} {request.Model}",
            ActivityKind.Client);

        SetRequestAttributes(activity, request);

        long startTimestamp = Stopwatch.GetTimestamp();
        try
        {
            ChatResponse response = await operation(cancellationToken).ConfigureAwait(false);

            RecordDuration(startTimestamp, errorType: null);
            SetResponseAttributes(activity, response);
            RecordTokenUsage(response.Usage);
            activity?.SetStatus(ActivityStatusCode.Ok);
            return response;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // Cooperative cancellation: record it as a distinct error type, then re-throw un-wrapped.
            RecordFailure(activity, startTimestamp, "cancelled", description: "Operation cancelled.");
            throw;
        }
        catch (ParleyAIException ex)
        {
            RecordFailure(activity, startTimestamp, ErrorTypeFor(ex), ex.Message);
            throw;
        }
        catch (Exception ex)
        {
            RecordFailure(activity, startTimestamp, ex.GetType().FullName ?? "error", ex.Message);
            throw;
        }
    }

    private void SetRequestAttributes(Activity? activity, ChatRequest request)
    {
        if (activity is null)
        {
            return;
        }

        activity.SetTag(GenAiAttributes.OperationName, GenAiAttributes.OperationChat);
        activity.SetTag(GenAiAttributes.ProviderName, _providerName);
        activity.SetTag(GenAiAttributes.RequestModel, request.Model);

        if (request.MaxTokens is int maxTokens)
        {
            activity.SetTag(GenAiAttributes.RequestMaxTokens, maxTokens);
        }

        if (request.Temperature is double temperature)
        {
            activity.SetTag(GenAiAttributes.RequestTemperature, temperature);
        }

        if (_captureContent)
        {
            activity.SetTag(GenAiAttributes.InputMessages, RenderInputMessages(request.Messages));
        }
    }

    private void SetResponseAttributes(Activity? activity, ChatResponse response)
    {
        if (activity is null)
        {
            return;
        }

        // finish_reasons is an array per semconv — one element for v1 non-streaming chat.
        activity.SetTag(GenAiAttributes.ResponseFinishReasons, new[] { FinishReasonValue(response.FinishReason) });
        activity.SetTag(GenAiAttributes.UsageInputTokens, response.Usage.InputTokens);
        activity.SetTag(GenAiAttributes.UsageOutputTokens, response.Usage.OutputTokens);

        if (_captureContent)
        {
            activity.SetTag(GenAiAttributes.OutputMessages, response.Content);
        }
    }

    private void RecordFailure(Activity? activity, long startTimestamp, string errorType, string description)
    {
        RecordDuration(startTimestamp, errorType);
        if (activity is not null)
        {
            activity.SetTag(GenAiAttributes.ErrorType, errorType);
            activity.SetStatus(ActivityStatusCode.Error, description);
        }
    }

    private void RecordDuration(long startTimestamp, string? errorType)
    {
        if (!ParleyAiTelemetry.OperationDuration.Enabled)
        {
            return;
        }

        double seconds = Stopwatch.GetElapsedTime(startTimestamp).TotalSeconds;
        ParleyAiTelemetry.OperationDuration.Record(seconds, OperationTags(errorType));
    }

    private void RecordTokenUsage(TokenUsage usage)
    {
        if (!ParleyAiTelemetry.TokenUsage.Enabled)
        {
            return;
        }

        ParleyAiTelemetry.TokenUsage.Record(usage.InputTokens, TokenTags(GenAiAttributes.TokenTypeInput));
        ParleyAiTelemetry.TokenUsage.Record(usage.OutputTokens, TokenTags(GenAiAttributes.TokenTypeOutput));
    }

    private TagList OperationTags(string? errorType)
    {
        var tags = new TagList
        {
            { GenAiAttributes.OperationName, GenAiAttributes.OperationChat },
            { GenAiAttributes.ProviderName, _providerName },
        };
        if (errorType is not null)
        {
            tags.Add(GenAiAttributes.ErrorType, errorType);
        }

        return tags;
    }

    private TagList TokenTags(string tokenType) => new()
    {
        { GenAiAttributes.OperationName, GenAiAttributes.OperationChat },
        { GenAiAttributes.ProviderName, _providerName },
        { GenAiAttributes.TokenType, tokenType },
    };

    /// <summary>Maps a mapped <see cref="ParleyAIException"/> category onto the <c>error.type</c> value.</summary>
    private static string ErrorTypeFor(ParleyAIException ex) => ex.Category switch
    {
        ParleyAIErrorCategory.RateLimit => "rate_limit",
        ParleyAIErrorCategory.TokenLimit => "token_limit",
        ParleyAIErrorCategory.Authentication => "authentication",
        ParleyAIErrorCategory.InvalidRequest => "invalid_request",
        ParleyAIErrorCategory.Transient => "transient",
        _ => "unknown",
    };

    private static string FinishReasonValue(FinishReason reason) => reason switch
    {
        FinishReason.Stop => "stop",
        FinishReason.Length => "length",
        FinishReason.ContentFilter => "content_filter",
        _ => "unknown",
    };

    private static string RenderInputMessages(IReadOnlyList<ChatMessage> messages)
    {
        var builder = new StringBuilder();
        for (int i = 0; i < messages.Count; i++)
        {
            if (i > 0)
            {
                builder.Append('\n');
            }

            ChatMessage message = messages[i];
            builder.Append(message.Role.ToString().ToLower(CultureInfo.InvariantCulture));
            builder.Append(": ");
            builder.Append(message.Content);
        }

        return builder.ToString();
    }
}
