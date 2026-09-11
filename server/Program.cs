using System.Security.Claims;
using System.Text.Json.Nodes;
using BackupS3Manager.Server;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;

var builder = WebApplication.CreateBuilder(args);
builder.Configuration.AddEnvironmentVariables();
builder.Services.AddSingleton<ServerStore>();
builder.Services.AddAuthentication(CookieAuthenticationDefaults.AuthenticationScheme).AddCookie(options =>
{
    options.LoginPath = "/login.html";
    options.Cookie.Name = "BackupS3.Server";
    options.Cookie.HttpOnly = true;
    options.Cookie.SameSite = SameSiteMode.Strict;
    options.ExpireTimeSpan = TimeSpan.FromHours(12);
});
builder.Services.AddAuthorization();

var app = builder.Build();
app.UseDefaultFiles();
app.UseStaticFiles();
app.UseAuthentication();
app.UseAuthorization();

app.MapGet("/api/health", () => Results.Ok(new { ok = true, product = "BackupS3 Manager Server", version = "25.0.0", host = Environment.MachineName }));
app.MapPost("/api/login", async (HttpContext context) =>
{
    var body = await JsonNode.ParseAsync(context.Request.Body) as JsonObject;
    var supplied = body?["password"]?.ToString() ?? "";
    var expected = app.Configuration["BS3_ADMIN_PASSWORD"] ?? "";
    if (expected.Length < 10 || supplied != expected) return Results.Unauthorized();
    var identity = new ClaimsIdentity(new[] { new Claim(ClaimTypes.Name, "admin") }, CookieAuthenticationDefaults.AuthenticationScheme);
    await context.SignInAsync(CookieAuthenticationDefaults.AuthenticationScheme, new ClaimsPrincipal(identity));
    return Results.Ok(new { ok = true });
}).AllowAnonymous();
app.MapPost("/api/logout", async (HttpContext context) => { await context.SignOutAsync(); return Results.Ok(); }).RequireAuthorization();

app.MapGet("/api/server", (ServerStore store) => Results.Json(store.PublicSettings())).RequireAuthorization();
app.MapGet("/api/agents", (ServerStore store) => Results.Json(new JsonObject { ["agents"] = store.AgentsForDashboard() })).RequireAuthorization();

app.MapPost("/agent/enroll", async (HttpContext context, ServerStore store) =>
{
    try
    {
        var body = await JsonNode.ParseAsync(context.Request.Body) as JsonObject ?? new JsonObject();
        return Results.Json(store.Enroll(body["enrollmentCode"]?.ToString() ?? "", body["host"]?.ToString() ?? "",
            body["displayName"]?.ToString() ?? "", body["version"]?.ToString() ?? "unknown"));
    }
    catch (UnauthorizedAccessException ex) { return Results.Json(new { error = ex.Message }, statusCode: 403); }
}).AllowAnonymous();

app.MapPost("/agent/heartbeat", async (HttpContext context, ServerStore store) =>
{
    try
    {
        var body = await JsonNode.ParseAsync(context.Request.Body) as JsonObject ?? new JsonObject();
        var authorization = context.Request.Headers.Authorization.ToString();
        var token = authorization.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase) ? authorization[7..].Trim() : "";
        return Results.Json(store.Heartbeat(body["agentId"]?.ToString() ?? "", token, body["report"]));
    }
    catch (UnauthorizedAccessException ex) { return Results.Json(new { error = ex.Message }, statusCode: 401); }
}).AllowAnonymous();

app.Run();
