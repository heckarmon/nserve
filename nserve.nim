import asynchttpserver, asyncdispatch, os, strutils, uri, parseopt, times, net, asyncnet

const VERSION = "1.0.3"

# --------------------------
# Helper / Usage
# --------------------------

proc showHelp() =
  echo """
nserve v""" & VERSION & """ - A lightweight Async HTTP File Server

Usage:
  nserve [options] [directory]

Options:
  -p, --port        Set the port (default: 8000)
  -H, --host        Set the host address (default: 0.0.0.0)
  -d, --dir         Set the directory to serve (default: current dir)
  -m, --max-size    Set max upload size in MB (default: 100)
  -v, --version     Show version information
  -h, --help        Show this help message

Syntax Notes:
  • Short flags (-d, -p) use space or colon:   -d ./waw  OR  -d:./waw
  • Long flags (--dir) use equals or colon:    --dir=./waw

Examples:
  nserve ./waw                # Serve directory directly (Recommended)
  nserve -p 8080              # Serve current dir on port 8080
  nserve -d:./html -p:3000    # Short options with colons
  nserve --dir=/var/www       # Long options
  nserve -m 500               # Allow uploads up to 500MB
  nserve --max-size=1024      # Allow uploads up to 1GB

Upload via CLI (curl):
  curl -F "file=@document.pdf" http://localhost:8000/path/to/dir/
  curl -F "file=@image.png" http://192.168.1.100:8080/uploads/
"""
  quit(0)

proc showVersion() =
  echo "nserve v", VERSION
  echo "A lightweight Async HTTP File Server"
  echo "Built with Nim - Zero runtime dependencies"
  quit(0)

# --------------------------
# Utility Functions
# --------------------------

proc formatFileSize(bytes: int64): string =
  ## Format bytes into human-readable size
  const units = ["B", "KB", "MB", "GB", "TB"]
  var size = bytes.float
  var unitIndex = 0
  
  while size >= 1024.0 and unitIndex < units.high:
    size = size / 1024.0
    inc unitIndex
  
  if unitIndex == 0:
    result = $bytes & " " & units[0]
  else:
    result = size.formatFloat(ffDecimal, 1) & " " & units[unitIndex]

