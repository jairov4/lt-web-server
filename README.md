# lt-web-server
Simple lightweight static web server using Vibe.D and language D.

Usage:

This web server can be configured using a simple settings file called `web.json`

    {
        "routes": [
            {"path": "*", "type": "path", "arg": "public/"},
            {"path": "test.html", "type": "file", "arg": "public/my-file.txt"}
        ]
    }

The type path allows to serve a path with wildcards using a base folder.
The type file allows to serve a path using a static file.
