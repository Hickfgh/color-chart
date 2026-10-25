param(
    [int]$Port = 8765,
    [string]$ListenAddress = 'http://localhost'
)

$ErrorActionPreference = 'Stop'
$dataDirectory = Join-Path $PSScriptRoot 'data'
$dataFile = Join-Path $dataDirectory 'reservations.json'
$credentialFile = Join-Path $dataDirectory 'admin-credentials.json'
$staffCredentialFile = Join-Path $dataDirectory 'staff-credentials.json'
$gmailSettingsFile = Join-Path $dataDirectory 'gmail-settings.json'
if (-not (Test-Path $dataDirectory)) { New-Item -ItemType Directory -Path $dataDirectory | Out-Null }
if (-not (Test-Path $dataFile)) { Set-Content -Path $dataFile -Value '{"reservations":[]}' -Encoding UTF8 }
Add-Type -AssemblyName System.Security

$adminUsername = ''
$adminSalt = ''
$adminHash = ''
$staffUsername = ''
$staffSalt = ''
$staffHash = ''
if (Test-Path $credentialFile) {
    $savedCredentials = Get-Content -Path $credentialFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $adminUsername = [string]$savedCredentials.username
    $adminSalt = [string]$savedCredentials.salt
    $adminHash = [string]$savedCredentials.hash
}
if (Test-Path $staffCredentialFile) {
    $savedStaffCredentials = Get-Content -Path $staffCredentialFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $staffUsername = [string]$savedStaffCredentials.username
    $staffSalt = [string]$savedStaffCredentials.salt
    $staffHash = [string]$savedStaffCredentials.hash
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

function Get-PasswordHash([string]$Password, [byte[]]$Salt) {
    $deriveBytes = [Security.Cryptography.Rfc2898DeriveBytes]::new($Password, $Salt, 120000)
    try { return [Convert]::ToBase64String($deriveBytes.GetBytes(32)) } finally { $deriveBytes.Dispose() }
}

function Test-AdminPassword([string]$Username, [string]$Password) {
    if (-not $adminHash -or -not [string]::Equals($Username, $adminUsername, [StringComparison]::Ordinal)) { return $false }
    $salt = [Convert]::FromBase64String($adminSalt)
    return [string]::Equals((Get-PasswordHash $Password $salt), $adminHash, [StringComparison]::Ordinal)
}

function Test-StaffPassword([string]$Username, [string]$Password) {
    if (-not $staffHash -or -not [string]::Equals($Username, $staffUsername, [StringComparison]::Ordinal)) { return $false }
    $salt = [Convert]::FromBase64String($staffSalt)
    return [string]::Equals((Get-PasswordHash $Password $salt), $staffHash, [StringComparison]::Ordinal)
}

function Save-AdminCredentials {
    $temporaryFile = "$credentialFile.tmp"
    ConvertTo-Json -InputObject @{ username = $adminUsername; salt = $adminSalt; hash = $adminHash } -Compress | Set-Content -Path $temporaryFile -Encoding UTF8
    Move-Item -Path $temporaryFile -Destination $credentialFile -Force
}

function Save-StaffCredentials {
    $temporaryFile = "$staffCredentialFile.tmp"
    ConvertTo-Json -InputObject @{ username = $staffUsername; salt = $staffSalt; hash = $staffHash } -Compress | Set-Content -Path $temporaryFile -Encoding UTF8
    Move-Item -Path $temporaryFile -Destination $staffCredentialFile -Force
}

function Protect-GmailPassword([string]$Password) {
    $plainBytes = [Text.Encoding]::UTF8.GetBytes($Password)
    $entropy = [Text.Encoding]::UTF8.GetBytes('ColorChart.Gmail.Settings.v1')
    $encryptedBytes = [Security.Cryptography.ProtectedData]::Protect($plainBytes, $entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Convert]::ToBase64String($encryptedBytes)
}

function Unprotect-GmailPassword([string]$EncryptedPassword) {
    $encryptedBytes = [Convert]::FromBase64String($EncryptedPassword)
    $entropy = [Text.Encoding]::UTF8.GetBytes('ColorChart.Gmail.Settings.v1')
    $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect($encryptedBytes, $entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Text.Encoding]::UTF8.GetString($plainBytes)
}

function Read-GmailSettings {
    if (-not (Test-Path $gmailSettingsFile)) {
        return [PSCustomObject]@{ sender = ''; recipient = ''; enabled = $false; encryptedPassword = '' }
    }
    return Get-Content -Path $gmailSettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-GmailSettings($Settings) {
    $temporaryFile = "$gmailSettingsFile.tmp"
    ConvertTo-Json -InputObject $Settings -Compress | Set-Content -Path $temporaryFile -Encoding UTF8
    Move-Item -Path $temporaryFile -Destination $gmailSettingsFile -Force
}

function Send-GmailMessage($Settings, [string]$Subject, [string]$Body) {
    $appPassword = Unprotect-GmailPassword $Settings.encryptedPassword
    $message = [System.Net.Mail.MailMessage]::new()
    $client = [System.Net.Mail.SmtpClient]::new('smtp.gmail.com', 587)
    try {
        $message.From = [System.Net.Mail.MailAddress]::new($Settings.sender)
        $message.To.Add([System.Net.Mail.MailAddress]::new($Settings.recipient))
        $message.Subject = $Subject
        $message.SubjectEncoding = [Text.Encoding]::UTF8
        $message.Body = $Body
        $message.BodyEncoding = [Text.Encoding]::UTF8
        $client.EnableSsl = $true
        $client.Timeout = 15000
        $client.Credentials = [System.Net.NetworkCredential]::new($Settings.sender, $appPassword)
        $client.Send($message)
    } finally {
        $message.Dispose()
        $client.Dispose()
    }
}

function Read-Json($Request) {
    $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    try { return $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
}

function Read-Reservations {
    if (-not (Test-Path $dataFile)) { return @{ reservations = @() } }
    $raw = Get-Content -Path $dataFile -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return @{ reservations = @() } }
    $parsed = ConvertFrom-Json -InputObject $raw
    if ($parsed.PSObject.Properties['reservations']) { return $parsed }
    return @{ reservations = @($parsed | Where-Object { $_.PSObject.Properties['colorId'] }) }
}

function Write-Reservations($Items) {
    $temporaryFile = "$dataFile.tmp"
    ConvertTo-Json -InputObject @{ reservations = @($Items) } -Depth 8 | Set-Content -Path $temporaryFile -Encoding UTF8
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
        if ($request.HttpMethod -eq 'GET' -and $path -eq '/staff') {
            $html = Get-Content -Path (Join-Path $PSScriptRoot 'staff.html') -Raw -Encoding UTF8
            Send-Response $context 200 $html 'text/html; charset=utf-8'
            continue
        }
        if ($request.HttpMethod -eq 'GET' -and $path -eq '/admin/staff') {
            $html = Get-Content -Path (Join-Path $PSScriptRoot 'staff-admin.html') -Raw -Encoding UTF8
            Send-Response $context 200 $html 'text/html; charset=utf-8'
            continue
        }

        if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/status') {
            $store = Read-Reservations
            Send-Json $context 200 @{ taken = @($store.reservations | ForEach-Object { $_.colorId }) }
            continue
        }

        if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/admin/setup-status') {
            Send-Json $context 200 @{ configured = [bool]$adminHash }
            continue
        }

        if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/admin/register') {
            if ($adminHash) {
                Send-Json $context 409 @{ error = 'registration_closed' }
                continue
            }
            $body = Read-Json $request
            $username = ([string]$body.username).Trim()
            $password = [string]$body.password
            if ($username.Length -lt 3 -or $username.Length -gt 80 -or $password.Length -lt 12 -or $password.Length -gt 256) {
                Send-Json $context 400 @{ error = 'invalid_credentials' }
                continue
            }
            $saltBytes = New-Object byte[] 16
            [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($saltBytes)
            $adminUsername = $username
            $adminSalt = [Convert]::ToBase64String($saltBytes)
            $adminHash = Get-PasswordHash $password $saltBytes
            Save-AdminCredentials
            $token = [Guid]::NewGuid().ToString('N')
            $sessions[$token] = 'admin'
            Send-Json $context 201 @{ token = $token }
            continue
        }

        if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/admin/login') {
            $body = Read-Json $request
            if (-not (Test-AdminPassword ([string]$body.username) ([string]$body.password))) {
                Send-Json $context 401 @{ error = 'invalid_login' }
                continue
            }
            $token = [Guid]::NewGuid().ToString('N')
            $sessions[$token] = 'admin'
            Send-Json $context 200 @{ token = $token }
            continue
        }

        if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/staff/login') {
            $body = Read-Json $request
            if (-not (Test-StaffPassword ([string]$body.username) ([string]$body.password))) {
                Send-Json $context 401 @{ error = 'invalid_login' }
                continue
            }
            $token = [Guid]::NewGuid().ToString('N')
            $sessions[$token] = 'staff'
            Send-Json $context 200 @{ token = $token }
            continue
        }

        if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/staff/setup-status') {
            Send-Json $context 200 @{ configured = [bool]$staffHash }
            continue
        }

        if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/staff/reservations') {
            $authorization = $request.Headers['Authorization']
            $token = if ($authorization -match '^Bearer (.+)$') { $Matches[1] } else { '' }
            if (-not $sessions.ContainsKey($token) -or $sessions[$token] -ne 'staff') {
                Send-Json $context 401 @{ error = 'staff_login_required' }
                continue
            }
            $store = Read-Reservations
            Send-Json $context 200 @($store.reservations | Sort-Object createdAt -Descending)
            continue
        }

        if ($path -like '/api/admin/*' -or $path -eq '/api/admin/reservations') {
            $authorization = $request.Headers['Authorization']
            $token = if ($authorization -match '^Bearer (.+)$') { $Matches[1] } else { '' }
            if (-not $sessions.ContainsKey($token) -or $sessions[$token] -ne 'admin') {
                Send-Json $context 401 @{ error = 'login_required' }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/admin/staff-account') {
                $body = Read-Json $request
                $username = ([string]$body.username).Trim()
                $password = [string]$body.password
                if ($username.Length -lt 3 -or $username.Length -gt 80 -or $password.Length -lt 12 -or $password.Length -gt 256) {
                    Send-Json $context 400 @{ error = 'invalid_credentials' }
                    continue
                }
                $saltBytes = New-Object byte[] 16
                [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($saltBytes)
                $staffUsername = $username
                $staffSalt = [Convert]::ToBase64String($saltBytes)
                $staffHash = Get-PasswordHash $password $saltBytes
                Save-StaffCredentials
                Send-Json $context 200 @{ saved = $true; username = $staffUsername }
                continue
            }
            if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/admin/staff-account') {
                Send-Json $context 200 @{ configured = [bool]$staffHash; username = $staffUsername }
                continue
            }
            if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/admin/reservations') {
                $store = Read-Reservations
                $reservations = @($store.reservations | Sort-Object createdAt -Descending)
                Send-Json $context 200 $reservations
                continue
            }
            if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/admin/gmail-settings') {
                $settings = Read-GmailSettings
                $gmailAddress = if ($settings.recipient) { $settings.recipient } else { $settings.sender }
                Send-Json $context 200 @{ configured = [bool]$settings.encryptedPassword; gmailAddress = $gmailAddress; enabled = [bool]$settings.enabled }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/admin/gmail-settings') {
                $body = Read-Json $request
                $gmailAddress = ([string]$(if ($body.gmailAddress) { $body.gmailAddress } elseif ($body.recipient) { $body.recipient } else { $body.sender })).Trim()
                $enabled = [bool]$body.enabled
                $settings = Read-GmailSettings
                $appPassword = ([string]$body.appPassword).Replace(' ', '').Trim()
                if ($enabled -and $gmailAddress -notmatch '^[^@\s]+@gmail\.com$') {
                    Send-Json $context 400 @{ error = 'invalid_email' }
                    continue
                }
                if ($enabled -and -not $appPassword -and -not $settings.encryptedPassword) {
                    Send-Json $context 400 @{ error = 'app_password_required' }
                    continue
                }
                if ($enabled -and $appPassword.Length -gt 0) {
                    $settings.encryptedPassword = Protect-GmailPassword $appPassword
                }
                $settings.sender = $gmailAddress
                $settings.recipient = $gmailAddress
                $settings.enabled = $enabled
                Write-GmailSettings $settings
                Send-Json $context 200 @{ configured = [bool]$settings.encryptedPassword; enabled = [bool]$settings.enabled }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/admin/gmail-test') {
                $settings = Read-GmailSettings
                if (-not $settings.enabled -or -not $settings.encryptedPassword) {
                    Send-Json $context 400 @{ error = 'gmail_not_configured' }
                    continue
                }
                try {
                    Send-GmailMessage $settings 'Color chart test notification' 'Gmail notification setup succeeded. New color reservations will trigger email notifications.'
                    Send-Json $context 200 @{ sent = $true }
                } catch {
                    Write-Host 'Gmail test message failed.' -ForegroundColor Yellow
                    Send-Json $context 502 @{ error = 'gmail_send_failed' }
                }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/admin/password') {
                $body = Read-Json $request
                $currentPassword = [string]$body.currentPassword
                $newPassword = [string]$body.newPassword
                if (-not (Test-AdminPassword $adminUsername $currentPassword)) {
                    Send-Json $context 400 @{ error = 'invalid_current_password' }
                    continue
                }
                if ($newPassword.Length -lt 12 -or $newPassword.Length -gt 256) {
                    Send-Json $context 400 @{ error = 'invalid_new_password' }
                    continue
                }
                $saltBytes = New-Object byte[] 16
                [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($saltBytes)
                $adminSalt = [Convert]::ToBase64String($saltBytes)
                $adminHash = Get-PasswordHash $newPassword $saltBytes
                Save-AdminCredentials
                Send-Json $context 200 @{ changed = $true }
                continue
            }
        }

        if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/reservations') {
            $body = Read-Json $request
            $colorId = [string]$body.colorId
            $claimant = ([string]$(if ($body.nickname) { $body.nickname } else { $body.claimant })).Trim()
            $contact = ([string]$(if ($body.email) { $body.email } else { $body.contact })).Trim()
            $validEmail = $false
            try { $validEmail = ([System.Net.Mail.MailAddress]::new($contact)).Address -ceq $contact } catch { }
            if ($colorId -notmatch '^(yellow|orange|red|pink|brown|brick|cyan|blue|navy|purple|lavender|teal)-(\d+-){3}\d+$' -or [string]::IsNullOrWhiteSpace($claimant) -or $claimant.Length -gt 60 -or $contact.Length -gt 120 -or -not $validEmail) {
                Send-Json $context 400 @{ error = 'invalid_request' }
                continue
            }
            $store = Read-Reservations
            $reservations = @($store.reservations)
            if ($reservations | Where-Object { $_.colorId -eq $colorId }) {
                Send-Json $context 409 @{ error = 'already_taken' }
                continue
            }
            $parts = $colorId -split '-'
            $categoryId = $parts[0]
            $cmyk = @([int]$parts[1], [int]$parts[2], [int]$parts[3], [int]$parts[4])
            $group = if ($categoryId -in @('yellow', 'orange', 'red', 'pink', 'brown', 'brick')) { 'warm' } else { 'cool' }
            $red = [int][Math]::Round(255 * (1 - $cmyk[0] / 100) * (1 - $cmyk[3] / 100))
            $green = [int][Math]::Round(255 * (1 - $cmyk[1] / 100) * (1 - $cmyk[3] / 100))
            $blue = [int][Math]::Round(255 * (1 - $cmyk[2] / 100) * (1 - $cmyk[3] / 100))
            $rgb = @($red, $green, $blue)
            $hex = '#' + (($rgb | ForEach-Object { $_.ToString('x2') }) -join '')
            $record = [PSCustomObject]@{ colorId = $colorId; categoryId = $categoryId; group = $group; cmyk = $cmyk; hex = $hex; claimant = $claimant; contact = $contact; createdAt = [DateTime]::UtcNow.ToString('o') }
            Write-Reservations (@($reservations) + @($record))
            $gmailSettings = Read-GmailSettings
            $notificationSent = $false
            if ($gmailSettings.enabled -and $gmailSettings.encryptedPassword) {
                $categoryNames = @{ yellow='Yellow'; orange='Orange'; red='Red'; pink='Pink'; brown='Brown'; brick='Warm brown'; cyan='Cyan'; blue='Blue'; navy='Navy'; purple='Purple'; lavender='Lavender'; teal='Teal' }
                $mailBody = "A new color reservation was made.`r`n`r`nColor: $($categoryNames[$categoryId])`r`nCMYK: C$($cmyk[0]) M$($cmyk[1]) Y$($cmyk[2]) K$($cmyk[3])`r`nNickname: $claimant`r`nEmail: $contact`r`nTime (UTC): $($record.createdAt)"
                try {
                    Send-GmailMessage $gmailSettings 'New color reservation' $mailBody
                    $notificationSent = $true
                } catch {
                    Write-Host 'Gmail reservation notification failed; reservation was saved.' -ForegroundColor Yellow
                }
            }
            Send-Json $context 201 @{ colorId = $colorId; notificationConfigured = [bool]$gmailSettings.enabled; notificationSent = $notificationSent }
            continue
        }

        Send-Json $context 404 @{ error = 'not_found' }
    } catch {
        Write-Host "Request error: $($_.Exception.Message)" -ForegroundColor Red
        if ($context -and $context.Response.OutputStream.CanWrite) {
            try { Send-Json $context 500 @{ error = 'server_error' } } catch { }
        }
    }
}