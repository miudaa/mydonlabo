# =========================================================
#  マイドンラボ 投稿ツール（Windows 用）
#  「起動.bat」をダブルクリックして使います
# =========================================================
$Owner = 'miudaa'
$Repo  = 'mydonlabo'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName Microsoft.VisualBasic
Add-Type -AssemblyName System.Security
[System.Windows.Forms.Application]::EnableVisualStyles()
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ConfDir   = Join-Path $env:APPDATA 'MydonLabo'
$TokenFile = Join-Path $ConfDir 'token.txt'
$HookFile  = Join-Path $ConfDir 'discord.txt'
$SiteUrl   = "https://$Owner.github.io/$Repo/"
$ImageExt  = @('.png', '.gif', '.jpg', '.jpeg', '.webp')

# ---------- トークン（このPCのこのユーザーだけが読める形で保存） ----------
$script:tokenError = ''
function Get-Token {
    $script:tokenError = ''
    if (-not (Test-Path $TokenFile)) { return $null }
    try {
        $enc = ([IO.File]::ReadAllText($TokenFile)).Trim()
        if (-not $enc) { return $null }
        if ($enc.StartsWith('dpapi:')) {
            $bytes = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($enc.Substring(6)), $null, 'CurrentUser')
            return [Text.Encoding]::UTF8.GetString($bytes)
        }
        # 前の版で保存したトークン
        $sec = ConvertTo-SecureString -String $enc
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    } catch {
        $script:tokenError = $_.Exception.Message
        return $null
    }
}
function Save-Token([string]$t) {
    New-Item -ItemType Directory -Force -Path $ConfDir | Out-Null
    $bytes = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($t), $null, 'CurrentUser')
    [IO.File]::WriteAllText($TokenFile, 'dpapi:' + [Convert]::ToBase64String($bytes))
    # 書けたかどうか、その場で読み直して確かめる
    $check = Get-Token
    if ($check -ne $t) { throw "トークンを保存できませんでした（$TokenFile）。$script:tokenError" }
}

# ---------- GitHub との通信 ----------
$script:http = New-Object System.Net.Http.HttpClient
$script:http.Timeout = [TimeSpan]::FromHours(12)

function Wait-Task($task, [int]$timeoutSec = 0) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (-not $task.IsCompleted) {
        [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40
        if ($timeoutSec -gt 0 -and $sw.Elapsed.TotalSeconds -gt $timeoutSec) { throw "通信が $timeoutSec 秒止まったので、あきらめました。" }
    }
    return $task.GetAwaiter().GetResult()
}

# 画面を固めずにストリームをコピーする（途中で画面を動かしたり、最小化から戻したりできる）
function Copy-StreamUI($src, $dst, [string]$label, [long]$total = -1, [int]$stallSec = 0) {
    $buf = New-Object byte[] 1048576
    $done = [long]0; $tick = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $n = if ($stallSec -gt 0) { Wait-Task ($src.ReadAsync($buf, 0, $buf.Length)) $stallSec } else { $src.Read($buf, 0, $buf.Length) }
        if ($n -le 0) { break }
        $dst.Write($buf, 0, $n)
        $done += $n
        if ($tick.ElapsedMilliseconds -gt 150) {
            if ($label -and $lblStatus) {
                $lblStatus.Text = if ($total -gt 0) { "$label（$(Format-Size $done) / $(Format-Size $total)）" } else { "$label（$(Format-Size $done)）" }
            }
            [System.Windows.Forms.Application]::DoEvents(); $tick.Restart()
        }
    }
}

# メッセージは必ずツールの画面の上に出す（後ろに隠れて操作できなくなるのを防ぐ）
function Show-Msg([string]$text, [string]$buttons = 'OK') {
    if ($form -and -not $form.IsDisposed) {
        if ($form.WindowState -eq 'Minimized') { $form.WindowState = 'Normal' }
        $form.Activate()
        return [System.Windows.Forms.MessageBox]::Show($form, $text, 'マイドンラボ', $buttons)
    }
    return [System.Windows.Forms.MessageBox]::Show($text, 'マイドンラボ', $buttons)
}
function New-GhRequest([string]$method, [string]$url) {
    $req = New-Object System.Net.Http.HttpRequestMessage ((New-Object System.Net.Http.HttpMethod $method), $url)
    $req.Headers.UserAgent.ParseAdd('MydonLaboUploader/1.0')
    $req.Headers.Accept.ParseAdd('application/vnd.github+json')
    $req.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue ('Bearer', $script:token)
    return $req
}
function Invoke-Gh([string]$method, [string]$path, $bodyObj) {
    $req = New-GhRequest $method ("https://api.github.com/repos/$Owner/$Repo" + $path)
    if ($null -ne $bodyObj) {
        $json = $bodyObj | ConvertTo-Json -Depth 5 -Compress
        $req.Content = New-Object System.Net.Http.StringContent ($json, [Text.Encoding]::UTF8, 'application/json')
    }
    $res  = Wait-Task ($script:http.SendAsync($req))
    $text = Wait-Task ($res.Content.ReadAsStringAsync())
    if (-not $res.IsSuccessStatusCode) {
        $code = [int]$res.StatusCode
        if ($code -eq 401) { throw 'トークンが正しくないか、期限が切れています。「トークン設定」から入れ直して下さい。' }
        if ($code -eq 403 -or $code -eq 404) { throw "このリポジトリに書き込む権限がありません（$code）。トークンの権限を確認して下さい。" }
        throw "GitHub でエラーが起きました（$code）：$text"
    }
    if ($text) { return ($text | ConvertFrom-Json) }
}
function Get-Mime([string]$path) {
    switch ([IO.Path]::GetExtension($path).ToLower()) {
        '.png'  { 'image/png' }  '.gif' { 'image/gif' }  '.jpg' { 'image/jpeg' }  '.jpeg' { 'image/jpeg' }
        '.webp' { 'image/webp' } '.zip' { 'application/zip' } default { 'application/octet-stream' }
    }
}
function Send-Asset($releaseId, [string]$path, [string]$name) {
    $url = "https://uploads.github.com/repos/$Owner/$Repo/releases/$releaseId/assets?name=" + [Uri]::EscapeDataString($name)
    $req = New-GhRequest 'POST' $url
    $fs = [IO.File]::OpenRead($path)
    try {
        $content = New-Object System.Net.Http.StreamContent ($fs, 1048576)
        $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse((Get-Mime $path))
        $content.Headers.ContentLength = $fs.Length
        $req.Content = $content
        $res  = Wait-Task ($script:http.SendAsync($req))
        $text = Wait-Task ($res.Content.ReadAsStringAsync())
        if (-not $res.IsSuccessStatusCode) {
            if ([int]$res.StatusCode -eq 422) { throw "同じ名前のファイル（$name）がすでにあります。" }
            throw "ファイルのアップロードに失敗しました（$([int]$res.StatusCode)）：$text"
        }
    } finally { $fs.Dispose() }
}
# ---------- Discord への通知（Webhook） ----------
function Get-Hook {
    if (-not (Test-Path $HookFile)) { return $null }
    try {
        $enc = ([IO.File]::ReadAllText($HookFile)).Trim(); if (-not $enc) { return $null }
        $bytes = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($enc.Substring(6)), $null, 'CurrentUser')
        return [Text.Encoding]::UTF8.GetString($bytes)
    } catch { return $null }
}
function Save-Hook([string]$u) {
    New-Item -ItemType Directory -Force -Path $ConfDir | Out-Null
    if (-not $u) { Remove-Item $HookFile -Force -ErrorAction SilentlyContinue; return }
    $bytes = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($u), $null, 'CurrentUser')
    [IO.File]::WriteAllText($HookFile, 'dpapi:' + [Convert]::ToBase64String($bytes))
}
# 1通送る。$files は画像のパス（最大10枚）。送れなければ例外
function Send-DiscordMessage([string]$hook, $payload, [string[]]$files) {
    for ($try = 0; $try -lt 3; $try++) {
        $mp = New-Object System.Net.Http.MultipartFormDataContent
        $json = $payload | ConvertTo-Json -Depth 8 -Compress
        $mp.Add((New-Object System.Net.Http.StringContent ($json, [Text.Encoding]::UTF8, 'application/json')), 'payload_json')
        $streams = @()
        for ($i = 0; $i -lt $files.Count; $i++) {
            $fs = [IO.File]::OpenRead($files[$i]); $streams += $fs
            $sc = New-Object System.Net.Http.StreamContent ($fs)
            $sc.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse((Get-Mime $files[$i]))
            $mp.Add($sc, "files[$i]", "img$i" + [IO.Path]::GetExtension($files[$i]).ToLower())
        }
        try {
            $res = Wait-Task ($script:http.PostAsync($hook + '?wait=true', $mp)) 120
            $text = Wait-Task ($res.Content.ReadAsStringAsync())
        } finally { foreach ($fs in $streams) { $fs.Dispose() }; $mp.Dispose() }
        if ($res.IsSuccessStatusCode) { return }
        if ([int]$res.StatusCode -eq 429) {
            $wait = 2; try { $wait = [double](($text | ConvertFrom-Json).retry_after) + 0.5 } catch { }
            $sw = [Diagnostics.Stopwatch]::StartNew(); while ($sw.Elapsed.TotalSeconds -lt $wait) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
            continue
        }
        throw "Discord に送れませんでした（$([int]$res.StatusCode)）：$text"
    }
    throw 'Discord が混んでいて送れませんでした。'
}
function Get-DlUrl($rel, [string]$fname) { "https://github.com/$Owner/$Repo/releases/download/$([Uri]::EscapeDataString([string]$rel.tag_name))/$([Uri]::EscapeDataString($fname))" }
function Write-NotifyLog([string]$msg) {
    try { New-Item -ItemType Directory -Force -Path $ConfDir | Out-Null; [IO.File]::AppendAllText((Join-Path $ConfDir 'discord.log'), "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg`r`n", [Text.Encoding]::UTF8) } catch { }
}
# 投稿したマイドンを知らせる。$entries は {Name, Image(パス or 空), Note}
function Send-DiscordNotify([string]$title, [string]$cat, [bool]$isNew, $entries) {
    $hook = Get-Hook
    if (-not $hook) { Write-NotifyLog "送らない（Webhook が読めない）：$title"; return $false }
    # List をそのまま @() で包むと「Argument types do not match」になることがあるので、1つずつ取り出して配列にする
    $entries = @(foreach ($x in $entries) { $x })
    if (-not $entries.Count) { Write-NotifyLog "送らない（知らせるマイドンが 0 体）：$title"; return $false }
    Write-NotifyLog "送る：$title（$($entries.Count) 体）"
    $where = if ($cat) { "**$title**（$cat）" } else { "**$title**" }
    $head = if ($isNew) { "新しい小分類 $where ができました！ マイドン $($entries.Count) 体" } else { "$where にマイドンが追加されました！ $($entries.Count) 体" }
    for ($p = 0; $p -lt $entries.Count; $p += 10) {
        $chunk = @($entries[$p..([Math]::Min($entries.Count, $p + 10) - 1)])
        $files = @(); $embeds = @(); $size = 0
        foreach ($e in $chunk) {
            $emb = [ordered]@{ title = [string]$e.Name; color = 2073558 }
            $links = @(foreach ($u in @($e.Links)) { if ($u) { [string]$u } })
            # タイトルの行き先は zip の直リンク（1体ずつ違う URL なので、Discord に画像をまとめられない）
            if ($links.Count) { $emb['url'] = $links[0] }
            $desc = @(); if ($e.Note) { $desc += [string]$e.Note }; $desc += $links
            if ($desc.Count) { $emb['description'] = ($desc -join "`n") }
            if ($e.Image -and (Test-Path -LiteralPath $e.Image)) {
                $len = (Get-Item -LiteralPath $e.Image).Length
                if ($size + $len -lt 9MB) {
                    $size += $len
                    $emb['image'] = @{ url = "attachment://img$($files.Count)" + [IO.Path]::GetExtension($e.Image).ToLower() }
                    $files += $e.Image
                }
            }
            $embeds += $emb
        }
        $payload = [ordered]@{ username = 'マイドンラボ'; embeds = $embeds; allowed_mentions = @{ parse = @() } }
        if ($p -eq 0) { $payload['content'] = "$head`n$SiteUrl" }
        try { Send-DiscordMessage $hook $payload $files }
        catch { Write-NotifyLog "失敗：$title → $($_.Exception.Message)"; throw }
    }
    Write-NotifyLog "送った：$title"
    return $true
}

