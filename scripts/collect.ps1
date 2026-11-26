# 静岡県のコンペ・入札案件を収集して docs/data.json と docs/feed.xml を更新する
# Windows PowerShell 5.1 / PowerShell 7 (GitHub Actions) の両方で動作
param(
    [string]$Root = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
$Jst = [TimeZoneInfo]::CreateCustomTimeZone('JST', [TimeSpan]::FromHours(9), 'JST', 'JST')
$Now = [TimeZoneInfo]::ConvertTime([DateTimeOffset]::UtcNow, $Jst)
$Today = $Now.ToString('yyyy-MM-dd')

$config = Get-Content -Raw -Encoding UTF8 (Join-Path $Root 'config.json') | ConvertFrom-Json
$dataPath = Join-Path $Root 'docs/data.json'

# ---------- helpers ----------
function Get-Html([string]$Url) {
    for ($i = 1; $i -le 3; $i++) {
        try {
            $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 60 -UserAgent 'shizuoka-bid-watch/1.0'
            return [System.Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
        } catch {
            if ($i -eq 3) { throw }
            Start-Sleep -Seconds (3 * $i)
        }
    }
}

function ConvertTo-Norm([string]$s) {
    if (-not $s) { return '' }
    return $s.Normalize([Text.NormalizationForm]::FormKC)
}

function ConvertFrom-Html([string]$html) {
    $t = [regex]::Replace($html, '(?is)<(script|style)[^>]*>.*?</\1>', ' ')
    $t = [regex]::Replace($t, '(?i)<br\s*/?>|</p>|</li>|</h\d>|</tr>', "`n")
    $t = [regex]::Replace($t, '<[^>]+>', ' ')
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    $t = [regex]::Replace($t, '[ \t　]+', ' ')
    $t = [regex]::Replace($t, '\s*\n\s*', "`n")
    return $t.Trim()
}

function Test-Keyword([string]$text, [string]$kw) {
    if ($kw -match '^[A-Za-z]+$') {
        return [regex]::IsMatch($text, "(?<![A-Za-z])$([regex]::Escape($kw))(?![A-Za-z])")
    }
    return $text.Contains($kw)
}

function Get-Tags([string]$text, [string]$title = '') {
    $t = ConvertTo-Norm $text
    # 案件名に「工事」などを含むものは対象外(本文に出てくるだけなら除外しない)
    $tt = ConvertTo-Norm $(if ($title) { $title } else { $text })
    foreach ($ex in $config.excludeTitleKeywords) { if (Test-Keyword $tt $ex) { return @() } }
    # 公告文の定型句(電子入札・ホームページに掲載 など)やサイトのメニュー文言で分野が誤判定されないよう除去
    $t = [regex]::Replace($t, '電子入札ポータル(サイト)?|電子(入札|調達|申請|契約|メール|データ|納品|媒体)(システム)?|入札(情報)?(公開)?システム|(ホームページ|ウェブサイト|Webサイト|サイト)(に|で|から|より|上|へ|を|等)|サイト(内検索|マップ|ポリシー|について|の使い方|ナビ)|このサイト|公式SNS|SNS(一覧|アカウント|で共有|でシェア)|PDF|(?<![A-Za-z])KB(?![A-Za-z])', ' ')
    foreach ($ex in $config.excludeKeywords) { if (Test-Keyword $t $ex) { return @() } }
    $tags = @()
    foreach ($tag in $config.tags) {
        foreach ($kw in $tag.keywords) {
            if (Test-Keyword $t (ConvertTo-Norm $kw)) { $tags += $tag.name; break }
        }
    }
    return $tags
}

function Test-Proposal([string]$text) {
    $t = ConvertTo-Norm $text
    foreach ($kw in $config.proposalKeywords) { if ($t.Contains($kw)) { return $true } }
    return $false
}

# 「提出期限」等の近くにある日付を締切目安として推定する(確実でない場合は空)
function Get-Deadline([string]$text, [string]$published) {
    $t = ConvertTo-Norm $text
    if (-not $t) { return '' }
    $base = [datetime]::ParseExact($(if ($published) { $published } else { $Today }), 'yyyy-MM-dd', $null)
    $kwRe = '(提出期限|提出期間|提出締切|締切|締め切り|受付期間|応募期限|応募期間|申込期限|参加申込|参加申し込み|参加表明|(企画)?提案書(等)?の提出|申請書(等)?の提出|応募書類(等)?の提出)'
    $dateRe = '(?:(令和|R)\s*(\d{1,2})\s*年\s*|(20\d{2})\s*年\s*|(20\d{2})[/.])?(\d{1,2})\s*[月/.]\s*(\d{1,2})\s*日?'
    foreach ($m in [regex]::Matches($t, $kwRe)) {
        # 「成果物の提出期限」「実績報告書の提出」など、契約後の期限は締切ではない
        $pre = $t.Substring([Math]::Max(0, $m.Index - 20), [Math]::Min(20, $m.Index))
        if ($pre -match '成果物|報告書|実績|請求|完了|納品|検査|履行|納入|精算|変更') { continue }
        $start = $m.Index + $m.Length
        $win = $t.Substring($start, [Math]::Min(140, $t.Length - $start))
        $cut = $win.IndexOf('。'); if ($cut -gt 0) { $win = $win.Substring(0, $cut) }
        $dates = @([regex]::Matches($win, $dateRe))
        if ($dates.Count -eq 0) { continue }
        $pick = $null
        foreach ($d in $dates) {
            $after = $win.Substring($d.Index + $d.Length, [Math]::Min(25, $win.Length - $d.Index - $d.Length))
            if ($after -match '^[^月]{0,22}(まで|必着|締切|厳守)') { $pick = $d; break }
        }
        if (-not $pick -and $dates.Count -eq 1) { $pick = $dates[0] }
        if (-not $pick) { continue }
        $g = $pick.Groups
        $mon = [int]$g[5].Value; $day = [int]$g[6].Value
        if ($mon -lt 1 -or $mon -gt 12 -or $day -lt 1 -or $day -gt 31) { continue }
        if ($g[2].Success) { $year = 2018 + [int]$g[2].Value }
        elseif ($g[3].Success) { $year = [int]$g[3].Value }
        elseif ($g[4].Success) { $year = [int]$g[4].Value }
        else { $year = $base.Year; if ($mon -lt $base.Month - 1) { $year++ } }
        try { $dt = New-Object DateTime $year, $mon, $day } catch { continue }
        # 公募の締切は通常、公告から5か月以内
        if ($dt -lt $base.AddDays(-1) -or $dt -gt $base.AddDays(150)) { continue }
        return $dt.ToString('yyyy-MM-dd')
    }
    return ''
}

function Get-NormTitle([string]$s) {
    return ([regex]::Replace((ConvertTo-Norm $s), '[\s()（）「」『』【】・、。]|について|に係る|にかかる|の募集|募集', ''))
}

function Get-Summary([string]$s, [int]$len = 220) {
    $s = ([regex]::Replace((ConvertTo-Norm $s), '\s+', ' ')).Trim()
    if ($s.Length -gt $len) { return $s.Substring(0, $len) + '…' }
    return $s
}

# ---------- 既存データ読み込み ----------
$items = @{}
if (Test-Path $dataPath) {
    $old = Get-Content -Raw -Encoding UTF8 $dataPath | ConvertFrom-Json
    foreach ($it in $old.items) { $items[$it.id] = $it }
}
$cutoff = $Now.AddDays(-[int]$config.keepDays).ToString('yyyy-MM-dd')
$errors = @()
# 一度取得した案件ID(期限切れで削除した案件を再取得・再通知しないために保持)
$seenIds = @{}
if ($old -and $old.seen) { foreach ($p in $old.seen.PSObject.Properties) { $seenIds[$p.Name] = $p.Value } }
foreach ($k in $items.Keys) { if (-not $seenIds.ContainsKey($k)) { $seenIds[$k] = $Today } }
$oldIds = @{}; foreach ($k in $seenIds.Keys) { $oldIds[$k] = 1 }
$closedRe = '募集終了|受付終了|終了しました|【終了】|結果|事業者決定|受託者決定|決定しました|決定について|選定しました|中止|締め切りました|締切りました'

function Add-Item($obj) {
    # 期限切れ等で削除済みの案件は再登録しない
    if (-not $script:items.ContainsKey($obj.id) -and $script:seenIds.ContainsKey($obj.id)) { return }
    if ($script:items.ContainsKey($obj.id)) {
        $prev = $script:items[$obj.id]
        $obj.firstSeen = $prev.firstSeen
        # PDFなどから読み取り済みの情報は引き継ぐ
        if ($prev.PSObject.Properties['enriched'] -and $prev.enriched) {
            foreach ($n in 'budget', 'budgetLabel', 'region', 'qual', 'enriched') { Set-Prop $obj $n $prev.$n }
            if (-not $obj.deadline -and $prev.deadline) { $obj.deadline = $prev.deadline }
            if ($prev.summary -and $prev.summary.Length -gt $obj.summary.Length) { $obj.summary = $prev.summary }
        }
    }
    $script:items[$obj.id] = $obj
}

function Set-Prop($o, [string]$n, $v) {
    if ($o.PSObject.Properties[$n]) { $o.$n = $v } else { $o | Add-Member -NotePropertyName $n -NotePropertyValue $v }
}

# 予算上限額・地域要件・参加資格の読み取り
function Get-Extra([string]$text) {
    $t = [regex]::Replace((ConvertTo-Norm $text), '\s+', ' ')
    $budget = [int64]0; $blabel = ''
    $bm = [regex]::Match($t, '(委託限度額|委託上限額|提案上限額|提案限度額|上限提案金額|提案上限金額|契約上限額|上限金額|上限額|限度額|上限価格|予定価格|委託料の上限|事業費の上限|費用の上限|予算額|見積上限額)[^0-9。]{0,30}?([0-9][0-9,]*(?:\.[0-9]+)?)\s*(千円|万円|円)')
    if ($bm.Success) {
        $n = [double]($bm.Groups[2].Value -replace ',', '')
        switch ($bm.Groups[3].Value) { '千円' { $n *= 1000 } '万円' { $n *= 10000 } }
        if ($n -ge 10000 -and $n -lt 1e11) { $budget = [int64]$n; $blabel = $bm.Groups[1].Value }
    }
    $region = ''
    $rm = [regex]::Match($t, '((静岡)?県内|[^\s、。,()「」]{1,6}市内|[^\s、。,()「」]{1,6}町内|市内|町内)に(本店|本社|主たる営業所|主たる事務所|本店又は支店|本店又は営業所|本店若しくは支店|支店|営業所|事業所|事務所)')
    if ($rm.Success) { $region = $rm.Value }
    $qual = [bool]($t -match '入札参加資格[^。]{0,30}(名簿に登録|登録され|認定を受け|を有する|を受けて)')
    return [pscustomobject]@{ budget = $budget; budgetLabel = $blabel; region = $region; qual = $qual }
}

function Get-PdfLinks([string]$html, [string]$base, [string]$pat) {
    $out = @()
    foreach ($m in [regex]::Matches($html, '<a[^>]+href="([^"]+\.pdf)"[^>]*>(.*?)</a>')) {
        $lt = ConvertTo-Norm ([regex]::Replace($m.Groups[2].Value, '<[^>]+>', ''))
        if ($lt -match $pat) {
            try { $out += ([Uri]::new([Uri]$base, [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value))).AbsoluteUri } catch {}
        }
    }
    return @($out | Select-Object -Unique)
}
$noticePdfRe = '実施要領|募集要領|要領|要項|公告|仕様書|説明書|募集'

# 案件ページの本文と公告PDF(GitHub上でのみ)から、締切・予算・要件を補う
function Update-ItemDetail($it, [string]$text, [string]$html) {
    $pdfText = ''
    if ($script:pdftotext) {
        if ($it.url -match '\.pdf($|\?)') { $pdfText = Get-PdfText $it.url }
        elseif ($html) {
            foreach ($pu in (Get-PdfLinks $html $it.url $noticePdfRe | Select-Object -First 2)) { $pdfText += "`n" + (Get-PdfText $pu) }
        }
    }
    $ex = Get-Extra "$text`n$pdfText"
    Set-Prop $it 'budget' $ex.budget
    Set-Prop $it 'budgetLabel' $ex.budgetLabel
    Set-Prop $it 'region' $ex.region
    Set-Prop $it 'qual' $ex.qual
    if ($pdfText.Trim()) {
        if (-not $it.deadline) { $dl = Get-Deadline $pdfText $it.published; if ($dl) { $it.deadline = $dl } }
        if (-not $it.summary -or $it.summary.Length -lt 60) { $it.summary = Get-Summary $pdfText }
        if (-not $it.proposal) { $it.proposal = (Test-Proposal $pdfText.Substring(0, [Math]::Min(1500, $pdfText.Length))) }
    }
    Set-Prop $it 'enriched' ([bool]$script:pdftotext)
}

# ---------- 結果(落札者・選定事業者)の記録用 ----------
$resultsPath = Join-Path $Root 'docs/results.json'
$resultMap = @{}    # id -> 結果レコード
$watch = @{}        # id -> 結果待ちの案件(ページを定期的に確認)
$resultChecked = @{} # id -> 監視に入れた日(二重登録防止)
if (Test-Path $resultsPath) {
    $ro = Get-Content -Raw -Encoding UTF8 $resultsPath | ConvertFrom-Json
    foreach ($r in @($ro.results)) { if ($r) { $resultMap[$r.id] = $r } }
    foreach ($w in @($ro.watch)) { if ($w) { $watch[$w.id] = $w } }
    if ($ro.checked) { foreach ($p in $ro.checked.PSObject.Properties) { $resultChecked[$p.Name] = $p.Value } }
}

function Add-Watch([string]$id, [string]$url, [string]$title, [string]$org, [string]$source, $tags, [bool]$proposal) {
    # 対象分野の案件だけ、結果の公表を見張る
    if (@($tags).Count -eq 0 -or -not $url -or $url -match '\.pdf$') { return }
    if ($script:resultMap.ContainsKey($id) -or $script:watch.ContainsKey($id) -or $script:resultChecked.ContainsKey($id)) { return }
    $script:resultChecked[$id] = $Today
    $script:watch[$id] = [pscustomobject][ordered]@{
        id = $id; url = $url; title = $title; org = $org; source = $source
        tags = @($tags); proposal = $proposal; since = $Today; lastCheck = ''
    }
}

$orgNameRe = '(?:(?:株式会社|有限会社|合同会社|合資会社|一般社団法人|公益社団法人|一般財団法人|公益財団法人|特定非営利活動法人|NPO法人|社会福祉法人|学校法人|医療法人|協同組合)\s*[^\s、。,，()（）「」『』:：/|]{1,30}|[^\s、。,，()（）「」『』:：/|]{1,30}?(?:株式会社|有限会社|合同会社|合資会社|共同企業体|\(株\)|\(有\)))'
$winnerLabels = @('優先交渉権者', '交渉権者', '契約候補者', '受託候補者', '受注候補者', '最優秀提案者', '最優秀者', '特定者', '落札者', '落札業者', '契約者の氏名', '契約者名', '契約の相手方', '契約相手方', '決定事業者', '選定事業者', '選定された事業者', '受注者', '受託者', '事業者名', '選定しました', '決定しました', '特定しました')

function Find-Result([string]$text) {
    $t = ConvertTo-Norm $text
    $t = [regex]::Replace($t, '\s+', ' ')
    $winner = ''
    foreach ($lb in $winnerLabels) {
        foreach ($m in [regex]::Matches($t, [regex]::Escape($lb))) {
            $win = $t.Substring($m.Index + $m.Length, [Math]::Min(80, $t.Length - $m.Index - $m.Length))
            $om = [regex]::Match($win, $orgNameRe)
            if ($om.Success) { $winner = $om.Value.Trim(); break }
        }
        if ($winner) { break }
    }
    if (-not $winner) { return $null }
    $score = ''
    $sm = [regex]::Match($t, '(\d{1,4}(?:\.\d+)?)\s*点?\s*[/／]\s*(\d{1,4})\s*点')
    if ($sm.Success) { $score = "$($sm.Groups[1].Value)/$($sm.Groups[2].Value)点" }
    $amount = ''
    $am = [regex]::Match($t, '(?:契約金額|落札金額|契約額|落札額|提案金額|見積金額|契約金)[^0-9]{0,15}([0-9][0-9,]{2,})\s*(千円|円)')
    if ($am.Success) { $amount = "$($am.Groups[1].Value)$($am.Groups[2].Value)" }
    return [pscustomobject]@{ winner = $winner; score = $score; amount = $amount }
}

$pdftotext = Get-Command pdftotext -ErrorAction SilentlyContinue
function Get-PdfText([string]$url) {
    if (-not $pdftotext) { return '' }
    $tmp = [IO.Path]::GetTempFileName()
    try {
        Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing -TimeoutSec 60 -UserAgent 'shizuoka-bid-watch/1.0'
        if ((Get-Item $tmp).Length -gt 8MB) { return '' }
        $out = & $pdftotext.Source -enc UTF-8 -q $tmp - 2>$null
        return ($out -join "`n")
    } catch { return '' } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

# ---------- 1. 官公需情報ポータルサイト API (静岡県内の県・市町・国の機関) ----------
try {
    $url = "https://www.kkj.go.jp/api/?LG_Code=$($config.kkj.lgCode)&Count=$($config.kkj.count)"
    [xml]$xml = Get-Html $url
    $results = $xml.SelectNodes('//SearchResult')
    Write-Host "kkj: $($results.Count) 件取得"
    foreach ($r in $results) {
        function Get-Node($name) { $n = $r.SelectSingleNode($name); if ($n) { $n.InnerText.Trim() } else { '' } }
        $cat = Get-Node 'Category'
        if ($config.kkj.excludeCategories -contains $cat) { continue }
        $title = ConvertTo-Norm (Get-Node 'ProjectName')
        $desc = Get-Node 'ProjectDescription'
        $tags = @(Get-Tags $title)
        if ($tags.Count -eq 0) { continue }
        $issue = Get-Node 'CftIssueDate'; if (-not $issue) { $issue = Get-Node 'Date' }
        $pub = ([DateTimeOffset]::Parse($issue)).ToString('yyyy-MM-dd')
        if ($pub -lt $cutoff) { continue }
        $org = Get-Node 'OrganizationName'
        $city = Get-Node 'CityName'
        $ex = Get-Extra $desc
        Add-Item ([pscustomobject][ordered]@{
            id        = 'kkj:' + (Get-Node 'Key')
            source    = '官公需ポータル'
            title     = $title
            org       = $(if ($org) { ConvertTo-Norm $org } else { '静岡県内の機関' })
            city      = $(if ($city) { $city } else { '' })
            kind      = $cat
            tags      = $tags
            proposal  = (Test-Proposal ($title + ' ' + $desc.Substring(0, [Math]::Min(400, $desc.Length))))
            url       = Get-Node 'ExternalDocumentURI'
            published = $pub
            deadline  = Get-Deadline $desc $pub
            summary   = Get-Summary $desc
            closed    = $false
            firstSeen = $Today
            budget    = $ex.budget
            budgetLabel = $ex.budgetLabel
            region    = $ex.region
            qual      = $ex.qual
            enriched  = $false
        })
    }
} catch {
    $errors += "官公需ポータルの取得に失敗: $($_.Exception.Message)"
    Write-Warning $errors[-1]
}

# ---------- 2. 静岡県公式サイト 部署別「入札・業務委託・プロポーザル等」 ----------
try {
    $indexUrl = $config.pref.indexUrl
    $indexHtml = Get-Html $indexUrl
    $listPages = @()
    $detailLinks = @()
    foreach ($m in [regex]::Matches($indexHtml, '<a[^>]+href="([^"]+)"[^>]*>\s*([^<]+?)\s*</a>')) {
        $href = ([Uri]::new([Uri]$indexUrl, $m.Groups[1].Value)).AbsoluteUri
        $text = $m.Groups[2].Value
        if ($text.Contains($config.pref.listTitlePattern) -and $href -match '/index\.html$') { $listPages += $href }
        elseif ($href -match '/kensei/nyusatsukobai/\d+\.html$') { $detailLinks += [pscustomobject]@{ url = $href; title = $text } }
    }
    $listPages = $listPages | Select-Object -Unique
    Write-Host "県HP: 部署別一覧 $($listPages.Count) ページ"
    foreach ($lp in $listPages) {
        try {
            $h = Get-Html $lp
            $s = $h.IndexOf('<h2'); if ($s -lt 0) { $s = 0 }
            $body = $h.Substring($s)
            $n = 0
            foreach ($m in [regex]::Matches($body, '<a[^>]+href="([^"]+/\d+\.html)"[^>]*>\s*([^<]+?)\s*</a>')) {
                $href = ([Uri]::new([Uri]$lp, $m.Groups[1].Value)).AbsoluteUri
                if ($href -notmatch '/kensei/nyusatsukobai/') { continue }
                $detailLinks += [pscustomobject]@{ url = $href; title = $m.Groups[2].Value }
                $n++; if ($n -ge [int]$config.pref.linksPerPage) { break }
            }
            Start-Sleep -Milliseconds 400
        } catch { $errors += "県HP一覧の取得に失敗: $lp"; Write-Warning $errors[-1] }
    }
    $seen = @{}
    foreach ($d in $detailLinks) {
        if ($seen.ContainsKey($d.url)) { continue }; $seen[$d.url] = 1
        $id = 'pref:' + ([regex]::Match($d.url, '(\d+)\.html$').Groups[1].Value)
        $title = ConvertTo-Norm ([System.Net.WebUtility]::HtmlDecode($d.title))
        $closed = [bool]($title -match $closedRe)
        if ($items.ContainsKey($id)) {
            # 既知の案件: 詳細は再取得せず、タイトル(募集終了表示など)と分野だけ更新
            $items[$id].title = $title
            $items[$id].closed = $closed
            $items[$id].tags = @(Get-Tags ($title + ' ' + $items[$id].summary) $title)
            continue
        }
        if ($closed -or $seenIds.ContainsKey($id)) {
            Add-Watch $id $d.url $title '静岡県' '静岡県HP' @(Get-Tags $title) (Test-Proposal $title)
            continue
        }
        try {
            $h = Get-Html $d.url
            Start-Sleep -Milliseconds 400
        } catch { $errors += "県HP詳細の取得に失敗: $($d.url)"; Write-Warning $errors[-1]; continue }
        $um = [regex]::Match($h, '更新日[^0-9]{0,40}?(\d{4})年(\d{1,2})月(\d{1,2})日')
        $pub = $(if ($um.Success) { '{0}-{1:00}-{2:00}' -f [int]$um.Groups[1].Value, [int]$um.Groups[2].Value, [int]$um.Groups[3].Value } else { $Today })
        if ($pub -lt $cutoff) { continue }
        $s = $h.IndexOf('<h1'); if ($s -lt 0) { $s = 0 }
        $e = $h.IndexOf('このページに関するお問い合わせ', $s); if ($e -lt 0) { $e = $h.Length }
        $text = ConvertFrom-Html $h.Substring($s, $e - $s)
        $text = [regex]::Replace($text, 'いいね[!！]|ページID\s*\d+|更新日\s*\d{4}年\d{1,2}月\d{1,2}日|大きな文字で印刷|印刷', ' ')
        $text = $text.Trim()
        $ht = ConvertTo-Norm $text
        if ($ht.StartsWith($title)) { $text = $ht.Substring($title.Length).Trim() }
        $om = [regex]::Match($h.Substring($e), '(?s)<p[^>]*>\s*(?:<strong>)?([^<]{2,40}?(?:部|局|課|室|委員会)[^<]{0,30})')
        $org = $(if ($om.Success) { ConvertTo-Norm $om.Groups[1].Value.Trim() } else { '静岡県' })
        $gi = $text.IndexOf('概要')
        $summarySrc = $(if ($gi -ge 0) { $text.Substring($gi + 2) } else { $text })
        $tags = @(Get-Tags ($title + ' ' + (Get-Summary $summarySrc 300)) $title)
        $obj = [pscustomobject][ordered]@{
            id        = $id
            source    = '静岡県HP'
            title     = $title
            org       = $(if ($org -notmatch '静岡県') { "静岡県 $org" } else { $org })
            city      = ''
            kind      = '役務'
            tags      = $tags
            proposal  = (Test-Proposal ($title + ' ' + $text))
            url       = $d.url
            published = $pub
            deadline  = Get-Deadline $text $pub
            summary   = Get-Summary $summarySrc
            closed    = $false
            firstSeen = $Today
        }
        if (@($tags).Count -gt 0) { Update-ItemDetail $obj $text $h }
        # 分野に該当しない県案件も一度取得したら再取得しないよう、tags 空で保持(表示はしない)
        $items[$id] = $obj
    }
} catch {
    $errors += "静岡県HPの取得に失敗: $($_.Exception.Message)"
    Write-Warning $errors[-1]
}

# ---------- 3. 市のサイト (静岡市・焼津市・藤枝市・富士市 など config.cities) ----------
function Read-DetailPage([string]$url, [string]$start = '<h1') {
    $h = Get-Html $url
    $dm = [regex]::Match($h, '(?:更新日|掲載日|公開日|公開開始日|作成日|登録日|公告日)[^0-9令]{0,40}?(?:(\d{4})年|令和\s*(\d{1,2})\s*年)\s*(\d{1,2})月\s*(\d{1,2})日')
    if (-not $dm.Success) {
        # 「2026年6月16日更新」「(令和8年6月17日掲載)」のように日付の後ろに書く形式
        $dm = [regex]::Match($h, '(?:(\d{4})年|令和\s*(\d{1,2})\s*年)\s*(\d{1,2})月\s*(\d{1,2})日\s*(?:更新|掲載|公開)')
    }
    $pub = $Today
    if ($dm.Success) {
        $y = $(if ($dm.Groups[1].Success) { [int]$dm.Groups[1].Value } else { 2018 + [int]$dm.Groups[2].Value })
        $pub = '{0}-{1:00}-{2:00}' -f $y, [int]$dm.Groups[3].Value, [int]$dm.Groups[4].Value
    }
    $s = $h.IndexOf($start); if ($s -lt 0) { $s = $h.IndexOf('<h1') }; if ($s -lt 0) { $s = 0 }
    $e = -1
    foreach ($mk in 'このページに関するお問い合わせ', 'このページに関するお問合せ', 'お問い合わせ先', 'id="footer"', 'class="footer') {
        $e = $h.IndexOf($mk, $s); if ($e -gt 0) { break }
    }
    if ($e -lt 0) { $e = $h.Length }
    $text = ConvertFrom-Html $h.Substring($s, $e - $s)
    $text = [regex]::Replace($text, 'いいね[!！]|ページID\s*[:：]?\s*\d+|(?:最終)?更新日\s*[:：]?\s*\S+日|大きな文字で印刷|印刷する|印刷', ' ').Trim()
    return [pscustomobject]@{ pub = $pub; text = $text; html = $h }
}

foreach ($c in $config.cities) {
    try {
        $links = @()
        $jsonPages = 0
        foreach ($lu in @($c.lists)) {
            if (-not $lu) { continue }
            try {
                $h = Get-Html $lu
                $s = $h.IndexOf($(if ($c.bodyStart) { $c.bodyStart } else { '<h1' })); if ($s -lt 0) { $s = 0 }
                $n = 0
                foreach ($m in [regex]::Matches($h.Substring($s), '<a[^>]+href="([^"]+)"[^>]*>(.*?)</a>')) {
                    $href = ([Uri]::new([Uri]$lu, [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value))).AbsoluteUri
                    if ($href -notmatch $c.linkPattern) { continue }
                    $t = ([regex]::Replace($m.Groups[2].Value, '<[^>]+>', '')).Trim()
                    if ($t.Length -lt 4) { continue }
                    if ($c.titlePattern -and $t -notmatch $c.titlePattern) { continue }
                    $links += [pscustomobject]@{ url = $href; title = $t }
                    $n++; if ($n -ge 100) { break }
                }
                Start-Sleep -Milliseconds 400
            } catch { $errors += "$($c.name)の一覧取得に失敗: $lu"; Write-Warning $errors[-1] }
        }
        if ($c.updateJson) {
            # 最近更新されたページ一覧(JSON)から、案件らしいページ名のものを拾う
            try {
                $j = (Get-Html $c.updateJson) | ConvertFrom-Json
                $jsonPages = @($j).Count
                foreach ($p in @($j)) { if ($p.page_name -match $c.updateNamePattern) { $links += [pscustomobject]@{ url = $p.url; title = $p.page_name } } }
            } catch { $errors += "$($c.name)の更新情報取得に失敗"; Write-Warning $errors[-1] }
        }
        # サイトの作り変えなどで1件も拾えなくなったら、一覧ページに警告を出す
        if (@($c.lists | Where-Object { $_ }).Count -gt 0 -and -not $c.allowEmpty -and -not $c.updateJson -and @($links).Count -eq 0) {
            $errors += "$($c.name)の一覧ページから案件を1件も取得できませんでした（サイト構成が変わった可能性があります）"
            Write-Warning $errors[-1]
        }
        if ($c.updateJson -and $jsonPages -eq 0) {
            $errors += "$($c.name)の更新情報を取得できませんでした（サイト構成が変わった可能性があります）"
            Write-Warning $errors[-1]
        }
        $uniq = @{}
        $cnt = 0
        foreach ($d in $links) {
            if ($uniq.ContainsKey($d.url)) { continue }; $uniq[$d.url] = 1
            $id = 'city:' + ($d.url -replace '^https?://(www\.)?', '')
            $title = ConvertTo-Norm ([System.Net.WebUtility]::HtmlDecode($d.title))
            $title = [regex]::Replace($title, '\s+', ' ').Trim()
            # 一覧のタイトル先頭に「2026-11-25NEW」のような日付がある場合は掲載日として使い、タイトルからは外す
            $listDate = ''
            $ldm = [regex]::Match($title, '^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})\s*(NEW|CHECK|New|new)?\s*')
            if ($ldm.Success) {
                $listDate = '{0}-{1:00}-{2:00}' -f [int]$ldm.Groups[1].Value, [int]$ldm.Groups[2].Value, [int]$ldm.Groups[3].Value
                $title = $title.Substring($ldm.Length).Trim()
            }
            $closed = [bool]($title -match $closedRe)
            if ($items.ContainsKey($id)) {
                $items[$id].title = $title
                $items[$id].closed = ($closed -or $items[$id].closed)
                $items[$id].tags = @(Get-Tags ($title + ' ' + $items[$id].summary) $title)
                continue
            }
            if ($closed -or $seenIds.ContainsKey($id)) {
                Add-Watch $id $d.url $title $c.name "$($c.name)HP" @(Get-Tags $title) (Test-Proposal $title)
                continue
            }
            try { $pg = Read-DetailPage $d.url $(if ($c.detailStart) { $c.detailStart } else { '<h1' }); Start-Sleep -Milliseconds 400 }
            catch { $errors += "$($c.name)の詳細取得に失敗: $($d.url)"; Write-Warning $errors[-1]; continue }
            if ($listDate -and $pg.pub -eq $Today) { $pg.pub = $listDate }
            if ($pg.pub -lt $cutoff) { continue }
            $text = $pg.text
            $ht = ConvertTo-Norm $text
            if ($ht.StartsWith($title)) { $text = $ht.Substring($title.Length).Trim() }
            # ページ内に選定結果が掲載済みなら終了扱い
            $pageClosed = [bool]((ConvertTo-Norm $text) -match '優先交渉権者|契約候補者は|結果表|選定しました|特定しました|決定しました|受託候補者を(選定|決定)|契約者の氏名|契約決定日|落札者(名|は)')
            $items[$id] = [pscustomobject][ordered]@{
                id        = $id
                source    = "$($c.name)HP"
                title     = $title
                org       = $c.name
                city      = $c.name
                kind      = ''
                tags      = @(Get-Tags ($title + ' ' + (Get-Summary $text 300)) $title)
                proposal  = (Test-Proposal ($title + ' ' + $text))
                url       = $d.url
                published = $pg.pub
                deadline  = Get-Deadline $text $pg.pub
                summary   = Get-Summary $text
                closed    = $pageClosed
                firstSeen = $Today
            }
            if (-not $pageClosed -and @($items[$id].tags).Count -gt 0) { Update-ItemDetail $items[$id] $text $pg.html }
            $cnt++
        }
        Write-Host "$($c.name): 候補 $($uniq.Count) 件 / 新規取得 $cnt 件"
    } catch {
        $errors += "$($c.name)の取得に失敗: $($_.Exception.Message)"
        Write-Warning $errors[-1]
    }
}

# ---------- 既存案件の補完(予算・要件が未読み取り、またはPDF未読の案件) ----------
# 公告から5か月以上先の「締切」は契約期間などの誤読とみなして読み直す
foreach ($it in @($items.Values)) {
    if ($it.deadline -and $it.published -and $it.deadline -gt ([datetime]::ParseExact($it.published, 'yyyy-MM-dd', $null)).AddDays(150).ToString('yyyy-MM-dd')) {
        $it.deadline = ''
        if ($it.PSObject.Properties['enriched']) { $it.enriched = $false }
    }
}
$enrichNow = 0
foreach ($it in @($items.Values)) {
    if ($enrichNow -ge 40) { break }
    if (@($it.tags).Count -eq 0 -or $it.closed) { continue }
    $hasBudget = [bool]$it.PSObject.Properties['budget']
    $done = $it.PSObject.Properties['enriched'] -and $it.enriched
    if ($done -or ($hasBudget -and -not $pdftotext)) { continue }
    $enrichNow++
    try {
        if ($it.url -match '\.pdf($|\?)') { Update-ItemDetail $it $it.summary '' }
        else {
            $h = Get-Html $it.url; Start-Sleep -Milliseconds 300
            $hs = [regex]::Replace($h, '(?is)<(script|style|header|nav|footer)[^>]*>.*?</\1>', ' ')
            Update-ItemDetail $it (ConvertFrom-Html $hs) $h
        }
    } catch { Set-Prop $it 'enriched' ([bool]$pdftotext) }
}
Write-Host "案件の補完(予算・要件・PDF): $enrichNow 件$(if (-not $pdftotext) { '（PDF読み取りなし）' })"

# ---------- 整理・期限切れ削除・重複除去 ----------
foreach ($k in $items.Keys) { if (-not $seenIds.ContainsKey($k)) { $seenIds[$k] = $Today } }
$staleDate = $Now.AddDays(-[int]$config.noDeadlineDays).ToString('yyyy-MM-dd')
$all = @($items.Values | Where-Object {
        $_.published -ge $cutoff -and
        -not $_.closed -and
        $(if ($_.deadline) { $_.deadline -ge $Today } else { $_.published -ge $staleDate })
    })
Write-Host "期限切れ・終了で削除: $($items.Count - $all.Count) 件"
# 削除した案件(県・市・団体のサイト分)は、結果の公表を見張る
$keptIds = @{}; foreach ($it in $all) { $keptIds[$it.id] = 1 }
foreach ($it in $items.Values) {
    if (-not $keptIds.ContainsKey($it.id) -and $it.source -ne '官公需ポータル') {
        Add-Watch $it.id $it.url $it.title $it.org $it.source @($it.tags) ([bool]$it.proposal)
    }
}

# ---------- 結果の確認(見張っている案件のページを開いて、選定事業者・落札者を探す) ----------
$checkGap = $Now.AddDays(-2).ToString('yyyy-MM-dd')
$watchLimit = $Now.AddDays(-[int]$config.resultWatchDays).ToString('yyyy-MM-dd')
$checkedNow = 0; $foundNow = 0
foreach ($w in @($watch.Values | Sort-Object lastCheck)) {
    if ($w.since -lt $watchLimit) { $watch.Remove($w.id); continue }   # 長期間結果が出ないものは諦める
    if ($w.lastCheck -and $w.lastCheck -gt $checkGap) { continue }      # 2日に1回まで
    if ($checkedNow -ge 80) { break }
    $checkedNow++
    $w.lastCheck = $Today
    try { $h = Get-Html $w.url; Start-Sleep -Milliseconds 400 } catch { continue }
    $hs = [regex]::Replace($h, '(?is)<(script|style|header|nav|footer)[^>]*>.*?</\1>', ' ')
    $text = ConvertFrom-Html $hs
    $res = Find-Result $text
    $src = 'ページ'
    if (-not $res -and $pdftotext) {
        # 結果がPDFで公表されている場合
        $pdfs = @()
        foreach ($m in [regex]::Matches($h, '<a[^>]+href="([^"]+\.pdf)"[^>]*>(.*?)</a>')) {
            $lt = ConvertTo-Norm ([regex]::Replace($m.Groups[2].Value, '<[^>]+>', ''))
            if ($lt -match '結果|選定|審査|特定|決定|落札|評価') { $pdfs += ([Uri]::new([Uri]$w.url, [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value))).AbsoluteUri }
        }
        foreach ($pu in ($pdfs | Select-Object -Unique -First 2)) {
            $res = Find-Result (Get-PdfText $pu)
            if ($res) { $src = 'PDF'; break }
        }
    }
    if ($res) {
        $dm = [regex]::Match($h, '(?:更新日|掲載日|公開日|公告日)[^0-9令]{0,40}?(?:(\d{4})年|令和\s*(\d{1,2})\s*年)\s*(\d{1,2})月\s*(\d{1,2})日')
        if (-not $dm.Success) { $dm = [regex]::Match($h, '(?:(\d{4})年|令和\s*(\d{1,2})\s*年)\s*(\d{1,2})月\s*(\d{1,2})日\s*(?:更新|掲載|公開)') }
        $rdate = $Today
        if ($dm.Success) { $y = $(if ($dm.Groups[1].Success) { [int]$dm.Groups[1].Value } else { 2018 + [int]$dm.Groups[2].Value }); $rdate = '{0}-{1:00}-{2:00}' -f $y, [int]$dm.Groups[3].Value, [int]$dm.Groups[4].Value }
        # 先頭の【選定結果の公表】(事業者決定) などの状態表示だけを外す(【案件名】形式は残す)
        $title = [regex]::Replace($w.title, '^(【[^】]*(結果|公表|決定|終了|選定|募集|回答)[^】]*】|\([^)]*(結果|決定|終了)[^)]*\))\s*', '')
        $resultMap[$w.id] = [pscustomobject][ordered]@{
            id = $w.id; title = $title; org = $w.org; source = $w.source; url = $w.url
            tags = @($w.tags); proposal = [bool]$w.proposal
            winner = $res.winner; score = $res.score; amount = $res.amount
            resultDate = $rdate; foundIn = $src; recordedAt = $Today
        }
        $watch.Remove($w.id)
        $foundNow++
    }
}
Write-Host "結果の確認: $checkedNow 件 / 新たに判明 $foundNow 件 / 見張り中 $($watch.Count) 件 / 記録済み $($resultMap.Count) 件$(if (-not $pdftotext) { '（PDF読み取りなし）' })"
$resKeep = $Now.AddDays(-[int]$config.resultKeepDays).ToString('yyyy-MM-dd')
$chkOut = [ordered]@{}
foreach ($k in ($resultChecked.Keys | Sort-Object)) { if ($resultChecked[$k] -ge $resKeep) { $chkOut[$k] = $resultChecked[$k] } }
$resOut = [ordered]@{
    updatedAt = $Now.ToString('yyyy-MM-ddTHH:mm:sszzz')
    results   = @($resultMap.Values | Where-Object { $_.resultDate -ge $resKeep } | Sort-Object -Property @{Expression = 'resultDate'; Descending = $true })
    watch     = @($watch.Values)
    checked   = $chkOut
}
New-Item -ItemType Directory -Force (Join-Path $Root 'docs') | Out-Null
[IO.File]::WriteAllText($resultsPath, (ConvertTo-Json -InputObject $resOut -Depth 5), $Utf8NoBom)

# ---------- 履歴の蓄積と「例年の案件」の予告 ----------
# 年度や「公募型プロポーザル」などの言い回しを除いた“案件の芯”で、毎年同じ案件を同一視する
function Get-RecurKey([string]$org, [string]$title) {
    $t = ConvertTo-Norm $title
    $t = [regex]::Replace($t, '【[^】]*(結果|公表|決定|終了|選定|募集|回答|質問)[^】]*】|\([^)]*(結果|決定|終了|PDF)[^)]*\)', '')
    $t = [regex]::Replace($t, '令和\s*\d+\s*(・\s*\d+\s*)?(年度|年)?|R\s*\d+\s*(年度|年)?|平成\s*\d+\s*(年度|年)?|20\d{2}\s*(年度|年)?|第\s*\d+\s*(回|期|次)', '')
    $t = [regex]::Replace($t, '(に係る|に関する|にかかる|における|の)?(公募型|簡易|企画競争型)?(プロポーザル|企画提案(書)?(の)?(募集|公募)?|コンペ(ティション)?)(方式)?', '')
    $t = [regex]::Replace($t, '(の)?(実施|募集|参加者|参加事業者|受託者|事業者|審査|選定|特定|契約候補者選定)*(の)?(結果)?(について|のお知らせ|の公表|のご案内|を募集します|を実施します)?$', '')
    $t = [regex]::Replace($t, '[\s「」『』【】()（）・,、。:：\-~〜]', '')
    $t = [regex]::Replace($t, '(業務委託|委託業務|業務|事業)+$', '')
    if ($t.Length -lt 6) { return '' }
    return "$org|$t"
}
$historyPath = Join-Path $Root 'docs/history.json'
$hist = @{}   # key -> list of occurrences
if (Test-Path $historyPath) {
    $ho = Get-Content -Raw -Encoding UTF8 $historyPath | ConvertFrom-Json
    if ($ho.entries) { foreach ($p in $ho.entries.PSObject.Properties) { $hist[$p.Name] = [System.Collections.ArrayList]@($p.Value) } }
}
function Add-History($key, [string]$date, [string]$kind, $src) {
    if (-not $key -or -not $date) { return }
    if (-not $script:hist.ContainsKey($key)) { $script:hist[$key] = [System.Collections.ArrayList]@() }
    $list = $script:hist[$key]
    # 公告日の推定(結果は公告の約40日後とみなす)
    $est = $(if ($kind -eq 'notice') { $date } else { ([datetime]::ParseExact($date, 'yyyy-MM-dd', $null)).AddDays(-40).ToString('yyyy-MM-dd') })
    $same = @($list | Where-Object { $_.url -eq $src.url -and $_.kind -eq $kind })
    if ($same.Count -gt 0) {
        foreach ($s in $same) { foreach ($n in 'winner', 'amount', 'budget') { if ($src.$n -and -not $s.$n) { Set-Prop $s $n $src.$n } } }
        return
    }
    [void]$list.Add([pscustomobject][ordered]@{
            date = $date; est = $est; kind = $kind; title = $src.title; org = $src.org; source = $src.source; url = $src.url
            tags = @($src.tags); winner = "$($src.winner)"; amount = "$($src.amount)"; budget = [int64]$(if ($src.budget) { $src.budget } else { 0 })
        })
}
foreach ($it in $all) {
    if (@($it.tags).Count -eq 0) { continue }
    Add-History (Get-RecurKey $it.org $it.title) $it.published 'notice' ([pscustomobject]@{ title = $it.title; org = $it.org; source = $it.source; url = $it.url; tags = $it.tags; budget = $(if ($it.PSObject.Properties['budget']) { $it.budget } else { 0 }) })
}
foreach ($r in $resultMap.Values) {
    Add-History (Get-RecurKey $r.org $r.title) $r.resultDate 'result' $r
}
$histKeep = $Now.AddDays(-1100).ToString('yyyy-MM-dd')
$forecast = @()
$fromD = $Now.AddDays(-30).ToString('yyyy-MM-dd'); $toD = $Now.AddDays([int]$config.forecastDays).ToString('yyyy-MM-dd')
$thisRound = $Now.AddDays(-300).ToString('yyyy-MM-dd')
foreach ($k in @($hist.Keys)) {
    $occ = @($hist[$k] | Where-Object { $_.date -ge $histKeep } | Sort-Object est -Descending)
    if ($occ.Count -eq 0) { $hist.Remove($k); continue }
    $hist[$k] = [System.Collections.ArrayList]@($occ | Select-Object -First 6)
    $latest = $occ[0]
    if ($latest.est -ge $thisRound) { continue }   # 今年度分はすでに出ている
    $next = [datetime]::ParseExact($latest.est, 'yyyy-MM-dd', $null)
    while ($next.ToString('yyyy-MM-dd') -lt $fromD) { $next = $next.AddYears(1) }
    $nd = $next.ToString('yyyy-MM-dd')
    if ($nd -gt $toD -or $next -gt [datetime]::ParseExact($latest.est, 'yyyy-MM-dd', $null).AddYears(2)) { continue }
    $res = @($occ | Where-Object { $_.winner } | Select-Object -First 1)
    $bud = @($occ | Where-Object { $_.budget -gt 0 } | Select-Object -First 1)
    $forecast += [pscustomobject][ordered]@{
        key = $k; expected = $nd; title = $latest.title; org = $latest.org; source = $latest.source; url = $latest.url
        tags = @($latest.tags); lastDate = $latest.est; years = @($occ | ForEach-Object { $_.est.Substring(0, 4) } | Select-Object -Unique).Count
        lastWinner = $(if ($res) { $res[0].winner } else { '' }); lastAmount = $(if ($res) { $res[0].amount } else { '' })
        lastBudget = [int64]$(if ($bud) { $bud[0].budget } else { 0 })
    }
}
$forecast = @($forecast | Sort-Object expected)
Write-Host "履歴: $($hist.Count) 案件 / 予告: $($forecast.Count) 件"
$histOut = [ordered]@{}
foreach ($k in ($hist.Keys | Sort-Object)) { $histOut[$k] = @($hist[$k]) }
[IO.File]::WriteAllText($historyPath, (ConvertTo-Json -InputObject ([ordered]@{ updatedAt = $Now.ToString('yyyy-MM-ddTHH:mm:sszzz'); forecast = $forecast; entries = $histOut }) -Depth 6), $Utf8NoBom)
# 設定(キーワード)変更を過去分にも反映
foreach ($it in $all) { if ($it.source -eq '官公需ポータル') { $it.tags = @(Get-Tags $it.title) } }
# 県・市のサイトと官公需ポータルで重複する案件は、県・市のサイト側を残す
$siteTitles = @{}
foreach ($it in $all) { if ($it.source -ne '官公需ポータル') { $siteTitles[(Get-NormTitle $it.title)] = 1 } }
$all = @($all | Where-Object { $_.source -ne '官公需ポータル' -or -not $siteTitles.ContainsKey((Get-NormTitle $_.title)) })
# 既出IDの記録は keepDays を過ぎたら忘れる
$seenOut = [ordered]@{}
foreach ($k in ($seenIds.Keys | Sort-Object)) { if ($seenIds[$k] -ge $cutoff) { $seenOut[$k] = $seenIds[$k] } }
$all = @($all | Sort-Object -Property @{Expression = 'published'; Descending = $true }, @{Expression = 'id'; Descending = $false })

$out = [ordered]@{
    updatedAt = $Now.ToString('yyyy-MM-ddTHH:mm:sszzz')
    newDays   = [int]$config.newDays
    tags      = @($config.tags | ForEach-Object { $_.name })
    errors    = $errors
    items     = $all
    seen      = $seenOut
}
New-Item -ItemType Directory -Force (Join-Path $Root 'docs') | Out-Null
[IO.File]::WriteAllText($dataPath, (ConvertTo-Json -InputObject $out -Depth 6), $Utf8NoBom)

# ---------- RSS フィード(分野に該当し、募集中のもの) ----------
function ConvertTo-XmlText([string]$s) { return [System.Security.SecurityElement]::Escape($s) }
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
[void]$sb.AppendLine('<rss version="2.0"><channel>')
[void]$sb.AppendLine('<title>静岡県 コンペ・入札ウォッチ</title><link>https://www.kkj.go.jp/</link><description>静岡県内のイベント・Web/IT・デザイン/広報/映像分野の入札・プロポーザル新着</description>')
foreach ($it in ($all | Where-Object { @($_.tags).Count -gt 0 -and -not $_.closed } | Select-Object -First 100)) {
    $pubDate = ([datetime]::ParseExact($it.published, 'yyyy-MM-dd', $null)).ToString('ddd, dd MMM yyyy 00:00:00 +0900', [Globalization.CultureInfo]::InvariantCulture)
    $desc = "[$((@($it.tags)) -join ' / ')] $($it.org)"
    if ($it.deadline) { $desc += " / 締切目安 $($it.deadline)" }
    $desc += " / $($it.summary)"
    [void]$sb.AppendLine("<item><title>$(ConvertTo-XmlText $it.title)</title><link>$(ConvertTo-XmlText $it.url)</link><guid isPermaLink=`"false`">$(ConvertTo-XmlText $it.id)</guid><pubDate>$pubDate</pubDate><description>$(ConvertTo-XmlText $desc)</description></item>")
}
[void]$sb.AppendLine('</channel></rss>')
[IO.File]::WriteAllText((Join-Path $Root 'docs/feed.xml'), $sb.ToString(), $Utf8NoBom)

# ---------- 新着のプッシュ通知 (ntfy) ----------
# 環境変数 NTFY_TOPIC が設定されているときだけ送信。初回実行(既存データなし)は送らない
$newItems = @($all | Where-Object { @($_.tags).Count -gt 0 -and -not $_.closed -and -not $oldIds.ContainsKey($_.id) })
# 締切リマインド(締切の remindDays 日前)
$remindDates = @($config.remindDays | ForEach-Object { $Now.AddDays([int]$_).ToString('yyyy-MM-dd') })
$remindItems = @($all | Where-Object { @($_.tags).Count -gt 0 -and $_.deadline -and ($remindDates -contains $_.deadline) -and $oldIds.ContainsKey($_.id) } | Sort-Object deadline)
Write-Host "新着: $($newItems.Count) 件 / 締切リマインド: $($remindItems.Count) 件"

function Send-Ntfy([string]$title, [string[]]$lines, [string]$tag, [int]$priority = 3) {
    $payload = [ordered]@{ topic = $env:NTFY_TOPIC; title = $title; message = ($lines -join "`n"); tags = @($tag); click = $config.siteUrl; priority = $priority }
    try {
        $body = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $payload -Depth 3))
        Invoke-RestMethod -Method Post -Uri 'https://ntfy.sh/' -Body $body -ContentType 'application/json; charset=utf-8' -TimeoutSec 30 | Out-Null
        Write-Host "通知を送信しました: $title"
    } catch { Write-Warning "通知の送信に失敗: $($_.Exception.Message)" }
}
function Format-Line($it) {
    $line = "・$($it.title)（$($it.org)）"
    if ($it.PSObject.Properties['budget'] -and $it.budget) { $line += " 上限$([math]::Round($it.budget / 10000))万円" }
    if ($it.deadline) { $line += " 締切目安 $($it.deadline.Substring(5).Replace('-', '/'))" }
    return $line
}

if ($env:NTFY_TOPIC -and $oldIds.Count -gt 0) {
    if ($newItems.Count -gt 0) {
        $lines = @($newItems | Select-Object -First 8 | ForEach-Object { Format-Line $_ })
        if ($newItems.Count -gt 8) { $lines += "ほか $($newItems.Count - 8) 件" }
        $prop = @($newItems | Where-Object { $_.proposal }).Count
        $title = "静岡 新着案件 $($newItems.Count) 件"
        if ($prop -gt 0) { $title += "（プロポーザル $prop 件）" }
        Send-Ntfy $title $lines 'bell'
    }
    if ($remindItems.Count -gt 0) {
        $lines = @($remindItems | Select-Object -First 8 | ForEach-Object { $n = ([datetime]::ParseExact($_.deadline, 'yyyy-MM-dd', $null) - $Now.Date).Days; "・あと$($n)日 " + (Format-Line $_).Substring(1) })
        Send-Ntfy "締切が近い案件 $($remindItems.Count) 件" $lines 'alarm_clock' 4
    }
    if ($foundNow -gt 0 -and $config.notifyResults) {
        $newRes = @($resultMap.Values | Where-Object { $_.recordedAt -eq $Today } | Select-Object -First 6)
        $lines = @($newRes | ForEach-Object { "・$($_.title)（$($_.org)）→ $($_.winner)" })
        Send-Ntfy "落札・選定結果 $foundNow 件を記録" $lines 'trophy' 2
    }
    if ($errors.Count -gt 0) {
        # 同じエラーが続く場合に毎日鳴らないよう、前回と内容が変わったときだけ通知
        $prevErr = $(if ($old -and $old.errors) { (@($old.errors) -join '|') } else { '' })
        if (($errors -join '|') -ne $prevErr) { Send-Ntfy "収集エラー $($errors.Count) 件" @($errors | Select-Object -First 5) 'warning' 3 }
    }
}

$shown = @($all | Where-Object { @($_.tags).Count -gt 0 }).Count
Write-Host "完了: 表示対象 $shown 件 / 保持 $($all.Count) 件 / エラー $($errors.Count) 件"
