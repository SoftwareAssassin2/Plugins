using System;
using System.ClientModel;
using System.ClientModel.Primitives;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using OpenAI;
using OpenAI.Chat;
using ParleyAI.Abstractions;
using OpenAiChatMessage = OpenAI.Chat.ChatMessage;

namespace ParleyAI.Providers.OpenAi;

/// <summary>
/// The OpenAI implementation of <see cref="IAiChatClient"/>, built over the official
/// OpenAI .NET SDK.
/// </summary>
/// <remarks>
/// <para>
/// The injected (keyed, singleton-safe) <see cref="HttpClient"/> is wired into the SDK as the
/// pipeline <c>Transport</c> via a <see cref="HttpClientPipelineTransport"/>, so the resilience
/// pipeline (fn-4.4) attaches once to that named client.
/// </para>
/// <para>
/// <b>Base-URL override:</b> when an <see cref="OpenAiChatClientSettings.BaseUrl"/> is supplied
/// it is set verbatim as <see cref="OpenAIClientOptions.Endpoint"/> (the <c>/v1</c> suffix is
/// kept) and validated as an absolute URI at construction. When absent the SDK default endpoint
/// applies — ParleyAI never hardcodes <c>api.openai.com</c>.
/// </para>
/// <para>
/// <b>Single retry authority:</b> the SDK's built-in pipeline retry is disabled (the pipeline
/// <c>RetryPolicy</c> = <c>new ClientRetryPolicy(maxRetries: 0)</c>) so a logical call makes
/// exactly ONE HTTP attempt. The resilience handler (fn-4.4) is the only
/// retry layer; the AIMD optimizer reacts to the final mapped error.
/// </para>
/// </remarks>
public sealed class OpenAiChatClient : IAiChatClient
{
    private readonly ChatClient? _explicitModelClient;
    private readonly Func<string, ChatClient> _clientForModel;

    /// <summary>
    /// Constructs the client from resolved settings + the keyed transport <see cref="HttpClient"/>.
    /// </summary>
    /// <param name="settings">
    /// The resolved connection settings (required API key + optional verbatim base URL), already
    /// having applied the ctor &gt; flat-key precedence in the DI layer.
    /// </param>
    /// <param name="httpClient">The keyed, singleton-safe transport <see cref="HttpClient"/>.</param>
    /// <exception cref="ArgumentException">
    /// The API key is missing/blank, or the base URL is present but not an absolute URI.
    /// </exception>
    public OpenAiChatClient(OpenAiChatClientSettings settings, HttpClient httpClient)
    {
        ArgumentNullException.ThrowIfNull(settings);
        ArgumentNullException.ThrowIfNull(httpClient);

        if (string.IsNullOrWhiteSpace(settings.ApiKey))
        {
            throw new ArgumentException(
                "An OpenAI API key is required (ctor override or the flat OPENAI_API_KEY config key); there is no SDK-default key.",
                nameof(settings));
        }

        OpenAIClientOptions options = BuildOptions(settings, httpClient);
        var credential = new ApiKeyCredential(settings.ApiKey);

        // One OpenAIClient; ChatClient is created per request model (cheap, shares the pipeline).
        var openAiClient = new OpenAIClient(credential, options);
        _clientForModel = model => openAiClient.GetChatClient(model);
    }

    /// <summary>Test/advanced seam: inject a pre-built <see cref="ChatClient"/> directly.</summary>
    internal OpenAiChatClient(ChatClient chatClient)
    {
        _explicitModelClient = chatClient ?? throw new ArgumentNullException(nameof(chatClient));
        _clientForModel = _ => _explicitModelClient;
    }

    /// <inheritdoc />
    public async Task<ChatResponse> CompleteChatAsync(
        ChatRequest request,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);

        // Validation + role mapping (throws InvalidRequest for the single-leading-System rule).
        var messages = OpenAiMessageMapper.MapMessages(request.Messages);
        ChatCompletionOptions completionOptions = BuildCompletionOptions(request);
        ChatClient chatClient = _clientForModel(request.Model);

        try
        {
            ClientResult<ChatCompletion> result =
                await chatClient.CompleteChatAsync(messages, completionOptions, cancellationToken)
                    .ConfigureAwait(false);
            return OpenAiMessageMapper.MapResponse(result.Value);
        }
        catch (OperationCanceledException)
        {
            // Cooperative cancellation propagates un-wrapped.
            throw;
        }
        catch (ClientResultException ex)
        {
            throw OpenAiErrorMapper.Map(ex);
        }
        catch (HttpRequestException ex)
        {
            throw OpenAiErrorMapper.Map(ex);
        }
        catch (ParleyAIException)
        {
            // Mapping/validation already produced a neutral exception — surface as-is.
            throw;
        }
        catch (Exception ex)
        {
            throw OpenAiErrorMapper.MapUnknown(ex);
        }
    }

    private static ChatCompletionOptions BuildCompletionOptions(ChatRequest request)
    {
        var options = new ChatCompletionOptions();
        if (request.MaxTokens is int maxTokens)
        {
            options.MaxOutputTokenCount = maxTokens;
        }

        if (request.Temperature is double temperature)
        {
            options.Temperature = (float)temperature;
        }

        return options;
    }

    private static OpenAIClientOptions BuildOptions(OpenAiChatClientSettings settings, HttpClient httpClient)
    {
        var options = new OpenAIClientOptions
        {
            // Inject the keyed HttpClient as the SDK transport so resilience (fn-4.4) attaches once.
            Transport = new HttpClientPipelineTransport(httpClient),

            // Single retry authority: disable the SDK's pipeline-level retry of 408/429/5xx.
            // Confirmed against OpenAI 2.11.0 + System.ClientModel: RetryPolicy lives on
            // ClientPipelineOptions; ClientRetryPolicy(maxRetries: 0) yields exactly one attempt.
            RetryPolicy = new ClientRetryPolicy(maxRetries: 0),
        };

        if (!string.IsNullOrWhiteSpace(settings.BaseUrl))
        {
            if (!Uri.TryCreate(settings.BaseUrl, UriKind.Absolute, out Uri? endpoint))
            {
                throw new ArgumentException(
                    $"OPENAI_BASE_URL must be an absolute URI; got '{settings.BaseUrl}'.",
                    nameof(settings));
            }

            // Verbatim: the /v1 suffix (per the fn-3 contract) is preserved.
            options.Endpoint = endpoint;
        }

        return options;
    }
}
