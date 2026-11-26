# docs フォルダをローカルで確認するための簡易Webサーバー (http://localhost:8765/)
param([int]$Port = 8765)
$docs = Join-Path (Split-Path -Parent $PSScriptRoot) 'docs'
$types = @{ '.html' = 'text/html; charset=utf-8'; '.json' = 'application/json; charset=utf-8'; '.xml' = 'application/xml; charset=utf-8' }
$l = New-Object System.Net.HttpListener
$l.Prefixes.Add("http://localhost:$Port/")
$l.Start()
Write-Host "http://localhost:$Port/ で公開中 (Ctrl+C で停止)"
while ($l.IsListening) {
    $c = $l.GetContext()
    $path = $c.Request.Url.AbsolutePath.TrimStart('/'); if (-not $path) { $path = 'index.html' }
    $file = Join-Path $docs $path
    if ((Test-Path $file -PathType Leaf) -and ((Resolve-Path $file).Path.StartsWith((Resolve-Path $docs).Path))) {
        $bytes = [IO.File]::ReadAllBytes($file)
        $ext = [IO.Path]::GetExtension($file)
        if ($types.ContainsKey($ext)) { $c.Response.ContentType = $types[$ext] }
        $c.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    } else { $c.Response.StatusCode = 404 }
    $c.Response.Close()
}