proc formatTimeAgo(modTime: Time): string =
  ## Format time as relative "X ago" string
  let now = getTime()
  let diff = now - modTime
  let seconds = diff.inSeconds
  
  if seconds < 60:
    result = $seconds & " sec ago"
  elif seconds < 3600:
    let mins = seconds div 60
    result = $mins & " min ago"
  elif seconds < 86400:
    let hours = seconds div 3600
    result = $hours & " hour" & (if hours > 1: "s" else: "") & " ago"
  elif seconds < 2592000:  # 30 days
    let days = seconds div 86400
    result = $days & " day" & (if days > 1: "s" else: "") & " ago"
  elif seconds < 31536000:  # 365 days
    let months = seconds div 2592000
    result = $months & " month" & (if months > 1: "s" else: "") & " ago"
  else:
    let years = seconds div 31536000
    result = $years & " year" & (if years > 1: "s" else: "") & " ago"

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
  --meta-color: #888888;
}
body.dark {
  --bg: #121212;
  --text: #eeeeee;
  --card: #1e1e1e;
  --dir-color: #6db3ff;
  --file-color: #aaaaaa;
  --parent-color: #ffb340;
  --meta-color: #999999;
}
body {
  background: var(--bg);
  color: var(--text);
  font-family: sans-serif;
  padding: 20px;
}
a {
  color: inherit;
  text-decoration: none;
  display: flex;
  align-items: center;
  gap: 8px;
  width: 100%;
}
.card {
  background: var(--card);
  padding: 12px;
  border-radius: 8px;
  margin-bottom: 8px;
  transition: transform 0.1s;
}
.card:hover {
  transform: translateX(4px);
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
.file-info {
  display: flex;
  flex-direction: column;
  flex: 1;
}
.file-name {
  font-weight: 500;
}
.file-meta {
  font-size: 0.85em;
  color: var(--meta-color);
  margin-top: 2px;
}
button { padding: 6px 10px; cursor: pointer; }
button:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}
.error { color: #ff4444; margin-top: 10px; font-weight: bold; }
.warning { color: #ff9500; margin-top: 5px; font-size: 0.9em; }
.footer {
  margin-top: 40px;
  padding-top: 20px;
  border-top: 1px solid var(--card);
  font-size: 0.85em;
  opacity: 0.6;
  text-align: center;
}
</style>
</head>
<body>
<button onclick="toggleTheme()">Toggle Theme</button>
""" & body & """
<div class="footer">nserve v""" & VERSION & """</div>
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

proc dirListing(path: string, urlPath: string, maxSizeMB: int): string =
  var content = "<h1>Index of " & urlPath & "</h1>"

  let maxSizeBytes = maxSizeMB * 1024 * 1024
  
  content.add("""
<form method="POST" enctype="multipart/form-data" id="uploadForm">
  <input type="file" name="file" id="fileInput">
  <button type="submit" id="uploadBtn">Upload</button>
  <span style="margin-left: 10px; font-size: 0.9em; opacity: 0.7;">Max: """ & $maxSizeMB & """ MB</span>
  <div id="fileWarning" class="warning" style="display: none;"></div>
</form>
<hr>

<script>
const maxSize = """ & $maxSizeBytes & """;
const fileInput = document.getElementById('fileInput');
const uploadBtn = document.getElementById('uploadBtn');
const fileWarning = document.getElementById('fileWarning');
const uploadForm = document.getElementById('uploadForm');

fileInput.addEventListener('change', function() {
  if (this.files.length > 0) {
    const file = this.files[0];
    const fileSizeMB = (file.size / (1024 * 1024)).toFixed(2);
    
    if (file.size > maxSize) {
      uploadBtn.disabled = true;
      fileWarning.style.display = 'block';
      fileWarning.textContent = '⚠ File too large: ' + fileSizeMB + ' MB (max: """ & $maxSizeMB & """ MB)';
      fileWarning.style.color = '#ff4444';
    } else {
      uploadBtn.disabled = false;
      fileWarning.style.display = 'block';
      fileWarning.textContent = '✓ File size: ' + fileSizeMB + ' MB';
      fileWarning.style.color = '#4da3ff';
    }
  } else {
    uploadBtn.disabled = false;
    fileWarning.style.display = 'none';
  }
});

uploadForm.addEventListener('submit', function(e) {
  if (uploadBtn.disabled) {
    e.preventDefault();
    alert('Please select a file within the size limit.');
  }
});
</script>
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
        "<a href='" & parentPath & "'>" &
        "<span class='icon'>⬆️</span>" &
        "<div class='file-info'>" &
        "<span class='file-name'>.. (Parent Directory)</span>" &
        "</div>" &
        "</a>" &
        "</div>"
      )

  # Collect directories and files with metadata
  type FileEntry = object
    name: string
    isDir: bool
    size: int64
    modTime: Time

  var entries: seq[FileEntry] = @[]

  for kind, filePath in walkDir(path):
    let name = extractFilename(filePath)
    var entry = FileEntry(name: name, isDir: kind == pcDir)
    
    try:
      let info = getFileInfo(filePath)
      entry.size = info.size
      entry.modTime = info.lastWriteTime
    except:
      entry.size = 0
      entry.modTime = getTime()
    
    entries.add(entry)

  # Separate and sort
  var dirs: seq[FileEntry] = @[]
  var files: seq[FileEntry] = @[]
  
  for entry in entries:
    if entry.isDir:
      dirs.add(entry)
    else:
      files.add(entry)

  var prefix = urlPath
  if not prefix.endsWith("/"):
    prefix &= "/"

  # Display directories
  for entry in dirs:
    let encodedName = encodeUrl(entry.name, usePlus = false)
    let timeAgo = formatTimeAgo(entry.modTime)
    
    content.add(
      "<div class='card dir'>" &
      "<a href='" & prefix & encodedName & "/'>" &
      "<span class='icon'>📁</span>" &
      "<div class='file-info'>" &
      "<span class='file-name'>" & entry.name & "/</span>" &
      "<span class='file-meta'>" & timeAgo & "</span>" &
      "</div>" &
      "</a>" &
      "</div>"
    )

  # Display files
  for entry in files:
    let encodedName = encodeUrl(entry.name, usePlus = false)
    let sizeStr = formatFileSize(entry.size)
    let timeAgo = formatTimeAgo(entry.modTime)
    
    content.add(
      "<div class='card file'>" &
      "<a href='" & prefix & encodedName & "'>" &
      "<span class='icon'>📄</span>" &
      "<div class='file-info'>" &
      "<span class='file-name'>" & entry.name & "</span>" &
      "<span class='file-meta'>" & sizeStr & " • " & timeAgo & "</span>" &
      "</div>" &
      "</a>" &
      "</div>"
    )

  pageTemplate("Index of " & urlPath, content)

# --------------------------
# Upload Handling
# --------------------------

proc handleUpload(req: Request, path: string, maxSizeBytes: int): tuple[success: bool, error: string] =
  if req.headers.getOrDefault("Content-Type").startsWith("multipart/form-data"):
    let data = req.body

    # Check size limit
    if data.len > maxSizeBytes:
      return (false, "File too large. Maximum size: " & $(maxSizeBytes div (1024 * 1024)) & " MB")

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
              return (false, "No file selected")
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
        try:
          writeFile(fullPath, fileData)
          return (true, "")
        except IOError as e:
          return (false, "Failed to write file: " & e.msg)

  return (false, "Invalid upload request")

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
  var maxSizeMB = 100  # Default 100MB

  # State flags for parsing split arguments (e.g., -d ./folder)
  var expectingDir = false
  var expectingPort = false
  var expectingHost = false
  var expectingMaxSize = false

  var p = initOptParser()
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      # Reset expectation flags if a new flag is found
      expectingDir = false; expectingPort = false; expectingHost = false; expectingMaxSize = false

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
      of "m", "max-size":
        if p.val.len > 0: maxSizeMB = parseInt(p.val)
        else: expectingMaxSize = true
      of "v", "version":
        showVersion()
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
      elif expectingMaxSize:
        maxSizeMB = parseInt(p.key)
        expectingMaxSize = false
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

  # Convert MB to bytes
  let maxSizeBytes = maxSizeMB * 1024 * 1024

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
      let (success, error) = handleUpload(req, fsPath, maxSizeBytes)
      if success:
        statusCode = Http200
        logRequest(req.reqMethod, req.url.path, statusCode, clientAddr)
        await req.respond(
          statusCode,
          pageTemplate("Uploaded",
            "<h2>✓ File uploaded successfully.</h2><a href='" & req.url.path & "'>Back</a>"
          )
        )
      else:
        statusCode = Http413  # Payload Too Large
        logRequest(req.reqMethod, req.url.path, statusCode, clientAddr)
        await req.respond(
          statusCode,
          pageTemplate("Upload Failed",
            "<h2>✗ Upload Failed</h2><p class='error'>" & error & "</p><a href='" & req.url.path & "'>Back</a>"
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
      await req.respond(statusCode, dirListing(fsPath, req.url.path, maxSizeMB))

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

  echo "nserve v", VERSION
  echo "Serving directory ", serveDir.absolutePath, " on http://", host, ":", port
  echo "Max upload size: ", maxSizeMB, " MB"
  echo "Press Ctrl+C to stop"
  echo ""

  waitFor server.serve(Port(port), cb, host)

# Run the main procedure
main()