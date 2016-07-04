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

To run the server without to install as service use:

    dub run lt-web-server --no-service --settings=/absolute/path/web.json
