module app;

import dlogg.strict;
import daemonize.d;

// cannot use vibe.d due symbol clash for logging
import vibe.core.core;
import vibe.core.log : setLogLevel, setLogFile, VibeLogLevel = LogLevel;
import vibe.http.server;
import vibe.http.router;
import vibe.http.fileserver;

import std.json;
import std.file;
import std.path;

void loadRouteSpecs(string settings, URLRouter router, shared ILogger logger) {
    auto json = parseJSON(settings);
    if (json.type != JSON_TYPE.OBJECT) throw new Error("Settings file must contain an object");
    auto routes = json["routes"].array;
    foreach(route; routes)
    {
        if (route.type != JSON_TYPE.OBJECT) throw new Error("Settings file: each route must be an object");
        auto path = route["path"].str;
        auto type = route["type"].str;
        auto arg = route["arg"].str;

        if(type == "path") 
		{
            auto targetPath = thisExePath.dirName.buildPath(arg);
			router.get(path, serveStaticFiles(targetPath)); 
			logger.logInfo("Mapping path: " ~ path ~ " with " ~ targetPath);
		}
        else if(type == "file") 
		{
            auto targetPath = thisExePath.dirName.buildPath(arg);
			router.get(path, serveStaticFile(targetPath));
			logger.logInfo("Mapping path: " ~ path ~ " with " ~ targetPath);
		}
        else throw new Error("Invalid type: " ~ type);
    }
}

void setupServer(shared ILogger logger, bool function() shouldExit)
{
    // Default vibe initialization
    auto settings = new HTTPServerSettings;
    settings.port = 8080;
    settings.useCompressionIfPossible = true;
    settings.bindAddresses = ["::1", "127.0.0.1"];

    auto router = new URLRouter;
    auto settingsFileName = thisExePath.dirName.buildPath("web.json");
    logger.logInfo("Loading settings file: " ~ settingsFileName);
    auto settingsFileContents = readText(settingsFileName);
    loadRouteSpecs(settingsFileContents, router, logger);

    listenHTTP(settings, router);
}

// Simple daemon description
alias daemon = Daemon!(
    "lt-web-server", // unique name
    KeyValueList!(
        Composition!(Signal.Terminate, Signal.Quit, Signal.Shutdown, Signal.Stop), (logger)
        {
            logger.logInfo("Exiting...");
            
            // No need to force exit here
            // main will stop after the call 
            exitEventLoop(true);
            return false; 
        },
        Signal.HangUp, (logger)
        {
            logger.logInfo("Hang up");
            return true;
        }
    ),
    
    (logger, shouldExit) {
        setupServer(logger, shouldExit);

        // All exceptions are caught by daemonize
        return runEventLoop();
    }
);

int main(string[] args)
{
    bool noService = args.length > 1 && args[1] == "--no-svc";

    // Setting vibe logger 
    // daemon closes stdout/stderr and vibe logger will crash
    // if not suppress printing to console
    version(Windows) auto vibeLogName = (noService ? "" : "C:\\" ) ~ "server-access.log";
    else enum vibeLogName = "server-access.log";

    // no stdout/stderr output
    version(Windows) {}
    else setLogLevel(VibeLogLevel.none);

    setLogFile(vibeLogName, VibeLogLevel.info);

    version(Windows) auto logFileName = (noService ? "" : "C:\\" ) ~ "logfile.log";
    else enum logFileName = "logfile.log";

    auto logger = new shared StrictLogger(logFileName);
    logger.minOutputLevel = LoggingLevel.Debug;

    if (noService) {
        setupServer(logger, null);
        return runEventLoop();
    }

    return buildDaemon!daemon.run(logger); 
}
