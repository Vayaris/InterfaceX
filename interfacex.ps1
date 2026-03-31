# =============================================================================
#  InterfaceX v1.1.0 - Network Interface Configuration Tool
#  Fast, beautiful CMD-based network config with presets
# =============================================================================

$script:Version         = "1.1.1"
$script:PresetFile      = Join-Path $PSScriptRoot "presets.json"
$script:HistoryFile     = Join-Path $PSScriptRoot "history.json"
$script:ProfilesFile    = Join-Path $PSScriptRoot "profiles.json"
$script:ShowAll         = $false
$script:AutoDetectShown = $false
$script:MaxHistory      = 10

# ─── TUI Drawing Functions ───────────────────────────────────────────────────

function Write-Color($text, $color = "White") {
    Write-Host $text -ForegroundColor $color -NoNewline
}

function Write-ColorLine($text, $color = "White") {
    Write-Host $text -ForegroundColor $color
}

function Write-Header {
    Clear-Host
    $w = 58
    $border = "+" + ("-" * ($w - 2)) + "+"
    $empty  = "|" + (" " * ($w - 2)) + "|"
    $title  = "InterfaceX v$($script:Version)"
    $sub    = "Network Interface Configuration Tool"
    $tPad   = [math]::Floor(($w - 2 - $title.Length) / 2)
    $sPad   = [math]::Floor(($w - 2 - $sub.Length) / 2)

    Write-ColorLine $border "Cyan"
    Write-ColorLine $empty "Cyan"
    Write-Color "|" "Cyan"; Write-Color (" " * $tPad) "Cyan"
    Write-Color $title "Yellow"; Write-Color (" " * ($w - 2 - $tPad - $title.Length)) "Cyan"
    Write-ColorLine "|" "Cyan"
    Write-Color "|" "Cyan"; Write-Color (" " * $sPad) "Cyan"
    Write-Color $sub "White"; Write-Color (" " * ($w - 2 - $sPad - $sub.Length)) "Cyan"
    Write-ColorLine "|" "Cyan"
    Write-ColorLine $empty "Cyan"
    Write-ColorLine $border "Cyan"
    Write-Host ""
}

function Write-Separator {
    Write-ColorLine ("  " + ("-" * 54)) "DarkGray"
}

function Write-StatusLine($label, $value, $valueColor = "White") {
    Write-Color ("  {0,-16}" -f "${label}:") "DarkGray"
    Write-ColorLine $value $valueColor
}

function Invoke-WithSpinner {
    param([string]$Message, [scriptblock]$ScriptBlock)

    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($msg)
        $frames = @('|', '/', '-', '\')
        $i = 0
        [Console]::CursorVisible = $false
        while ($true) {
            [Console]::Write("`r  $msg " + $frames[$i % 4] + "   ")
            $i++
            Start-Sleep -Milliseconds 80
        }
    }).AddArgument($Message)
    [void]$ps.BeginInvoke()

    $capturedError = $null
    $result = $null
    try {
        $result = & $ScriptBlock
    } catch {
        $capturedError = $_
    } finally {
        $ps.Stop()
        $rs.Close()
        $rs.Dispose()
        $ps.Dispose()
        [Console]::CursorVisible = $true
        [Console]::Write("`r" + (" " * ($Message.Length + 10)) + "`r")
    }

    if ($capturedError) { throw $capturedError }
    return $result
}

function Read-SingleKey($prompt) {
    Write-Host ""
    Write-Color "  $prompt " "Yellow"
    do {
        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    } while ([int]$key.Character -eq 0)
    $char = $key.Character
    Write-Host $char
    return [string]$char
}

function Read-InputWithDefault($prompt, $default) {
    if ($default) {
        Write-Color "  $prompt " "Yellow"
        Write-Color "[$default]" "DarkGray"
        Write-Color ": " "Yellow"
    } else {
        Write-Color "  ${prompt}: " "Yellow"
    }
    $userInput = Read-Host
    if ([string]::IsNullOrWhiteSpace($userInput) -and $default) {
        return $default
    }
    return $userInput
}

# ─── Validation Functions ────────────────────────────────────────────────────

function Test-IPv4Address($ip) {
    if ($ip -notmatch '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$') { return $false }
    $octets = $ip.Split('.')
    foreach ($o in $octets) {
        $n = [int]$o
        if ($n -lt 0 -or $n -gt 255) { return $false }
    }
    return $true
}

