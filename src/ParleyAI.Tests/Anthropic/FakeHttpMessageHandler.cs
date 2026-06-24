using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace ParleyAI.Tests.Anthropic;

/// <summary>
/// An in-process fake <see cref="HttpMessageHandler"/> that records every request URI and returns
/// canned responses. Mirrors the LiteLLM ai-mock surface (unified <c>/v1/messages</c>) enough to
/// exercise the Anthropic provider WITHOUT a real network or fn-3 container. It sits at the BOTTOM
/// of the keyed pipeline (the primary handler), so the request URI it records is the FINAL,
/// origin-rewritten URI the provider would put on the wire.
/// </summary>
internal sealed class FakeHttpMessageHandler : HttpMessageHandler
{
    private readonly Func<HttpRequestMessage, HttpResponseMessage> _responder;

    public FakeHttpMessageHandler(Func<HttpRequestMessage, HttpResponseMessage> responder) =>
        _responder = responder;

    /// <summary>Every request URI seen, in order — used to assert the final scheme + host + path.</summary>
    public List<Uri> RequestUris { get; } = new();

    /// <summary>Total send attempts — proves single-attempt behavior (no SDK retry layer).</summary>
    public int AttemptCount => RequestUris.Count;

    protected override Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        RequestUris.Add(request.RequestUri!);
        return Task.FromResult(_responder(request));
    }

    /// <summary>A canned 200 Anthropic messages response with the given assistant text.</summary>
    public static HttpResponseMessage Completion(string content = "hello from fake")
    {
        string json = $$"""
        {
          "id": "msg_fake",
          "type": "message",
          "role": "assistant",
          "model": "claude-3-5-sonnet",
          "content": [ { "type": "text", "text": {{System.Text.Json.JsonSerializer.Serialize(content)}} } ],
          "stop_reason": "end_turn",
          "usage": { "input_tokens": 11, "output_tokens": 5 }
        }
        """;
        return Json(HttpStatusCode.OK, json);
    }

    /// <summary>A canned error response with status, optional headers, and a body.</summary>
    public static HttpResponseMessage Error(
        HttpStatusCode status,
        string body = "{\"type\":\"error\",\"error\":{\"type\":\"api_error\",\"message\":\"boom\"}}",
        IEnumerable<KeyValuePair<string, string>>? headers = null)
    {
        HttpResponseMessage response = Json(status, body);
        if (headers is not null)
        {
            foreach (KeyValuePair<string, string> header in headers)
            {
                response.Headers.TryAddWithoutValidation(header.Key, header.Value);
            }
        }

        return response;
    }

    private static HttpResponseMessage Json(HttpStatusCode status, string json) =>
        new(status)
        {
            Content = new StringContent(json, System.Text.Encoding.UTF8, "application/json"),
        };
}
