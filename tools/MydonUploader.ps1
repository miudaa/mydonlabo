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
[System.Windows.Forms.Application]::EnableVisualStyles()
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ConfDir   = Join-Path $env:APPDATA 'MydonLabo'
$TokenFile = Join-Path $ConfDir 'token.txt'
$ImageExt  = @('.png', '.gif', '.jpg', '.jpeg', '.webp')

# ---------- トークン（このPCのこのユーザーだけが読める形で保存） ----------
function Get-Token {
    if (-not (Test-Path $TokenFile)) { return $null }
    try {
        $sec = Get-Content $TokenFile -Raw | ConvertTo-SecureString
        $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    } catch { return $null }
}
function Save-Token([string]$t) {
    New-Item -ItemType Directory -Force -Path $ConfDir | Out-Null
    ConvertTo-SecureString $t -AsPlainText -Force | ConvertFrom-SecureString | Set-Content -Path $TokenFile
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
$lblToken = Add-Label '' 16 12 420
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
    if ($script:token) { $lblToken.Text = "投稿先：$Owner/$Repo（トークン設定済み）"; $lblToken.ForeColor = [System.Drawing.Color]::DarkGreen }
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
    if ($t.Trim()) { Save-Token $t.Trim(); $script:token = $t.Trim(); Update-TokenLabel; Load-Releases }
})
$rbNew.Add_CheckedChanged({ Update-Mode })
$rbAdd.Add_CheckedChanged({ Update-Mode })
$btnReload.Add_Click({ Load-Releases })

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