function Format-Size([long]$n) {
    if ($n -ge 1GB) { return '{0:N2} GB' -f ($n / 1GB) }
    if ($n -ge 1MB) { return '{0:N1} MB' -f ($n / 1MB) }
    return '{0:N0} KB' -f ($n / 1KB)
}

# ---------- 小分類をまとめる（ダウンロードと組み分け） ----------
$script:httpNoRedir = New-Object System.Net.Http.HttpClient ((New-Object System.Net.Http.HttpClientHandler -Property @{ AllowAutoRedirect = $false }))
$script:httpNoRedir.Timeout = [TimeSpan]::FromHours(12)
$script:httpPlain = New-Object System.Net.Http.HttpClient
$script:httpPlain.Timeout = [TimeSpan]::FromHours(12)

function Save-AssetTo($asset, [string]$path) {
    $req = New-GhRequest 'GET' "https://api.github.com/repos/$Owner/$Repo/releases/assets/$($asset.id)"
    $req.Headers.Accept.Clear(); $req.Headers.Accept.ParseAdd('application/octet-stream')
    $res = Wait-Task ($script:httpNoRedir.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead))
    if ([int]$res.StatusCode -ge 300 -and [int]$res.StatusCode -lt 400 -and $res.Headers.Location) {
        # 実体は別のサーバーにあるので、鍵を付けずに取りに行く
        $res = Wait-Task ($script:httpPlain.GetAsync($res.Headers.Location, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead))
    }
    if (-not $res.IsSuccessStatusCode) { throw "$($asset.name) をダウンロードできませんでした（$([int]$res.StatusCode)）" }
    $src = Wait-Task ($res.Content.ReadAsStreamAsync()) 120
    $fs = [IO.File]::Create($path)
    try { Copy-StreamUI $src $fs "ダウンロード中… $($asset.name)" ([long]$asset.size) 180 } finally { $fs.Dispose(); $src.Dispose() }
}

# 1体分の添付を、別のリリースに m番号を付け直して上げる。上げたファイル名の一覧を返す
function Copy-ItemTo($item, $destId, [string]$id, [string]$tmp, [string]$destSim, [int]$fileStart = 1, [switch]$NoImages) {
    $k = 0
    $simLines = New-Object System.Collections.Generic.List[string]
    foreach ($a in @($item.Images) + @($item.Files)) {
        $isImg = $ImageExt -contains [IO.Path]::GetExtension($a.name).ToLower()
        if ($isImg) { $k++ }
        $ext = [IO.Path]::GetExtension($a.name).ToLower(); if (-not $ext) { $ext = '.zip' }
        if ($isImg -and $NoImages) { continue }
        $idx = if ($isImg) { $k } else { [array]::IndexOf(@($item.Files), $a) + $fileStart }
        $fname = if ($idx -le 1) { "$id$ext" } else { "${id}_$idx$ext" }
        if (-not $isImg -and $item.FileSims) {
            $sim = $item.FileSims[[string]$a.id]
            if ($sim -and $sim -ne $destSim) { $simLines.Add("シミュレーター $([IO.Path]::GetFileNameWithoutExtension($fname)): $sim") }
        }
        $local = Join-Path $tmp ([guid]::NewGuid().ToString('N') + $ext)
        Save-AssetTo $a $local
        if ($progress.Value -lt $progress.Maximum) { $progress.Value++ }
        $lblStatus.Text = "「$($item.Name)」をアップロード中… $fname（$(Format-Size $a.size)）"
        Send-Asset $destId $local $fname
        if ($progress.Value -lt $progress.Maximum) { $progress.Value++ }
        Remove-Item $local -Force -ErrorAction SilentlyContinue
    }
    return ,$simLines
}

# 選んだマイドンを別の小分類へ移す。$dest が $null なら新しい小分類（$newCat / $newTitle）を作る
function Invoke-Move($srcRel, [string[]]$stems, $dest, [string]$newCat, [string]$newTitle, [bool]$deleteEmpty) {
    $src = Invoke-Gh 'GET' "/releases/$($srcRel.id)" $null
    $items = @(Get-ReleaseItems $src | Where-Object { $stems -contains $_.Stem })
    if (-not $items.Count) { throw '移すマイドンが見つかりませんでした。↻ で読み込み直して下さい。' }
    $created = $false
    if ($dest) {
        $target = Invoke-Gh 'GET' "/releases/$($dest.id)" $null
    } else {
        # 新しい小分類：元の本文の設定（fps やカラーなど）を引き継ぐ
        $meta = (@(([string]$src.body) -split "`r?`n") | Where-Object { $_ -notmatch '^\s*名前\s+\S+\s*[:：]' -and $_ -notmatch "^\s*$SimRe\s+\S+\s*[:：]" }) -join "`n"
        $meta = Set-BodyCategory $meta.TrimEnd() $newCat
        $tag = 'post-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 4))
        $target = Invoke-Gh 'POST' '/releases' @{ tag_name = $tag; name = $newTitle; body = $meta; draft = $true }
        $created = $true
    }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('MydonLaboMove_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $nums = @($target.assets | ForEach-Object { if ($_.name -match '^m(\d+)') { [int]$Matches[1] } })
        $n = if ($nums.Count) { [int](($nums | Measure-Object -Maximum).Maximum) + 1 } else { 1 }
        $total = 0; foreach ($it in $items) { $total += $it.Images.Count + $it.Files.Count }
        $progress.Maximum = [Math]::Max(1, $total * 2); $progress.Value = 0
        $nameLines = New-Object System.Collections.Generic.List[string]
        $destSim = Get-BodySim ([string]$target.body)
        try {
            foreach ($it in $items) {
                $id = 'm{0:D2}' -f $n; $n++
                $sl = Copy-ItemTo $it $target.id $id $tmp $destSim
                $nameLines.Add("名前 ${id}: $($it.Name)")
                foreach ($l in $sl) { $nameLines.Add($l) }
            }
        } catch {
            if ($created) { try { Invoke-Gh 'DELETE' "/releases/$($target.id)" $null | Out-Null } catch { } }
            throw
        }
        $lblStatus.Text = '仕上げ中…'
        $body = ([string]$target.body).TrimEnd() + "`n" + ($nameLines -join "`n")
        Invoke-Gh 'PATCH' "/releases/$($target.id)" @{ body = $body; draft = $false } | Out-Null

        # 移し終わってから、元の小分類から消す
        $lblStatus.Text = '元の小分類から消しています…'
        foreach ($it in $items) { foreach ($a in @($it.Images) + @($it.Files)) { Invoke-Gh 'DELETE' "/releases/assets/$($a.id)" $null | Out-Null } }
        $movedIds = @($items | ForEach-Object { @($_.Images) + @($_.Files) } | ForEach-Object { $_.id })
        $left = @($src.assets | Where-Object { $movedIds -notcontains $_.id })
        if (-not $left.Count -and $deleteEmpty) {
            Invoke-Gh 'DELETE' "/releases/$($src.id)" $null | Out-Null
            try { Invoke-Gh 'DELETE' ('/git/refs/tags/' + [Uri]::EscapeDataString($src.tag_name)) $null | Out-Null } catch { }
        } else {
            $drop = @($items | ForEach-Object { $_.Stem } | Where-Object { $_ })
            $lines = @(([string]$src.body) -split "`r?`n") | Where-Object { -not ($_ -match '^\s*名前\s+(\S+?)\s*[:：]' -and $drop -contains $Matches[1].ToLower()) }
            $fileStems = @($items | ForEach-Object { $_.Files } | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.name) })
            Invoke-Gh 'PATCH' "/releases/$($src.id)" @{ body = (Remove-SimLines ($lines -join "`n") $fileStems) } | Out-Null
        }
        return [pscustomobject]@{ Count = $items.Count; Title = [string]$target.name }
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Show-MoveDialog {
    if (-not $script:token) { (Show-Msg ('先に「トークン設定」をして下さい。')) | Out-Null; return }
    if (-not $script:releases.Count) { Load-Releases }
    if (-not $script:releases.Count) { (Show-Msg ('小分類がまだありません。')) | Out-Null; return }
    $P = { param($x, $y) New-Object System.Drawing.Point ($x, $y) }
    $S = { param($w, $h) New-Object System.Drawing.Size ($w, $h) }
    $d = New-Object System.Windows.Forms.Form
    $d.Text = 'マイドンを移動'; $d.Font = $font; $d.ClientSize = (& $S 460 560)
    $d.StartPosition = 'CenterParent'; $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $l1 = New-Object System.Windows.Forms.Label; $l1.Text = '移動元の小分類'; $l1.Location = (& $P 14 12); $l1.Size = (& $S 432 22); $d.Controls.Add($l1)
    $cSrc = New-Object System.Windows.Forms.ComboBox; $cSrc.DropDownStyle = 'DropDownList'; $cSrc.Location = (& $P 14 36); $cSrc.Size = (& $S 432 26); $d.Controls.Add($cSrc)
    foreach ($item in $cbExisting.Items) { [void]$cSrc.Items.Add($item) }
    $l2 = New-Object System.Windows.Forms.Label; $l2.Text = '移すマイドンにチェック'; $l2.Location = (& $P 14 72); $l2.Size = (& $S 300 22); $d.Controls.Add($l2)
    $bAll = New-Object System.Windows.Forms.Button; $bAll.Text = '全部'; $bAll.Location = (& $P 316 68); $bAll.Size = (& $S 64 26); $d.Controls.Add($bAll)
    $bNone = New-Object System.Windows.Forms.Button; $bNone.Text = '外す'; $bNone.Location = (& $P 382 68); $bNone.Size = (& $S 64 26); $d.Controls.Add($bNone)
    $clb = New-Object System.Windows.Forms.CheckedListBox; $clb.Location = (& $P 14 98); $clb.Size = (& $S 432 200); $clb.CheckOnClick = $true; $d.Controls.Add($clb)
    $rExist = New-Object System.Windows.Forms.RadioButton; $rExist.Text = '今ある小分類へ'; $rExist.Checked = $true; $rExist.Location = (& $P 14 310); $rExist.Size = (& $S 432 24); $d.Controls.Add($rExist)
    $cDst = New-Object System.Windows.Forms.ComboBox; $cDst.DropDownStyle = 'DropDownList'; $cDst.Location = (& $P 34 336); $cDst.Size = (& $S 412 26); $d.Controls.Add($cDst)
    foreach ($item in $cbExisting.Items) { [void]$cDst.Items.Add($item) }
    $rNew = New-Object System.Windows.Forms.RadioButton; $rNew.Text = '新しい小分類を作る'; $rNew.Location = (& $P 14 372); $rNew.Size = (& $S 432 24); $d.Controls.Add($rNew)
    $l3 = New-Object System.Windows.Forms.Label; $l3.Text = '大分類'; $l3.Location = (& $P 34 402); $l3.Size = (& $S 90 22); $d.Controls.Add($l3)
    $cCat = New-Object System.Windows.Forms.ComboBox; $cCat.Location = (& $P 126 398); $cCat.Size = (& $S 320 26); $d.Controls.Add($cCat)
    foreach ($c in $cbCat.Items) { [void]$cCat.Items.Add($c) }
    $l4 = New-Object System.Windows.Forms.Label; $l4.Text = '小分類の名前'; $l4.Location = (& $P 34 436); $l4.Size = (& $S 90 22); $d.Controls.Add($l4)
    $tTitle = New-Object System.Windows.Forms.TextBox; $tTitle.Location = (& $P 126 432); $tTitle.Size = (& $S 320 26); $d.Controls.Add($tTitle)
    $chk = New-Object System.Windows.Forms.CheckBox; $chk.Text = '移動元が空になったら、その小分類を削除する'; $chk.Checked = $true; $chk.Location = (& $P 14 474); $chk.Size = (& $S 432 24); $d.Controls.Add($chk)
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = '移動する'; $ok.Location = (& $P 254 516); $ok.Size = (& $S 92 30); $d.Controls.Add($ok)
    $cancel = New-Object System.Windows.Forms.Button; $cancel.Text = 'やめる'; $cancel.Location = (& $P 354 516); $cancel.Size = (& $S 92 30); $cancel.DialogResult = 'Cancel'; $d.Controls.Add($cancel)
    $d.CancelButton = $cancel
    $script:moveItems = @()
    $syncDst = { $cDst.Enabled = $rExist.Checked; $cCat.Enabled = $rNew.Checked; $tTitle.Enabled = $rNew.Checked }
    $rExist.Add_CheckedChanged($syncDst); $rNew.Add_CheckedChanged($syncDst); & $syncDst
    $cSrc.Add_SelectedIndexChanged({
        $clb.Items.Clear()
        $script:moveItems = @(Get-ReleaseItems $script:releases[$cSrc.SelectedIndex])
        foreach ($it in $script:moveItems) { [void]$clb.Items.Add($it.Name) }
        $c = ''; foreach ($line in (([string]$script:releases[$cSrc.SelectedIndex].body) -split "`r?`n")) { if ($line -match '^\s*(カテゴリ|category)\s*[:：;；]\s*(.+?)\s*$') { $c = $Matches[2]; break } }
        if (-not $cCat.Text) { $cCat.Text = $c }
    })
    $bAll.Add_Click({ for ($i = 0; $i -lt $clb.Items.Count; $i++) { $clb.SetItemChecked($i, $true) } })
    $bNone.Add_Click({ for ($i = 0; $i -lt $clb.Items.Count; $i++) { $clb.SetItemChecked($i, $false) } })
    $ok.Add_Click({
        if ($cSrc.SelectedIndex -lt 0) { (Show-Msg ('移動元の小分類を選んで下さい。')) | Out-Null; return }
        if ($clb.CheckedIndices.Count -lt 1) { (Show-Msg ('移すマイドンを1体以上チェックして下さい。')) | Out-Null; return }
        if ($rExist.Checked -and $cDst.SelectedIndex -lt 0) { (Show-Msg ('移動先の小分類を選んで下さい。')) | Out-Null; return }
        if ($rExist.Checked -and $cDst.SelectedIndex -eq $cSrc.SelectedIndex) { (Show-Msg ('移動元と移動先が同じです。')) | Out-Null; return }
        if ($rNew.Checked -and -not $tTitle.Text.Trim()) { (Show-Msg ('新しい小分類の名前を入れて下さい。')) | Out-Null; return }
        if ($rNew.Checked -and -not $cCat.Text.Trim()) { (Show-Msg ('大分類を入れて下さい。')) | Out-Null; return }
        $d.DialogResult = 'OK'; $d.Close()
    })
    if ($cbExisting.SelectedIndex -ge 0) { $cSrc.SelectedIndex = $cbExisting.SelectedIndex } else { $cSrc.SelectedIndex = 0 }
    if ($d.ShowDialog($form) -ne 'OK') { return }
    $srcRel = $script:releases[$cSrc.SelectedIndex]
    $stems = @($clb.CheckedIndices | ForEach-Object { $script:moveItems[$_].Stem })
    $dest = if ($rExist.Checked) { $script:releases[$cDst.SelectedIndex] } else { $null }
    $btnPost.Enabled = $false; $btnMerge.Enabled = $false; $btnMove.Enabled = $false; $btnBatch.Enabled = $false
    try {
        $r = Invoke-Move $srcRel $stems $dest $cCat.Text.Trim() $tTitle.Text.Trim() $chk.Checked
        $lblStatus.Text = "移動しました！「$($r.Title)」に $($r.Count) 体を移しました。サイトを再読み込みすると出ます。"
        Load-Releases -Keep
    } catch {
        $lblStatus.Text = 'エラー：' + $_.Exception.Message
        (Show-Msg ("移動の途中で止まりました。`n`n$($_.Exception.Message)`n`n移動元からはまだ消していません。移動先に途中まで上がったファイルがあれば、GitHub で削除して下さい。")) | Out-Null
    } finally { $btnPost.Enabled = $true; $btnMerge.Enabled = $true; $btnMove.Enabled = $true; $btnBatch.Enabled = $true }
}

