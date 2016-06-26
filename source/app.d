module app;

import dlogg.strict;
import daemonize.d;

// cannot use vibe.d due symbol clash for logging
import vibe.core.core;
import vibe.core.log : setLogLevel, setLogFile, VibeLogLevel = LogLevel;
import vibe.http.server;
import vibe.http.router;
import vibe.http.fileserver;

import jsonizer;
import std.json;
import std.file;
import std.path;
import std.getopt;

immutable string settingsFileName = "web.json";

void loadRouteSpecs(RouteSettings[] routes, string basePath, URLRouter router, shared ILogger logger) 
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
        logger.logInfo("Mapping path: " ~ route.path ~ " with " ~ targetPath);
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
    settings.vibeLogFileName = settings.vibeLogFileName.absolutePath(basePath);

    // Setup loggers
    setLogFile(settings.vibeLogFileName, settings.vibeLogLevel);
    auto logger = new shared StrictLogger(settings.logFileName);
    logger.minOutputLevel = settings.logLevel;

    // Default vibe initialization
    auto svrSettings = new HTTPServerSettings;
    svrSettings.port = cast(ushort)settings.port;
    svrSettings.useCompressionIfPossible = settings.useCompressionIfPossible;
    svrSettings.bindAddresses = settings.bindAddresses;

    auto router = new URLRouter;
    logger.logInfo("Loading routes from settings");
    loadRouteSpecs(settings.routes, basePath, router, logger);

    listenHTTP(svrSettings, router);

    return runEventLoop();
}

// Simple daemon description
alias daemon = Daemon!(
    "lt-web-server", // unique name
    KeyValueList!(
        Composition!(Signal.Terminate, Signal.Quit, Signal.Shutdown, Signal.Stop), (logger)
        {
            logger.logInfo("Exiting...");
            exitEventLoop(true);
            return false; 
        },
        Signal.HangUp, (logger)
        {
            logger.logInfo("Hang up");
            return true;
        }
    ),
    (logger, shouldExit) { return runServer(settingsFileName.dup); }
);

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
    @jsonize(JsonizeOptional.yes) string[] bindAddresses = ["::1", "127.0.0.1"];
    @jsonize(JsonizeOptional.yes) bool useCompressionIfPossible = true;
    @jsonize(JsonizeOptional.yes) string logFileName = "general.log";
    @jsonize(JsonizeOptional.yes) string vibeLogFileName = "vibe.log";
    @jsonize(JsonizeOptional.yes) LoggingLevel logLevel = LoggingLevel.Debug;
    @jsonize(JsonizeOptional.yes) VibeLogLevel vibeLogLevel = VibeLogLevel.info;
    @jsonize RouteSettings[] routes;
}

int main(string[] args)
{
    bool noExecAsService = false;
    string settingsFileNameOpt = settingsFileName;
    auto helpInformation = getopt(args, 
        "no-service", "No use as system service", &noExecAsService,
        "settings", "JSON settings file name.", &settingsFileNameOpt);

    if (helpInformation.helpWanted)
    {
        defaultGetoptPrinter(
            "Help about this program. "
            "Settings file path is relative to this executable",
            helpInformation.options);
        return 0;
    }

    if(!noExecAsService)
    {
        auto logger = new shared StrictLogger(thisExePath.dirName.buildPath("lt-web-server-service.log"));
        return buildDaemon!daemon.run(logger);
    }

    return runServer(settingsFileNameOpt);
}
