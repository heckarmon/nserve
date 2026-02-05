import asynchttpserver, asyncdispatch, os, strutils, uri, parseopt, times, net, asyncnet

let server = newAsyncHttpServer()

# --------------------------
# CLI Arguments
# --------------------------

var port = 8000
var host = "0.0.0.0"

var p = initOptParser()
while true:
  p.next()
  case p.kind
  of cmdEnd: break
  of cmdShortOption, cmdLongOption:
    case p.key
    of "p", "port":
      port = parseInt(p.val.strip())
    of "h", "host":
      host = p.val.strip()
    else:
      echo "Unknown option: ", p.key
  of cmdArgument:
    discard

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
  var content = "<h1>Directory listing for " & urlPath & "</h1>"

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
    # Remove trailing slash if present
    if parentPath.endsWith("/"):
      parentPath = parentPath[0 ..< parentPath.len - 1]
    # Get parent directory
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

  # Separate directories and files
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

  # Show directories first
  for name in dirs:
    # Only encode the filename, not the full path
    let encodedName = encodeUrl(name, usePlus = false)
    content.add(
      "<div class='card dir'>" &
      "<span class='icon'>📁</span>" &
      "<a href='" & prefix & encodedName & "/'>" & name & "/</a>" &
      "</div>"
    )

  # Then show files
  for name in files:
    # Only encode the filename, not the full path
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

    # Extract filename from Content-Disposition header
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
            if filename == "":
              return
            break

    # Extract file content
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
# Request Callback
# --------------------------

proc cb(req: Request) {.async, gcsafe.} =
  var fsPath = "." & req.url.path
  var statusCode = Http200

  # Determine client address
  # We import asyncnet to allow getPeerAddr on AsyncSocket
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
# Signal Handler
# --------------------------

proc handleSignal() {.noconv.} =
  echo "\nShutting down server..."
  quit(0)

setControlCHook(handleSignal)

echo "Serving on http://", host, ":", port
echo "Press Ctrl+C to stop"
echo ""
waitFor server.serve(Port(port), cb, host)
