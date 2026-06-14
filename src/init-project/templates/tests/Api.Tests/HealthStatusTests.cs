using Api;
using Xunit;

namespace Api.Tests;

public class HealthStatusTests
{
    [Fact]
    public void Live_ReportsOk()
    {
        Assert.Equal("ok", HealthStatus.Live().Status);
    }
}
