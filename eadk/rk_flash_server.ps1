# EADK RK Flash HTTP. Bind 127.0.0.1, routes under base_path.
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Version = "1.0.0"
$ToolId = "rk-flash"

$HttpPort = 0
$ConfigPath = ""
for ($i = 0; $i -lt $args.Count; $i++) {
    $a = [string]$args[$i]
    if ($a -eq "--http-port" -and ($i + 1) -lt $args.Count) { $HttpPort = [int]$args[++$i]; continue }
    if ($a -eq "-c" -and ($i + 1) -lt $args.Count) { $ConfigPath = [string]$args[++$i]; continue }
}

$Bind = "127.0.0.1"
$Base = "/rk-flash"
$Port = 18086
$Gateway = "http://127.0.0.1:18081"
if ($ConfigPath) {
    if (-not [IO.Path]::IsPathRooted($ConfigPath)) { $ConfigPath = Join-Path (Get-Location) $ConfigPath }
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "config not found: $ConfigPath" }
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($cfg.eadk -and $cfg.eadk.tool -and [string]$cfg.eadk.tool -ne $ToolId) {
        throw "eadk.tool mismatch: $($cfg.eadk.tool)"
    }
    if ($cfg.server) {
        if ($cfg.server.port) { $Port = [int]$cfg.server.port }
        if ($cfg.server.http_bind) { $Bind = [string]$cfg.server.http_bind }
        if ($cfg.server.base_path) { $Base = [string]$cfg.server.base_path.TrimEnd("/") }
        if ($cfg.server.gateway) { $Gateway = [string]$cfg.server.gateway.TrimEnd("/") }
    }
}
if ($HttpPort -gt 0) { $Port = $HttpPort }
if (-not $Base.StartsWith("/")) { $Base = "/" + $Base }
if ($env:EADK_GATEWAY) { $Gateway = [string]$env:EADK_GATEWAY.TrimEnd("/") }

function Test-EadkGateway([string]$gw) {
    if (-not $gw) { return $false }
    try {
        $r = Invoke-WebRequest -Uri "$gw/relay/health" -UseBasicParsing -TimeoutSec 2
        return ($r.StatusCode -eq 200 -and $r.Content -match '"tool"\s*:\s*"relay"')
    } catch { return $false }
}

function Resolve-EadkGateway([string]$preferred) {
    $cands = New-Object System.Collections.Generic.List[string]
    if ($preferred) { [void]$cands.Add($preferred.TrimEnd("/")) }
    [void]$cands.Add("http://127.0.0.1:18081")
    $extras = @()
    try {
        $extras = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } |
            Select-Object -ExpandProperty IPAddress)
    } catch { $extras = @() }
    # 优先普通网卡，ICS/热点 192.168.137.* 放后
    foreach ($ip in ($extras | Where-Object { $_ -notlike "192.168.137.*" })) {
        [void]$cands.Add("http://${ip}:18081")
    }
    foreach ($ip in ($extras | Where-Object { $_ -like "192.168.137.*" })) {
        [void]$cands.Add("http://${ip}:18081")
    }
    $seen = @{}
    foreach ($c in $cands) {
        if ($seen.ContainsKey($c)) { continue }
        $seen[$c] = $true
        if (Test-EadkGateway $c) { return $c }
    }
    if ($preferred) { return $preferred.TrimEnd("/") }
    return "http://127.0.0.1:18081"
}

$Gateway = Resolve-EadkGateway $Gateway
Write-Host "EADK RK Flash gateway=$Gateway"

$ToolDir = Join-Path $Root "tools\upgrade_tool"
$ToolExe = Join-Path $ToolDir "upgrade_tool.exe"
$FlashPs1 = Join-Path $Root "scripts\flash.ps1"
$EnterMaskromBat = Join-Path $Root "scripts\enter-maskrom.bat"
if (-not (Test-Path -LiteralPath $EnterMaskromBat)) {
    $EnterMaskromBat = Join-Path $Root "enter-maskrom.bat"
}
$Cache = Join-Path $Root "cache"
$Firmware = Join-Path $Root "firmware"
if (-not (Test-Path -LiteralPath $Cache)) { New-Item -ItemType Directory -Path $Cache | Out-Null }
if (-not (Test-Path -LiteralPath $ToolExe)) { throw "missing $ToolExe" }
if (-not (Test-Path -LiteralPath $FlashPs1)) { throw "missing $FlashPs1" }

$script:Pending = $null

function ConvertTo-ApiJson($obj) {
    $j = $obj | ConvertTo-Json -Compress -Depth 8
    if (-not $j) { $j = "{}" }
    return ($j -replace '"\s*:\s*', '":')
}

