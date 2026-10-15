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

function Wait-Task($task) {
    while (-not $task.IsCompleted) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 40 }
    return $task.GetAwaiter().GetResult()
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
    $src = Wait-Task ($res.Content.ReadAsStreamAsync())
    $fs = [IO.File]::Create($path)
    try { Wait-Task ($src.CopyToAsync($fs)) | Out-Null } finally { $fs.Dispose(); $src.Dispose() }
}

function Get-BodyNames([string]$body) {
    $map = @{}
    foreach ($line in ($body -split "`r?`n")) { if ($line -match '^\s*名前\s+(\S+?)\s*[:：]\s*(.+?)\s*$') { $map[$Matches[1].ToLower()] = $Matches[2] } }
    return $map
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
        return @([pscustomobject]@{ Stem = ''; Name = [string]$rel.name; Images = $imgs; Files = $others })
    }
    foreach ($g in $list) {
        if (-not $g.Images.Count) { $g.Images = $loose }
        if ($names.ContainsKey($g.Stem)) { $g.Name = $names[$g.Stem] }
        else { $g.Name = ($g.Name -replace '[_\-\s]*\d+\s*fps$', '') }
    }
    if ($list.Count -eq 1 -and -not $names.ContainsKey($list[0].Stem)) { $list[0].Name = [string]$rel.name }
    return $list
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
        foreach ($j in $jobs) {
            $id = 'm{0:D2}' -f $n; $n++
            $nameLines.Add("名前 ${id}: $($j.Item.Name)")
            $k = 0
            foreach ($a in @($j.Item.Images) + @($j.Item.Files)) {
                $isImg = $ImageExt -contains [IO.Path]::GetExtension($a.name).ToLower()
                if ($isImg) { $k++ }
                $ext = [IO.Path]::GetExtension($a.name).ToLower(); if (-not $ext) { $ext = '.zip' }
                $idx = if ($isImg) { $k } else { [array]::IndexOf(@($j.Item.Files), $a) + 1 }
                $fname = if ($idx -le 1) { "$id$ext" } else { "${id}_$idx$ext" }
                $local = Join-Path $tmp ([guid]::NewGuid().ToString('N') + $ext)
                $lblStatus.Text = "「$($j.Item.Name)」をダウンロード中… $($a.name)（$(Format-Size $a.size)）"
                Save-AssetTo $a $local; $progress.Value++
                $lblStatus.Text = "「$($j.Item.Name)」をアップロード中… $fname"
                Send-Asset $target.id $local $fname; $progress.Value++
                Remove-Item $local -Force -ErrorAction SilentlyContinue
                if ($j.FromTarget) { $replaced.Add($a) }
            }
        }

        # 本文：まとめ先の内容（カテゴリやタグなど）を残し、名前の行を付け直す
        $keep = if ($targetIsTool) { [string]$target.body } else { (@(([string]$target.body) -split "`r?`n") | Where-Object { $_ -notmatch '^\s*名前\s+\S+\s*[:：]' }) -join "`n" }
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
    if (-not $script:token) { [System.Windows.Forms.MessageBox]::Show('先に「トークン設定」をして下さい。', 'マイドンラボ') | Out-Null; return }
    if ($script:releases.Count -lt 2) { [System.Windows.Forms.MessageBox]::Show('まとめられる小分類が2つ以上ありません。↻ で読み込み直して下さい。', 'マイドンラボ') | Out-Null; return }
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
        if ($clb.CheckedIndices.Count -lt 2) { [System.Windows.Forms.MessageBox]::Show('2つ以上チェックして下さい。', 'マイドンラボ') | Out-Null; return }
        if (-not $tTitle.Text.Trim()) { [System.Windows.Forms.MessageBox]::Show('まとめた後の名前を入れて下さい。', 'マイドンラボ') | Out-Null; return }
        $d.DialogResult = 'OK'; $d.Close()
    })
    if ($d.ShowDialog($form) -ne 'OK') { return }
    $sel = @($clb.CheckedIndices | ForEach-Object { $script:releases[$_] })
    $btnPost.Enabled = $false; $btnMerge.Enabled = $false
    try {
        $count = Invoke-Merge $sel $tTitle.Text.Trim() $cCat.Text.Trim() $chk.Checked
        $lblStatus.Text = "まとめました！「$($tTitle.Text.Trim())」に $count 体を入れました。サイトを再読み込みすると出ます。"
        Load-Releases
    } catch {
        $lblStatus.Text = 'エラー：' + $_.Exception.Message
        [System.Windows.Forms.MessageBox]::Show("まとめる途中で止まりました。`n`n$($_.Exception.Message)`n`n元の小分類はまだ消していません。まとめ先に途中まで上がったファイルがあれば、GitHub で削除して下さい。", 'マイドンラボ') | Out-Null
    } finally { $btnPost.Enabled = $true; $btnMerge.Enabled = $true }
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
    $src = Wait-Task ($res.Content.ReadAsStreamAsync())
    $fs = [IO.File]::Create($path)
    try { Wait-Task ($src.CopyToAsync($fs, 1048576)) | Out-Null } finally { $fs.Dispose(); $src.Dispose() }
    return $path
}

