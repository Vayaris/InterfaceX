# =============================================================================
#  InterfaceX v1.0.0 - Network Interface Configuration Tool
#  Fast, beautiful CMD-based network config with presets
# =============================================================================

$script:Version = "1.0.0"
$script:PresetFile = Join-Path $PSScriptRoot "presets.json"
$script:ShowAll = $false

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
    $tLine  = "|" + (" " * $tPad) + $title + (" " * ($w - 2 - $tPad - $title.Length)) + "|"
    $sLine  = "|" + (" " * $sPad) + $sub + (" " * ($w - 2 - $sPad - $sub.Length)) + "|"

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
    $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
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
        $ipInfo = Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                  Where-Object { $_.IPAddress -ne '127.0.0.1' } | Select-Object -First 1
        $gwInfo = Get-NetRoute -InterfaceIndex $a.ifIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
                  Select-Object -First 1
        $dnsInfo = Get-DnsClientServerAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $dhcpInfo = Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue

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

    # IP Address
    do {
        $defaultIP = if ($iface.IP -ne "--") { $iface.IP } else { "" }
        $ip = Read-InputWithDefault "IP Address" $defaultIP
        if (-not (Test-IPv4Address $ip)) {
            Write-ColorLine "  Invalid IP address. Try again." "Red"
        }
    } while (-not (Test-IPv4Address $ip))

    # Subnet Mask
    do {
        $defaultMask = if ($iface.Mask -ne "--") { $iface.Mask } else { "255.255.255.0" }
        $maskInput = Read-InputWithDefault "Subnet Mask (or /prefix)" $defaultMask
        $mask = Resolve-Mask $maskInput
        if (-not $mask) {
            Write-ColorLine "  Invalid subnet mask. Use 255.255.255.0 or /24 format." "Red"
        }
    } while (-not $mask)

    # Gateway
    do {
        $defaultGW = if ($iface.Gateway -ne "--") { $iface.Gateway } else { "" }
        $gw = Read-InputWithDefault "Gateway" $defaultGW
        if ($gw -and -not (Test-IPv4Address $gw)) {
            Write-ColorLine "  Invalid gateway address. Try again." "Red"
            $gw = $null
        }
    } while (-not $gw)

    # DNS
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

    # Confirmation
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
        $backup = "$($script:PresetFile).bak"
        Copy-Item $script:PresetFile $backup -Force -ErrorAction SilentlyContinue
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
    }

    $presets += $preset
    Save-Presets $presets
    Write-ColorLine "  [OK] Preset '$name' saved!" "Green"
    Start-Sleep -Milliseconds 800
}

