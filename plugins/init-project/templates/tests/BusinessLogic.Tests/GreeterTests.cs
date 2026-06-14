using System;
using BusinessLogic;
using Framework;
using Xunit;

namespace BusinessLogic.Tests;

public class GreeterTests
{
    private readonly Greeter _greeter = new();

    [Fact]
    public void Greet_ReturnsGreeting_ForAuthenticatedSession()
    {
        var session = new SessionContext("ada", new[] { "user" });

        Assert.Equal("Hello, ada.", _greeter.Greet(session));
    }

    [Fact]
    public void Greet_Throws_ForUnauthenticatedSession()
    {
        var session = new SessionContext("", Array.Empty<string>());

        Assert.Throws<InvalidOperationException>(() => _greeter.Greet(session));
    }

    [Fact]
    public void Greet_Throws_ForNullSession()
    {
        Assert.Throws<ArgumentNullException>(() => _greeter.Greet(null!));
    }
}