function Send-Bytes($ctx, $code, $type, [byte[]]$bytes) {
    $ctx.Response.StatusCode = $code
    $ctx.Response.ContentType = $type
    $ctx.Response.ContentLength64 = $bytes.Length
    if ($bytes.Length -gt 0) { $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length) }
    $ctx.Response.Close()
}

function Send-Text($ctx, $code, $type, [string]$text) {
    Send-Bytes $ctx $code $type ([Text.Encoding]::UTF8.GetBytes($text))
}

function Send-Json($ctx, $code, $obj) {
    Send-Text $ctx $code "application/json; charset=utf-8" (ConvertTo-ApiJson $obj)
}

function Send-Err($ctx, $http, $code, $msg) {
    Send-Json $ctx $http @{ ok = $false; error = @{ code = $code; message = $msg } }
}

function Invoke-UpgradeLd {
    Push-Location $ToolDir
    try {
        $out = & $ToolExe LD 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally { Pop-Location }
    $devices = @()
    foreach ($line in ($out -split "`r?`n")) {
        $t = $line.Trim()
        if ($t -notmatch "DevNo=") { continue }
        $d = @{ line = $t }
        if ($t -match "DevNo=(\S+)") { $d.dev_no = $Matches[1].Trim("`t ,") }
        if ($t -match "Vid=([^\s,]+)") { $d.vid = $Matches[1] }
        if ($t -match "Pid=([^\s,]+)") { $d.pid = $Matches[1] }
        if ($t -match "LocationID=([^\s,]+)") { $d.location_id = $Matches[1] }
        if ($t -match "Mode=(\S+)") { $d.mode = $Matches[1] }
        if ($t -match "SerialNo=(\S*)") { $d.serial = $Matches[1] }
        $devices += $d
    }
    return @{ ok = ($code -eq 0 -or $devices.Count -gt 0); exit_code = $code; devices = @($devices); count = @($devices).Count }
}

function Resolve-ImageUrl([string]$url) {
    $url = $url.Trim()
    if ($url -notmatch '(?i)\.(img|bin)(\?.*)?$') {
        throw "url 必须是具体镜像，例如 http://host/.../boot.img 或 update.img"
    }
    $leaf = [Uri]::UnescapeDataString((([Uri]$url).AbsolutePath -split "/")[-1])
    return @{ url = $url; name = $leaf }
}

function Save-RemoteFile([string]$url, [string]$name) {
    $dest = Join-Path $Cache $name
    $part = "$dest.part"
    if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force }
    & curl.exe -fL --retry 2 --retry-delay 2 -o $part $url
    if ($LASTEXITCODE -ne 0) { throw "下载失败 $url" }
    Move-Item -LiteralPath $part -Destination $dest -Force
    $sumUrl = "$url.sha256sum"
    $sumText = & curl.exe -fsSL --max-time 20 $sumUrl 2>$null
    if ($LASTEXITCODE -eq 0 -and $sumText) {
        $expect = ([string]$sumText -split '\s+')[0].Trim().ToLower()
        if ($expect -match '^[0-9a-f]{64}$') {
            $sha = [Security.Cryptography.SHA256]::Create()
            $hfs = [IO.File]::OpenRead($dest)
            try { $hash = ([BitConverter]::ToString($sha.ComputeHash($hfs))).Replace("-", "").ToLower() }
            finally { $hfs.Close(); $sha.Dispose() }
            if ($hash -ne $expect) { throw "SHA256 不匹配: $name" }
        }
    }
    return (Resolve-Path -LiteralPath $dest).Path
}

function Assert-LocationSelect([string]$select) {
    $st = Invoke-UpgradeLd
    if ($st.count -gt 1 -and [string]::IsNullOrWhiteSpace($select)) {
        throw "多台设备，请指定 select（LocationID）。先 GET /api/devices"
    }
    return $st
}

function Start-ScriptJob([string[]]$toolArgs, [string]$label) {
    if ($script:Pending) { throw "已有任务在进行" }
    $log = Join-Path $Cache "flash-last.log"
    $argList = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $FlashPs1,
        "-SkipConfirm"
    ) + $toolArgs
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $psi.WorkingDirectory = $Root
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.Arguments = ""
    # ArgumentList via ProcessStartInfo.Arguments needs quoting
    $quoted = foreach ($p in $argList) {
        if ($p -match '[\s"]') { '"' + ($p -replace '"', '\"') + '"' } else { $p }
    }
    $psi.Arguments = ($quoted -join " ")
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    $script:Pending = @{
        proc    = $p
        outTask = $p.StandardOutput.ReadToEndAsync()
        errTask = $p.StandardError.ReadToEndAsync()
        ctx     = $null
        image   = $label
        log     = $log
    }
}

