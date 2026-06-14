// REMOVABLE SAMPLE — see SampleApp.csproj. A tiny end-to-end demonstration that
// the layered solution wires up (BusinessLogic -> DataAccess -> Framework).
// Delete src/SampleApp/ once you have a real entry point.

using BusinessLogic;
using Framework;

var greeter = new Greeter();
var session = new SessionContext("sample-user", new[] { "user" });
Console.WriteLine(greeter.Greet(session));
