module fileCache;

import vibe.core.file;
import vibe.core.log;
import vibe.http.server;
import vibe.http.fileserver;
import vibe.inet.message;
import vibe.inet.mimetypes;
import vibe.inet.url;
import vibe.stream.memory;

import std.conv;
import std.datetime;
import std.digest.md;
import std.string;

struct CacheEntry 
{
	FileInfo dirent;
	string lastModified;
	string etag;
	string cacheControl;
	string contentType;
	string contentLength;
	bool notFound;
	bool isCompressedContent;
	ubyte[] content;
}

// Max 3MB
immutable uint MAX_SIZE_TO_CACHE = 3*1024*1024;
private CacheEntry[string] entries;
private uint cacheSize = 0;

private CacheEntry prepareRequestResponseInfo(string pathstr, HTTPFileServerSettings settings)
{
	auto info = CacheEntry.init;	

	// return if the file does not exist
	if (!existsFile(pathstr)){
		info.notFound = true;
		return info;
	}

	FileInfo dirent;
	try dirent = getFileInfo(pathstr);
	catch(Exception){
		throw new HTTPStatusException(HTTPStatus.InternalServerError, "Failed to get information for the file due to a file system error.");
	}

	// TODO: Cache directory requests
	if (dirent.isDirectory) {
		if (settings.options & HTTPFileServerOption.serveIndexHTML)
			return prepareRequestResponseInfo(pathstr ~ "index.html", settings);
		logDebugV("Hit directory when serving files, ignoring: %s", pathstr);
		info.notFound = true;
		return info;
	}

	info.dirent = dirent;

	info.lastModified = toRFC822DateTimeString(dirent.timeModified.toUTC());
	// simple etag generation
	info.etag = "\"" ~ hexDigest!MD5(pathstr ~ ":" ~ info.lastModified ~ ":" ~ to!string(dirent.size)).idup ~ "\"";

	info.contentType = getMimeTypeForFile(pathstr);
	info.contentLength = to!string(dirent.size);

	// else write out the file contents
	//logTrace("Open file '%s' -> '%s'", srv_path, pathstr);
	FileStream fil;
	try {
		fil = openFile(pathstr);
	} catch( Exception e ){
		// TODO: handle non-existant files differently than locked files?
		logDebug("Failed to open file %s: %s", pathstr, e.toString());
		info.notFound = true;
		return info;
	}
	scope(exit) fil.close();

	info.content = new ubyte[cast(uint)info.dirent.size];
	fil.read(info.content);

	return info;
}

private void sendFileCacheImpl(scope HTTPServerRequest req, scope HTTPServerResponse res, Path path, HTTPFileServerSettings settings)
{
	CacheEntry info;
	auto pathstr = path.toNativeString();
	auto cachedItem = pathstr in entries;
	if(cachedItem is null) {
		info = prepareRequestResponseInfo(pathstr, settings);
		if(info.notFound || (cacheSize + info.dirent.size <= MAX_SIZE_TO_CACHE)) { 
			cacheSize += info.dirent.size;
			entries[pathstr] = info;
		}
	}
	else 
	{
		info = *cachedItem;
	}

	if(info.notFound) 
	{
		if(settings.options & HTTPFileServerOption.failIfNotFound) throw new HTTPStatusException(HTTPStatus.NotFound);
		res.statusCode = HTTPStatus.notFound;
		return;
	}
	
	res.headers["Last-Modified"] = info.lastModified;
	res.headers["Etag"] = info.etag;
	if (settings.maxAge > seconds(0)) {
		auto expireTime = Clock.currTime(UTC()) + settings.maxAge;
		res.headers["Expires"] = toRFC822DateTimeString(expireTime);
		res.headers["Cache-Control"] = "max-age="~to!string(settings.maxAge.total!"seconds");
	}

	if( auto pv = "If-Modified-Since" in req.headers ) {
		if( *pv == info.lastModified ) {
			res.statusCode = HTTPStatus.NotModified;
			res.writeVoidBody();
			return;
		}
	}

	if( auto pv = "If-None-Match" in req.headers ) {
		if ( *pv == info.etag ) {
			res.statusCode = HTTPStatus.NotModified;
			res.writeVoidBody();
			return;
		}
	}

	// avoid double-compression
	if ("Content-Encoding" in res.headers && isCompressedFormat(info.contentType))
		res.headers.remove("Content-Encoding");
	res.headers["Content-Type"] = info.contentType;
	res.headers["Content-Length"] = info.contentLength;

	if(settings.preWriteCallback) {
		settings.preWriteCallback(req, res, pathstr);
	}

	// for HEAD responses, stop here
	if( res.isHeadResponse() ){
		res.writeVoidBody();
		assert(res.headerWritten);
		logDebug("sent file header %d, %s!", info.dirent.size, res.headers["Content-Type"]);
		return;
	}

	auto stream = new MemoryStream(info.content, false);
	res.writeBody(stream);

	logTrace("sent file %d, %s!", stream.size, res.headers["Content-Type"]);
}