function Get-Http([string]$url, [string]$referer) {
    $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Get, $url)
    if ($referer) { $req.Headers.Referrer = [Uri]$referer }
    $res = Wait-Task ($script:gfHttp.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead))
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
    $pngs = @($zip.Entries | Where-Object { ($_.FullName -replace '\\', '/').StartsWith($pre) -and $_.Name -match '\.(png|gif)$' })
    if (-not $pngs.Count) { return $null }
    $pick = @($pngs | Where-Object { ($_.FullName -replace '\\', '/') -match '/normal/' } | Sort-Object { [int](($_.Name -replace '\D', '') + '0') } , Name)
    $e = if ($pick.Count) { $pick[0] } else { $pngs[0] }
    $out = Join-Path $dir ([guid]::NewGuid().ToString('N') + [IO.Path]::GetExtension($e.Name))
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $out, $true)
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
                    $ne = $za.CreateEntry($full, [System.IO.Compression.CompressionLevel]::Optimal)
                    $ne.LastWriteTime = $e.LastWriteTime
                    if ($full.EndsWith('/')) { continue }
                    $src = $e.Open(); $dst = $ne.Open()
                    try { $src.CopyTo($dst) } finally { $dst.Dispose(); $src.Dispose() }
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
    $okCount = 0
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
            foreach ($row in $g.Group) {
                $link = $row.'リンク'.Trim()
                $work = Join-Path $tmp ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $work | Out-Null
                try {
                    $lblStatus.Text = "ダウンロード中… $link"
                    $files = @(Get-LinkFiles $link $work)
                    $thumbs = @(([string]$row.'サムネ') -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and (Test-Path $_) })
                    $items = @()
                    foreach ($f in $files) { $items += Split-Download $f $work $thumbs }
                    if ($row.'名前' -and $items.Count -eq 1) { $items[0].Name = $row.'名前'.Trim() }
                    foreach ($it in $items) {
                        $id = 'm{0:D2}' -f $n; $n++
                        $k = 0
                        foreach ($t in $it.Thumbs) {
                            $k++; $ext = [IO.Path]::GetExtension($t).ToLower()
                            $lblStatus.Text = "「$($it.Name)」の画像をアップロード中…"
                            Send-Asset $rel.id $t $(if ($k -eq 1) { "$id$ext" } else { "${id}_$k$ext" })
                        }
                        $ext = [IO.Path]::GetExtension($it.Zip).ToLower(); if (-not $ext) { $ext = '.zip' }
                        $lblStatus.Text = "「$($it.Name)」をアップロード中…（$(Format-Size (Get-Item $it.Zip).Length)）"
                        Send-Asset $rel.id $it.Zip "$id$ext"
                        $nameLines.Add("名前 ${id}: $($it.Name)")
                        $okCount++
                        $log.Add("○ $($it.Name)" + $(if ($it.Note) { "（$($it.Note)）" } else { '' }))
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
            } elseif ($rel.draft) {
                Invoke-Gh 'DELETE' "/releases/$($rel.id)" $null | Out-Null
            }
        }
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
    $logPath = Join-Path ([IO.Path]::GetDirectoryName($csvPath)) ('一括投稿の結果_' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
    [IO.File]::WriteAllLines($logPath, $log, [Text.Encoding]::UTF8)
    return [pscustomobject]@{ Ok = $okCount; Fail = @($log | Where-Object { $_.StartsWith('×') }).Count; Log = $logPath }
}

