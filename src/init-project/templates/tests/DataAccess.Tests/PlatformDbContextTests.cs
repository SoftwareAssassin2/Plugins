using DataAccess;
using Microsoft.EntityFrameworkCore;
using Xunit;

namespace DataAccess.Tests;

public class PlatformDbContextTests
{
    [Fact]
    public void Constructs_WithNpgsqlOptions()
    {
        var options = new DbContextOptionsBuilder<PlatformDbContext>()
            .UseNpgsql("Host=localhost;Database=platform;Username=migrator")
            .Options;

        using var context = new PlatformDbContext(options);

        Assert.Equal("Npgsql.EntityFrameworkCore.PostgreSQL", context.Database.ProviderName);
    }
}
