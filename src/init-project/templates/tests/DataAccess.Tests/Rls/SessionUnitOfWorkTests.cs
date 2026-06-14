using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;
using DataAccess.Rls;
using Framework;
using Xunit;

namespace DataAccess.Tests.Rls;

public class SessionUnitOfWorkTests
{
    /// <summary>Records the order of seam calls so the UoW's ordering contract is assertable.</summary>
    private sealed class RecordingDbSession : IDbSession
    {
        public List<string> Calls { get; } = new();
        public SessionContext? AppliedSession { get; private set; }
        public int DisposeCount { get; private set; }

        /// <summary>When set, ApplySessionContextAsync throws this after recording the call.</summary>
        public Exception? ApplyFailure { get; set; }

        public Task BeginTransactionAsync(CancellationToken cancellationToken = default)
        {
            Calls.Add("begin");
            return Task.CompletedTask;
        }

        public Task ApplySessionContextAsync(SessionContext session, CancellationToken cancellationToken = default)
        {
            Calls.Add("apply");
            AppliedSession = session;
            if (ApplyFailure is not null)
            {
                throw ApplyFailure;
            }

            return Task.CompletedTask;
        }

        public Task CommitTransactionAsync(CancellationToken cancellationToken = default)
        {
            Calls.Add("commit");
            return Task.CompletedTask;
        }

        public Task RollbackTransactionAsync(CancellationToken cancellationToken = default)
        {
            Calls.Add("rollback");
            return Task.CompletedTask;
        }

        public ValueTask DisposeAsync()
        {
            DisposeCount++;
            return ValueTask.CompletedTask;
        }
    }

    private static SessionContext Authenticated() => new("user-1", new[] { "user" });

    [Fact]
    public void Ctor_NullSession_Throws()
    {
        Assert.Throws<ArgumentNullException>(() => new SessionUnitOfWork(null!));
    }

    [Fact]
    public async Task BeginAsync_OpensTransactionBeforeApplyingSessionContext()
    {
        var db = new RecordingDbSession();
        await using var uow = new SessionUnitOfWork(db);

        await uow.BeginAsync(Authenticated());

        // ORDER IS THE CONTRACT: begin must precede apply.
        Assert.Equal(new[] { "begin", "apply" }, db.Calls);
        Assert.Equal("user-1", db.AppliedSession!.UserId);
    }

    [Fact]
    public async Task BeginAsync_NullSession_Throws()
    {
        var db = new RecordingDbSession();
        await using var uow = new SessionUnitOfWork(db);

        await Assert.ThrowsAsync<ArgumentNullException>(() => uow.BeginAsync(null!));
    }

    [Fact]
    public async Task BeginAsync_ApplyContextFails_RollsBackOpenTransactionAndRethrows()
    {
        var boom = new InvalidOperationException("set_config failed");
        var db = new RecordingDbSession { ApplyFailure = boom };
        await using var uow = new SessionUnitOfWork(db);

        var thrown = await Assert.ThrowsAsync<InvalidOperationException>(() => uow.BeginAsync(Authenticated()));

        Assert.Same(boom, thrown);
        // Transaction was opened then rolled back — never left dangling.
        Assert.Equal(new[] { "begin", "apply", "rollback" }, db.Calls);
    }

    [Fact]
    public async Task BeginAsync_Twice_Throws()
    {
        var db = new RecordingDbSession();
        await using var uow = new SessionUnitOfWork(db);
        await uow.BeginAsync(Authenticated());

        await Assert.ThrowsAsync<InvalidOperationException>(() => uow.BeginAsync(Authenticated()));
    }

    [Fact]
    public async Task CommitAsync_AfterBegin_Commits()
    {
        var db = new RecordingDbSession();
        await using var uow = new SessionUnitOfWork(db);
        await uow.BeginAsync(Authenticated());

        await uow.CommitAsync();

        Assert.Equal(new[] { "begin", "apply", "commit" }, db.Calls);
    }

    [Fact]
    public async Task CommitAsync_WithoutBegin_Throws()
    {
        var db = new RecordingDbSession();
        await using var uow = new SessionUnitOfWork(db);

        await Assert.ThrowsAsync<InvalidOperationException>(() => uow.CommitAsync());
    }

    [Fact]
    public async Task RollbackAsync_AfterBegin_RollsBack()
    {
        var db = new RecordingDbSession();
        await using var uow = new SessionUnitOfWork(db);
        await uow.BeginAsync(Authenticated());

        await uow.RollbackAsync();

        Assert.Equal(new[] { "begin", "apply", "rollback" }, db.Calls);
    }

    [Fact]
    public async Task RollbackAsync_WithoutBegin_IsNoOp()
    {
        var db = new RecordingDbSession();
        await using var uow = new SessionUnitOfWork(db);

        await uow.RollbackAsync();

        Assert.Empty(db.Calls);
    }

    [Fact]
    public async Task DisposeAsync_DisposesUnderlyingSessionOnce()
    {
        var db = new RecordingDbSession();
        var uow = new SessionUnitOfWork(db);

        await uow.DisposeAsync();
        await uow.DisposeAsync(); // idempotent: must not double-dispose the seam.

        Assert.Equal(1, db.DisposeCount);
    }
}