function Start-Batch {
    if (-not $script:token) { [System.Windows.Forms.MessageBox]::Show('先に「トークン設定」をして下さい。', 'マイドンラボ') | Out-Null; return }
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = '一括投稿の一覧ファイル（CSV）を選んで下さい'
    $dlg.Filter = 'CSV (*.csv)|*.csv'
    if ($dlg.ShowDialog() -ne 'OK') { return }
    $count = @(Import-Csv -Path $dlg.FileName -Encoding UTF8 | Where-Object { $_.'リンク' }).Count
    $ans = [System.Windows.Forms.MessageBox]::Show("$count 件のリンクを、ダウンロードして投稿します。`n時間がかかるので、終わるまでツールを閉じないで下さい。`n`n始めますか？", 'マイドンラボ', 'YesNo')
    if ($ans -ne 'Yes') { return }
    $btnPost.Enabled = $false; $btnMerge.Enabled = $false; $btnBatch.Enabled = $false
    try {
        if (-not $script:releases.Count) { Load-Releases }
        $r = Invoke-Batch $dlg.FileName
        $lblStatus.Text = "一括投稿が終わりました：成功 $($r.Ok) 体 / 失敗 $($r.Fail) 件"
        [System.Windows.Forms.MessageBox]::Show("終わりました！`n成功：$($r.Ok) 体`n失敗：$($r.Fail) 件`n`n結果はこのファイルにまとめました：`n$($r.Log)", 'マイドンラボ') | Out-Null
        Load-Releases
    } catch {
        $lblStatus.Text = 'エラー：' + $_.Exception.Message
        [System.Windows.Forms.MessageBox]::Show("止まりました。`n`n$($_.Exception.Message)", 'マイドンラボ') | Out-Null
    } finally { $btnPost.Enabled = $true; $btnMerge.Enabled = $true; $btnBatch.Enabled = $true }
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
$lblToken = Add-Label '' 16 12 296
$btnToken = Add-Control (New-Object System.Windows.Forms.Button) 470 10 134 28
$btnToken.Text = 'トークン設定'

# 投稿先
$rbNew = Add-Control (New-Object System.Windows.Forms.RadioButton) 16 48 190
$rbNew.Text = '新しい小分類を作る'; $rbNew.Checked = $true
$rbAdd = Add-Control (New-Object System.Windows.Forms.RadioButton) 214 48 190
$rbAdd.Text = '今ある小分類に追加'
$cbExisting = Add-Control (New-Object System.Windows.Forms.ComboBox) 16 80 540
$cbExisting.DropDownStyle = 'DropDownList'; $cbExisting.Enabled = $false
$btnReload = Add-Control (New-Object System.Windows.Forms.Button) 562 79 42 28
$btnReload.Text = '↻'
$btnMerge = Add-Control (New-Object System.Windows.Forms.Button) 430 45 174 28
$btnBatch = Add-Control (New-Object System.Windows.Forms.Button) 316 10 148 28
$btnBatch.Text = '一括投稿（一覧）…'
$btnMerge.Text = '小分類をまとめる…'

# 項目
$y = 124
Add-Label '大分類' 16 $y | Out-Null
$cbCat = Add-Control (New-Object System.Windows.Forms.ComboBox) 130 $y 474
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
    if ($script:token) { $lblToken.Text = "✓ トークン設定済み（$Repo）"; $lblToken.ForeColor = [System.Drawing.Color]::DarkGreen }
    elseif ($script:tokenError) { $lblToken.Text = "保存したトークンを読めませんでした：$script:tokenError"; $lblToken.ForeColor = [System.Drawing.Color]::Firebrick }
    else { $lblToken.Text = 'まず「トークン設定」をして下さい'; $lblToken.ForeColor = [System.Drawing.Color]::Firebrick }
}
function Update-List {
    $list.BeginUpdate(); $list.Items.Clear()
    foreach ($m in $script:mydons) {
        $it = New-Object System.Windows.Forms.ListViewItem ($m.Name)
        [void]$it.SubItems.Add((($m.Images | ForEach-Object { [IO.Path]::GetFileName($_) }) -join ', '))
        [void]$it.SubItems.Add((($m.Zips | ForEach-Object { '{0} ({1})' -f [IO.Path]::GetFileName($_), (Format-Size (Get-Item $_).Length) }) -join ', '))
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
    [void]$script:mydons.Add([pscustomobject]@{ Name = $name; Images = @($images); Zips = @($zips) })
    Update-List
}

function Load-Releases {
    if (-not $script:token) { return }
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
        $lblStatus.Text = "小分類 $($script:releases.Count) 件を読み込みました"
    } catch { $lblStatus.Text = $_.Exception.Message }
}