function Test-SubnetMask($mask) {
    if (-not (Test-IPv4Address $mask)) { return $false }
    $octets = $mask.Split('.') | ForEach-Object { [int]$_ }
    $binary = ($octets | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') }) -join ''
    return $binary -match '^1*0*$'
}

function Convert-PrefixToMask($prefix) {
    $p = [int]$prefix
    if ($p -lt 0 -or $p -gt 32) { return $null }
    $binary = ('1' * $p).PadRight(32, '0')
    $octets = @()
    for ($i = 0; $i -lt 4; $i++) {
        $octets += [Convert]::ToInt32($binary.Substring($i * 8, 8), 2)
    }
    return ($octets -join '.')
}

function Convert-MaskToPrefix($mask) {
    $octets = $mask.Split('.') | ForEach-Object { [int]$_ }
    $binary = ($octets | ForEach-Object { [Convert]::ToString($_, 2).PadLeft(8, '0') }) -join ''
    return ($binary.ToCharArray() | Where-Object { $_ -eq '1' }).Count
}

function Resolve-Mask($maskStr) {
    if ($maskStr -match '^/?\d{1,2}$') {
        $prefix = [int]($maskStr -replace '/', '')
        $mask = Convert-PrefixToMask $prefix
        if ($mask) { return $mask }
    }
    if (Test-SubnetMask $maskStr) { return $maskStr }
    return $null
}

# ─── Network Interface Discovery ────────────────────────────────────────────

function Get-NetworkInterfaces {
    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue
    if (-not $script:ShowAll) {
        $adapters = $adapters | Where-Object {
            $_.Status -eq 'Up' -or
            $_.PhysicalMediaType -ne 'Unspecified' -or
            $_.Name -match 'Wi-Fi|Ethernet|LAN'
        }
    }
    $adapters = $adapters | Sort-Object -Property @{Expression={if($_.Status -eq 'Up'){0}else{1}}}, Name

    $result = @()
    foreach ($a in $adapters) {
        $ipInfo  = Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                   Where-Object { $_.IPAddress -ne '127.0.0.1' } | Select-Object -First 1
        $gwInfo  = Get-NetRoute -InterfaceIndex $a.ifIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
                   Select-Object -First 1
        $dnsInfo = Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $dhcpInfo= Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue

        $result += [PSCustomObject]@{
            Name    = $a.Name
            Index   = $a.ifIndex
            Status  = $a.Status
            Speed   = $a.LinkSpeed
            Mac     = $a.MacAddress
            IP      = if ($ipInfo) { $ipInfo.IPAddress } else { "--" }
            Prefix  = if ($ipInfo) { $ipInfo.PrefixLength } else { $null }
            Mask    = if ($ipInfo) { Convert-PrefixToMask $ipInfo.PrefixLength } else { "--" }
            Gateway = if ($gwInfo) { $gwInfo.NextHop } else { "--" }
            DNS     = if ($dnsInfo -and $dnsInfo.ServerAddresses) { $dnsInfo.ServerAddresses } else { @() }
            DHCP    = if ($dhcpInfo) { $dhcpInfo.Dhcp -eq 'Enabled' } else { $false }
        }
    }
    return $result
}

# ─── Network Configuration ───────────────────────────────────────────────────

function Set-InterfaceDHCP($name) {
    Write-Host ""
    Write-Color "  Switching " "White"
    Write-Color $name "Yellow"
    Write-ColorLine " to DHCP..." "White"

    try {
        Invoke-WithSpinner "Applying DHCP config" {
            $r1 = netsh interface ipv4 set address name="$name" source=dhcp 2>&1
            if ($LASTEXITCODE -ne 0) { throw "netsh address: $r1" }
            $r2 = netsh interface ipv4 set dns name="$name" source=dhcp 2>&1
            if ($LASTEXITCODE -ne 0) { throw "netsh dns: $r2" }
            Start-Sleep -Milliseconds 600
        }
        Write-ColorLine "  [OK] DHCP enabled successfully!" "Green"
        Add-HistoryEntry $name @{
            timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
            dhcp = $true; ip = ""; mask = ""; gateway = ""; dns1 = ""; dns2 = ""
        }
    }
    catch {
        Write-ColorLine "  [ERROR] $($_.Exception.Message)" "Red"
    }
    Write-Host ""
    Write-Color "  Press any key..." "DarkGray"
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

function Set-InterfaceStatic($name, $ip, $mask, $gw, $dns1, $dns2) {
    Write-Host ""
    Write-Color "  Applying static config to " "White"
    Write-ColorLine $name "Yellow"

    try {
        Invoke-WithSpinner "Applying static config" {
            $r = netsh interface ipv4 set address name="$name" static $ip $mask $gw 2>&1
            if ($LASTEXITCODE -ne 0) { throw "netsh address: $r" }
            $r = netsh interface ipv4 set dns name="$name" static $dns1 2>&1
            if ($LASTEXITCODE -ne 0) { throw "netsh dns: $r" }
            if ($dns2 -and $dns2 -ne "--" -and $dns2 -ne "") {
                $r = netsh interface ipv4 add dns name="$name" $dns2 index=2 2>&1
            }
            Start-Sleep -Milliseconds 400
        }
        Write-ColorLine "  [OK] Static IP configured successfully!" "Green"
        Write-StatusLine "IP" "$ip / $mask" "Cyan"
        Write-StatusLine "Gateway" $gw "Cyan"
        Write-StatusLine "DNS" "$dns1$(if($dns2 -and $dns2 -ne '--'){', '+$dns2})" "Cyan"
        Add-HistoryEntry $name @{
            timestamp = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
            dhcp = $false; ip = $ip; mask = $mask; gateway = $gw; dns1 = $dns1; dns2 = $dns2
        }
    }
    catch {
        Write-ColorLine "  [ERROR] $($_.Exception.Message)" "Red"
    }
    Write-Host ""
    Write-Color "  Press any key..." "DarkGray"
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
}

# ─── Static IP Interactive Prompt ────────────────────────────────────────────

function Invoke-StaticIPPrompt($iface) {
    Write-Header
    Write-ColorLine "  Configure Static IP - $($iface.Name)" "Cyan"
    Write-Separator
    Write-Host ""

    do {
        $defaultIP = if ($iface.IP -ne "--") { $iface.IP } else { "" }
        $ip = Read-InputWithDefault "IP Address" $defaultIP
        if (-not (Test-IPv4Address $ip)) {
            Write-ColorLine "  Invalid IP address. Try again." "Red"
        }
    } while (-not (Test-IPv4Address $ip))

    do {
        $defaultMask = if ($iface.Mask -ne "--") { $iface.Mask } else { "255.255.255.0" }
        $maskInput = Read-InputWithDefault "Subnet Mask (or /prefix)" $defaultMask
        $mask = Resolve-Mask $maskInput
        if (-not $mask) {
            Write-ColorLine "  Invalid subnet mask. Use 255.255.255.0 or /24 format." "Red"
        }
    } while (-not $mask)

    do {
        $defaultGW = if ($iface.Gateway -ne "--") { $iface.Gateway } else { "" }
        $gw = Read-InputWithDefault "Gateway" $defaultGW
        if ($gw -and -not (Test-IPv4Address $gw)) {
            Write-ColorLine "  Invalid gateway address. Try again." "Red"
            $gw = $null
        }
    } while (-not $gw)

    do {
        $defaultDNS1 = if ($iface.DNS.Count -gt 0) { $iface.DNS[0] } else { "8.8.8.8" }
        $dns1 = Read-InputWithDefault "Primary DNS" $defaultDNS1
        if (-not (Test-IPv4Address $dns1)) {
            Write-ColorLine "  Invalid DNS address. Try again." "Red"
        }
    } while (-not (Test-IPv4Address $dns1))

    $defaultDNS2 = if ($iface.DNS.Count -gt 1) { $iface.DNS[1] } else { "8.8.4.4" }
    $dns2 = Read-InputWithDefault "Secondary DNS (Enter to skip)" $defaultDNS2

    if ($dns2 -and -not (Test-IPv4Address $dns2)) {
        Write-ColorLine "  Invalid secondary DNS, skipping." "Yellow"
        $dns2 = ""
    }

    Write-Host ""
    Write-Separator
    Write-ColorLine "  Summary:" "Cyan"
    Write-StatusLine "IP" "$ip / $mask" "White"
    Write-StatusLine "Gateway" $gw "White"
    Write-StatusLine "DNS" "$dns1$(if($dns2){', '+$dns2})" "White"
    Write-Host ""
    $confirm = Read-SingleKey "Apply? [Y/n]"

    if ($confirm -eq '' -or $confirm -match '[Yy]') {
        Set-InterfaceStatic $iface.Name $ip $mask $gw $dns1 $dns2
    } else {
        Write-ColorLine "  Cancelled." "Yellow"
        Start-Sleep -Milliseconds 500
    }
}

# ─── Preset System ───────────────────────────────────────────────────────────

function Get-Presets {
    if (-not (Test-Path $script:PresetFile)) { return @() }
    try {
        $content = Get-Content $script:PresetFile -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($content)) { return @() }
        $presets = $content | ConvertFrom-Json
        if ($presets -isnot [Array]) { $presets = @($presets) }
        return $presets
    }
    catch {
        Write-ColorLine "  [WARN] Preset file corrupted. Backing up and resetting." "Yellow"
        Copy-Item $script:PresetFile "$($script:PresetFile).bak" -Force -ErrorAction SilentlyContinue
        return @()
    }
}

function Save-Presets($presets) {
    $presets | ConvertTo-Json -Depth 10 | Set-Content $script:PresetFile -Force
}

function Save-CurrentAsPreset($iface) {
    Write-Header
    Write-ColorLine "  Save Preset - $($iface.Name)" "Cyan"
    Write-Separator
    Write-Host ""

    $name = Read-InputWithDefault "Preset name" ""
    if ([string]::IsNullOrWhiteSpace($name)) {
        Write-ColorLine "  Cancelled." "Yellow"
        Start-Sleep -Milliseconds 500
        return
    }

    $currentSSID = Get-CurrentSSID
    $ssidDefault = if ($currentSSID) { $currentSSID } else { "" }
    $ssid = Read-InputWithDefault "SSID for auto-detect (Enter to skip)" $ssidDefault

    $presets = @(Get-Presets)
    $existing = $presets | Where-Object { $_.name -eq $name }
    if ($existing) {
        $overwrite = Read-SingleKey "Preset '$name' exists. Overwrite? [Y/n]"
        if ($overwrite -notmatch '[Yy]' -and $overwrite -ne '') { return }
        $presets = @($presets | Where-Object { $_.name -ne $name })
    }

    $preset = @{
        name    = $name
        dhcp    = $iface.DHCP
        ip      = $iface.IP
        mask    = $iface.Mask
        gateway = $iface.Gateway
        dns1    = if ($iface.DNS.Count -gt 0) { $iface.DNS[0] } else { "" }
        dns2    = if ($iface.DNS.Count -gt 1) { $iface.DNS[1] } else { "" }
        ssid    = $ssid
    }

    $presets += $preset
    Save-Presets $presets
    Write-ColorLine "  [OK] Preset '$name' saved!" "Green"
    Start-Sleep -Milliseconds 800
}

function Export-Presets {
    Write-Header
    Write-ColorLine "  Export Presets" "Cyan"
    Write-Separator
    Write-Host ""

    $presets = @(Get-Presets)
    if ($presets.Count -eq 0) {
        Write-ColorLine "  No presets to export." "Yellow"
        Start-Sleep -Milliseconds 800
        return
    }

    $defaultPath = Join-Path $env:USERPROFILE "Desktop\interfacex-presets.json"
    $path = Read-InputWithDefault "Export path" $defaultPath
    $path = $path.Trim('"')

    try {
        $presets | ConvertTo-Json -Depth 10 | Set-Content $path -Force -ErrorAction Stop
        Write-ColorLine "  [OK] Exported $($presets.Count) preset(s) to:" "Green"
        Write-ColorLine "       $path" "DarkGray"
    }
    catch {
        Write-ColorLine "  [ERROR] $($_.Exception.Message)" "Red"
    }
    Start-Sleep -Milliseconds 1200
}

function Import-Presets {
    Write-Header
    Write-ColorLine "  Import Presets" "Cyan"
    Write-Separator
    Write-Host ""

    $path = Read-InputWithDefault "Import file path" ""
    $path = $path.Trim('"')

    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path $path)) {
        Write-ColorLine "  File not found." "Red"
        Start-Sleep -Milliseconds 800
        return
    }

    try {
        $content = Get-Content $path -Raw -ErrorAction Stop
        $rawData = $content | ConvertFrom-Json
        $incoming = @($rawData)
    }
    catch {
        Write-ColorLine "  [ERROR] Cannot read file: $($_.Exception.Message)" "Red"
        Start-Sleep -Milliseconds 800
        return
    }

    $valid = @($incoming | Where-Object { $_.name -and -not [string]::IsNullOrWhiteSpace($_.name) })
    if ($valid.Count -eq 0) {
        Write-ColorLine "  No valid presets found in file." "Yellow"
        Start-Sleep -Milliseconds 800
        return
    }

    $merged = @(Get-Presets)
    $imported = 0; $skipped = 0

    foreach ($p in $valid) {
        $dup = $merged | Where-Object { $_.name -eq $p.name }
        if ($dup) {
            $ow = Read-SingleKey "Preset '$($p.name)' exists. Overwrite? [Y/n]"
            if ($ow -eq '' -or $ow -match '[Yy]') {
                $merged = @($merged | Where-Object { $_.name -ne $p.name })
                $merged += $p
                $imported++
            } else { $skipped++ }
        } else {
            $merged += $p
            $imported++
        }
    }

    Save-Presets $merged
    Write-Host ""
    Write-ColorLine "  [OK] Imported: $imported   Skipped: $skipped" "Green"
    Start-Sleep -Milliseconds 1000
}

