# UniFi Troubleshooter 1.0.2 - https://ihavenoram.com - https://github.com/ihavenoram/unifi-troubleshooter
# MIT licence, (c) 2026 ihavenoram.com. If you publish something built on this, please credit ihavenoram.com.
<#
.SYNOPSIS
    UniFi Layer-3 Adoption & Controller Reachability Troubleshooter - technician GUI.

.DESCRIPTION
    Single-file Windows Forms tool for diagnosing UniFi devices that have lost
    adoption or cannot reach a remote (Layer 3) controller.

    Built around a specific, recurring failure: a device that is powered off,
    comes back with its inform URL reset to the factory default
    http://unifi:8080/inform, and then cannot resolve that bare hostname because
    the site has no local DNS entry for it.

    Tabs:
      Diagnostics   - local network, DNS, controller port matrix, inform probe
      Find Devices  - ARP/OUI, ping sweep, and UDP 10001 Ubiquiti discovery
      SSH Commands  - copy/paste command blocks tailored to the selected device
      PuTTY         - download, verify and launch putty.exe / plink.exe
      Controller    - optional API login: device states and inform URLs
      Known Issues  - matched knowledge base + DHCP Option 43 generator
      Log           - transcript, saved as HTML or text

.NOTES
    Windows PowerShell 5.1. MUST run -STA; use Launch-UniFiTool.cmd.
    Designed for an interactive or ScreenConnect Backstage session.
    Read-only against the network unless you use the plink actions, which
    confirm before they change anything on a device.
#>

[CmdletBinding()]
param(
    [string]$ControllerHost = 'unifi.example.com',
    [int]   $InformPort     = 8080,
    [int]   $UiPort         = 8443,
    [string]$PortalUrl      = 'https://unifi.example.com:8443',
    [string]$UispUrl        = 'https://example.uisp.com/nms/sites',
    [string]$DeviceIp       = '',
    # 'ubnt' is the factory default, but the site's Device Authentication
    # settings can change it and 'admin' is a common override - so it is a
    # parameter rather than a constant.
    [string]$SshUser        = 'ubnt',
    [switch]$NoHideConsole
)

# $PSScriptRoot is empty inside param defaults when [CmdletBinding()] is used,
# so script-relative paths are resolved here in the body instead.
$scriptDir = $PSScriptRoot
if (-not $scriptDir) {
    # MyCommand.Path is null when this is dot-sourced from a scriptblock rather
    # than run as a file, and Split-Path throws on a null path rather than
    # returning nothing - so it is guarded instead of chained.
    try { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path } catch { }
}
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# --- WinForms first ---------------------------------------------------------
# Loaded BEFORE anything that might need to report a problem. An error handler
# that calls MessageBox while these assemblies are still unloaded fails with
# "Unable to find type [System.Windows.Forms.MessageBox]" - the handler breaks
# instead of the error being reported.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

function Show-UfStartupError {
    # Console AND dialog. Wherever WinForms will not draw, the console line is
    # the only thing that comes out.
    param([string]$Message)
    Write-Error $Message
    try {
        [System.Windows.Forms.MessageBox]::Show($Message, 'UniFi Troubleshooter', 'OK', 'Error') | Out-Null
    } catch { }
}

# --- Hide our own console window -------------------------------------------
# Deliberately NOT done with -WindowStyle Hidden on the launcher: that hides the
# FORM as well as the console, and the failure looks like the tool never
# started. Pass -NoHideConsole to keep the console for debugging.
if (-not $NoHideConsole) {
    try {
        Add-Type -Namespace UfWin -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@ -ErrorAction Stop
        $consoleHandle = [UfWin.Native]::GetConsoleWindow()
        if ($consoleHandle -ne [IntPtr]::Zero) { [void][UfWin.Native]::ShowWindow($consoleHandle, 0) }
    } catch { }
}

# --- Palette ----------------------------------------------------------------
# Named deliberately verbosely. Single-letter names get clobbered by any
# "foreach ($c in ...)" later in the file, and the result still launches, which
# makes it a genuinely nasty bug to find.
$UfColorBg      = [System.Drawing.Color]::FromArgb(250, 250, 252)
$UfColorPanel   = [System.Drawing.Color]::FromArgb(255, 255, 255)
$UfColorText    = [System.Drawing.Color]::FromArgb(24, 26, 32)
$UfColorMuted   = [System.Drawing.Color]::FromArgb(96, 102, 116)
$UfColorOk      = [System.Drawing.Color]::FromArgb(18, 122, 62)
$UfColorWarn    = [System.Drawing.Color]::FromArgb(176, 104, 8)
$UfColorFail    = [System.Drawing.Color]::FromArgb(178, 34, 42)
$UfColorInfo    = [System.Drawing.Color]::FromArgb(64, 82, 128)
$UfColorOkBg    = [System.Drawing.Color]::FromArgb(232, 246, 237)
$UfColorWarnBg  = [System.Drawing.Color]::FromArgb(253, 244, 227)
$UfColorFailBg  = [System.Drawing.Color]::FromArgb(253, 235, 236)
$UfColorInfoBg  = [System.Drawing.Color]::FromArgb(238, 242, 250)

$UfFontUi   = New-Object System.Drawing.Font('Segoe UI', 9)
$UfFontBold = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$UfFontHead = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Bold)
$UfFontMono = New-Object System.Drawing.Font('Consolas', 9)

function Get-UfStatusColor {
    param([string]$Status)
    switch ($Status) {
        'ok'      { return $UfColorOk }
        'warn'    { return $UfColorWarn }
        'fail'    { return $UfColorFail }
        'skipped' { return $UfColorMuted }
        default   { return $UfColorInfo }
    }
}

# =============================================================================
#UFHELPERS_BEGIN
# =============================================================================
# Everything between the two sentinel markers is pure logic - no UI, no
# script-scoped UI variables. The text of this region is extracted at startup
# and re-created inside each background runspace, because runspaces do not
# inherit the caller's function table.
# =============================================================================

function Get-UfNow { (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }

function New-UfCheck {
    # One row in the Diagnostics list. Status is ok|warn|fail|info|skipped.
    param(
        [string]$Check,
        [string]$Target = '',
        [string]$Status = 'info',
        [string]$Result = '',
        [string]$Detail = ''
    )
    [PSCustomObject]@{
        Check  = $Check
        Target = $Target
        Status = $Status
        Result = $Result
        Detail = $Detail
    }
}

function Format-UfMfgWeek {
    # The manufacture week comes back in one of two formats and they are not
    # interchangeable: /proc/ubnthal/system.info reports YYYYWW (202335), while
    # the Date Code printed on the device label is YYWW (2335). Anything else is
    # handed back untouched - a field we cannot read is not a field to guess at.
    param([string]$Value)
    $v = ([string]$Value).Trim()
    if (-not $v) { return '' }

    $year = 0
    $week = 0
    if ($v -match '^(\d{4})(\d{2})$')     { $year = [int]$Matches[1]; $week = [int]$Matches[2] }
    elseif ($v -match '^(\d{2})(\d{2})$') { $year = 2000 + [int]$Matches[1]; $week = [int]$Matches[2] }
    else { return $v }

    # Week 0 or 54+ means we have misread the format, not that the device was
    # built in a week that does not exist.
    if ($week -lt 1 -or $week -gt 53 -or $year -lt 2005 -or $year -gt 2100) { return $v }

    $age = ''
    try {
        # Approximate, and only ever used for the age: week 1 starts 1 January.
        # A day or two either way does not change an answer given in years.
        $built = ([datetime]::new($year, 1, 1)).AddDays(($week - 1) * 7)
        $years = ((Get-Date) - $built).TotalDays / 365.25
        if ($years -ge 0) { $age = (' ({0:N1} yr)' -f $years) }
    } catch { }

    return ('{0} - wk{1} {2}{3}' -f $v, $week, $year, $age)
}

function Format-UfUptime {
    param([int64]$Seconds)
    if ($Seconds -le 0) { return '' }
    $ts = [TimeSpan]::FromSeconds($Seconds)
    if ($ts.TotalDays -ge 1) { return ('{0}d {1}h {2}m' -f [int]$ts.Days, $ts.Hours, $ts.Minutes) }
    if ($ts.TotalHours -ge 1) { return ('{0}h {1}m' -f [int]$ts.Hours, $ts.Minutes) }
    return ('{0}m {1}s' -f [int]$ts.Minutes, $ts.Seconds)
}

function Enable-UfTls {
    # PS 5.1 does not negotiate TLS 1.2 by default, and the controller on 8443
    # presents a self-signed certificate. There is no -SkipCertificateCheck on
    # 5.1, so the validation callback has to do the work.
    #
    # The callback is a COMPILED delegate, not the usual { $true } scriptblock.
    # A scriptblock here fails with "There is no Runspace available to run
    # scripts in this thread": the TLS handshake completes on a threadpool
    # thread that has no runspace attached, so the scriptblock cannot execute
    # and the request dies as "The underlying connection was closed: An
    # unexpected error occurred on a send." That failure is worse inside a
    # background runspace, which is where most of this tool's work happens.
    try {
        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
    } catch { }

    if (-not ('UfCertTrust' -as [type])) {
        # Guarded: the helper region is re-loaded in every background runspace,
        # and Add-Type throws if the type is already in the AppDomain.
        try {
            Add-Type -TypeDefinition @'
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class UfCertTrust {
    public static bool Validate(object sender, X509Certificate cert, X509Chain chain, SslPolicyErrors errors) {
        return true;
    }
    public static RemoteCertificateValidationCallback Callback {
        get { return new RemoteCertificateValidationCallback(Validate); }
    }
}
'@ -ErrorAction Stop
        } catch { }
    }
    try {
        if ('UfCertTrust' -as [type]) {
            [Net.ServicePointManager]::ServerCertificateValidationCallback = [UfCertTrust]::Callback
        }
    } catch { }
}

function Invoke-UfCurlJson {
    # curl.exe uses Schannel and ignores all of the above, so it is the
    # fallback whenever the .NET stack will not talk to a self-signed
    # controller. Present in System32 on Win10 1803+ and Server 2019+.
    param([string]$Uri, [int]$TimeoutSec = 12)
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path -LiteralPath $curl)) { return '' }
    try {
        $out = & $curl -s -k --connect-timeout 8 --max-time $TimeoutSec $Uri 2>$null
        return ([string]($out -join ''))
    } catch { return '' }
}

# -----------------------------------------------------------------------------
# Local network and DNS
# -----------------------------------------------------------------------------

function Get-UfLocalNetwork {
    # One object per adapter that actually has a default gateway.
    $rows = [System.Collections.Generic.List[object]]::new()
    try {
        $cfgs = @(Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $null -ne $_.IPv4DefaultGateway })
        foreach ($cfg in $cfgs) {
            $dns = @()
            try {
                $dns = @((Get-DnsClientServerAddress -InterfaceIndex $cfg.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses)
            } catch { }
            $prefix = 24
            try {
                $ipObj = Get-NetIPAddress -InterfaceIndex $cfg.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop |
                         Where-Object { $_.IPAddress -eq $cfg.IPv4Address.IPAddress } | Select-Object -First 1
                if ($ipObj) { $prefix = [int]$ipObj.PrefixLength }
            } catch { }
            $rows.Add([PSCustomObject]@{
                Alias          = $cfg.InterfaceAlias
                InterfaceIndex = $cfg.InterfaceIndex
                IPAddress      = $cfg.IPv4Address.IPAddress
                PrefixLength   = $prefix
                Gateway        = $cfg.IPv4DefaultGateway.NextHop
                DnsServers     = $dns
            })
        }
    } catch { }
    return @($rows)
}

function Test-UfPrivateIp {
    param([string]$IpAddress)
    if (-not $IpAddress) { return $false }
    return ($IpAddress -match '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.|127\.)')
}

function Resolve-UfName {
    # Wraps Resolve-DnsName so a failure is data, not an exception. A bare
    # hostname that does not exist throws ERROR_INVALID_NAME rather than
    # returning nothing, which is exactly what happened to 'unifi' on site.
    param([string]$Name)
    $out = [PSCustomObject]@{ Name = $Name; Resolved = $false; Addresses = @(); Error = '' }
    if (-not $Name) { return $out }
    try {
        $ans = @(Resolve-DnsName -Name $Name -Type A -ErrorAction Stop | Where-Object { $_.IPAddress })
        if ($ans.Count -gt 0) {
            $out.Resolved  = $true
            $out.Addresses = @($ans | ForEach-Object { $_.IPAddress })
        } else {
            $out.Error = 'No A record returned'
        }
    } catch {
        $out.Error = $_.Exception.Message
    }
    return $out
}

function Get-UfHostsEntry {
    # A hosts-file override for 'unifi' on THIS PC helps the technician's
    # browser only - it does nothing for the AP. Reported for completeness.
    param([string]$Name = 'unifi')
    $path = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    $hits = [System.Collections.Generic.List[object]]::new()
    try {
        if (Test-Path -LiteralPath $path) {
            foreach ($line in (Get-Content -LiteralPath $path -ErrorAction Stop)) {
                $trim = $line.Trim()
                if (-not $trim -or $trim.StartsWith('#')) { continue }
                $parts = @($trim -split '\s+')
                if ($parts.Count -ge 2) {
                    for ($i = 1; $i -lt $parts.Count; $i++) {
                        if ($parts[$i] -eq $Name) { $hits.Add($trim); break }
                    }
                }
            }
        }
    } catch { }
    return @($hits)
}

function ConvertTo-UfOption43Hex {
    # UniFi controller address as DHCP option 43, sub-option 1:
    #   01 <length> <4 address bytes>
    param([string]$IpAddress)
    try {
        $parsed = [System.Net.IPAddress]::Parse($IpAddress)
        $b = $parsed.GetAddressBytes()
        if ($b.Length -ne 4) { return '' }
        $hex = @('01', '04') + @($b | ForEach-Object { '{0:X2}' -f $_ })
        return ($hex -join ':')
    } catch { return '' }
}

function ConvertFrom-UfOption43Hex {
    param([string]$Hex)
    try {
        $parts = @($Hex -split '[:\s-]+' | Where-Object { $_ })
        if ($parts.Count -ge 6 -and $parts[0] -eq '01') {
            $ipBytes = @($parts[2..5] | ForEach-Object { [Convert]::ToInt32($_, 16) })
            return ('controller = {0}' -f ($ipBytes -join '.'))
        }
    } catch { }
    return ''
}

function Get-UfDhcpOption43 {
    # Best effort only. Windows stores the options it received under
    # DhcpInterfaceOptions as a packed binary blob whose layout is not
    # documented, so this scans for the option-43 record rather than walking
    # the structure formally. Any failure yields nothing - it must never throw,
    # because this is advisory information sitting in the middle of a scan.
    $results = [System.Collections.Generic.List[object]]::new()
    try {
        $base = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
        foreach ($key in @(Get-ChildItem -Path $base -ErrorAction Stop)) {
            $blob = $null
            try {
                $blob = (Get-ItemProperty -Path $key.PSPath -Name 'DhcpInterfaceOptions' -ErrorAction Stop).DhcpInterfaceOptions
            } catch { }
            if (-not $blob) { continue }
            $bytes = [byte[]]$blob
            $found = ''
            # Records are DWORD-aligned: <option id> 00 00 00 <length dword> ... <data>
            for ($i = 0; $i -lt ($bytes.Length - 16); $i += 4) {
                if ($bytes[$i] -eq 43 -and $bytes[$i+1] -eq 0 -and $bytes[$i+2] -eq 0 -and $bytes[$i+3] -eq 0) {
                    $len = [BitConverter]::ToInt32($bytes, $i + 4)
                    if ($len -gt 0 -and $len -le 255 -and ($i + 16 + $len) -le $bytes.Length) {
                        $data = $bytes[($i+16)..($i+15+$len)]
                        $found = (@($data | ForEach-Object { '{0:X2}' -f $_ }) -join ':')
                        break
                    }
                }
            }
            if ($found) {
                $results.Add([PSCustomObject]@{
                    Interface = $key.PSChildName
                    Option43  = $found
                    Decoded   = (ConvertFrom-UfOption43Hex -Hex $found)
                })
            }
        }
    } catch { }
    return @($results)
}

# -----------------------------------------------------------------------------
# Controller reachability
# -----------------------------------------------------------------------------

function Test-UfTcpPort {
    # TcpClient with an explicit wait rather than Test-NetConnection: an order
    # of magnitude faster, no progress spam, and a real timeout we control.
    param(
        [string]$ComputerName,
        [int]$Port,
        [int]$TimeoutMs = 3000
    )
    $out = [PSCustomObject]@{
        Target = ('{0}:{1}' -f $ComputerName, $Port)
        Port   = $Port
        Open   = $false
        Ms     = 0
        Error  = ''
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $async  = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if ($async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            $client.EndConnect($async)
            $out.Open = $true
        } else {
            $out.Error = 'Timed out'
        }
    } catch {
        $out.Error = $_.Exception.Message
    } finally {
        if ($client) { try { $client.Close() } catch { } }
        $sw.Stop()
        $out.Ms = [int]$sw.ElapsedMilliseconds
    }
    return $out
}

function Test-UfStunPort {
    # Real STUN binding request (RFC 5389), not just a blind UDP send:
    #   type 0x0001, length 0x0000, magic cookie 0x2112A442, 12-byte txn id.
    # UDP 3478 matters because a device can adopt successfully and then keep
    # dropping to Offline when STUN is blocked - which looks like a flaky AP.
    param(
        [string]$ComputerName,
        [int]$Port = 3478,
        [int]$TimeoutMs = 2500
    )
    $out = [PSCustomObject]@{
        Target   = ('{0}:{1}/udp' -f $ComputerName, $Port)
        Answered = $false
        Ms       = 0
        Error    = ''
    }
    $udp = $null
    $sw  = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $header = [byte[]]::new(20)
        $header[0] = 0x00; $header[1] = 0x01      # Binding Request
        $header[2] = 0x00; $header[3] = 0x00      # Length 0
        $header[4] = 0x21; $header[5] = 0x12
        $header[6] = 0xA4; $header[7] = 0x42      # Magic cookie
        $rnd = New-Object System.Random
        for ($i = 8; $i -lt 20; $i++) { $header[$i] = [byte]$rnd.Next(0, 256) }

        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $udp.Connect($ComputerName, $Port)
        [void]$udp.Send($header, $header.Length)
        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $reply  = $udp.Receive([ref]$remote)
        # A Binding Success Response is type 0x0101 and repeats the cookie.
        if ($reply -and $reply.Length -ge 20 -and $reply[4] -eq 0x21 -and $reply[5] -eq 0x12) {
            $out.Answered = $true
        } elseif ($reply) {
            $out.Answered = $true
            $out.Error    = 'Answered, but not a STUN response'
        }
    } catch {
        $out.Error = $_.Exception.Message
    } finally {
        if ($udp) { try { $udp.Close() } catch { } }
        $sw.Stop()
        $out.Ms = [int]$sw.ElapsedMilliseconds
    }
    return $out
}

function Invoke-UfInformProbe {
    # HTTP 400 from /inform is the PASS condition, not a failure.
    #
    # The inform endpoint expects an encrypted binary payload produced by the
    # device's management agent. A plain GET carries no such payload, so a
    # healthy controller rejects it with 400 and closes the connection. A
    # firewall block or dead service gives a timeout or a connection error
    # instead. This trips up every technician who sees it for the first time,
    # so the wording here is deliberately explicit.
    param(
        [string]$ComputerName,
        [int]$Port = 8080,
        [int]$TimeoutMs = 8000
    )
    $uri = ('http://{0}:{1}/inform' -f $ComputerName, $Port)
    $out = [PSCustomObject]@{
        Uri        = $uri
        StatusCode = 0
        Healthy    = $false
        Error      = ''
    }
    try {
        $req = [System.Net.HttpWebRequest]::Create($uri)
        $req.Method    = 'GET'
        $req.Timeout   = $TimeoutMs
        $req.UserAgent = 'UniFi-Troubleshooter'
        $req.AllowAutoRedirect = $false
        $resp = $req.GetResponse()
        $out.StatusCode = [int]$resp.StatusCode
        $resp.Close()
        # 2xx from /inform is odd but still proves something is listening.
        $out.Healthy = $true
    } catch [System.Net.WebException] {
        $we = $_.Exception
        if ($we.Response) {
            $out.StatusCode = [int]$we.Response.StatusCode
            if ($out.StatusCode -eq 400) {
                $out.Healthy = $true
            } else {
                $out.Error = ('HTTP {0}' -f $out.StatusCode)
            }
            try { $we.Response.Close() } catch { }
        } else {
            $out.Error = $we.Message
        }
    } catch {
        $out.Error = $_.Exception.Message
    }
    return $out
}

function Get-UfControllerStatus {
    # /status is unauthenticated on the classic self-hosted Network
    # Application and returns {"meta":{"rc":"ok","up":true,"server_version":...}}
    # It proves the APPLICATION is alive, which an open TCP port does not.
    param(
        [string]$ComputerName,
        [int]$Port = 8443,
        [int]$TimeoutMs = 10000
    )
    Enable-UfTls
    $out = [PSCustomObject]@{
        Uri      = ('https://{0}:{1}/status' -f $ComputerName, $Port)
        Up       = $false
        Version  = ''
        UniFiOs  = $false
        Error    = ''
    }
    $content = ''
    try {
        $resp = Invoke-WebRequest -Uri $out.Uri -UseBasicParsing -TimeoutSec ([int]($TimeoutMs / 1000)) -ErrorAction Stop
        $content = [string]$resp.Content
    } catch {
        $out.Error = $_.Exception.Message
        # Fall back to curl before giving up - a self-signed controller that
        # the .NET stack refuses will usually answer curl quite happily.
        $content = Invoke-UfCurlJson -Uri $out.Uri -TimeoutSec ([int]($TimeoutMs / 1000))
        if ($content) { $out.Error = '' }
    }

    if ($content) {
        try {
            # Assign first, THEN inspect. Wrapping ConvertFrom-Json inline in
            # @() silently collapses structures and has bitten this before.
            $parsed = $content | ConvertFrom-Json
            if ($parsed -and $parsed.meta) {
                $out.Up      = [bool]$parsed.meta.up
                $out.Version = [string]$parsed.meta.server_version
            }
        } catch {
            if (-not $out.Error) { $out.Error = 'Response was not the JSON status document.' }
        }
        if ($content -match 'UniFi OS') { $out.UniFiOs = $true }
    }
    return $out
}

function Get-UfPortMatrix {
    # Each port carries the consequence of it being shut, not just a boolean.
    param([string]$ComputerName, [int]$InformPort = 8080, [int]$UiPort = 8443)
    return @(
        [PSCustomObject]@{ Port = $InformPort; Proto = 'tcp'; Name = 'Device inform';      Severity = 'critical'; Meaning = 'Devices cannot inform the controller. Adoption is impossible until this opens.' }
        [PSCustomObject]@{ Port = $UiPort;     Proto = 'tcp'; Name = 'Controller admin UI'; Severity = 'high';     Meaning = 'The admin interface is unreachable from here.' }
        [PSCustomObject]@{ Port = 443;         Proto = 'tcp'; Name = 'HTTPS / UniFi OS';    Severity = 'low';      Meaning = 'Only used by UniFi OS consoles and portal redirects.' }
        [PSCustomObject]@{ Port = 8880;        Proto = 'tcp'; Name = 'Guest portal (http)'; Severity = 'low';      Meaning = 'Guest portal only. Not needed for adoption.' }
        [PSCustomObject]@{ Port = 8843;        Proto = 'tcp'; Name = 'Guest portal (https)';Severity = 'low';      Meaning = 'Guest portal only. Not needed for adoption.' }
        [PSCustomObject]@{ Port = 6789;        Proto = 'tcp'; Name = 'Mobile speed test';   Severity = 'low';      Meaning = 'Throughput test only.' }
        [PSCustomObject]@{ Port = 27117;       Proto = 'tcp'; Name = 'MongoDB (internal)';  Severity = 'security'; Meaning = 'Must NOT be reachable across the internet. If open from here, that is a finding.' }
    )
}

# -----------------------------------------------------------------------------
# Finding UniFi devices on the LAN
# -----------------------------------------------------------------------------

function Get-UfUbiquitiOui {
    # Ubiquiti OUI prefixes, normalised to lower case with dashes.
    return @(
        'd8-b3-70','78-8a-20','ac-8b-a9','b4-fb-e4','24-a4-3c','04-18-d6',
        'f0-9f-c2','e0-63-da','68-d7-9a','80-2a-a8','74-83-c2','9c-05-d6',
        'fc-ec-da','dc-9f-db','44-d9-e7','18-e8-29','28-70-4e','b4-a5-ef',
        '70-a7-41','00-27-22','68-72-51','ab-cd-ef','60-22-32','e4-38-83',
        '94-2a-6f','d0-21-f9','f4-92-bf','ac-a3-1e','ea-cb-3f'
    )
}

function Test-UfIsUbiquitiMac {
    param([string]$Mac)
    if (-not $Mac) { return $false }
    $norm = ($Mac -replace '[:\.]', '-').ToLower()
    foreach ($oui in (Get-UfUbiquitiOui)) {
        if ($norm.StartsWith($oui)) { return $true }
    }
    return $false
}

