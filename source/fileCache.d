module fileCache;

import vibe.core.file;
import vibe.core.log;
import vibe.http.server;
import vibe.inet.message;
import vibe.inet.mimetypes;
import vibe.inet.url;
import vibe.stream.memory;

import std.conv;
import std.datetime;
import std.digest.md;
import std.string;
import std.regex;

class CacheEntry 
{
	FileInfo dirent;
	string pathstr;
	string lastModified;
	string etag;
	string cacheControl;
	string contentType;
	string contentLength;
	bool notFound;
	bool contentsTooLarge;
	bool isCompressedContent;
	ubyte[] content;
}

// Max 3MB
immutable uint DEFAULT_CACHE_SIZE = 3*1024*1024;
private CacheEntry[string] entries;

class FileServerCache
{
	private CacheEntry[string] entries;
	private uint remainingSize = DEFAULT_CACHE_SIZE;
	private uint maxSize = DEFAULT_CACHE_SIZE;
	private uint myMaxItemSize;

	@property uint maxItemSize() { return myMaxItemSize; }

	this(uint maxSize = DEFAULT_CACHE_SIZE, uint maxItemSize = DEFAULT_CACHE_SIZE)
	{
		this.maxSize = maxSize;
		this.myMaxItemSize = maxItemSize;
	}

	void tryPut(CacheEntry info)
	{
		auto addSize = info.dirent.size;
		if(addSize > myMaxItemSize) return;
		if(addSize > remainingSize) return;

		// TODO: Replacement policy
		synchronized(this)
		{
			remainingSize -= addSize;
			entries[info.pathstr] = info;
		}
	}

	CacheEntry get(string pathstr)
	{
		synchronized(this)
		{
			if(auto pv = pathstr in entries)
			{
				return *pv;
			}
		}

		return null;
	}
}

auto byteRangeExpression = ctRegex!(`^bytes=(\d+)?-(\d+)?$`);

/**
Additional options for the static file server.
*/
enum HTTPFileServerOption {
	none = 0,
	/// respond with 404 if a file was not found
	failIfNotFound = 1 << 0,
	/// serve index.html for directories
	serveIndexHTML = 1 << 1,
	/// default options are serveIndexHTML
	defaults = serveIndexHTML,
}

/**
Configuration options for the static file server.
*/
class HTTPFileServerSettings {
	/// Prefix of the request path to strip before looking up files
	string serverPathPrefix = "/";

	/// Maximum cache age to report to the client (24 hours by default)
	Duration maxAge;// = hours(24);

	/// General options
	HTTPFileServerOption options = HTTPFileServerOption.defaults; /// additional options

	/// File cache
	FileServerCache cache = null;

	/**
	Called just before headers and data are sent.
	Allows headers to be customized, or other custom processing to be performed.

	Note: Any changes you make to the response, physicalPath, or anything
	else during this function will NOT be verified by Vibe.d for correctness.
	Make sure any alterations you make are complete and correct according to HTTP spec.
	*/
	void delegate(scope HTTPServerRequest req, scope HTTPServerResponse res, ref string physicalPath) preWriteCallback = null;

	this()
	{
		// need to use the contructor because the Ubuntu 13.10 GDC cannot CTFE dur()
		maxAge = 2.seconds;
	}

	this(string path_prefix)
	{
		this();
		serverPathPrefix = path_prefix;
	}
}

private CacheEntry prepareRequestResponseInfo(string pathstr, HTTPFileServerSettings settings)
{
	auto info = new CacheEntry;
	info.pathstr = pathstr;

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

	info.contentsTooLarge = info.dirent.size > (settings.cache !is null ? settings.cache.maxItemSize : DEFAULT_CACHE_SIZE);
	if(info.contentsTooLarge) return info;

	FileStream fil;
	try {
		fil = openFile(info.pathstr);
		info.content.length = cast(int)info.dirent.size;
		fil.read(info.content);
	} catch( Exception e ){
		// TODO: handle non-existant files differently than locked files?
		logDebug("Failed to open file %s: %s", info.pathstr, e.toString());
		info.notFound = true;
	}
	finally {
		fil.close();
	}

	return info;
}

