<#
.SYNOPSIS
    UniFi Layer-3 Adoption & Connectivity Troubleshooter
.DESCRIPTION
    Comprehensive diagnostic script to test local DNS, remote UniFi Controller reachability,
    inform port HTTP/TCP health, local UniFi device discovery (ARP/MAC OUI), and generate SSH remediation commands.
.PARAMETER ControllerHost
    The FQDN or IP of the UniFi Controller (e.g. unifi.example.com or 203.0.113.10).
.PARAMETER InformPort
    The UniFi inform port (default: 8080).
.EXAMPLE
    .\Test-UniFiTroubleshooter.ps1 -ControllerHost "unifi.example.com"
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $false)]
    [string]$ControllerHost = "unifi.example.com",

    [Parameter(Mandatory = $false)]
    [int]$InformPort = 8080
)

$ErrorActionPreference = "Continue"

Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "         UNIFI LAYER-3 TROUBLESHOOTING & DIAGNOSTIC SUITE        " -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "Target Controller : $ControllerHost" -ForegroundColor Yellow
Write-Host "Inform Port       : $InformPort" -ForegroundColor Yellow
Write-Host ""

# -------------------------------------------------------------
# 1. LOCAL NETWORK & DNS DIAGNOSTICS
# -------------------------------------------------------------
Write-Host "[1/5] Checking Local Network & DNS Client Configuration..." -ForegroundColor Green

$adapters = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -ne $null }
foreach ($adapter in $adapters) {
    Write-Host "  - Adapter       : $($adapter.InterfaceAlias)"
    Write-Host "    IPv4 Address  : $($adapter.IPv4Address.IPAddress)"
    Write-Host "    Gateway       : $($adapter.IPv4DefaultGateway.NextHop)"
    $dnsServers = (Get-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4).ServerAddresses
    Write-Host "    DNS Servers   : $($dnsServers -join ', ')"
}

# Test bare 'unifi' resolution
Write-Host "`n  Testing bare hostname 'unifi' resolution..." -NoNewline
try {
    $unifiDns = Resolve-DnsName -Name "unifi" -Type A -ErrorAction Stop
    Write-Host " [FOUND]" -ForegroundColor Green
    Write-Host "    Resolved 'unifi' -> $($unifiDns.IPAddress -join ', ')" -ForegroundColor Gray
} catch {
    Write-Host " [NOT CONFIGURED]" -ForegroundColor Yellow
    Write-Host "    Default 'unifi' hostname does not resolve in local DNS (Expected if no local DNS override / Option 43 exists)." -ForegroundColor DarkGray
}

# Test Controller Host Resolution
Write-Host "  Testing Controller Host '$ControllerHost' resolution..." -NoNewline
$controllerIps = @()
try {
    $controllerDns = Resolve-DnsName -Name $ControllerHost -Type A -ErrorAction Stop
    $controllerIps = $controllerDns.IPAddress
    Write-Host " [RESOLVED]" -ForegroundColor Green
    Write-Host "    Target IP(s)  : $($controllerIps -join ', ')" -ForegroundColor Gray
} catch {
    Write-Host " [FAILED]" -ForegroundColor Red
    Write-Host "    Error: Unable to resolve $ControllerHost. Verify internet connectivity and DNS settings." -ForegroundColor Red
}

# -------------------------------------------------------------
# 2. CONTROLLER TCP & HTTP INFORM PROBE
# -------------------------------------------------------------
Write-Host "`n[2/5] Testing Controller Port & Service Health..." -ForegroundColor Green

$tcpResult = Test-NetConnection -ComputerName $ControllerHost -Port $InformPort -WarningAction SilentlyContinue
if ($tcpResult.TcpTestSucceeded) {
    Write-Host "  - TCP Port $InformPort Reachability : [PASS] Connected successfully." -ForegroundColor Green
} else {
    Write-Host "  - TCP Port $InformPort Reachability : [FAIL] Connection timed out or port closed." -ForegroundColor Red
    Write-Host "    Action: Check firewall / NAT port forwarding for TCP $InformPort on the controller gateway." -ForegroundColor Yellow
}

# HTTP Inform probe test
$informUri = "http://${ControllerHost}:${InformPort}/inform"
Write-Host "  - Probing Inform Endpoint ($informUri)..." -NoNewline
try {
    $response = Invoke-WebRequest -Uri $informUri -Method GET -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    Write-Host " [HTTP $($response.StatusCode)]" -ForegroundColor Green
} catch {
    if ($_.Exception.Response -and $_.Exception.Response.StatusCode -eq 400) {
        Write-Host " [HTTP 400 Bad Request - EXPECTED]" -ForegroundColor Green
        Write-Host "    Note: HTTP 400 is the expected response from a healthy UniFi inform daemon for raw HTTP requests." -ForegroundColor DarkGray
    } else {
        Write-Host " [ERROR: $($_.Exception.Message)]" -ForegroundColor Red
    }
}