function Get-UfArpDevices {
    # Reads the neighbour cache and keeps anything with a Ubiquiti OUI.
    param([switch]$IncludeAll)
    $rows = [System.Collections.Generic.List[object]]::new()
    try {
        $entries = @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction Stop |
                     Where-Object { $_.LinkLayerAddress -and $_.State -ne 'Permanent' -and $_.State -ne 'Unreachable' })
        foreach ($e in $entries) {
            $isUbnt = Test-UfIsUbiquitiMac -Mac $e.LinkLayerAddress
            if (-not $isUbnt -and -not $IncludeAll) { continue }
            $rows.Add([PSCustomObject]@{
                IPAddress = [string]$e.IPAddress
                Mac       = ([string]$e.LinkLayerAddress).ToUpper()
                Interface = [string]$e.InterfaceAlias
                Source    = 'ARP'
                Ubiquiti  = $isUbnt
            })
        }
    } catch { }
    return @($rows)
}

function Invoke-UfPingSweep {
    # Warms the neighbour cache so Get-UfArpDevices can see devices that have
    # not spoken to this PC recently. Parallel async pings, no runspaces needed.
    param(
        [string]$BaseIp,
        [int]$PrefixLength = 24,
        [int]$TimeoutMs = 250,
        $Sync = $null
    )
    $live = [System.Collections.Generic.List[string]]::new()
    try {
        if ($PrefixLength -lt 22) { $PrefixLength = 24 }   # refuse to sweep anything huge
        $parts = @($BaseIp -split '\.')
        if ($parts.Count -ne 4) { return @($live) }
        $prefix3 = ('{0}.{1}.{2}' -f $parts[0], $parts[1], $parts[2])

        $pings = [System.Collections.Generic.List[object]]::new()
        for ($i = 1; $i -le 254; $i++) {
            $p = New-Object System.Net.NetworkInformation.Ping
            $pings.Add([PSCustomObject]@{
                Ip   = ('{0}.{1}' -f $prefix3, $i)
                Ping = $p
                Task = $p.SendPingAsync(('{0}.{1}' -f $prefix3, $i), $TimeoutMs)
            })
        }
        foreach ($item in $pings) {
            if ($Sync -and $Sync.Cancel) { break }
            try {
                $r = $item.Task.Result
                if ($r -and $r.Status -eq 'Success') { $live.Add($item.Ip) }
            } catch { }
            try { $item.Ping.Dispose() } catch { }
        }
    } catch { }
    return @($live)
}

function ConvertFrom-UfDiscoveryPacket {
    # Ubiquiti discovery replies are TLV records after a 4-byte header:
    #   version(1) command(1) payload-length(2, big endian)
    #   then repeating: type(1) length(2, big endian) value(length)
    #
    # Deliberately tolerant. Firmware varies in which fields it sends and in
    # what it puts in them, so an unrecognised or malformed record is captured
    # as raw text rather than thrown - a partial row still tells the technician
    # the IP and MAC, which is the part they actually need.
    param([byte[]]$Bytes, [string]$FromIp)

    $out = [PSCustomObject]@{
        IPAddress = $FromIp
        Mac       = ''
        Model     = ''
        Firmware  = ''
        Hostname  = ''
        Uptime    = 0
        IsDefault = $null
        Essid     = ''
        Extra     = ''
        Source    = 'UDP 10001'
        Ubiquiti  = $true
    }
    if (-not $Bytes -or $Bytes.Length -lt 4) { return $out }

    $extras = [System.Collections.Generic.List[string]]::new()
    try {
        $pos = 4
        while ($pos + 3 -le $Bytes.Length) {
            $type = $Bytes[$pos]
            $len  = ($Bytes[$pos + 1] -shl 8) -bor $Bytes[$pos + 2]
            $pos += 3
            if ($len -lt 0 -or ($pos + $len) -gt $Bytes.Length) { break }
            $val = $Bytes[$pos..($pos + $len - 1)]
            $pos += $len
            if ($len -eq 0) { continue }

            switch ($type) {
                0x01 {
                    if ($len -ge 6) { $out.Mac = (@($val[0..5] | ForEach-Object { '{0:X2}' -f $_ }) -join ':') }
                }
                0x02 {
                    # MAC + IP together. The IP here is authoritative.
                    if ($len -ge 10) {
                        if (-not $out.Mac) { $out.Mac = (@($val[0..5] | ForEach-Object { '{0:X2}' -f $_ }) -join ':') }
                        $out.IPAddress = (@($val[6..9] | ForEach-Object { [int]$_ }) -join '.')
                    }
                }
                0x03 { $out.Firmware = [Text.Encoding]::ASCII.GetString($val).Trim([char]0) }
                0x0A { if ($len -ge 4) { $out.Uptime = ($val[0] -shl 24) -bor ($val[1] -shl 16) -bor ($val[2] -shl 8) -bor $val[3] } }
                0x0B { $out.Hostname = [Text.Encoding]::UTF8.GetString($val).Trim([char]0) }
                0x0C { if (-not $out.Model) { $out.Model = [Text.Encoding]::ASCII.GetString($val).Trim([char]0) } }
                0x0D { $out.Essid = [Text.Encoding]::UTF8.GetString($val).Trim([char]0) }
                0x14 { $out.Model = [Text.Encoding]::ASCII.GetString($val).Trim([char]0) }
                0x15 { if (-not $out.Model) { $out.Model = [Text.Encoding]::ASCII.GetString($val).Trim([char]0) } }
                0x16 { if (-not $out.Firmware) { $out.Firmware = [Text.Encoding]::ASCII.GetString($val).Trim([char]0) } }
                0x17 {
                    # 1 = still on factory defaults / not adopted. Worth a column
                    # of its own: it settles "has this been reset?" immediately.
                    $out.IsDefault = ($val[0] -ne 0)
                }
                0x1B { if (-not $out.Firmware) { $out.Firmware = [Text.Encoding]::ASCII.GetString($val).Trim([char]0) } }
                default {
                    $txt = ''
                    try { $txt = [Text.Encoding]::ASCII.GetString($val).Trim([char]0) } catch { }
                    if ($txt -and ($txt -match '^[\x20-\x7E]+$')) {
                        $extras.Add(('0x{0:X2}={1}' -f $type, $txt))
                    } else {
                        $extras.Add(('0x{0:X2}=[{1} bytes]' -f $type, $len))
                    }
                }
            }
        }
    } catch {
        $extras.Add('parse stopped: ' + $_.Exception.Message)
    }
    $out.Extra = ($extras -join '; ')
    return $out
}

function Invoke-UfDiscovery {
    # Ubiquiti UDP discovery on 10001. This is the method that finds devices
    # ARP cannot: unadopted units, units holding a stale address from another
    # subnet, and units that have not talked to this PC at all.
    #
    # Sends both the v1 and v2 probes, to the all-ones broadcast and to each
    # interface's directed broadcast, because different firmware answers
    # different combinations.
    param(
        [int]$ListenMs = 2500,
        $Sync = $null
    )
    $found = @{}
    $probes = @(
        ,([byte[]]@(0x01, 0x00, 0x00, 0x00))
        ,([byte[]]@(0x02, 0x08, 0x00, 0x00))
    )

    foreach ($nic in (Get-UfLocalNetwork)) {
        if ($Sync -and $Sync.Cancel) { break }
        $udp = $null
        try {
            $udp = New-Object System.Net.Sockets.UdpClient
            $udp.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket,
                                        [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
            $udp.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($nic.IPAddress), 0)))
            $udp.EnableBroadcast = $true
            $udp.Client.ReceiveTimeout = 700

            # Directed broadcast for this interface's subnet, plus 255.255.255.255.
            $targets = [System.Collections.Generic.List[string]]::new()
            $targets.Add('255.255.255.255')
            try {
                $ipBytes   = ([System.Net.IPAddress]::Parse($nic.IPAddress)).GetAddressBytes()
                $maskBits  = [uint32]0
                if ($nic.PrefixLength -gt 0 -and $nic.PrefixLength -le 32) {
                    $maskBits = [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - $nic.PrefixLength))
                }
                $maskBytes = [BitConverter]::GetBytes($maskBits)
                [array]::Reverse($maskBytes)
                $bcast = @(0..3 | ForEach-Object { [int]($ipBytes[$_] -bor (255 - $maskBytes[$_])) })
                $targets.Add(($bcast -join '.'))
            } catch { }

            foreach ($t in ($targets | Select-Object -Unique)) {
                foreach ($probe in $probes) {
                    try {
                        $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($t), 10001)
                        [void]$udp.Send($probe, $probe.Length, $ep)
                    } catch { }
                }
            }

            # Drain replies until the listen budget is spent.
            $deadline = (Get-Date).AddMilliseconds($ListenMs)
            while ((Get-Date) -lt $deadline) {
                if ($Sync -and $Sync.Cancel) { break }
                try {
                    $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
                    $data   = $udp.Receive([ref]$remote)
                    if ($data -and $data.Length -gt 4) {
                        $dev = ConvertFrom-UfDiscoveryPacket -Bytes $data -FromIp $remote.Address.ToString()
                        $key = if ($dev.Mac) { $dev.Mac } else { $dev.IPAddress }
                        if ($key) { $found[$key] = $dev }
                    }
                } catch {
                    # Receive timeout is the normal way out of a quiet moment.
                }
            }
        } catch {
        } finally {
            if ($udp) { try { $udp.Close() } catch { } }
        }
    }
    return @($found.Values)
}

function Merge-UfDeviceLists {
    # ARP gives IP+MAC; discovery gives model, firmware, uptime and the
    # is-default flag. Merge on MAC, falling back to IP.
    param($ArpDevices, $DiscoveredDevices)
    $byKey = [ordered]@{}

    foreach ($d in @($DiscoveredDevices)) {
        $key = if ($d.Mac) { $d.Mac.ToUpper() } else { $d.IPAddress }
        if ($key) { $byKey[$key] = $d }
    }
    foreach ($a in @($ArpDevices)) {
        $key = if ($a.Mac) { $a.Mac.ToUpper() } else { $a.IPAddress }
        if (-not $key) { continue }
        if ($byKey.Contains($key)) {
            if (-not $byKey[$key].IPAddress) { $byKey[$key].IPAddress = $a.IPAddress }
            $byKey[$key].Source = 'ARP + UDP 10001'
        } else {
            $byKey[$key] = [PSCustomObject]@{
                IPAddress = $a.IPAddress
                Mac       = $a.Mac
                Model     = ''
                Firmware  = ''
                Hostname  = ''
                Uptime    = 0
                IsDefault = $null
                Essid     = ''
                Extra     = ''
                Source    = 'ARP'
                Ubiquiti  = $a.Ubiquiti
            }
        }
    }
    return @($byKey.Values)
}

# -----------------------------------------------------------------------------
# PuTTY / plink
# -----------------------------------------------------------------------------

function Get-UfToolDir {
    # Local disk, under ProgramData - NOT %TEMP%. Download-and-run-from-temp is
    # the pattern endpoint protection flags hardest, and a stable signed copy in
    # a company folder is both quieter and reusable on the next call-out.
    return 'C:\ProgramData\UniFiTroubleshooter\Tools'
}

function Find-UfPutty {
    # Existing installs win: no download, no EDR event, no waiting.
    param([string]$Exe = 'putty.exe')
    $candidates = @(
        (Join-Path (Get-UfToolDir) $Exe),
        (Join-Path $env:ProgramFiles ('PuTTY\' + $Exe)),
        (Join-Path ${env:ProgramFiles(x86)} ('PuTTY\' + $Exe))
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    try {
        $cmd = Get-Command $Exe -ErrorAction Stop
        if ($cmd -and $cmd.Source) { return $cmd.Source }
    } catch { }
    return ''
}

function Test-UfSignature {
    # PuTTY releases are Authenticode signed by Simon Tatham. An unsigned or
    # tampered binary is never launched.
    param([string]$Path)
    $out = [PSCustomObject]@{ Valid = $false; Status = 'Unknown'; Signer = ''; Error = '' }
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        $out.Status = [string]$sig.Status
        if ($sig.SignerCertificate) { $out.Signer = [string]$sig.SignerCertificate.Subject }
        $out.Valid = ($sig.Status -eq 'Valid')
    } catch {
        $out.Error = $_.Exception.Message
    }
    return $out
}

function Install-UfPutty {
    # Downloads putty.exe and plink.exe from the author's own release path.
    # Returns a result object; the caller decides what to say about it.
    param(
        [string[]]$Files = @('putty.exe', 'plink.exe'),
        [switch]$Force,
        $Sync = $null
    )
    $dir = Get-UfToolDir
    $log = [System.Collections.Generic.List[string]]::new()
    $out = [PSCustomObject]@{
        Directory = $dir
        Putty     = ''
        Plink     = ''
        Log       = @()
        Success   = $false
    }

    try {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
            $log.Add("Created $dir")
        }
    } catch {
        $log.Add('Could not create ' + $dir + ': ' + $_.Exception.Message)
        $out.Log = @($log)
        return $out
    }

    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    foreach ($file in $Files) {
        if ($Sync -and $Sync.Cancel) { break }
        $dest = Join-Path $dir $file

        # An existing install anywhere Find-UfPutty looks counts, not just our
        # own folder - a machine with C:\Program Files\PuTTY already on it
        # should not have a second copy pulled down for no reason.
        $existing = ''
        if (-not $Force) { $existing = Find-UfPutty -Exe $file }

        if ($existing -and -not $Force) {
            $log.Add("$file already on this machine at $existing - not downloading")
            if ($file -eq 'putty.exe') { $out.Putty = $existing }
            if ($file -eq 'plink.exe') { $out.Plink = $existing }
            continue
        } elseif ((Test-Path -LiteralPath $dest) -and -not $Force) {
            $log.Add("$file already present, skipping download")
        } else {
            $url = 'https://the.earth.li/~sgtatham/putty/latest/w64/' + $file
            $log.Add("Downloading $url")
            $ok = $false
            if (Test-Path -LiteralPath $curl) {
                # curl.exe uses Schannel, so it needs no TLS coaxing on 5.1.
                & $curl -L -f -s -S --connect-timeout 20 --max-time 180 -o $dest $url 2>&1 | Out-Null
                $ok = ($LASTEXITCODE -eq 0)
                if (-not $ok) { $log.Add("curl exit $LASTEXITCODE") }
            }
            if (-not $ok) {
                try {
                    Enable-UfTls
                    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -ErrorAction Stop
                    $ok = $true
                } catch {
                    $log.Add('Download failed: ' + $_.Exception.Message)
                }
            }
            # A wrong path on many hosts does not 404 - it returns 200 with an
            # HTML page, which -f cannot catch and which would then be launched
            # as an executable. The real binaries are ~1 MB, so a size floor is
            # what actually stops that.
            if ($ok -and (Test-Path -LiteralPath $dest)) {
                $size = (Get-Item -LiteralPath $dest).Length
                if ($size -lt 300KB) {
                    $log.Add("$file is only $size bytes - that is a web page, not a binary. Discarded.")
                    Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
                    $ok = $false
                } else {
                    $log.Add(('Saved {0} ({1:n0} bytes)' -f $file, $size))
                }
            }
            if (-not $ok) { continue }
        }

        if (Test-Path -LiteralPath $dest) {
            $sig = Test-UfSignature -Path $dest
            if ($sig.Valid) {
                $log.Add("Signature OK: $($sig.Signer)")
            } else {
                $log.Add("SIGNATURE NOT VALID ($($sig.Status)) - will not launch $file")
                Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
                continue
            }
            if ($file -eq 'putty.exe') { $out.Putty = $dest }
            if ($file -eq 'plink.exe') { $out.Plink = $dest }
        }
    }

    $out.Log     = @($log)
    $out.Success = [bool]$out.Putty
    return $out
}

function Get-UfBrowserPath {
    # A Backstage / SYSTEM session frequently has no usable default browser -
    # Start-Process on a URL there either does nothing or opens something in
    # the wrong session. The site convention is a portable Pale Moon under
    # C:\Temp, so look for that first and only fall back to the shell handler.
    # The exe sits at a different depth depending on how the portable build was
    # unpacked, hence the recursive look rather than a fixed path.
    $roots = @(
        'C:\Temp\Palemoon-Portable',
        'C:\Temp\Browser\Palemoon-Portable'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($pattern in @('Palemoon-Portable.exe', 'palemoon.exe')) {
            try {
                $hit = Get-ChildItem -LiteralPath $root -Filter $pattern -Recurse -Depth 3 -File -ErrorAction SilentlyContinue |
                       Select-Object -First 1
                if ($hit) { return $hit.FullName }
            } catch { }
        }
    }
    return ''
}

function Open-UfUrl {
    # Returns what it used, so the caller can say so in the log.
    param([string]$Url)
    if (-not $Url) { return '' }
    $browser = Get-UfBrowserPath
    if ($browser) {
        Start-Process -FilePath $browser -ArgumentList $Url | Out-Null
        return $browser
    }
    Start-Process $Url | Out-Null
    return 'the default browser'
}

function Start-UfPutty {
    # Pre-fills host and user only. The password is NEVER passed on the command
    # line - it would sit in the process list for anyone on the box to read.
    param(
        [string]$PuttyPath,
        [string]$DeviceIp,
        [string]$User = 'ubnt',
        [int]$Port = 22
    )
    if (-not $PuttyPath -or -not (Test-Path -LiteralPath $PuttyPath)) { throw 'putty.exe was not found.' }
    if (-not $DeviceIp) { throw 'No device IP given.' }
    # Not $args: that is an automatic variable, and assigning to it inside a
    # function is a good way to lose an argument list somewhere surprising.
    $puttyArgs = @('-ssh', ('{0}@{1}' -f $User, $DeviceIp), '-P', [string]$Port)
    Start-Process -FilePath $PuttyPath -ArgumentList $puttyArgs | Out-Null
}

function Invoke-UfPlink {
    # Runs one command on the device and returns its output.
    #
    # -pwfile is used in preference to -pw: -pw puts the device password into
    # the command line, where it is visible in the process list. -pwfile needs
    # PuTTY 0.77+; if plink rejects it we fall back to -pw and say so.
    #
    # The host key is accepted by feeding "y" on stdin. -batch is deliberately
    # not used, because -batch aborts on an unknown host key and every device
    # here is unknown on first contact.
    param(
        [string]$PlinkPath,
        [string]$DeviceIp,
        [string]$User = 'ubnt',
        [string]$Password,
        [string]$Command,
        [int]$TimeoutMs = 30000
    )
    $out = [PSCustomObject]@{
        Command  = $Command
        Output   = ''
        Error    = ''
        ExitCode = -1
    }
    if (-not $PlinkPath -or -not (Test-Path -LiteralPath $PlinkPath)) {
        $out.Error = 'plink.exe was not found. Use the PuTTY tab to fetch it.'
        return $out
    }

    $pwFile = $null
    try {
        $pwFile = Join-Path (Get-UfToolDir) ('.pw-' + [Guid]::NewGuid().ToString('N'))
        # ASCII, no BOM - plink reads the file literally.
        [System.IO.File]::WriteAllText($pwFile, $Password, (New-Object System.Text.ASCIIEncoding))

        $argList = @('-ssh', '-P', '22', '-l', $User, '-pwfile', ('"' + $pwFile + '"'), $DeviceIp, ('"' + $Command + '"'))

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName               = $PlinkPath
        $psi.Arguments              = ($argList -join ' ')
        $psi.UseShellExecute        = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        $psi.RedirectStandardInput  = $true
        # CreateNoWindow, not -WindowStyle Hidden: the latter would also hide
        # our own form.
        $psi.CreateNoWindow         = $true

        $proc = [System.Diagnostics.Process]::Start($psi)
        try { $proc.StandardInput.WriteLine('y') } catch { }
        try { $proc.StandardInput.Close() } catch { }

        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutMs)) {
            try { $proc.Kill() } catch { }
            $out.Error = "plink did not finish within $([int]($TimeoutMs/1000))s - check the IP, or that SSH is enabled on the device."
            return $out
        }
        $out.Output   = [string]$stdout.Result
        $out.Error    = [string]$stderr.Result
        $out.ExitCode = $proc.ExitCode

        if ($out.Error -match 'pwfile|unknown option|unrecognised') {
            $out.Error += "`r`nThis plink build does not support -pwfile (needs PuTTY 0.77+). Use the copy/paste commands with PuTTY instead."
        }
    } catch {
        $out.Error = $_.Exception.Message
    } finally {
        if ($pwFile -and (Test-Path -LiteralPath $pwFile)) {
            Remove-Item -LiteralPath $pwFile -Force -ErrorAction SilentlyContinue
        }
    }
    return $out
}

function ConvertFrom-UfDeviceInfo {
    # Parses the output of "mca-cli-op info" / "info" into fields. The Status
    # line is the one that matters - it names the fault outright.
    param([string]$Text)
    $out = [PSCustomObject]@{
        Model     = ''
        Version   = ''
        Mac       = ''
        IPAddress = ''
        Hostname  = ''
        Uptime    = ''
        Status    = ''
        InformUrl = ''
        Raw       = $Text
    }
    if (-not $Text) { return $out }
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*Model:\s*(.+?)\s*$')        { $out.Model     = $Matches[1] }
        elseif ($line -match '^\s*Version:\s*(.+?)\s*$')  { $out.Version   = $Matches[1] }
        elseif ($line -match '^\s*MAC Address:\s*(.+?)\s*$') { $out.Mac    = $Matches[1] }
        elseif ($line -match '^\s*IP Address:\s*(.+?)\s*$')  { $out.IPAddress = $Matches[1] }
        elseif ($line -match '^\s*Hostname:\s*(.+?)\s*$') { $out.Hostname  = $Matches[1] }
        elseif ($line -match '^\s*Uptime:\s*(.+?)\s*$')   { $out.Uptime    = $Matches[1] }
        elseif ($line -match '^\s*Status:\s*(.+?)\s*$')   { $out.Status    = $Matches[1] }
    }
    if ($out.Status -match '\((https?://[^\)]+)\)') { $out.InformUrl = $Matches[1] }
    return $out
}

function Get-UfSerialFromMac {
    # UniFi hardware uses the device MAC as its serial number - it is what the
    # controller displays as Serial Number and what serialno reports in
    # /proc/ubnthal/system.info. Derived here rather than read, so the column
    # says so; an SSH read overwrites it with the device's own answer.
    param([string]$Mac)
    if (-not $Mac) { return '' }
    return (($Mac -replace '[^0-9A-Fa-f]', '').ToUpper())
}

function ConvertFrom-UfSystemInfo {
    # /proc/ubnthal/system.info is a flat key=value file. Which keys are present
    # varies by board and firmware - mfgweek is not on every device, and UniFi
    # OS hardware may have no such file at all - so every line is kept instead
    # of only a fixed list, and a key that is absent stays empty rather than
    # being inferred from something else.
    param([string]$Text)
    $out = [PSCustomObject]@{
        ShortName = ''
        Serial    = ''
        BoardRev  = ''
        MfgWeek   = ''
        Pairs     = [ordered]@{}
        Count     = 0
    }
    if (-not $Text) { return $out }
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*([A-Za-z0-9_.\-]+)\s*=\s*(.*?)\s*$') {
            $k = $Matches[1]
            $v = $Matches[2]
            $out.Pairs[$k] = $v
            switch -Regex ($k) {
                '^shortname$'          { $out.ShortName = $v }
                '^serialno$'           { $out.Serial    = $v.ToUpper() }
                '^boardrevision$'      { $out.BoardRev  = $v }
                '^mfgweek$'            { $out.MfgWeek   = $v }
                '^board\.name$'        { if (-not $out.ShortName) { $out.ShortName = $v } }
                '^board\.shortname$'   { $out.ShortName = $v }
                '^board\.hwrev$'       { if (-not $out.BoardRev) { $out.BoardRev = $v } }
            }
        }
    }
    $out.Count = $out.Pairs.Count
    return $out
}

