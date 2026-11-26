# GitHub から最新の案件データを取り込み、一覧ページをブラウザで開く
$root = Split-Path -Parent $PSScriptRoot
$git = 'C:\Program Files\Git\cmd\git.exe'
if (-not (Test-Path $git)) { $git = 'git' }
Write-Host '最新データを取り込み中...'
& $git -C $root pull --ff-only
if ($LASTEXITCODE -ne 0) { Write-Warning '取り込みに失敗しました。手元のデータで表示します。' }
Start-Process 'http://localhost:8765/'
& (Join-Path $PSScriptRoot 'serve.ps1')