# -------------------------------------------------------------
# 3. LOCAL UNIFI DEVICE DISCOVERY (ARP CACHE INSPECTION)
# -------------------------------------------------------------
Write-Host "`n[3/5] Scanning Local ARP Cache for UniFi Device MACs..." -ForegroundColor Green

# Common Ubiquiti OUI prefixes
$ubntOuis = @("d8-b3-70", "78-8a-20", "ac-8b-a9", "b4-fb-e4", "24-a4-3c", "04-18-d6", "f0-9f-c2", "e0-63-da", "68-d7-9a", "80-2a-a8")

$arpEntries = Get-NetNeighbor -AddressFamily IPv4 | Where-Object { $_.State -ne 'Permanent' -and $_.LinkLayerAddress }
$discoveredUniFi = @()

foreach ($entry in $arpEntries) {
    $mac = $entry.LinkLayerAddress.ToLower()
    foreach ($oui in $ubntOuis) {
        if ($mac.StartsWith($oui)) {
            $discoveredUniFi += [PSCustomObject]@{
                IPAddress = $entry.IPAddress
                MAC       = $entry.LinkLayerAddress
                Interface = $entry.InterfaceAlias
            }
        }
    }
}

if ($discoveredUniFi.Count -gt 0) {
    Write-Host "  Found $($discoveredUniFi.Count) suspected UniFi device(s) on local subnet:" -ForegroundColor Green
    $discoveredUniFi | Format-Table -AutoSize | Out-String | Write-Host -ForegroundColor Yellow
} else {
    Write-Host "  No UniFi MAC addresses found in current ARP cache." -ForegroundColor Gray
    Write-Host "  Tip: Ping your subnet range (e.g. 192.168.1.1-254) or check DHCP server leases to find AP IP." -ForegroundColor DarkGray
}

# -------------------------------------------------------------
# 4. SSH & ADOPTION COMMAND GENERATOR
# -------------------------------------------------------------
Write-Host "[4/5] Remediation & Set-Inform Command Generator" -ForegroundColor Green

$sampleIp = if ($discoveredUniFi.Count -gt 0) { $discoveredUniFi[0].IPAddress } else { "<AP_IP_ADDRESS>" }

Write-Host "  Run these commands in SSH (PuTTY or Windows Terminal):" -ForegroundColor Cyan
Write-Host ""
Write-Host "  1. Connect to Access Point:" -ForegroundColor White
Write-Host "     ssh ubnt@$sampleIp" -ForegroundColor Yellow
Write-Host "     (Default password is 'ubnt' for unadopted/reset AP, or your Site Device Password for adopted AP)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  2. Check current AP status:" -ForegroundColor White
Write-Host "     mca-cli-op info" -ForegroundColor Yellow
Write-Host ""
Write-Host "  3. Set remote controller inform URL (Step 1):" -ForegroundColor White
Write-Host "     set-inform http://${ControllerHost}:${InformPort}/inform" -ForegroundColor Yellow
Write-Host ""
Write-Host "  4. In UniFi Controller Web UI:" -ForegroundColor White
Write-Host "     - Open Devices page -> Click 'Adopt' on the AP (shows 'Pending Adoption')" -ForegroundColor Yellow
Write-Host ""
Write-Host "  5. Re-run set-inform command on AP (Step 2 - Layer 3 requirement):" -ForegroundColor White
Write-Host "     set-inform http://${ControllerHost}:${InformPort}/inform" -ForegroundColor Yellow
Write-Host ""

# -------------------------------------------------------------
# 5. SUMMARY & HEALTH STATUS
# -------------------------------------------------------------
Write-Host "[5/5] Diagnostic Summary" -ForegroundColor Green
if ($tcpResult.TcpTestSucceeded) {
    Write-Host "  [OK] Network path to UniFi Controller (${ControllerHost}:${InformPort}) is OPEN and READY." -ForegroundColor Green
    Write-Host "       Execute 'set-inform http://${ControllerHost}:${InformPort}/inform' via SSH on your AP to resolve 'Unable to resolve' errors." -ForegroundColor Cyan
} else {
    Write-Host "  [CRITICAL] Controller port $InformPort is UNREACHABLE. Check router NAT/port-forwarding rules before troubleshooting AP." -ForegroundColor Red
}
Write-Host "================================================================" -ForegroundColor Cyan