function Show-PresetMenu($interfaceName) {
    while ($true) {
        Write-Header
        Write-ColorLine "  Presets" "Cyan"
        if ($interfaceName) { Write-ColorLine "  Target: $interfaceName" "DarkGray" }
        Write-Separator
        Write-Host ""

        $presets = @(Get-Presets)
        if ($presets.Count -eq 0) {
            Write-ColorLine "  No presets saved yet." "DarkGray"
            Write-Host ""
            Write-ColorLine "  [E] Export    [I] Import    [B] Back" "White"
            $choice = Read-SingleKey ">"
            if ($choice -match '[Ee]') { Export-Presets; continue }
            if ($choice -match '[Ii]') { Import-Presets; continue }
            return
        }

        for ($i = 0; $i -lt $presets.Count; $i++) {
            $p = $presets[$i]
            $mode = if ($p.dhcp) { "DHCP" } else { "$($p.ip)/$($p.mask)" }
            Write-Color "  [$($i+1)] " "Cyan"
            Write-Color ("{0,-18}" -f $p.name) "White"
            Write-ColorLine $mode "DarkGray"
        }

        Write-Host ""
        Write-ColorLine "  [E] Export    [I] Import    [D] Delete    [B] Back" "White"
        $choice = Read-SingleKey ">"

        if ($choice -match '[Bb]') { return }
        if ($choice -match '[Ee]') { Export-Presets; continue }
        if ($choice -match '[Ii]') { Import-Presets; continue }
        if ($choice -match '[Dd]') {
            $delChoice = Read-SingleKey "Delete preset # >"
            $delIdx = 0
            if ([int]::TryParse($delChoice, [ref]$delIdx) -and $delIdx -ge 1 -and $delIdx -le $presets.Count) {
                $toDelete = $presets[$delIdx - 1]
                $presets = @($presets | Where-Object { $_.name -ne $toDelete.name })
                Save-Presets $presets
                Write-ColorLine "  [OK] Preset deleted." "Green"
                Start-Sleep -Milliseconds 500
            }
            continue
        }

        $idx = 0
        if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $presets.Count) {
            $selected = $presets[$idx - 1]
            if ($interfaceName) {
                Apply-Preset $selected $interfaceName
                return
            } else {
                Write-ColorLine "  Select an interface first to apply a preset." "Yellow"
                Start-Sleep -Milliseconds 800
            }
        }
    }
}

function Apply-Preset($preset, $interfaceName) {
    Write-Host ""
    Write-Color "  Applying preset " "White"
    Write-Color "'$($preset.name)'" "Yellow"
    Write-Color " to " "White"
    Write-ColorLine $interfaceName "Cyan"

    if ($preset.dhcp) {
        Set-InterfaceDHCP $interfaceName
    } else {
        Set-InterfaceStatic $interfaceName $preset.ip $preset.mask $preset.gateway $preset.dns1 $preset.dns2
    }
}

# ─── History System ──────────────────────────────────────────────────────────

function Get-History {
    if (-not (Test-Path $script:HistoryFile)) { return @{} }
    try {
        $content = Get-Content $script:HistoryFile -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($content)) { return @{} }
        $raw = $content | ConvertFrom-Json
        $h = @{}
        $raw.PSObject.Properties | ForEach-Object { $h[$_.Name] = @($_.Value) }
        return $h
    }
    catch { return @{} }
}

function Save-History($history) {
    $history | ConvertTo-Json -Depth 10 | Set-Content $script:HistoryFile -Force
}

function Add-HistoryEntry($interfaceName, $entry) {
    $history = Get-History
    if (-not $history.ContainsKey($interfaceName)) { $history[$interfaceName] = @() }
    $history[$interfaceName] = @($entry) + @($history[$interfaceName])
    if ($history[$interfaceName].Count -gt $script:MaxHistory) {
        $history[$interfaceName] = $history[$interfaceName][0..($script:MaxHistory - 1)]
    }
    Save-History $history
}

