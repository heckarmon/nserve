import asynchttpserver, asyncdispatch, os, strutils, uri, parseopt, times, net
import streams

const VERSION = "1.0.4"

# --------------------------
# EMBEDDED JS LIBRARY
# --------------------------
const QR_LIB = staticRead("static/qrcode.min.js")

# --------------------------
# ZIP Implementation (Zero Dependency)
# --------------------------

type
  ZipFileEntry = object
    name: string
    data: string
    crc32: uint32
    uncompressedSize: uint32
    compressedSize: uint32
    localHeaderOffset: uint32

proc crc32(data: string): uint32 =
  const crcTable = block:
    var table: array[256, uint32]
    for i in 0..255:
      var c = uint32(i)
      for j in 0..7:
        if (c and 1) != 0: c = 0xEDB88320'u32 xor (c shr 1)
        else: c = c shr 1
      table[i] = c
    table

  var crc = 0xFFFFFFFF'u32
  for b in data:
    crc = crcTable[int((crc xor uint32(b)) and 0xFF)] xor (crc shr 8)
  return not crc

proc writeUint16LE(s: Stream, val: uint16) = s.write(val)
proc writeUint32LE(s: Stream, val: uint32) = s.write(val)

proc createZipFile(files: var seq[ZipFileEntry]): string =
  var zipStream = newStringStream()
  var centralDir = newStringStream()

  for i in 0..<files.len:
    files[i].localHeaderOffset = uint32(zipStream.getPosition())

    # Local File Header
    zipStream.writeUint32LE(0x04034b50'u32)
    zipStream.writeUint16LE(20)
    zipStream.writeUint16LE(0)
    zipStream.writeUint16LE(0) # No compression (Stored)
    zipStream.writeUint16LE(0)
    zipStream.writeUint16LE(0)
    zipStream.writeUint32LE(files[i].crc32)
    zipStream.writeUint32LE(files[i].compressedSize)
    zipStream.writeUint32LE(files[i].uncompressedSize)
    zipStream.writeUint16LE(uint16(files[i].name.len))
    zipStream.writeUint16LE(0)

    zipStream.write(files[i].name)
    zipStream.write(files[i].data)

    # Central Directory Header
    centralDir.writeUint32LE(0x02014b50'u32)
    centralDir.writeUint16LE(20)
    centralDir.writeUint16LE(20)
    centralDir.writeUint16LE(0)
    centralDir.writeUint16LE(0)
    centralDir.writeUint16LE(0)
    centralDir.writeUint16LE(0)
    centralDir.writeUint32LE(files[i].crc32)
    centralDir.writeUint32LE(files[i].compressedSize)
    centralDir.writeUint32LE(files[i].uncompressedSize)
    centralDir.writeUint16LE(uint16(files[i].name.len))
    centralDir.writeUint16LE(0)
    centralDir.writeUint16LE(0)
    centralDir.writeUint16LE(0)
    centralDir.writeUint16LE(0)
    centralDir.writeUint32LE(0)
    centralDir.writeUint32LE(files[i].localHeaderOffset)

    centralDir.write(files[i].name)

  let centralDirOffset = uint32(zipStream.getPosition())
  let centralDirSize = uint32(centralDir.getPosition())

  centralDir.setPosition(0)
  zipStream.write(centralDir.readAll())

  # End of Central Directory
  zipStream.writeUint32LE(0x06054b50'u32)
  zipStream.writeUint16LE(0)
  zipStream.writeUint16LE(0)
  zipStream.writeUint16LE(uint16(files.len))
  zipStream.writeUint16LE(uint16(files.len))
  zipStream.writeUint32LE(centralDirSize)
  zipStream.writeUint32LE(centralDirOffset)
  zipStream.writeUint16LE(0)

  zipStream.setPosition(0)
  return zipStream.readAll()

proc zipDirectory(dirPath: string): string =
  var entries: seq[ZipFileEntry] = @[]
  # Ensure base path does not have trailing slash for consistent replacement
  let basePath = if dirPath.endsWith($DirSep): dirPath[0 ..< ^1] else: dirPath

  # FIX: walkDirRec only yields 'path', not 'kind, path'
  for path in walkDirRec(dirPath, yieldFilter = {pcFile}):

    # Calculate relative path inside ZIP
    # We use basePath location to slice the string
    # We add 1 to length to skip the slash separator
    var relativePath = path[basePath.len+1 .. ^1]

    # Standardize to forward slashes for ZIP spec (Windows fix)
    relativePath = relativePath.replace('\\', '/')

    let fileData = readFile(path)

    entries.add(ZipFileEntry(
      name: relativePath,
      data: fileData,
      crc32: crc32(fileData),
      uncompressedSize: uint32(fileData.len),
      compressedSize: uint32(fileData.len)
    ))

  return createZipFile(entries)

# --------------------------
# Helpers & UI
# --------------------------

proc formatFileSize(bytes: int64): string =
  const units = ["B", "KB", "MB", "GB", "TB"]
  var size = bytes.float
  var unitIndex = 0
  while size >= 1024.0 and unitIndex < units.high:
    size = size / 1024.0
    inc unitIndex
  if unitIndex == 0: result = $bytes & " " & units[0]
  else: result = size.formatFloat(ffDecimal, 1) & " " & units[unitIndex]

proc formatTimeAgo(modTime: Time): string =
  let now = getTime()
  let diff = now - modTime
  let seconds = diff.inSeconds
  if seconds < 60: result = $seconds & " sec ago"
  elif seconds < 3600: result = $(seconds div 60) & " min ago"
  elif seconds < 86400: result = $(seconds div 3600) & " hours ago"
  else: result = $(seconds div 86400) & " days ago"

proc showHelp() =
  echo """nserve v""" & VERSION & """
Usage: nserve [options] [directory]
  -p, --port      Port (8000)
  -H, --host      Host (0.0.0.0)
  -d, --dir       Directory (.)
  -m, --max-size  Max upload MB (100)"""
  quit(0)

proc showVersion() =
  echo "nserve v", VERSION
  quit(0)

proc logRequest(reqMethod: HttpMethod, path: string, statusCode: HttpCode,
    clientAddr: string) =
  let timestamp = now().format("yyyy-MM-dd HH:mm:ss")
  let statusInt = statusCode.int
  let methodColor = case reqMethod
    of HttpGet: "\e[32m"
    of HttpPost: "\e[33m"
    else: "\e[37m"
  let statusColor = if statusInt < 300: "\e[32m" elif statusInt <
      400: "\e[36m" else: "\e[31m"
  echo "[", timestamp, "] ", "\e[36m", clientAddr.alignLeft(21), "\e[0m ",
       methodColor, ($reqMethod).alignLeft(7), "\e[0m ",
       " ", statusColor, $statusInt, "\e[0m ", " ", path

# --------------------------
# HTML Template
# --------------------------

proc pageTemplate(title, body: string): string =
  """
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>""" & title &
      """</title>
<style>
:root { --bg: #fff; --text: #111; --card: #f4f4f4; --dir: #4da3ff; --file: #666; --meta: #888; --modal: rgba(0,0,0,0.8); }
body.dark { --bg: #121212; --text: #eee; --card: #1e1e1e; --dir: #6db3ff; --file: #aaa; --meta: #999; --modal: rgba(255,255,255,0.1); }
body { background: var(--bg); color: var(--text); font-family: sans-serif; padding: 20px; }
a { color: inherit; text-decoration: none; display: flex; align-items: center; gap: 8px; width: 100%; }
.card { background: var(--card); padding: 12px; border-radius: 8px; margin-bottom: 8px; display: flex; justify-content: space-between; align-items: center; }
.card:hover { transform: translateX(4px); transition: 0.1s; }
.card-left { display: flex; align-items: center; gap: 8px; flex: 1; overflow: hidden; }
.card.dir { border-left: 4px solid var(--dir); }
.card.file { border-left: 4px solid var(--file); }
.icon { font-size: 20px; min-width: 24px; }
.file-info { display: flex; flex-direction: column; flex: 1; overflow: hidden; }
.file-name { font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.file-meta { font-size: 0.85em; color: var(--meta); }
.btn { padding: 4px 8px; border-radius: 4px; cursor: pointer; border: 1px solid var(--meta); background: none; color: var(--text); font-size: 0.8em; margin-left: 5px; opacity: 0.7; }
.btn:hover { opacity: 1; background: var(--card); }
#qrModal { display: none; position: fixed; inset: 0; background: var(--modal); align-items: center; justify-content: center; z-index: 1000; }
.modal-content { background: #fff; padding: 20px; border-radius: 10px; text-align: center; max-width: 300px; color: #000; }
</style>
</head>
<body>
<button onclick="toggleTheme()" style="padding:6px 10px; cursor:pointer;">Toggle Theme</button>
""" & body &
      """
<div style="margin-top:40px; text-align:center; opacity:0.6; font-size:0.8em; border-top:1px solid #ccc; padding-top:20px;">nserve v""" &
      VERSION &
      """</div>

<div id="qrModal" onclick="closeQR()">
  <div class="modal-content" onclick="event.stopPropagation()">
    <h3>Scan to Download</h3>
    <div id="qrPlaceholder" style="display:flex; justify-content:center; margin:10px 0;"></div>
    <div id="qrLink" style="font-size:0.75em; word-break:break-all; color:#555;"></div>
    <button class="btn" style="width:100%; margin-top:10px; background:#eee; color:#000;" onclick="closeQR()">Close</button>
  </div>
</div>

<script>
""" & QR_LIB & """
</script>
<script>
if (localStorage.getItem('theme') === 'dark') document.body.classList.add('dark');
function toggleTheme() {
  document.body.classList.toggle('dark');
  localStorage.setItem('theme', document.body.classList.contains('dark') ? 'dark' : 'light');
}
function showQR(path) {
  const fullUrl = window.location.protocol + "//" + window.location.host + path;
  document.getElementById("qrPlaceholder").innerHTML = "";
  document.getElementById("qrLink").innerText = fullUrl;
  new QRCode(document.getElementById("qrPlaceholder"), { text: fullUrl, width: 200, height: 200 });
  document.getElementById('qrModal').style.display = "flex";
}
function closeQR() { document.getElementById('qrModal').style.display = "none"; }
document.addEventListener('keydown', (e) => { if (e.key === "Escape") closeQR(); });
</script>
</body>
</html>
"""

# --------------------------
# Directory Logic
# --------------------------

proc dirListing(path: string, urlPath: string, maxSizeMB: int): string =
  var content = "<h1>Index of " & urlPath & "</h1>"
  let maxBytes = maxSizeMB * 1024 * 1024

  content.add("""
<form method="POST" enctype="multipart/form-data" id="uForm">
  <input type="file" name="file" id="fIn">
  <button type="submit" id="uBtn">Upload</button>
  <span style="font-size:0.8em; margin-left:5px;">Max: """ & $maxSizeMB &
      """MB</span>
  <div id="fWarn" style="display:none; font-weight:bold; margin-top:5px;"></div>
</form>
<hr>
<script>
const max = """ & $maxBytes & """;
const fIn = document.getElementById('fIn');
const uBtn = document.getElementById('uBtn');
const fWarn = document.getElementById('fWarn');
fIn.addEventListener('change', function() {
  if (this.files.length > 0) {
    const sz = this.files[0].size;
    const mb = (sz/1048576).toFixed(2);
    if (sz > max) {
       uBtn.disabled = true; fWarn.style.display='block'; fWarn.style.color='red'; fWarn.textContent='⚠ Too large: '+mb+'MB';
    } else {
       uBtn.disabled = false; fWarn.style.display='block'; fWarn.style.color='green'; fWarn.textContent='✓ '+mb+'MB';
    }
  }
});
</script>
""")

  if urlPath != "/":
    var pPath = urlPath
    if pPath.endsWith("/"): pPath = pPath[0 ..< ^1]
    let slash = pPath.rfind('/')
    if slash >= 0: pPath = pPath[0 ..< slash]
    if pPath == "": pPath = "/"
    content.add("<div class='card parent'><div class='card-left'><a href='" &
        pPath & "'><span class='icon'>⬆️</span><span>.. (Parent)</span></a></div></div>")

  var dirs: seq[tuple[name: string, time: Time]] = @[]
  var files: seq[tuple[name: string, size: int64, time: Time]] = @[]

  for kind, p in walkDir(path):
    let n = extractFilename(p)
    try:
      let i = getFileInfo(p)
      if kind == pcDir: dirs.add((n, i.lastWriteTime))
      else: files.add((n, i.size, i.lastWriteTime))
    except: discard

  # Directories
  for d in dirs:
    let enc = encodeUrl(d.name, usePlus = false)
    let zipUrl = (if urlPath.endsWith("/"): urlPath else: urlPath & "/") & enc & "?zip=1"
    content.add(
      "<div class='card dir'><div class='card-left'><a href='" & enc &
      "/'><span class='icon'>📁</span>" &
      "<div class='file-info'><span class='file-name'>" & d.name & "/</span>" &
      "<span class='file-meta'>" & formatTimeAgo(d.time) &
          "</span></div></a></div>" &
      "<a href='" & zipUrl & "' download='" & d.name &
          ".zip' style='width:auto;'><button class='btn'>📦 ZIP</button></a>" &
      "</div>"
    )

  # Files
  for f in files:
    let enc = encodeUrl(f.name, usePlus = false)
    let url = (if urlPath.endsWith("/"): urlPath else: urlPath & "/") & enc
    content.add(
      "<div class='card file'><div class='card-left'><a href='" & enc &
      "'><span class='icon'>📄</span>" &
      "<div class='file-info'><span class='file-name'>" & f.name & "</span>" &
      "<span class='file-meta'>" & formatFileSize(f.size) & " • " &
          formatTimeAgo(f.time) & "</span></div></a></div>" &
      "<button class='btn' onclick=\"showQR('" & url & "')\">📱 QR</button></div>"
    )

  pageTemplate("Index of " & urlPath, content)

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
# Main
# --------------------------

proc main() =
  var port = 8000
  var host = "0.0.0.0"
  var serveDir = "."
  var maxSizeMB = 100

  var p = initOptParser()
  while true:
    p.next()
    case p.kind
    of cmdEnd: break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "p", "port": port = parseInt(p.val)
      of "H", "host": host = p.val
      of "d", "dir": serveDir = p.val
      of "m", "max-size": maxSizeMB = parseInt(p.val)
      of "v", "version": showVersion()
      of "h", "help": showHelp()
    of cmdArgument: serveDir = p.key

  if serveDir.len > 1 and serveDir.endsWith(DirSep): serveDir = serveDir[0 ..< ^1]
  if not dirExists(serveDir):
    echo "Error: Directory not found"
    quit(1)

  let maxBytes = maxSizeMB * 1024 * 1024

  proc cb(req: Request) {.async, gcsafe.} =
    let urlPath = req.url.path.decodeUrl()
    let relPath = if urlPath.startsWith("/"): urlPath[1..^1] else: urlPath
    let fsPath = serveDir / relPath
    let client = req.hostname # Async simpler client IP

    # 1. HANDLE ZIP DOWNLOAD
    if req.url.query.contains("zip=1") and dirExists(fsPath):
      try:
        echo "Creating ZIP for: ", fsPath
        # Directly get string data from memory (FIXED HERE)
        let zipData = zipDirectory(fsPath)
        let dirName = extractFilename(fsPath)
        let zipName = if dirName == "": "root.zip" else: dirName & ".zip"

        logRequest(req.reqMethod, req.url.path & " (ZIP)", Http200, client)
        await req.respond(Http200, zipData, newHttpHeaders([
          ("Content-Type", "application/zip"),
          ("Content-Disposition", "attachment; filename=\"" & zipName & "\"")
        ]))
      except Exception as e:
        echo "ZIP Error: ", e.msg
        await req.respond(Http500, "Error creating ZIP: " & e.msg)
      return

    # 2. HANDLE UPLOAD
    if req.reqMethod == HttpPost and dirExists(fsPath):
      let data = req.body
      if data.len > maxBytes:
        await req.respond(Http413, pageTemplate("Error",
            "<h1>File too large</h1>"))
        return

      # Simple parser
      if "filename=\"" in data:
        let s = data.find("filename=\"") + 10
        let e = data.find("\"", s)
        let fname = data[s ..< e]
        if fname.len > 0:
          let bStart = data.find("\r\n\r\n")
          if bStart != -1:
            let content = data[bStart+4 ..< ^1] # Rough trim, works for simple uploads
 # Basic trim of trailing boundary (approximate)
            let realEnd = content.rfind("------WebKitFormBoundary")
            if realEnd > 0:
              try:
                writeFile(fsPath / fname, content[0 ..< realEnd-2])
                logRequest(req.reqMethod, req.url.path, Http200, client)
                await req.respond(Http200, pageTemplate("Success",
                    "<h1>Uploaded!</h1><a href='"&req.url.path&"'>Back</a>"))
                return
              except: discard

      await req.respond(Http400, pageTemplate("Error",
          "<h1>Upload Failed</h1>"))
      return

    # 3. SERVE FILES / DIRS
    if dirExists(fsPath):
      if not req.url.path.endsWith("/"):
        if fileExists(fsPath / "index.html"):
          await req.respond(Http200, readFile(fsPath / "index.html"),
              newHttpHeaders([("Content-Type", "text/html")]))
          return
      logRequest(req.reqMethod, req.url.path, Http200, client)
      await req.respond(Http200, dirListing(fsPath, req.url.path, maxSizeMB))
    elif fileExists(fsPath):
      logRequest(req.reqMethod, req.url.path, Http200, client)
      let ext = splitFile(fsPath).ext.toLowerAscii
      let mime = getMime(ext)
      await req.respond(Http200, readFile(fsPath), newHttpHeaders([(
          "Content-Type", mime)]))
    else:
      logRequest(req.reqMethod, req.url.path, Http404, client)
      await req.respond(Http404, pageTemplate("404", "<h1>Not Found</h1>"))

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

main()