function Start-FlashProcess([string]$image, [string]$select, [bool]$noReset, [bool]$eraseFirst) {
    $toolArgs = @("-Image", $image)
    if ($select) { $toolArgs += @("-Select", $select) }
    if ($noReset) { $toolArgs += "-NoReset" }
    if ($eraseFirst) { $toolArgs += "-EraseFirst" }
    Start-ScriptJob $toolArgs $image
}

function Get-RelayBoards {
    $url = "$Gateway/relay/api/boards"
    try {
        $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 8
        $j = $resp.Content | ConvertFrom-Json
    } catch {
        throw "无法访问 $url ：$($_.Exception.Message)"
    }
    $names = @()
    if ($null -ne $j.boards) {
        foreach ($p in @($j.boards.PSObject.Properties)) {
            if ($p -and $p.Name) { $names += [string]$p.Name }
        }
    }
    return @{
        ok      = $true
        gateway = $Gateway
        count   = $names.Count
        boards  = $names
        raw     = $j
    }
}

function Start-EnterMaskrom([string]$board) {
    if ($script:Pending) { throw "已有任务在进行" }
    if ($board -notmatch '^[A-Za-z0-9_-]+$') { throw "非法 board 名" }
    if (-not (Test-Path -LiteralPath $EnterMaskromBat)) {
        throw "缺少 enter-maskrom.bat（应在 scripts\ 下）"
    }
    $log = Join-Path $Cache "enter-maskrom-last.log"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot "System32\cmd.exe"
    $psi.Arguments = "/c `"$EnterMaskromBat`" $board"
    $psi.WorkingDirectory = $Root
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $utf8 = New-Object System.Text.UTF8Encoding $false
    $psi.StandardOutputEncoding = $utf8
    $psi.StandardErrorEncoding = $utf8
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $env:EADK_GATEWAY = $Gateway
    [void]$p.Start()
    $script:Pending = @{
        proc    = $p
        outTask = $p.StandardOutput.ReadToEndAsync()
        errTask = $p.StandardError.ReadToEndAsync()
        ctx     = $null
        image   = "enter-maskrom:$board"
        log     = $log
    }
}

function Complete-Pending {
    $job = $script:Pending
    if (-not $job) { return }
    if (-not $job.proc.HasExited) { return }
    $out = ""
    $err = ""
    try { $out = [string]$job.outTask.Result } catch { $out = "" }
    try { $err = [string]$job.errTask.Result } catch { $err = "" }
    $text = ($out + "`n" + $err).Trim()
    Set-Content -LiteralPath $job.log -Value $text -Encoding UTF8
    $code = $job.proc.ExitCode
    $tail = $text
    if ($tail.Length -gt 8000) { $tail = $tail.Substring($tail.Length - 8000) }
    $ok = ($code -eq 0)
    $body = @{
        ok        = $ok
        exit_code = $code
        image     = $job.image
        log       = $tail
        log_file  = $job.log
    }
    if (-not $ok) { $body.error = @{ code = "command_failed"; message = "命令失败，退出码 $code" } }
    try { Send-Json $job.ctx 200 $body } catch {}
    try { $job.proc.Dispose() } catch {}
    $script:Pending = $null
}

function Read-JsonBody($req) {
    $sr = New-Object IO.StreamReader($req.InputStream, [Text.Encoding]::UTF8)
    $txt = $sr.ReadToEnd()
    if (-not $txt) { return $null }
    return ($txt | ConvertFrom-Json)
}

function Get-RelPath([string]$abs) {
    $p = $abs
    if ($p.Length -gt 1 -and $p.EndsWith("/")) { $p = $p.TrimEnd("/") }
    return $p
}