function Show-HistoryMenu($iface) {
    while ($true) {
        Write-Header
        Write-ColorLine "  Config History - $($iface.Name)" "Cyan"
        Write-Separator
        Write-Host ""

        $history = Get-History
        $entries = @()
        if ($history.ContainsKey($iface.Name)) { $entries = @($history[$iface.Name]) }

        if ($entries.Count -eq 0) {
            Write-ColorLine "  No history yet for this interface." "DarkGray"
            Write-Host ""
            Read-SingleKey "Press any key to return..." | Out-Null
            return
        }

        for ($i = 0; $i -lt $entries.Count; $i++) {
            $e = $entries[$i]
            $modeText = if ($e.dhcp) { "DHCP" } else { "Static  $($e.ip)" }
            $gwText   = if (-not $e.dhcp -and $e.gateway) { "  GW:$($e.gateway)" } else { "" }
            Write-Color "  [$($i+1)] " "Cyan"
            Write-Color ("{0,-20}" -f $e.timestamp) "DarkGray"
            Write-Color ("{0,-22}" -f $modeText) "White"
            Write-ColorLine $gwText "DarkGray"
        }

        Write-Host ""
        Write-ColorLine "  [D] Delete entry    [B] Back" "White"
        $choice = Read-SingleKey "Select to rollback or action >"

        if ($choice -match '[Bb]') { return }

        if ($choice -match '[Dd]') {
            $delChoice = Read-SingleKey "Delete entry # >"
            $delIdx = 0
            if ([int]::TryParse($delChoice, [ref]$delIdx) -and $delIdx -ge 1 -and $delIdx -le $entries.Count) {
                $newEntries = @()
                for ($j = 0; $j -lt $entries.Count; $j++) {
                    if ($j -ne ($delIdx - 1)) { $newEntries += $entries[$j] }
                }
                $history[$iface.Name] = $newEntries
                Save-History $history
                Write-ColorLine "  [OK] Entry deleted." "Green"
                Start-Sleep -Milliseconds 500
            }
            continue
        }

        $idx = 0
        if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $entries.Count) {
            $entry = $entries[$idx - 1]
            $synth = [PSCustomObject]@{
                name    = "history-rollback"
                dhcp    = [bool]$entry.dhcp
                ip      = [string]$entry.ip
                mask    = [string]$entry.mask
                gateway = [string]$entry.gateway
                dns1    = [string]$entry.dns1
                dns2    = [string]$entry.dns2
            }
            Apply-Preset $synth $iface.Name
        }
    }
}

# ─── Profile System ──────────────────────────────────────────────────────────

function Get-Profiles {
    if (-not (Test-Path $script:ProfilesFile)) { return @() }
    try {
        $content = Get-Content $script:ProfilesFile -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($content)) { return @() }
        $profiles = $content | ConvertFrom-Json
        if ($profiles -isnot [Array]) { $profiles = @($profiles) }
        return $profiles
    }
    catch { return @() }
}

function Save-Profiles($profiles) {
    $profiles | ConvertTo-Json -Depth 10 | Set-Content $script:ProfilesFile -Force
}

function New-ProfileWizard {
    Write-Header
    Write-ColorLine "  New Profile" "Cyan"
    Write-Separator
    Write-Host ""

    $profileName = Read-InputWithDefault "Profile name" ""
    if ([string]::IsNullOrWhiteSpace($profileName)) {
        Write-ColorLine "  Cancelled." "Yellow"
        Start-Sleep -Milliseconds 500
        return
    }

    $presets = @(Get-Presets)
    if ($presets.Count -eq 0) {
        Write-ColorLine "  No presets available. Create presets first." "Yellow"
        Start-Sleep -Milliseconds 800
        return
    }

    $interfaces = @(Invoke-WithSpinner "Loading interfaces" { Get-NetworkInterfaces })

    Write-Host ""
    Write-ColorLine "  Available presets:" "DarkGray"
    foreach ($p in $presets) {
        $mode = if ($p.dhcp) { "DHCP" } else { $p.ip }
        Write-ColorLine "    - $($p.name) ($mode)" "DarkGray"
    }
    Write-Host ""

    $mappings = @()
    foreach ($iface in $interfaces) {
        $presetName = Read-InputWithDefault "Preset for '$($iface.Name)' (Enter to skip)" ""
        if ([string]::IsNullOrWhiteSpace($presetName)) { continue }
        $found = $presets | Where-Object { $_.name -eq $presetName }
        if (-not $found) {
            Write-ColorLine "  [WARN] Preset '$presetName' not found, skipping." "Yellow"
            continue
        }
        $mappings += @{ interface = $iface.Name; preset = $presetName }
    }

    if ($mappings.Count -eq 0) {
        Write-ColorLine "  No mappings defined. Profile not saved." "Yellow"
        Start-Sleep -Milliseconds 800
        return
    }

    $profiles = @(Get-Profiles)
    $existing = $profiles | Where-Object { $_.name -eq $profileName }
    if ($existing) {
        $ow = Read-SingleKey "Profile '$profileName' exists. Overwrite? [Y/n]"
        if ($ow -notmatch '[Yy]' -and $ow -ne '') { return }
        $profiles = @($profiles | Where-Object { $_.name -ne $profileName })
    }

    $profiles += @{ name = $profileName; mappings = $mappings }
    Save-Profiles $profiles
    Write-ColorLine "  [OK] Profile '$profileName' saved with $($mappings.Count) mapping(s)!" "Green"
    Start-Sleep -Milliseconds 800
}

function Invoke-ApplyProfile($profile) {
    Write-Header
    Write-ColorLine "  Applying Profile - $($profile.name)" "Cyan"
    Write-Separator
    Write-Host ""

    $presets = @(Get-Presets)
    $mappings = @($profile.mappings)

    foreach ($m in $mappings) {
        $found = $presets | Where-Object { $_.name -eq $m.preset }
        if (-not $found) {
            Write-Color "  [SKIP] " "Yellow"
            Write-ColorLine "Preset '$($m.preset)' not found." "DarkGray"
            continue
        }
        Write-Color "  Applying " "White"
        Write-Color "'$($m.preset)'" "Yellow"
        Write-Color " -> " "DarkGray"
        Write-ColorLine $m.interface "Cyan"
        Apply-Preset $found $m.interface
    }

    Write-Host ""
    Write-ColorLine "  [OK] Profile applied." "Green"
    Start-Sleep -Milliseconds 800
}