function Get-BodyNames([string]$body) {
    $map = @{}
    foreach ($line in ($body -split "`r?`n")) { if ($line -match '^\s*名前\s+(\S+?)\s*[:：]\s*(.+?)\s*$') { $map[$Matches[1].ToLower()] = $Matches[2] } }
    return $map
}

# 本文の「シミュレーター m01_2: TJAPlayer3」（zip ごとのシミュレーター）を読む
$SimRe = '(シミュレーター|シミュレータ|simulator|sim)'
function Get-BodySims([string]$body) {
    $map = @{}
    foreach ($line in ($body -split "`r?`n")) { if ($line -match "^\s*$SimRe\s+(\S+?)\s*[:：]\s*(.+?)\s*$") { $map[$Matches[2].ToLower()] = $Matches[3] } }
    return $map
}
# 小分類全体のシミュレーター（書いていなければ taikonauts）
function Get-BodySim([string]$body) {
    foreach ($line in ($body -split "`r?`n")) { if ($line -match "^\s*$SimRe\s*[:：;；]\s*(.+?)\s*$") { return $Matches[2] } }
    return 'taikonauts'
}
# zip の名前からシミュレーターを推測する（分からなければ空）
function Guess-Sim([string]$path) {
    $n = [IO.Path]::GetFileNameWithoutExtension($path)
    if ($n -match '(?i)tja\s*p(layer)?\s*3?|tjap3') { return 'TJAPlayer3' }
    if ($n -match '(?i)open\s*taiko') { return 'OpenTaiko' }
    if ($n -match '(?i)taikonauts') { return 'taikonauts' }
    return ''
}
# 名前の最後に付いたシミュレーター名（_TJAP3 など）を外す
function Remove-SimTag([string]$name) {
    $t = $name -replace '(?i)[\s_\-]*[\(（\[【]?\s*(tja\s*player\s*3?|tjap3?|open\s*taiko|taikonauts)\s*(版|用)?\s*[\)）\]】]?\s*$', ''
    if ($t.Trim()) { return $t.Trim() } else { return $name }
}
# 本文から、指定した添付（m01_2 など）のシミュレーター行を消す
function Remove-SimLines([string]$body, [string[]]$stems) {
    $low = @($stems | ForEach-Object { $_.ToLower() })
    return ((@($body -split "`r?`n") | Where-Object { -not ($_ -match "^\s*$SimRe\s+(\S+?)\s*[:：]" -and $low -contains $Matches[2].ToLower()) }) -join "`n")
}

# サイトと同じルールで、リリースの添付をマイドン1体ずつに分ける
function Get-ReleaseItems($rel) {
    $names = Get-BodyNames ([string]$rel.body)
    $imgs   = @($rel.assets | Where-Object { $ImageExt -contains [IO.Path]::GetExtension($_.name).ToLower() })
    $others = @($rel.assets | Where-Object { $ImageExt -notcontains [IO.Path]::GetExtension($_.name).ToLower() })
    $groups = [ordered]@{}
    foreach ($f in $others) {
        $k = ([IO.Path]::GetFileNameWithoutExtension($f.name).ToLower() -replace '^(m\d+)[_\-]\d+$', '$1')
        if (-not $groups.Contains($k)) { $groups[$k] = [pscustomobject]@{ Stem = $k; Name = [IO.Path]::GetFileNameWithoutExtension($f.name); Images = @(); Files = @() } }
        $groups[$k].Files += $f
    }
    $loose = @()
    foreach ($im in $imgs) {
        $k = [IO.Path]::GetFileNameWithoutExtension($im.name).ToLower(); $base = $k -replace '[_\-\s]\d+$', ''
        if ($groups.Contains($k)) { $groups[$k].Images += $im } elseif ($groups.Contains($base)) { $groups[$base].Images += $im } else { $loose += $im }
    }
    $list = @($groups.Values)
    if (-not @($list | Where-Object { $_.Images.Count }).Count) {
        $one = @([pscustomobject]@{ Stem = ''; Name = [string]$rel.name; Images = $imgs; Files = $others })
        Add-FileSims $rel $one
        return $one
    }
    foreach ($g in $list) {
        if (-not $g.Images.Count) { $g.Images = $loose }
        if ($names.ContainsKey($g.Stem)) { $g.Name = $names[$g.Stem] }
        else { $g.Name = ($g.Name -replace '[_\-\s]*\d+\s*fps$', '') }
    }
    if ($list.Count -eq 1 -and -not $names.ContainsKey($list[0].Stem)) { $list[0].Name = [string]$rel.name }
    Add-FileSims $rel $list
    return $list
}

# 各マイドンに、添付ごとのシミュレーター（FileSims：添付ID → 名前）を付ける
function Add-FileSims($rel, $list) {
    $fs = Get-BodySims ([string]$rel.body); $def = Get-BodySim ([string]$rel.body)
    foreach ($g in $list) {
        $m = @{}
        foreach ($f in $g.Files) { $k = [IO.Path]::GetFileNameWithoutExtension($f.name).ToLower(); $m[[string]$f.id] = $(if ($fs.ContainsKey($k)) { $fs[$k] } else { $def }) }
        $g | Add-Member -NotePropertyName FileSims -NotePropertyValue $m -Force
    }
}

function Set-BodyCategory([string]$body, [string]$cat) {
    $lines = @($body -split "`r?`n")
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*(カテゴリ|category)\s*[:：;；]') { $lines[$i] = "カテゴリ: $cat"; $found = $true; break } }
    if (-not $found) { $lines = @("カテゴリ: $cat") + $lines }
    return ($lines -join "`n")
}

