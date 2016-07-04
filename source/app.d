module app;

// cannot use vibe.d due symbol clash for logging
import vibe.core.core;
import vibe.core.log;
import vibe.http.server;
import vibe.http.router;
import vibe.http.fileserver : HTTPFileServerSettings;

import jsonizer;
import std.json;
import std.file;
import std.path;
import std.getopt;

import fileCache;

immutable string settingsFileName = "web.json";

void loadRouteSpecs(RouteSettings[] routes, string basePath, URLRouter router)
{
    foreach(route; routes)
    {
        auto targetPath = route.arg.absolutePath(basePath);
        if(route.type == "path")
        {
            router.get(route.path, serveStaticFiles(targetPath)); 
        }
        else if(route.type == "file")
        {
            router.get(route.path, serveStaticFile(targetPath));
        }
        else throw new Error("Invalid type: " ~ route.type);
        logInfo("Mapping path: " ~ route.path ~ " with " ~ targetPath);
    }
}

int runServer(string settingsFileName)
{
    settingsFileName = settingsFileName.absolutePath(thisExePath.dirName);
    auto basePath = settingsFileName.dirName;

    // Load settings from file
    auto settingsFileContents = readText(settingsFileName);
    auto json = parseJSON(settingsFileContents);
    auto settings = json.fromJSON!Settings;

    settings.logFileName = settings.logFileName.absolutePath(basePath);

    // Setup loggers
    setLogFile(settings.logFileName, settings.logLevel);
    
    // Default vibe initialization
    auto svrSettings = new HTTPServerSettings;
    svrSettings.port = cast(ushort)settings.port;
    svrSettings.useCompressionIfPossible = settings.useCompressionIfPossible;
    svrSettings.bindAddresses = settings.bindAddresses;

    auto router = new URLRouter;
    logInfo("Loading routes from settings");
    loadRouteSpecs(settings.routes, basePath, router);

    listenHTTP(svrSettings, router);

    return runEventLoop();
}

struct RouteSettings 
{
    mixin JsonizeMe;

    @jsonize string type;
    @jsonize string path;
    @jsonize string arg;
}

struct Settings 
{
    mixin JsonizeMe;

    @jsonize(JsonizeOptional.yes) int port = 3000;
    @jsonize(JsonizeOptional.yes) string[] bindAddresses = ["::", "0.0.0.0"];
    @jsonize(JsonizeOptional.yes) bool useCompressionIfPossible = true;
    @jsonize(JsonizeOptional.yes) string logFileName = "vibe.log";
    @jsonize(JsonizeOptional.yes) LogLevel logLevel = LogLevel.info;
    @jsonize RouteSettings[] routes;
}

int main(string[] args)
{
    bool noExecAsService = false;
    string settingsFileNameOpt = settingsFileName;
    auto helpInformation = getopt(args, 
        "settings", "JSON settings file name.", &settingsFileNameOpt);

    if (helpInformation.helpWanted)
    {
        defaultGetoptPrinter(
            "Help about this program. "
            "Settings file path is relative to this executable",
            helpInformation.options);
        return 0;
    }

    return runServer(settingsFileNameOpt);
}