function Show-ProfileMenu {
    while ($true) {
        Write-Header
        Write-ColorLine "  Profiles" "Cyan"
        Write-Separator
        Write-Host ""

        $profiles = @(Get-Profiles)
        if ($profiles.Count -eq 0) {
            Write-ColorLine "  No profiles saved yet." "DarkGray"
            Write-Host ""
            Write-ColorLine "  [N] New profile    [B] Back" "White"
            $choice = Read-SingleKey ">"
            if ($choice -match '[Nn]') { New-ProfileWizard; continue }
            return
        }

        for ($i = 0; $i -lt $profiles.Count; $i++) {
            $pr = $profiles[$i]
            $mapCount = @($pr.mappings).Count
            Write-Color "  [$($i+1)] " "Cyan"
            Write-Color ("{0,-20}" -f $pr.name) "White"
            Write-ColorLine "($mapCount mapping$(if($mapCount -ne 1){'s'}))" "DarkGray"
        }

        Write-Host ""
        Write-ColorLine "  [N] New    [D] Delete    [B] Back" "White"
        $choice = Read-SingleKey "Select profile or action >"

        if ($choice -match '[Bb]') { return }
        if ($choice -match '[Nn]') { New-ProfileWizard; continue }
        if ($choice -match '[Dd]') {
            $delChoice = Read-SingleKey "Delete profile # >"
            $delIdx = 0
            if ([int]::TryParse($delChoice, [ref]$delIdx) -and $delIdx -ge 1 -and $delIdx -le $profiles.Count) {
                $toDelete = $profiles[$delIdx - 1]
                $profiles = @($profiles | Where-Object { $_.name -ne $toDelete.name })
                Save-Profiles $profiles
                Write-ColorLine "  [OK] Profile deleted." "Green"
                Start-Sleep -Milliseconds 500
            }
            continue
        }

        $idx = 0
        if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $profiles.Count) {
            Invoke-ApplyProfile $profiles[$idx - 1]
        }
    }
}

# ─── Diagnostics & Auto-detect ───────────────────────────────────────────────

function Get-CurrentSSID {
    try {
        $raw = netsh wlan show interfaces 2>&1
        $line = $raw | Where-Object { $_ -match '^\s+SSID\s+:' } | Select-Object -First 1
        if ($line -match ':\s+(.+)$') { return $matches[1].Trim() }
    } catch {}
    return $null
}

function Invoke-AutoDetect {
    $presets = @(Get-Presets)
    if ($presets.Count -eq 0) { return $null }
    $interfaces  = @(Get-NetworkInterfaces)
    $upIfaces    = @($interfaces | Where-Object { $_.Status -eq 'Up' })
    if ($upIfaces.Count -eq 0) { return $null }

    $currentSSID     = Get-CurrentSSID
    $currentGateways = @($upIfaces | Where-Object { $_.Gateway -ne "--" } | Select-Object -ExpandProperty Gateway -Unique)

    foreach ($p in $presets) {
        if ($p.ssid -and $currentSSID -and $p.ssid -eq $currentSSID) {
            $wifiIface = $upIfaces | Where-Object { $_.Name -match 'Wi-Fi|WiFi|Wireless|WLAN' } | Select-Object -First 1
            if (-not $wifiIface) { $wifiIface = $upIfaces[0] }
            return [PSCustomObject]@{ Preset = $p; Reason = "SSID match ($currentSSID)"; Interface = $wifiIface.Name }
        }
    }
    foreach ($p in $presets) {
        if ($p.gateway -and $p.gateway -ne "" -and $currentGateways -contains $p.gateway) {
            $matchedIface = $upIfaces | Where-Object { $_.Gateway -eq $p.gateway } | Select-Object -First 1
            if ($matchedIface) {
                return [PSCustomObject]@{ Preset = $p; Reason = "Gateway match ($($p.gateway))"; Interface = $matchedIface.Name }
            }
        }
    }
    return $null
}

function Show-GlobalDiagnostic {
    Write-Header
    Write-ColorLine "  Global Diagnostics" "Cyan"
    Write-Separator
    Write-Host ""

    $savedShowAll = $script:ShowAll
    $script:ShowAll = $true
    $interfaces = @(Invoke-WithSpinner "Loading interfaces" { Get-NetworkInterfaces })
    $script:ShowAll = $savedShowAll

    $diagResults = @()
    foreach ($iface in $interfaces) {
        $ifaceName = $iface.Name
        $ifaceGW   = $iface.Gateway
        $ifaceDNS  = $iface.DNS
        $ifaceIP   = $iface.IP
        $ifacePrefix = $iface.Prefix

        $r = Invoke-WithSpinner "Diagnosing $ifaceName" {
            $gwPing = $null; $gwLoss = $null; $dnsOk = $false; $dnsMs = $null

            if ($ifaceGW -ne "--" -and $ifaceGW) {
                $pings = @(Test-Connection -ComputerName $ifaceGW -Count 4 -ErrorAction SilentlyContinue)
                $recv  = $pings.Count
                $gwLoss = [math]::Round(100 * (4 - $recv) / 4)
                if ($recv -gt 0) {
                    $gwPing = [math]::Round(($pings | Measure-Object -Property ResponseTime -Average).Average)
                }
            }

            if ($ifaceDNS -and $ifaceDNS.Count -gt 0 -and $ifaceDNS[0] -ne "") {
                try {
                    $sw = [System.Diagnostics.Stopwatch]::StartNew()
                    $resolved = Resolve-DnsName "google.com" -Server $ifaceDNS[0] -Type A -ErrorAction SilentlyContinue
                    $sw.Stop()
                    $dnsOk = ($null -ne $resolved)
                    $dnsMs = $sw.ElapsedMilliseconds
                } catch { $dnsOk = $false }
            }

            [PSCustomObject]@{
                Name   = $ifaceName
                IP     = if ($ifaceIP -ne "--") { "$ifaceIP/$ifacePrefix" } else { "--" }
                GwPing = $gwPing
                GwLoss = $gwLoss
                DnsOk  = $dnsOk
                DnsMs  = $dnsMs
                HasGw  = ($ifaceGW -ne "--" -and $ifaceGW)
                HasDns = ($ifaceDNS -and $ifaceDNS.Count -gt 0 -and $ifaceDNS[0] -ne "")
            }
        }
        $diagResults += $r
    }

    Write-Header
    Write-ColorLine "  Global Diagnostics" "Cyan"
    Write-Separator
    Write-Host ""

    Write-Color ("  {0,-20}" -f "Interface") "DarkGray"
    Write-Color ("{0,-17}" -f "IP") "DarkGray"
    Write-Color ("{0,-9}" -f "GW Ping") "DarkGray"
    Write-Color ("{0,-7}" -f "Loss") "DarkGray"
    Write-ColorLine "DNS" "DarkGray"
    Write-ColorLine ("  " + "-" * 58) "DarkGray"

    foreach ($r in $diagResults) {
        Write-Color ("  {0,-20}" -f $r.Name) "White"
        Write-Color ("{0,-17}" -f $r.IP) "DarkGray"

        if ($r.HasGw) {
            if ($null -ne $r.GwPing) {
                $pingColor = if ($r.GwPing -le 20) { "Green" } elseif ($r.GwPing -le 80) { "Yellow" } else { "Red" }
                Write-Color ("{0,-9}" -f "$($r.GwPing)ms") $pingColor
            } else {
                Write-Color ("{0,-9}" -f "FAIL") "Red"
            }
            $lossColor = if ($r.GwLoss -eq 0) { "Green" } elseif ($r.GwLoss -lt 100) { "Yellow" } else { "Red" }
            Write-Color ("{0,-7}" -f "$($r.GwLoss)%") $lossColor
        } else {
            Write-Color ("{0,-9}" -f "--") "DarkGray"
            Write-Color ("{0,-7}" -f "--") "DarkGray"
        }

        if ($r.HasDns) {
            if ($r.DnsOk) {
                $dnsStr = if ($r.DnsMs) { "OK ($($r.DnsMs)ms)" } else { "OK" }
                Write-ColorLine $dnsStr "Green"
            } else {
                Write-ColorLine "FAIL" "Red"
            }
        } else {
            Write-ColorLine "--" "DarkGray"
        }
    }

    Write-Host ""
    Read-SingleKey "Press any key to return..." | Out-Null
}