private void writeBody(CacheEntry info, ulong begin, HTTPServerResponse res)
{
	if(info.contentsTooLarge)
	{
		auto fil = openFile(info.pathstr);
		scope(exit) fil.close();
		res.writeBody(fil);
	}
	else if(begin == 0)
	{
		res.writeBody(info.content);
	}
	else
	{
		auto stream = new MemoryStream(info.content);
		stream.seek(begin);
		res.writeRawBody(stream);
	}
}

private void sendFileCacheImpl(scope HTTPServerRequest req, scope HTTPServerResponse res, Path path, HTTPFileServerSettings settings)
{
	CacheEntry info;
	auto pathstr = path.toNativeString();
	
	if(settings.cache is null)
	{
		info = prepareRequestResponseInfo(pathstr, settings);
	} else {
		info = settings.cache.get(pathstr);
		if(info is null) info = prepareRequestResponseInfo(pathstr, settings);
		else settings.cache.tryPut(info);
	}

	if(info.notFound) 
	{
		if(settings.options & HTTPFileServerOption.failIfNotFound) throw new HTTPStatusException(HTTPStatus.NotFound);
		res.statusCode = HTTPStatus.notFound;
		return;
	}

	res.headers["Accept-Ranges"] = "bytes";

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

	if( auto pv = "If-Unmodified-Since" in req.headers ) {
		if( *pv != info.lastModified ) {
			res.statusCode = HTTPStatus.NotModified;
			res.writeVoidBody();
			return;
		}
	}

	if( auto pv = "If-Match" in req.headers ) {
		if ( *pv != info.etag ) {
			res.statusCode = HTTPStatus.NotModified;
			res.writeVoidBody();
			return;
		}
	}

	res.headers["Content-Type"] = info.contentType;

	if( auto pv = "Range" in req.headers )
	{
		auto match = matchFirst(*pv, byteRangeExpression);
		// both inclusive indices
		uint begin, end;
		auto p1 = match.length > 1 && match[1] != "";
		auto p2 = match.length > 2 && match[2] != "";

		if(p1 || p2)
		{
			if ("Content-Encoding" in res.headers)
				res.headers.remove("Content-Encoding");

			if(p1 && !p2)
			{
				begin = to!uint(match[1]);
				end = cast(uint)info.dirent.size - 1;
			}
			else if(!p1 && p2)
			{
				begin = cast(uint)info.dirent.size - to!uint(match[2]);
				end = cast(uint)info.dirent.size - 1;
			}
			else if(p1 && p2) 
			{
				begin = to!uint(match[1]);
				end = to!uint(match[2]);
			}

			res.statusCode = HTTPStatus.partialContent;
			res.headers["Content-Range"] = "bytes " ~ to!string(begin) ~ "-" ~ to!string(end) ~ "/" ~ info.contentLength;

			auto length = end - begin + 1;
			res.headers["Content-Length"] = to!string(length);

			if(info.contentsTooLarge)
			{
				auto fil = openFile(info.pathstr);
				scope(exit) fil.close();
				fil.seek(begin);
				res.writeRawBody(fil);
			}
			else
			{
				auto stream = new MemoryStream(info.content[begin..end+1]);
				res.writeRawBody(stream);
			}

			logTrace("sent partial file %d-%d, %s!", begin, end, res.headers["Content-Type"]);
			return;
		}
	}

	// avoid double-compression
	if ("Content-Encoding" in res.headers && isCompressedFormat(info.contentType))
		res.headers.remove("Content-Encoding");
	res.headers["Content-Length"] = info.contentLength;

	if(settings.preWriteCallback)
	{
		settings.preWriteCallback(req, res, pathstr);
	}

	// for HEAD responses, stop here
	if( res.isHeadResponse() ){
		res.writeVoidBody();
		assert(res.headerWritten);
		logDebug("sent file header %d, %s!", info.dirent.size, res.headers["Content-Type"]);
		return;
	}

	if(info.contentsTooLarge)
	{
		auto fil = openFile(info.pathstr);
		scope(exit) fil.close();
		res.writeBody(fil);
	}
	else
	{
		res.writeBody(info.content);
	}

	logTrace("sent file %d, %s!", info.dirent.size, res.headers["Content-Type"]);
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