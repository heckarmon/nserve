import asynchttpserver, asyncdispatch, os, strutils, uri, parseopt, times, net, asyncnet

# --------------------------
# Helper / Usage
# --------------------------

proc showHelp() =
  echo """
nserve - A lightweight Async HTTP File Server

Usage:
  nserve [options] [directory]

Options:
  -p, --port     Set the port (default: 8000)
  -H, --host     Set the host address (default: 0.0.0.0)
  -d, --dir      Set the directory to serve (default: current dir)
  -h, --help     Show this help message

Syntax Notes:
  • Short flags (-d, -p) use space or colon:   -d ./waw  OR  -d:./waw
  • Long flags (--dir) use equals or colon:    --dir=./waw

Examples:
  nserve ./waw              # Serve directory directly (Recommended)
  nserve -p 8080            # Serve current dir on port 8000
  nserve -d:./html -p:3000  # Short options with colons
  nserve --dir=/var/www     # Long options
"""
  quit(0)

# --------------------------
# Logging
# --------------------------

proc logRequest(reqMethod: HttpMethod, path: string, statusCode: HttpCode,
    clientAddr: string) =
  let timestamp = now().format("yyyy-MM-dd HH:mm:ss")
  let methodStr = $reqMethod
  let statusStr = $statusCode.int

  # Color codes for terminal output
  let methodColor = case reqMethod
    of HttpGet: "\e[32m"
    of HttpPost: "\e[33m"
    of HttpPut: "\e[34m"
    of HttpDelete: "\e[31m"
    else: "\e[37m"

  let statusInt = statusCode.int
  let statusColor = if statusInt >= 200 and statusInt < 300: "\e[32m"
    elif statusInt >= 300 and statusInt < 400: "\e[36m"
    elif statusInt >= 400 and statusInt < 500: "\e[33m"
    else: "\e[31m"

  let reset = "\e[0m"

  echo "[", timestamp, "] ", "\e[36m", clientAddr.alignLeft(21), reset, " ",
       methodColor, methodStr.alignLeft(7), reset,
       " ", statusColor, statusStr, reset, " ", path

# --------------------------
# HTML Template
# --------------------------

proc pageTemplate(title, body: string): string =
  """
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>""" & title &
      """</title>
<style>
:root {
  --bg: #ffffff;
  --text: #111111;
  --card: #f4f4f4;
  --dir-color: #4da3ff;
  --file-color: #666666;
  --parent-color: #ff9500;
}
body.dark {
  --bg: #121212;
  --text: #eeeeee;
  --card: #1e1e1e;
  --dir-color: #6db3ff;
  --file-color: #aaaaaa;
  --parent-color: #ffb340;
}
body {
  background: var(--bg);
  color: var(--text);
  font-family: sans-serif;
  padding: 20px;
}
a { color: #4da3ff; text-decoration: none; }
.card {
  background: var(--card);
  padding: 12px;
  border-radius: 8px;
  margin-bottom: 8px;
  display: flex;
  align-items: center;
  gap: 8px;
}
.card.dir {
  border-left: 4px solid var(--dir-color);
}
.card.file {
  border-left: 4px solid var(--file-color);
}
.card.parent {
  border-left: 4px solid var(--parent-color);
  font-weight: bold;
}
.icon {
  font-size: 20px;
  min-width: 24px;
}
button { padding: 6px 10px; cursor: pointer; }
</style>
</head>
<body>
<button onclick="toggleTheme()">Toggle Theme</button>
""" & body & """
<script>
// Load theme from localStorage on page load
if (localStorage.getItem('theme') === 'dark') {
  document.body.classList.add('dark');
}

function toggleTheme() {
  document.body.classList.toggle('dark');
  // Save theme preference to localStorage
  if (document.body.classList.contains('dark')) {
    localStorage.setItem('theme', 'dark');
  } else {
    localStorage.setItem('theme', 'light');
  }
}
</script>
</body>
</html>
"""

# --------------------------
# Directory Listing
# --------------------------