# ─── Connectivity Tools ──────────────────────────────────────────────────────

function Invoke-PingTest($iface) {
    Write-Header
    Write-ColorLine "  Connectivity Test - $($iface.Name)" "Cyan"
    Write-Separator
    Write-Host ""

    $targets = [System.Collections.ArrayList]@()
    if ($iface.Gateway -and $iface.Gateway -ne "--") {
        [void]$targets.Add(@{ Label = "Gateway"; IP = $iface.Gateway })
    }
    if ($iface.DNS -and $iface.DNS.Count -gt 0 -and $iface.DNS[0] -ne "") {
        [void]$targets.Add(@{ Label = "DNS 1"; IP = $iface.DNS[0] })
    }
    if ($iface.DNS -and $iface.DNS.Count -gt 1 -and $iface.DNS[1] -ne "") {
        [void]$targets.Add(@{ Label = "DNS 2"; IP = $iface.DNS[1] })
    }

    $customIP = Read-InputWithDefault "Custom target IP (Enter to skip)" ""
    if ($customIP -and (Test-IPv4Address $customIP)) {
        [void]$targets.Add(@{ Label = "Custom"; IP = $customIP })
    }

    if ($targets.Count -eq 0) {
        Write-ColorLine "  No targets available (no gateway or DNS configured)." "Yellow"
        Write-Host ""
        Read-SingleKey "Press any key to return..." | Out-Null
        return
    }

    Write-Host ""
    $pingResults = @()
    foreach ($t in $targets) {
        $tIP    = $t.IP
        $tLabel = $t.Label
        $r = Invoke-WithSpinner "Testing $tLabel ($tIP)" {
            $pings = @(Test-Connection -ComputerName $tIP -Count 4 -ErrorAction SilentlyContinue)
            $recv  = $pings.Count
            $loss  = [math]::Round(100 * (4 - $recv) / 4)
            $avg   = if ($recv -gt 0) { [math]::Round(($pings | Measure-Object -Property ResponseTime -Average).Average) } else { $null }
            [PSCustomObject]@{ Label = $tLabel; IP = $tIP; Avg = $avg; Loss = $loss; Ok = ($recv -gt 0) }
        }
        $pingResults += $r
    }

    Write-Header
    Write-ColorLine "  Connectivity Test - $($iface.Name)" "Cyan"
    Write-Separator
    Write-Host ""

    foreach ($r in $pingResults) {
        Write-Color ("  {0,-10}" -f $r.Label) "DarkGray"
        Write-Color ("{0,-16}" -f $r.IP) "DarkGray"
        if ($r.Ok) {
            Write-Color "OK    " "Green"
            $latColor = if ($r.Avg -le 20) { "Green" } elseif ($r.Avg -le 80) { "Yellow" } else { "Red" }
            Write-Color "$($r.Avg)ms" $latColor
            $lossColor = if ($r.Loss -eq 0) { "Green" } elseif ($r.Loss -lt 50) { "Yellow" } else { "Red" }
            Write-ColorLine "   loss:$($r.Loss)%" $lossColor
        } else {
            Write-ColorLine "FAIL" "Red"
        }
    }

    Write-Host ""
    Read-SingleKey "Press any key to return..." | Out-Null
}

function Invoke-Traceroute($iface) {
    Write-Header
    Write-ColorLine "  Traceroute - $($iface.Name)" "Cyan"
    Write-Separator
    Write-Host ""

    $target = Read-InputWithDefault "Target host or IP" "8.8.8.8"
    Write-Host ""

    $raw = @(Invoke-WithSpinner "Running traceroute to $target (may take ~30s)" {
        tracert -d -w 1000 $target 2>&1
    })

    Write-Header
    Write-ColorLine "  Traceroute to $target" "Cyan"
    Write-Separator
    Write-Host ""

    Write-Color ("  {0,-4}" -f "Hop") "DarkGray"
    Write-Color (" {0,-17}" -f "Address") "DarkGray"
    Write-Color (" {0,-8}" -f "RTT1") "DarkGray"
    Write-Color (" {0,-8}" -f "RTT2") "DarkGray"
    Write-Color (" {0,-8}" -f "RTT3") "DarkGray"
    Write-ColorLine (" {0}" -f "Avg") "DarkGray"
    Write-ColorLine ("  " + "-" * 56) "DarkGray"

    $hopCount = 0
    foreach ($line in $raw) {
        $lineStr = [string]$line
        if ($lineStr -match '^\s*(\d+)\s+') {
            $hopNum = [int]$matches[1]
            $rtts   = @([regex]::Matches($lineStr, '(\d+) ms') | ForEach-Object { [int]$_.Groups[1].Value })

            if ($lineStr -match '(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s*$') {
                $addr = $matches[1]
            } elseif ($lineStr -match '\s(\S+)\s*$') {
                $addr = $matches[1]
                if ($addr -match '^\*+$') { $addr = "*" }
            } else { $addr = "*" }

            $avgMs    = if ($rtts.Count -gt 0) { [math]::Round(($rtts | Measure-Object -Average).Average) } else { $null }
            $avgColor = if ($null -eq $avgMs) { "DarkGray" } elseif ($avgMs -le 20) { "Green" } elseif ($avgMs -le 80) { "Yellow" } else { "Red" }
            $rtt1     = if ($rtts.Count -gt 0) { "$($rtts[0])ms" } else { "*" }
            $rtt2     = if ($rtts.Count -gt 1) { "$($rtts[1])ms" } else { "*" }
            $rtt3     = if ($rtts.Count -gt 2) { "$($rtts[2])ms" } else { "*" }
            $avgStr   = if ($null -ne $avgMs)  { "$($avgMs)ms" } else { "timeout" }

            Write-Color ("  {0,-4}" -f $hopNum) "DarkGray"
            Write-Color (" {0,-17}" -f $addr) "White"
            Write-Color (" {0,-8}" -f $rtt1) "DarkGray"
            Write-Color (" {0,-8}" -f $rtt2) "DarkGray"
            Write-Color (" {0,-8}" -f $rtt3) "DarkGray"
            Write-ColorLine (" {0}" -f $avgStr) $avgColor
            $hopCount++
        }
    }

    if ($hopCount -eq 0) {
        Write-ColorLine "  No hops captured. Host may be unreachable." "Yellow"
    }

    Write-Host ""
    Read-SingleKey "Press any key to return..." | Out-Null
}