function ConvertFrom-UfPersistence {
    # Reads the output of the persistence block: does anything this device
    # writes actually survive a power cut?
    #
    # The decisive line is the root filesystem type. A root of rootfs, tmpfs or
    # ramfs is a RAM disk, which means /etc/persistent is a plain directory
    # inside it and every byte of the configuration is gone at power-off. That
    # single fact settles the question on its own - the storage section below
    # only tells you WHY, which is a repair-or-replace question, not a
    # diagnosis one.
    param([string]$Text)
    $out = [PSCustomObject]@{
        CmdLine    = ''
        RootFs     = ''
        PersistFs  = ''
        Volatile   = $null
        MmcHost    = ''
        MmcCard    = ''
        MmcBlocks  = @()
        InformUrl  = ''
        DmesgLines = -1
        Parsed     = $false
        Raw        = $Text
    }
    if (-not $Text) { return $out }

    # The command emits ---SECTION--- markers, so each line is read only in the
    # context it came from. Without that a df row or a mount line starting
    # /dev/mmcblk0p9 gets counted as a block device, which inflates the count
    # and makes a healthy device look stranger than it is.
    $blocks  = @()
    $section = ''
    foreach ($line in ($Text -split "`r?`n")) {
        $l = $line.Trim()
        if (-not $l) { continue }
        if ($l -match '^---([A-Z]+)---$') { $section = $Matches[1]; continue }

        switch ($section) {
            'CMDLINE' { if (-not $out.CmdLine) { $out.CmdLine = $l } }
            'MOUNT' {
                # "rootfs on / type rootfs (rw,size=95812k,...)" - the type for '/'.
                if ($l -match '^\S+\s+on\s+/\s+type\s+(\S+)') { $out.RootFs = $Matches[1] }
            }
            'PERSISTFS' {
                # The df body row, not its header.
                if ($l -match '^(\S+)\s+\S+\s+\S+\s+\S+\s+\d+%\s+\S' -and $Matches[1] -ne 'Filesystem') {
                    if (-not $out.PersistFs) { $out.PersistFs = $Matches[1] }
                }
            }
            'PARTITIONS' {
                if ($l -match '^\d+\s+\d+\s+\d+\s+(mmcblk\S+)$') { $blocks += ('/dev/' + $Matches[1]) }
            }
            'MMCBLOCK' { if ($l -match '^(/dev/mmcblk\S*)$') { $blocks += $Matches[1] } }
            'MMCHOST'  { if ($l -match '^(mmc\d+)$') { $out.MmcHost = $Matches[1] } }
            'MMCCARD'  { if ($l -match '^(mmc\d+:[0-9a-fA-F]+)$') { $out.MmcCard = $Matches[1] } }
            'MGMT' {
                if ($l -match 'mgmt\.servers\.\d+\.url=(\S+)' -and -not $out.InformUrl) { $out.InformUrl = $Matches[1] }
            }
            'DMESG' { if ($l -match '^DMESGLINES=(\d+)$') { $out.DmesgLines = [int]$Matches[1] } }
        }
    }

    $out.MmcBlocks = @($blocks | Select-Object -Unique)
    if ($out.RootFs) {
        $out.Parsed = $true
        $out.Volatile = ($out.RootFs -match '^(rootfs|tmpfs|ramfs)$')
    }
    return $out
}

function Get-UfStatusVerdict {
    # Maps the Status string from "info" onto the fix. This table is the whole
    # point of the SSH round trip.
    param([string]$Status)
    $s = [string]$Status
    if ($s -match 'Unable to resolve') {
        return [PSCustomObject]@{ Level = 'high'; Headline = 'Device cannot resolve its inform hostname';
            Advice = 'The device is pointed at a name it cannot look up. Run set-inform with the controller FQDN or IP. Then fix it permanently with Override Inform Host on the controller, or this returns on the next reboot.' }
    }
    if ($s -match 'Pending Adoption') {
        return [PSCustomObject]@{ Level = 'medium'; Headline = 'Pending Adoption - waiting for you to adopt it';
            Advice = 'The device has reached the controller. Click Adopt in the Network application, then run set-inform a SECOND time immediately - Layer 3 adoption needs both.' }
    }
    if ($s -match 'Server Reject') {
        return [PSCustomObject]@{ Level = 'high'; Headline = 'Server Reject - device credentials do not match the site';
            Advice = 'Check Settings > System > Advanced > Device Authentication on the controller, or forget and re-adopt the device.' }
    }
    if ($s -match 'Decrypt Error|decrypt') {
        return [PSCustomObject]@{ Level = 'high'; Headline = 'Decrypt Error - the device key is out of sync';
            Advice = 'Forget the device in the controller, run syswrapper.sh restore-default on it, then re-adopt.' }
    }
    if ($s -match 'Disconnected') {
        return [PSCustomObject]@{ Level = 'high'; Headline = 'Disconnected - the controller is not reachable from the device';
            Advice = 'Test TCP 8080 from the device itself with nc. Check NAT/port-forwarding and outbound filtering on the site gateway.' }
    }
    if ($s -match 'Connected') {
        return [PSCustomObject]@{ Level = 'ok'; Headline = 'Connected - the device is managed';
            Advice = 'No action needed. Confirm the inform URL is the FQDN and not the bare unifi hostname.' }
    }
    return [PSCustomObject]@{ Level = 'info'; Headline = ('Status: ' + $s); Advice = '' }
}

# -----------------------------------------------------------------------------
# SSH command blocks
# -----------------------------------------------------------------------------

function Get-UfSshBlocks {
    # Every block is generated against the CURRENT host/port/device values, so
    # what the technician pastes is never a stale default. Typing into a
    # Backstage session is painful; these exist to be copied, not read.
    param(
        [string]$ControllerHost = 'unifi.example.com',
        [int]$InformPort = 8080,
        [string]$DeviceIp = '<AP_IP>',
        [string]$SshUser = 'ubnt'
    )
    $ip     = if ($DeviceIp) { $DeviceIp } else { '<AP_IP>' }
    $user   = if ($SshUser)  { $SshUser }  else { 'ubnt' }
    $inform = ('http://{0}:{1}/inform' -f $ControllerHost, $InformPort)

    $blocks = [System.Collections.Generic.List[object]]::new()

    $blocks.Add([PSCustomObject]@{
        Title = '1. Connect to the device'
        Note  = "Username and password both come from the site's Device Authentication settings (Settings > System > Advanced on the controller). 'ubnt' is only the factory default - sites commonly change it to 'admin', and a device adopted under older settings can keep the previous one. If the login is refused, try the other username before assuming the password is wrong. A factory-reset device is always ubnt/ubnt."
        Text  = ('ssh {0}@{1}' -f $user, $ip)
    })

    $blocks.Add([PSCustomObject]@{
        Title = '2. Read the current status and inform URL'
        Note  = 'The Status: line names the fault outright. If it reads "Unable to resolve (http://unifi:8080/inform)" you have confirmed this incident.'
        Text  = "mca-cli-op info"
    })

    $blocks.Add([PSCustomObject]@{
        Title = '3. Point the device at the controller (stage 1 of 2)'
        Note  = 'Moves the device from "Unable to resolve" to "Pending Adoption".'
        Text  = ('set-inform {0}' -f $inform)
    })

    $blocks.Add([PSCustomObject]@{
        Title = '4. Adopt in the controller, then repeat set-inform (stage 2 of 2)'
        Note  = 'MANDATORY for Layer 3 adoption. Click Adopt in the Network application first, then run this again straight away - without the second run the device loses the URL during provisioning.'
        Text  = ('set-inform {0}' -f $inform)
    })

    $blocks.Add([PSCustomObject]@{
        Title = '5. Prove the controller is reachable FROM the device'
        Note  = 'Run these on the device, not on the PC. This is what separates "the AP has a problem" from "the network has a problem". The 3478 check matters: with STUN blocked a device adopts and then keeps falling offline.'
        Text  = @(
            ('nslookup {0}' -f $ControllerHost),
            ('nc -zv {0} {1}' -f $ControllerHost, $InformPort),
            ('nc -zvu {0} 3478' -f $ControllerHost),
            'date'
        ) -join "`r`n"
    })

    $blocks.Add([PSCustomObject]@{
        Title = '6. Watch the inform attempts live'
        Note  = 'Leave this running while you click Adopt. Ctrl+C to stop.'
        Text  = 'tail -f /var/log/messages'
    })

    $blocks.Add([PSCustomObject]@{
        Title = '7. Hardware check - can this device still save its config?'
        Note  = 'Run this when settings survive a reboot but NOT a power-off. A read-only rootfs or mmc/jffs2 errors in dmesg mean worn flash: the device cannot persist the inform URL, and no amount of set-inform will fix it. That is an RMA.'
        Text  = @(
            'mount',
            "dmesg | grep -iE 'mmc|jffs|squashfs|read-only|error'",
            'df -h',
            'cfgmtd -w -p /etc/'
        ) -join "`r`n"
    })

    $blocks.Add([PSCustomObject]@{
        Title = '8. Restart the management agent (no reboot)'
        Note  = 'Restarts the process that talks to the controller. Least invasive recovery step.'
        Text  = 'killall -9 mca-ctrl'
    })

    $blocks.Add([PSCustomObject]@{
        Title = '9. Reboot the device'
        Note  = 'A warm reboot. Useful as a persistence test: if the inform URL survives this but not a power-off, see block 7.'
        Text  = 'reboot'
    })

    $blocks.Add([PSCustomObject]@{
        Title = '10. Factory reset - DESTRUCTIVE, last resort'
        Note  = 'Wipes all configuration and returns the login to ubnt/ubnt. Forget the device in the controller FIRST. Only needed for a Decrypt Error that will not clear.'
        Text  = 'syswrapper.sh restore-default'
    })

    return @($blocks)
}

# -----------------------------------------------------------------------------
# Knowledge base
# -----------------------------------------------------------------------------

function Get-UfKnowledgeBase {
    param([string]$ControllerHost = 'unifi.example.com', [string]$ControllerIp = '')
    $ip = if ($ControllerIp) { $ControllerIp } else { '<controller IP>' }
    $o43 = if ($ControllerIp) { ConvertTo-UfOption43Hex -IpAddress $ControllerIp } else { '' }
    $o43Note = if ($o43) { ' - hex ' + $o43 } else { '' }

    $kb = @(
        [PSCustomObject]@{
            Id = 1; Severity = 'critical'
            Title = 'The controller is re-pushing http://unifi:8080/inform (Override Inform Host is off)'
            Symptom = 'set-inform fixes the device, then it reverts to the bare "unifi" hostname after a reboot or the next provision.'
            Confirm = "Controller: super_mgmt.override_inform_host = false, or a device's inform_url contains //unifi:. The Controller tab reads both."
            Fix = "Controller > Settings > System > Advanced > Inform Host: set it to $ControllerHost, tick Override, Apply, then force-provision the device. This is the durable fix - set-inform on its own only lasts until the controller next provisions the device."
        },
        [PSCustomObject]@{
            Id = 2; Severity = 'critical'
            Title = 'Device cannot persist config across a cold power-off (eMMC or flash fault)'
            Symptom = 'Settings survive a warm reboot but are lost after the device is actually powered down. In the worst form it comes back on http://unifi:8080/inform with its SSIDs gone and showing Pending Adoption - the adoption keys went too, so this is a factory reset on every power cut rather than an inform problem.'
            Confirm = 'Find Devices tab > Check config persistence. A root filesystem of rootfs, tmpfs or ramfs means /etc/persistent is a directory in RAM and nothing written to it survives. On hardware that keeps its OS on eMMC, an absent /dev/mmcblk0 next to a present mmc host is the usual cause. Read nothing into an empty dmesg on a device that has been up for weeks - the ring buffer has long since wrapped.'
            Fix = "Hardware fault - no software change will hold, so plan on replacing the device. Until then make the power cut survivable: serve DHCP option 43 at the site$o43Note, or add a DNS A record for the name 'unifi' pointing at $ip, so the device finds the controller by itself on boot and recovery is one Adopt click instead of an SSH session. A UPS on the PoE switch avoids the fault altogether."
        },
        [PSCustomObject]@{
            Id = 3; Severity = 'high'
            Title = 'The bare hostname "unifi" does not resolve at this site'
            Symptom = 'nslookup unifi returns Non-existent domain. The site uses ISP DNS with no local resolver or override.'
            Confirm = 'Diagnostics tab: the "unifi" resolution check fails while the controller FQDN resolves.'
            Fix = ("Any one of: (a) DHCP Option 43 on the site gateway pointing at {0}{1}; (b) a DNS host override for 'unifi' on the gateway; (c) Override Inform Host set to the FQDN on the controller (see issue 1). Option (c) is the one that fixes it for every device at once." -f $ip, $o43Note)
        },
        [PSCustomObject]@{
            Id = 4; Severity = 'high'
            Title = 'UDP 3478 (STUN) blocked'
            Symptom = 'The device adopts successfully and then keeps dropping to Offline or Unreachable. Looks like a failing AP; it is a firewall.'
            Confirm = 'Diagnostics tab STUN probe, and "nc -zvu <host> 3478" from the device itself.'
            Fix = 'Allow UDP 3478 outbound from the device subnet to the controller.'
        },
        [PSCustomObject]@{
            Id = 5; Severity = 'medium'
            Title = 'No real-time clock - the device clock resets on power loss'
            Symptom = 'Log entries dated 1970, certificate and adoption oddities immediately after a power cut.'
            Confirm = 'Run "date" on the device (SSH block 5).'
            Fix = 'Make sure NTP and DNS are reachable from the device subnet. The clock corrects itself once NTP succeeds.'
        },
        [PSCustomObject]@{
            Id = 6; Severity = 'high'
            Title = 'Device credentials mismatch - Server Reject, or SSH refuses the login'
            Symptom = '"info" reports Server Reject, or you cannot SSH in at all. Note the USERNAME is a credential too: ubnt is only the factory default and many sites use admin, so a device can refuse ubnt while the password is perfectly correct. A device adopted under earlier settings can also keep the previous username.'
            Confirm = 'The Status line from SSH block 2. For the username specifically, connect on the Controller tab - it reads x_ssh_username from the site and fills the header SSH user in for you. A factory-reset device is always ubnt/ubnt.'
            Fix = 'Controller > Settings > System > Advanced > Device Authentication. Match both the username and the password, or forget and re-adopt. Check SSH is enabled for the site while you are there.'
        },
        [PSCustomObject]@{
            Id = 7; Severity = 'medium'
            Title = 'Duplicate or ghost device entry for the same MAC'
            Symptom = 'Two rows for one physical device, one Offline and one Pending Adoption. The Adopt action may be missing on either.'
            Confirm = 'Controller tab: two rows sharing a MAC.'
            Fix = 'Forget the stale entry, then adopt the live one. Do not delete the good entry - that turns a re-adoption into a clean adoption and discards site config.'
        },
        [PSCustomObject]@{
            Id = 8; Severity = 'high'
            Title = 'Decrypt Error'
            Symptom = '"info" reports Decrypt Error. Usually follows a controller restore or a device moved between controllers.'
            Confirm = 'The Status line from SSH block 2.'
            Fix = 'Forget the device in the controller, run syswrapper.sh restore-default on it, then re-adopt.'
        },
        [PSCustomObject]@{
            Id = 9; Severity = 'high'
            Title = 'Marginal PoE or injector - fails only on a cold start'
            Symptom = 'Device survives warm reboots but does not come back after a real power interruption. Uptime resets unexpectedly.'
            Confirm = 'Check the switch port PoE budget and the injector. A U6+ needs 802.3af, roughly 13W. Try a different port, injector and patch lead.'
            Fix = 'Replace the injector or move to a port with headroom. Suspect the cable run if the link renegotiates.'
        },
        [PSCustomObject]@{
            Id = 10; Severity = 'medium'
            Title = 'The device took a new DHCP lease, or sits on another VLAN'
            Symptom = 'The old IP no longer answers after a long outage, so the device looks dead.'
            Confirm = 'Find Devices tab: the device answers UDP 10001 discovery even when it is absent from the ARP cache.'
            Fix = 'Use the discovered address. Check the gateway lease table and reserve the address if this recurs.'
        },
        [PSCustomObject]@{
            Id = 11; Severity = 'info'
            Title = 'UISP is a different platform - UniFi devices do not adopt there'
            Symptom = 'Time lost looking for the AP in the UISP portal.'
            Confirm = 'example.uisp.com/nms/sites manages airMAX, EdgeRouter and UFiber hardware. Its inform port is 15443, not 8080.'
            Fix = "Adopt UniFi access points in the UniFi Network application at https://$ControllerHost`:8443 only."
        },
        [PSCustomObject]@{
            Id = 12; Severity = 'high'
            Title = 'Layer 3 adoption needs set-inform TWICE'
            Symptom = 'The device reaches Pending Adoption, you click Adopt, and it falls back instead of provisioning.'
            Confirm = 'Status returns to Pending or Disconnected shortly after adopting.'
            Fix = 'Run set-inform once before adopting and once immediately after clicking Adopt.'
        },
        [PSCustomObject]@{
            Id = 13; Severity = 'critical'
            Title = 'MongoDB (27117) reachable from outside'
            Symptom = 'The controller database port answers from the internet.'
            Confirm = 'Diagnostics tab port matrix shows 27117 open.'
            Fix = 'Block it at the perimeter immediately. Only 8080, 8443 and 3478/udp need to be exposed for remote adoption.'
        }
    )
    return @($kb)
}

function Get-UfOption43Recipes {
    param([string]$ControllerIp)
    $hex = ConvertTo-UfOption43Hex -IpAddress $ControllerIp
    if (-not $hex) { return @() }
    $plain = ($hex -replace ':', '')
    return @(
        [PSCustomObject]@{ Vendor = 'Raw hex';            Value = $hex }
        [PSCustomObject]@{ Vendor = 'Windows DHCP';       Value = ("Scope Option 043, data type Binary: {0}" -f $plain) }
        [PSCustomObject]@{ Vendor = 'MikroTik RouterOS';  Value = ("/ip dhcp-server option add code=43 name=unifi value=0x{0}" -f $plain) }
        [PSCustomObject]@{ Vendor = 'Cisco IOS';          Value = ("ip dhcp pool <name>`r`n option 43 hex {0}" -f $plain.ToLower()) }
        [PSCustomObject]@{ Vendor = 'UniFi gateway';      Value = ("Network settings > DHCP > Advanced > Option 43 = {0}" -f $ControllerIp) }
        [PSCustomObject]@{ Vendor = 'ISC dhcpd';          Value = ("option space ubnt;`r`noption ubnt.unifi-address code 1 = ip-address;`r`noption ubnt.unifi-address {0};" -f $ControllerIp) }
    )
}

# -----------------------------------------------------------------------------
# Controller API
# -----------------------------------------------------------------------------

function ConvertTo-UfDeviceState {
    param($State)
    $n = -1
    try { $n = [int]$State } catch { return ('Unknown ({0})' -f $State) }
    switch ($n) {
        0  { return 'Offline' }
        1  { return 'Connected' }
        2  { return 'Pending Adoption' }
        4  { return 'Upgrading' }
        5  { return 'Provisioning' }
        6  { return 'Unreachable' }
        7  { return 'Adopting' }
        8  { return 'Deleting' }
        9  { return 'Inform error' }
        10 { return 'Adopt failed' }
        11 { return 'Isolated' }
        default { return ('Unknown ({0})' -f $n) }
    }
}

function Connect-UfController {
    # Classic self-hosted Network Application first (login on :8443), then
    # UniFi OS (login on :443, everything else under /proxy/network). The
    # returned object carries whichever shape succeeded so later calls can
    # build the right URL.
    param(
        [string]$ComputerName,
        [int]$Port = 8443,
        [string]$Username,
        [string]$Password
    )
    Enable-UfTls
    $out = [PSCustomObject]@{
        Connected = $false
        BaseUrl   = ''
        ApiPrefix = ''
        UniFiOs   = $false
        Session   = $null
        CsrfToken = ''
        Error     = ''
    }

    $body = (@{ username = $Username; password = $Password } | ConvertTo-Json -Compress)

    # --- classic -------------------------------------------------------------
    $base = ('https://{0}:{1}' -f $ComputerName, $Port)
    try {
        $resp = Invoke-WebRequest -Uri ($base + '/api/login') -Method Post -Body $body `
                    -ContentType 'application/json' -SessionVariable sess -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
        $parsed = $null
        try { $parsed = $resp.Content | ConvertFrom-Json } catch { }
        if ($parsed -and $parsed.meta -and $parsed.meta.rc -eq 'ok') {
            $out.Connected = $true
            $out.BaseUrl   = $base
            $out.ApiPrefix = '/api'
            $out.Session   = $sess
            return $out
        }
        $out.Error = 'Login rejected by the controller.'
    } catch {
        $out.Error = $_.Exception.Message
    }

    # --- UniFi OS ------------------------------------------------------------
    $osBase = ('https://{0}' -f $ComputerName)
    try {
        $resp = Invoke-WebRequest -Uri ($osBase + '/api/auth/login') -Method Post -Body $body `
                    -ContentType 'application/json' -SessionVariable sess2 -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
        if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) {
            $out.Connected = $true
            $out.BaseUrl   = $osBase
            $out.ApiPrefix = '/proxy/network/api'
            $out.UniFiOs   = $true
            $out.Session   = $sess2
            if ($resp.Headers['X-CSRF-Token']) { $out.CsrfToken = [string]$resp.Headers['X-CSRF-Token'] }
            $out.Error = ''
            return $out
        }
    } catch {
        if (-not $out.Error) { $out.Error = $_.Exception.Message }
    }

    if (-not $out.Error) { $out.Error = 'Could not log in to the controller.' }
    return $out
}

function Invoke-UfApi {
    param(
        $Connection,
        [string]$Path,
        [string]$Method = 'Get',
        $Body = $null
    )
    if (-not $Connection -or -not $Connection.Connected) { throw 'Not connected to the controller.' }
    Enable-UfTls
    $uri = $Connection.BaseUrl + $Connection.ApiPrefix + $Path
    $headers = @{}
    if ($Connection.CsrfToken) { $headers['X-CSRF-Token'] = $Connection.CsrfToken }

    $params = @{
        Uri             = $uri
        Method          = $Method
        WebSession      = $Connection.Session
        UseBasicParsing = $true
        TimeoutSec      = 25
        ErrorAction     = 'Stop'
    }
    if ($headers.Count -gt 0) { $params['Headers'] = $headers }
    if ($Body) {
        $params['Body']        = ($Body | ConvertTo-Json -Compress)
        $params['ContentType'] = 'application/json'
    }
    $resp = Invoke-WebRequest @params
    # Assign first, then use. @($resp.Content | ConvertFrom-Json) collapses a
    # JSON array into a single object - which would silently reduce a whole
    # device list to one row.
    $parsed = $resp.Content | ConvertFrom-Json
    return $parsed
}

function Get-UfControllerSites {
    param($Connection)
    $sites = [System.Collections.Generic.List[object]]::new()
    try {
        $parsed = Invoke-UfApi -Connection $Connection -Path '/self/sites'
        foreach ($s in @($parsed.data)) {
            $sites.Add([PSCustomObject]@{ Name = [string]$s.name; Description = [string]$s.desc })
        }
    } catch { }
    return @($sites)
}

function Get-UfControllerDevices {
    param($Connection, [string]$Site = 'default')
    $rows = [System.Collections.Generic.List[object]]::new()
    $parsed = Invoke-UfApi -Connection $Connection -Path ('/s/{0}/stat/device' -f $Site)
    foreach ($d in @($parsed.data)) {
        $rows.Add([PSCustomObject]@{
            Name      = if ($d.name) { [string]$d.name } else { [string]$d.model }
            Model     = [string]$d.model
            Mac       = ([string]$d.mac).ToUpper()
            IPAddress = [string]$d.ip
            State     = (ConvertTo-UfDeviceState -State $d.state)
            StateCode = [int]$d.state
            Adopted   = [bool]$d.adopted
            InformUrl = [string]$d.inform_url
            Version   = [string]$d.version
            Uptime    = [int64]$d.uptime
            LastSeen  = if ($d.last_seen) { ([DateTimeOffset]::FromUnixTimeSeconds([int64]$d.last_seen)).LocalDateTime.ToString('yyyy-MM-dd HH:mm') } else { '' }
        })
    }
    return @($rows)
}

function Get-UfSuperMgmt {
    # The decisive check for issue 1. override_inform_host lives on the special
    # "super" settings of the default site, not on the site you are viewing.
    param($Connection)
    $out = [PSCustomObject]@{ Found = $false; OverrideInformHost = $false; Hostname = ''; Error = '' }
    try {
        $parsed = Invoke-UfApi -Connection $Connection -Path '/s/default/get/setting/super_mgmt'
        foreach ($s in @($parsed.data)) {
            if ($s.PSObject.Properties.Name -contains 'override_inform_host') {
                $out.Found = $true
                $out.OverrideInformHost = [bool]$s.override_inform_host
                if ($s.PSObject.Properties.Name -contains 'hostname') { $out.Hostname = [string]$s.hostname }
            }
        }
        if (-not $out.Found) { $out.Error = 'super_mgmt returned no override_inform_host field.' }
    } catch {
        $out.Error = $_.Exception.Message
    }
    return $out
}

function Get-UfSiteMgmt {
    # The site's Device Authentication block. x_ssh_username is the account the
    # devices actually accept - 'ubnt' is only the factory default, and a site
    # that has changed it to 'admin' will refuse ubnt outright. Reading it
    # beats guessing, and x_ssh_enabled explains a refused login that has
    # nothing to do with credentials at all.
    param($Connection, [string]$Site = 'default')
    $out = [PSCustomObject]@{ Found = $false; SshUsername = ''; SshEnabled = $null; Error = '' }
    try {
        $parsed = Invoke-UfApi -Connection $Connection -Path ('/s/{0}/get/setting/mgmt' -f $Site)
        foreach ($s in @($parsed.data)) {
            $names = $s.PSObject.Properties.Name
            if ($names -contains 'x_ssh_username') {
                $out.Found       = $true
                $out.SshUsername = [string]$s.x_ssh_username
            }
            if ($names -contains 'x_ssh_enabled') { $out.SshEnabled = [bool]$s.x_ssh_enabled }
        }
        if (-not $out.Found) { $out.Error = 'The mgmt settings returned no x_ssh_username field.' }
    } catch {
        $out.Error = $_.Exception.Message
    }
    return $out
}

