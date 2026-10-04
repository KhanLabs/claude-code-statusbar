# Claude Code status line: model, context %, project/branch, thinking, context + cache advice,
# 5-hour + weekly limit bars, all-time tokens + API-equivalent cost, auto-continue.
# Source is ASCII-only on purpose (Windows PowerShell 5.1 reads BOM-less files as ANSI).

$ErrorActionPreference = 'SilentlyContinue'
$utf8 = New-Object System.Text.UTF8Encoding $false
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8

$raw = [Console]::In.ReadToEnd().TrimStart([char]0xFEFF)
$in = $null
try { $in = $raw | ConvertFrom-Json } catch {}

$configDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$stateDir = Join-Path $configDir 'statusline'

# ---------- glyphs & colors ----------
$E = [char]27
$DOT = [string][char]0x25CF; $RING = [string][char]0x25CB
$BAR = [string][char]0x2502; $RESET_ICON = [string][char]0x27F3
$MID = [string][char]0x00B7
$WRITE = [char]::ConvertFromUtf32(0x270D) + [char]0xFE0F

function C([int]$r, [int]$g, [int]$b, [string]$t) { "$E[38;2;${r};${g};${b}m$t$E[0m" }
function B([int]$r, [int]$g, [int]$b, [string]$t) { "$E[1;38;2;${r};${g};${b}m$t$E[0m" }   # bold

# Status: lavender = good, light pink = watch it, magenta = act soon, red = act now.
function Good($t)   { C 196 181 253 $t }   # lavender
function Caution($t){ C 249 168 212 $t }   # light pink
function Warn($t)   { C 232 121 249 $t }   # magenta
function Red($t)    { C 239 68 68 $t }
function Level([double]$p, $t) { if ($p -ge 80) { Red $t } elseif ($p -ge 50) { Caution $t } else { Good $t } }

# Accents: identity and values.
function Blue($t)   { C 30 144 255 $t }
function Cyan($t)   { C 0 184 196 $t }
function Sky($t)    { C 56 189 248 $t }
function Violet($t) { C 167 139 250 $t }
function Pink($t)   { C 236 72 153 $t }
function Gold($t)   { B 251 191 36 $t }

# Text: prose, values, and the quiet bits.
function Text($t)   { C 150 150 160 $t }
function Value($t)  { C 225 225 230 $t }
function Dim($t)    { C 105 105 105 $t }
function Faint($t)  { C 70 70 70 $t }

# Row labels: one color per row so rows are easy to tell apart.
function RowLabel([string]$name) {
  $t = $name.PadRight(9)
  switch ($name) {
    'context'  { B 167 139 250 $t }
    'cache'    { B 45 212 191 $t }
    'current'  { B 56 189 248 $t }
    'weekly'   { B 129 140 248 $t }
    'all-time' { B 251 191 36 $t }
    'auto'     { B 34 211 238 $t }
    default    { B 205 205 205 $t }
  }
}
$SEP = ' ' + (Faint $BAR) + ' '
$DOT_SEP = Faint " $MID "

function Fmt-Tokens([double]$n) {
  if ($n -ge 1e9) { '{0:0.00}B' -f ($n / 1e9) }
  elseif ($n -ge 1e6) { '{0:0.0}M' -f ($n / 1e6) }
  elseif ($n -ge 1e3) { '{0:0.0}K' -f ($n / 1e3) }
  else { '{0:0}' -f $n }
}
function Fmt-Clock([datetime]$d) { ($d.ToString('h:mmtt', [Globalization.CultureInfo]::InvariantCulture)).ToLower() }
function Fmt-Reset($epoch) {
  if (-not $epoch) { return '' }
  $d = [DateTimeOffset]::FromUnixTimeSeconds([long]$epoch).LocalDateTime
  if ($d.Date -eq (Get-Date).Date) { Fmt-Clock $d }
  else { ($d.ToString('MMM d', [Globalization.CultureInfo]::InvariantCulture)).ToLower() + ', ' + (Fmt-Clock $d) }
}
function Dots([double]$p, [int]$n = 10) {
  $filled = [Math]::Min($n, [Math]::Max(0, [int][Math]::Round($p / 100 * $n)))
  Level $p (($DOT * $filled) + ($RING * ($n - $filled)))
}