$html = @'
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>EADK RK Flash</title>
<style>
:root{
  --bg0:#07111f; --bg1:#0a1628; --card:#132033;
  --line:rgba(148,163,184,.18); --text:#e8eef8; --muted:#8b9bb4;
  --accent:#38bdf8; --accent2:#0ea5e9; --ok:#4ade80; --bad:#fb7185;
  --soft:rgba(56,189,248,.12);
}
*{box-sizing:border-box}
html,body{margin:0;min-height:100%;font-family:"Segoe UI","Microsoft YaHei",sans-serif;color:var(--text);
  background:radial-gradient(780px 360px at 0% -8%,rgba(8,145,178,.22),transparent 58%),
    radial-gradient(640px 320px at 100% 0%,rgba(56,189,248,.1),transparent 52%),
    linear-gradient(168deg,var(--bg0),var(--bg1) 48%,#08111d)}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
.wrap{max-width:980px;margin:0 auto;padding:18px 16px 28px}
.top{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-bottom:14px}
h1{margin:0;font-size:20px;font-weight:700}
html.kit h1{font-size:16px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 16px;margin:0 0 12px;
  box-shadow:0 14px 32px rgba(0,0,0,.22)}
.card h2{margin:0 0 10px;font-size:13px;font-weight:700;color:var(--muted);letter-spacing:.04em;text-transform:uppercase}
.row{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin:8px 0}
label.field{display:block;width:100%;font-size:12px;color:var(--muted);margin:6px 0 4px}
input[type=text],input[type=file],select{width:100%;padding:9px 11px;border-radius:10px;border:1px solid var(--line);
  background:rgba(255,255,255,.04);color:var(--text);font:inherit}
input[type=text]:focus,select:focus{outline:none;border-color:var(--accent);box-shadow:0 0 0 3px var(--soft)}
select option{background:#132033;color:var(--text)}
.btn{border:1px solid var(--line);border-radius:999px;background:rgba(255,255,255,.05);
  color:var(--text);padding:7px 14px;font-size:12px;font-weight:650;cursor:pointer}
.btn:hover{border-color:var(--accent);color:var(--accent)}
.btn.primary{background:linear-gradient(135deg,var(--accent),var(--accent2));border-color:transparent;color:#041018}
.btn.primary:hover{filter:brightness(1.06);color:#041018}
.btn.danger{border-color:rgba(251,113,133,.45);color:var(--bad)}
pre{margin:0;padding:12px;border-radius:10px;background:rgba(0,0,0,.28);border:1px solid var(--line);
  white-space:pre-wrap;word-break:break-all;font-size:12px;line-height:1.45;color:#dbe7f5;max-height:360px;overflow:auto}
</style>
</head>
<body>
<div class="wrap">
  <div class="top">
    <h1>EADK RK Flash</h1>
    <a href="help">Agent 接口</a>
  </div>
  <div class="card">
    <h2>Rockusb 设备 <span id="dev-status" style="font-weight:500;text-transform:none;letter-spacing:0;margin-left:8px">检测中…</span></h2>
    <div class="row">
      <button class="btn" id="act-maskrom">是否 Maskrom</button>
      <button class="btn" id="act-info">设备信息</button>
      <button class="btn" id="act-reset">复位</button>
      <button class="btn" id="act-mask">Loader→Maskrom</button>
      <button class="btn danger" id="act-erase">整片擦除</button>
    </div>
    <label class="field">LocationID（多台必选；自动检测后填入）</label>
    <select id="select"><option value="">（自动 / 单台可空）</option></select>
  </div>
  <div class="card">
    <h2>进 Maskrom（Relay 复位 + SSH Bridge）</h2>
    <p style="margin:0 0 8px;font-size:12px;color:var(--muted)">板名须同时存在于 Relay 与 SSH Bridge。流程：reset → Ctrl+C → 擦 eMMC boot → reset。</p>
    <label class="field">板子</label>
    <div class="row">
      <select id="board" style="flex:1;min-width:160px;padding:9px 11px;border-radius:10px;border:1px solid var(--line);background:rgba(255,255,255,.04);color:var(--text);font:inherit">
        <option value="">（选择板子）</option>
      </select>
      <button class="btn primary" id="enter-maskrom">进 Maskrom</button>
    </div>
  </div>
  <div class="card">
    <h2>本地镜像</h2>
    <label class="field">本机路径</label>
    <input id="path" type="text" placeholder="C:\code\rk-tool\update.img" value="C:\code\rk-tool\update.img"/>
    <div class="row"><button class="btn primary" id="go-path">烧写本地文件</button></div>
  </div>
  <div class="card">
    <h2>网络镜像</h2>
    <label class="field">具体文件 URL</label>
    <input id="url" type="text" placeholder="http://host/.../boot.img"/>
    <div class="row"><button class="btn primary" id="go-url">下载并烧写</button></div>
  </div>
  <div class="card">
    <h2>上传镜像</h2>
    <input id="up" type="file"/>
    <div class="row"><button class="btn primary" id="go-up">上传并烧写</button></div>
  </div>
  <div class="card">
    <h2>日志</h2>
    <pre id="log"></pre>
  </div>
</div>
<script>
if (location.search.indexOf("eadk_kit=1")>=0) document.documentElement.classList.add("kit");
function base(){var p=location.pathname; if(p.slice(-1)!=="/") p+="/"; return p.replace(/\/$/,"")}
function logText(d){
  if(!d) return "";
  if(typeof d==="string") return d;
  return d.log || "";
}
function show(d){document.getElementById("log").textContent=logText(d)}
async function api(path, opt){
  const r=await fetch(base()+path, opt||{});
  const t=await r.text();
  try{return JSON.parse(t)}catch(e){return {ok:false, raw:t}}
}
function sel(){return document.getElementById("select").value.trim()}
function withSel(body){var s=sel(); if(s) body.select=s; return body}
function fillSelect(el, values, emptyLabel){
  var cur=el.value, html='<option value="">'+emptyLabel+'</option>';
  (values||[]).forEach(function(v){ html+='<option value="'+v+'">'+v+'</option>'; });
  el.innerHTML=html;
  if(cur && values && values.indexOf(cur)>=0) el.value=cur;
  else if(values && values.length===1) el.value=values[0];
}
async function refreshDevices(){
  var d;
  try{ d=await api("/api/devices") }catch(e){ return }
  var ids=(d.devices||[]).map(function(x){return x.location_id}).filter(Boolean);
  fillSelect(document.getElementById("select"), ids, "（自动 / 单台可空）");
  var st=document.getElementById("dev-status");
  if(!d.count) st.textContent="未检测到 Rockusb";
  else st.textContent="已挂载 "+d.count+" 台"+(d.need_select?"（请选择 LocationID）":"");
}
async function act(name){
  show(await api("/api/action",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(withSel({action:name}))}));
}
document.getElementById("act-maskrom").onclick=function(){act("maskrom")};
document.getElementById("act-info").onclick=function(){act("info")};
document.getElementById("act-reset").onclick=function(){act("reset")};
document.getElementById("act-mask").onclick=function(){act("to-maskrom")};
document.getElementById("act-erase").onclick=function(){ if(confirm("整片擦除？")) act("erase") };
async function refreshBoards(){
  var d;
  try{ d=await api("/api/relay-boards") }catch(e){ return }
  fillSelect(document.getElementById("board"), d.boards||[], "（选择板子）");
}
document.getElementById("enter-maskrom").onclick=async function(){
  var b=document.getElementById("board").value.trim();
  if(!b) return;
  if(!confirm("对板子 "+b+" 执行进 Maskrom？（会复位并擦 eMMC boot 区）")) return;
  show(await api("/api/enter-maskrom",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({board:b})}));
};
refreshBoards();
setInterval(refreshBoards, 5000);
refreshDevices();
setInterval(refreshDevices, 5000);
document.getElementById("go-path").onclick=async function(){
  show(await api("/api/flash",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(withSel({path:document.getElementById("path").value}))}));
};
document.getElementById("go-url").onclick=async function(){
  show(await api("/api/flash",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(withSel({url:document.getElementById("url").value}))}));
};
document.getElementById("go-up").onclick=async function(){
  var f=document.getElementById("up").files[0];
  if(!f) return;
  var q="/api/upload?name="+encodeURIComponent(f.name)+"&flash=1";
  var s=sel(); if(s) q+="&select="+encodeURIComponent(s);
  show(await api(q,{method:"POST",headers:{"Content-Type":"application/octet-stream"},body:f}));
};
</script>
</body>
</html>
'@

function Get-HelpMarkdown([string]$pub) {
    $b = "$pub$Base"
    return @"
# EADK RK Flash — Agent 操作手册

先看约定与 devices 字段，再复制下面的 curl（说明紧挨命令，不同命令之间空一行）。
PowerShell / Agent 请用 curl.exe；JSON 用单引号包住（与 sshbridge /help 相同），不要写 -d "{\"a\":1}"。

- 机器清单: $b/api/help
- WebUI: $b/
- Agent 接口: $b/help

---

## 1. 约定

- **Base**: ``$b``（局域网经 Gateway 时用主机 IP:18081，勿写死 127.0.0.1 给远端 Agent）
- 本机直连后端: ``http://127.0.0.1:$Port$Base``（不经 Gateway）
- Rockusb 设备用 LocationID 区分；列表见 ``GET /api/devices`` 的 ``location_id``
- **只有 1 台设备时，写操作可以不带 ``select``**；``count > 1``（``need_select=true``）时必须带 ``"select":"<LocationID>"``
- 网络镜像 ``url`` 必须是具体文件，例如 ``.../boot.img`` 或 ``.../update.img``，不要给目录地址
- 烧写/维护类 HTTP 会阻塞到命令结束，返回 JSON 含 ``ok`` / ``exit_code`` / ``log``

---

## 2. 设备列表返回什么

### 2.1 GET /api/devices

curl.exe -s $b/api/devices

JSON 顶层:

- ``ok`` — 请求是否成功
- ``count`` — Rockusb 数量
- ``need_select`` — 是否必须指定 LocationID（count>1 时为 true）
- ``devices`` — 设备数组

每个 device 常用字段:

- ``location_id`` — 多板选择用（对应 upgrade_tool ``-s``）
- ``dev_no`` / ``mode`` — 序号；Loader 或 Maskrom
- ``vid`` / ``pid`` / ``serial`` — USB 标识

---

## 3. 典型操作示例

把 ``224`` 换成真实 LocationID；单板可去掉 ``,"select":"224"``。

### 3.1 查看是否 Maskrom

**POST /api/action action=maskrom（当前是 Maskrom 则 ok=true / exit_code=0）**
curl.exe -s -X POST -H "Content-Type: application/json" -d '{"action":"maskrom"}' $b/api/action

**多板时带 LocationID**
curl.exe -s -X POST -H "Content-Type: application/json" -d '{"action":"maskrom","select":"224"}' $b/api/action

### 3.2 读设备信息（芯片 / 存储 / 分区）

**POST /api/action action=info**
curl.exe -s -X POST -H "Content-Type: application/json" -d '{"action":"info"}' $b/api/action

**仅芯片 ID / 存储 / 分区表**
curl.exe -s -X POST -H "Content-Type: application/json" -d '{"action":"rci"}' $b/api/action

curl.exe -s -X POST -H "Content-Type: application/json" -d '{"action":"rfi"}' $b/api/action

curl.exe -s -X POST -H "Content-Type: application/json" -d '{"action":"pl"}' $b/api/action

### 3.3 复位 / Loader→Maskrom / Download Boot / 整片擦除

**复位**
curl.exe -s -X POST -H "Content-Type: application/json" -d '{"action":"reset"}' $b/api/action

**Loader→Maskrom（upgrade_tool to-maskrom；设备须已在 Rockusb）**
curl.exe -s -X POST -H "Content-Type: application/json" -d '{"action":"to-maskrom"}' $b/api/action

**Maskrom 下 Download Boot（需 firmware\MiniLoaderAll.bin）**
curl.exe -s -X POST -H "Content-Type: application/json" -d '{"action":"db"}' $b/api/action

**整片擦除（危险）**
curl.exe -s -X POST -H "Content-Type: application/json" -d '{"action":"erase","select":"224"}' $b/api/action

### 3.4 经 Relay+SSH Bridge 进 Maskrom（enter-maskrom.bat）

板名须在 Relay 与 SSH Bridge 中同名配置。

**列出 Relay 板子**
curl.exe -s $b/api/relay-boards

**进 Maskrom（阻塞到脚本结束）**
curl.exe -s -X POST -H "Content-Type: application/json" -d '{"board":"BOARD"}' $b/api/enter-maskrom

### 3.5 烧写网络镜像（具体文件 URL）

**烧 boot.img**
curl.exe -s -X POST -H "Content-Type: application/json" -d '{"url":"http://172.16.45.24/dsp_release/noesis3588/QSemOS-24.03-LTS/boot.img"}' $b/api/flash

**烧 update.img（整包，体积大）**
curl.exe -s -X POST -H "Content-Type: application/json" -d '{"url":"http://172.16.45.24/dsp_release/noesis3588/QSemOS-24.03-LTS/update.img","select":"224"}' $b/api/flash

### 3.6 烧写本机镜像 / 上传后烧写

**本机路径**
curl.exe -s -X POST -H "Content-Type: application/json" -d '{"path":"C:\\code\\rk-tool\\update.img"}' $b/api/flash

**先上传再烧（@ 后为本地文件路径；query flash=1；多板加 &select=）**
curl.exe -s -X POST -H "Content-Type: application/octet-stream" --data-binary "@C:\code\rk-tool\update.img" "$b/api/upload?name=update.img&flash=1"

**只上传，返回 path 后再调 /api/flash**
curl.exe -s -X POST -H "Content-Type: application/octet-stream" --data-binary "@C:\code\rk-tool\update.img" "$b/api/upload?name=update.img"

---

## 4. 接口速查（与 /api/help 一致）

- ``GET /health`` — 存活；``tool=rk-flash``
- ``GET /api/help`` — 机器可读 operations
- ``GET /help`` — Agent 接口（text/plain Markdown）
- ``GET /api/devices`` — 列出 Rockusb；多板看 location_id
- ``GET /api/resolve?url=`` — 校验具体镜像 URL
- ``POST /api/action`` — status|maskrom|info|rci|rfi|pl|reset|to-maskrom|db|erase；可选 select
- ``GET /api/relay-boards`` — 经 Gateway 拉 Relay 板名列表
- ``POST /api/enter-maskrom`` — body ``board``；跑 enter-maskrom.bat
- ``POST /api/flash`` — path 或 url；可选 select / no_reset / erase_first
- ``POST /api/upload?name=&flash=`` — 上传原始字节；flash=1 则接着烧

"@
}

function Handle-Request($ctx) {
    $req = $ctx.Request
    $path = Get-RelPath $req.Url.AbsolutePath
    $method = $req.HttpMethod.ToUpperInvariant()

    if ($path -eq "" -or $path -eq "/") {
        $ctx.Response.Redirect("$Base/")
        $ctx.Response.Close()
        return
    }
    if ($path -ne $Base -and -not $path.StartsWith($Base + "/")) {
        Send-Json $ctx 404 @{ error = "use path prefix $Base/" }
        return
    }
    $rel = $path.Substring($Base.Length)
    if ($rel -eq "") { $rel = "/" }

    if ($method -eq "GET" -and $rel -eq "/health") {
        Send-Json $ctx 200 @{ ok = $true; tool = $ToolId; version = $Version; product = "EADK RK Flash" }
        return
    }
    if ($method -eq "GET" -and ($rel -eq "/" -or $rel -eq "")) {
        Send-Text $ctx 200 "text/html; charset=utf-8" $html
        return
    }
    if ($method -eq "GET" -and ($rel -eq "/help" -or $rel -eq "/docs")) {
        $hostHdr = [string]$req.Headers["Host"]
        $pub = "http://127.0.0.1:18081"
        if ($hostHdr -match "^([^:]+):(\d+)$") {
            $h = $Matches[1]; $hp = [int]$Matches[2]
            # ${h} 必须加大括号，否则 $h:18081 被 PowerShell 当成作用域变量
            if ($hp -eq 18081) { $pub = "http://${h}:18081" }
            elseif ($h -eq "127.0.0.1" -or $h -eq "localhost") { $pub = "http://127.0.0.1:${Port}" }
            else { $pub = "http://${h}:18081" }
        }
        Send-Text $ctx 200 "text/plain; charset=utf-8" (Get-HelpMarkdown $pub)
        return
    }
    if ($method -eq "GET" -and $rel -eq "/api/help") {
        Send-Json $ctx 200 @{
            tool = $ToolId
            product = "EADK RK Flash"
            version = $Version
            http_port = $Port
            advertise_http_port = 18081
            operations = @(
                @{ id = "device.list"; method = "GET"; path = "$Base/api/devices"; side_effect = $false; summary = "List Rockusb devices and LocationID" }
                @{ id = "device.action"; method = "POST"; path = "$Base/api/action"; body = @{ action = "status|maskrom|info|rci|rfi|pl|reset|to-maskrom|db|erase"; select = "LocationID when more than one device" }; side_effect = $true; summary = "Device status and maintenance" }
                @{ id = "relay.boards"; method = "GET"; path = "$Base/api/relay-boards"; side_effect = $false; summary = "List board names from Relay via Gateway" }
                @{ id = "board.enter_maskrom"; method = "POST"; path = "$Base/api/enter-maskrom"; body = @{ board = "relay/sshbridge board name" }; side_effect = $true; summary = "Run enter-maskrom.bat for a board" }
                @{ id = "image.resolve"; method = "GET"; path = "$Base/api/resolve"; query = @{ url = "http://host/.../boot.img" }; side_effect = $false; summary = "Check a concrete image URL" }
                @{ id = "image.flash"; method = "POST"; path = "$Base/api/flash"; body = @{ path = "local file"; url = "http://host/.../update.img"; select = "LocationID"; no_reset = $false; erase_first = $false }; side_effect = $true; summary = "Flash a local path or a concrete image URL" }
                @{ id = "image.upload"; method = "POST"; path = "$Base/api/upload"; query = @{ name = "update.img"; flash = "1 optional" }; side_effect = $true; summary = "Upload raw image bytes" }
            )
        }
        return
    }
    if ($method -eq "GET" -and $rel -eq "/api/devices") {
        $st = Invoke-UpgradeLd
        $st.ok = $true
        $st.need_select = ($st.count -gt 1)
        Send-Json $ctx 200 $st
        return
    }
    if ($method -eq "GET" -and $rel -eq "/api/relay-boards") {
        try {
            Send-Json $ctx 200 (Get-RelayBoards)
        } catch {
            Send-Err $ctx 502 "relay_unreachable" $_.Exception.Message
        }
        return
    }
    if ($method -eq "POST" -and $rel -eq "/api/enter-maskrom") {
        if ($script:Pending) { Send-Err $ctx 409 "busy" "已有任务在进行"; return }
        $j = Read-JsonBody $req
        $board = if ($j -and $j.board) { [string]$j.board.Trim() } else { "" }
        if (-not $board) { Send-Err $ctx 400 "bad_request" "需要 board"; return }
        try {
            Start-EnterMaskrom $board
            $script:Pending.ctx = $ctx
        } catch {
            Send-Err $ctx 400 "bad_request" $_.Exception.Message
        }
        return
    }
    if ($method -eq "GET" -and $rel -eq "/api/resolve") {
        $url = [string]$req.QueryString["url"]
        if (-not $url) { Send-Err $ctx 400 "bad_request" "缺少 url"; return }
        $r = Resolve-ImageUrl $url
        Send-Json $ctx 200 @{ ok = $true; url = $r.url; name = $r.name }
        return
    }
    if ($method -eq "POST" -and $rel -eq "/api/upload") {
        $name = [IO.Path]::GetFileName([string]$req.QueryString["name"])
        if (-not $name) { Send-Err $ctx 400 "bad_request" "缺少 name"; return }
        if ($name -notmatch '(?i)\.(img|bin)$') { Send-Err $ctx 400 "bad_request" "只接受 .img / .bin"; return }
        $dest = Join-Path $Cache $name
        $fs = [IO.File]::Create($dest)
        try {
            $buf = New-Object byte[] 1048576
            while (($n = $req.InputStream.Read($buf, 0, $buf.Length)) -gt 0) { $fs.Write($buf, 0, $n) }
        } finally { $fs.Close() }
        $full = (Resolve-Path -LiteralPath $dest).Path
        if ([string]$req.QueryString["flash"] -eq "1") {
            if ($script:Pending) { Send-Err $ctx 409 "busy" "已有烧写在进行"; return }
            $sel = [string]$req.QueryString["select"]
            Assert-LocationSelect $sel | Out-Null
            Start-FlashProcess $full $sel $false $false
            $script:Pending.ctx = $ctx
            return
        }
        Send-Json $ctx 200 @{ ok = $true; path = $full; name = $name }
        return
    }
    if ($method -eq "POST" -and $rel -eq "/api/flash") {
        if ($script:Pending) { Send-Err $ctx 409 "busy" "已有烧写在进行"; return }
        $j = Read-JsonBody $req
        if (-not $j) { Send-Err $ctx 400 "bad_request" "需要 JSON"; return }
        $image = $null
        if ($j.path) {
            $image = [string]$j.path
            if (-not (Test-Path -LiteralPath $image)) { Send-Err $ctx 400 "not_found" "找不到 $image"; return }
            $image = (Resolve-Path -LiteralPath $image).Path
        } elseif ($j.url) {
            $r = Resolve-ImageUrl ([string]$j.url)
            $image = Save-RemoteFile $r.url $r.name
        } else {
            Send-Err $ctx 400 "bad_request" "需要 path 或 url"
            return
        }
        $sel = if ($j.select) { [string]$j.select } else { "" }
        Assert-LocationSelect $sel | Out-Null
        $noReset = [bool]$j.no_reset
        $erase = [bool]$j.erase_first
        Start-FlashProcess $image $sel $noReset $erase
        $script:Pending.ctx = $ctx
        return
    }
    if ($method -eq "POST" -and $rel -eq "/api/action") {
        if ($script:Pending) { Send-Err $ctx 409 "busy" "已有任务在进行"; return }
        $j = Read-JsonBody $req
        if (-not $j -or -not $j.action) { Send-Err $ctx 400 "bad_request" "需要 action"; return }
        $action = [string]$j.action
        $cmd = @{
            status = "status"; ld = "ld"; maskrom = "maskrom"; info = "info"
            rci = "rci"; rfi = "rfi"; pl = "pl"; reset = "rd"
            "to-maskrom" = "to-maskrom"; db = "db"; erase = "erase"
        }
        if (-not $cmd.ContainsKey($action)) { Send-Err $ctx 400 "bad_request" "未知 action"; return }
        $sel = if ($j.select) { [string]$j.select } else { "" }
        if ($action -ne "status" -and $action -ne "ld") { Assert-LocationSelect $sel | Out-Null }
        $toolArgs = @()
        if ($sel) { $toolArgs += @("-Select", $sel) }
        $toolArgs += $cmd[$action]
        Start-ScriptJob $toolArgs $action
        $script:Pending.ctx = $ctx
        return
    }
    Send-Err $ctx 404 "not_found" "未知路径 $rel"
}

$prefix = "http://${Bind}:${Port}/"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)
$listener.Start()
Write-Host "EADK RK Flash listen $prefix base=$Base"

$iar = $listener.BeginGetContext($null, $null)
while ($listener.IsListening) {
    $got = $iar.AsyncWaitHandle.WaitOne(400)
    if ($script:Pending -and $script:Pending.proc.HasExited) { Complete-Pending }
    if (-not $got) { continue }
    try { $ctx = $listener.EndGetContext($iar) } catch { break }
    $iar = $listener.BeginGetContext($null, $null)
    try {
        Handle-Request $ctx
    } catch {
        try { Send-Err $ctx 500 "internal" $_.Exception.Message } catch {}
    }
}