function Disconnect-UfController {
    # The logout endpoint is NOT under the same prefix as everything else on
    # UniFi OS, so the URL is built directly here rather than through
    # Invoke-UfApi. A failure is ignored - the session expires by itself.
    param($Connection)
    try {
        if (-not $Connection -or -not $Connection.Connected) { return }
        Enable-UfTls
        $uri = if ($Connection.UniFiOs) { $Connection.BaseUrl + '/api/auth/logout' } else { $Connection.BaseUrl + '/api/logout' }
        $headers = @{}
        if ($Connection.CsrfToken) { $headers['X-CSRF-Token'] = $Connection.CsrfToken }
        Invoke-WebRequest -Uri $uri -Method Post -WebSession $Connection.Session -Headers $headers `
            -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop | Out-Null
    } catch { }
}

# -----------------------------------------------------------------------------
# The full check
# -----------------------------------------------------------------------------

function Invoke-UfFullCheck {
    # Runs the whole diagnostic ladder and returns one report object. Pure
    # logic: it writes progress into $Sync but touches no controls, so it is
    # safe to call from the background runspace.
    param(
        [string]$ControllerHost,
        [int]$InformPort = 8080,
        [int]$UiPort = 8443,
        [string]$DeviceIp = '',
        $Sync = $null
    )
    $checks   = [System.Collections.Generic.List[object]]::new()
    $findings = [System.Collections.Generic.List[object]]::new()
    $report = [PSCustomObject]@{
        Timestamp      = Get-UfNow
        ControllerHost = $ControllerHost
        ControllerIp   = ''
        InformPort     = $InformPort
        UiPort         = $UiPort
        Checks         = @()
        Findings       = @()
        Adapters       = @()
        Verdict        = 'info'
        Headline       = ''
        Sub            = ''
    }

    function Set-UfProgress {
        param($S, [int]$Pct, [string]$Text)
        if ($S) { $S.Progress = $Pct; $S.Status = $Text }
    }

    # --- 1. local network ----------------------------------------------------
    Set-UfProgress $Sync 5 'Reading local network configuration...'
    $adapters = @(Get-UfLocalNetwork)
    $report.Adapters = $adapters
    $allDns = @()
    foreach ($a in $adapters) {
        $checks.Add((New-UfCheck -Check 'Adapter' -Target $a.Alias -Status 'info' `
            -Result ('{0}/{1}' -f $a.IPAddress, $a.PrefixLength) `
            -Detail ('Gateway {0}; DNS {1}' -f $a.Gateway, (@($a.DnsServers) -join ', '))))
        $allDns += @($a.DnsServers)
    }
    if ($adapters.Count -eq 0) {
        $checks.Add((New-UfCheck -Check 'Adapter' -Target '-' -Status 'fail' -Result 'No adapter with a default gateway' `
            -Detail 'This PC has no usable network path. Nothing else here will be meaningful.'))
    }

    $privateDns = @($allDns | Where-Object { Test-UfPrivateIp -IpAddress $_ })
    if ($allDns.Count -gt 0 -and $privateDns.Count -eq 0) {
        $checks.Add((New-UfCheck -Check 'DNS servers' -Target (@($allDns | Select-Object -Unique) -join ', ') -Status 'warn' `
            -Result 'Public/ISP DNS only - no local resolver' `
            -Detail 'Nothing on this network can resolve a bare hostname such as "unifi". This is the precondition for the whole incident.'))
        $findings.Add([PSCustomObject]@{ Severity = 'medium'; KbId = 3
            Text = 'This site resolves through ISP DNS only. A device that falls back to http://unifi:8080/inform has no way to look that name up.' })
    } elseif ($allDns.Count -gt 0) {
        $checks.Add((New-UfCheck -Check 'DNS servers' -Target (@($allDns | Select-Object -Unique) -join ', ') -Status 'ok' `
            -Result 'A local resolver is configured' -Detail 'A local DNS override for "unifi" is possible here.'))
    }

    # --- 2. name resolution --------------------------------------------------
    Set-UfProgress $Sync 15 'Testing DNS resolution...'
    $bare = Resolve-UfName -Name 'unifi'
    if ($bare.Resolved) {
        $checks.Add((New-UfCheck -Check 'Resolve "unifi"' -Target 'unifi' -Status 'ok' `
            -Result (@($bare.Addresses) -join ', ') `
            -Detail 'The factory default inform hostname resolves here, so a device falling back to it can still find a controller.'))
    } else {
        $checks.Add((New-UfCheck -Check 'Resolve "unifi"' -Target 'unifi' -Status 'warn' `
            -Result 'Does not resolve' `
            -Detail ('{0} - expected when there is no local DNS entry or DHCP Option 43. A device that reverts to http://unifi:8080/inform is stranded.' -f $bare.Error)))
    }

    $fqdn = Resolve-UfName -Name $ControllerHost
    if ($fqdn.Resolved) {
        $report.ControllerIp = @($fqdn.Addresses)[0]
        $checks.Add((New-UfCheck -Check 'Resolve controller' -Target $ControllerHost -Status 'ok' `
            -Result (@($fqdn.Addresses) -join ', ') -Detail 'The controller name resolves from this PC.'))
    } else {
        $checks.Add((New-UfCheck -Check 'Resolve controller' -Target $ControllerHost -Status 'fail' `
            -Result 'Does not resolve' -Detail $fqdn.Error))
        $findings.Add([PSCustomObject]@{ Severity = 'critical'; KbId = 0
            Text = ('{0} does not resolve from this PC. Check the name is right and that this PC has working DNS before going further.' -f $ControllerHost) })
    }

    $hostsHits = @(Get-UfHostsEntry -Name 'unifi')
    if ($hostsHits.Count -gt 0) {
        $checks.Add((New-UfCheck -Check 'hosts file' -Target 'unifi' -Status 'info' `
            -Result 'Entry present' `
            -Detail ((@($hostsHits) -join ' | ') + '  - note this affects THIS PC only, never the access point.')))
    }

    $o43 = @(Get-UfDhcpOption43)
    if ($o43.Count -gt 0) {
        foreach ($o in $o43) {
            $checks.Add((New-UfCheck -Check 'DHCP Option 43' -Target $o.Interface -Status 'ok' `
                -Result $o.Option43 -Detail ('This site already advertises a controller via DHCP. {0}' -f $o.Decoded)))
        }
    } else {
        $checks.Add((New-UfCheck -Check 'DHCP Option 43' -Target 'this PC' -Status 'info' `
            -Result 'Not offered (or not readable)' `
            -Detail 'Best-effort read of the DHCP options this PC received. Absence is not proof - some servers send it only to Ubiquiti vendor-class clients.'))
    }

    # --- 3. controller ports -------------------------------------------------
    Set-UfProgress $Sync 30 'Testing controller ports...'
    $matrix = @(Get-UfPortMatrix -ComputerName $ControllerHost -InformPort $InformPort -UiPort $UiPort)
    $informOpen = $false
    $uiOpen     = $false
    foreach ($p in $matrix) {
        if ($Sync -and $Sync.Cancel) { break }
        $r = Test-UfTcpPort -ComputerName $ControllerHost -Port $p.Port -TimeoutMs 3000
        $status = 'info'
        $result = if ($r.Open) { ('Open ({0} ms)' -f $r.Ms) } else { 'Closed / filtered' }
        if ($p.Severity -eq 'security') {
            $status = if ($r.Open) { 'fail' } else { 'ok' }
            if ($r.Open) {
                $findings.Add([PSCustomObject]@{ Severity = 'critical'; KbId = 13
                    Text = ('TCP {0} (MongoDB) answers from this network. The controller database should never be reachable outside the host.' -f $p.Port) })
            }
        } elseif ($p.Severity -eq 'critical') {
            $status = if ($r.Open) { 'ok' } else { 'fail' }
        } elseif ($p.Severity -eq 'high') {
            $status = if ($r.Open) { 'ok' } else { 'warn' }
        } else {
            $status = if ($r.Open) { 'ok' } else { 'info' }
        }
        $checks.Add((New-UfCheck -Check ('TCP ' + $p.Port) -Target $p.Name -Status $status -Result $result -Detail $p.Meaning))

        if ($p.Port -eq $InformPort) { $informOpen = $r.Open }
        if ($p.Port -eq $UiPort)     { $uiOpen     = $r.Open }
    }
    if (-not $informOpen) {
        $findings.Add([PSCustomObject]@{ Severity = 'critical'; KbId = 0
            Text = ('TCP {0} to {1} is not reachable. No device can be adopted until this opens - fix the NAT/port-forward before touching the access point.' -f $InformPort, $ControllerHost) })
    }

    # --- 4. STUN -------------------------------------------------------------
    Set-UfProgress $Sync 45 'Probing UDP 3478 (STUN)...'
    $stun = Test-UfStunPort -ComputerName $ControllerHost -Port 3478
    if ($stun.Answered) {
        $checks.Add((New-UfCheck -Check 'UDP 3478' -Target 'STUN keepalive' -Status 'ok' `
            -Result ('Answered ({0} ms)' -f $stun.Ms) -Detail 'Devices can keep their session alive with the controller.'))
    } else {
        $checks.Add((New-UfCheck -Check 'UDP 3478' -Target 'STUN keepalive' -Status 'warn' `
            -Result 'No answer' `
            -Detail ('{0} - advisory. Some controllers do not answer STUN from a plain client, but if devices adopt and then keep dropping offline, this is the first thing to check from the device with: nc -zvu {1} 3478' -f $stun.Error, $ControllerHost)))
    }

    # --- 5. inform endpoint --------------------------------------------------
    Set-UfProgress $Sync 60 'Probing the inform endpoint...'
    $probe = Invoke-UfInformProbe -ComputerName $ControllerHost -Port $InformPort
    if ($probe.Healthy -and $probe.StatusCode -eq 400) {
        $checks.Add((New-UfCheck -Check 'Inform endpoint' -Target $probe.Uri -Status 'ok' `
            -Result 'HTTP 400 - PASS' `
            -Detail 'HTTP 400 is the CORRECT response and means the inform service is healthy. The endpoint expects an encrypted payload from the device agent; a plain GET carries none, so it is rejected. A dead service or a firewall gives a timeout instead.'))
    } elseif ($probe.Healthy) {
        $checks.Add((New-UfCheck -Check 'Inform endpoint' -Target $probe.Uri -Status 'ok' `
            -Result ('HTTP {0}' -f $probe.StatusCode) -Detail 'Something is listening and answering on the inform port.'))
    } else {
        $checks.Add((New-UfCheck -Check 'Inform endpoint' -Target $probe.Uri -Status 'fail' `
            -Result 'No usable response' -Detail $probe.Error))
    }

    # --- 6. controller application -------------------------------------------
    Set-UfProgress $Sync 75 'Asking the controller for its status...'
    if ($uiOpen) {
        $st = Get-UfControllerStatus -ComputerName $ControllerHost -Port $UiPort
        if ($st.Up) {
            $checks.Add((New-UfCheck -Check 'Controller application' -Target $st.Uri -Status 'ok' `
                -Result ('Up, version {0}' -f $st.Version) `
                -Detail 'The Network application itself answered, not just the TCP port.'))
        } else {
            $checks.Add((New-UfCheck -Check 'Controller application' -Target $st.Uri -Status 'warn' `
                -Result 'No status response' `
                -Detail ('{0} - the port is open but the application did not answer /status. It may still be starting, or this may be a UniFi OS console where /status lives elsewhere.' -f $st.Error)))
        }
    } else {
        $checks.Add((New-UfCheck -Check 'Controller application' -Target $ControllerHost -Status 'skipped' `
            -Result 'Skipped' -Detail ('TCP {0} is closed, so there is nothing to ask.' -f $UiPort)))
    }

    # --- 7. optional device reachability -------------------------------------
    if ($DeviceIp) {
        Set-UfProgress $Sync 88 ('Testing SSH to ' + $DeviceIp + '...')
        $ssh = Test-UfTcpPort -ComputerName $DeviceIp -Port 22 -TimeoutMs 2500
        if ($ssh.Open) {
            $checks.Add((New-UfCheck -Check 'TCP 22' -Target $DeviceIp -Status 'ok' `
                -Result ('Open ({0} ms)' -f $ssh.Ms) -Detail 'You can SSH to the device to read its status and set the inform URL.'))
        } else {
            $checks.Add((New-UfCheck -Check 'TCP 22' -Target $DeviceIp -Status 'warn' `
                -Result 'No answer' `
                -Detail 'The device is not answering SSH on this address. Use Find Devices - it may have taken a different lease, or SSH may be disabled for the site.'))
        }
    }

    # --- verdict -------------------------------------------------------------
    Set-UfProgress $Sync 96 'Forming a verdict...'
    $bareOk   = $bare.Resolved
    $informOk = ($informOpen -and $probe.Healthy)

    if (-not $fqdn.Resolved) {
        $report.Verdict  = 'critical'
        $report.Headline = 'Cannot resolve the controller name from this PC'
        $report.Sub      = 'Fix DNS on this workstation, or correct the controller hostname, before troubleshooting the access point.'
    } elseif (-not $informOpen) {
        $report.Verdict  = 'critical'
        $report.Headline = ('The inform port TCP {0} is not reachable' -f $InformPort)
        $report.Sub      = 'No device can adopt until this opens. Check NAT and port forwarding at the controller end - this is not an access point problem.'
    } elseif ($informOk -and -not $bareOk) {
        $report.Verdict  = 'medium'
        $report.Headline = 'Controller path is healthy - the device just needs the right inform URL'
        $report.Sub      = ('TCP {0} is open and /inform answered correctly. "unifi" does not resolve here, which is exactly why a reset device is stranded. Run set-inform with the FQDN, then set Override Inform Host on the controller so it stops coming back.' -f $InformPort)
        $findings.Add([PSCustomObject]@{ Severity = 'high'; KbId = 1
            Text = 'The network is fine and the device is pointed at a name it cannot resolve. Treat Override Inform Host on the controller as the real fix - set-inform alone lasts only until the next provision.' })
    } elseif ($informOk) {
        $report.Verdict  = 'ok'
        $report.Headline = 'Controller reachable and the inform service is healthy'
        $report.Sub      = 'Both the name and the inform endpoint are good from here. If a device is still offline, go to Find Devices and read its status over SSH.'
    } else {
        $report.Verdict  = 'high'
        $report.Headline = 'The inform port is open but the service did not answer as expected'
        $report.Sub      = 'Something is listening on the inform port that is not a healthy UniFi controller. Check the port forward points at the right host.'
    }

    Set-UfProgress $Sync 100 'Done.'
    $report.Checks   = @($checks)
    $report.Findings = @($findings)
    return $report
}

function ConvertTo-UfHtmlReport {
    # $Report is optional. A device scan and an SSH read are a perfectly good
    # report on their own - refusing to produce one until an unrelated
    # controller check has also been run only means the finding gets saved as a
    # screenshot instead.
    param($Report = $null, $Devices = @(), $ControllerDevices = @(), $MatchedIssues = @(), $HeaderValues = $null)
    $esc = {
        param([string]$s)
        if ($null -eq $s) { return '' }
        # Quotes included: everything currently goes into element text, where
        # they are harmless, but the first attribute value anyone adds would
        # otherwise break the markup silently.
        return ([string]$s).Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;').Replace("'",'&#39;')
    }
    # Only an SSH read adds the hardware properties, so a device row may not
    # carry them. Local twin of Get-UfProp, which lives on the UI side and is
    # not available in here.
    $prop = {
        param($o, [string]$n)
        if ($null -eq $o) { return '' }
        $pp = $o.PSObject.Properties[$n]
        if ($pp) { return [string]$pp.Value }
        return ''
    }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine('<!DOCTYPE html><html><head><meta charset="utf-8"><title>UniFi Troubleshooter Report</title><style>')
    [void]$sb.AppendLine('body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#181a20;background:#fafafc}')
    [void]$sb.AppendLine('h1{font-size:20px}h2{font-size:15px;margin-top:26px;border-bottom:1px solid #dcdfe6;padding-bottom:4px}')
    [void]$sb.AppendLine('table{border-collapse:collapse;width:100%;margin-top:8px;font-size:13px}')
    [void]$sb.AppendLine('th,td{border:1px solid #dcdfe6;padding:6px 8px;text-align:left;vertical-align:top}')
    [void]$sb.AppendLine('th{background:#eef2fa}')
    [void]$sb.AppendLine('.ok{color:#127a3e;font-weight:600}.warn{color:#b06808;font-weight:600}.fail{color:#b2222a;font-weight:600}.info{color:#405280}.skipped{color:#606674}')
    [void]$sb.AppendLine('.banner{padding:12px 14px;border-radius:6px;margin:12px 0}')
    [void]$sb.AppendLine('.b-ok{background:#e8f6ed}.b-medium{background:#fdf4e3}.b-high,.b-critical{background:#fdebec}.b-info{background:#eef2fa}')
    [void]$sb.AppendLine('code{font-family:Consolas,monospace;background:#f2f3f7;padding:1px 4px;border-radius:3px}')
    [void]$sb.AppendLine('</style></head><body>')
    [void]$sb.AppendLine('<h1>UniFi Troubleshooter Report</h1>')
    $hdrHost = if ($Report) { $Report.ControllerHost } elseif ($HeaderValues) { $HeaderValues.ControllerHost } else { '' }
    $hdrIp   = if ($Report) { $Report.ControllerIp }   else { '' }
    $hdrPort = if ($Report) { $Report.InformPort }     elseif ($HeaderValues) { $HeaderValues.InformPort } else { '' }
    $hdrWhen = if ($Report) { $Report.Timestamp }      else { Get-UfNow }
    # No full check means no resolved controller IP, and empty parentheses read
    # like something failed rather than like something was not asked for.
    $hdrIpPart = if ($hdrIp) { ' (' + (& $esc $hdrIp) + ')' } else { '' }
    [void]$sb.AppendLine(('<p>{0} &middot; controller <code>{1}</code>{2} &middot; inform port {3}</p>' -f `
        (& $esc $hdrWhen), (& $esc $hdrHost), $hdrIpPart, (& $esc $hdrPort)))

    if ($Report) {
        [void]$sb.AppendLine(('<div class="banner b-{0}"><strong>{1}</strong><br>{2}</div>' -f `
            $Report.Verdict, (& $esc $Report.Headline), (& $esc $Report.Sub)))
    } else {
        [void]$sb.AppendLine('<div class="banner b-info"><strong>No full check was run for this report</strong><br>' +
            'What follows is the device scan and whatever was read from the devices themselves. Run a full check for controller reachability and the port matrix.</div>')
    }

    if ($Report -and @($Report.Findings).Count -gt 0) {
        [void]$sb.AppendLine('<h2>Findings</h2><table><tr><th>Severity</th><th>Finding</th></tr>')
        foreach ($f in @($Report.Findings)) {
            [void]$sb.AppendLine(('<tr><td class="{0}">{1}</td><td>{2}</td></tr>' -f `
                $(if ($f.Severity -eq 'critical' -or $f.Severity -eq 'high') { 'fail' } elseif ($f.Severity -eq 'medium') { 'warn' } else { 'info' }), `
                (& $esc $f.Severity), (& $esc $f.Text)))
        }
        [void]$sb.AppendLine('</table>')
    }

    if ($Report) {
    [void]$sb.AppendLine('<h2>Checks</h2><table><tr><th>Check</th><th>Target</th><th>Result</th><th>Detail</th></tr>')
    foreach ($c in @($Report.Checks)) {
        [void]$sb.AppendLine(('<tr><td>{0}</td><td>{1}</td><td class="{2}">{3}</td><td>{4}</td></tr>' -f `
            (& $esc $c.Check), (& $esc $c.Target), $c.Status, (& $esc $c.Result), (& $esc $c.Detail)))
    }
    [void]$sb.AppendLine('</table>')
    }

    if (@($Devices).Count -gt 0) {
        # Serial, board revision and manufacture week are what an asset-age
        # report is actually for, so they belong here and not only on screen.
        [void]$sb.AppendLine('<h2>Devices found on the LAN</h2><table><tr><th>IP</th><th>MAC</th><th>Serial</th><th>Model</th><th>Firmware</th><th>Board rev</th><th>Mfg week / age</th><th>Config persists</th><th>Hostname</th><th>Uptime</th><th>Factory defaults</th><th>Found by</th></tr>')
        foreach ($d in @($Devices)) {
            $def = if ($null -eq $d.IsDefault) { '' } elseif ($d.IsDefault) { 'YES' } else { 'no' }
            $serial = & $prop $d 'Serial'
            if (-not $serial) { $serial = Get-UfSerialFromMac -Mac $d.Mac }
            # Blank means not checked, not healthy - the two are very different
            # answers and the column must not blur them.
            $persist = & $prop $d 'ConfigPersists'
            $pClass  = if ($persist -like 'NO*') { 'fail' } elseif ($persist) { 'ok' } else { 'skipped' }
            [void]$sb.AppendLine(('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td><td>{5}</td><td>{6}</td><td class="{7}">{8}</td><td>{9}</td><td>{10}</td><td>{11}</td><td>{12}</td></tr>' -f `
                (& $esc $d.IPAddress), (& $esc $d.Mac), (& $esc $serial), (& $esc $d.Model), (& $esc $d.Firmware), `
                (& $esc (& $prop $d 'BoardRev')), (& $esc (Format-UfMfgWeek -Value (& $prop $d 'MfgWeek'))), `
                $pClass, (& $esc $(if ($persist) { $persist } else { 'not checked' })), `
                (& $esc $d.Hostname), (& $esc (Format-UfUptime -Seconds $d.Uptime)), $def, (& $esc $d.Source)))
        }
        [void]$sb.AppendLine('</table>')
    }

    if (@($ControllerDevices).Count -gt 0) {
        [void]$sb.AppendLine('<h2>Controller view</h2><table><tr><th>Name</th><th>Model</th><th>MAC</th><th>IP</th><th>State</th><th>Inform URL</th><th>Version</th><th>Last seen</th></tr>')
        foreach ($d in @($ControllerDevices)) {
            [void]$sb.AppendLine(('<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td><td><code>{5}</code></td><td>{6}</td><td>{7}</td></tr>' -f `
                (& $esc $d.Name), (& $esc $d.Model), (& $esc $d.Mac), (& $esc $d.IPAddress), `
                (& $esc $d.State), (& $esc $d.InformUrl), (& $esc $d.Version), (& $esc $d.LastSeen)))
        }
        [void]$sb.AppendLine('</table>')
    }

    # The tool works out which known issues this site matches and highlights
    # them on screen. Leaving them out of the saved report drops the half a
    # technician is meant to act on.
    if (@($MatchedIssues).Count -gt 0) {
        [void]$sb.AppendLine('<h2>Known issues matching this site</h2>')
        foreach ($k in @($MatchedIssues)) {
            $cls = if ($k.Severity -eq 'critical' -or $k.Severity -eq 'high') { 'fail' } elseif ($k.Severity -eq 'medium') { 'warn' } else { 'info' }
            [void]$sb.AppendLine(('<h3 style="font-size:14px;margin-bottom:2px">#{0} <span class="{1}">{2}</span> - {3}</h3>' -f `
                $k.Id, $cls, (& $esc $k.Severity), (& $esc $k.Title)))
            [void]$sb.AppendLine(('<p style="margin:2px 0"><strong>Symptom</strong> {0}</p>' -f (& $esc $k.Symptom)))
            [void]$sb.AppendLine(('<p style="margin:2px 0"><strong>Confirm</strong> {0}</p>' -f (& $esc $k.Confirm)))
            [void]$sb.AppendLine(('<p style="margin:2px 0"><strong>Fix</strong> {0}</p>' -f (& $esc $k.Fix)))
        }
    }

    [void]$sb.AppendLine('<p style="margin-top:24px;color:#606674;font-size:12px">Generated by UniFi-Troubleshooter-Gui.ps1. Credentials are never written to this report.</p>')
    [void]$sb.AppendLine('</body></html>')
    return $sb.ToString()
}

# =============================================================================
#UFHELPERS_END
# =============================================================================

# =============================================================================
# Extract the helper region as text
# =============================================================================
# The background runspace does not inherit this session's functions, so the
# helper region is re-created there from its own source text. The marker
# strings are assembled from pieces so that this lookup does not match itself.

$script:HelpersText = ''
try {
    $selfRaw = ''
    if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath)) {
        $selfRaw = Get-Content -LiteralPath $PSCommandPath -Raw
    }
    if (-not $selfRaw) { $selfRaw = $MyInvocation.MyCommand.ScriptBlock.ToString() }

    $markerBegin = '#UF' + 'HELPERS_BEGIN'
    $markerEnd   = '#UF' + 'HELPERS_END'
    $iStart = $selfRaw.IndexOf($markerBegin)
    $iEnd   = $selfRaw.IndexOf($markerEnd)
    if ($iStart -ge 0 -and $iEnd -gt $iStart) {
        $script:HelpersText = $selfRaw.Substring($iStart, $iEnd - $iStart)
    }
} catch { }

# Shared state between the UI thread and the worker. Exactly one object crosses
# the boundary; the worker writes, a WinForms timer reads. No control is ever
# touched from the background thread, which is what usually kills these tools.
$script:Sync = [hashtable]::Synchronized(@{
    Running  = $false
    Cancel   = $false
    Status   = ''
    Progress = 0
    Result   = $null
    Error    = ''
    Kind     = ''
})

$script:Worker            = $null
$script:WorkerAsync       = $null
$script:Report            = $null
$script:Devices           = @()
$script:ControllerConn    = $null
$script:ControllerDevices = @()
$script:SuperMgmt         = $null
$script:SiteMgmt          = $null
$script:PuttyPath         = ''
$script:PlinkPath         = ''
$script:PlinkIp           = ''
$script:MatchedKb         = @()

# =============================================================================
# Form
# =============================================================================

$form = New-Object System.Windows.Forms.Form
$form.Text            = 'UniFi Troubleshooter - controller reachability, device discovery and L3 adoption'
$form.Size            = New-Object System.Drawing.Size(1180, 830)
$form.MinimumSize     = New-Object System.Drawing.Size(980, 640)
$form.StartPosition   = 'CenterScreen'
$form.BackColor       = $UfColorBg
$form.Font            = $UfFontUi

# --- header -----------------------------------------------------------------
$panelTop = New-Object System.Windows.Forms.Panel
$panelTop.Dock      = 'Top'
$panelTop.Height    = 96
$panelTop.BackColor = $UfColorPanel
$panelTop.Padding   = New-Object System.Windows.Forms.Padding(12, 8, 12, 8)
$form.Controls.Add($panelTop)

function New-UfLabel {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width = 90, $Color = $null)
    $l = New-Object System.Windows.Forms.Label
    $l.Text      = $Text
    $l.Location  = New-Object System.Drawing.Point($X, ($Y + 3))
    $l.Size      = New-Object System.Drawing.Size($Width, 18)
    $l.ForeColor = if ($Color) { $Color } else { $UfColorMuted }
    return $l
}
function New-UfTextBox {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Text     = $Text
    $t.Location = New-Object System.Drawing.Point($X, $Y)
    $t.Size     = New-Object System.Drawing.Size($Width, 22)
    return $t
}

$panelTop.Controls.Add((New-UfLabel -Text 'Controller host' -X 4 -Y 6 -Width 88))
$txtHost = New-UfTextBox -Text $ControllerHost -X 96 -Y 6 -Width 210
$panelTop.Controls.Add($txtHost)

$panelTop.Controls.Add((New-UfLabel -Text 'Inform port' -X 320 -Y 6 -Width 70))
$txtInform = New-UfTextBox -Text ([string]$InformPort) -X 392 -Y 6 -Width 56
$panelTop.Controls.Add($txtInform)

$panelTop.Controls.Add((New-UfLabel -Text 'UI port' -X 460 -Y 6 -Width 46))
$txtUi = New-UfTextBox -Text ([string]$UiPort) -X 508 -Y 6 -Width 56
$panelTop.Controls.Add($txtUi)

$panelTop.Controls.Add((New-UfLabel -Text 'Device IP' -X 578 -Y 6 -Width 58))
$txtDevice = New-UfTextBox -Text $DeviceIp -X 638 -Y 6 -Width 130
$panelTop.Controls.Add($txtDevice)

$btnRunAll = New-Object System.Windows.Forms.Button
$btnRunAll.Text     = 'Run full check'
$btnRunAll.Location = New-Object System.Drawing.Point(790, 4)
$btnRunAll.Size     = New-Object System.Drawing.Size(120, 27)
$btnRunAll.Font     = $UfFontBold
$panelTop.Controls.Add($btnRunAll)

$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text     = 'Cancel'
$btnCancel.Location = New-Object System.Drawing.Point(918, 4)
$btnCancel.Size     = New-Object System.Drawing.Size(80, 27)
$btnCancel.Enabled  = $false
$panelTop.Controls.Add($btnCancel)

$panelTop.Controls.Add((New-UfLabel -Text 'Portal URL' -X 4 -Y 36 -Width 88))
$txtPortal = New-UfTextBox -Text $PortalUrl -X 96 -Y 36 -Width 352
$panelTop.Controls.Add($txtPortal)

$btnPortal = New-Object System.Windows.Forms.Button
$btnPortal.Text     = 'Open UniFi portal'
$btnPortal.Location = New-Object System.Drawing.Point(456, 35)
$btnPortal.Size     = New-Object System.Drawing.Size(130, 24)
$panelTop.Controls.Add($btnPortal)

$btnUisp = New-Object System.Windows.Forms.Button
$btnUisp.Text     = 'Open UISP'
$btnUisp.Location = New-Object System.Drawing.Point(592, 35)
$btnUisp.Size     = New-Object System.Drawing.Size(90, 24)
$panelTop.Controls.Add($btnUisp)

# Kept short so it cannot clip against the SSH user control; the full
# explanation is in the confirmation dialog that opening UISP raises.
$lblUispNote = New-UfLabel -Text '(a different platform)' -X 688 -Y 36 -Width 140
$lblUispNote.ForeColor = $UfColorMuted
$panelTop.Controls.Add($lblUispNote)

# SSH username lives in the header, not on the PuTTY tab, because both the
# generated command blocks and the plink actions need it. One control, one
# source of truth. Editable combo: 'ubnt' is the factory default and 'admin' a
# common site override, but Device Authentication can be set to anything.
$lblSshUser = New-UfLabel -Text 'SSH user' -X 996 -Y 36 -Width 56
$panelTop.Controls.Add($lblSshUser)
$txtSshUser = New-Object System.Windows.Forms.ComboBox
$txtSshUser.Location      = New-Object System.Drawing.Point(1054, 35)
$txtSshUser.Size          = New-Object System.Drawing.Size(96, 22)
$txtSshUser.DropDownStyle = 'DropDown'
[void]$txtSshUser.Items.AddRange(@('ubnt', 'admin'))
$txtSshUser.Text          = $SshUser
$panelTop.Controls.Add($txtSshUser)

# --- verdict banner ---------------------------------------------------------
$panelVerdict = New-Object System.Windows.Forms.Panel
$panelVerdict.Dock      = 'Top'
$panelVerdict.Height    = 56
$panelVerdict.BackColor = $UfColorInfoBg
$panelVerdict.Padding   = New-Object System.Windows.Forms.Padding(12, 6, 12, 6)
$form.Controls.Add($panelVerdict)

$lblVerdict = New-Object System.Windows.Forms.Label
$lblVerdict.Text      = 'Ready. Check the controller host above, then Run full check.'
$lblVerdict.Font      = $UfFontHead
$lblVerdict.ForeColor = $UfColorInfo
$lblVerdict.Location  = New-Object System.Drawing.Point(12, 6)
$lblVerdict.Size      = New-Object System.Drawing.Size(1120, 22)
$lblVerdict.AutoEllipsis = $true
$panelVerdict.Controls.Add($lblVerdict)

$lblVerdictSub = New-Object System.Windows.Forms.Label
$lblVerdictSub.Text      = 'Everything here is read-only until you use a plink action or the factory-reset command.'
$lblVerdictSub.ForeColor = $UfColorText
$lblVerdictSub.Location  = New-Object System.Drawing.Point(12, 30)
$lblVerdictSub.Size      = New-Object System.Drawing.Size(1120, 20)
$lblVerdictSub.AutoEllipsis = $true
$panelVerdict.Controls.Add($lblVerdictSub)

# --- bottom strip -----------------------------------------------------------
$panelBottom = New-Object System.Windows.Forms.Panel
$panelBottom.Dock      = 'Bottom'
$panelBottom.Height    = 42
$panelBottom.BackColor = $UfColorPanel
$form.Controls.Add($panelBottom)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(12, 10)
$progress.Size     = New-Object System.Drawing.Size(220, 20)
$panelBottom.Controls.Add($progress)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text      = 'Idle'
$lblStatus.Location  = New-Object System.Drawing.Point(242, 13)
$lblStatus.Size      = New-Object System.Drawing.Size(620, 18)
$lblStatus.ForeColor = $UfColorMuted
$lblStatus.AutoEllipsis = $true
$panelBottom.Controls.Add($lblStatus)

$btnSaveReport = New-Object System.Windows.Forms.Button
$btnSaveReport.Text     = 'Save report'
$btnSaveReport.Location = New-Object System.Drawing.Point(1030, 8)
$btnSaveReport.Size     = New-Object System.Drawing.Size(110, 26)
$panelBottom.Controls.Add($btnSaveReport)

# --- tabs -------------------------------------------------------------------
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$tabs.Padding = New-Object System.Drawing.Point(12, 5)
$form.Controls.Add($tabs)
$tabs.BringToFront()

$tabDiag  = New-Object System.Windows.Forms.TabPage; $tabDiag.Text  = 'Diagnostics';   $tabDiag.BackColor  = $UfColorBg
$tabFind  = New-Object System.Windows.Forms.TabPage; $tabFind.Text  = 'Find Devices';  $tabFind.BackColor  = $UfColorBg
$tabSsh   = New-Object System.Windows.Forms.TabPage; $tabSsh.Text   = 'SSH Commands';  $tabSsh.BackColor   = $UfColorBg
$tabPutty = New-Object System.Windows.Forms.TabPage; $tabPutty.Text = 'PuTTY';         $tabPutty.BackColor = $UfColorBg
$tabCtrl  = New-Object System.Windows.Forms.TabPage; $tabCtrl.Text  = 'Controller';    $tabCtrl.BackColor  = $UfColorBg
$tabKb    = New-Object System.Windows.Forms.TabPage; $tabKb.Text    = 'Known Issues';  $tabKb.BackColor    = $UfColorBg
$tabLog   = New-Object System.Windows.Forms.TabPage; $tabLog.Text   = 'Log';           $tabLog.BackColor   = $UfColorBg
$tabs.TabPages.AddRange(@($tabDiag, $tabFind, $tabSsh, $tabPutty, $tabCtrl, $tabKb, $tabLog))

function Add-UfListRow {
    param($ListView, [string[]]$Values, [string]$Status = '', $Tag = $null)
    $item = New-Object System.Windows.Forms.ListViewItem($Values[0])
    for ($i = 1; $i -lt $Values.Count; $i++) {
        [void]$item.SubItems.Add([string]$Values[$i])
    }
    if ($Status) { $item.ForeColor = Get-UfStatusColor -Status $Status }
    if ($Tag) { $item.Tag = $Tag }
    [void]$ListView.Items.Add($item)
    return $item
}

# --- Tab 1: Diagnostics -----------------------------------------------------
$splitDiag = New-Object System.Windows.Forms.SplitContainer
$splitDiag.Dock        = 'Fill'
$splitDiag.Orientation = 'Horizontal'
$tabDiag.Controls.Add($splitDiag)

$lvChecks = New-Object System.Windows.Forms.ListView
$lvChecks.Dock          = 'Fill'
$lvChecks.View          = 'Details'
$lvChecks.FullRowSelect = $true
$lvChecks.GridLines     = $true
$lvChecks.HideSelection = $false
[void]$lvChecks.Columns.Add('Check', 150)
[void]$lvChecks.Columns.Add('Target', 210)
[void]$lvChecks.Columns.Add('Result', 200)
[void]$lvChecks.Columns.Add('What it means', 560)
$splitDiag.Panel1.Controls.Add($lvChecks)

$rtbFindings = New-Object System.Windows.Forms.RichTextBox
$rtbFindings.Dock       = 'Fill'
$rtbFindings.ReadOnly   = $true
$rtbFindings.BackColor  = $UfColorPanel
$rtbFindings.Font       = $UfFontUi
$rtbFindings.Text       = 'Findings appear here after a check.'
$splitDiag.Panel2.Controls.Add($rtbFindings)

# --- Tab 2: Find Devices ----------------------------------------------------
$panelFindTop = New-Object System.Windows.Forms.Panel
$panelFindTop.Dock      = 'Top'
$panelFindTop.Height    = 74
$panelFindTop.BackColor = $UfColorPanel
$tabFind.Controls.Add($panelFindTop)

$btnScan = New-Object System.Windows.Forms.Button
$btnScan.Text     = 'Scan for UniFi devices'
$btnScan.Location = New-Object System.Drawing.Point(8, 7)
$btnScan.Size     = New-Object System.Drawing.Size(160, 26)
$btnScan.Font     = $UfFontBold
$panelFindTop.Controls.Add($btnScan)

$chkPingSweep = New-Object System.Windows.Forms.CheckBox
$chkPingSweep.Text     = 'Also ping-sweep the local /24 (slower, finds more)'
$chkPingSweep.Location = New-Object System.Drawing.Point(178, 10)
$chkPingSweep.Size     = New-Object System.Drawing.Size(300, 20)
$chkPingSweep.Checked  = $true
$panelFindTop.Controls.Add($chkPingSweep)

$btnUsePutty = New-Object System.Windows.Forms.Button
$btnUsePutty.Text     = 'Open PuTTY to selected'
$btnUsePutty.Location = New-Object System.Drawing.Point(486, 7)
$btnUsePutty.Size     = New-Object System.Drawing.Size(150, 26)
$panelFindTop.Controls.Add($btnUsePutty)

$btnUseDevice = New-Object System.Windows.Forms.Button
$btnUseDevice.Text     = 'Use selected as Device IP'
$btnUseDevice.Location = New-Object System.Drawing.Point(644, 7)
$btnUseDevice.Size     = New-Object System.Drawing.Size(160, 26)
$panelFindTop.Controls.Add($btnUseDevice)

# Selecting a row already sets the header Device IP; this says so, because a
# field that changed on a different tab is a change nobody sees happen.
$lblFindSel = New-Object System.Windows.Forms.Label
$lblFindSel.Location  = New-Object System.Drawing.Point(812, 12)
$lblFindSel.Size      = New-Object System.Drawing.Size(320, 18)
$lblFindSel.ForeColor = $UfColorMuted
$lblFindSel.Text      = 'Device IP: none selected'
$lblFindSel.AutoEllipsis = $true
$panelFindTop.Controls.Add($lblFindSel)

# Serial, board revision and mfg week are not in the discovery broadcast - the
# only place a device carries them is /proc/ubnthal/system.info, which means an
# SSH round trip. Second row so the discovery controls above stay where they
# were, and next to a line that says what it costs.
$btnHwInfo = New-Object System.Windows.Forms.Button
$btnHwInfo.Text     = 'Read hardware info (SSH)'
$btnHwInfo.Location = New-Object System.Drawing.Point(8, 41)
$btnHwInfo.Size     = New-Object System.Drawing.Size(170, 26)
$panelFindTop.Controls.Add($btnHwInfo)

$btnPersist = New-Object System.Windows.Forms.Button
$btnPersist.Text     = 'Check config persistence'
$btnPersist.Location = New-Object System.Drawing.Point(186, 41)
$btnPersist.Size     = New-Object System.Drawing.Size(170, 26)
$panelFindTop.Controls.Add($btnPersist)

# Two lines on purpose. A single-line hint has to be trimmed until it says
# nothing, and it still clips the moment the window is restored down.
$lblHwHint = New-Object System.Windows.Forms.Label
$lblHwHint.Location  = New-Object System.Drawing.Point(364, 38)
$lblHwHint.Size      = New-Object System.Drawing.Size(620, 32)
$lblHwHint.ForeColor = $UfColorMuted
$lblHwHint.Text      = 'Both read the selected device over SSH and change nothing, using the PuTTY tab password. Persistence answers "will this survive a power cut" - the one for a device that keeps reverting to unifi:8080.'
$panelFindTop.Controls.Add($lblHwHint)

$lvDevices = New-Object System.Windows.Forms.ListView
$lvDevices.Dock          = 'Fill'
$lvDevices.View          = 'Details'
$lvDevices.FullRowSelect = $true
$lvDevices.GridLines     = $true
$lvDevices.HideSelection = $false
[void]$lvDevices.Columns.Add('IP address', 130)
[void]$lvDevices.Columns.Add('MAC', 140)
# UniFi serials ARE the MAC, so this one is filled in for every device from the
# start. Board rev and mfg week stay empty until someone reads them over SSH -
# an empty cell here means not read, not absent.
[void]$lvDevices.Columns.Add('Serial (from MAC)', 130)
[void]$lvDevices.Columns.Add('Model', 110)
[void]$lvDevices.Columns.Add('Firmware', 150)
[void]$lvDevices.Columns.Add('Board rev', 80)
[void]$lvDevices.Columns.Add('Mfg week / age', 200)
[void]$lvDevices.Columns.Add('Hostname', 150)
[void]$lvDevices.Columns.Add('Uptime', 90)
[void]$lvDevices.Columns.Add('Factory defaults', 100)
[void]$lvDevices.Columns.Add('Found by', 120)
[void]$lvDevices.Columns.Add('Other fields', 220)
$tabFind.Controls.Add($lvDevices)
$lvDevices.BringToFront()

$lblFindHint = New-Object System.Windows.Forms.Label
$lblFindHint.Dock      = 'Bottom'
$lblFindHint.Height    = 50
$lblFindHint.ForeColor = $UfColorMuted
$lblFindHint.Text      = 'Click a device to make it the header Device IP - the SSH command blocks and both PuTTY buttons follow it. Double-click jumps straight to the commands. ARP finds devices this PC has spoken to. UDP 10001 discovery also finds unadopted devices and devices holding an address from another subnet - it is the one that finds an AP after a long outage. Windows Firewall can suppress the replies; if the list looks short, the ARP and ping-sweep results still stand.'
$tabFind.Controls.Add($lblFindHint)

# --- Tab 3: SSH Commands ----------------------------------------------------
$panelSshTop = New-Object System.Windows.Forms.Panel
$panelSshTop.Dock      = 'Top'
$panelSshTop.Height    = 68
$panelSshTop.BackColor = $UfColorPanel
$tabSsh.Controls.Add($panelSshTop)

$lblSshFor = New-Object System.Windows.Forms.Label
$lblSshFor.Location  = New-Object System.Drawing.Point(8, 8)
$lblSshFor.Size      = New-Object System.Drawing.Size(700, 18)
$lblSshFor.Font      = $UfFontBold
$lblSshFor.Text      = 'Commands for <no device selected>'
$panelSshTop.Controls.Add($lblSshFor)

$lblSshHint = New-Object System.Windows.Forms.Label
$lblSshHint.Location  = New-Object System.Drawing.Point(8, 30)
$lblSshHint.Size      = New-Object System.Drawing.Size(900, 34)
$lblSshHint.ForeColor = $UfColorMuted
$lblSshHint.Text      = 'Every block below is built from the host, port and device IP currently in the header - change those and press Refresh. Use Copy rather than retyping; Backstage sessions swallow keystrokes.'
$panelSshTop.Controls.Add($lblSshHint)

$btnSshRefresh = New-Object System.Windows.Forms.Button
$btnSshRefresh.Text     = 'Refresh'
$btnSshRefresh.Location = New-Object System.Drawing.Point(930, 6)
$btnSshRefresh.Size     = New-Object System.Drawing.Size(90, 26)
$panelSshTop.Controls.Add($btnSshRefresh)

$btnCopyAllSsh = New-Object System.Windows.Forms.Button
$btnCopyAllSsh.Text     = 'Copy all'
$btnCopyAllSsh.Location = New-Object System.Drawing.Point(1026, 6)
$btnCopyAllSsh.Size     = New-Object System.Drawing.Size(90, 26)
$panelSshTop.Controls.Add($btnCopyAllSsh)

$flowSsh = New-Object System.Windows.Forms.FlowLayoutPanel
$flowSsh.Dock          = 'Fill'
$flowSsh.FlowDirection = 'TopDown'
$flowSsh.WrapContents  = $false
$flowSsh.AutoScroll    = $true
$flowSsh.BackColor     = $UfColorBg
$flowSsh.Padding       = New-Object System.Windows.Forms.Padding(8)
$tabSsh.Controls.Add($flowSsh)
$flowSsh.BringToFront()

# --- Tab 4: PuTTY -----------------------------------------------------------
$panelPuttyTop = New-Object System.Windows.Forms.Panel
$panelPuttyTop.Dock      = 'Top'
$panelPuttyTop.Height    = 108
$panelPuttyTop.BackColor = $UfColorPanel
$tabPutty.Controls.Add($panelPuttyTop)

$lblPuttyIntro = New-Object System.Windows.Forms.Label
$lblPuttyIntro.Location  = New-Object System.Drawing.Point(8, 8)
$lblPuttyIntro.Size      = New-Object System.Drawing.Size(1100, 34)
$lblPuttyIntro.Text      = "Downloads putty.exe and plink.exe from the author's release path into C:\ProgramData\UniFiTroubleshooter\Tools, checks the Authenticode signature, and refuses to launch anything that is not validly signed. An existing copy is reused rather than re-downloaded."
$panelPuttyTop.Controls.Add($lblPuttyIntro)

$btnGetPutty = New-Object System.Windows.Forms.Button
$btnGetPutty.Text     = 'Download / verify PuTTY'
$btnGetPutty.Location = New-Object System.Drawing.Point(8, 48)
$btnGetPutty.Size     = New-Object System.Drawing.Size(170, 28)
$btnGetPutty.Font     = $UfFontBold
$panelPuttyTop.Controls.Add($btnGetPutty)

$btnLaunchPutty = New-Object System.Windows.Forms.Button
$btnLaunchPutty.Text     = 'Launch PuTTY to device'
$btnLaunchPutty.Location = New-Object System.Drawing.Point(186, 48)
$btnLaunchPutty.Size     = New-Object System.Drawing.Size(160, 28)
# The label carries the username, so the account being used is visible from the
# button itself rather than only after a failed login.
$btnLaunchPutty.AutoEllipsis = $true
$panelPuttyTop.Controls.Add($btnLaunchPutty)

$btnOpenToolDir = New-Object System.Windows.Forms.Button
$btnOpenToolDir.Text     = 'Open tools folder'
$btnOpenToolDir.Location = New-Object System.Drawing.Point(354, 48)
$btnOpenToolDir.Size     = New-Object System.Drawing.Size(130, 28)
$panelPuttyTop.Controls.Add($btnOpenToolDir)

# The same SSH username as the header combo, shown again here because this is
# where a technician looks for it. A Launch button sitting next to a username
# that lives off at the far right of the header is how "it always logs in as
# ubnt" happens. Both controls edit one value - see Copy-UfSshUser below.
$panelPuttyTop.Controls.Add((New-UfLabel -Text 'SSH user' -X 498 -Y 50 -Width 54))
$cboPuttyUser = New-Object System.Windows.Forms.ComboBox
$cboPuttyUser.Location      = New-Object System.Drawing.Point(554, 50)
$cboPuttyUser.Size          = New-Object System.Drawing.Size(120, 22)
$cboPuttyUser.DropDownStyle = 'DropDown'
[void]$cboPuttyUser.Items.AddRange(@('ubnt', 'admin'))
$cboPuttyUser.Text          = $SshUser
$panelPuttyTop.Controls.Add($cboPuttyUser)

$lblPuttyUserHint = New-UfLabel -Text 'ubnt is only the factory default; many sites use admin.' -X 684 -Y 50 -Width 340
$panelPuttyTop.Controls.Add($lblPuttyUserHint)

$lblPuttyState = New-Object System.Windows.Forms.Label
$lblPuttyState.Location  = New-Object System.Drawing.Point(8, 82)
$lblPuttyState.Size      = New-Object System.Drawing.Size(1100, 18)
$lblPuttyState.ForeColor = $UfColorMuted
$lblPuttyState.Text      = 'Not checked yet.'
$panelPuttyTop.Controls.Add($lblPuttyState)

$rtbPutty = New-Object System.Windows.Forms.RichTextBox
$rtbPutty.Dock      = 'Fill'
$rtbPutty.ReadOnly  = $true
$rtbPutty.Font      = $UfFontMono
$rtbPutty.BackColor = $UfColorPanel
$tabPutty.Controls.Add($rtbPutty)
$rtbPutty.BringToFront()

# --- plink action strip (lives on the PuTTY tab) ----------------------------
$panelPlink = New-Object System.Windows.Forms.Panel
$panelPlink.Dock      = 'Bottom'
$panelPlink.Height    = 96
$panelPlink.BackColor = $UfColorInfoBg
$tabPutty.Controls.Add($panelPlink)

$lblPlinkHead = New-Object System.Windows.Forms.Label
$lblPlinkHead.Location = New-Object System.Drawing.Point(8, 6)
$lblPlinkHead.Size     = New-Object System.Drawing.Size(600, 18)
$lblPlinkHead.Font     = $UfFontBold
$lblPlinkHead.Text     = 'Run a command on the device without opening a terminal'
$panelPlink.Controls.Add($lblPlinkHead)

$panelPlink.Controls.Add((New-UfLabel -Text 'Device password' -X 8 -Y 30 -Width 96))
$txtSshPass = New-UfTextBox -Text '' -X 108 -Y 30 -Width 150
$txtSshPass.UseSystemPasswordChar = $true
$panelPlink.Controls.Add($txtSshPass)

$btnPlinkInfo = New-Object System.Windows.Forms.Button
$btnPlinkInfo.Text     = 'Get device info'
$btnPlinkInfo.Location = New-Object System.Drawing.Point(272, 29)
$btnPlinkInfo.Size     = New-Object System.Drawing.Size(120, 26)
$panelPlink.Controls.Add($btnPlinkInfo)

$btnPlinkInform = New-Object System.Windows.Forms.Button
$btnPlinkInform.Text     = 'Send set-inform'
$btnPlinkInform.Location = New-Object System.Drawing.Point(400, 29)
$btnPlinkInform.Size     = New-Object System.Drawing.Size(120, 26)
$panelPlink.Controls.Add($btnPlinkInform)

$lblPlinkUser = New-Object System.Windows.Forms.Label
$lblPlinkUser.Location  = New-Object System.Drawing.Point(530, 33)
$lblPlinkUser.Size      = New-Object System.Drawing.Size(420, 18)
$lblPlinkUser.ForeColor = $UfColorMuted
$lblPlinkUser.Text      = 'connecting as ubnt - change the SSH user above'
$panelPlink.Controls.Add($lblPlinkUser)

$lblPlinkWarn = New-Object System.Windows.Forms.Label
$lblPlinkWarn.Location  = New-Object System.Drawing.Point(8, 60)
$lblPlinkWarn.Size      = New-Object System.Drawing.Size(1100, 32)
$lblPlinkWarn.ForeColor = $UfColorMuted
$lblPlinkWarn.Text      = 'The password is held in memory for this session only, written to a temporary file that is deleted immediately after each run, and never saved to a report. plink is given -pwfile rather than -pw so it does not appear in the process list. The device host key is accepted automatically on first connect.'
$panelPlink.Controls.Add($lblPlinkWarn)

# --- Tab 5: Controller ------------------------------------------------------
$panelCtrlTop = New-Object System.Windows.Forms.Panel
$panelCtrlTop.Dock      = 'Top'
$panelCtrlTop.Height    = 96
$panelCtrlTop.BackColor = $UfColorPanel
$tabCtrl.Controls.Add($panelCtrlTop)

$lblCtrlIntro = New-Object System.Windows.Forms.Label
$lblCtrlIntro.Location  = New-Object System.Drawing.Point(8, 6)
$lblCtrlIntro.Size      = New-Object System.Drawing.Size(1100, 30)
$lblCtrlIntro.Text      = 'Optional. Logging in lets this tool read what the CONTROLLER thinks - each device state, its stored inform URL, and whether Override Inform Host is switched on. That last one settles the most common cause of a device reverting to http://unifi:8080/inform after a reboot.'
$panelCtrlTop.Controls.Add($lblCtrlIntro)

$panelCtrlTop.Controls.Add((New-UfLabel -Text 'Username' -X 8 -Y 42 -Width 62))
$txtApiUser = New-UfTextBox -Text '' -X 74 -Y 42 -Width 160
$panelCtrlTop.Controls.Add($txtApiUser)

$panelCtrlTop.Controls.Add((New-UfLabel -Text 'Password' -X 246 -Y 42 -Width 60))
$txtApiPass = New-UfTextBox -Text '' -X 310 -Y 42 -Width 160
$txtApiPass.UseSystemPasswordChar = $true
$panelCtrlTop.Controls.Add($txtApiPass)

$panelCtrlTop.Controls.Add((New-UfLabel -Text 'Site' -X 482 -Y 42 -Width 30))
$cboSite = New-Object System.Windows.Forms.ComboBox
$cboSite.Location      = New-Object System.Drawing.Point(514, 42)
$cboSite.Size          = New-Object System.Drawing.Size(160, 22)
$cboSite.DropDownStyle = 'DropDownList'
[void]$cboSite.Items.Add('default')
$cboSite.SelectedIndex = 0
$panelCtrlTop.Controls.Add($cboSite)

$btnApiConnect = New-Object System.Windows.Forms.Button
$btnApiConnect.Text     = 'Connect and read devices'
$btnApiConnect.Location = New-Object System.Drawing.Point(686, 41)
$btnApiConnect.Size     = New-Object System.Drawing.Size(170, 26)
$btnApiConnect.Font     = $UfFontBold
$panelCtrlTop.Controls.Add($btnApiConnect)

$btnApiRefresh = New-Object System.Windows.Forms.Button
$btnApiRefresh.Text     = 'Refresh'
$btnApiRefresh.Location = New-Object System.Drawing.Point(864, 41)
$btnApiRefresh.Size     = New-Object System.Drawing.Size(90, 26)
$btnApiRefresh.Enabled  = $false
$panelCtrlTop.Controls.Add($btnApiRefresh)

$lblApiState = New-Object System.Windows.Forms.Label
$lblApiState.Location  = New-Object System.Drawing.Point(8, 72)
$lblApiState.Size      = New-Object System.Drawing.Size(1100, 18)
$lblApiState.ForeColor = $UfColorMuted
$lblApiState.Text      = 'Not connected. Credentials are used for this session only and are never written to disk or to a report.'
$panelCtrlTop.Controls.Add($lblApiState)

$splitCtrl = New-Object System.Windows.Forms.SplitContainer
$splitCtrl.Dock        = 'Fill'
$splitCtrl.Orientation = 'Horizontal'
$tabCtrl.Controls.Add($splitCtrl)
$splitCtrl.BringToFront()

$lvCtrlDevices = New-Object System.Windows.Forms.ListView
$lvCtrlDevices.Dock          = 'Fill'
$lvCtrlDevices.View          = 'Details'
$lvCtrlDevices.FullRowSelect = $true
$lvCtrlDevices.GridLines     = $true
$lvCtrlDevices.HideSelection = $false
[void]$lvCtrlDevices.Columns.Add('Name', 150)
[void]$lvCtrlDevices.Columns.Add('Model', 80)
[void]$lvCtrlDevices.Columns.Add('MAC', 140)
[void]$lvCtrlDevices.Columns.Add('IP', 120)
[void]$lvCtrlDevices.Columns.Add('State', 130)
[void]$lvCtrlDevices.Columns.Add('Inform URL stored by controller', 300)
[void]$lvCtrlDevices.Columns.Add('Version', 110)
[void]$lvCtrlDevices.Columns.Add('Last seen', 120)
$splitCtrl.Panel1.Controls.Add($lvCtrlDevices)

$rtbCtrl = New-Object System.Windows.Forms.RichTextBox
$rtbCtrl.Dock      = 'Fill'
$rtbCtrl.ReadOnly  = $true
$rtbCtrl.BackColor = $UfColorPanel
$rtbCtrl.Text      = 'Connect to see the controller-side verdict.'
$splitCtrl.Panel2.Controls.Add($rtbCtrl)

# --- Tab 6: Known Issues ----------------------------------------------------
$splitKb = New-Object System.Windows.Forms.SplitContainer
$splitKb.Dock             = 'Fill'
$splitKb.Orientation      = 'Vertical'
$tabKb.Controls.Add($splitKb)

$lvKb = New-Object System.Windows.Forms.ListView
$lvKb.Dock          = 'Fill'
$lvKb.View          = 'Details'
$lvKb.FullRowSelect = $true
$lvKb.GridLines     = $true
$lvKb.HideSelection = $false
[void]$lvKb.Columns.Add('#', 34)
[void]$lvKb.Columns.Add('Severity', 70)
[void]$lvKb.Columns.Add('Known issue', 430)
$splitKb.Panel1.Controls.Add($lvKb)

$rtbKb = New-Object System.Windows.Forms.RichTextBox
$rtbKb.Dock      = 'Fill'
$rtbKb.ReadOnly  = $true
$rtbKb.BackColor = $UfColorPanel
$rtbKb.Text      = 'Select an issue to see the symptom, how to confirm it, and the fix.'
$splitKb.Panel2.Controls.Add($rtbKb)

$panelKbBottom = New-Object System.Windows.Forms.Panel
$panelKbBottom.Dock      = 'Bottom'
$panelKbBottom.Height    = 74
$panelKbBottom.BackColor = $UfColorPanel
$tabKb.Controls.Add($panelKbBottom)

$lblO43 = New-Object System.Windows.Forms.Label
$lblO43.Location = New-Object System.Drawing.Point(8, 6)
$lblO43.Size     = New-Object System.Drawing.Size(500, 18)
$lblO43.Font     = $UfFontBold
$lblO43.Text     = 'DHCP Option 43 generator - the permanent fix for devices with no DNS'
$panelKbBottom.Controls.Add($lblO43)

$cboO43 = New-Object System.Windows.Forms.ComboBox
$cboO43.Location      = New-Object System.Drawing.Point(8, 30)
$cboO43.Size          = New-Object System.Drawing.Size(180, 22)
$cboO43.DropDownStyle = 'DropDownList'
$panelKbBottom.Controls.Add($cboO43)

$txtO43 = New-Object System.Windows.Forms.TextBox
$txtO43.Location   = New-Object System.Drawing.Point(196, 30)
$txtO43.Size       = New-Object System.Drawing.Size(720, 22)
$txtO43.ReadOnly   = $true
$txtO43.Font       = $UfFontMono
$panelKbBottom.Controls.Add($txtO43)

$btnCopyO43 = New-Object System.Windows.Forms.Button
$btnCopyO43.Text     = 'Copy'
$btnCopyO43.Location = New-Object System.Drawing.Point(924, 29)
$btnCopyO43.Size     = New-Object System.Drawing.Size(70, 24)
$panelKbBottom.Controls.Add($btnCopyO43)

$lblO43Hint = New-Object System.Windows.Forms.Label
$lblO43Hint.Location  = New-Object System.Drawing.Point(8, 54)
$lblO43Hint.Size      = New-Object System.Drawing.Size(1100, 16)
$lblO43Hint.ForeColor = $UfColorMuted
$lblO43Hint.Text      = 'Run a full check first so the controller IP is known. Option 43 lets a freshly reset device find the controller with no DNS at all.'
$panelKbBottom.Controls.Add($lblO43Hint)

$splitKb.BringToFront()

# --- Tab 7: Log -------------------------------------------------------------
$panelLogTop = New-Object System.Windows.Forms.Panel
$panelLogTop.Dock      = 'Top'
$panelLogTop.Height    = 38
$panelLogTop.BackColor = $UfColorPanel
$tabLog.Controls.Add($panelLogTop)

$btnSaveHtml = New-Object System.Windows.Forms.Button
$btnSaveHtml.Text     = 'Save HTML report'
$btnSaveHtml.Location = New-Object System.Drawing.Point(8, 6)
$btnSaveHtml.Size     = New-Object System.Drawing.Size(140, 26)
$panelLogTop.Controls.Add($btnSaveHtml)

$btnSaveTxt = New-Object System.Windows.Forms.Button
$btnSaveTxt.Text     = 'Save log as text'
$btnSaveTxt.Location = New-Object System.Drawing.Point(156, 6)
$btnSaveTxt.Size     = New-Object System.Drawing.Size(130, 26)
$panelLogTop.Controls.Add($btnSaveTxt)

$btnClearLog = New-Object System.Windows.Forms.Button
$btnClearLog.Text     = 'Clear'
$btnClearLog.Location = New-Object System.Drawing.Point(294, 6)
$btnClearLog.Size     = New-Object System.Drawing.Size(80, 26)
$panelLogTop.Controls.Add($btnClearLog)

$rtbLog = New-Object System.Windows.Forms.RichTextBox
$rtbLog.Dock      = 'Fill'
$rtbLog.ReadOnly  = $true
$rtbLog.Font      = $UfFontMono
$rtbLog.BackColor = $UfColorPanel
$tabLog.Controls.Add($rtbLog)
$rtbLog.BringToFront()

# =============================================================================
# UI helpers
# =============================================================================

function Write-UfLog {
    param([string]$Text, [string]$Level = 'info')
    $stamp = (Get-Date).ToString('HH:mm:ss')
    $rtbLog.SelectionStart  = $rtbLog.TextLength
    $rtbLog.SelectionLength = 0
    $rtbLog.SelectionColor  = $UfColorMuted
    $rtbLog.AppendText("[$stamp] ")
    $rtbLog.SelectionColor  = Get-UfStatusColor -Status $Level
    $rtbLog.AppendText($Text + [Environment]::NewLine)
    $rtbLog.ScrollToCaret()
}

function Set-UfVerdictBanner {
    param([string]$Level, [string]$Headline, [string]$Sub = '')
    $lblVerdict.Text    = $Headline
    $lblVerdictSub.Text = $Sub
    switch ($Level) {
        'critical' { $panelVerdict.BackColor = $UfColorFailBg; $lblVerdict.ForeColor = $UfColorFail }
        'high'     { $panelVerdict.BackColor = $UfColorFailBg; $lblVerdict.ForeColor = $UfColorFail }
        'medium'   { $panelVerdict.BackColor = $UfColorWarnBg; $lblVerdict.ForeColor = $UfColorWarn }
        'low'      { $panelVerdict.BackColor = $UfColorInfoBg; $lblVerdict.ForeColor = $UfColorInfo }
        'ok'       { $panelVerdict.BackColor = $UfColorOkBg;   $lblVerdict.ForeColor = $UfColorOk }
        default    { $panelVerdict.BackColor = $UfColorInfoBg; $lblVerdict.ForeColor = $UfColorInfo }
    }
}

function Get-UfHeaderValues {
    $informPortValue = 8080
    $uiPortValue     = 8443
    [void][int]::TryParse($txtInform.Text.Trim(), [ref]$informPortValue)
    [void][int]::TryParse($txtUi.Text.Trim(), [ref]$uiPortValue)
    if ($informPortValue -le 0) { $informPortValue = 8080 }
    if ($uiPortValue     -le 0) { $uiPortValue     = 8443 }
    $sshUserValue = $txtSshUser.Text.Trim()
    if (-not $sshUserValue) { $sshUserValue = 'ubnt' }
    return [PSCustomObject]@{
        ControllerHost = $txtHost.Text.Trim()
        InformPort     = $informPortValue
        UiPort         = $uiPortValue
        DeviceIp       = $txtDevice.Text.Trim()
        SshUser        = $sshUserValue
    }
}

function Set-UfBusy {
    param([bool]$Busy)
    $btnRunAll.Enabled      = -not $Busy
    $btnScan.Enabled        = -not $Busy
    $btnGetPutty.Enabled    = -not $Busy
    $btnApiConnect.Enabled  = -not $Busy
    $btnHwInfo.Enabled      = -not $Busy
    $btnPersist.Enabled     = -not $Busy
    $btnPlinkInfo.Enabled   = -not $Busy
    $btnPlinkInform.Enabled = -not $Busy
    $btnCancel.Enabled      = $Busy
    if (-not $Busy) { $btnApiRefresh.Enabled = ($null -ne $script:ControllerConn -and $script:ControllerConn.Connected) }
    else            { $btnApiRefresh.Enabled = $false }
}

# =============================================================================
# Worker plumbing
# =============================================================================
# Everything slow runs in a background runspace so the UI thread never blocks:
# Cancel keeps working and the window never greys out mid-scan. The two sides
# share exactly one object, a synchronized hashtable. The worker writes
# Status/Progress/Result; a WinForms timer on the UI thread reads them.

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 200

function Start-UfWork {
    param([string]$Kind, [scriptblock]$Body, $Arguments = @{})

    if ($script:Sync.Running) { return }

    $script:Sync.Running  = $true
    $script:Sync.Cancel   = $false
    $script:Sync.Status   = 'Starting...'
    $script:Sync.Progress = 0
    $script:Sync.Result   = $null
    $script:Sync.Error    = ''
    $script:Sync.Kind     = $Kind

    Set-UfBusy $true

    if (-not $script:HelpersText) {
        # Could not read our own source (pasted into a console, say). Degrade to
        # running on the UI thread rather than failing outright - slower and the
        # window will not repaint, but the tool still works.
        Write-UfLog 'Helper region not readable, running this task on the UI thread (the window will not respond until it finishes).' 'warn'
        try {
            $script:Sync.Result = & $Body $Arguments $script:Sync
        } catch {
            $script:Sync.Error = $_.Exception.Message
        }
        $script:Sync.Running  = $false
        $script:Sync.Progress = 100
        $timer.Start()
        return
    }

    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.ApartmentState = 'STA'
    $runspace.ThreadOptions  = 'ReuseThread'
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('Sync', $script:Sync)
    $runspace.SessionStateProxy.SetVariable('HelpersText', $script:HelpersText)
    # Deliberately NOT called 'Args': an injected variable of that name loses to
    # the automatic $args, and the symptom is a probe that silently targets
    # nothing at all.
    $runspace.SessionStateProxy.SetVariable('UfArgs', $Arguments)

    $wrapper = {
        param($Body)
        try {
            . ([ScriptBlock]::Create($HelpersText))
            $Sync.Result = & ([ScriptBlock]::Create($Body)) $UfArgs $Sync
        } catch {
            $Sync.Error = ('{0}{1}{2}' -f $_.Exception.Message, [Environment]::NewLine, $_.ScriptStackTrace)
        } finally {
            $Sync.Running  = $false
            $Sync.Progress = 100
        }
    }

    $ps = [PowerShell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript($wrapper).AddArgument($Body.ToString())

    $script:Worker      = $ps
    $script:WorkerAsync = $ps.BeginInvoke()
    $timer.Start()
}

function Stop-UfWork {
    $timer.Stop()
    if ($script:Worker) {
        try { $script:Worker.EndInvoke($script:WorkerAsync) | Out-Null } catch { }
        try { $script:Worker.Runspace.Close() } catch { }
        try { $script:Worker.Dispose() } catch { }
        $script:Worker = $null
    }
    Set-UfBusy $false
    $progress.Value = 0
    $lblStatus.Text = 'Idle'
}

# =============================================================================
# Rendering
# =============================================================================

function Show-UfReport {
    param($Report)
    $lvChecks.BeginUpdate()
    $lvChecks.Items.Clear()
    foreach ($c in @($Report.Checks)) {
        [void](Add-UfListRow -ListView $lvChecks -Values @($c.Check, $c.Target, $c.Result, $c.Detail) -Status $c.Status)
    }
    $lvChecks.EndUpdate()

    $rtbFindings.Clear()
    $append = {
        param([string]$Text, $Color, $Font)
        $rtbFindings.SelectionStart  = $rtbFindings.TextLength
        $rtbFindings.SelectionLength = 0
        $rtbFindings.SelectionColor  = $Color
        $rtbFindings.SelectionFont   = $Font
        $rtbFindings.AppendText($Text)
    }

    & $append ($Report.Headline + [Environment]::NewLine) (Get-UfStatusColor -Status $(if ($Report.Verdict -eq 'ok') { 'ok' } elseif ($Report.Verdict -eq 'medium') { 'warn' } elseif ($Report.Verdict -eq 'info') { 'info' } else { 'fail' })) $UfFontBold
    & $append ($Report.Sub + [Environment]::NewLine + [Environment]::NewLine) $UfColorText $UfFontUi

    $findings = @($Report.Findings)
    if ($findings.Count -eq 0) {
        & $append 'No specific findings beyond the checks above.' $UfColorMuted $UfFontUi
    } else {
        & $append ('Findings (' + $findings.Count + ')' + [Environment]::NewLine) $UfColorText $UfFontBold
        foreach ($f in $findings) {
            $col = if ($f.Severity -eq 'critical' -or $f.Severity -eq 'high') { $UfColorFail } elseif ($f.Severity -eq 'medium') { $UfColorWarn } else { $UfColorInfo }
            & $append ('  [' + $f.Severity.ToUpper() + '] ') $col $UfFontBold
            & $append ($f.Text + [Environment]::NewLine) $UfColorText $UfFontUi
            if ($f.KbId -gt 0) {
                & $append ('           See Known Issues #' + $f.KbId + [Environment]::NewLine) $UfColorMuted $UfFontUi
            }
        }
    }
    Set-UfVerdictBanner -Level $Report.Verdict -Headline $Report.Headline -Sub $Report.Sub
}

function Get-UfProp {
    # The device rows come from three places (discovery, ARP, an SSH read) and
    # only the SSH read adds the hardware properties. Asking for one that is not
    # there returns empty rather than throwing.
    param($Object, [string]$Name)
    if ($null -eq $Object) { return '' }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return [string]$prop.Value }
    return ''
}

function Set-UfDeviceProp {
    # An SSH read attaches what it learned to the device row, so the list and
    # the saved report are the one place to look afterwards. The row may or may
    # not already carry the property depending on where it came from.
    param($Object, [string]$Name, $Value)
    if ($null -eq $Object -or -not $Name) { return }
    if ($null -eq $Value -or '' -eq [string]$Value) { return }
    if ($Object.PSObject.Properties[$Name]) { $Object.($Name) = $Value }
    else { Add-Member -InputObject $Object -MemberType NoteProperty -Name $Name -Value $Value -Force }
}

function Show-UfDevices {
    param($Devices, [string]$SelectIp = '')
    $lvDevices.BeginUpdate()
    $lvDevices.Items.Clear()
    foreach ($d in @($Devices)) {
        $def = if ($null -eq $d.IsDefault) { '' } elseif ($d.IsDefault) { 'YES - unadopted' } else { 'no' }
        $status = if ($d.IsDefault) { 'warn' } else { 'info' }
        # A serial read over SSH wins over the one derived from the MAC. They
        # should agree; if they ever do not, the device's own answer is right.
        $serial = Get-UfProp -Object $d -Name 'Serial'
        if (-not $serial) { $serial = Get-UfSerialFromMac -Mac $d.Mac }
        [void](Add-UfListRow -ListView $lvDevices -Status $status -Tag $d -Values @(
            $d.IPAddress, $d.Mac, $serial, $d.Model, $d.Firmware,
            (Get-UfProp -Object $d -Name 'BoardRev'),
            (Format-UfMfgWeek -Value (Get-UfProp -Object $d -Name 'MfgWeek')),
            $d.Hostname, (Format-UfUptime -Seconds $d.Uptime), $def, $d.Source, $d.Extra
        ))
    }
    $lvDevices.EndUpdate()
    if ($SelectIp) {
        foreach ($item in $lvDevices.Items) {
            if ($item.SubItems[0].Text -eq $SelectIp) { $item.Selected = $true; $item.EnsureVisible(); break }
        }
    }
}

function Show-UfSshBlocks {
    $vals = Get-UfHeaderValues
    $ip   = if ($vals.DeviceIp) { $vals.DeviceIp } else { '<AP_IP>' }
    $lblSshFor.Text = ('Commands for {0} as {1}  ->  controller {2}:{3}' -f $ip, $vals.SshUser, $vals.ControllerHost, $vals.InformPort)
    $lblPlinkUser.Text = ('connecting as {0} - change the SSH user above' -f $vals.SshUser)
    $btnLaunchPutty.Text = ('Launch PuTTY as {0}' -f $vals.SshUser)

    $flowSsh.SuspendLayout()
    $flowSsh.Controls.Clear()
    $blocks = @(Get-UfSshBlocks -ControllerHost $vals.ControllerHost -InformPort $vals.InformPort -DeviceIp $vals.DeviceIp -SshUser $vals.SshUser)
    $width = [Math]::Max(600, $flowSsh.ClientSize.Width - 40)

    foreach ($b in $blocks) {
        $lineCount = @($b.Text -split "`r?`n").Count
        $gb = New-Object System.Windows.Forms.GroupBox
        $gb.Text      = $b.Title
        $gb.Font      = $UfFontBold
        $gb.BackColor = $UfColorPanel
        $gb.Width     = $width
        $gb.Height    = 74 + (16 * $lineCount) + 22

        $lblNote = New-Object System.Windows.Forms.Label
        $lblNote.Text      = $b.Note
        $lblNote.Font      = $UfFontUi
        $lblNote.ForeColor = $UfColorMuted
        $lblNote.Location  = New-Object System.Drawing.Point(10, 20)
        $lblNote.Size      = New-Object System.Drawing.Size(($width - 130), 34)
        $gb.Controls.Add($lblNote)

        $txt = New-Object System.Windows.Forms.TextBox
        $txt.Text       = $b.Text
        $txt.Font       = $UfFontMono
        $txt.ReadOnly   = $true
        $txt.Multiline  = $true
        $txt.BackColor  = [System.Drawing.Color]::FromArgb(242, 243, 247)
        $txt.BorderStyle = 'FixedSingle'
        $txt.Location   = New-Object System.Drawing.Point(10, 58)
        $txt.Size       = New-Object System.Drawing.Size(($width - 130), (8 + (16 * $lineCount)))
        $gb.Controls.Add($txt)

        $btnCopy = New-Object System.Windows.Forms.Button
        $btnCopy.Text     = 'Copy'
        $btnCopy.Font     = $UfFontUi
        $btnCopy.Location = New-Object System.Drawing.Point(($width - 112), 58)
        $btnCopy.Size     = New-Object System.Drawing.Size(90, 28)
        $btnCopy.Tag      = $b.Text
        $btnCopy.Add_Click({
            param($eventSender, $e)
            try {
                [System.Windows.Forms.Clipboard]::SetText([string]$eventSender.Tag)
                $eventSender.Text = 'Copied'
            } catch {
                $eventSender.Text = 'Failed'
            }
        })
        $gb.Controls.Add($btnCopy)

        # Destructive commands are marked, not hidden. A technician who needs a
        # factory reset should not have to go and look it up elsewhere.
        if ($b.Title -match 'DESTRUCTIVE') {
            $gb.ForeColor = $UfColorFail
            $lblNote.ForeColor = $UfColorFail
        }

        $flowSsh.Controls.Add($gb)
    }
    $flowSsh.ResumeLayout()
}

function Show-UfKb {
    param([string]$ControllerHostValue, [string]$ControllerIpValue)
    $kb = @(Get-UfKnowledgeBase -ControllerHost $ControllerHostValue -ControllerIp $ControllerIpValue)
    $lvKb.BeginUpdate()
    $lvKb.Items.Clear()
    foreach ($k in $kb) {
        $status = switch ($k.Severity) {
            'critical' { 'fail' }
            'high'     { 'fail' }
            'medium'   { 'warn' }
            default    { 'info' }
        }
        $title = $k.Title
        if ($script:MatchedKb -contains $k.Id) { $title = '>> ' + $title + '   (matches this site)' }
        $item = Add-UfListRow -ListView $lvKb -Status $status -Tag $k -Values @([string]$k.Id, $k.Severity, $title)
        if ($script:MatchedKb -contains $k.Id) { $item.BackColor = $UfColorWarnBg; $item.Font = $UfFontBold }
    }
    $lvKb.EndUpdate()

    $cboO43.Items.Clear()
    $script:O43Recipes = @()
    if ($ControllerIpValue) {
        $script:O43Recipes = @(Get-UfOption43Recipes -ControllerIp $ControllerIpValue)
        foreach ($r in $script:O43Recipes) { [void]$cboO43.Items.Add($r.Vendor) }
        if ($cboO43.Items.Count -gt 0) { $cboO43.SelectedIndex = 0 }
    } else {
        $txtO43.Text = 'Run a full check first - the controller IP is needed to build the option value.'
    }
}

# =============================================================================
# Events
# =============================================================================

$timer.Add_Tick({
    $lblStatus.Text = [string]$script:Sync.Status
    $p = [int]$script:Sync.Progress
    if ($p -lt 0) { $p = 0 }; if ($p -gt 100) { $p = 100 }
    $progress.Value = $p

    if ($script:Sync.Running) { return }

    $kind   = [string]$script:Sync.Kind
    $result = $script:Sync.Result
    $err    = [string]$script:Sync.Error
    Stop-UfWork

    if ($err) {
        Write-UfLog ("$kind failed: " + $err) 'fail'
        [System.Windows.Forms.MessageBox]::Show($err, 'UniFi Troubleshooter', 'OK', 'Warning') | Out-Null
        return
    }
    if ($null -eq $result) {
        Write-UfLog "$kind returned nothing (cancelled?)." 'warn'
        return
    }

    switch ($kind) {
        'fullcheck' {
            $script:Report = $result
            Show-UfReport -Report $result
            Write-UfLog ('Full check complete: ' + $result.Headline) $(if ($result.Verdict -eq 'ok') { 'ok' } else { 'warn' })

            # Light up the knowledge-base entries this site actually matches.
            $matched = [System.Collections.Generic.List[int]]::new()
            foreach ($f in @($result.Findings)) {
                if ($f.KbId -gt 0 -and -not $matched.Contains([int]$f.KbId)) { $matched.Add([int]$f.KbId) }
            }
            foreach ($c in @($result.Checks)) {
                if ($c.Check -eq 'Resolve "unifi"' -and $c.Status -eq 'warn' -and -not $matched.Contains(3)) { $matched.Add(3) }
                if ($c.Check -eq 'UDP 3478' -and $c.Status -eq 'warn' -and -not $matched.Contains(4)) { $matched.Add(4) }
            }
            $script:MatchedKb = @($matched)
            Show-UfKb -ControllerHostValue $result.ControllerHost -ControllerIpValue $result.ControllerIp
            Show-UfSshBlocks
        }
        'scan' {
            $script:Devices = @($result)
            Show-UfDevices -Devices $script:Devices
            $unadopted = @($script:Devices | Where-Object { $_.IsDefault })
            Write-UfLog ('Device scan complete: {0} device(s) found, {1} on factory defaults.' -f @($script:Devices).Count, $unadopted.Count) 'ok'
            if (@($script:Devices).Count -eq 0) {
                Write-UfLog 'Nothing found. The device may be on another VLAN or subnet, powered off, or the firewall may be dropping the discovery replies. Check the gateway DHCP lease table next.' 'warn'
            }
        }
        'putty' {
            foreach ($line in @($result.Log)) { Write-UfLog ('  ' + $line) 'info' }
            $rtbPutty.Text = (@($result.Log) -join [Environment]::NewLine)
            $script:PuttyPath = [string]$result.Putty
            $script:PlinkPath = [string]$result.Plink
            if ($result.Success) {
                $lblPuttyState.Text = ('Ready: {0}{1}' -f $script:PuttyPath, $(if ($script:PlinkPath) { '  and  ' + $script:PlinkPath } else { '  (plink unavailable)' }))
                $lblPuttyState.ForeColor = $UfColorOk
                Write-UfLog 'PuTTY is ready.' 'ok'
            } else {
                $lblPuttyState.Text = 'Could not obtain a validly signed putty.exe. See the log.'
                $lblPuttyState.ForeColor = $UfColorFail
            }
        }
        'persist' {
            $rtbPutty.Text = ('$ ' + $result.Command + [Environment]::NewLine + [Environment]::NewLine + $result.Output)
            if ($result.Error) { $rtbPutty.AppendText([Environment]::NewLine + '--- stderr ---' + [Environment]::NewLine + $result.Error) }

            $ip = [string]$script:PlinkIp
            $ps = ConvertFrom-UfPersistence -Text $result.Output
            if (-not $ps.Parsed) {
                Write-UfLog ('Could not read a mount table from ' + $ip + '. Nothing was changed on the device.') 'warn'
                if ($result.Error) { Write-UfLog ('plink reported: ' + $result.Error) 'fail' }
            } else {
                Write-UfLog ('Root filesystem on ' + $ip + ' is ' + $ps.RootFs + $(if ($ps.PersistFs) { '; /etc/persistent sits on ' + $ps.PersistFs } else { '' })) 'info'

                # Storage detail is the WHY, and it is a repair-or-replace
                # question. The verdict below does not depend on it.
                if ($ps.MmcHost -and -not $ps.MmcCard -and @($ps.MmcBlocks).Count -eq 0) {
                    Write-UfLog ('MMC host ' + $ps.MmcHost + ' is present but no card enumerated and there are no /dev/mmcblk devices. On UniFi hardware that keeps its OS on eMMC, this is the usual cause.') 'warn'
                } elseif (@($ps.MmcBlocks).Count -gt 0) {
                    Write-UfLog (('eMMC present: {0} block device(s) - {1}' -f @($ps.MmcBlocks).Count, (@($ps.MmcBlocks) -join ', '))) 'ok'
                }
                if ($ps.CmdLine) { Write-UfLog ('Kernel command line: ' + $ps.CmdLine) 'info' }
                if ($ps.InformUrl) { Write-UfLog ('Stored inform URL: ' + $ps.InformUrl) 'info' }
                if ($ps.DmesgLines -ge 0) {
                    # Counted rather than grepped on purpose. A near-empty buffer
                    # on a device that has been up for weeks means the boot
                    # messages are gone, so grepping it for storage errors would
                    # have proved nothing either way - worth saying out loud,
                    # because it is an easy piece of false evidence to collect.
                    $note = if ($ps.DmesgLines -lt 20) { ' Too few to hold the boot messages, so grepping it for storage errors would prove nothing - reboot and read it immediately if you need them.' } else { '' }
                    Write-UfLog (('dmesg holds {0} line(s).{1}' -f $ps.DmesgLines, $note)) 'info'
                }

                # The verdict belongs on the device row, not only in the banner:
                # the banner is gone the moment the next task runs, and a finding
                # this important should reach the saved report.
                $target = @($script:Devices | Where-Object { $_.IPAddress -eq $ip })[0]
                if ($target) {
                    Set-UfDeviceProp -Object $target -Name 'RootFs'    -Value $ps.RootFs
                    Set-UfDeviceProp -Object $target -Name 'PersistFs' -Value $ps.PersistFs
                    Set-UfDeviceProp -Object $target -Name 'ConfigPersists' `
                        -Value $(if ($ps.Volatile) { 'NO - root is ' + $ps.RootFs + ' (RAM)' } else { 'yes - ' + $ps.RootFs })
                    Show-UfDevices -Devices $script:Devices -SelectIp $ip
                }

                if ($ps.Volatile) {
                    $head = 'Configuration cannot survive a power cut on this device'
                    $sub  = ('Root is ' + $ps.RootFs + ' - a RAM disk. /etc/persistent is a plain directory inside it, so set-inform, the SSIDs and the adoption keys are all lost at power-off and the device returns to factory defaults. This is a hardware fault, not an inform problem. See Known Issues #2 for how to make it survivable until the device is replaced.')
                    Set-UfVerdictBanner -Level 'critical' -Headline $head -Sub $sub
                    Write-UfLog ($head + '. ' + $sub) 'fail'
                    if (-not ($script:MatchedKb -contains 2)) {
                        $script:MatchedKb = @($script:MatchedKb) + 2
                        Show-UfKb -ControllerHostValue (Get-UfHeaderValues).ControllerHost -ControllerIpValue $(if ($script:Report) { $script:Report.ControllerIp } else { '' })
                    }
                    $tabs.SelectedTab = $tabKb
                } elseif ($ps.MmcHost -and -not $ps.MmcCard -and @($ps.MmcBlocks).Count -eq 0) {
                    Set-UfVerdictBanner -Level 'high' -Headline 'Storage subsystem is not enumerating' `
                        -Sub 'The MMC host controller is present but no card was found. Root is not in RAM, so some configuration may still persist - check whether the device actually keeps a set-inform across a reboot before replacing it.'
                    Write-UfLog 'MMC host present, no card. Root is not in RAM, so this is not conclusive on its own.' 'warn'
                } else {
                    Set-UfVerdictBanner -Level 'ok' -Headline 'Persistent storage looks healthy' `
                        -Sub (('Root is {0} and /etc/persistent sits on {1}. Configuration written here should survive a reboot, so a device that keeps reverting is doing so for another reason - start with Known Issues #1.' -f $ps.RootFs, $(if ($ps.PersistFs) { $ps.PersistFs } else { 'a real filesystem' })))
                    Write-UfLog 'Persistent storage looks healthy - configuration should survive a reboot.' 'ok'
                }
            }
        }
        'hwinfo' {
            $rtbPutty.Text = ('$ ' + $result.Command + [Environment]::NewLine + [Environment]::NewLine + $result.Output)
            if ($result.Error) { $rtbPutty.AppendText([Environment]::NewLine + '--- stderr ---' + [Environment]::NewLine + $result.Error) }

            $hw = ConvertFrom-UfSystemInfo -Text $result.Output
            $ip = [string]$script:PlinkIp
            if ($hw.Count -eq 0) {
                Write-UfLog ('No key=value lines came back from ' + $ip + '. /proc/ubnthal/system.info is an older-UniFi file - UniFi OS hardware (UDM, UDR, newer APs) does not have it, and neither does a device that refused the login.') 'warn'
                if ($result.Error) { Write-UfLog ('plink reported: ' + $result.Error) 'fail' }
            } else {
                # Attach what came back to the device row itself, so the list is
                # the one place to look rather than the PuTTY pane.
                $target = @($script:Devices | Where-Object { $_.IPAddress -eq $ip })[0]
                if ($target) {
                    Set-UfDeviceProp -Object $target -Name 'ShortName' -Value $hw.ShortName
                    Set-UfDeviceProp -Object $target -Name 'Serial'    -Value $hw.Serial
                    Set-UfDeviceProp -Object $target -Name 'BoardRev'  -Value $hw.BoardRev
                    Set-UfDeviceProp -Object $target -Name 'MfgWeek'   -Value $hw.MfgWeek
                    # Every other key goes somewhere too - flashSize, boardid and
                    # the rest are exactly what is wanted on an RMA call.
                    $rest = @()
                    foreach ($k in $hw.Pairs.Keys) {
                        if ($k -match '^(shortname|serialno|boardrevision|mfgweek)$') { continue }
                        $rest += ('{0}={1}' -f $k, $hw.Pairs[$k])
                    }
                    if ($rest.Count -gt 0) { $target.Extra = (@($rest) -join '; ') }
                    Show-UfDevices -Devices $script:Devices -SelectIp $ip
                } else {
                    Write-UfLog ('Read hardware info for ' + $ip + ', but that address is no longer in the device list - re-scan to see it in the table.') 'warn'
                }

                $summary = @()
                if ($hw.ShortName) { $summary += ('shortname ' + $hw.ShortName) }
                if ($hw.Serial)    { $summary += ('serial ' + $hw.Serial) }
                if ($hw.BoardRev)  { $summary += ('board rev ' + $hw.BoardRev) }
                if ($hw.MfgWeek)   { $summary += ('mfg week ' + $hw.MfgWeek) }
                Write-UfLog (('Hardware info from {0}: {1} field(s)' -f $ip, $hw.Count) + $(if ($summary.Count) { ' - ' + ($summary -join ', ') } else { '' })) 'ok'

                if (-not $hw.MfgWeek) {
                    Write-UfLog 'This board does not publish mfgweek. It is not on every model, so an empty Mfg week column means the device did not report one - not that the read failed.' 'info'
                }
                if ($hw.Serial) {
                    $derived = Get-UfSerialFromMac -Mac $(if ($target) { $target.Mac } else { '' })
                    if ($derived -and $derived -ne $hw.Serial) {
                        Write-UfLog ('The device reports serialno ' + $hw.Serial + ' but its MAC gives ' + $derived + '. The device is right; the Serial column now shows its answer.') 'warn'
                    }
                }
            }
        }
        'plink' {
            $rtbPutty.Text = ('$ ' + $result.Command + [Environment]::NewLine + [Environment]::NewLine + $result.Output)
            if ($result.Error) { $rtbPutty.AppendText([Environment]::NewLine + '--- stderr ---' + [Environment]::NewLine + $result.Error) }
            Write-UfLog ('plink: ' + $result.Command) 'info'

            $info = ConvertFrom-UfDeviceInfo -Text $result.Output
            if ($info.Status) {
                $verdict = Get-UfStatusVerdict -Status $info.Status
                Set-UfVerdictBanner -Level $verdict.Level -Headline $verdict.Headline -Sub $verdict.Advice
                Write-UfLog ('Device status: ' + $info.Status) $(if ($verdict.Level -eq 'ok') { 'ok' } else { 'warn' })
                $rtbPutty.AppendText([Environment]::NewLine + [Environment]::NewLine + '--- interpretation ---' + [Environment]::NewLine +
                    $verdict.Headline + [Environment]::NewLine + $verdict.Advice)
                if ($info.InformUrl -match '//unifi:') {
                    $rtbPutty.AppendText([Environment]::NewLine + [Environment]::NewLine +
                        'The device is still pointed at the bare "unifi" hostname. Fix it now with set-inform, then fix it permanently with Override Inform Host on the controller (Known Issues #1) or it will come back on the next reboot.')
                    if (-not ($script:MatchedKb -contains 1)) {
                        $script:MatchedKb = @($script:MatchedKb) + 1
                        Show-UfKb -ControllerHostValue (Get-UfHeaderValues).ControllerHost -ControllerIpValue $(if ($script:Report) { $script:Report.ControllerIp } else { '' })
                    }
                }
            } elseif ($result.Error) {
                Write-UfLog ('plink reported: ' + $result.Error) 'fail'
            }
        }
        'api' {
            $script:ControllerConn    = $result.Connection
            $script:ControllerDevices = @($result.Devices)
            $script:SuperMgmt         = $result.SuperMgmt

            $lvCtrlDevices.BeginUpdate()
            $lvCtrlDevices.Items.Clear()
            foreach ($d in $script:ControllerDevices) {
                $st = switch ($d.StateCode) {
                    1 { 'ok' }
                    2 { 'warn' }
                    5 { 'warn' }
                    7 { 'warn' }
                    default { 'fail' }
                }
                $item = Add-UfListRow -ListView $lvCtrlDevices -Status $st -Tag $d -Values @(
                    $d.Name, $d.Model, $d.Mac, $d.IPAddress, $d.State, $d.InformUrl, $d.Version, $d.LastSeen)
                if ($d.InformUrl -match '//unifi:') { $item.BackColor = $UfColorFailBg }
            }
            $lvCtrlDevices.EndUpdate()

            $cboSite.Items.Clear()
            foreach ($s in @($result.Sites)) { [void]$cboSite.Items.Add($s.Name) }
            if ($cboSite.Items.Count -eq 0) { [void]$cboSite.Items.Add('default') }
            $idx = $cboSite.Items.IndexOf([string]$result.Site)
            $cboSite.SelectedIndex = $(if ($idx -ge 0) { $idx } else { 0 })

            $lblApiState.Text = ('Connected to {0} ({1}) - {2} device(s).' -f $result.Connection.BaseUrl,
                                 $(if ($result.Connection.UniFiOs) { 'UniFi OS' } else { 'self-hosted Network application' }),
                                 @($script:ControllerDevices).Count)
            $lblApiState.ForeColor = $UfColorOk

            # The site's real SSH username, straight from the controller. If it
            # is not the factory default, fill it in and say so - a refused
            # login is otherwise very easily mistaken for a wrong password.
            $script:SiteMgmt = $result.SiteMgmt
            if ($result.SiteMgmt -and $result.SiteMgmt.Found -and $result.SiteMgmt.SshUsername) {
                $realUser = $result.SiteMgmt.SshUsername
                if ($txtSshUser.Items.IndexOf($realUser)   -lt 0) { [void]$txtSshUser.Items.Add($realUser) }
                if ($cboPuttyUser.Items.IndexOf($realUser) -lt 0) { [void]$cboPuttyUser.Items.Add($realUser) }
                if ($txtSshUser.Text.Trim() -ne $realUser) {
                    Write-UfLog ("Device Authentication username for this site is '$realUser' - SSH user updated from '" + $txtSshUser.Text.Trim() + "'.") 'ok'
                    $txtSshUser.Text = $realUser
                    Show-UfSshBlocks
                } else {
                    Write-UfLog "Device Authentication username confirmed as '$realUser'." 'ok'
                }
            }

            # The controller-side verdict. This is the part that separates
            # "the device forgot" from "the controller keeps telling it to".
            $lines = [System.Collections.Generic.List[string]]::new()
            if ($result.SiteMgmt -and $result.SiteMgmt.Found) {
                $lines.Add('Device Authentication username: ' + $result.SiteMgmt.SshUsername +
                    $(if ($result.SiteMgmt.SshUsername -ne 'ubnt') { '   (not the factory default - ubnt will be refused)' } else { '' }))
                if ($result.SiteMgmt.SshEnabled -eq $false) {
                    $lines.Add('SSH is DISABLED for this site. Enable it under Settings > System > Advanced before trying to log in to a device.')
                }
                $lines.Add('')
            } elseif ($result.SiteMgmt -and $result.SiteMgmt.Error) {
                $lines.Add('Could not read Device Authentication: ' + $result.SiteMgmt.Error)
                $lines.Add('')
            }
            $badUrl = @($script:ControllerDevices | Where-Object { $_.InformUrl -match '//unifi:' })
            if ($script:SuperMgmt -and $script:SuperMgmt.Found) {
                if ($script:SuperMgmt.OverrideInformHost) {
                    $lines.Add('Override Inform Host: ON, hostname = ' + $script:SuperMgmt.Hostname)
                    $lines.Add('The controller is pushing an explicit inform host, which is what you want. If a device still reverts after a power cycle, suspect the device rather than the controller - see Known Issues #2 and run SSH block 7.')
                } else {
                    $lines.Add('Override Inform Host: OFF   <-- THIS IS THE PROBLEM')
                    $lines.Add('')
                    $lines.Add('With Override Inform Host off, the controller pushes its own detected hostname to every device each time it provisions them. That is how a device ends up back on http://unifi:8080/inform after a reboot, and it is why set-inform appears to work and then stops working.')
                    $lines.Add('')
                    $lines.Add('Fix: Settings > System > Advanced > Inform Host = ' + (Get-UfHeaderValues).ControllerHost + ', tick Override, Apply, then force-provision the device.')
                    if (-not ($script:MatchedKb -contains 1)) { $script:MatchedKb = @($script:MatchedKb) + 1 }
                }
            } else {
                $lines.Add('Could not read Override Inform Host' + $(if ($script:SuperMgmt) { ': ' + $script:SuperMgmt.Error } else { '.' }))
                $lines.Add('Check it by hand at Settings > System > Advanced > Inform Host. It is the single most common cause of this fault.')
            }
            if ($badUrl.Count -gt 0) {
                $lines.Add('')
                $lines.Add(('{0} device(s) have the bare "unifi" hostname stored as their inform URL:' -f $badUrl.Count))
                foreach ($b in $badUrl) { $lines.Add('   ' + $b.Name + '  ' + $b.Mac + '  ' + $b.InformUrl) }
                if (-not ($script:MatchedKb -contains 1)) { $script:MatchedKb = @($script:MatchedKb) + 1 }
            }
            $dupes = @($script:ControllerDevices | Group-Object Mac | Where-Object { $_.Count -gt 1 })
            if ($dupes.Count -gt 0) {
                $lines.Add('')
                $lines.Add(('{0} MAC address(es) appear more than once - a ghost entry can hide the Adopt action. See Known Issues #7.' -f $dupes.Count))
                if (-not ($script:MatchedKb -contains 7)) { $script:MatchedKb = @($script:MatchedKb) + 7 }
            }
            $rtbCtrl.Text = ($lines -join [Environment]::NewLine)
            Show-UfKb -ControllerHostValue (Get-UfHeaderValues).ControllerHost -ControllerIpValue $(if ($script:Report) { $script:Report.ControllerIp } else { '' })
            Write-UfLog ('Controller read: {0} device(s).' -f @($script:ControllerDevices).Count) 'ok'
        }
    }
})

