import asynchttpserver, asyncdispatch, os, strutils, uri, parseopt, times, strformat
import streams

const
  VERSION = "1.0.4"
  # Embed JS/CSS here to keep logic clean
  QR_LIB = staticRead("static/qrcode.min.js")
  CSS_STYLES = """
    :root { --bg: #fff; --text: #111; --card: #f4f4f4; --dir: #4da3ff; --file: #666; --meta: #888; --modal: rgba(0,0,0,0.8); }
    body.dark { --bg: #121212; --text: #eee; --card: #1e1e1e; --dir: #6db3ff; --file: #aaa; --meta: #999; --modal: rgba(255,255,255,0.1); }
    body { background: var(--bg); color: var(--text); font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; padding: 20px; }
    a { color: inherit; text-decoration: none; display: flex; align-items: center; gap: 8px; width: 100%; }
    .card { background: var(--card); padding: 12px; border-radius: 8px; margin-bottom: 8px; display: flex; justify-content: space-between; align-items: center; }
    .card:hover { transform: translateX(4px); transition: 0.1s; }
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
  """

# ---------------------------------------------------------------------------
# ZIP IMPLEMENTATION
# ---------------------------------------------------------------------------

# 1. Define this FIRST
type DosFileTime = uint32

# 2. Now you can use it here
type ZipFileEntry = object
  name: string
  data: string
  crc32: uint32
  time: DosFileTime
  uncompressedSize: uint32
  compressedSize: uint32
  localHeaderOffset: uint32

# Helper to convert Nim time to MS-DOS time format for ZIP
proc toDosTime(t: Time): DosFileTime =
  let dt = t.local()
  let year = (dt.year - 1980).uint32
  let month = dt.month.uint32
  let day = dt.monthday.uint32
  let hour = dt.hour.uint32
  let minute = dt.minute.uint32
  let second = (dt.second div 2).uint32
  return (year shl 25) or (month shl 21) or (day shl 16) or (hour shl 11) or (
      minute shl 5) or second

proc crc32(data: string): uint32 =
  var table: array[256, uint32]
  for i in 0..255:
    var c = uint32(i)
    for j in 0..7:
      if (c and 1) != 0: c = 0xEDB88320'u32 xor (c shr 1)
      else: c = c shr 1
    table[i] = c
  result = 0xFFFFFFFF'u32
  for b in data:
    result = table[int((result xor uint32(b)) and 0xFF)] xor (result shr 8)
  return not result

proc writeUint16LE(s: Stream, val: uint16) = s.write(val)
proc writeUint32LE(s: Stream, val: uint32) = s.write(val)

