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

function Get-Tags([string]$text) {
    $t = ConvertTo-Norm $text
    # 公告文の定型句(電子入札・ホームページに掲載 など)で分野が誤判定されないよう除去
    $t = [regex]::Replace($t, '電子(入札|調達|申請|契約|メール|データ|納品|媒体)(システム)?|入札(情報)?(公開)?システム|(ホームページ|ウェブサイト|Webサイト|サイト)(に|で|から|より|上|へ|を|等)|PDF|(?<![A-Za-z])KB(?![A-Za-z])', ' ')
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
    $kwRe = '(提出期限|提出期間|提出締切|締切|締め切り|受付期間|応募期限|応募期間|申込期限|参加申込|参加表明書の提出|企画提案書の提出|企画提案書等の提出)'
    $dateRe = '(?:(令和|R)\s*(\d{1,2})\s*年\s*|(20\d{2})\s*年\s*|(20\d{2})[/.])?(\d{1,2})\s*[月/.]\s*(\d{1,2})\s*日?'
    foreach ($m in [regex]::Matches($t, $kwRe)) {
        $start = $m.Index + $m.Length
        $win = $t.Substring($start, [Math]::Min(140, $t.Length - $start))
        $cut = $win.IndexOf('。'); if ($cut -gt 0) { $win = $win.Substring(0, $cut) }
        $dates = @([regex]::Matches($win, $dateRe))
        if ($dates.Count -eq 0) { continue }
        $pick = $null
        foreach ($d in $dates) {
            $after = $win.Substring($d.Index + $d.Length, [Math]::Min(25, $win.Length - $d.Index - $d.Length))
            if ($after -match '^[^月]{0,22}まで') { $pick = $d; break }
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
        if ($dt -lt $base.AddDays(-1) -or $dt -gt $base.AddDays(240)) { continue }
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
    }
    $script:items[$obj.id] = $obj
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
            $items[$id].tags = @(Get-Tags ($title + ' ' + $items[$id].summary))
            continue
        }
        if ($closed -or $seenIds.ContainsKey($id)) { continue }
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
        $tags = @(Get-Tags ($title + ' ' + (Get-Summary $summarySrc 300)))
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
        # 分野に該当しない県案件も一度取得したら再取得しないよう、tags 空で保持(表示はしない)
        $items[$id] = $obj
    }
} catch {
    $errors += "静岡県HPの取得に失敗: $($_.Exception.Message)"
    Write-Warning $errors[-1]
}

# ---------- 3. 市のサイト (静岡市・焼津市・藤枝市・富士市 など config.cities) ----------
function Read-DetailPage([string]$url) {
    $h = Get-Html $url
    $dm = [regex]::Match($h, '(?:更新日|掲載日|公開日|公開開始日|作成日|登録日)[^0-9令]{0,40}?(?:(\d{4})年|令和\s*(\d{1,2})\s*年)\s*(\d{1,2})月\s*(\d{1,2})日')
    $pub = $Today
    if ($dm.Success) {
        $y = $(if ($dm.Groups[1].Success) { [int]$dm.Groups[1].Value } else { 2018 + [int]$dm.Groups[2].Value })
        $pub = '{0}-{1:00}-{2:00}' -f $y, [int]$dm.Groups[3].Value, [int]$dm.Groups[4].Value
    }
    $s = $h.IndexOf('<h1'); if ($s -lt 0) { $s = 0 }
    $e = -1
    foreach ($mk in 'このページに関するお問い合わせ', 'このページに関するお問合せ', 'お問い合わせ先', 'id="footer"', 'class="footer') {
        $e = $h.IndexOf($mk, $s); if ($e -gt 0) { break }
    }
    if ($e -lt 0) { $e = $h.Length }
    $text = ConvertFrom-Html $h.Substring($s, $e - $s)
    $text = [regex]::Replace($text, 'いいね[!！]|ページID\s*[:：]?\s*\d+|(?:最終)?更新日\s*[:：]?\s*\S+日|大きな文字で印刷|印刷する|印刷', ' ').Trim()
    return [pscustomobject]@{ pub = $pub; text = $text }
}