$btnCancel.Add_Click({
    $script:Sync.Cancel = $true
    $lblStatus.Text = 'Cancelling...'
    Write-UfLog 'Cancel requested.' 'warn'
})

$btnRunAll.Add_Click({
    $vals = Get-UfHeaderValues
    if (-not $vals.ControllerHost) {
        [System.Windows.Forms.MessageBox]::Show('Enter the controller host first.', 'UniFi Troubleshooter', 'OK', 'Information') | Out-Null
        return
    }
    Write-UfLog ('Full check against {0} (inform {1}, UI {2})' -f $vals.ControllerHost, $vals.InformPort, $vals.UiPort) 'info'
    $script:MatchedKb = @()
    Start-UfWork -Kind 'fullcheck' -Arguments @{
        ControllerHost = $vals.ControllerHost
        InformPort     = $vals.InformPort
        UiPort         = $vals.UiPort
        DeviceIp       = $vals.DeviceIp
    } -Body {
        param($UfArgs, $Sync)
        Invoke-UfFullCheck -ControllerHost $UfArgs.ControllerHost -InformPort $UfArgs.InformPort `
            -UiPort $UfArgs.UiPort -DeviceIp $UfArgs.DeviceIp -Sync $Sync
    }
})

$btnScan.Add_Click({
    Write-UfLog 'Scanning for UniFi devices...' 'info'
    Start-UfWork -Kind 'scan' -Arguments @{ PingSweep = [bool]$chkPingSweep.Checked } -Body {
        param($UfArgs, $Sync)
        $Sync.Status = 'Reading the ARP cache...'; $Sync.Progress = 10
        $arp = @(Get-UfArpDevices)

        if ($UfArgs.PingSweep) {
            $Sync.Status = 'Ping-sweeping the local subnet...'; $Sync.Progress = 30
            foreach ($nic in (Get-UfLocalNetwork)) {
                if ($Sync.Cancel) { break }
                [void](Invoke-UfPingSweep -BaseIp $nic.IPAddress -PrefixLength $nic.PrefixLength -Sync $Sync)
            }
            $Sync.Status = 'Re-reading the ARP cache...'; $Sync.Progress = 60
            $arp = @(Get-UfArpDevices)
        }

        $Sync.Status = 'Broadcasting UniFi discovery on UDP 10001...'; $Sync.Progress = 75
        $disc = @(Invoke-UfDiscovery -ListenMs 2500 -Sync $Sync)

        $Sync.Status = 'Merging results...'; $Sync.Progress = 95
        # Returned through the comma operator so a site with nothing on it comes
        # back as an empty array rather than $null - PowerShell unwraps a bare
        # empty pipeline to nothing, and the caller reads $null as "cancelled",
        # which is a misleading thing to tell a technician who just scanned a
        # quiet subnet.
        $merged = @(Merge-UfDeviceLists -ArpDevices $arp -DiscoveredDevices $disc)
        , $merged
    }
})

function Get-UfSelectedDeviceIp {
    if ($lvDevices.SelectedItems.Count -gt 0) { return [string]$lvDevices.SelectedItems[0].SubItems[0].Text }
    return ''
}

$btnUseDevice.Add_Click({
    $ip = Get-UfSelectedDeviceIp
    if (-not $ip) { [System.Windows.Forms.MessageBox]::Show('Select a device first.', 'UniFi Troubleshooter', 'OK', 'Information') | Out-Null; return }
    $txtDevice.Text = $ip
    $lblFindSel.Text = ('Device IP: ' + $ip)
    Show-UfSshBlocks
    Write-UfLog ('Device IP set to ' + $ip) 'ok'
})

# Rebuilding the SSH blocks means recreating six group boxes, which is too much
# to do on every keyboard arrow through the list. The IP itself lands in the
# header immediately; the blocks catch up once the selection settles.
$timerDeviceSel = New-Object System.Windows.Forms.Timer
$timerDeviceSel.Interval = 250
$timerDeviceSel.Add_Tick({
    $timerDeviceSel.Stop()
    Show-UfSshBlocks
})

# Selecting a device is the gesture people expect to set the device. The button
# beside the list stays for anyone who wants it spelled out, but nothing should
# require finding it first.
$lvDevices.Add_SelectedIndexChanged({
    if ($lvDevices.SelectedItems.Count -eq 0) { return }
    $ip = [string]$lvDevices.SelectedItems[0].SubItems[0].Text
    if (-not $ip) { return }
    $lblFindSel.Text = ('Device IP: ' + $ip)
    if ($txtDevice.Text.Trim() -eq $ip) { return }
    $txtDevice.Text = $ip
    $timerDeviceSel.Stop()
    $timerDeviceSel.Start()
})

$lvDevices.Add_DoubleClick({
    $ip = Get-UfSelectedDeviceIp
    if ($ip) { $timerDeviceSel.Stop(); $txtDevice.Text = $ip; Show-UfSshBlocks; $tabs.SelectedTab = $tabSsh }
})

$btnUsePutty.Add_Click({
    $ip = Get-UfSelectedDeviceIp
    if (-not $ip) { [System.Windows.Forms.MessageBox]::Show('Select a device first.', 'UniFi Troubleshooter', 'OK', 'Information') | Out-Null; return }
    $txtDevice.Text = $ip
    $lblFindSel.Text = ('Device IP: ' + $ip)
    Invoke-UfLaunchPutty -Ip $ip
})

$btnPortal.Add_Click({
    $url = $txtPortal.Text.Trim()
    if (-not $url) { return }
    try {
        $used = Open-UfUrl -Url $url
        Write-UfLog ('Opened ' + $url + ' with ' + $used) 'ok'
    } catch {
        Write-UfLog ('Could not open ' + $url + ': ' + $_.Exception.Message) 'fail'
        Write-UfLog 'If this is a Backstage session there may be no browser to hand. Put a portable Pale Moon in C:\Temp\Palemoon-Portable or C:\Temp\Browser\Palemoon-Portable and press this again.' 'warn'
    }
})

$btnUisp.Add_Click({
    $msg = "example.uisp.com is UISP, not UniFi.`r`n`r`nUISP manages airMAX, EdgeRouter and UFiber hardware and informs on port 15443. UniFi access points do not adopt there, so if you are chasing a U6 or similar this is not the place to look.`r`n`r`nOpen it anyway?"
    if ([System.Windows.Forms.MessageBox]::Show($msg, 'Different platform', 'YesNo', 'Information') -eq 'Yes') {
        try {
            $used = Open-UfUrl -Url $UispUrl
            Write-UfLog ('Opened ' + $UispUrl + ' with ' + $used) 'info'
        } catch {
            Write-UfLog ('Could not open ' + $UispUrl + ': ' + $_.Exception.Message) 'fail'
        }
    }
})

$btnSshRefresh.Add_Click({ Show-UfSshBlocks })

$btnCopyAllSsh.Add_Click({
    $vals   = Get-UfHeaderValues
    $blocks = @(Get-UfSshBlocks -ControllerHost $vals.ControllerHost -InformPort $vals.InformPort -DeviceIp $vals.DeviceIp -SshUser $vals.SshUser)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($b in $blocks) {
        [void]$sb.AppendLine('### ' + $b.Title)
        [void]$sb.AppendLine('# ' + $b.Note)
        [void]$sb.AppendLine($b.Text)
        [void]$sb.AppendLine('')
    }
    try { [System.Windows.Forms.Clipboard]::SetText($sb.ToString()); Write-UfLog 'All command blocks copied to the clipboard.' 'ok' } catch { }
})

# --- PuTTY / plink ----------------------------------------------------------

function Sync-UfPuttyState {
    # Cheap enough to call whenever: it only looks at the filesystem.
    $script:PuttyPath = Find-UfPutty -Exe 'putty.exe'
    $script:PlinkPath = Find-UfPutty -Exe 'plink.exe'
    if ($script:PuttyPath) {
        $lblPuttyState.Text = ('Found: {0}{1}' -f $script:PuttyPath, $(if ($script:PlinkPath) { '   and   ' + $script:PlinkPath } else { '   (plink not present - Download will fetch it)' }))
        $lblPuttyState.ForeColor = $UfColorOk
    } else {
        $lblPuttyState.Text = 'PuTTY not found on this machine. Press Download / verify PuTTY.'
        $lblPuttyState.ForeColor = $UfColorMuted
    }
}

function Invoke-UfLaunchPutty {
    param([string]$Ip)
    if (-not $Ip) { $Ip = (Get-UfHeaderValues).DeviceIp }
    if (-not $Ip) {
        [System.Windows.Forms.MessageBox]::Show('No device IP. Set one in the header, or pick a device on the Find Devices tab.', 'UniFi Troubleshooter', 'OK', 'Information') | Out-Null
        return
    }
    Sync-UfPuttyState
    if (-not $script:PuttyPath) {
        [System.Windows.Forms.MessageBox]::Show('putty.exe is not available yet. Use the PuTTY tab to download and verify it first.', 'UniFi Troubleshooter', 'OK', 'Information') | Out-Null
        $tabs.SelectedTab = $tabPutty
        return
    }
    try {
        Start-UfPutty -PuttyPath $script:PuttyPath -DeviceIp $Ip -User $txtSshUser.Text.Trim()
        Write-UfLog ('Launched PuTTY to ' + $txtSshUser.Text.Trim() + '@' + $Ip) 'ok'
    } catch {
        Write-UfLog ('Could not launch PuTTY: ' + $_.Exception.Message) 'fail'
    }
}

$btnGetPutty.Add_Click({
    Write-UfLog 'Fetching PuTTY...' 'info'
    Start-UfWork -Kind 'putty' -Arguments @{} -Body {
        param($UfArgs, $Sync)
        $Sync.Status = 'Downloading and verifying PuTTY...'; $Sync.Progress = 20
        Install-UfPutty -Files @('putty.exe', 'plink.exe') -Sync $Sync
    }
})

$btnLaunchPutty.Add_Click({ Invoke-UfLaunchPutty -Ip (Get-UfHeaderValues).DeviceIp })

$btnOpenToolDir.Add_Click({
    $dir = Get-UfToolDir
    try {
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Start-Process explorer.exe $dir | Out-Null
    } catch { Write-UfLog ('Could not open ' + $dir + ': ' + $_.Exception.Message) 'fail' }
})

function Invoke-UfPlinkAction {
    param([string]$Command, [string]$Confirm = '', [string]$Kind = 'plink', [string]$Ip = '')
    $vals = Get-UfHeaderValues
    if ($Ip) { $vals.DeviceIp = $Ip }
    if (-not $vals.DeviceIp) {
        [System.Windows.Forms.MessageBox]::Show('Set a device IP first.', 'UniFi Troubleshooter', 'OK', 'Information') | Out-Null
        return
    }
    Sync-UfPuttyState
    if (-not $script:PlinkPath) {
        [System.Windows.Forms.MessageBox]::Show('plink.exe is not available. Press Download / verify PuTTY first.', 'UniFi Troubleshooter', 'OK', 'Information') | Out-Null
        return
    }
    if (-not $txtSshPass.Text) {
        [System.Windows.Forms.MessageBox]::Show("Enter the device password for user '" + $vals.SshUser + "'.`r`n`r`nBoth the username and the password come from the site's Device Authentication settings. A factory-reset device is ubnt/ubnt; sites often change the user to 'admin'. If the login is refused, try the other username before assuming the password is wrong - or connect on the Controller tab and the real username will be filled in for you.", 'UniFi Troubleshooter', 'OK', 'Information') | Out-Null
        return
    }
    if ($Confirm) {
        if ([System.Windows.Forms.MessageBox]::Show($Confirm, 'Confirm', 'YesNo', 'Warning') -ne 'Yes') { return }
    }

    Write-UfLog ('Running on ' + $vals.DeviceIp + ': ' + $Command) 'info'
    $script:PlinkIp = $vals.DeviceIp
    Start-UfWork -Kind $Kind -Arguments @{
        PlinkPath = $script:PlinkPath
        DeviceIp  = $vals.DeviceIp
        User      = $txtSshUser.Text.Trim()
        Password  = $txtSshPass.Text
        Command   = $Command
    } -Body {
        param($UfArgs, $Sync)
        $Sync.Status = 'Connecting to the device...'; $Sync.Progress = 40
        Invoke-UfPlink -PlinkPath $UfArgs.PlinkPath -DeviceIp $UfArgs.DeviceIp -User $UfArgs.User `
            -Password $UfArgs.Password -Command $UfArgs.Command
    }
}

$btnPlinkInfo.Add_Click({ Invoke-UfPlinkAction -Command 'mca-cli-op info' })

# Both files are read rather than grepped for a fixed list of keys: which keys a
# board publishes varies, and an empty result is itself the answer (UniFi OS
# hardware has neither file). /etc/board.info is the older airOS-style name and
# is simply absent on most UniFi gear, which costs nothing.
$UfHwInfoCommand = 'cat /proc/ubnthal/system.info 2>/dev/null; cat /etc/board.info 2>/dev/null'

$btnHwInfo.Add_Click({
    $ip = Get-UfSelectedDeviceIp
    if (-not $ip) { [System.Windows.Forms.MessageBox]::Show('Select a device first.', 'UniFi Troubleshooter', 'OK', 'Information') | Out-Null; return }
    $txtDevice.Text = $ip
    $lblFindSel.Text = ('Device IP: ' + $ip)
    Invoke-UfPlinkAction -Command $UfHwInfoCommand -Kind 'hwinfo' -Ip $ip
})

# Read-only throughout - nothing here writes to the device. /proc/cmdline comes
# first because it is the single line that says where the running system was
# loaded from, which is the question the rest of the block only circles around.
# dmesg is COUNTED rather than read: on a device that has been up for weeks the
# ring buffer has long since wrapped, so an empty grep of it proves nothing, and
# knowing that is worth more than the grep would have been.
$UfPersistCommand = 'echo ---CMDLINE---; cat /proc/cmdline 2>/dev/null; ' +
                    'echo ---MOUNT---; mount; ' +
                    'echo ---PERSISTFS---; df -h /etc/persistent 2>/dev/null; ' +
                    'echo ---PARTITIONS---; cat /proc/partitions 2>/dev/null; ' +
                    'echo ---MMCBLOCK---; ls -d /dev/mmcblk* 2>/dev/null; ' +
                    'echo ---MMCHOST---; ls /sys/class/mmc_host/ 2>/dev/null; ' +
                    'echo ---MMCCARD---; ls /sys/class/mmc_host/*/ 2>/dev/null; ' +
                    'echo ---MGMT---; grep mgmt /etc/persistent/cfg/mgmt 2>/dev/null; ' +
                    'echo ---DMESG---; echo DMESGLINES=$(dmesg 2>/dev/null | wc -l)'

$btnPersist.Add_Click({
    $ip = Get-UfSelectedDeviceIp
    if (-not $ip) { [System.Windows.Forms.MessageBox]::Show('Select a device first.', 'UniFi Troubleshooter', 'OK', 'Information') | Out-Null; return }
    $txtDevice.Text = $ip
    $lblFindSel.Text = ('Device IP: ' + $ip)
    Invoke-UfPlinkAction -Command $UfPersistCommand -Kind 'persist' -Ip $ip
})

$btnPlinkInform.Add_Click({
    $vals   = Get-UfHeaderValues
    $inform = ('http://{0}:{1}/inform' -f $vals.ControllerHost, $vals.InformPort)
    $msg = "Send this to $($vals.DeviceIp)?`r`n`r`n    set-inform $inform`r`n`r`nThis changes the device's configuration. Remember Layer 3 adoption needs it TWICE: once now, and once immediately after you click Adopt in the controller."
    Invoke-UfPlinkAction -Command ('set-inform ' + $inform) -Confirm $msg
})

# --- Controller API ---------------------------------------------------------

function Invoke-UfApiRead {
    $vals = Get-UfHeaderValues
    if (-not $txtApiUser.Text -or -not $txtApiPass.Text) {
        [System.Windows.Forms.MessageBox]::Show('Enter the controller username and password.', 'UniFi Troubleshooter', 'OK', 'Information') | Out-Null
        return
    }
    $site = if ($cboSite.SelectedItem) { [string]$cboSite.SelectedItem } else { 'default' }
    Write-UfLog ('Connecting to the controller at ' + $vals.ControllerHost + ':' + $vals.UiPort) 'info'
    Start-UfWork -Kind 'api' -Arguments @{
        ControllerHost = $vals.ControllerHost
        UiPort         = $vals.UiPort
        Username       = $txtApiUser.Text
        Password       = $txtApiPass.Text
        Site           = $site
    } -Body {
        param($UfArgs, $Sync)
        $Sync.Status = 'Logging in...'; $Sync.Progress = 20
        $conn = Connect-UfController -ComputerName $UfArgs.ControllerHost -Port $UfArgs.UiPort `
                    -Username $UfArgs.Username -Password $UfArgs.Password
        if (-not $conn.Connected) { throw ('Controller login failed: ' + $conn.Error) }

        $Sync.Status = 'Reading sites...'; $Sync.Progress = 45
        $sites = @(Get-UfControllerSites -Connection $conn)
        $site  = $UfArgs.Site
        if (@($sites | Where-Object { $_.Name -eq $site }).Count -eq 0 -and $sites.Count -gt 0) {
            $site = $sites[0].Name
        }

        $Sync.Status = 'Reading devices...'; $Sync.Progress = 65
        $devices = @(Get-UfControllerDevices -Connection $conn -Site $site)

        $Sync.Status = 'Reading Override Inform Host...'; $Sync.Progress = 82
        $super = Get-UfSuperMgmt -Connection $conn

        $Sync.Status = 'Reading Device Authentication...'; $Sync.Progress = 92
        $mgmt = Get-UfSiteMgmt -Connection $conn -Site $site

        [PSCustomObject]@{
            Connection = $conn
            Sites      = $sites
            Site       = $site
            Devices    = $devices
            SuperMgmt  = $super
            SiteMgmt   = $mgmt
        }
    }
}

$btnApiConnect.Add_Click({ Invoke-UfApiRead })
$btnApiRefresh.Add_Click({ Invoke-UfApiRead })

$lvCtrlDevices.Add_DoubleClick({
    if ($lvCtrlDevices.SelectedItems.Count -gt 0) {
        $ip = [string]$lvCtrlDevices.SelectedItems[0].SubItems[3].Text
        if ($ip) { $txtDevice.Text = $ip; Show-UfSshBlocks; $tabs.SelectedTab = $tabSsh }
    }
})

# --- Known Issues -----------------------------------------------------------

$lvKb.Add_SelectedIndexChanged({
    if ($lvKb.SelectedItems.Count -eq 0) { return }
    $k = $lvKb.SelectedItems[0].Tag
    if (-not $k) { return }
    $rtbKb.Clear()
    $add = {
        param([string]$Head, [string]$Body, $Color)
        $rtbKb.SelectionStart  = $rtbKb.TextLength
        $rtbKb.SelectionColor  = $Color
        $rtbKb.SelectionFont   = $UfFontBold
        $rtbKb.AppendText($Head + [Environment]::NewLine)
        $rtbKb.SelectionColor  = $UfColorText
        $rtbKb.SelectionFont   = $UfFontUi
        $rtbKb.AppendText($Body + [Environment]::NewLine + [Environment]::NewLine)
    }
    $sevColor = switch ($k.Severity) {
        'critical' { $UfColorFail }
        'high'     { $UfColorFail }
        'medium'   { $UfColorWarn }
        default    { $UfColorInfo }
    }
    & $add ('#' + $k.Id + '  ' + $k.Title) ('Severity: ' + $k.Severity) $sevColor
    & $add 'Symptom' $k.Symptom $UfColorText
    & $add 'How to confirm it' $k.Confirm $UfColorText
    & $add 'Fix' $k.Fix $UfColorOk
    if ($script:MatchedKb -contains $k.Id) {
        & $add 'This one matches what was measured at this site' 'The diagnostics or the controller read produced evidence for this entry. Start here.' $UfColorWarn
    }
})

$cboO43.Add_SelectedIndexChanged({
    if ($cboO43.SelectedIndex -lt 0) { return }
    $recipes = @($script:O43Recipes)
    if ($cboO43.SelectedIndex -lt $recipes.Count) {
        $txtO43.Text = ($recipes[$cboO43.SelectedIndex].Value -replace "`r`n", '  |  ')
    }
})

$btnCopyO43.Add_Click({
    $recipes = @($script:O43Recipes)
    if ($cboO43.SelectedIndex -ge 0 -and $cboO43.SelectedIndex -lt $recipes.Count) {
        try {
            [System.Windows.Forms.Clipboard]::SetText($recipes[$cboO43.SelectedIndex].Value)
            Write-UfLog 'Option 43 recipe copied.' 'ok'
        } catch { }
    }
})

# --- Saving -----------------------------------------------------------------

function Save-UfReport {
    param([string]$Format = 'html')
    # A device scan or a single SSH read is a report in its own right. The old
    # guard demanded a full check first, which meant the most valuable finding
    # the tool produces - a device that cannot hold its configuration - could
    # not be saved unless an unrelated controller check had also been run.
    if ($Format -eq 'html' -and -not $script:Report -and @($script:Devices).Count -eq 0 -and @($script:ControllerDevices).Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Nothing to report yet - run a full check, scan for devices, or connect to the controller first.', 'UniFi Troubleshooter', 'OK', 'Information') | Out-Null
        return
    }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    if ($Format -eq 'html') {
        $dlg.Filter   = 'HTML report (*.html)|*.html'
        $dlg.FileName = "UniFi-Report-$stamp.html"
    } else {
        $dlg.Filter   = 'Text file (*.txt)|*.txt'
        $dlg.FileName = "UniFi-Log-$stamp.txt"
    }
    try { $dlg.InitialDirectory = [Environment]::GetFolderPath('Desktop') } catch { }
    if ($dlg.ShowDialog() -ne 'OK') { return }

    try {
        if ($Format -eq 'html') {
            # Credentials never reach this: the report is built from the check
            # results and the device lists, neither of which carries a password.
            $vals    = Get-UfHeaderValues
            $matched = @()
            if (@($script:MatchedKb).Count -gt 0) {
                $allKb   = @(Get-UfKnowledgeBase -ControllerHost $vals.ControllerHost -ControllerIp $(if ($script:Report) { $script:Report.ControllerIp } else { '' }))
                $matched = @($allKb | Where-Object { $script:MatchedKb -contains $_.Id })
            }
            $html = ConvertTo-UfHtmlReport -Report $script:Report -Devices $script:Devices `
                        -ControllerDevices $script:ControllerDevices -MatchedIssues $matched -HeaderValues $vals
            [System.IO.File]::WriteAllText($dlg.FileName, $html, (New-Object System.Text.UTF8Encoding($true)))
        } else {
            [System.IO.File]::WriteAllText($dlg.FileName, $rtbLog.Text, (New-Object System.Text.UTF8Encoding($true)))
        }
        Write-UfLog ('Saved ' + $dlg.FileName) 'ok'
        if ([System.Windows.Forms.MessageBox]::Show('Saved. Open it now?', 'UniFi Troubleshooter', 'YesNo', 'Information') -eq 'Yes') {
            # Through the same resolver: an HTML report needs a browser, and a
            # Backstage session may not have a default one registered.
            try { [void](Open-UfUrl -Url $dlg.FileName) } catch { Write-UfLog ('Could not open the report: ' + $_.Exception.Message) 'warn' }
        }
    } catch {
        Write-UfLog ('Save failed: ' + $_.Exception.Message) 'fail'
    }
}