function Show-PresetMenu($interfaceName) {
    while ($true) {
        Write-Header
        Write-ColorLine "  Presets" "Cyan"
        if ($interfaceName) {
            Write-ColorLine "  Target: $interfaceName" "DarkGray"
        }
        Write-Separator
        Write-Host ""

        $presets = @(Get-Presets)
        if ($presets.Count -eq 0) {
            Write-ColorLine "  No presets saved yet." "DarkGray"
            Write-Host ""
            Write-ColorLine "  [B] Back" "White"
            $choice = Read-SingleKey ">"
            return
        }

        for ($i = 0; $i -lt $presets.Count; $i++) {
            $p = $presets[$i]
            $num = $i + 1
            $mode = if ($p.dhcp) { "DHCP" } else { "$($p.ip)/$($p.mask)" }
            Write-Color "  [$num] " "Cyan"
            Write-Color ("{0,-18}" -f $p.name) "White"
            Write-ColorLine $mode "DarkGray"
        }

        Write-Host ""
        Write-ColorLine "  [D] Delete a preset    [B] Back" "White"
        $choice = Read-SingleKey ">"

        if ($choice -match '[Bb]') { return }
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

# ─── Interface Detail Menu ───────────────────────────────────────────────────

function Show-InterfaceMenu($iface) {
    while ($true) {
        Write-Header
        Write-ColorLine "  $($iface.Name) - Configuration" "Cyan"
        # Refresh interface data
        $ifaceIdx = $iface.Index
        $fresh = Invoke-WithSpinner "Refreshing data" { Get-NetworkInterfaces | Where-Object { $_.Index -eq $ifaceIdx } }
        if ($fresh) { $iface = $fresh }
        Write-Header
        Write-ColorLine "  $($iface.Name) - Configuration" "Cyan"
        Write-Separator
        Write-Host ""

        $statusColor = if ($iface.Status -eq 'Up') { "Green" } else { "Red" }
        $modeText = if ($iface.DHCP) { "DHCP" } else { "Static" }
        $modeColor = if ($iface.DHCP) { "Green" } else { "Yellow" }

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
        Write-Host ""
        Write-ColorLine "  [B] Back    [Q] Quit" "DarkGray"

        $choice = Read-SingleKey ">"

        switch ($choice) {
            '1' { Set-InterfaceDHCP $iface.Name }
            '2' { Invoke-StaticIPPrompt $iface }
            '3' { Save-CurrentAsPreset $iface }
            '4' { Show-PresetMenu $iface.Name }
            { $_ -match '[Bb]' } { return }
            { $_ -match '[Qq]' } { exit 0 }
        }
    }
}

# ─── Main Menu ───────────────────────────────────────────────────────────────

function Show-MainMenu {
    while ($true) {
        Write-Header
        $interfaces = @(Invoke-WithSpinner "Loading interfaces" { Get-NetworkInterfaces })

        if ($interfaces.Count -eq 0) {
            Write-ColorLine "  No network interfaces found." "Red"
            Write-Host ""
            Write-ColorLine "  [A] Show all adapters    [Q] Quit" "White"
            $choice = Read-SingleKey ">"
            if ($choice -match '[Aa]') { $script:ShowAll = -not $script:ShowAll; continue }
            if ($choice -match '[Qq]') { exit 0 }
            continue
        }

        $showAllText = if ($script:ShowAll) { "active only" } else { "all" }
        Write-ColorLine "  Interfaces:" "Cyan"
        Write-Separator
        Write-Host ""

        for ($i = 0; $i -lt $interfaces.Count; $i++) {
            $iface = $interfaces[$i]
            $num = $i + 1
            $statusIcon = if ($iface.Status -eq 'Up') { "UP" } else { "DN" }
            $statusColor = if ($iface.Status -eq 'Up') { "Green" } else { "Red" }
            $modeText = if ($iface.DHCP) { "DHCP" } else { "Static" }
            $ipText = if ($iface.IP -ne "--") { "$($iface.IP)/$($iface.Prefix)" } else { "--" }

            Write-Color "  [$num] " "Cyan"
            Write-Color ("{0,-20}" -f $iface.Name) "White"
            Write-Color ("{0,-20}" -f $ipText) "DarkGray"
            Write-Color ("{0,-8}" -f $modeText) "DarkGray"
            Write-ColorLine $statusIcon $statusColor
        }

        Write-Host ""
        Write-Separator
        Write-Host ""
        Write-Color "  [P] " "Cyan"; Write-Color "Presets    " "White"
        Write-Color "[A] " "Cyan"; Write-Color "Show $showAllText    " "White"
        Write-Color "[R] " "Cyan"; Write-Color "Refresh    " "White"
        Write-Color "[Q] " "Cyan"; Write-ColorLine "Quit" "White"

        $choice = Read-SingleKey "Select interface [1-$($interfaces.Count)] or action >"

        if ($choice -match '[Qq]') { exit 0 }
        if ($choice -match '[Aa]') { $script:ShowAll = -not $script:ShowAll; continue }
        if ($choice -match '[Rr]') { continue }
        if ($choice -match '[Pp]') { Show-PresetMenu $null; continue }

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
    Write-Host "    interfacex list                               List interfaces"
    Write-Host "    interfacex dhcp <interface>                   Switch to DHCP"
    Write-Host "    interfacex static <iface> <ip> <mask> <gw> [dns1] [dns2]"
    Write-Host "                                                  Set static IP"
    Write-Host "    interfacex preset <name> <interface>          Apply a preset"
    Write-Host "    interfacex presets                            List saved presets"
    Write-Host "    interfacex --help                             Show this help"
    Write-Host ""
    Write-ColorLine "  Examples:" "Yellow"
    Write-Host '    interfacex dhcp "Wi-Fi"'
    Write-Host '    interfacex static "Ethernet" 10.0.1.50 255.255.255.0 10.0.1.1 8.8.8.8'
    Write-Host '    interfacex preset "Office" "Wi-Fi"'
    Write-Host ""
}

function Invoke-CLIMode($arguments) {
    switch ($arguments[0].ToLower()) {
        "--help" {
            Show-Help
            exit 0
        }
        "-h" {
            Show-Help
            exit 0
        }
        "list" {
            $script:ShowAll = $true
            $interfaces = @(Get-NetworkInterfaces)
            Write-Host ""
            Write-ColorLine "  Network Interfaces:" "Cyan"
            Write-Host ""
            foreach ($iface in $interfaces) {
                $statusColor = if ($iface.Status -eq 'Up') { "Green" } else { "Red" }
                $ipText = if ($iface.IP -ne "--") { "$($iface.IP)/$($iface.Prefix)" } else { "--" }
                $modeText = if ($iface.DHCP) { "DHCP" } else { "Static" }
                Write-Color "  " "White"
                Write-Color ("{0,-22}" -f $iface.Name) "White"
                Write-Color ("{0,-20}" -f $ipText) "DarkGray"
                Write-Color ("{0,-8}" -f $modeText) "DarkGray"
                Write-ColorLine $iface.Status $statusColor
            }
            Write-Host ""
            exit 0
        }
        "dhcp" {
            if ($arguments.Count -lt 2) {
                Write-ColorLine "  Usage: interfacex dhcp <interface_name>" "Red"
                exit 1
            }
            Set-InterfaceDHCP $arguments[1]
            exit 0
        }
        "static" {
            if ($arguments.Count -lt 5) {
                Write-ColorLine "  Usage: interfacex static <interface> <ip> <mask> <gateway> [dns1] [dns2]" "Red"
                exit 1
            }
            $ifName = $arguments[1]
            $ip     = $arguments[2]
            $mask   = Resolve-Mask $arguments[3]
            $gw     = $arguments[4]
            $dns1   = if ($arguments.Count -gt 5) { $arguments[5] } else { "8.8.8.8" }
            $dns2   = if ($arguments.Count -gt 6) { $arguments[6] } else { "" }

            if (-not (Test-IPv4Address $ip)) { Write-ColorLine "  Invalid IP: $ip" "Red"; exit 1 }
            if (-not $mask) { Write-ColorLine "  Invalid mask: $($arguments[3])" "Red"; exit 1 }
            if (-not (Test-IPv4Address $gw)) { Write-ColorLine "  Invalid gateway: $gw" "Red"; exit 1 }

            Set-InterfaceStatic $ifName $ip $mask $gw $dns1 $dns2
            exit 0
        }
        "preset" {
            if ($arguments.Count -lt 3) {
                Write-ColorLine "  Usage: interfacex preset <preset_name> <interface_name>" "Red"
                exit 1
            }
            $presets = @(Get-Presets)
            $found = $presets | Where-Object { $_.name -eq $arguments[1] }
            if (-not $found) {
                Write-ColorLine "  Preset '$($arguments[1])' not found." "Red"
                exit 1
            }
            Apply-Preset $found $arguments[2]
            exit 0
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
                    Write-Color "  " "White"
                    Write-Color ("{0,-20}" -f $p.name) "Yellow"
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