function Invoke-Merge($rels, [string]$title, [string]$cat, [bool]$deleteOld) {
    $target = Invoke-Gh 'GET' "/releases/$($rels[0].id)" $null
    $sources = @($rels | Select-Object -Skip 1 | ForEach-Object { Invoke-Gh 'GET' "/releases/$($_.id)" $null })
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('MydonLaboMerge_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        # まとめ先がすでにツール形式（m01 など）ならそのまま残し、そうでなければ付け直す
        $targetIsTool = (@($target.assets).Count -gt 0) -and -not @($target.assets | Where-Object { $_.name -notmatch '^m\d+' }).Count
        $jobs = @()
        if (-not $targetIsTool) { foreach ($it in (Get-ReleaseItems $target)) { $jobs += [pscustomobject]@{ Item = $it; FromTarget = $true } } }
        foreach ($s in $sources) { foreach ($it in (Get-ReleaseItems $s)) { $jobs += [pscustomobject]@{ Item = $it; FromTarget = $false } } }
        $jobs = @($jobs | Where-Object { $_.Item.Images.Count -or $_.Item.Files.Count })

        $nums = @($target.assets | ForEach-Object { if ($_.name -match '^m(\d+)') { [int]$Matches[1] } })
        $n = if ($targetIsTool -and $nums.Count) { [int](($nums | Measure-Object -Maximum).Maximum) + 1 } else { 1 }
        if (-not $targetIsTool -and $nums.Count) { $n = [int](($nums | Measure-Object -Maximum).Maximum) + 1 }

        $total = 0; foreach ($j in $jobs) { $total += $j.Item.Images.Count + $j.Item.Files.Count }
        $progress.Maximum = [Math]::Max(1, $total * 2); $progress.Value = 0
        $nameLines = New-Object System.Collections.Generic.List[string]
        $replaced = New-Object System.Collections.Generic.List[object]
        $destSim = Get-BodySim ([string]$target.body)
        foreach ($j in $jobs) {
            $id = 'm{0:D2}' -f $n; $n++
            $nameLines.Add("名前 ${id}: $($j.Item.Name)")
            $sl = Copy-ItemTo $j.Item $target.id $id $tmp $destSim
            foreach ($l in $sl) { $nameLines.Add($l) }
            if ($j.FromTarget) { foreach ($a in @($j.Item.Images) + @($j.Item.Files)) { $replaced.Add($a) } }
        }

        # 本文：まとめ先の内容（カテゴリやタグなど）を残し、名前の行を付け直す
        $keep = if ($targetIsTool) { [string]$target.body } else { (@(([string]$target.body) -split "`r?`n") | Where-Object { $_ -notmatch '^\s*名前\s+\S+\s*[:：]' -and $_ -notmatch "^\s*$SimRe\s+\S+\s*[:：]" }) -join "`n" }
        $body = $keep.TrimEnd() + "`n" + ($nameLines -join "`n")
        if ($cat) { $body = Set-BodyCategory $body $cat }
        $lblStatus.Text = '仕上げ中…'
        Invoke-Gh 'PATCH' "/releases/$($target.id)" @{ name = $title; body = $body } | Out-Null

        # ここまで全部うまくいってから、古いファイルと元の小分類を消す
        foreach ($a in $replaced) { Invoke-Gh 'DELETE' "/releases/assets/$($a.id)" $null | Out-Null }
        if ($deleteOld) {
            foreach ($s in $sources) {
                $lblStatus.Text = "元の小分類「$($s.name)」を削除中…"
                Invoke-Gh 'DELETE' "/releases/$($s.id)" $null | Out-Null
                try { Invoke-Gh 'DELETE' ('/git/refs/tags/' + [Uri]::EscapeDataString($s.tag_name)) $null | Out-Null } catch { }
            }
        }
        return $jobs.Count
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Show-MergeDialog {
    if (-not $script:token) { (Show-Msg ('先に「トークン設定」をして下さい。')) | Out-Null; return }
    if ($script:releases.Count -lt 2) { (Show-Msg ('まとめられる小分類が2つ以上ありません。↻ で読み込み直して下さい。')) | Out-Null; return }
    $d = New-Object System.Windows.Forms.Form
    $d.Text = '小分類をまとめる'; $d.Font = $font; $d.ClientSize = (New-Object System.Drawing.Size (460, 430))
    $d.StartPosition = 'CenterParent'; $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $l1 = New-Object System.Windows.Forms.Label; $l1.Text = 'まとめる小分類を2つ以上チェックして下さい（一番上のものにまとめます）'; $l1.Location = (New-Object System.Drawing.Point (14, 12)); $l1.Size = (New-Object System.Drawing.Size (432, 22)); $d.Controls.Add($l1)
    $clb = New-Object System.Windows.Forms.CheckedListBox; $clb.Location = (New-Object System.Drawing.Point (14, 38)); $clb.Size = (New-Object System.Drawing.Size (432, 190)); $clb.CheckOnClick = $true; $d.Controls.Add($clb)
    foreach ($item in $cbExisting.Items) { [void]$clb.Items.Add($item) }
    $l2 = New-Object System.Windows.Forms.Label; $l2.Text = 'まとめた後の小分類の名前'; $l2.Location = (New-Object System.Drawing.Point (14, 240)); $l2.Size = (New-Object System.Drawing.Size (432, 22)); $d.Controls.Add($l2)
    $tTitle = New-Object System.Windows.Forms.TextBox; $tTitle.Location = (New-Object System.Drawing.Point (14, 264)); $tTitle.Size = (New-Object System.Drawing.Size (432, 26)); $d.Controls.Add($tTitle)
    $l3 = New-Object System.Windows.Forms.Label; $l3.Text = '大分類（空ならまとめ先のまま）'; $l3.Location = (New-Object System.Drawing.Point (14, 298)); $l3.Size = (New-Object System.Drawing.Size (432, 22)); $d.Controls.Add($l3)
    $cCat = New-Object System.Windows.Forms.ComboBox; $cCat.Location = (New-Object System.Drawing.Point (14, 322)); $cCat.Size = (New-Object System.Drawing.Size (432, 26)); $d.Controls.Add($cCat)
    foreach ($c in $cbCat.Items) { [void]$cCat.Items.Add($c) }
    $chk = New-Object System.Windows.Forms.CheckBox; $chk.Text = 'まとめ終わったら元の小分類を削除する'; $chk.Checked = $true; $chk.Location = (New-Object System.Drawing.Point (14, 356)); $chk.Size = (New-Object System.Drawing.Size (432, 24)); $d.Controls.Add($chk)
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'まとめる'; $ok.Location = (New-Object System.Drawing.Point (254, 390)); $ok.Size = (New-Object System.Drawing.Size (92, 30)); $d.Controls.Add($ok)
    $cancel = New-Object System.Windows.Forms.Button; $cancel.Text = 'やめる'; $cancel.Location = (New-Object System.Drawing.Point (354, 390)); $cancel.Size = (New-Object System.Drawing.Size (92, 30)); $cancel.DialogResult = 'Cancel'; $d.Controls.Add($cancel)
    $d.CancelButton = $cancel
    $clb.Add_ItemCheck({ param($sender, $e)
        if ($e.NewValue -eq [System.Windows.Forms.CheckState]::Checked -and -not $tTitle.Text) { $tTitle.Text = [string]$script:releases[$e.Index].name }
    })
    $ok.Add_Click({
        if ($clb.CheckedIndices.Count -lt 2) { (Show-Msg ('2つ以上チェックして下さい。')) | Out-Null; return }
        if (-not $tTitle.Text.Trim()) { (Show-Msg ('まとめた後の名前を入れて下さい。')) | Out-Null; return }
        $d.DialogResult = 'OK'; $d.Close()
    })
    if ($d.ShowDialog($form) -ne 'OK') { return }
    $sel = @($clb.CheckedIndices | ForEach-Object { $script:releases[$_] })
    $btnPost.Enabled = $false; $btnMerge.Enabled = $false
    try {
        $count = Invoke-Merge $sel $tTitle.Text.Trim() $cCat.Text.Trim() $chk.Checked
        $lblStatus.Text = "まとめました！「$($tTitle.Text.Trim())」に $count 体を入れました。サイトを再読み込みすると出ます。"
        Load-Releases -Keep
    } catch {
        $lblStatus.Text = 'エラー：' + $_.Exception.Message
        (Show-Msg ("まとめる途中で止まりました。`n`n$($_.Exception.Message)`n`n元の小分類はまだ消していません。まとめ先に途中まで上がったファイルがあれば、GitHub で削除して下さい。")) | Out-Null
    } finally { $btnPost.Enabled = $true; $btnMerge.Enabled = $true }
}

# ---------- 大分類を移動（小分類ごと、別の大分類へ） ----------
function Get-BodyCat([string]$body) {
    foreach ($line in ($body -split "`r?`n")) { if ($line -match '^\s*(カテゴリ|category)\s*[:：;；]\s*(.+?)\s*$') { return $Matches[2] } }
    return ''
}
function Show-CatMoveDialog {
    if (-not $script:token) { (Show-Msg ('先に「トークン設定」をして下さい。')) | Out-Null; return }
    if (-not $script:releases.Count) { Load-Releases }
    if (-not $script:releases.Count) { (Show-Msg ('小分類がまだありません。')) | Out-Null; return }
    $P = { param($x, $y) New-Object System.Drawing.Point ($x, $y) }
    $S = { param($w, $h) New-Object System.Drawing.Size ($w, $h) }
    $catOf = { param($r) $c = Get-BodyCat ([string]$r.body); if ($c) { $c } else { 'その他' } }
    $d = New-Object System.Windows.Forms.Form
    $d.Text = '大分類を移動'; $d.Font = $font; $d.ClientSize = (& $S 460 540)
    $d.StartPosition = 'CenterParent'; $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $rWhole = New-Object System.Windows.Forms.RadioButton; $rWhole.Text = '小分類ごと移す'; $rWhole.Checked = $true; $rWhole.Location = (& $P 14 10); $rWhole.Size = (& $S 160 24); $d.Controls.Add($rWhole)
    $rEach = New-Object System.Windows.Forms.RadioButton; $rEach.Text = 'どんちゃん1体ずつ移す'; $rEach.Location = (& $P 180 10); $rEach.Size = (& $S 260 24); $d.Controls.Add($rEach)
    $l0 = New-Object System.Windows.Forms.Label; $l0.Text = '大分類で絞る'; $l0.Location = (& $P 14 46); $l0.Size = (& $S 100 22); $d.Controls.Add($l0)
    $cFilter = New-Object System.Windows.Forms.ComboBox; $cFilter.DropDownStyle = 'DropDownList'; $cFilter.Location = (& $P 116 42); $cFilter.Size = (& $S 330 26); $d.Controls.Add($cFilter)
    $cats = @($script:releases | ForEach-Object { & $catOf $_ } | Select-Object -Unique)
    [void]$cFilter.Items.Add('（すべて）'); foreach ($c in $cats) { [void]$cFilter.Items.Add($c) }
    $l1 = New-Object System.Windows.Forms.Label; $l1.Location = (& $P 14 80); $l1.Size = (& $S 300 22); $d.Controls.Add($l1)
    $bAll = New-Object System.Windows.Forms.Button; $bAll.Text = '全部'; $bAll.Location = (& $P 316 76); $bAll.Size = (& $S 64 26); $d.Controls.Add($bAll)
    $bNone = New-Object System.Windows.Forms.Button; $bNone.Text = '外す'; $bNone.Location = (& $P 382 76); $bNone.Size = (& $S 64 26); $d.Controls.Add($bNone)
    $clb = New-Object System.Windows.Forms.CheckedListBox; $clb.Location = (& $P 14 106); $clb.Size = (& $S 432 230); $clb.CheckOnClick = $true; $d.Controls.Add($clb)
    $l2 = New-Object System.Windows.Forms.Label; $l2.Text = '移動先の大分類（新しい名前を入れてもOK）'; $l2.Location = (& $P 14 346); $l2.Size = (& $S 432 22); $d.Controls.Add($l2)
    $cDst = New-Object System.Windows.Forms.ComboBox; $cDst.Location = (& $P 14 370); $cDst.Size = (& $S 432 26); $d.Controls.Add($cDst)
    foreach ($c in $cats) { if ($c -ne 'その他') { [void]$cDst.Items.Add($c) } }
    $l4 = New-Object System.Windows.Forms.Label; $l4.Text = '入れる小分類（空なら元と同じ名前の小分類。無ければ作ります）'; $l4.Location = (& $P 14 404); $l4.Size = (& $S 432 22); $d.Controls.Add($l4)
    $cSub = New-Object System.Windows.Forms.ComboBox; $cSub.Location = (& $P 14 428); $cSub.Size = (& $S 432 26); $d.Controls.Add($cSub)
    $chk = New-Object System.Windows.Forms.CheckBox; $chk.Text = '移動元の小分類が空になったら削除する'; $chk.Checked = $true; $chk.Location = (& $P 14 460); $chk.Size = (& $S 432 24); $d.Controls.Add($chk)
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = '移動する'; $ok.Location = (& $P 254 496); $ok.Size = (& $S 92 30); $d.Controls.Add($ok)
    $cancel = New-Object System.Windows.Forms.Button; $cancel.Text = 'やめる'; $cancel.Location = (& $P 354 496); $cancel.Size = (& $S 92 30); $cancel.DialogResult = 'Cancel'; $d.Controls.Add($cancel)
    $d.CancelButton = $cancel
    $script:catRows = @()
    $fill = {
        $clb.Items.Clear(); $script:catRows = @()
        $each = $rEach.Checked
        $l1.Text = if ($each) { '移すどんちゃんにチェック' } else { '移す小分類にチェック' }
        foreach ($c in @($l4, $cSub, $chk)) { $c.Enabled = $each }
        foreach ($r in $script:releases) {
            $cv = & $catOf $r
            if ($cFilter.SelectedIndex -gt 0 -and $cv -ne [string]$cFilter.SelectedItem) { continue }
            if ($each) {
                foreach ($it in (Get-ReleaseItems $r)) { $script:catRows += [pscustomobject]@{ Rel = $r; Item = $it }; [void]$clb.Items.Add("$($it.Name)（$($r.name)／$cv）") }
            } else { $script:catRows += [pscustomobject]@{ Rel = $r; Item = $null }; [void]$clb.Items.Add("$($r.name)（$cv）") }
        }
    }
    $fillSub = {
        $keep = $cSub.Text; $cSub.Items.Clear()
        foreach ($r in $script:releases) { if ((& $catOf $r) -eq $cDst.Text.Trim()) { [void]$cSub.Items.Add([string]$r.name) } }
        $cSub.Text = $keep
    }
    $cFilter.Add_SelectedIndexChanged($fill); $rWhole.Add_CheckedChanged($fill); $rEach.Add_CheckedChanged($fill)
    $cDst.Add_TextChanged($fillSub)
    $bAll.Add_Click({ for ($i = 0; $i -lt $clb.Items.Count; $i++) { $clb.SetItemChecked($i, $true) } })
    $bNone.Add_Click({ for ($i = 0; $i -lt $clb.Items.Count; $i++) { $clb.SetItemChecked($i, $false) } })
    $ok.Add_Click({
        if ($clb.CheckedIndices.Count -lt 1) { (Show-Msg ($(if ($rEach.Checked) { '移すどんちゃんを1体以上チェックして下さい。' } else { '移す小分類を1つ以上チェックして下さい。' }))) | Out-Null; return }
        if (-not $cDst.Text.Trim()) { (Show-Msg ('移動先の大分類を入れて下さい。')) | Out-Null; return }
        $d.DialogResult = 'OK'; $d.Close()
    })
    $cFilter.SelectedIndex = 0
    if ($d.ShowDialog($form) -ne 'OK') { return }
    $sel = @($clb.CheckedIndices | ForEach-Object { $script:catRows[$_] })
    $cat = $cDst.Text.Trim(); $sub = $cSub.Text.Trim(); $each = $rEach.Checked; $delEmpty = $chk.Checked
    foreach ($b in @($btnPost, $btnCatMove, $btnMove, $btnMerge, $btnBatch)) { $b.Enabled = $false }
    $done = 0
    try {
        if (-not $each) {
            $progress.Maximum = $sel.Count; $progress.Value = 0
            foreach ($row in $sel) {
                $r = $row.Rel
                $lblStatus.Text = "「$($r.name)」を「$cat」へ移動中…"
                $fresh = Invoke-Gh 'GET' "/releases/$($r.id)" $null
                Invoke-Gh 'PATCH' "/releases/$($r.id)" @{ body = (Set-BodyCategory ([string]$fresh.body) $cat) } | Out-Null
                $done++; $progress.Value = $done
            }
            $lblStatus.Text = "移動しました！ $done 件の小分類を「$cat」へ移しました。サイトを再読み込みすると出ます。"
        } else {
            # 移動元の小分類ごとにまとめて、移動先の小分類へ移す
            foreach ($grp in ($sel | Group-Object { $_.Rel.id })) {
                $srcRel = $grp.Group[0].Rel
                $title = if ($sub) { $sub } else { [string]$srcRel.name }
                $dest = @($script:releases | Where-Object { [string]$_.name -eq $title -and (& $catOf $_) -eq $cat }) | Select-Object -First 1
                if ($dest -and $dest.id -eq $srcRel.id) { continue }
                $stems = @($grp.Group | ForEach-Object { $_.Item.Stem })
                $r = Invoke-Move $srcRel $stems $dest $cat $title $delEmpty
                $done += $r.Count
                Load-Releases   # 新しく作った小分類を、次の組でも使えるように
            }
            $lblStatus.Text = "移動しました！ $done 体を「$cat」へ移しました。サイトを再読み込みすると出ます。"
        }
        Load-Releases -Keep
    } catch {
        $lblStatus.Text = 'エラー：' + $_.Exception.Message
        (Show-Msg ("途中で止まりました（$done 件は移動済み）。`n`n$($_.Exception.Message)`n`n移し終わっていない分は、元の場所に残っています。")) | Out-Null
        Load-Releases -Keep
    } finally { foreach ($b in @($btnPost, $btnCatMove, $btnMove, $btnMerge, $btnBatch)) { $b.Enabled = $true } }
}

# ---------- 一括投稿（一覧ファイルから） ----------
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:gfCookies = New-Object System.Net.CookieContainer
$script:gfHandler = New-Object System.Net.Http.HttpClientHandler
$script:gfHandler.CookieContainer = $script:gfCookies
$script:gfHandler.AllowAutoRedirect = $true
$script:gfHttp = New-Object System.Net.Http.HttpClient ($script:gfHandler)
$script:gfHttp.Timeout = [TimeSpan]::FromHours(12)
$script:gfHttp.DefaultRequestHeaders.UserAgent.ParseAdd('Mozilla/5.0 (Windows NT 10.0; Win64; x64) MydonLaboUploader/1.0')

function Get-ResponseFileName($res, [string]$fallback) {
    $cd = $res.Content.Headers.ContentDisposition
    if ($cd) {
        $n = if ($cd.FileNameStar) { $cd.FileNameStar } else { $cd.FileName }
        if ($n) { $n = $n.Trim('"'); try { $n = [Uri]::UnescapeDataString($n) } catch { }; return $n }
    }
    # Content-Disposition が無い/読めない時は生のヘッダから拾う
    $raw = $null
    if ($res.Content.Headers.TryGetValues('Content-Disposition', [ref]$raw)) {
        $line = ($raw -join ';')
        if ($line -match "filename\*=UTF-8''([^;]+)") { return [Uri]::UnescapeDataString($Matches[1]) }
        if ($line -match 'filename="?([^";]+)"?') { $b = [Text.Encoding]::GetEncoding('ISO-8859-1').GetBytes($Matches[1]); return [Text.Encoding]::UTF8.GetString($b) }
    }
    return $fallback
}

# 応答をファイルに保存。HTML（ダウンロードページ）なら $null を返して中身の文字列を $script:lastHtml に入れる
function Save-HttpResponse($res, [string]$dir, [string]$fallbackName) {
    $ct = if ($res.Content.Headers.ContentType) { $res.Content.Headers.ContentType.MediaType } else { '' }
    if ($ct -like 'text/html*') { $script:lastHtml = Wait-Task ($res.Content.ReadAsStringAsync()); return $null }
    $name = Get-ResponseFileName $res $fallbackName
    $name = ($name -replace '[\\/:*?"<>|]', '_')
    $path = Join-Path $dir $name
    $src = Wait-Task ($res.Content.ReadAsStreamAsync()) 120
    $len = if ($res.Content.Headers.ContentLength) { [long]$res.Content.Headers.ContentLength } else { -1 }
    $fs = [IO.File]::Create($path)
    try { Copy-StreamUI $src $fs "ダウンロード中… $name" $len 180 } finally { $fs.Dispose(); $src.Dispose() }
    return $path
}

function Get-Http([string]$url, [string]$referer) {
    $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Get, $url)
    if ($referer) { $req.Headers.Referrer = [Uri]$referer }
    $res = Wait-Task ($script:gfHttp.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)) 180
    if (-not $res.IsSuccessStatusCode) { throw "ダウンロードできませんでした（$([int]$res.StatusCode)）：$url" }
    return $res
}