proc dirListing(path: string, urlPath: string): string =
  var content = "<h1>Index of " & urlPath & "</h1>"

  content.add("""
<form method="POST" enctype="multipart/form-data">
  <input type="file" name="file">
  <button type="submit">Upload</button>
</form>
<hr>
""")

  # Add parent directory link if not at root
  if urlPath != "/":
    var parentPath = urlPath
    if parentPath.endsWith("/"):
      parentPath = parentPath[0 ..< parentPath.len - 1]

    let lastSlash = parentPath.rfind('/')
    if lastSlash >= 0:
      parentPath = parentPath[0 ..< lastSlash]
      if parentPath == "":
        parentPath = "/"

      content.add(
        "<div class='card parent'>" &
        "<span class='icon'>⬆️</span>" &
        "<a href='" & parentPath & "'>.. (Parent Directory)</a>" &
        "</div>"
      )

  var dirs: seq[string] = @[]
  var files: seq[string] = @[]

  for kind, file in walkDir(path):
    let name = extractFilename(file)
    if kind == pcDir:
      dirs.add(name)
    else:
      files.add(name)

  var prefix = urlPath
  if not prefix.endsWith("/"):
    prefix &= "/"

  for name in dirs:
    let encodedName = encodeUrl(name, usePlus = false)
    content.add(
      "<div class='card dir'>" &
      "<span class='icon'>📁</span>" &
      "<a href='" & prefix & encodedName & "/'>" & name & "/</a>" &
      "</div>"
    )

  for name in files:
    let encodedName = encodeUrl(name, usePlus = false)
    content.add(
      "<div class='card file'>" &
      "<span class='icon'>📄</span>" &
      "<a href='" & prefix & encodedName & "'>" & name & "</a>" &
      "</div>"
    )

  pageTemplate("Index of " & urlPath, content)

# --------------------------
# Upload Handling
# --------------------------

proc handleUpload(req: Request, path: string) {.async, gcsafe.} =
  if req.headers.getOrDefault("Content-Type").startsWith("multipart/form-data"):
    let data = req.body

    var filename = "upload.bin"
    let lines = data.split("\r\n")
    for line in lines:
      if line.contains("Content-Disposition") and line.contains("filename="):
        let start = line.find("filename=\"")
        if start != -1:
          let nameStart = start + 10
          let nameEnd = line.find("\"", nameStart)
          if nameEnd != -1:
            filename = line[nameStart ..< nameEnd]
            if filename == "": return
            break

    let start = data.find("\r\n\r\n")
    if start != -1:
      let boundaryStart = data.find("------WebKitFormBoundary", start + 4)
      var fileData: string
      if boundaryStart != -1:
        fileData = data[start + 4 ..< boundaryStart - 2]
      else:
        fileData = data[start + 4 ..< data.len]

      if fileData.len > 0 and filename != "" and filename != "upload.bin":
        let fullPath = path / filename
        writeFile(fullPath, fileData)

# --------------------------
# MIME type getter
# --------------------------

proc getMime(ext: string): string =
  case ext.toLowerAscii()
  of ".html", ".htm": "text/html"
  of ".css": "text/css"
  of ".js": "application/javascript"
  of ".json": "application/json"
  of ".png": "image/png"
  of ".jpg", ".jpeg": "image/jpeg"
  of ".gif": "image/gif"
  of ".svg": "image/svg+xml"
  of ".txt": "text/plain"
  of ".pdf": "application/pdf"
  of ".zip": "application/zip"
  of ".xml": "application/xml"
  of ".mp4": "video/mp4"
  of ".mp3": "audio/mpeg"
  of ".webp": "image/webp"
  of ".woff", ".woff2": "font/woff"
  of ".ttf": "font/ttf"
  of ".ico": "image/x-icon"
  else: "application/octet-stream"

# --------------------------
# MAIN LOGIC
# --------------------------

