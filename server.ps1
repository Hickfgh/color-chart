param(
    [int]$Port = 8765,
    [string]$ListenAddress = 'http://localhost'
)

$ErrorActionPreference = 'Stop'
$dataDirectory = Join-Path $PSScriptRoot 'data'
$dataFile = Join-Path $dataDirectory 'reservations.json'
if (-not (Test-Path $dataDirectory)) { New-Item -ItemType Directory -Path $dataDirectory | Out-Null }
if (-not (Test-Path $dataFile)) { Set-Content -Path $dataFile -Value '[]' -Encoding UTF8 }

$adminPassword = $env:COLOR_CHART_ADMIN_PASSWORD
if ([string]::IsNullOrWhiteSpace($adminPassword)) {
    $bytes = New-Object byte[] 18
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $adminPassword = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', 'A').Replace('/', 'B')
    Write-Host "Generated temporary admin password: $adminPassword" -ForegroundColor Yellow
    Write-Host 'Set COLOR_CHART_ADMIN_PASSWORD before restarting to use a fixed password.'
}

$sessions = @{}
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("$($ListenAddress.TrimEnd('/')):$Port/")
try { $listener.Start() } catch {
    Write-Error "Could not listen on $($ListenAddress.TrimEnd('/')):$Port. For network access, configure a Windows URL reservation for the chosen address. $($_.Exception.Message)"
    exit 1
}
Write-Host "Color chart server: $($ListenAddress.TrimEnd('/')):$Port/"
Write-Host 'Press Ctrl+C to stop.'

function Send-Response($Context, [int]$StatusCode, $Body, [string]$ContentType = 'application/json; charset=utf-8') {
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = $ContentType
    $Context.Response.Headers['Cache-Control'] = 'no-store'
    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Body)
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.Close()
}

function Send-Json($Context, [int]$StatusCode, $Value) {
    Send-Response $Context $StatusCode (ConvertTo-Json -InputObject $Value -Depth 8 -Compress)
}

function Read-Json($Request) {
    $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    try { return $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
}

function Read-Reservations {
    if (-not (Test-Path $dataFile)) { return @() }
    $raw = Get-Content -Path $dataFile -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    return @(ConvertFrom-Json -InputObject $raw)
}

function Write-Reservations($Items) {
    $temporaryFile = "$dataFile.tmp"
    ConvertTo-Json -InputObject @($Items) -Depth 8 | Set-Content -Path $temporaryFile -Encoding UTF8
    Move-Item -Path $temporaryFile -Destination $dataFile -Force
}

while ($listener.IsListening) {
    $context = $null
    try {
        $context = $listener.GetContext()
        $request = $context.Request
        $path = $request.Url.AbsolutePath.TrimEnd('/')
        if ($path -eq '') { $path = '/' }

        if ($request.HttpMethod -eq 'GET' -and ($path -eq '/' -or $path -eq '/admin')) {
            $html = Get-Content -Path (Join-Path $PSScriptRoot 'index.html') -Raw -Encoding UTF8
            Send-Response $context 200 $html 'text/html; charset=utf-8'
            continue
        }

        if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/status') {
            $reservations = Read-Reservations
            Send-Json $context 200 @{ taken = @($reservations | ForEach-Object { $_.colorId }) }
            continue
        }

        if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/admin/login') {
            $body = Read-Json $request
            if (-not [string]::Equals([string]$body.password, $adminPassword, [StringComparison]::Ordinal)) {
                Send-Json $context 401 @{ error = '管理密碼不正確。' }
                continue
            }
            $token = [Guid]::NewGuid().ToString('N')
            $sessions[$token] = $true
            Send-Json $context 200 @{ token = $token }
            continue
        }

        if ($path -like '/api/admin/*' -or $path -eq '/api/admin/reservations') {
            $authorization = $request.Headers['Authorization']
            $token = if ($authorization -match '^Bearer (.+)$') { $Matches[1] } else { '' }
            if (-not $sessions.ContainsKey($token)) {
                Send-Json $context 401 @{ error = '請先登入管理後台。' }
                continue
            }
            if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/admin/reservations') {
                $reservations = @(Read-Reservations | Sort-Object createdAt -Descending)
                Send-Json $context 200 $reservations
                continue
            }
        }

        if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/reservations') {
            $body = Read-Json $request
            $colorId = [string]$body.colorId
            $claimant = ([string]$body.claimant).Trim()
            $contact = ([string]$body.contact).Trim()
            if ($colorId -notmatch '^(yellow|orange|red|pink|brown|brick|cyan|blue|navy|purple|lavender|teal)-(\d+-){3}\d+$' -or [string]::IsNullOrWhiteSpace($claimant) -or $claimant.Length -gt 60 -or $contact.Length -gt 120) {
                Send-Json $context 400 @{ error = '請提供有效的色票與名字。' }
                continue
            }
            $reservations = @(Read-Reservations)
            if ($reservations | Where-Object { $_.colorId -eq $colorId }) {
                Send-Json $context 409 @{ error = '這張色票已被選走。' }
                continue
            }
            $parts = $colorId -split '-'
            $categoryId = $parts[0]
            $cmyk = @([int]$parts[1], [int]$parts[2], [int]$parts[3], [int]$parts[4])
            $group = if ($categoryId -in @('yellow', 'orange', 'red', 'pink', 'brown', 'brick')) { '暖色調' } else { '冷色調' }
            $categories = @{ yellow='黃色系'; orange='橙色系'; red='紅色系'; pink='粉紅色系'; brown='棕色系'; brick='暖橘棕、磚紅'; cyan='青色系'; blue='藍色系'; navy='深藍色系'; purple='紫色系'; lavender='淡紫色系'; teal='青綠色系' }
            $rgb = @($cmyk[0], $cmyk[1], $cmyk[2] | ForEach-Object { [int][Math]::Round(255 * (1 - $_ / 100) * (1 - $cmyk[3] / 100)) })
            $hex = '#' + (($rgb | ForEach-Object { $_.ToString('x2') }) -join '')
            $record = [PSCustomObject]@{ colorId = $colorId; category = $categories[$categoryId]; group = $group; cmyk = $cmyk; hex = $hex; claimant = $claimant; contact = $contact; createdAt = [DateTime]::UtcNow.ToString('o') }
            Write-Reservations (@($reservations) + @($record))
            Send-Json $context 201 @{ colorId = $colorId }
            continue
        }

        Send-Json $context 404 @{ error = '找不到這個頁面。' }
    } catch {
        Write-Host "Request error: $($_.Exception.Message)" -ForegroundColor Red
        if ($context -and $context.Response.OutputStream.CanWrite) {
            try { Send-Json $context 500 @{ error = '伺服器發生錯誤，請稍後重試。' } } catch { }
        }
    }
}