# ギガファイル便などのリンクからファイルを落とす。落とせたファイルのパスの配列を返す
function Get-LinkFiles([string]$url, [string]$dir) {
    $u = [Uri]$url
    $script:lastHtml = ''
    $res = Get-Http $url $null                                 # まずページを開いて Cookie をもらう
    $p = Save-HttpResponse $res $dir 'download.bin'
    if ($p) { return @($p) }
    if ($u.Host -like '*gigafile.nu') {
        $id = $u.AbsolutePath.Trim('/')
        $base = "$($u.Scheme)://$($u.Host)"
        foreach ($try in @("$base/download.php?file=$id", "$base/dl_zip.php?file=$id")) {
            $script:lastHtml = ''
            try { $res = Get-Http $try $url } catch { continue }
            $p = Save-HttpResponse $res $dir "$id.zip"
            if ($p) { return @($p) }
        }
        # まとめページ：中のダウンロードリンクを全部拾う
        $html = [string]$script:lastHtml
        $ids = @([regex]::Matches($html, 'download\.php\?file=([0-9A-Za-z\-]+)') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
        $out = @()
        foreach ($fid in $ids) {
            $res = Get-Http "$base/download.php?file=$fid" $url
            $p = Save-HttpResponse $res $dir "$fid.zip"
            if ($p) { $out += $p }
        }
        if ($out.Count) { return $out }
        if ($html -match 'パスワード|password') { throw 'パスワード付きのリンクでした。' }
        throw 'ダウンロード用のファイルが見つかりませんでした（期限切れか、ページの形が変わったかもしれません）。'
    }
    throw 'ファイルではなくページが返ってきました。直接ダウンロードできるリンクか確かめて下さい。'
}

# zip の中から「Config.json が入っているフォルダ」＝マイドン1体を探す
function Get-MydonRoots($zip) {
    $roots = @()
    foreach ($e in $zip.Entries) {
        $full = $e.FullName -replace '\\', '/'
        if ($full -match '(^|/)config\.json$' -and -not $e.FullName.EndsWith('/')) {
            $dir = $full.Substring(0, $full.Length - 'config.json'.Length).TrimEnd('/')
            $roots += $dir
        }
    }
    return @($roots | Select-Object -Unique)
}

function Get-RootThumb($zip, [string]$root, [string]$dir) {
    $pre = if ($root) { $root + '/' } else { '' }
    $imgs = @($zip.Entries | Where-Object { ($_.FullName -replace '\\', '/').StartsWith($pre) -and $_.Name -match '\.(png|gif)$' })
    if (-not $imgs.Count) { return $null }
    $num = { $d = ($_.Name -replace '\D', ''); if ($d) { [long]$d } else { 0 } }
    # サムネ：balloon_broke の最後の画像 → なければ normal の最初の画像 → なければ何か1枚
    $broke = @($imgs | Where-Object { ($_.FullName -replace '\\', '/') -match '(^|/)balloon_broke/' } | Sort-Object $num, Name)
    $normal = @($imgs | Where-Object { ($_.FullName -replace '\\', '/') -match '(^|/)normal/' } | Sort-Object $num, Name)
    $e = if ($broke.Count) { $broke[-1] } elseif ($normal.Count) { $normal[0] } else { $imgs[0] }
    $out = Join-Path $dir ([guid]::NewGuid().ToString('N') + [IO.Path]::GetExtension($e.Name))
    $src = $e.Open(); $dst = [IO.File]::Create($out)
    try { Copy-StreamUI $src $dst '' } finally { $dst.Dispose(); $src.Dispose() }
    return $out
}

# 1つのダウンロードファイルを、マイドン1体ずつの {Name, Zip, Thumbs} に分ける
function Split-Download([string]$path, [string]$dir, [string[]]$thumbs) {
    $stem = [IO.Path]::GetFileNameWithoutExtension($path)
    $zip = $null
    try { $zip = [System.IO.Compression.ZipFile]::OpenRead($path) } catch { $zip = $null }
    if (-not $zip) {
        # 普通の zip として開けない（7z など）時はそのまま1体として上げる
        return @([pscustomobject]@{ Name = $stem; Zip = $path; Thumbs = $thumbs; Note = 'zipとして開けなかったので、そのまま上げました' })
    }
    try {
        $roots = @(Get-MydonRoots $zip)
        if ($roots.Count -le 1) {
            $th = @($thumbs)
            if (-not $th.Count) { $root = if ($roots.Count) { $roots[0] } else { '' }; $t = Get-RootThumb $zip $root $dir; if ($t) { $th = @($t) } }
            return @([pscustomobject]@{ Name = $stem; Zip = $path; Thumbs = $th; Note = $(if ($thumbs.Count) { '' } else { 'サムネはzipの中の画像から作りました' }) })
        }
        $items = @()
        $i = 0
        foreach ($root in ($roots | Sort-Object)) {
            $name = ($root -split '/')[-1]
            $outZip = Join-Path $dir ((($name -replace '[\\/:*?"<>|]', '_')) + '_' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.zip')
            $fs = [IO.File]::Create($outZip)
            $za = New-Object System.IO.Compression.ZipArchive ($fs, [System.IO.Compression.ZipArchiveMode]::Create)
            try {
                foreach ($e in $zip.Entries) {
                    $full = $e.FullName -replace '\\', '/'
                    if (-not ($full -eq $root -or $full.StartsWith($root + '/'))) { continue }
                    $ne = $za.CreateEntry($full, [System.IO.Compression.CompressionLevel]::Fastest)
                    $ne.LastWriteTime = $e.LastWriteTime
                    if ($full.EndsWith('/')) { continue }
                    $src = $e.Open(); $dst = $ne.Open()
                    try { Copy-StreamUI $src $dst "「$name」を分けています…" } finally { $dst.Dispose(); $src.Dispose() }
                }
            } finally { $za.Dispose(); $fs.Dispose() }
            $th = @()
            if ($thumbs.Count -eq $roots.Count) { $th = @($thumbs[$i]) }
            else { $t = Get-RootThumb $zip $root $dir; if ($t) { $th = @($t) } elseif ($thumbs.Count) { $th = @($thumbs[0]) } }
            $items += [pscustomobject]@{ Name = $name; Zip = $outZip; Thumbs = $th; Note = '' }
            $i++
        }
        return $items
    } finally { $zip.Dispose() }
}

function Find-OrCreateRelease([string]$cat, [string]$title) {
    foreach ($r in $script:releases) {
        $c = ''
        foreach ($line in (([string]$r.body) -split "`r?`n")) { if ($line -match '^\s*(カテゴリ|category)\s*[:：;；]\s*(.+?)\s*$') { $c = $Matches[2]; break } }
        if ($r.name -eq $title -and $c -eq $cat) { return (Invoke-Gh 'GET' "/releases/$($r.id)" $null) }
    }
    $tag = 'post-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 4))
    $body = "カテゴリ: $cat`nfps: `nカラー: default`nシミュレーター: taikonauts"
    return (Invoke-Gh 'POST' '/releases' @{ tag_name = $tag; name = $title; body = $body; draft = $true })
}

function Invoke-Batch([string]$csvPath) {
    $rows = @(Import-Csv -Path $csvPath -Encoding UTF8)
    $rows = @($rows | Where-Object { $_.'リンク' -and $_.'リンク'.Trim() })
    if (-not $rows.Count) { throw '一覧にリンクがありません。' }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('MydonLaboBatch_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $log = New-Object System.Collections.Generic.List[string]
    $okCount = 0; $skipCount = 0
    # すでにサイトにあるマイドンの名前（被りは飛ばす）
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $norm = { param($t) (([string]$t).Normalize([Text.NormalizationForm]::FormKC) -replace '\s', '').ToLower() }
    $lblStatus.Text = 'サイトにあるマイドンを確認中…'
    # 被りは「名前＋シミュレーター」で見る（シミュレーター違いは別の版として上げる）
    foreach ($r in @(Invoke-Gh 'GET' '/releases?per_page=100' $null)) {
        if ($r.draft) { continue }
        foreach ($it in (Get-ReleaseItems $r)) {
            $sims = @($it.FileSims.Values); if (-not $sims.Count) { $sims = @(Get-BodySim ([string]$r.body)) }
            foreach ($sv in $sims) { [void]$seen.Add((& $norm $it.Name) + '|' + ([string]$sv).ToLower()) }
        }
    }
    try {
        $groups = $rows | Group-Object { "$($_.'大分類')`t$($_.'小分類')" }
        $progress.Maximum = $rows.Count; $progress.Value = 0
        foreach ($g in $groups) {
            $cat, $title = $g.Name -split "`t", 2
            if (-not $title) { $title = 'Discord配布' }
            $lblStatus.Text = "小分類「$title」を準備中…"
            $rel = Find-OrCreateRelease $cat $title
            $nums = @($rel.assets | ForEach-Object { if ($_.name -match '^m(\d+)') { [int]$Matches[1] } })
            $n = if ($nums.Count) { [int](($nums | Measure-Object -Maximum).Maximum) + 1 } else { 1 }
            $nameLines = New-Object System.Collections.Generic.List[string]
            $notify = New-Object System.Collections.Generic.List[object]
            $wasNew = [bool]$rel.draft
            $keepDir = Join-Path $tmp 'notify'; New-Item -ItemType Directory -Force -Path $keepDir | Out-Null
            $relSim = Get-BodySim ([string]$rel.body)
            # この小分類にあるマイドン：名前 → { Id, Zip数 }（同じ名前のシミュレーター違いは、ここに zip を足す）
            $here = @{}
            foreach ($it in (Get-ReleaseItems $rel)) { if ($it.Stem -match '^m\d+$') { $here[(& $norm $it.Name)] = [pscustomobject]@{ Id = $it.Stem; Zips = @($it.Files).Count } } }
            foreach ($row in $g.Group) {
                $link = $row.'リンク'.Trim()
                $work = Join-Path $tmp ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $work | Out-Null
                try {
                    $lblStatus.Text = "ダウンロード中… $link"
                    $files = if (Test-Path -LiteralPath $link -PathType Leaf) {
                        $dstPath = Join-Path $work ([IO.Path]::GetFileName($link))
                        $src = [IO.File]::OpenRead($link); $dst = [IO.File]::Create($dstPath)
                        try { Copy-StreamUI $src $dst "コピー中… $([IO.Path]::GetFileName($link))" $src.Length } finally { $dst.Dispose(); $src.Dispose() }
                        @($dstPath)
                    } else { @(Get-LinkFiles $link $work) }
                    $thumbs = @(([string]$row.'サムネ') -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and (Test-Path $_) })
                    $items = @()
                    foreach ($f in $files) { $items += Split-Download $f $work $thumbs }
                    if ($row.'名前' -and $items.Count -eq 1) { $items[0].Name = $row.'名前'.Trim() }
                    $rowSim = ([string]$row.'シミュレーター').Trim()
                    foreach ($it in $items) {
                        $sim = if ($rowSim) { $rowSim } else { $g2 = Guess-Sim $it.Zip; if (-not $g2) { $g2 = Guess-Sim $link }; if ($g2) { $g2 } else { $relSim } }
                        if (-not ([string]$row.'名前').Trim()) { $it.Name = Remove-SimTag $it.Name }
                        $nk = & $norm $it.Name
                        $key = $nk + '|' + $sim.ToLower()
                        if ($seen.Contains($key)) { $log.Add("△ $($it.Name)（$sim 版がもうあるので飛ばしました）"); $skipCount++; continue }
                        [void]$seen.Add($key)
                        $zext = [IO.Path]::GetExtension($it.Zip).ToLower(); if (-not $zext) { $zext = '.zip' }
                        if ($here.ContainsKey($nk)) {
                            # 同じ名前のマイドンがこの小分類にある → シミュレーター違いの zip として足す
                            $h = $here[$nk]; $h.Zips++
                            $fname = "$($h.Id)_$($h.Zips)$zext"
                            $lblStatus.Text = "「$($it.Name)」に $sim 版を追加中…（$(Format-Size (Get-Item $it.Zip).Length)）"
                            Send-Asset $rel.id $it.Zip $fname
                            if ($sim -ne $relSim) { $nameLines.Add("シミュレーター $($h.Id)_$($h.Zips): $sim") }
                            $okCount++
                            $log.Add("○ $($it.Name)（$sim 版を追加）")
                            $notify.Add([pscustomobject]@{ Name = $it.Name; Image = $null; Note = "$sim 版を追加"; Links = @(Get-DlUrl $rel $fname) })
                            continue
                        }
                        $id = 'm{0:D2}' -f $n; $n++
                        $here[$nk] = [pscustomobject]@{ Id = $id; Zips = 1 }
                        $k = 0
                        foreach ($t in $it.Thumbs) {
                            $k++; $ext = [IO.Path]::GetExtension($t).ToLower()
                            $lblStatus.Text = "「$($it.Name)」の画像をアップロード中…"
                            Send-Asset $rel.id $t $(if ($k -eq 1) { "$id$ext" } else { "${id}_$k$ext" })
                        }
                        $lblStatus.Text = "「$($it.Name)」をアップロード中…（$(Format-Size (Get-Item $it.Zip).Length)）"
                        Send-Asset $rel.id $it.Zip "$id$zext"
                        $nameLines.Add("名前 ${id}: $($it.Name)")
                        if ($sim -ne $relSim) { $nameLines.Add("シミュレーター ${id}: $sim") }
                        $okCount++
                        $log.Add("○ $($it.Name)" + $(if ($it.Note) { "（$($it.Note)）" } else { '' }))
                        # 通知用にサムネを取っておく（作業フォルダは1件ごとに消えるので）
                        $keep = $null
                        if (@($it.Thumbs).Count) { $keep = Join-Path $keepDir ([guid]::NewGuid().ToString('N') + [IO.Path]::GetExtension($it.Thumbs[0]).ToLower()); Copy-Item -LiteralPath $it.Thumbs[0] -Destination $keep }
                        $notify.Add([pscustomobject]@{ Name = $it.Name; Image = $keep; Note = $(if ($sim -ne $relSim) { "$sim 版" } else { '' }); Links = @(Get-DlUrl $rel "$id$zext") })
                    }
                } catch {
                    $log.Add("× $link → $($_.Exception.Message)")
                } finally {
                    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
                    $progress.Value = [Math]::Min($progress.Maximum, $progress.Value + 1)
                }
            }
            if ($nameLines.Count) {
                $body = ([string]$rel.body).TrimEnd() + "`n" + ($nameLines -join "`n")
                Invoke-Gh 'PATCH' "/releases/$($rel.id)" @{ body = $body; draft = $false } | Out-Null
                try {
                    $lblStatus.Text = "Discord に知らせています…（$title）"
                    if (Send-DiscordNotify $title $cat $wasNew $notify) { $log.Add("（Discord に「$title」の $($notify.Count) 体を知らせました）") }
                } catch { $log.Add("！ Discord に知らせられませんでした（$title）→ $($_.Exception.Message)") }
            } elseif ($rel.draft) {
                Invoke-Gh 'DELETE' "/releases/$($rel.id)" $null | Out-Null
            }
        }
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    $logPath = Join-Path ([IO.Path]::GetDirectoryName($csvPath)) ('一括投稿の結果_' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
    [IO.File]::WriteAllLines($logPath, $log, [Text.Encoding]::UTF8)
    return [pscustomobject]@{ Ok = $okCount; Skip = $skipCount; Fail = @($log | Where-Object { $_.StartsWith('×') }).Count; Log = $logPath }
}

function Start-Batch {
    if (-not $script:token) { (Show-Msg ('先に「トークン設定」をして下さい。')) | Out-Null; return }
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = '一括投稿の一覧ファイル（CSV）を選んで下さい'
    $dlg.Filter = 'CSV (*.csv)|*.csv'
    if ($dlg.ShowDialog() -ne 'OK') { return }
    $count = @(Import-Csv -Path $dlg.FileName -Encoding UTF8 | Where-Object { $_.'リンク' }).Count
    $ans = (Show-Msg ("$count 件のリンクを、ダウンロードして投稿します。`n時間がかかるので、終わるまでツールを閉じないで下さい。`n`n始めますか？") 'YesNo')
    if ($ans -ne 'Yes') { return }
    $btnPost.Enabled = $false; $btnMerge.Enabled = $false; $btnMove.Enabled = $false; $btnBatch.Enabled = $false
    try {
        if (-not $script:releases.Count) { Load-Releases }
        $r = Invoke-Batch $dlg.FileName
        $lblStatus.Text = "一括投稿が終わりました：成功 $($r.Ok) 体 / 被り $($r.Skip) 体 / 失敗 $($r.Fail) 件"
        (Show-Msg ("終わりました！`n成功：$($r.Ok) 体`n被りで飛ばした：$($r.Skip) 体`n失敗：$($r.Fail) 件`n`n結果はこのファイルにまとめました：`n$($r.Log)")) | Out-Null
        Load-Releases -Keep
    } catch {
        $lblStatus.Text = 'エラー：' + $_.Exception.Message
        (Show-Msg ("止まりました。`n`n$($_.Exception.Message)")) | Out-Null
    } finally { $btnPost.Enabled = $true; $btnMerge.Enabled = $true; $btnMove.Enabled = $true; $btnBatch.Enabled = $true }
}

# ---------- 画面 ----------
$font = New-Object System.Drawing.Font ('Yu Gothic UI', 9.5)
$form = New-Object System.Windows.Forms.Form
$form.Text = 'マイドンラボ 投稿ツール'
$form.Font = $font
$form.ClientSize = New-Object System.Drawing.Size (620, 730)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$iconPath = Join-Path $PSScriptRoot 'icon.ico'
if (Test-Path $iconPath) { $form.Icon = New-Object System.Drawing.Icon $iconPath }

function Add-Label($text, $x, $y, $w = 110) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point ($x, ($y + 4)); $l.Size = New-Object System.Drawing.Size ($w, 22)
    $form.Controls.Add($l); return $l
}
function Add-Control($ctl, $x, $y, $w, $h = 26) {
    $ctl.Location = New-Object System.Drawing.Point ($x, $y); $ctl.Size = New-Object System.Drawing.Size ($w, $h)
    $form.Controls.Add($ctl); return $ctl
}

# トークン
$lblToken = Add-Label '' 16 12 190
$btnHook = Add-Control (New-Object System.Windows.Forms.Button) 210 10 100 28
$btnHook.Text = 'Discord通知…'
$btnToken = Add-Control (New-Object System.Windows.Forms.Button) 470 10 134 28
$btnToken.Text = 'トークン設定'

# 投稿先
$rbNew = Add-Control (New-Object System.Windows.Forms.RadioButton) 16 48 140
$rbNew.Text = '新しい小分類を作る'; $rbNew.Checked = $true
$rbAdd = Add-Control (New-Object System.Windows.Forms.RadioButton) 160 48 150
$rbAdd.Text = '今ある小分類に追加'
$cbExisting = Add-Control (New-Object System.Windows.Forms.ComboBox) 16 80 540
$cbExisting.DropDownStyle = 'DropDownList'; $cbExisting.Enabled = $false
$btnReload = Add-Control (New-Object System.Windows.Forms.Button) 562 79 42 28
$btnReload.Text = '↻'
$btnMove = Add-Control (New-Object System.Windows.Forms.Button) 316 45 148 28
$btnMove.Text = 'マイドンを移動…'
$btnMerge = Add-Control (New-Object System.Windows.Forms.Button) 470 45 134 28
$btnBatch = Add-Control (New-Object System.Windows.Forms.Button) 316 10 148 28
$btnBatch.Text = '一括投稿（一覧）…'
$btnMerge.Text = '小分類をまとめる…'

# 項目
$y = 124
Add-Label '大分類' 16 $y | Out-Null
$cbCat = Add-Control (New-Object System.Windows.Forms.ComboBox) 130 $y 320
$btnCatMove = Add-Control (New-Object System.Windows.Forms.Button) 456 ($y - 1) 148 28
$btnCatMove.Text = '大分類を移動…'
$y += 36; Add-Label '小分類の名前' 16 $y | Out-Null
$txtTitle = Add-Control (New-Object System.Windows.Forms.TextBox) 130 $y 474
$y += 36; Add-Label 'タグ' 16 $y | Out-Null
$txtTags = Add-Control (New-Object System.Windows.Forms.TextBox) 130 $y 474
$y += 36; Add-Label 'fps' 16 $y | Out-Null
$cbFps = Add-Control (New-Object System.Windows.Forms.ComboBox) 130 $y 120
@('240', '120', '60', '30', '20', '15', '10') | ForEach-Object { [void]$cbFps.Items.Add($_) }
$cbFps.Text = '60'
Add-Label 'カラー' 270 $y 60 | Out-Null
$txtColor = Add-Control (New-Object System.Windows.Forms.TextBox) 334 $y 270
$txtColor.Text = 'default'
$y += 36; Add-Label 'シミュレーター' 16 $y | Out-Null
$cbSim = Add-Control (New-Object System.Windows.Forms.ComboBox) 130 $y 220
@('taikonauts', 'TJAPlayer3', 'OpenTaiko') | ForEach-Object { [void]$cbSim.Items.Add($_) }
$cbSim.Text = 'taikonauts'
$y += 36; Add-Label '説明（任意）' 16 $y | Out-Null
$txtDesc = Add-Control (New-Object System.Windows.Forms.TextBox) 130 $y 474 56
$txtDesc.Multiline = $true; $txtDesc.ScrollBars = 'Vertical'

# マイドン一覧
$y += 70
Add-Label 'マイドン（画像とzipをまとめてドラッグ＆ドロップでもOK）' 16 $y 560 | Out-Null
$y += 26
$list = Add-Control (New-Object System.Windows.Forms.ListView) 16 $y 588 200
$list.View = 'Details'; $list.FullRowSelect = $true; $list.GridLines = $true; $list.AllowDrop = $true; $list.HideSelection = $false
[void]$list.Columns.Add('名前', 190); [void]$list.Columns.Add('画像', 170); [void]$list.Columns.Add('zip', 204)
$y += 206
$btnAddM = Add-Control (New-Object System.Windows.Forms.Button) 16 $y 130 30;  $btnAddM.Text = '＋ マイドン追加'
$btnRename = Add-Control (New-Object System.Windows.Forms.Button) 152 $y 110 30; $btnRename.Text = '名前を変える'
$btnDelM = Add-Control (New-Object System.Windows.Forms.Button) 268 $y 80 30;  $btnDelM.Text = '削除'
$btnSim = Add-Control (New-Object System.Windows.Forms.Button) 354 $y 150 30;  $btnSim.Text = 'zipのシミュレーター…'

# 投稿
$y += 44
$progress = Add-Control (New-Object System.Windows.Forms.ProgressBar) 16 $y 588 14
$y += 20
$lblStatus = Add-Label '' 16 $y 588
$y += 28
$btnPost = Add-Control (New-Object System.Windows.Forms.Button) 16 $y 588 40
$btnPost.Text = 'GitHub に投稿する'
$btnPost.Font = New-Object System.Drawing.Font ('Yu Gothic UI', 11, [System.Drawing.FontStyle]::Bold)

# ---------- データ ----------
$script:mydons   = New-Object System.Collections.ArrayList
$script:releases = @()
$script:token    = Get-Token

function Update-TokenLabel {
    $btnHook.Text = if (Get-Hook) { 'Discord通知 ✓' } else { 'Discord通知…' }
    if ($script:token) { $lblToken.Text = '✓ トークン設定済み'; $lblToken.ForeColor = [System.Drawing.Color]::DarkGreen }
    elseif ($script:tokenError) { $lblToken.Text = "保存したトークンを読めませんでした：$script:tokenError"; $lblToken.ForeColor = [System.Drawing.Color]::Firebrick }
    else { $lblToken.Text = 'まず「トークン設定」をして下さい'; $lblToken.ForeColor = [System.Drawing.Color]::Firebrick }
}
function Update-List {
    $list.BeginUpdate(); $list.Items.Clear()
    foreach ($m in $script:mydons) {
        $it = New-Object System.Windows.Forms.ListViewItem ($m.Name)
        [void]$it.SubItems.Add((($m.Images | ForEach-Object { [IO.Path]::GetFileName($_) }) -join ', '))
        $zs = for ($i = 0; $i -lt $m.Zips.Count; $i++) {
            $z = $m.Zips[$i]; $sim = $m.Sims[$i]
            '{0} ({1})' -f [IO.Path]::GetFileName($z), (Format-Size (Get-Item $z).Length) + $(if ($sim) { " [$sim]" } else { '' })
        }
        [void]$it.SubItems.Add((@($zs) -join ', '))
        [void]$list.Items.Add($it)
    }
    $list.EndUpdate()
}
function Update-Mode {
    $add = $rbAdd.Checked
    $cbExisting.Enabled = $add
    foreach ($c in @($cbCat, $txtTitle, $txtTags, $cbFps, $txtColor, $cbSim, $txtDesc)) { $c.Enabled = -not $add }
}
function Get-DefaultName {
    if ($script:mydons.Count -eq 0 -and $rbNew.Checked -and $txtTitle.Text.Trim()) { return $txtTitle.Text.Trim() }
    return ''
}
function Ask-Name([string]$suggest) {
    return [Microsoft.VisualBasic.Interaction]::InputBox('このマイドンの名前を入れて下さい（サイトにこの名前で出ます）', 'マイドンの名前', $suggest)
}
function Add-Mydon([string]$name, $images, $zips) {
    $name = $name.Trim()
    if (-not $name) { return }
    $sims = @($zips | ForEach-Object { Guess-Sim $_ })
    [void]$script:mydons.Add([pscustomobject]@{ Name = $name; Images = @($images); Zips = @($zips); Sims = $sims })
    Update-List
}

function Load-Releases([switch]$Keep) {
    if (-not $script:token) { return }
    $before = $lblStatus.Text
    $lblStatus.Text = 'GitHub から小分類の一覧を読み込み中…'
    try {
        $all = @(Invoke-Gh 'GET' '/releases?per_page=100' $null) | Where-Object { -not $_.draft }
        $script:releases = @($all)
        $cbExisting.Items.Clear()
        $cats = New-Object System.Collections.Generic.List[string]
        foreach ($r in $script:releases) {
            $cat = ''
            foreach ($line in ($r.body -split "`r?`n")) { if ($line -match '^\s*(カテゴリ|category)\s*[:：;；]\s*(.+?)\s*$') { $cat = $Matches[2]; break } }
            if ($cat -and -not $cats.Contains($cat)) { $cats.Add($cat) }
            $label = if ($cat) { "$($r.name)（$cat）" } else { $r.name }
            [void]$cbExisting.Items.Add($label)
        }
        $keep = $cbCat.Text; $cbCat.Items.Clear(); foreach ($c in $cats) { [void]$cbCat.Items.Add($c) }; $cbCat.Text = $keep
        if ($cbExisting.Items.Count) { $cbExisting.SelectedIndex = 0 }
        $lblStatus.Text = if ($Keep) { $before } else { "小分類 $($script:releases.Count) 件を読み込みました" }
    } catch { $lblStatus.Text = $_.Exception.Message }
}

# ---------- 操作 ----------
$btnToken.Add_Click({
    $msg = "GitHub のトークンを貼り付けて下さい。`n（Fine-grained token／リポジトリ $Repo／Contents: Read and write）`n`nこのPCの、このユーザーだけが読める形で保存されます。"
    $t = [Microsoft.VisualBasic.Interaction]::InputBox($msg, 'トークン設定', '')
    if ($t.Trim()) {
        try { Save-Token $t.Trim() } catch { (Show-Msg ($_.Exception.Message)) | Out-Null }
        $script:token = $t.Trim(); Update-TokenLabel; Load-Releases
    }
})
$btnHook.Add_Click({
    $now = Get-Hook
    $msg = "投稿した時に Discord へ知らせる Webhook の URL を貼り付けて下さい。`n（チャンネルの設定 → 連携サービス → ウェブフック → 新しいウェブフック → URLをコピー）`n`n空にして OK を押すと、通知をやめます。"
    $u = [Microsoft.VisualBasic.Interaction]::InputBox($msg, 'Discord通知', $(if ($now) { $now } else { '' }))
    if ($u -eq '' -and -not $now) { return }
    $u = $u.Trim()
    if ($u -and $u -notmatch '^https://(ptb\.|canary\.)?(discord|discordapp)\.com/api/webhooks/\d+/[\w-]+$') { (Show-Msg ('Discord の Webhook の URL ではないようです。もう一度コピーして下さい。')) | Out-Null; return }
    if ($u -eq $now) { return }
    Save-Hook $u; Update-TokenLabel
    if (-not $u) { $lblStatus.Text = 'Discord への通知をやめました。'; return }
    try {
        Send-DiscordMessage $u ([ordered]@{ username = 'マイドンラボ'; content = "マイドンラボの投稿ツールから、通知のテストです。`n$SiteUrl"; allowed_mentions = @{ parse = @() } }) @()
        $lblStatus.Text = 'Discord 通知を設定しました（テストを送りました）。'
    } catch { (Show-Msg ("保存はしましたが、テストを送れませんでした。`n`n$($_.Exception.Message)")) | Out-Null }
})
$rbNew.Add_CheckedChanged({ Update-Mode })
$rbAdd.Add_CheckedChanged({ Update-Mode })
$btnReload.Add_Click({ Load-Releases })
$btnMerge.Add_Click({ Show-MergeDialog })
$btnMove.Add_Click({ Show-MoveDialog })
$btnCatMove.Add_Click({ Show-CatMoveDialog })
$btnBatch.Add_Click({ Start-Batch })

$btnAddM.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = '① マイドンの画像を選んで下さい（複数可・なしでもOK）'
    $dlg.Filter = '画像 (*.png;*.gif;*.jpg;*.jpeg;*.webp)|*.png;*.gif;*.jpg;*.jpeg;*.webp'
    $dlg.Multiselect = $true
    $imgs = @(); if ($dlg.ShowDialog() -eq 'OK') { $imgs = @($dlg.FileNames) }
    $dlg2 = New-Object System.Windows.Forms.OpenFileDialog
    $dlg2.Title = '② マイドンの zip を選んで下さい（複数可）'
    $dlg2.Filter = 'zip (*.zip)|*.zip|すべてのファイル (*.*)|*.*'
    $dlg2.Multiselect = $true
    if ($dlg2.ShowDialog() -ne 'OK') { return }
    $suggest = Get-DefaultName
    if (-not $suggest) { $suggest = Remove-SimTag ([IO.Path]::GetFileNameWithoutExtension($dlg2.FileNames[0])) }
    Add-Mydon (Ask-Name $suggest) $imgs $dlg2.FileNames
})
$list.Add_DragEnter({ if ($_.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) { $_.Effect = 'Copy' } })
$list.Add_DragDrop({
    $files = @($_.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop))
    $imgs = @($files | Where-Object { $ImageExt -contains [IO.Path]::GetExtension($_).ToLower() })
    $zips = @($files | Where-Object { $ImageExt -notcontains [IO.Path]::GetExtension($_).ToLower() })
    if (-not $zips.Count) { (Show-Msg ('zip が入っていません。画像と zip を一緒にドロップして下さい。')) | Out-Null; return }
    # 同じ名前の画像と zip をペアにする。ペアにならない時は全部で1体
    $groups = [ordered]@{}
    foreach ($z in $zips) { $k = [IO.Path]::GetFileNameWithoutExtension($z).ToLower(); if (-not $groups.Contains($k)) { $groups[$k] = @{ Name = [IO.Path]::GetFileNameWithoutExtension($z); Images = @(); Zips = @() } }; $groups[$k].Zips += $z }
    $loose = @()
    foreach ($im in $imgs) { $k = ([IO.Path]::GetFileNameWithoutExtension($im).ToLower() -replace '[_\-\s]\d+$', ''); if ($groups.Contains($k)) { $groups[$k].Images += $im } else { $loose += $im } }
    $paired = @($groups.Values | Where-Object { $_.Images.Count })
    if ($groups.Count -eq 1 -or -not $paired.Count) {
        $suggest = Get-DefaultName; if (-not $suggest) { $suggest = Remove-SimTag (@($groups.Values)[0].Name) }
        Add-Mydon (Ask-Name $suggest) $imgs $zips
    } else {
        foreach ($g in $groups.Values) { if (-not $g.Images.Count) { $g.Images = $loose }; Add-Mydon (Ask-Name $g.Name) $g.Images $g.Zips }
    }
})
$btnRename.Add_Click({
    if (-not $list.SelectedIndices.Count) { return }
    $i = $list.SelectedIndices[0]; $m = $script:mydons[$i]
    $n = Ask-Name $m.Name
    if ($n.Trim()) { $m.Name = $n.Trim(); Update-List }
})
$list.Add_DoubleClick({ $btnRename.PerformClick() })
$btnDelM.Add_Click({
    if (-not $list.SelectedIndices.Count) { return }
    $script:mydons.RemoveAt($list.SelectedIndices[0]); Update-List
})