$btnSaveHtml.Add_Click({ Save-UfReport -Format 'html' })
$btnSaveTxt.Add_Click({ Save-UfReport -Format 'txt' })
$btnSaveReport.Add_Click({ Save-UfReport -Format 'html' })
$btnClearLog.Add_Click({ $rtbLog.Clear() })

# The header combo and the PuTTY tab combo are two views of one username. Each
# mirrors into the other on TextChanged; the guard stops the mirror bouncing
# back. Only Leave and a dropdown pick rebuild the command blocks - doing that
# per keystroke would recreate six group boxes for every letter typed.
$script:UfSyncingSshUser = $false
function Copy-UfSshUser {
    param($From, $To)
    if ($script:UfSyncingSshUser) { return }
    $script:UfSyncingSshUser = $true
    try { if ($To.Text -ne $From.Text) { $To.Text = $From.Text } }
    finally { $script:UfSyncingSshUser = $false }
}

$txtSshUser.Add_TextChanged({ Copy-UfSshUser -From $txtSshUser -To $cboPuttyUser })
$txtSshUser.Add_Leave({ Show-UfSshBlocks })
$txtSshUser.Add_SelectedIndexChanged({ Show-UfSshBlocks })
$cboPuttyUser.Add_TextChanged({ Copy-UfSshUser -From $cboPuttyUser -To $txtSshUser })
$cboPuttyUser.Add_Leave({ Show-UfSshBlocks })
$cboPuttyUser.Add_SelectedIndexChanged({ Show-UfSshBlocks })
$txtDevice.Add_Leave({ Show-UfSshBlocks })
$txtHost.Add_Leave({ Show-UfSshBlocks })
# Deliberately no Resize handler on the SSH panel: rebuilding the blocks
# changes the layout, which raises Resize again. Use the Refresh button.

