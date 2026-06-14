using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using System.Security.Claims;
using Api.Auth;
using DataAccess.Rls;
using Framework;
using Microsoft.AspNetCore.Http;
using Xunit;

namespace Api.Tests.Auth;

public class SessionUnitOfWorkMiddlewareTests
{
    /// <summary>Records begin/commit ordering relative to the pipeline <c>next</c> call.</summary>
    private sealed class RecordingUnitOfWork : ISessionUnitOfWork
    {
        public List<string> Calls { get; } = new();
        public SessionContext? BegunWith { get; private set; }

        public Task BeginAsync(SessionContext session, CancellationToken cancellationToken = default)
        {
            Calls.Add("begin");
            BegunWith = session;
            return Task.CompletedTask;
        }

        public Task CommitAsync(CancellationToken cancellationToken = default)
        {
            Calls.Add("commit");
            return Task.CompletedTask;
        }

        public ValueTask DisposeAsync()
        {
            Calls.Add("dispose");
            return ValueTask.CompletedTask;
        }
    }

    [Fact]
    public void Ctor_NullNext_Throws()
    {
        Assert.Throws<ArgumentNullException>(() => new SessionUnitOfWorkMiddleware(null!));
    }

    [Fact]
    public async Task InvokeAsync_AuthenticatedUser_DerivesSessionFromPrincipalAndRunsUnitOfWork()
    {
        var uow = new RecordingUnitOfWork();
        var nextRan = false;
        var middleware = new SessionUnitOfWorkMiddleware(_ =>
        {
            nextRan = true;
            uow.Calls.Add("next");
            return Task.CompletedTask;
        });

        var context = new DefaultHttpContext
        {
            User = new ClaimsPrincipal(new ClaimsIdentity(
                new[] { new Claim("sub", "kc-user-9") }, authenticationType: "Bearer")),
        };

        await middleware.InvokeAsync(context, uow);

        Assert.True(nextRan);
        Assert.Equal(new[] { "begin", "next", "commit" }, uow.Calls);
        Assert.Equal("kc-user-9", uow.BegunWith!.UserId);
    }

    [Fact]
    public async Task InvokeAsync_NullContext_Throws()
    {
        var middleware = new SessionUnitOfWorkMiddleware(_ => Task.CompletedTask);
        var uow = new RecordingUnitOfWork();

        await Assert.ThrowsAsync<ArgumentNullException>(() => middleware.InvokeAsync(null!, uow));
    }

    [Fact]
    public async Task InvokeCore_Authenticated_BeginsRunsNextInsideTransactionThenCommits()
    {
        var uow = new RecordingUnitOfWork();
        var session = new SessionContext("user-1", new[] { "user" });

        await SessionUnitOfWorkMiddleware.InvokeCoreAsync(
            session, uow, () => { uow.Calls.Add("next"); return Task.CompletedTask; });

        Assert.Equal(new[] { "begin", "next", "commit" }, uow.Calls);
        Assert.Equal("user-1", uow.BegunWith!.UserId);
    }

    [Fact]
    public async Task InvokeCore_Anonymous_RunsNextWithoutTransaction()
    {
        var uow = new RecordingUnitOfWork();
        var session = new SessionContext(string.Empty, Array.Empty<string>());

        await SessionUnitOfWorkMiddleware.InvokeCoreAsync(
            session, uow, () => { uow.Calls.Add("next"); return Task.CompletedTask; });

        // No begin/commit for an unauthenticated request (RLS denies by default).
        Assert.Equal(new[] { "next" }, uow.Calls);
    }

    [Fact]
    public async Task InvokeCore_NullSession_Throws()
    {
        var uow = new RecordingUnitOfWork();
        await Assert.ThrowsAsync<ArgumentNullException>(() =>
            SessionUnitOfWorkMiddleware.InvokeCoreAsync(null!, uow, () => Task.CompletedTask));
    }

    [Fact]
    public async Task InvokeCore_NullUnitOfWork_Throws()
    {
        var session = new SessionContext("u", Array.Empty<string>());
        await Assert.ThrowsAsync<ArgumentNullException>(() =>
            SessionUnitOfWorkMiddleware.InvokeCoreAsync(session, null!, () => Task.CompletedTask));
    }

    [Fact]
    public async Task InvokeCore_NullNext_Throws()
    {
        var uow = new RecordingUnitOfWork();
        var session = new SessionContext("u", Array.Empty<string>());
        await Assert.ThrowsAsync<ArgumentNullException>(() =>
            SessionUnitOfWorkMiddleware.InvokeCoreAsync(session, uow, null!));
    }
}