$btnSim.Add_Click({
    if (-not $list.SelectedIndices.Count) { (Show-Msg ('一覧からマイドンを選んで下さい。')) | Out-Null; return }
    $m = $script:mydons[$list.SelectedIndices[0]]
    $def = if ($rbNew.Checked) { $cbSim.Text.Trim() } elseif ($cbExisting.SelectedIndex -ge 0) { Get-BodySim ([string]$script:releases[$cbExisting.SelectedIndex].body) } else { 'taikonauts' }
    if (-not $def) { $def = 'taikonauts' }
    $d = New-Object System.Windows.Forms.Form
    $d.Text = "「$($m.Name)」の zip ごとのシミュレーター"; $d.Font = $font
    $d.StartPosition = 'CenterParent'; $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $l = New-Object System.Windows.Forms.Label; $l.Text = "空のままなら小分類のシミュレーター（$def）になります"; $l.Location = (New-Object System.Drawing.Point (14, 12)); $l.Size = (New-Object System.Drawing.Size (452, 22)); $d.Controls.Add($l)
    $boxes = @(); $yy = 42
    for ($i = 0; $i -lt $m.Zips.Count; $i++) {
        $lz = New-Object System.Windows.Forms.Label; $lz.Text = [IO.Path]::GetFileName($m.Zips[$i]); $lz.AutoEllipsis = $true; $lz.Location = (New-Object System.Drawing.Point (14, ($yy + 4))); $lz.Size = (New-Object System.Drawing.Size (250, 22)); $d.Controls.Add($lz)
        $cb = New-Object System.Windows.Forms.ComboBox; $cb.Location = (New-Object System.Drawing.Point (270, $yy)); $cb.Size = (New-Object System.Drawing.Size (196, 26)); $d.Controls.Add($cb)
        @('taikonauts', 'TJAPlayer3', 'OpenTaiko') | ForEach-Object { [void]$cb.Items.Add($_) }
        $cb.Text = [string]$m.Sims[$i]
        $boxes += $cb; $yy += 34
    }
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'OK'; $ok.DialogResult = 'OK'; $ok.Location = (New-Object System.Drawing.Point (274, ($yy + 8))); $ok.Size = (New-Object System.Drawing.Size (92, 30)); $d.Controls.Add($ok)
    $cancel = New-Object System.Windows.Forms.Button; $cancel.Text = 'やめる'; $cancel.DialogResult = 'Cancel'; $cancel.Location = (New-Object System.Drawing.Point (374, ($yy + 8))); $cancel.Size = (New-Object System.Drawing.Size (92, 30)); $d.Controls.Add($cancel)
    $d.AcceptButton = $ok; $d.CancelButton = $cancel
    $d.ClientSize = (New-Object System.Drawing.Size (480, ($yy + 50)))
    if ($d.ShowDialog($form) -ne 'OK') { return }
    $m.Sims = @($boxes | ForEach-Object { $_.Text.Trim() })
    Update-List
})