# ---------- pricing (USD per 1M tokens: input, output, cache read) ----------
# Cache writes: 1.25x input (5m TTL), 2x input (1h TTL). Fast mode: 2x.
$PRICES = @(
  @('fable-5-1', 10, 50, 0.25), @('mythos-5-1', 10, 50, 0.25),
  @('fable-5', 10, 50, 1.0),    @('mythos-5', 10, 50, 1.0),
  @('opus-5-5', 4, 20, 0.20),   @('opus-5', 5, 25, 0.50),
  @('opus-4-8', 5, 25, 0.50),   @('opus-4-7', 5, 25, 0.50), @('opus-4-6', 5, 25, 0.50), @('opus-4-5', 5, 25, 0.50),
  @('opus-4', 15, 75, 1.50),
  @('sonnet-5-5', 2, 10, 0.20), @('sonnet-5', 2, 10, 0.20),
  @('sonnet-4', 3, 15, 0.30),   @('sonnet-3-7', 3, 15, 0.30),
  @('haiku-4-5', 1, 5, 0.10),   @('haiku-3-5', 0.8, 4, 0.08)
)
function Get-Price([string]$model) {
  foreach ($p in $PRICES) { if ($model -like "*$($p[0])*") { return $p } }
  return $null
}

# ---------- all-time usage (incremental scan of transcripts, cached) ----------
function Load-Totals {
  $f = Join-Path $stateDir 'usage-cache.json'
  $t = @{ input = 0.0; output = 0.0; cacheWrite = 0.0; cacheRead = 0.0; cost = 0.0; lastScan = 0; files = @{} }
  if (Test-Path $f) {
    try {
      $j = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($k in 'input', 'output', 'cacheWrite', 'cacheRead', 'cost', 'lastScan') { if ($null -ne $j.$k) { $t[$k] = $j.$k } }
      if ($j.files) { foreach ($p in $j.files.PSObject.Properties) { $t.files[$p.Name] = [long]$p.Value } }
    } catch {}
  }
  $t
}

function Update-Totals($t) {
  $seenFile = Join-Path $stateDir 'seen-ids.txt'
  $seen = New-Object 'System.Collections.Generic.HashSet[string]'
  if (Test-Path $seenFile) { foreach ($l in [IO.File]::ReadAllLines($seenFile)) { [void]$seen.Add($l) } }
  $newIds = New-Object System.Collections.Generic.List[string]

  $files = Get-ChildItem (Join-Path $configDir 'projects') -Recurse -Filter *.jsonl -File
  foreach ($file in $files) {
    $path = $file.FullName
    $off = if ($t.files.ContainsKey($path)) { $t.files[$path] } else { 0L }
    if ($file.Length -lt $off) { $off = 0L }
    if ($file.Length -eq $off) { continue }

    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try {
      [void]$fs.Seek($off, 'Begin')
      $buf = New-Object byte[] ($file.Length - $off)
      $read = 0
      while ($read -lt $buf.Length) { $n = $fs.Read($buf, $read, $buf.Length - $read); if ($n -le 0) { break }; $read += $n }
    } finally { $fs.Dispose() }

    $last = [Array]::LastIndexOf($buf, [byte]10, $read - 1)
    if ($last -lt 0) { continue }   # no complete line yet
    $text = $utf8.GetString($buf, 0, $last + 1)
    $t.files[$path] = $off + $last + 1

    foreach ($line in $text.Split("`n")) {
      if ($line -notmatch '"type":"assistant"' -or $line -notmatch '"usage"') { continue }
      try { $o = $line | ConvertFrom-Json } catch { continue }
      $m = $o.message; $u = $m.usage
      if (-not $u -or -not $m.id) { continue }
      $key = "$($m.id):$($o.requestId)"
      if (-not $seen.Add($key)) { continue }
      $newIds.Add($key)

      $inp = [double]$u.input_tokens; $out = [double]$u.output_tokens
      $cr = [double]$u.cache_read_input_tokens; $cw = [double]$u.cache_creation_input_tokens
      $cw1h = [double]$u.cache_creation.ephemeral_1h_input_tokens
      $cw5m = if ($u.cache_creation) { [double]$u.cache_creation.ephemeral_5m_input_tokens } else { $cw }
      $t.input += $inp; $t.output += $out; $t.cacheRead += $cr; $t.cacheWrite += $cw

      $p = Get-Price ([string]$m.model)
      if ($p) {
        $c = ($inp * $p[1] + $out * $p[2] + $cr * $p[3] + $cw5m * $p[1] * 1.25 + $cw1h * $p[1] * 2) / 1e6
        if ($u.speed -eq 'fast') { $c *= 2 }
        $t.cost += $c
      }
    }
  }

  if ($newIds.Count) { [IO.File]::AppendAllLines($seenFile, $newIds) }
  $t.lastScan = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $tmp = Join-Path $stateDir 'usage-cache.json.tmp'
  [IO.File]::WriteAllText($tmp, ($t | ConvertTo-Json -Depth 4 -Compress), $utf8)
  Move-Item $tmp (Join-Path $stateDir 'usage-cache.json') -Force
}