foreach ($c in $config.cities) {
    try {
        $links = @()
        foreach ($lu in @($c.lists)) {
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
                foreach ($p in @($j)) { if ($p.page_name -match $c.updateNamePattern) { $links += [pscustomobject]@{ url = $p.url; title = $p.page_name } } }
            } catch { $errors += "$($c.name)の更新情報取得に失敗"; Write-Warning $errors[-1] }
        }
        $uniq = @{}
        $cnt = 0
        foreach ($d in $links) {
            if ($uniq.ContainsKey($d.url)) { continue }; $uniq[$d.url] = 1
            $id = 'city:' + ($d.url -replace '^https?://(www\.)?', '')
            $title = ConvertTo-Norm ([System.Net.WebUtility]::HtmlDecode($d.title))
            $title = [regex]::Replace($title, '\s+', ' ').Trim()
            $closed = [bool]($title -match $closedRe)
            if ($items.ContainsKey($id)) {
                $items[$id].title = $title
                $items[$id].closed = $closed
                $items[$id].tags = @(Get-Tags ($title + ' ' + $items[$id].summary))
                continue
            }
            if ($closed -or $seenIds.ContainsKey($id)) { continue }
            try { $pg = Read-DetailPage $d.url; Start-Sleep -Milliseconds 400 }
            catch { $errors += "$($c.name)の詳細取得に失敗: $($d.url)"; Write-Warning $errors[-1]; continue }
            if ($pg.pub -lt $cutoff) { continue }
            $text = $pg.text
            $ht = ConvertTo-Norm $text
            if ($ht.StartsWith($title)) { $text = $ht.Substring($title.Length).Trim() }
            $items[$id] = [pscustomobject][ordered]@{
                id        = $id
                source    = "$($c.name)HP"
                title     = $title
                org       = $c.name
                city      = $c.name
                kind      = ''
                tags      = @(Get-Tags ($title + ' ' + (Get-Summary $text 300)))
                proposal  = (Test-Proposal ($title + ' ' + $text))
                url       = $d.url
                published = $pg.pub
                deadline  = Get-Deadline $text $pg.pub
                summary   = Get-Summary $text
                closed    = $false
                firstSeen = $Today
            }
            $cnt++
        }
        Write-Host "$($c.name): 候補 $($uniq.Count) 件 / 新規取得 $cnt 件"
    } catch {
        $errors += "$($c.name)の取得に失敗: $($_.Exception.Message)"
        Write-Warning $errors[-1]
    }
}

# ---------- 整理・期限切れ削除・重複除去 ----------
foreach ($k in $items.Keys) { if (-not $seenIds.ContainsKey($k)) { $seenIds[$k] = $Today } }
$staleDate = $Now.AddDays(-[int]$config.noDeadlineDays).ToString('yyyy-MM-dd')
$all = @($items.Values | Where-Object {
        $_.published -ge $cutoff -and
        -not $_.closed -and
        $(if ($_.deadline) { $_.deadline -ge $Today } else { $_.published -ge $staleDate })
    })
Write-Host "期限切れ・終了で削除: $($items.Count - $all.Count) 件"
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
Write-Host "新着: $($newItems.Count) 件"
if ($env:NTFY_TOPIC -and $newItems.Count -gt 0 -and $oldIds.Count -gt 0) {
    $lines = @()
    foreach ($it in ($newItems | Select-Object -First 8)) {
        $line = "・$($it.title)（$($it.org)）"
        if ($it.deadline) { $line += " 締切目安 $($it.deadline.Substring(5).Replace('-', '/'))" }
        $lines += $line
    }
    if ($newItems.Count -gt 8) { $lines += "ほか $($newItems.Count - 8) 件" }
    $prop = @($newItems | Where-Object { $_.proposal }).Count
    $title = "静岡 新着案件 $($newItems.Count) 件"
    if ($prop -gt 0) { $title += "（プロポーザル $prop 件）" }
    $payload = [ordered]@{
        topic   = $env:NTFY_TOPIC
        title   = $title
        message = ($lines -join "`n")
        tags    = @('bell')
        click   = $config.siteUrl
    }
    try {
        $body = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $payload -Depth 3))
        Invoke-RestMethod -Method Post -Uri 'https://ntfy.sh/' -Body $body -ContentType 'application/json; charset=utf-8' -TimeoutSec 30 | Out-Null
        Write-Host '通知を送信しました'
    } catch { Write-Warning "通知の送信に失敗: $($_.Exception.Message)" }
}

$shown = @($all | Where-Object { @($_.tags).Count -gt 0 }).Count
Write-Host "完了: 表示対象 $shown 件 / 保持 $($all.Count) 件 / エラー $($errors.Count) 件"
