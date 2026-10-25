param(
    [int]$Port = 8765,
    [string]$ListenAddress = 'http://localhost'
)

$ErrorActionPreference = 'Stop'
$dataDirectory = Join-Path $PSScriptRoot 'data'
$dataFile = Join-Path $dataDirectory 'reservations.json'
$credentialFile = Join-Path $dataDirectory 'admin-credentials.json'
$staffCredentialFile = Join-Path $dataDirectory 'staff-credentials.json'
$customerCredentialFile = Join-Path $dataDirectory 'customer-credentials.json'
$gmailSettingsFile = Join-Path $dataDirectory 'gmail-settings.json'
$ownerUsername = 'a0985577822@gmail.com'
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
$rememberedSessions = @{}
$sessionsFile = Join-Path $dataDirectory 'remembered-sessions.dat'
$staffRecoveryRequestTimes = @{}
$customerVerificationCodes = @{}
$customerVerificationRequestTimes = @{}
$customerAccounts = @{}
if (Test-Path $customerCredentialFile) {
    $savedCustomerCredentials = Get-Content -Path $customerCredentialFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($account in @($savedCustomerCredentials.accounts)) {
        $customerAccounts[[string]$account.email] = $account
    }
}
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

function Send-GmailMessage($Settings, [string]$Subject, [string]$Body, [string]$Recipient = '') {
    $appPassword = Unprotect-GmailPassword $Settings.encryptedPassword
    $message = [System.Net.Mail.MailMessage]::new()
    $client = [System.Net.Mail.SmtpClient]::new('smtp.gmail.com', 587)
    try {
        $message.From = [System.Net.Mail.MailAddress]::new($Settings.sender)
        $destination = if ($Recipient) { $Recipient } else { [string]$Settings.recipient }
        $message.To.Add([System.Net.Mail.MailAddress]::new($destination))
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

function Get-CancellationCodeHash([string]$Email, [string]$Code, [string]$Salt) {
    $bytes = [Text.Encoding]::UTF8.GetBytes("$Email`n$Code`n$Salt")
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToBase64String($sha.ComputeHash($bytes)) } finally { $sha.Dispose() }
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

function Test-CustomerPassword([string]$Email, [string]$Password) {
    if (-not $customerAccounts.ContainsKey($Email)) { return $false }
    $account = $customerAccounts[$Email]
    $salt = [Convert]::FromBase64String([string]$account.salt)
    return [string]::Equals((Get-PasswordHash $Password $salt), [string]$account.hash, [StringComparison]::Ordinal)
}

function Save-CustomerCredentials {
    $temporaryFile = "$customerCredentialFile.tmp"
    ConvertTo-Json -InputObject @{ accounts = @($customerAccounts.Values) } -Depth 6 | Set-Content -Path $temporaryFile -Encoding UTF8
    Move-Item -Path $temporaryFile -Destination $customerCredentialFile -Force
}

function Save-RememberedSessions {
    $json = ConvertTo-Json -InputObject @{ sessions = @($rememberedSessions.Values) } -Depth 5 -Compress
    $plainBytes = [Text.Encoding]::UTF8.GetBytes($json)
    $entropy = [Text.Encoding]::UTF8.GetBytes('ColorChart.RememberedSessions.v1')
    $encrypted = [Security.Cryptography.ProtectedData]::Protect($plainBytes, $entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    $temporaryFile = "$sessionsFile.tmp"
    [Convert]::ToBase64String($encrypted) | Set-Content -Path $temporaryFile -Encoding ASCII
    Move-Item -Path $temporaryFile -Destination $sessionsFile -Force
}

function Restore-RememberedSessions {
    if (-not (Test-Path $sessionsFile)) { return }
    try {
        $encrypted = [Convert]::FromBase64String((Get-Content -Path $sessionsFile -Raw -Encoding ASCII).Trim())
        $entropy = [Text.Encoding]::UTF8.GetBytes('ColorChart.RememberedSessions.v1')
        $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect($encrypted, $entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        $saved = ConvertFrom-Json -InputObject ([Text.Encoding]::UTF8.GetString($plainBytes))
        foreach ($record in @($saved.sessions)) {
            if ([DateTime]::Parse([string]$record.expiresAt).ToUniversalTime() -gt [DateTime]::UtcNow) {
                $sessions[[string]$record.token] = [string]$record.value
                $rememberedSessions[[string]$record.token] = $record
            }
        }
    } catch {
        Write-Host 'Remembered sign-in data could not be restored; sign in again.' -ForegroundColor Yellow
    }
}

function New-Session([string]$Value, [bool]$Remember = $false) {
    $token = [Guid]::NewGuid().ToString('N')
    $sessions[$token] = $Value
    if ($Remember) {
        $record = [PSCustomObject]@{ token = $token; value = $Value; expiresAt = [DateTime]::UtcNow.AddDays(30).ToString('o') }
        $rememberedSessions[$token] = $record
        Save-RememberedSessions
    }
    return $token
}

function Get-SessionValue([string]$Token) {
    if (-not $Token -or -not $sessions.ContainsKey($Token)) { return '' }
    if ($rememberedSessions.ContainsKey($Token) -and [DateTime]::Parse([string]$rememberedSessions[$Token].expiresAt).ToUniversalTime() -le [DateTime]::UtcNow) {
        [void]$sessions.Remove($Token)
        [void]$rememberedSessions.Remove($Token)
        Save-RememberedSessions
        return ''
    }
    return [string]$sessions[$Token]
}

function Remove-Session([string]$Token) {
    [void]$sessions.Remove($Token)
    if ($rememberedSessions.ContainsKey($Token)) {
        [void]$rememberedSessions.Remove($Token)
        Save-RememberedSessions
    }
}

function Remove-SessionsForValue([string]$Value) {
    foreach ($sessionToken in @($sessions.Keys)) {
        if ($sessions[$sessionToken] -eq $Value) { Remove-Session $sessionToken }
    }
}

Restore-RememberedSessions

while ($listener.IsListening) {
    foreach ($sessionToken in @($rememberedSessions.Keys)) {
        if ([DateTime]::Parse([string]$rememberedSessions[$sessionToken].expiresAt).ToUniversalTime() -le [DateTime]::UtcNow) {
            Remove-Session $sessionToken
        }
    }
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
        if ($request.HttpMethod -eq 'GET' -and $path -eq '/account') {
            $html = Get-Content -Path (Join-Path $PSScriptRoot 'account.html') -Raw -Encoding UTF8
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

        if ($request.HttpMethod -eq 'POST' -and $path -in @('/api/customer/register-code', '/api/customer/recovery-code')) {
            $body = Read-Json $request
            $email = ([string]$body.email).Trim().ToLowerInvariant()
            $purpose = if ($path -eq '/api/customer/register-code') { 'register' } else { 'recovery' }
            $key = "$purpose|$email"
            if ($email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
                Send-Json $context 400 @{ error = 'invalid_email' }
                continue
            }
            if ($purpose -eq 'register' -and $customerAccounts.ContainsKey($email)) {
                Send-Json $context 409 @{ error = 'account_exists' }
                continue
            }
            if ($purpose -eq 'recovery' -and -not $customerAccounts.ContainsKey($email)) {
                Send-Json $context 202 @{ sent = $true }
                continue
            }
            $settings = Read-GmailSettings
            if (-not $settings.enabled -or -not $settings.encryptedPassword) {
                Send-Json $context 503 @{ error = 'email_unavailable' }
                continue
            }
            if ($customerVerificationRequestTimes.ContainsKey($key) -and [DateTime]::UtcNow -lt $customerVerificationRequestTimes[$key]) {
                Send-Json $context 202 @{ sent = $true }
                continue
            }
            $randomBytes = New-Object byte[] 4
            [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($randomBytes)
            $code = '{0:D6}' -f ([BitConverter]::ToUInt32($randomBytes, 0) % 1000000)
            $saltBytes = New-Object byte[] 16
            [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($saltBytes)
            $salt = [Convert]::ToBase64String($saltBytes)
            $subject = if ($purpose -eq 'register') { 'Color chart account verification' } else { 'Color chart password reset code' }
            $message = if ($purpose -eq 'register') { "Your verification code is $code. It expires in 10 minutes." } else { "Your password reset code is $code. It expires in 10 minutes." }
            try {
                Send-GmailMessage $settings $subject $message $email
                $customerVerificationCodes[$key] = @{ hash = (Get-CancellationCodeHash $email $code $salt); salt = $salt; expiresAt = [DateTime]::UtcNow.AddMinutes(10); attempts = 0 }
                $customerVerificationRequestTimes[$key] = [DateTime]::UtcNow.AddSeconds(60)
                Send-Json $context 202 @{ sent = $true }
            } catch {
                $mailException = $_.Exception
                while ($mailException.InnerException) { $mailException = $mailException.InnerException }
                Write-Host ("Customer verification email failed: {0}" -f $mailException.Message) -ForegroundColor Yellow
                Send-Json $context 502 @{ error = 'email_send_failed' }
            }
            continue
        }

        if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/customer/register') {
            $body = Read-Json $request
            $email = ([string]$body.email).Trim().ToLowerInvariant()
            $nickname = ([string]$body.nickname).Trim()
            $password = [string]$body.password
            $code = ([string]$body.code).Trim()
            $key = "register|$email"
            if ($customerAccounts.ContainsKey($email)) {
                Send-Json $context 409 @{ error = 'account_exists' }
                continue
            }
            if ($nickname.Length -lt 1 -or $nickname.Length -gt 60 -or $password.Length -lt 12 -or $password.Length -gt 256 -or $email -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
                Send-Json $context 400 @{ error = 'invalid_credentials' }
                continue
            }
            if (-not $customerVerificationCodes.ContainsKey($key)) {
                Send-Json $context 400 @{ error = 'invalid_or_expired_code' }
                continue
            }
            $verification = $customerVerificationCodes[$key]
            if ([DateTime]::UtcNow -gt $verification.expiresAt -or -not [string]::Equals((Get-CancellationCodeHash $email $code $verification.salt), $verification.hash, [StringComparison]::Ordinal)) {
                $verification.attempts++
                if ($verification.attempts -ge 5) { [void]$customerVerificationCodes.Remove($key) }
                Send-Json $context 400 @{ error = 'invalid_or_expired_code' }
                continue
            }
            $saltBytes = New-Object byte[] 16
            [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($saltBytes)
            $salt = [Convert]::ToBase64String($saltBytes)
            $account = [PSCustomObject]@{ email = $email; nickname = $nickname; salt = $salt; hash = (Get-PasswordHash $password $saltBytes); createdAt = [DateTime]::UtcNow.ToString('o') }
            $customerAccounts[$email] = $account
            Save-CustomerCredentials
            [void]$customerVerificationCodes.Remove($key)
            [void]$customerVerificationRequestTimes.Remove($key)
            $token = New-Session "customer:$email" ([bool]$body.remember)
            Send-Json $context 201 @{ token = $token; email = $email; nickname = $nickname }
            continue
        }

        if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/customer/login') {
            $body = Read-Json $request
            $email = ([string]$body.email).Trim().ToLowerInvariant()
            if (-not (Test-CustomerPassword $email ([string]$body.password))) {
                Send-Json $context 401 @{ error = 'invalid_login' }
                continue
            }
            $account = $customerAccounts[$email]
            $token = New-Session "customer:$email" ([bool]$body.remember)
            Send-Json $context 200 @{ token = $token; email = $email; nickname = $account.nickname }
            continue
        }

        if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/customer/reset-password') {
            $body = Read-Json $request
            $email = ([string]$body.email).Trim().ToLowerInvariant()
            $code = ([string]$body.code).Trim()
            $password = [string]$body.password
            $key = "recovery|$email"
            if ($password.Length -lt 12 -or $password.Length -gt 256 -or -not $customerAccounts.ContainsKey($email)) {
                Send-Json $context 400 @{ error = 'invalid_request' }
                continue
            }
            if (-not $customerVerificationCodes.ContainsKey($key)) {
                Send-Json $context 400 @{ error = 'invalid_or_expired_code' }
                continue
            }
            $verification = $customerVerificationCodes[$key]
            if ([DateTime]::UtcNow -gt $verification.expiresAt -or -not [string]::Equals((Get-CancellationCodeHash $email $code $verification.salt), $verification.hash, [StringComparison]::Ordinal)) {
                $verification.attempts++
                if ($verification.attempts -ge 5) { [void]$customerVerificationCodes.Remove($key) }
                Send-Json $context 400 @{ error = 'invalid_or_expired_code' }
                continue
            }
            $account = $customerAccounts[$email]
            $saltBytes = New-Object byte[] 16
            [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($saltBytes)
            $account.salt = [Convert]::ToBase64String($saltBytes)
            $account.hash = Get-PasswordHash $password $saltBytes
            Save-CustomerCredentials
            [void]$customerVerificationCodes.Remove($key)
            [void]$customerVerificationRequestTimes.Remove($key)
            Remove-SessionsForValue "customer:$email"
            Send-Json $context 200 @{ reset = $true }
            continue
        }

        if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/customer/me') {
            $authorization = $request.Headers['Authorization']
            $token = if ($authorization -match '^Bearer (.+)$') { $Matches[1] } else { '' }
            if (-not $sessions.ContainsKey($token) -or $sessions[$token] -notlike 'customer:*') {
                Send-Json $context 401 @{ error = 'customer_login_required' }
                continue
            }
            $email = $sessions[$token].Substring(9)
            $account = $customerAccounts[$email]
            Send-Json $context 200 @{ email = $account.email; nickname = $account.nickname }
            continue
        }

        if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/customer/logout') {
            $authorization = $request.Headers['Authorization']
            $token = if ($authorization -match '^Bearer (.+)$') { $Matches[1] } else { '' }
            if (-not $sessions.ContainsKey($token) -or $sessions[$token] -notlike 'customer:*') {
                Send-Json $context 401 @{ error = 'customer_login_required' }
                continue
            }
            Remove-Session $token
            Send-Json $context 200 @{ loggedOut = $true }
            continue
        }

        if ($path -in @('/api/customer/reservation', '/api/customer/reservation/cancel')) {
            $authorization = $request.Headers['Authorization']
            $customerToken = if ($authorization -match '^Bearer (.+)$') { $Matches[1] } else { '' }
            if (-not $sessions.ContainsKey($customerToken) -or $sessions[$customerToken] -notlike 'customer:*') {
                Send-Json $context 401 @{ error = 'customer_login_required' }
                continue
            }
            $customerEmail = $sessions[$customerToken].Substring(9)
            $store = Read-Reservations
            $reservation = $store.reservations | Where-Object { ([string]$_.contact).Trim().ToLowerInvariant() -eq $customerEmail } | Select-Object -First 1
            if ($request.HttpMethod -eq 'GET' -and $path -eq '/api/customer/reservation') {
                Send-Json $context 200 @{ reservation = $reservation }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/customer/reservation/cancel') {
                if (-not $reservation) {
                    Send-Json $context 404 @{ error = 'reservation_not_found' }
                    continue
                }
                $remaining = @($store.reservations | Where-Object { ([string]$_.contact).Trim().ToLowerInvariant() -ne $customerEmail })
                Write-Reservations $remaining
                $settings = Read-GmailSettings
                if ($settings.enabled -and $settings.encryptedPassword) {
                    try { Send-GmailMessage $settings 'Reservation cancelled' 'Your reservation has been cancelled. The color is available again.' $customerEmail } catch { Write-Host 'Customer cancellation notice failed.' -ForegroundColor Yellow }
                }
                Send-Json $context 200 @{ cancelled = $true; colorId = $reservation.colorId }
                continue
            }
        }

        if ($path -in @('/api/customer/profile', '/api/customer/change-password')) {
            $authorization = $request.Headers['Authorization']
            $customerToken = if ($authorization -match '^Bearer (.+)$') { $Matches[1] } else { '' }
            if (-not $sessions.ContainsKey($customerToken) -or $sessions[$customerToken] -notlike 'customer:*') {
                Send-Json $context 401 @{ error = 'customer_login_required' }
                continue
            }
            $customerEmail = $sessions[$customerToken].Substring(9)
            $account = $customerAccounts[$customerEmail]
            $body = Read-Json $request
            if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/customer/profile') {
                $nickname = ([string]$body.nickname).Trim()
                if ($nickname.Length -lt 1 -or $nickname.Length -gt 60) {
                    Send-Json $context 400 @{ error = 'invalid_nickname' }
                    continue
                }
                $account.nickname = $nickname
                Save-CustomerCredentials
                Send-Json $context 200 @{ email = $customerEmail; nickname = $nickname }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/customer/change-password') {
                $currentPassword = [string]$body.currentPassword
                $newPassword = [string]$body.newPassword
                if (-not (Test-CustomerPassword $customerEmail $currentPassword)) {
                    Send-Json $context 400 @{ error = 'invalid_current_password' }
                    continue
                }
                if ($newPassword.Length -lt 12 -or $newPassword.Length -gt 256) {
                    Send-Json $context 400 @{ error = 'invalid_new_password' }
                    continue
                }
                $saltBytes = New-Object byte[] 16
                [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($saltBytes)
                $account.salt = [Convert]::ToBase64String($saltBytes)
                $account.hash = Get-PasswordHash $newPassword $saltBytes
                Save-CustomerCredentials
                foreach ($sessionToken in @($sessions.Keys)) {
                    if ($sessionToken -ne $customerToken -and $sessions[$sessionToken] -eq "customer:$customerEmail") { Remove-Session $sessionToken }
                }
                Send-Json $context 200 @{ changed = $true }
                continue
            }
        }

        if ($path -in @('/api/customer/change-email-code', '/api/customer/change-email')) {
            $authorization = $request.Headers['Authorization']
            $customerToken = if ($authorization -match '^Bearer (.+)$') { $Matches[1] } else { '' }
            if (-not $sessions.ContainsKey($customerToken) -or $sessions[$customerToken] -notlike 'customer:*') {
                Send-Json $context 401 @{ error = 'customer_login_required' }
                continue
            }
            $oldEmail = $sessions[$customerToken].Substring(9)
            $body = Read-Json $request
            $newEmail = ([string]$body.email).Trim().ToLowerInvariant()
            $codeKey = "email-change|$oldEmail|$newEmail"
            if ($newEmail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
                Send-Json $context 400 @{ error = 'invalid_email' }
                continue
            }
            if ($customerAccounts.ContainsKey($newEmail)) {
                Send-Json $context 409 @{ error = 'email_in_use' }
                continue
            }
            $store = Read-Reservations
            if ($store.reservations | Where-Object { ([string]$_.contact).Trim().ToLowerInvariant() -eq $newEmail }) {
                Send-Json $context 409 @{ error = 'email_has_reservation' }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/customer/change-email-code') {
                $settings = Read-GmailSettings
                if (-not $settings.enabled -or -not $settings.encryptedPassword) {
                    Send-Json $context 503 @{ error = 'email_unavailable' }
                    continue
                }
                if ($customerVerificationRequestTimes.ContainsKey($codeKey) -and [DateTime]::UtcNow -lt $customerVerificationRequestTimes[$codeKey]) {
                    Send-Json $context 202 @{ sent = $true }
                    continue
                }
                $randomBytes = New-Object byte[] 4
                [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($randomBytes)
                $code = '{0:D6}' -f ([BitConverter]::ToUInt32($randomBytes, 0) % 1000000)
                $saltBytes = New-Object byte[] 16
                [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($saltBytes)
                $salt = [Convert]::ToBase64String($saltBytes)
                try {
                    Send-GmailMessage $settings 'Email change verification code' "Your email change verification code is $code. It expires in 10 minutes." $newEmail
                    $customerVerificationCodes[$codeKey] = @{ hash = (Get-CancellationCodeHash $newEmail $code $salt); salt = $salt; expiresAt = [DateTime]::UtcNow.AddMinutes(10); attempts = 0 }
                    $customerVerificationRequestTimes[$codeKey] = [DateTime]::UtcNow.AddSeconds(60)
                    Send-Json $context 202 @{ sent = $true }
                } catch {
                    Write-Host 'Customer email-change verification failed.' -ForegroundColor Yellow
                    Send-Json $context 502 @{ error = 'email_send_failed' }
                }
                continue
            }
            if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/customer/change-email') {
                $code = ([string]$body.code).Trim()
                if (-not $customerVerificationCodes.ContainsKey($codeKey)) {
                    Send-Json $context 400 @{ error = 'invalid_or_expired_code' }
                    continue
                }
                $verification = $customerVerificationCodes[$codeKey]
                if ([DateTime]::UtcNow -gt $verification.expiresAt -or -not [string]::Equals((Get-CancellationCodeHash $newEmail $code $verification.salt), $verification.hash, [StringComparison]::Ordinal)) {
                    $verification.attempts++
                    if ($verification.attempts -ge 5) { [void]$customerVerificationCodes.Remove($codeKey) }
                    Send-Json $context 400 @{ error = 'invalid_or_expired_code' }
                    continue
                }
                $rememberCurrentSession = $rememberedSessions.ContainsKey($customerToken)
                $account = $customerAccounts[$oldEmail]
                [void]$customerAccounts.Remove($oldEmail)
                $account.email = $newEmail
                $customerAccounts[$newEmail] = $account
                foreach ($reservation in $store.reservations) {
                    if (([string]$reservation.contact).Trim().ToLowerInvariant() -eq $oldEmail) { $reservation.contact = $newEmail }
                }
                Write-Reservations $store.reservations
                Save-CustomerCredentials
                [void]$customerVerificationCodes.Remove($codeKey)
                [void]$customerVerificationRequestTimes.Remove($codeKey)
                Remove-SessionsForValue "customer:$oldEmail"
                $newToken = New-Session "customer:$newEmail" $rememberCurrentSession
                Send-Json $context 200 @{ token = $newToken; email = $newEmail; nickname = $account.nickname }
                continue
            }
        }

        if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/admin/register') {
            if ($adminHash) {
                Send-Json $context 409 @{ error = 'registration_closed' }
                continue
            }
            $body = Read-Json $request
            $username = ([string]$body.username).Trim()
            $password = [string]$body.password
            if (-not [string]::Equals($username, $ownerUsername, [StringComparison]::OrdinalIgnoreCase)) {
                Send-Json $context 403 @{ error = 'owner_account_only' }
                continue
            }
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
            $token = New-Session 'staff' ([bool]$body.remember)
            Send-Json $context 200 @{ token = $token }
            continue
        }

        if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/staff/logout') {
            $authorization = $request.Headers['Authorization']
            $token = if ($authorization -match '^Bearer (.+)$') { $Matches[1] } else { '' }
            if ((Get-SessionValue $token) -ne 'staff') {
                Send-Json $context 401 @{ error = 'staff_login_required' }
                continue
            }
            Remove-Session $token
            Send-Json $context 200 @{ loggedOut = $true }
            continue
        }

        if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/staff/forgot') {
            $body = Read-Json $request
            $username = ([string]$body.username).Trim()
            $key = $username.ToLowerInvariant()
            if ($staffRecoveryRequestTimes.ContainsKey($key) -and [DateTime]::UtcNow -lt $staffRecoveryRequestTimes[$key]) {
                Send-Json $context 202 @{ sent = $true }
                continue
            }
            $staffRecoveryRequestTimes[$key] = [DateTime]::UtcNow.AddSeconds(60)
            $settings = Read-GmailSettings
            if (-not $settings.enabled -or -not $settings.encryptedPassword) {
                Send-Json $context 503 @{ error = 'notification_unavailable' }
                continue
            }
            if ($staffHash -and [string]::Equals($username, $staffUsername, [StringComparison]::OrdinalIgnoreCase)) {
                try {
                    Send-GmailMessage $settings 'Staff account reset request' "A staff member requested a shared-account password reset. Account: $staffUsername. Please review and update it in the admin panel."
                } catch {
                    Write-Host 'Staff password reset notification failed.' -ForegroundColor Yellow
                    Send-Json $context 502 @{ error = 'notification_failed' }
                    continue
                }
            }
            Send-Json $context 202 @{ sent = $true }
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
            if ($path -eq '/api/admin/staff-account' -and -not [string]::Equals($adminUsername, $ownerUsername, [StringComparison]::OrdinalIgnoreCase)) {
                Send-Json $context 403 @{ error = 'owner_account_only' }
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
                foreach ($sessionToken in @($sessions.Keys)) {
                    if ($sessions[$sessionToken] -eq 'staff') { Remove-Session $sessionToken }
                }
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
            if ($request.HttpMethod -eq 'POST' -and $path -eq '/api/admin/reservations/cancel') {
                $body = Read-Json $request
                $colorId = [string]$body.colorId
                $store = Read-Reservations
                $cancelled = @($store.reservations | Where-Object { $_.colorId -eq $colorId })
                if (-not $cancelled.Count) {
                    Send-Json $context 404 @{ error = 'reservation_not_found' }
                    continue
                }
                $remaining = @($store.reservations | Where-Object { $_.colorId -ne $colorId })
                Write-Reservations $remaining
                $email = ([string]$cancelled[0].contact).Trim().ToLowerInvariant()
                if ($email) {
                    $settings = Read-GmailSettings
                    if ($settings.enabled -and $settings.encryptedPassword) {
                        try { Send-GmailMessage $settings 'Reservation cancelled' 'Your color reservation has been cancelled by the administrator. The color is available again.' $email } catch { Write-Host 'Administrator cancellation email failed.' -ForegroundColor Yellow }
                    }
                }
                Send-Json $context 200 @{ cancelled = $true; colorId = $colorId }
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
                    $mailException = $_.Exception
                    while ($mailException.InnerException) { $mailException = $mailException.InnerException }
                    Write-Host ("Gmail test message failed: {0}" -f $mailException.Message) -ForegroundColor Yellow
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
            $authorization = $request.Headers['Authorization']
            $customerToken = if ($authorization -match '^Bearer (.+)$') { $Matches[1] } else { '' }
            if (-not $sessions.ContainsKey($customerToken) -or $sessions[$customerToken] -notlike 'customer:*') {
                Send-Json $context 401 @{ error = 'customer_login_required' }
                continue
            }
            $customerEmail = $sessions[$customerToken].Substring(9)
            $customerAccount = $customerAccounts[$customerEmail]
            $body = Read-Json $request
            $colorId = [string]$body.colorId
            $claimant = [string]$customerAccount.nickname
            $contact = [string]$customerAccount.email
            $validEmail = $false
            try { $validEmail = ([System.Net.Mail.MailAddress]::new($contact)).Address -ceq $contact } catch { }
            if ($colorId -notmatch '^(yellow|orange|red|pink|brown|brick|cyan|blue|navy|purple|lavender|teal)-(\d+-){3}\d+$' -or [string]::IsNullOrWhiteSpace($claimant) -or $claimant.Length -gt 60 -or $contact.Length -gt 120 -or -not $validEmail) {
                Send-Json $context 400 @{ error = 'invalid_request' }
                continue
            }
            $store = Read-Reservations
            $reservations = @($store.reservations)
            if ($reservations | Where-Object { ([string]$_.contact).Trim().ToLowerInvariant() -eq $contact.ToLowerInvariant() }) {
                Send-Json $context 409 @{ error = 'email_already_reserved' }
                continue
            }
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
                    $mailException = $_.Exception
                    while ($mailException.InnerException) { $mailException = $mailException.InnerException }
                    Write-Host ("Gmail notification failed; reservation was saved: {0}" -f $mailException.Message) -ForegroundColor Yellow
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