function Invoke-PortScanner($iface) {
    Write-Header
    Write-ColorLine "  Port Scanner - $($iface.Name)" "Cyan"
    Write-Separator
    Write-Host ""

    $defaultTarget = if ($iface.Gateway -ne "--" -and $iface.Gateway) { $iface.Gateway } else { "" }
    $target = Read-InputWithDefault "Target IP" $defaultTarget
    if (-not (Test-IPv4Address $target)) {
        Write-ColorLine "  Invalid IP address." "Red"
        Start-Sleep -Milliseconds 800
        return
    }

    $portsInput = Read-InputWithDefault "Ports (e.g. 80,443,22,3389)" "80,443,22,3389"
    $ports = @($portsInput -split '[,\s]+' | ForEach-Object {
        $n = 0
        if ([int]::TryParse($_.Trim(), [ref]$n) -and $n -ge 1 -and $n -le 65535) { $n }
    } | Where-Object { $_ })

    if ($ports.Count -eq 0) {
        Write-ColorLine "  No valid ports specified." "Yellow"
        Start-Sleep -Milliseconds 800
        return
    }

    Write-Host ""
    $scanResults = @()
    foreach ($port in $ports) {
        $p = $port
        $r = Invoke-WithSpinner "Scanning $target : $p" {
            $tc = Test-NetConnection -ComputerName $target -Port $p -WarningAction SilentlyContinue -ErrorAction SilentlyContinue
            [PSCustomObject]@{ Port = $p; Open = [bool]$tc.TcpTestSucceeded }
        }
        $scanResults += $r
    }

    Write-Header
    Write-ColorLine "  Port Scanner - $target" "Cyan"
    Write-Separator
    Write-Host ""
    Write-Color ("  {0,-8}" -f "Port") "DarkGray"
    Write-ColorLine "Status" "DarkGray"
    Write-ColorLine ("  " + "-" * 16) "DarkGray"

    foreach ($r in $scanResults) {
        Write-Color ("  {0,-8}" -f $r.Port) "White"
        if ($r.Open) { Write-ColorLine "OPEN" "Green" } else { Write-ColorLine "CLOSED" "Red" }
    }

    Write-Host ""
    Read-SingleKey "Press any key to return..." | Out-Null
}

# ─── Interface Detail Menu ───────────────────────────────────────────────────

function Show-InterfaceMenu($iface) {
    while ($true) {
        Write-Header
        Write-ColorLine "  $($iface.Name) - Configuration" "Cyan"
        $ifaceIdx = $iface.Index
        $fresh = Invoke-WithSpinner "Refreshing data" { Get-NetworkInterfaces | Where-Object { $_.Index -eq $ifaceIdx } }
        if ($fresh) { $iface = $fresh }
        Write-Header
        Write-ColorLine "  $($iface.Name) - Configuration" "Cyan"
        Write-Separator
        Write-Host ""

        $statusColor = if ($iface.Status -eq 'Up') { "Green" } else { "Red" }
        $modeText    = if ($iface.DHCP) { "DHCP" } else { "Static" }
        $modeColor   = if ($iface.DHCP) { "Green" } else { "Yellow" }

        Write-StatusLine "Status" $iface.Status $statusColor
        if ($iface.Speed) { Write-StatusLine "Speed" $iface.Speed "White" }
        Write-StatusLine "MAC" $iface.Mac "DarkGray"
        Write-Host ""
        Write-StatusLine "Mode" $modeText $modeColor
        $ipDisplay = if ($iface.IP -ne "--") { "$($iface.IP)/$($iface.Prefix)" } else { "--" }
        Write-StatusLine "IP" $ipDisplay "White"
        Write-StatusLine "Mask" $iface.Mask "White"
        Write-StatusLine "Gateway" $iface.Gateway "White"
        $dnsText = if ($iface.DNS.Count -gt 0) { $iface.DNS -join ", " } else { "--" }
        Write-StatusLine "DNS" $dnsText "White"

        Write-Host ""
        Write-Separator
        Write-Host ""
        Write-ColorLine "  [1] Switch to DHCP" "White"
        Write-ColorLine "  [2] Set static IP" "White"
        Write-ColorLine "  [3] Save current config as preset" "White"
        Write-ColorLine "  [4] Load preset" "White"
        Write-ColorLine "  [5] Connectivity test" "White"
        Write-ColorLine "  [6] Config history / rollback" "White"
        Write-ColorLine "  [7] Traceroute" "White"
        Write-ColorLine "  [8] Port scanner" "White"
        Write-Host ""
        Write-ColorLine "  [B] Back    [Q] Quit" "DarkGray"

        $choice = Read-SingleKey ">"

        switch ($choice) {
            '1' { Set-InterfaceDHCP $iface.Name }
            '2' { Invoke-StaticIPPrompt $iface }
            '3' { Save-CurrentAsPreset $iface }
            '4' { Show-PresetMenu $iface.Name }
            '5' { Invoke-PingTest $iface }
            '6' { Show-HistoryMenu $iface }
            '7' { Invoke-Traceroute $iface }
            '8' { Invoke-PortScanner $iface }
            { $_ -match '[Bb]' } { return }
            { $_ -match '[Qq]' } { exit 0 }
        }
    }
}

# ─── Main Menu ───────────────────────────────────────────────────────────────

function Show-MainMenu {
    while ($true) {
        Write-Header

        # Auto-detect on first run only
        if (-not $script:AutoDetectShown) {
            $script:AutoDetectShown = $true
            $detected = Invoke-WithSpinner "Detecting network..." { Invoke-AutoDetect }
            if ($detected) {
                Write-Header
                Write-ColorLine "  [AUTO-DETECT] Network match found!" "Yellow"
                Write-ColorLine "  Reason  : $($detected.Reason)" "DarkGray"
                Write-ColorLine "  Preset  : $($detected.Preset.name)" "Cyan"
                Write-ColorLine "  Target  : $($detected.Interface)" "DarkGray"
                Write-Host ""
                $apply = Read-SingleKey "Apply this preset? [Y/n]"
                if ($apply -eq '' -or $apply -match '[Yy]') {
                    Apply-Preset $detected.Preset $detected.Interface
                    continue
                }
            }
        }

        $interfaces = @(Invoke-WithSpinner "Loading interfaces" { Get-NetworkInterfaces })

        if ($interfaces.Count -eq 0) {
            Write-Header
            Write-ColorLine "  No network interfaces found." "Red"
            Write-Host ""
            Write-ColorLine "  [A] Show all adapters    [Q] Quit" "White"
            $choice = Read-SingleKey ">"
            if ($choice -match '[Aa]') { $script:ShowAll = -not $script:ShowAll; continue }
            if ($choice -match '[Qq]') { exit 0 }
            continue
        }

        Write-Header
        $showAllText = if ($script:ShowAll) { "active only" } else { "all" }
        Write-ColorLine "  Interfaces:" "Cyan"
        Write-Separator
        Write-Host ""

        for ($i = 0; $i -lt $interfaces.Count; $i++) {
            $iface      = $interfaces[$i]
            $statusIcon = if ($iface.Status -eq 'Up') { "UP" } else { "DN" }
            $statusColor= if ($iface.Status -eq 'Up') { "Green" } else { "Red" }
            $modeText   = if ($iface.DHCP) { "DHCP" } else { "Static" }
            $ipText     = if ($iface.IP -ne "--") { "$($iface.IP)/$($iface.Prefix)" } else { "--" }

            Write-Color "  [$($i+1)] " "Cyan"
            Write-Color ("{0,-20}" -f $iface.Name) "White"
            Write-Color ("{0,-20}" -f $ipText) "DarkGray"
            Write-Color ("{0,-8}" -f $modeText) "DarkGray"
            Write-ColorLine $statusIcon $statusColor
        }

        Write-Host ""
        Write-Separator
        Write-Host ""
        Write-Color "  [P] " "Cyan"; Write-Color "Presets    " "White"
        Write-Color "[F] " "Cyan"; Write-Color "Profiles    " "White"
        Write-Color "[D] " "Cyan"; Write-ColorLine "Diagnostics" "White"
        Write-Color "  [A] " "Cyan"; Write-Color "Show $showAllText    " "White"
        Write-Color "[R] " "Cyan"; Write-Color "Refresh    " "White"
        Write-Color "[Q] " "Cyan"; Write-ColorLine "Quit" "White"

        $choice = Read-SingleKey "Select interface [1-$($interfaces.Count)] or action >"

        if ($choice -match '[Qq]') { exit 0 }
        if ($choice -match '[Aa]') { $script:ShowAll = -not $script:ShowAll; continue }
        if ($choice -match '[Rr]') { continue }
        if ($choice -match '[Pp]') { Show-PresetMenu $null; continue }
        if ($choice -match '[Ff]') { Show-ProfileMenu; continue }
        if ($choice -match '[Dd]') { Show-GlobalDiagnostic; continue }

        $idx = 0
        if ([int]::TryParse($choice, [ref]$idx) -and $idx -ge 1 -and $idx -le $interfaces.Count) {
            Show-InterfaceMenu $interfaces[$idx - 1]
        }
    }
}

