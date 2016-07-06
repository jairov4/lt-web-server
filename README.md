# lt-web-server
Simple lightweight static web server using Vibe.D and language D.

Usage:

This web server can be configured using a simple settings file called `web.json`

    {
        "useServerCache": false,
        "clientCacheMaxAge": 0,
        "routes": [
            {"path": "/my-file",         "type": "file", "arg": "source/test.html"},
            {"path": "/videos/my-video", "type": "file", "arg": "source/video.mp4"},
            {"path": "*",                "type": "path", "arg": "source/"}
        ]
    }

The routes will be evaluated in order that appears in the file. Therefore, is recomended use the fallback route as last item.
The type path allows to serve a path with wildcards using a base folder.
The type file allows to serve a path using a static file.
The `clientCacheMaxAge` is an integer value that specify the HTTP Cache-Control max-age in seconds. It is useful to instruct clients to keep a valid copy of files for an specified duration reducing the requests need. A value of zero will disable this header. The default value is 0.

To run the server use:

    dub run lt-web-server -- --settings=/absolute/path/web.json