/**
	Returns a request handler that serves files from the specified directory.

	See `sendFile` for more information.

	Params:
	local_path = Path to the folder to serve files from.
	settings = Optional settings object enabling customization of how
	the files get served.

	Returns:
	A request delegate is returned, which is suitable for registering in
	a `URLRouter` or for passing to `listenHTTP`.

	See_Also: `serveStaticFile`, `sendFile`
*/
HTTPServerRequestDelegateS serveStaticFiles(Path local_path, HTTPFileServerSettings settings = null)
{
	if (!settings) settings = new HTTPFileServerSettings;
	if (!settings.serverPathPrefix.endsWith("/")) settings.serverPathPrefix ~= "/";

	void callback(scope HTTPServerRequest req, scope HTTPServerResponse res)
	{
		string srv_path;
		if (auto pp = "pathMatch" in req.params) srv_path = *pp;
		else if (req.path.length > 0) srv_path = req.path;
		else srv_path = req.requestURL;

		if (!srv_path.startsWith(settings.serverPathPrefix)) {
			logDebug("path '%s' not starting with '%s'", srv_path, settings.serverPathPrefix);
			return;
		}

		auto rel_path = srv_path[settings.serverPathPrefix.length .. $];
		auto rpath = Path(rel_path);
		logTrace("Processing '%s'", srv_path);

		rpath.normalize();
		logDebug("Path '%s' -> '%s'", rel_path, rpath.toNativeString());
		if (rpath.absolute) {
			logDebug("Path is absolute, not responding");
			return;
		} else if (!rpath.empty && rpath[0] == "..")
			return; // don't respond to relative paths outside of the root path

		sendFileCacheImpl(req, res, local_path ~ rpath, settings);
	}

	return &callback;
}
/// ditto
HTTPServerRequestDelegateS serveStaticFiles(string local_path, HTTPFileServerSettings settings = null)
{
	return serveStaticFiles(Path(local_path), settings);
}

/**
	Returns a request handler that serves a specific file on disk.

	See `sendFile` for more information.

	Params:
	local_path = Path to the file to serve.
	settings = Optional settings object enabling customization of how
	the file gets served.

	Returns:
	A request delegate is returned, which is suitable for registering in
	a `URLRouter` or for passing to `listenHTTP`.

	See_Also: `serveStaticFiles`, `sendFile`
*/
HTTPServerRequestDelegateS serveStaticFile(Path local_path, HTTPFileServerSettings settings = null)
{
	if (!settings) settings = new HTTPFileServerSettings;
	assert(settings.serverPathPrefix == "/", "serverPathPrefix is not supported for single file serving.");

	void callback(scope HTTPServerRequest req, scope HTTPServerResponse res)
	{
		sendFileCacheImpl(req, res, local_path, settings);
	}

	return &callback;
}
/// ditto
HTTPServerRequestDelegateS serveStaticFile(string local_path, HTTPFileServerSettings settings = null)
{
	return serveStaticFile(Path(local_path), settings);
}