# ---------- 操作 ----------
$btnToken.Add_Click({
    $msg = "GitHub のトークンを貼り付けて下さい。`n（Fine-grained token／リポジトリ $Repo／Contents: Read and write）`n`nこのPCの、このユーザーだけが読める形で保存されます。"
    $t = [Microsoft.VisualBasic.Interaction]::InputBox($msg, 'トークン設定', '')
    if ($t.Trim()) {
        try { Save-Token $t.Trim() } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'マイドンラボ') | Out-Null }
        $script:token = $t.Trim(); Update-TokenLabel; Load-Releases
    }
})
$rbNew.Add_CheckedChanged({ Update-Mode })
$rbAdd.Add_CheckedChanged({ Update-Mode })
$btnReload.Add_Click({ Load-Releases })
$btnMerge.Add_Click({ Show-MergeDialog })
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
    if (-not $suggest) { $suggest = [IO.Path]::GetFileNameWithoutExtension($dlg2.FileNames[0]) }
    Add-Mydon (Ask-Name $suggest) $imgs $dlg2.FileNames
})
$list.Add_DragEnter({ if ($_.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) { $_.Effect = 'Copy' } })
$list.Add_DragDrop({
    $files = @($_.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop))
    $imgs = @($files | Where-Object { $ImageExt -contains [IO.Path]::GetExtension($_).ToLower() })
    $zips = @($files | Where-Object { $ImageExt -notcontains [IO.Path]::GetExtension($_).ToLower() })
    if (-not $zips.Count) { [System.Windows.Forms.MessageBox]::Show('zip が入っていません。画像と zip を一緒にドロップして下さい。', 'マイドンラボ') | Out-Null; return }
    # 同じ名前の画像と zip をペアにする。ペアにならない時は全部で1体
    $groups = [ordered]@{}
    foreach ($z in $zips) { $k = [IO.Path]::GetFileNameWithoutExtension($z).ToLower(); if (-not $groups.Contains($k)) { $groups[$k] = @{ Name = [IO.Path]::GetFileNameWithoutExtension($z); Images = @(); Zips = @() } }; $groups[$k].Zips += $z }
    $loose = @()
    foreach ($im in $imgs) { $k = ([IO.Path]::GetFileNameWithoutExtension($im).ToLower() -replace '[_\-\s]\d+$', ''); if ($groups.Contains($k)) { $groups[$k].Images += $im } else { $loose += $im } }
    $paired = @($groups.Values | Where-Object { $_.Images.Count })
    if ($groups.Count -eq 1 -or -not $paired.Count) {
        $suggest = Get-DefaultName; if (-not $suggest) { $suggest = @($groups.Values)[0].Name }
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

$btnPost.Add_Click({
    if (-not $script:token) { [System.Windows.Forms.MessageBox]::Show('先に「トークン設定」をして下さい。', 'マイドンラボ') | Out-Null; return }
    if (-not $script:mydons.Count) { [System.Windows.Forms.MessageBox]::Show('マイドンを1体以上追加して下さい。', 'マイドンラボ') | Out-Null; return }
    if ($rbNew.Checked -and -not $txtTitle.Text.Trim()) { [System.Windows.Forms.MessageBox]::Show('小分類の名前を入れて下さい。', 'マイドンラボ') | Out-Null; return }
    if ($rbAdd.Checked -and $cbExisting.SelectedIndex -lt 0) { [System.Windows.Forms.MessageBox]::Show('追加する小分類を選んで下さい。', 'マイドンラボ') | Out-Null; return }
    $noImg = @($script:mydons | Where-Object { -not $_.Images.Count })
    if ($noImg.Count) {
        $ans = [System.Windows.Forms.MessageBox]::Show("画像のないマイドンがあります（$($noImg[0].Name) など）。このまま投稿しますか？", 'マイドンラボ', 'YesNo')
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
        } else {
            $rel = $script:releases[$cbExisting.SelectedIndex]
            $rel = Invoke-Gh 'GET' "/releases/$($rel.id)" $null
            $baseBody = [string]$rel.body
            $desc = ''
            $nums = @($rel.assets | ForEach-Object { if ($_.name -match '^m(\d+)') { [int]$Matches[1] } })
            $start = if ($nums.Count) { [int](($nums | Measure-Object -Maximum).Maximum) + 1 } else { 1 }
            # 前からある、名前の付いていないマイドンには、小分類の名前を付けておく
            $oldStems = @($rel.assets | Where-Object { $ImageExt -notcontains [IO.Path]::GetExtension($_.name).ToLower() } | ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.name) } | Where-Object { $_ -notmatch '^m\d+' } | Select-Object -Unique)
            if ($oldStems.Count -eq 1 -and $baseBody -notmatch "(?m)^\s*名前\s+$([regex]::Escape($oldStems[0]))\s*[:：]") { $nameLines.Add("名前 $($oldStems[0]): $($rel.name)") }
        }

        $total = 0; foreach ($m in $script:mydons) { $total += $m.Images.Count + $m.Zips.Count }
        $progress.Maximum = [Math]::Max(1, $total); $progress.Value = 0
        $n = [int]$start
        foreach ($m in $script:mydons) {
            $id = 'm{0:D2}' -f $n
            $nameLines.Add("名前 ${id}: $($m.Name)")
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
                $lblStatus.Text = "「$($m.Name)」の zip をアップロード中… $fname（$(Format-Size (Get-Item $z).Length)）"
                Send-Asset $rel.id $z $fname; $progress.Value++
            }
            $n++
        }

        $body = ($baseBody.TrimEnd() + "`n" + ($nameLines -join "`n"))
        if ($desc) { $body += "`n$desc" }
        $lblStatus.Text = '仕上げ中…'
        Invoke-Gh 'PATCH' "/releases/$($rel.id)" @{ body = $body; draft = $false } | Out-Null

        $lblStatus.Text = "投稿しました！（$($script:mydons.Count) 体）サイトを再読み込みすると出ます。"
        $script:mydons.Clear(); Update-List
        if ($rbNew.Checked) { $txtTitle.Text = ''; $txtTags.Text = ''; $txtDesc.Text = '' }
        Load-Releases
    } catch {
        $lblStatus.Text = 'エラー：' + $_.Exception.Message
        [System.Windows.Forms.MessageBox]::Show("投稿できませんでした。`n`n$($_.Exception.Message)`n`n途中まで上がった分は、GitHub の Releases に「下書き（Draft）」として残っています。不要なら削除して下さい。", 'マイドンラボ') | Out-Null
    } finally {
        $btnPost.Enabled = $true
    }
})

Update-TokenLabel
Update-Mode
$form.Add_Shown({ Load-Releases })
[void]$form.ShowDialog()
