using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace ParleyAI.Tests.OpenAi;

/// <summary>
/// An in-process fake <see cref="HttpMessageHandler"/> that records every request URI and returns
/// queued canned responses. Mirrors the LiteLLM ai-mock surface enough to exercise the OpenAI
/// provider WITHOUT a real network or fn-3 container.
/// </summary>
internal sealed class FakeHttpMessageHandler : HttpMessageHandler
{
    private readonly Func<HttpRequestMessage, HttpResponseMessage> _responder;

    public FakeHttpMessageHandler(Func<HttpRequestMessage, HttpResponseMessage> responder) =>
        _responder = responder;

    /// <summary>Every request URI seen, in order — used to assert the final scheme + path.</summary>
    public List<Uri> RequestUris { get; } = new();

    /// <summary>Total send attempts — proves single-attempt behavior (SDK retry disabled).</summary>
    public int AttemptCount => RequestUris.Count;

    protected override Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        RequestUris.Add(request.RequestUri!);
        return Task.FromResult(_responder(request));
    }

    /// <summary>A canned 200 chat completion with the given assistant text.</summary>
    public static HttpResponseMessage Completion(string content = "hello from fake")
    {
        string json = $$"""
        {
          "id": "chatcmpl-fake",
          "object": "chat.completion",
          "created": 0,
          "model": "gpt-4o",
          "choices": [
            { "index": 0, "finish_reason": "stop",
              "message": { "role": "assistant", "content": {{System.Text.Json.JsonSerializer.Serialize(content)}} } }
          ],
          "usage": { "prompt_tokens": 11, "completion_tokens": 5, "total_tokens": 16 }
        }
        """;
        return Json(HttpStatusCode.OK, json);
    }

    /// <summary>A canned error response with status, optional headers, and a body.</summary>
    public static HttpResponseMessage Error(
        HttpStatusCode status,
        string body = "{\"error\":{\"message\":\"boom\"}}",
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