proc main() =
  # --------------------------
  # CLI Arguments Parsing
  # --------------------------
  var port = 8000
  var host = "0.0.0.0"
  var serveDir = "."

  # State flags for parsing split arguments (e.g., -d ./folder)
  var expectingDir = false
  var expectingPort = false
  var expectingHost = false

  var p = initOptParser()
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      # Reset expectation flags if a new flag is found
      expectingDir = false; expectingPort = false; expectingHost = false

      case p.key
      of "p", "port":
        if p.val.len > 0: port = parseInt(p.val)
        else: expectingPort = true
      of "H", "host":
        if p.val.len > 0: host = p.val
        else: expectingHost = true
      of "d", "dir":
        if p.val.len > 0: serveDir = p.val
        else: expectingDir = true
      of "h", "help":
        showHelp()
      else:
        echo "Unknown option: ", p.key
        showHelp()

    of cmdArgument:
      # Handle values that were separated by space (e.g. -d ./foo)
      if expectingDir:
        serveDir = p.key
        expectingDir = false
      elif expectingPort:
        port = parseInt(p.key)
        expectingPort = false
      elif expectingHost:
        host = p.key
        expectingHost = false
      else:
        # If no flag was pending, assume bare arg is the directory
        # This allows: nserve ./waw
        serveDir = p.key

  # Normalize serveDir
  if serveDir.len > 1 and serveDir.endsWith(DirSep):
    serveDir = serveDir[0 ..< ^1]

  if not dirExists(serveDir):
    echo "Error: Directory not found: '", serveDir, "'"
    quit(1)

  # --------------------------
  # Request Callback (Closure)
  # --------------------------
  proc cb(req: Request) {.async, gcsafe.} =
    # Decode URL to handle spaces/symbols in paths
    let urlPath = req.url.path.decodeUrl()

    # Remove leading slash to join correctly with serveDir
    let relativePath = if urlPath.startsWith("/"): urlPath[1..^1] else: urlPath

    # Construct full file system path based on serveDir
    var fsPath = serveDir / relativePath

    var statusCode = Http200

    let clientAddr =
      if req.headers.hasKey("X-Forwarded-For"):
        $req.headers["X-Forwarded-For"]
      else:
        try:
          let peer = req.client.getPeerAddr()
          peer[0] & ":" & $peer[1]
        except:
          req.hostname

    if req.reqMethod == HttpPost and dirExists(fsPath):
      await handleUpload(req, fsPath)
      statusCode = Http200
      logRequest(req.reqMethod, req.url.path, statusCode, clientAddr)
      await req.respond(
        statusCode,
        pageTemplate("Uploaded",
          "<h2>File uploaded successfully.</h2><a href='" & req.url.path & "'>Back</a>"
        )
      )
      return

    if dirExists(fsPath):
      if not req.url.path.endsWith("/"):
        let indexPath = fsPath / "index.html"
        if fileExists(indexPath):
          let mime = getMime(".html")
          statusCode = Http200
          logRequest(req.reqMethod, req.url.path, statusCode, clientAddr)
          await req.respond(
            statusCode,
            readFile(indexPath),
            newHttpHeaders([("Content-Type", mime)])
          )
          return

      statusCode = Http200
      logRequest(req.reqMethod, req.url.path, statusCode, clientAddr)
      await req.respond(statusCode, dirListing(fsPath, req.url.path))

    elif fileExists(fsPath):
      let (_, _, ext) = splitFile(fsPath)
      let mime = getMime(ext)
      statusCode = Http200
      logRequest(req.reqMethod, req.url.path, statusCode, clientAddr)
      await req.respond(
        statusCode,
        readFile(fsPath),
        newHttpHeaders([("Content-Type", mime)])
      )

    else:
      statusCode = Http404
      logRequest(req.reqMethod, req.url.path, statusCode, clientAddr)
      await req.respond(
        statusCode,
        pageTemplate("404", "<h1>404 Not Found</h1>")
      )

  # --------------------------
  # Start Server
  # --------------------------
  let server = newAsyncHttpServer()

  proc handleSignal() {.noconv.} =
    echo "\nShutting down server..."
    quit(0)
  setControlCHook(handleSignal)

  echo "Serving directory ", serveDir.absolutePath, " on http://", host, ":", port
  echo "Press Ctrl+C to stop"
  echo ""

  waitFor server.serve(Port(port), cb, host)

# Run the main procedure
main()