# ─── CLI Quick Mode ──────────────────────────────────────────────────────────

function Show-Help {
    Write-Host ""
    Write-ColorLine "  InterfaceX v$($script:Version) - Network Interface Configuration Tool" "Cyan"
    Write-Host ""
    Write-ColorLine "  Usage:" "Yellow"
    Write-Host "    interfacex                                    Launch interactive TUI"
    Write-Host "    interfacex status                             Compact interface table"
    Write-Host "    interfacex list                               List interfaces (verbose)"
    Write-Host "    interfacex dhcp <interface>                   Switch to DHCP"
    Write-Host "    interfacex static <iface> <ip> <mask> <gw> [dns1] [dns2]"
    Write-Host "                                                  Set static IP"
    Write-Host "    interfacex preset <name> <interface>          Apply a preset"
    Write-Host "    interfacex presets                            List saved presets"
    Write-Host "    interfacex --help                             Show this help"
    Write-Host ""
    Write-ColorLine "  Examples:" "Yellow"
    Write-Host '    interfacex status'
    Write-Host '    interfacex dhcp "Wi-Fi"'
    Write-Host '    interfacex static "Ethernet" 10.0.1.50 255.255.255.0 10.0.1.1 8.8.8.8'
    Write-Host '    interfacex preset "Office" "Wi-Fi"'
    Write-Host ""
}

function Show-StatusOneliner {
    $script:ShowAll = $true
    $interfaces = @(Get-NetworkInterfaces)
    Write-Host ""
    Write-Color ("  {0,-22}" -f "Interface") "DarkGray"
    Write-Color ("{0,-17}" -f "IP") "DarkGray"
    Write-Color ("{0,-8}" -f "Mode") "DarkGray"
    Write-Color ("{0,-7}" -f "Status") "DarkGray"
    Write-ColorLine "Gateway" "DarkGray"
    Write-ColorLine ("  " + "-" * 64) "DarkGray"
    foreach ($iface in $interfaces) {
        $ipText      = if ($iface.IP -ne "--") { "$($iface.IP)/$($iface.Prefix)" } else { "--" }
        $modeText    = if ($iface.DHCP) { "DHCP" } else { "Static" }
        $statusColor = if ($iface.Status -eq 'Up') { "Green" } else { "Red" }
        Write-Color ("  {0,-22}" -f $iface.Name) "White"
        Write-Color ("{0,-17}" -f $ipText) "DarkGray"
        Write-Color ("{0,-8}" -f $modeText) "DarkGray"
        Write-Color ("{0,-7}" -f $iface.Status) $statusColor
        Write-ColorLine $iface.Gateway "DarkGray"
    }
    Write-Host ""
    exit 0
}

function Invoke-CLIMode($arguments) {
    switch ($arguments[0].ToLower()) {
        "--help" { Show-Help; exit 0 }
        "-h"     { Show-Help; exit 0 }
        "status" {
            Show-StatusOneliner
        }
        "list" {
            $script:ShowAll = $true
            $interfaces = @(Get-NetworkInterfaces)
            Write-Host ""
            Write-ColorLine "  Network Interfaces:" "Cyan"
            Write-Host ""
            foreach ($iface in $interfaces) {
                $statusColor = if ($iface.Status -eq 'Up') { "Green" } else { "Red" }
                $ipText      = if ($iface.IP -ne "--") { "$($iface.IP)/$($iface.Prefix)" } else { "--" }
                $modeText    = if ($iface.DHCP) { "DHCP" } else { "Static" }
                Write-Color ("  {0,-22}" -f $iface.Name) "White"
                Write-Color ("{0,-20}" -f $ipText) "DarkGray"
                Write-Color ("{0,-8}" -f $modeText) "DarkGray"
                Write-ColorLine $iface.Status $statusColor
            }
            Write-Host ""
            exit 0
        }
        "dhcp" {
            if ($arguments.Count -lt 2) {
                Write-ColorLine "  Usage: interfacex dhcp <interface_name>" "Red"; exit 1
            }
            Set-InterfaceDHCP $arguments[1]; exit 0
        }
        "static" {
            if ($arguments.Count -lt 5) {
                Write-ColorLine "  Usage: interfacex static <interface> <ip> <mask> <gateway> [dns1] [dns2]" "Red"; exit 1
            }
            $ifName = $arguments[1]
            $ip     = $arguments[2]
            $mask   = Resolve-Mask $arguments[3]
            $gw     = $arguments[4]
            $dns1   = if ($arguments.Count -gt 5) { $arguments[5] } else { "8.8.8.8" }
            $dns2   = if ($arguments.Count -gt 6) { $arguments[6] } else { "" }

            if (-not (Test-IPv4Address $ip))  { Write-ColorLine "  Invalid IP: $ip" "Red"; exit 1 }
            if (-not $mask)                   { Write-ColorLine "  Invalid mask: $($arguments[3])" "Red"; exit 1 }
            if (-not (Test-IPv4Address $gw))  { Write-ColorLine "  Invalid gateway: $gw" "Red"; exit 1 }

            Set-InterfaceStatic $ifName $ip $mask $gw $dns1 $dns2; exit 0
        }
        "preset" {
            if ($arguments.Count -lt 3) {
                Write-ColorLine "  Usage: interfacex preset <preset_name> <interface_name>" "Red"; exit 1
            }
            $presets = @(Get-Presets)
            $found = $presets | Where-Object { $_.name -eq $arguments[1] }
            if (-not $found) {
                Write-ColorLine "  Preset '$($arguments[1])' not found." "Red"; exit 1
            }
            Apply-Preset $found $arguments[2]; exit 0
        }
        "presets" {
            $presets = @(Get-Presets)
            Write-Host ""
            Write-ColorLine "  Saved Presets:" "Cyan"
            Write-Host ""
            if ($presets.Count -eq 0) {
                Write-ColorLine "  No presets saved." "DarkGray"
            } else {
                foreach ($p in $presets) {
                    $mode = if ($p.dhcp) { "DHCP" } else { "$($p.ip)/$($p.mask)" }
                    Write-Color ("  {0,-20}" -f $p.name) "Yellow"
                    Write-ColorLine $mode "DarkGray"
                }
            }
            Write-Host ""
            exit 0
        }
        default {
            Write-ColorLine "  Unknown command: $($arguments[0])" "Red"
            Write-Host "  Use 'interfacex --help' for usage information."
            exit 1
        }
    }
}

# ─── Entry Point ─────────────────────────────────────────────────────────────

if ($args.Count -gt 0) {
    Invoke-CLIMode $args
} else {
    Show-MainMenu
}