New-Item -ItemType Directory -Force $stateDir | Out-Null
$totals = Load-Totals
$sinceScan = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $totals.lastScan
if ($sinceScan -ge 20 -or $sinceScan -lt 0) {   # negative: the clock jumped back
  # One scanner at a time across sessions; others just show the cached totals.
  $mutex = New-Object System.Threading.Mutex($false, 'Local\ClaudeStatuslineUsageScan')
  if ($mutex.WaitOne(0)) {
    try { $totals = Load-Totals; Update-Totals $totals } finally { $mutex.ReleaseMutex() }
  }
}

# ---------- plan limits from the endpoint behind /usage ----------
# Claude Code leaves a window out of the status line input when it is not the
# active limit, so fill gaps from /api/oauth/usage (cached; read-only).
function Get-ApiLimits {
  $cacheFile = Join-Path $stateDir 'api-usage.json'
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $cache = $null
  if (Test-Path $cacheFile) { try { $cache = Get-Content $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
  # A nextFetch far ahead means the clock jumped back; refetch instead of waiting it out.
  if ($cache -and $now -lt $cache.nextFetch -and $cache.nextFetch - $now -le 600) { return $cache.data }

  $next = $now + 120
  $data = if ($cache) { $cache.data } else { $null }
  try {
    $oauth = (Get-Content (Join-Path $configDir '.credentials.json') -Raw | ConvertFrom-Json).claudeAiOauth
    if ($oauth.accessToken -and [long]$oauth.expiresAt / 1000 -gt $now) {
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
      $data = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -TimeoutSec 3 -ErrorAction Stop -Headers @{
        Authorization = "Bearer $($oauth.accessToken)"; 'anthropic-beta' = 'oauth-2025-04-20'
      }
    }
  } catch { $next = $now + 600 }   # rate-limited or offline: back off, keep last data

  $out = @{ nextFetch = $next; data = $data } | ConvertTo-Json -Depth 6 -Compress
  [IO.File]::WriteAllText($cacheFile, $out, $utf8)
  $data
}

function To-Window($w) {
  if ($null -eq $w -or $null -eq $w.utilization) { return $null }
  $epoch = if ($w.resets_at) { ([DateTimeOffset]::Parse($w.resets_at)).ToUnixTimeSeconds() } else { $null }
  [pscustomobject]@{ used_percentage = [double]$w.utilization; resets_at = $epoch }
}

$fiveHour = $in.rate_limits.five_hour
$sevenDay = $in.rate_limits.seven_day
if (-not $fiveHour -or -not $sevenDay) {
  $api = Get-ApiLimits
  if ($api) {
    if (-not $fiveHour) { $fiveHour = To-Window $api.five_hour }
    if (-not $sevenDay) { $sevenDay = To-Window $api.seven_day }
  }
}

# ---------- auto-continue setting ----------
$autoOn = $true
$settingsFile = Join-Path $configDir 'settings.json'
if (Test-Path $settingsFile) {
  try { if ((Get-Content $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json).autoContinueAtUsageLimit -eq $false) { $autoOn = $false } } catch {}
}

# ---------- git branch ----------
function Get-Branch([string]$dir) {
  $d = $dir
  while ($d) {
    $gitPath = Join-Path $d '.git'
    if (Test-Path $gitPath) {
      $headFile = Join-Path $gitPath 'HEAD'
      if (-not (Test-Path $headFile -PathType Leaf)) {   # worktree: .git is a file "gitdir: ..."
        $gd = ((Get-Content $gitPath -Raw) -replace '^gitdir:\s*', '').Trim()
        $headFile = Join-Path $gd 'HEAD'
      }
      $head = (Get-Content $headFile -Raw).Trim()
      $branch = if ($head -match '^ref: refs/heads/(.+)$') { $Matches[1] } else { $head.Substring(0, 7) }
      if (Get-Command git -ErrorAction SilentlyContinue) {
        if (git -C $dir --no-optional-locks status --porcelain 2>$null | Select-Object -First 1) { $branch += '*' }
      }
      return $branch
    }
    $parent = Split-Path $d -Parent
    if ($parent -eq $d) { break }
    $d = $parent
  }
  $null
}

# ---------- context size (shared by line 1 and the context row) ----------
$cu = $in.context_window.current_usage
$ctxTokens = if ($cu) { [double]$cu.input_tokens + [double]$cu.cache_creation_input_tokens + [double]$cu.cache_read_input_tokens } else { 0 }
$ctxPct = [double]$in.context_window.used_percentage
if ($ctxTokens -lt 100000)     { $ctxPaint = 'Good';  $ctxTip = 'all good' }
elseif ($ctxTokens -lt 250000) { $ctxPaint = 'Caution'; $ctxTip = 'at a good stopping point: /handoff, then /clear, then /pickup' }
elseif ($ctxTokens -lt 500000) { $ctxPaint = 'Warn'; $ctxTip = 'now: /handoff, then /clear, then /pickup (or /compact mid-task)' }
else                           { $ctxPaint = 'Red';    $ctxTip = 'new chat now: /handoff, then /clear, then /pickup' }

# ---------- line 1: model | context % | project (branch) | thinking ----------
$model = if ($in.model.display_name) { $in.model.display_name } else { 'Claude' }
if ($in.model.id -match '-(\d+)-(\d+)$' -and $model -notmatch '\d') { $model += " $($Matches[1]).$($Matches[2])" }
$parts = @(B 30 144 255 $model)
if ($null -ne $in.context_window.used_percentage) { $parts += "$WRITE " + (& $ctxPaint ('{0:0}%' -f $ctxPct)) }

$cwd = if ($in.workspace.current_dir) { $in.workspace.current_dir } else { $in.cwd }
if ($cwd) {
  $proj = Cyan (Split-Path $cwd -Leaf)
  $branch = Get-Branch $cwd
  if ($branch) { $proj += ' ' + $(if ($branch.EndsWith('*')) { Caution "($branch)" } else { Good "($branch)" }) }
  $parts += $proj
}

# Effort colored by how hard Claude thinks: low grey -> medium sky -> high blue -> xhigh pink -> max red.
$effort = [string]$in.effort.level
$effortPaint = switch ($effort) { 'low' { 'Text' } 'medium' { 'Sky' } 'high' { 'Blue' } 'xhigh' { 'Pink' } 'max' { 'Red' } default { 'Text' } }
if ($in.thinking.enabled -or $effort) {
  $t = (& $effortPaint $DOT) + ' '
  if ($in.thinking.enabled) { $t += Text 'thinking' }
  if ($effort) { $t += $(if ($in.thinking.enabled) { ' ' } else { '' }) + (& $effortPaint $effort) }
  $parts += $t
}
$lines = @($parts -join $SEP)

# ---------- line 2: context (how much Claude re-reads every message) ----------
# Every message re-sends the whole chat, so cost per message grows with it.
# "xN vs new chat" compares against a fresh session (~20K tokens of setup).
$FRESH_CHAT_TOKENS = 20000
if ($ctxTokens -gt 0) {
  $mult = [Math]::Max(1, $ctxTokens / $FRESH_CHAT_TOKENS)
  $paint = $ctxPaint; $tip = $ctxTip
  $filled = [Math]::Min(10, [Math]::Max(0, [int][Math]::Round($ctxPct / 10)))
  $lines += (RowLabel 'context') + (& $paint (($DOT * $filled) + ($RING * (10 - $filled)))) + ' ' +
    (& $paint ('{0,3:0}%' -f $ctxPct)) + (Text ' full') + $DOT_SEP + (Text 'each message costs ') + (& $paint ('{0:0}x' -f $mult)) +
    (Text ' a new chat') + $DOT_SEP + (& $paint $tip)
} else {
  $lines += (RowLabel 'context') + (Faint ($RING * 10)) + (Text '   empty, new chat')
}

# ---------- line 3: cache (discount on re-reading the chat) ----------
$pc = $in.prompt_cache
$price = Get-Price ([string]$in.model.id)
$readX = if ($price) { $price[3] / $price[1] } else { 0.1 }              # cached re-read vs normal price
$writeX = if ($pc.ttl -eq '5m') { 1.25 } else { 2.0 }                     # rewriting the cache vs normal price
$coldX = [Math]::Round($writeX / $readX)
$recache = if ($pc.recache_tokens_if_cold) { [double]$pc.recache_tokens_if_cold } else { $ctxTokens }
$cacheLine = (RowLabel 'cache')
if ($pc -and $pc.caching_observed) {
  $left = if ($pc.expires_at) { [long]$pc.expires_at - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() } else { 0 }
  $left = [Math]::Min($left, $(if ($pc.ttl -eq '5m') { 300 } else { 3600 }))   # guard against clock jumps
  if ($pc.warm -and $left -gt 0) {
    $mins = [Math]::Ceiling($left / 60)
    $off = '{0:0}% off' -f ((1 - $readX) * 100)
    if ($mins -le 10) {
      $cacheLine += (Caution "$DOT expires in ") + (Value "$mins min") + $DOT_SEP
      if ($ctxTokens -ge 100000) {
        # Long chat about to lose its discount: last cheap moment to hand off.
        $cacheLine += (Caution 'stepping away? ') + (Value '/handoff') + (Caution ', then ') + (Value '/clear') + (Caution ', then ') + (Value '/pickup') + (Caution ' now while it is ') + (Gold $off)
      } else {
        $cacheLine += (Caution 'reply soon to keep ') + (Gold $off)
      }
    } else {
      $cacheLine += (Good "$DOT active") + (Text ' for ') + (Value "$mins min") + $DOT_SEP + (Text 're-reading the chat is ') + (Gold $off)
    }
  } else {
    $cacheLine += (Red "$RING expired") + $DOT_SEP + (Text 'next message costs ') + (Red "${coldX}x more") +
      $DOT_SEP + $(if ($recache -ge 100000) { Warn 'start a new chat' } else { Text 'ok for a short chat' })
  }
} else {
  $cacheLine += (Text "$RING not started yet")
}
$lines += $cacheLine

# ---------- lines 4-5: rate-limit bars ----------
function Limit-Line([string]$label, $w) {
  if ($null -eq $w -or $null -eq $w.used_percentage) {
    # Claude Code omits a window it has no current reading for.
    return (RowLabel $label) + (Faint ($RING * 10)) + ' ' + (Text ' --   no data yet')
  }
  $p = [double]$w.used_percentage
  if ($w.resets_at -and [long]$w.resets_at -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) {
    # The window already reset; the reported figure is stale until a new window opens.
    return (RowLabel $label) + (Dots 0) + ' ' + (Good '  0%') + '  ' + (Dim $RESET_ICON) + ' ' + (Good 'fresh window')
  }
  $s = (RowLabel $label) + (Dots $p) + ' ' + (Level $p ('{0,3:0}%' -f $p))
  $r = Fmt-Reset $w.resets_at
  if ($r) { $s += '  ' + (Dim $RESET_ICON) + ' ' + (Value $r) }
  $s
}
$l = Limit-Line 'current' $fiveHour; if ($l) { $lines += $l }
$l = Limit-Line 'weekly' $sevenDay; if ($l) { $lines += $l }

# ---------- lines 6-7: all-time usage, auto-continue ----------
$readTok = $totals.input + $totals.cacheWrite + $totals.cacheRead
$lines += (RowLabel 'all-time') + (Text 'Claude has read ') + (Sky (Fmt-Tokens $readTok)) +
  (Text ' tokens and written ') + (Violet (Fmt-Tokens $totals.output)) + $DOT_SEP + (Text 'would cost ') +
  (Gold ('$' + ('{0:N2}' -f $totals.cost))) + (Text ' without your plan')
$lines += (RowLabel 'auto') + $(if ($autoOn) {
    (Good "$DOT on") + $DOT_SEP + (Text 'Claude continues by itself when your limit resets')
  } else {
    (Red "$RING off") + $DOT_SEP + (Text 'turn on in ') + (Value '/config') + (Text ' to resume automatically after limits')
  })

[Console]::Out.Write(($lines -join "`n"))