proc createZipFile(files: var seq[ZipFileEntry]): string =
  var zipStream = newStringStream()
  var centralDir = newStringStream()

  for i in 0..<files.len:
    files[i].localHeaderOffset = uint32(zipStream.getPosition())

    # --- Local File Header ---
    zipStream.writeUint32LE(0x04034b50'u32) # Signature
    zipStream.writeUint16LE(20) # Version needed
    zipStream.writeUint16LE(0) # Flags
    zipStream.writeUint16LE(0) # Compression (0 = Store)
    zipStream.writeUint32LE(files[i].time) # Mod Time/Date
    zipStream.writeUint32LE(files[i].crc32) # CRC32
    zipStream.writeUint32LE(files[i].compressedSize)
    zipStream.writeUint32LE(files[i].uncompressedSize)
    zipStream.writeUint16LE(uint16(files[i].name.len))
    zipStream.writeUint16LE(0) # Extra field length

    zipStream.write(files[i].name)
    zipStream.write(files[i].data)

    # --- Central Directory Header ---
    centralDir.writeUint32LE(0x02014b50'u32) # Signature
    centralDir.writeUint16LE(20) # Version made by
    centralDir.writeUint16LE(20) # Version needed
    centralDir.writeUint16LE(0) # Flags
    centralDir.writeUint16LE(0) # Compression
    centralDir.writeUint32LE(files[i].time) # Mod Time/Date
    centralDir.writeUint32LE(files[i].crc32) # CRC32
    centralDir.writeUint32LE(files[i].compressedSize)
    centralDir.writeUint32LE(files[i].uncompressedSize)
    centralDir.writeUint16LE(uint16(files[i].name.len))
    centralDir.writeUint16LE(0) # Extra field len
    centralDir.writeUint16LE(0) # File comment len
    centralDir.writeUint16LE(0) # Disk number start
    centralDir.writeUint16LE(0) # Internal attrs
    centralDir.writeUint32LE(0) # External attrs
    centralDir.writeUint32LE(files[i].localHeaderOffset) # Rel offset

    centralDir.write(files[i].name)

  # Calculate offsets for EOCD
  let centralDirStart = uint32(zipStream.getPosition())
  let centralDirSize = uint32(centralDir.getPosition())

  # Append Central Directory to main stream
  centralDir.setPosition(0)
  zipStream.write(centralDir.readAll())

  # --- End of Central Directory Record ---
  zipStream.writeUint32LE(0x06054b50'u32) # Signature
  zipStream.writeUint16LE(0) # Disk number
  zipStream.writeUint16LE(0) # Disk number with CD
  zipStream.writeUint16LE(uint16(files.len)) # Entries on this disk
  zipStream.writeUint16LE(uint16(files.len)) # Total entries
  zipStream.writeUint32LE(centralDirSize) # Size of CD
  zipStream.writeUint32LE(centralDirStart) # Offset of CD start
  zipStream.writeUint16LE(0) # Comment len

  zipStream.setPosition(0)
  return zipStream.readAll()

proc zipDirectory(dirPath: string): string =
  var entries: seq[ZipFileEntry] = @[]
  let basePath = if dirPath.endsWith($DirSep): dirPath[0 ..< ^1] else: dirPath

  for path in walkDirRec(dirPath, yieldFilter = {pcFile}):
    # Create relative path (e.g., "css/style.css")
    var relativePath = path[basePath.len+1 .. ^1]

    # ZIP standard requires forward slashes
    relativePath = relativePath.replace('\\', '/')

    let fileData = readFile(path)
    let info = getFileInfo(path)

    entries.add(ZipFileEntry(
      name: relativePath,
      data: fileData,
      crc32: crc32(fileData),
      time: toDosTime(info.lastWriteTime),
      uncompressedSize: uint32(fileData.len),
      compressedSize: uint32(fileData.len)
    ))

  return createZipFile(entries)

# ---------------------------------------------------------------------------
# UI / TEMPLATING
# ---------------------------------------------------------------------------

proc formatFileSize(bytes: int64): string =
  if bytes == 0: return "0 B"
  const units = ["B", "KB", "MB", "GB", "TB"]
  var size = bytes.float; var i = 0
  while size >= 1024.0 and i < units.high: size /= 1024.0; inc i
  return fmt"{size:.1f} {units[i]}"

proc formatTimeAgo(modTime: Time): string =
  let s = (getTime() - modTime).inSeconds
  if s < 60: return fmt"{s} sec ago"
  if s < 3600: return fmt"{s div 60} min ago"
  if s < 86400: return fmt"{s div 3600} hours ago"
  return fmt"{s div 86400} days ago"

proc renderPage(title, body: string): string =
  fmt"""
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{title}</title>
  <style>{CSS_STYLES}</style>
</head>
<body>
  <div style="display:flex; justify-content:space-between; align-items:center;">
    <h3>nserve</h3>
    <button onclick="toggleTheme()" class="btn">🌗 Theme</button>
  </div>
  {body}
  <div style="margin-top:40px; text-align:center; opacity:0.6; font-size:0.8em; border-top:1px solid #ccc; padding-top:20px;">
    nserve v{VERSION}
  </div>

  <div id="qrModal" onclick="closeQR()">
    <div class="modal-content" onclick="event.stopPropagation()">
      <h3>Scan to Download</h3>
      <div id="qrPlaceholder" style="display:flex; justify-content:center; margin:10px 0;"></div>
      <div id="qrLink" style="font-size:0.75em; word-break:break-all; color:#555;"></div>
      <button class="btn" style="width:100%; margin-top:10px;" onclick="closeQR()">Close</button>
    </div>
  </div>

  <script>{QR_LIB}</script>
  <script>
    if (localStorage.getItem('theme') === 'dark') document.body.classList.add('dark');
    function toggleTheme() {{
      document.body.classList.toggle('dark');
      localStorage.setItem('theme', document.body.classList.contains('dark') ? 'dark' : 'light');
    }}
    function showQR(path) {{
      const fullUrl = window.location.protocol + "//" + window.location.host + path;
      document.getElementById("qrPlaceholder").innerHTML = "";
      document.getElementById("qrLink").innerText = fullUrl;
      new QRCode(document.getElementById("qrPlaceholder"), {{ text: fullUrl, width: 200, height: 200 }});
      document.getElementById('qrModal').style.display = "flex";
    }}
    function closeQR() {{ document.getElementById('qrModal').style.display = "none"; }}
    document.addEventListener('keydown', (e) => {{ if (e.key === "Escape") closeQR(); }});
  </script>
</body>
</html>
"""

proc renderDirListing(path, urlPath: string, maxSizeMB: int): string =
  let maxBytes = maxSizeMB * 1024 * 1024
  var items = ""

  # Parent Link
  if urlPath != "/":
    var pPath = urlPath.parentDir
    if pPath == "": pPath = "/"
    items.add(fmt"""<div class='card parent'><div class='card-left'><a href='{pPath}'><span class='icon'>⬆️</span><span>.. (Parent)</span></a></div></div>""")

  # File Walk
  var dirs: seq[tuple[name: string, time: Time]] = @[]
  var files: seq[tuple[name: string, size: int64, time: Time]] = @[]

  for kind, p in walkDir(path):
    try:
      let n = extractFilename(p); let i = getFileInfo(p)
      if kind == pcDir: dirs.add((n, i.lastWriteTime))
      else: files.add((n, i.size, i.lastWriteTime))
    except: discard

  # Render Dirs
  for d in dirs:
    let enc = encodeUrl(d.name, usePlus = false)
    let zipUrl = (if urlPath.endsWith("/"): urlPath else: urlPath & "/") & enc & "?zip=1"
    items.add(fmt"""
      <div class='card dir'>
        <div class='card-left'>
          <a href='{enc}/'>
            <span class='icon'>📁</span>
            <div class='file-info'>
              <span class='file-name'>{d.name}/</span>
              <span class='file-meta'>{formatTimeAgo(d.time)}</span>
            </div>
          </a>
        </div>
        <div style="display:flex; align-items:center;">
          <a href='{zipUrl}' download='{d.name}.zip'><button class='btn'>📦 ZIP</button></a>
          <button class='btn' onclick="showQR('{zipUrl}')">📱 QR</button>
        </div>
      </div>""")

  # Render Files
  for f in files:
    let enc = encodeUrl(f.name, usePlus = false)
    let url = (if urlPath.endsWith("/"): urlPath else: urlPath & "/") & enc
    items.add(fmt"""
      <div class='card file'>
        <div class='card-left'>
          <a href='{enc}'>
            <span class='icon'>📄</span>
            <div class='file-info'>
              <span class='file-name'>{f.name}</span>
              <span class='file-meta'>{formatFileSize(f.size)} • {formatTimeAgo(f.time)}</span>
            </div>
          </a>
        </div>
        <button class='btn' onclick="showQR('{url}')">📱 QR</button>
      </div>""")

  let uploadForm = fmt"""
    <h1>Index of {urlPath}</h1>
    <form method="POST" enctype="multipart/form-data" id="uForm" style="margin-bottom:20px; padding-bottom:10px; border-bottom:1px solid #ddd;">
      <input type="file" name="file" id="fIn">
      <button type="submit" id="uBtn">Upload</button>
      <span style="font-size:0.8em; color:#666;">Max: {maxSizeMB}MB</span>
      <div id="fWarn" style="display:none; font-weight:bold; margin-top:5px;"></div>
    </form>
    <script>
      const max = {maxBytes};
      document.getElementById('fIn').addEventListener('change', function() {{
        if (this.files.length > 0) {{
          const sz = this.files[0].size;
          const mb = (sz/1048576).toFixed(2);
          const warn = document.getElementById('fWarn');
          const btn = document.getElementById('uBtn');
          warn.style.display = 'block';
          if (sz > max) {{ btn.disabled = true; warn.style.color='red'; warn.textContent='⚠ Too large: '+mb+'MB'; }} 
          else {{ btn.disabled = false; warn.style.color='green'; warn.textContent='✓ '+mb+'MB'; }}
        }}
      }});
    </script>
  """
  return renderPage("Index of " & urlPath, uploadForm & items)

# ---------------------------------------------------------------------------
# SERVER LOGIC
# ---------------------------------------------------------------------------

proc getMime(ext: string): string =
  case ext.toLowerAscii()
  of ".html": "text/html"
  of ".css": "text/css"
  of ".js": "application/javascript"
  of ".json": "application/json"
  of ".png": "image/png"
  of ".jpg", ".jpeg": "image/jpeg"
  of ".txt": "text/plain"
  of ".pdf": "application/pdf"
  of ".zip": "application/zip"
  of ".mp4": "video/mp4"
  of ".mp3": "audio/mpeg"
  else: "application/octet-stream"

proc logRequest(req: Request, code: HttpCode) =
  # Define colors as normal strings where \e IS interpreted
  const Reset = "\e[0m"
  let color = if code.int < 300: "\e[32m" elif code.int <
      400: "\e[36m" else: "\e[31m"

  let timestamp = now().format("HH:mm:ss")

  # Use {Reset} to inject the code
  echo fmt"[{timestamp}] {req.hostname.alignLeft(15)} {($req.reqMethod).alignLeft(6)} {color}{code.int}{Reset} {req.url.path}"

# --- Request Handlers ---

proc handleZip(req: Request, fsPath: string) {.async.} =
  try:
    let zipData = zipDirectory(fsPath)
    let zipName = (if fsPath.extractFilename ==
        "": "root" else: fsPath.extractFilename) & ".zip"
    logRequest(req, Http200)
    await req.respond(Http200, zipData, newHttpHeaders([("Content-Type",
        "application/zip"), ("Content-Disposition",
        fmt"attachment; filename=""{zipName}""")]))
  except Exception as e:
    echo "ZIP Error: ", e.msg
    await req.respond(Http500, "Error creating ZIP")

proc handleUpload(req: Request, fsPath: string, maxBytes: int) {.async.} =
  if req.body.len > maxBytes:
    await req.respond(Http413, renderPage("Error", "<h1>File too large</h1>"))
    return

  # Simplistic multipart parser (Robust enough for basic tools)
  if "filename=\"" in req.body:
    let s = req.body.find("filename=\"") + 10
    let e = req.body.find("\"", s)
    let fname = req.body[s ..< e]
    if fname.len > 0:
      let boundaryStart = req.body.find("\r\n\r\n")
      if boundaryStart != -1:
        let contentEnd = req.body.rfind("------WebKitFormBoundary")
        if contentEnd > 0:
          writeFile(fsPath / fname, req.body[boundaryStart+4 ..< contentEnd-2])
          logRequest(req, Http200)
          await req.respond(Http200, renderPage("Success",
              fmt"<h1>Uploaded {fname}</h1><a href='{req.url.path}'>Back</a>"))
          return
  await req.respond(Http400, renderPage("Error", "<h1>Bad Upload Request</h1>"))

proc handleServe(req: Request, fsPath, relPath: string,
    maxSizeMB: int) {.async.} =
  if dirExists(fsPath):
    # Check for index.html
    if fileExists(fsPath / "index.html") and not req.url.path.endsWith("/"):
      logRequest(req, Http200)
      await req.respond(Http200, readFile(fsPath / "index.html"),
          newHttpHeaders([("Content-Type", "text/html")]))
    else:
      logRequest(req, Http200)
      await req.respond(Http200, renderDirListing(fsPath, relPath, maxSizeMB))
  elif fileExists(fsPath):
    logRequest(req, Http200)
    await req.respond(Http200, readFile(fsPath), newHttpHeaders([(
        "Content-Type", getMime(fsPath.splitFile.ext))]))
  else:
    logRequest(req, Http404)
    await req.respond(Http404, renderPage("404", "<h1>Not Found</h1>"))

# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------

proc main() =
  var port = 8000; var host = "0.0.0.0"; var serveDir = "."; var maxSizeMB = 100

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
      of "v", "version": (echo VERSION; quit(0))
      of "h", "help": (echo "Usage: nserve -p 8000 -d ./files"; quit(0))
    of cmdArgument: serveDir = p.key

  if serveDir.len > 1 and serveDir.endsWith(DirSep): serveDir = serveDir[0 ..< ^1]
  if not dirExists(serveDir): quit("Error: Directory not found")

  let server = newAsyncHttpServer()
  let maxBytes = maxSizeMB * 1024 * 1024

  echo fmt"""
  nserve v{VERSION}
  -----------------------------------------
  Path: {serveDir.absolutePath}
  Addr: http://{host}:{port}
  Max : {maxSizeMB} MB
  -----------------------------------------
  """

  proc cb(req: Request) {.async, gcsafe.} =
    let urlPath = req.url.path.decodeUrl()
    let relPath = if urlPath.startsWith("/"): urlPath else: "/" & urlPath
    let fsPath = serveDir / (if relPath.startsWith("/"): relPath[
        1..^1] else: relPath)

    if req.url.query.contains("zip=1") and dirExists(fsPath):
      await handleZip(req, fsPath)
    elif req.reqMethod == HttpPost and dirExists(fsPath):
      await handleUpload(req, fsPath, maxBytes)
    else:
      await handleServe(req, fsPath, req.url.path, maxSizeMB)

  waitFor server.serve(Port(port), cb, host)

main()