$btnPost.Add_Click({
    if (-not $script:token) { (Show-Msg ('先に「トークン設定」をして下さい。')) | Out-Null; return }
    if (-not $script:mydons.Count) { (Show-Msg ('マイドンを1体以上追加して下さい。')) | Out-Null; return }
    if ($rbNew.Checked -and -not $txtTitle.Text.Trim()) { (Show-Msg ('小分類の名前を入れて下さい。')) | Out-Null; return }
    if ($rbAdd.Checked -and $cbExisting.SelectedIndex -lt 0) { (Show-Msg ('追加する小分類を選んで下さい。')) | Out-Null; return }
    $noImg = @($script:mydons | Where-Object { -not $_.Images.Count })
    if ($noImg.Count) {
        $ans = (Show-Msg ("画像のないマイドンがあります（$($noImg[0].Name) など）。このまま投稿しますか？") 'YesNo')
        if ($ans -ne 'Yes') { return }
    }

    $btnPost.Enabled = $false
    try {
        $nameLines = New-Object System.Collections.Generic.List[string]
        if ($rbNew.Checked) {
            $tag = 'post-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
            $lines = @("カテゴリ: $($cbCat.Text.Trim())", "タグ: $($txtTags.Text.Trim())", "fps: $($cbFps.Text.Trim())", "カラー: $($txtColor.Text.Trim())", "シミュレーター: $($cbSim.Text.Trim())")
            $lblStatus.Text = '小分類（リリース）を作成中…'
            $rel = Invoke-Gh 'POST' '/releases' @{ tag_name = $tag; name = $txtTitle.Text.Trim(); body = ($lines -join "`n"); draft = $true }
            $baseBody = ($lines -join "`n")
            $desc = $txtDesc.Text.Trim()
            $start = 1
            $existing = @()
        } else {
            $rel = $script:releases[$cbExisting.SelectedIndex]
            $rel = Invoke-Gh 'GET' "/releases/$($rel.id)" $null
            $baseBody = [string]$rel.body
            $desc = ''
            $existing = @(Get-ReleaseItems $rel | Where-Object { $_.Stem -match '^m\d+$' })
            $nums = @($rel.assets | ForEach-Object { if ($_.name -match '^m(\d+)') { [int]$Matches[1] } })
            $start = if ($nums.Count) { [int](($nums | Measure-Object -Maximum).Maximum) + 1 } else { 1 }
            # 前からある、名前の付いていないマイドンには、小分類の名前を付けておく
            $oldStems = @($rel.assets | Where-Object { $ImageExt -notcontains [IO.Path]::GetExtension($_.name).ToLower() } | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.name) } | Where-Object { $_ -notmatch '^m\d+' } | Select-Object -Unique)
            if ($oldStems.Count -eq 1 -and $baseBody -notmatch "(?m)^\s*名前\s+$([regex]::Escape($oldStems[0]))\s*[:：]") { $nameLines.Add("名前 $($oldStems[0]): $($rel.name)") }
        }

        $total = 0; foreach ($m in $script:mydons) { $total += $m.Images.Count + $m.Zips.Count }
        $progress.Maximum = [Math]::Max(1, $total); $progress.Value = 0
        $n = [int]$start
        $notify = New-Object System.Collections.Generic.List[object]
        $relSim = Get-BodySim $baseBody
        $norm = { param($t) (([string]$t).Normalize([Text.NormalizationForm]::FormKC) -replace '\s', '').ToLower() }
        foreach ($m in $script:mydons) {
            # 同じ名前のマイドンがもうこの小分類にある時は、そのマイドンに zip を足す（シミュレーター違いの版など）
            $same = @($existing | Where-Object { (& $norm $_.Name) -eq (& $norm $m.Name) }) | Select-Object -First 1
            if ($same) {
                $addLinks = @()
                $id = $same.Stem
                $k = @($same.Files).Count
                for ($i = 0; $i -lt $m.Zips.Count; $i++) {
                    $z = $m.Zips[$i]; $k++
                    $ext = [IO.Path]::GetExtension($z).ToLower(); if (-not $ext) { $ext = '.zip' }
                    $fname = "${id}_$k$ext"
                    $sim = [string]$m.Sims[$i]; if ($sim -and $sim -ne $relSim) { $nameLines.Add("シミュレーター ${id}_${k}: $sim") }
                    $lblStatus.Text = "「$($m.Name)」に zip を追加中… $fname（$(Format-Size (Get-Item $z).Length)）"
                    Send-Asset $rel.id $z $fname; $progress.Value++
                    $addLinks += (Get-DlUrl $rel $fname)
                }
                $progress.Value = [Math]::Min($progress.Maximum, $progress.Value + $m.Images.Count)
                $sims = @($m.Sims | Where-Object { $_ }) ; $what = if ($sims.Count) { ($sims -join '・') + ' 版を追加' } else { 'zip を追加' }
                $notify.Add([pscustomobject]@{ Name = $m.Name; Image = $(if ($m.Images.Count) { $m.Images[0] } else { $null }); Note = $what; Links = $addLinks })
                continue
            }
            $id = 'm{0:D2}' -f $n
            $nameLines.Add("名前 ${id}: $($m.Name)")
            $ent = [pscustomobject]@{ Name = $m.Name; Image = $(if ($m.Images.Count) { $m.Images[0] } else { $null }); Note = ''; Links = @() }
            $notify.Add($ent)
            $k = 0
            foreach ($im in $m.Images) {
                $k++; $ext = [IO.Path]::GetExtension($im).ToLower()
                $fname = if ($k -eq 1) { "$id$ext" } else { "${id}_$k$ext" }
                $lblStatus.Text = "「$($m.Name)」の画像をアップロード中… $fname（$(Format-Size (Get-Item $im).Length)）"
                Send-Asset $rel.id $im $fname; $progress.Value++
            }
            $k = 0
            foreach ($z in $m.Zips) {
                $k++; $ext = [IO.Path]::GetExtension($z).ToLower(); if (-not $ext) { $ext = '.zip' }
                $fname = if ($k -eq 1) { "$id$ext" } else { "${id}_$k$ext" }
                $sim = [string]$m.Sims[$k - 1]; if ($sim -and $sim -ne $relSim) { $nameLines.Add("シミュレーター $([IO.Path]::GetFileNameWithoutExtension($fname)): $sim") }
                $lblStatus.Text = "「$($m.Name)」の zip をアップロード中… $fname（$(Format-Size (Get-Item $z).Length)）"
                Send-Asset $rel.id $z $fname; $progress.Value++
                $ent.Links = @($ent.Links) + (Get-DlUrl $rel $fname)
            }
            $n++
        }

        $body = ($baseBody.TrimEnd() + "`n" + ($nameLines -join "`n"))
        if ($desc) { $body += "`n$desc" }
        $lblStatus.Text = '仕上げ中…'
        Invoke-Gh 'PATCH' "/releases/$($rel.id)" @{ body = $body; draft = $false } | Out-Null

        $lblStatus.Text = "投稿しました！（$($script:mydons.Count) 体）サイトを再読み込みすると出ます。"
        try {
            $relCat = ''; foreach ($line in ($body -split "`r?`n")) { if ($line -match '^\s*(カテゴリ|category)\s*[:：;；]\s*(.+?)\s*$') { $relCat = $Matches[2]; break } }
            $lblStatus.Text = 'Discord に知らせています…'
            if (Send-DiscordNotify ([string]$rel.name) $relCat ([bool]$rbNew.Checked) $notify) { $lblStatus.Text = "投稿しました！（$($notify.Count) 体）Discord にも知らせました。" }
            else { $lblStatus.Text = "投稿しました！（$($notify.Count) 体）※ Discord 通知は設定されていません。" }
        } catch {
            $lblStatus.Text = "投稿しました！（$($notify.Count) 体）※ Discord には知らせられませんでした。"
            (Show-Msg ("投稿はできましたが、Discord に知らせられませんでした。`n`n$($_.Exception.Message)")) | Out-Null
        }
        $script:mydons.Clear(); Update-List
        if ($rbNew.Checked) { $txtTitle.Text = ''; $txtTags.Text = ''; $txtDesc.Text = '' }
        Load-Releases -Keep
    } catch {
        $lblStatus.Text = 'エラー：' + $_.Exception.Message
        (Show-Msg ("投稿できませんでした。`n`n$($_.Exception.Message)`n`n途中まで上がった分は、GitHub の Releases に「下書き（Draft）」として残っています。不要なら削除して下さい。")) | Out-Null
    } finally {
        $btnPost.Enabled = $true
    }
})

Update-TokenLabel
Update-Mode
$form.Add_Shown({ Load-Releases })
[void]$form.ShowDialog()