# =============================================================================
# Startup
# =============================================================================
# Anchors are set in Add_Shown, NOT at construction time. Setting Anchor before
# the form has laid itself out inflates the control to fill the anchored
# distance, and the tool still launches - which makes it a slow bug to find.

$form.Add_Shown({
    $anchorTopRight  = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
    $anchorTopLR     = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right

    $lblSshUser.Anchor     = $anchorTopRight
    $txtSshUser.Anchor     = $anchorTopRight
    $btnRunAll.Anchor      = $anchorTopRight
    $btnCancel.Anchor      = $anchorTopRight
    $lblUispNote.Anchor    = $anchorTopLR
    $lblVerdict.Anchor     = $anchorTopLR
    $lblVerdictSub.Anchor  = $anchorTopLR
    $lblStatus.Anchor      = $anchorTopLR
    $btnSaveReport.Anchor  = $anchorTopRight
    $btnSshRefresh.Anchor  = $anchorTopRight
    $btnCopyAllSsh.Anchor  = $anchorTopRight
    $lblSshHint.Anchor     = $anchorTopLR
    $lblPuttyIntro.Anchor  = $anchorTopLR
    $lblPuttyState.Anchor  = $anchorTopLR
    $lblPlinkWarn.Anchor   = $anchorTopLR
    $lblCtrlIntro.Anchor   = $anchorTopLR
    $lblApiState.Anchor    = $anchorTopLR
    $txtO43.Anchor         = $anchorTopLR
    $btnCopyO43.Anchor     = $anchorTopRight
    $lblO43Hint.Anchor     = $anchorTopLR

    # Maximise only now that the anchors are on. The right-hand controls are
    # placed for the 1180-wide design size, and an anchor records the distance
    # it finds rather than creating one - maximising first would strand the SSH
    # user box and Save report mid-header on a wide screen, with the anchor then
    # holding them there. A restore-down still lands on the centred design size.
    $form.WindowState = 'Maximized'
    $form.PerformLayout()

    # Splitter distances also need a laid-out form; setting them earlier throws.
    # After the maximise, so the proportions are of the window actually on
    # screen and not of the 830px one that was never really shown.
    try { $splitDiag.SplitterDistance = [int]($splitDiag.Height * 0.62) } catch { }
    try { $splitCtrl.SplitterDistance = [int]($splitCtrl.Height * 0.55) } catch { }
    try { $splitKb.SplitterDistance   = [int]($splitKb.Width  * 0.46) } catch { }

    Write-UfLog 'UniFi Troubleshooter started.' 'ok'
    if (-not $script:HelpersText) {
        Write-UfLog 'Could not read the helper region from this script file. Long tasks will run on the UI thread and the window will stop responding while they do.' 'warn'
    }

    Sync-UfPuttyState
    Show-UfSshBlocks
    Show-UfKb -ControllerHostValue $txtHost.Text.Trim() -ControllerIpValue ''

    # The incident this tool was built for, stated up front so a technician who
    # has never seen it knows what they are looking at.
    Set-UfVerdictBanner -Level 'info' `
        -Headline 'Ready - press Run full check' `
        -Sub 'Typical fault: a device powered off for a while comes back on http://unifi:8080/inform, which no local DNS can resolve. Run the check, then use Find Devices and the SSH blocks.'
})

$form.Add_FormClosing({
    param($eventSender, $e)
    if ($script:Sync.Running) {
        $script:Sync.Cancel = $true
        if ([System.Windows.Forms.MessageBox]::Show('A task is still running. Close anyway?', 'UniFi Troubleshooter', 'YesNo', 'Warning') -ne 'Yes') {
            $e.Cancel = $true
            return
        }
    }
    try { $timer.Stop() } catch { }
    if ($script:Worker) {
        try { $script:Worker.Stop() } catch { }
        try { $script:Worker.Dispose() } catch { }
    }
    if ($script:ControllerConn -and $script:ControllerConn.Connected) {
        try { Disconnect-UfController -Connection $script:ControllerConn } catch { }
    }
    # Leave certificate validation as we found it rather than leaving a
    # permissive callback behind in the session.
    try { [Net.ServicePointManager]::ServerCertificateValidationCallback = $null } catch { }
})

[void]$form.ShowDialog()
$form.Dispose()
