<#
.SYNOPSIS
    Manifest-driven menu launcher for a set of PowerShell scripts or a module.

.DESCRIPTION
    One engine, one manifest per script set. Nothing in this file knows about any
    particular toolkit - the manifest supplies the banner, the root path, the
    curated shortcuts and the discovery mode.

    Two discovery modes:
      Files  - enumerate .ps1 files under Root, group by subfolder
      Module - import a module and enumerate its exported functions

    Parameters are discovered rather than typed free-hand. Script files are read
    with the PowerShell AST (no execution, no regex); module functions are read
    from their command metadata. Mandatory parameters are prompted for, ValidateSet
    parameters become pickers, switches become yes/no.

    Dry-run handling is per-command. The engine finds whichever switch that command
    actually exposes - WhatIfMode, WhatIf, Preview, DryRun - instead of assuming.
    A [bool] dry-run parameter that defaults to $true is passed explicitly as $false
    for a live run, which is the case that silently does nothing if you get it wrong.

.PARAMETER ManifestPath
    Path to a menu manifest (.psd1). Defaults to menu.psd1 beside this script, then
    menu.psd1 in the current directory.

.PARAMETER NoLog
    Suppress invocation logging for this session.

.EXAMPLE
    .\Start-ScriptMenu.ps1 -ManifestPath \\fileserver\tools\O365-Management\menu.psd1
#>
[CmdletBinding()]
param(
    [string]$ManifestPath,
    [switch]$NoLog
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================================
# Manifest
# ============================================================================

function Get-MenuManifest {
    [CmdletBinding()]
    param([string]$Path)

    if (-not $Path) {
        $candidates = @(
            (Join-Path $PSScriptRoot 'menu.psd1'),
            (Join-Path (Get-Location).Path 'menu.psd1')
        )
        $Path = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    }

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        throw 'No manifest found. Pass -ManifestPath, or place menu.psd1 beside this script.'
    }

    $manifest = Import-PowerShellDataFile -LiteralPath $Path

    foreach ($required in @('Title', 'Discovery')) {
        if (-not $manifest.ContainsKey($required)) {
            throw ("Manifest '{0}' is missing the required key '{1}'." -f $Path, $required)
        }
    }

    # Defaults for everything optional, so the rest of the engine never tests keys.
    $defaults = @{
        Root                 = (Split-Path -Parent (Resolve-Path -LiteralPath $Path))
        Reports              = $null
        LogPath              = $null
        Sections             = @()
        DryRunNames          = @('WhatIfMode', 'WhatIf', 'Preview', 'DryRun')
        RedactParameters     = @('Password', 'Secret', 'Credential', 'Token', 'ClientSecret')
        Notice               = $null
        Tenants              = $null    # path to a tenant list (.psd1)
        TenantParameter      = $null    # parameter that receives the tenant identity
        TenantCloudParameter = $null    # parameter that receives the tenant's cloud
        RequireTenant        = $false   # force a selection before the menu opens
        OnTenantSwitch       = $null    # command run when switching away from a tenant
        TenantCache          = 'tenants.cache.json'  # remembered ad-hoc tenants
        SessionProbe         = $null    # command that throws when not connected
        SessionConnectKey    = $null    # shortcut key used to connect
    }
    foreach ($key in $defaults.Keys) {
        if (-not $manifest.ContainsKey($key) -or $null -eq $manifest[$key]) {
            $manifest[$key] = $defaults[$key]
        }
    }

    $manifest['ManifestPath'] = (Resolve-Path -LiteralPath $Path).Path

    # Root may be written relative to the manifest.
    if (-not [System.IO.Path]::IsPathRooted($manifest.Root)) {
        $manifest['Root'] = Join-Path (Split-Path -Parent $manifest.ManifestPath) $manifest.Root
    }

    if (-not $manifest.LogPath) {
        $manifest['LogPath'] = Join-Path $manifest.Root 'Logs\launcher.jsonl'
    }

    return $manifest
}

# ============================================================================
# Parameter discovery
# ============================================================================

function New-MenuParameter {
    [CmdletBinding()]
    param(
        [string]$Name,
        [string]$TypeName = 'System.Object',
        [bool]$IsSwitch = $false,
        [bool]$IsBool = $false,
        [bool]$IsMandatory = $false,
        [string[]]$ValidateSet = @(),
        [string]$Help = ''
    )

    return [pscustomobject]@{
        Name        = $Name
        TypeName    = $TypeName
        IsSwitch    = $IsSwitch
        IsBool      = $IsBool
        IsMandatory = $IsMandatory
        ValidateSet = $ValidateSet
        Help        = $Help
    }
}

function Add-MenuParameterHelp {
    <#
        Attaches each parameter's comment-based help to its metadata, so the
        picker can say what a parameter is for instead of only its type.

        Get-Help works against a script path as well as a function name, so one
        pass covers both discovery modes. Missing help is normal and silent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][object[]]$Parameters
    )

    if ($Parameters.Count -eq 0) { return }

    $help = $null
    try { $help = Get-Help -Name $Source -ErrorAction Stop }
    catch { return }

    if (-not $help -or -not (Test-GovGuardHelpProperty -InputObject $help -Name 'parameters')) { return }
    if (-not $help.parameters) { return }
    if (-not (Test-GovGuardHelpProperty -InputObject $help.parameters -Name 'parameter')) { return }

    foreach ($entry in @($help.parameters.parameter)) {
        if (-not $entry) { continue }

        $match = @($Parameters | Where-Object { $_.Name -eq $entry.name })
        if ($match.Count -eq 0) { continue }

        $text = ''
        if ($entry.PSObject.Properties.Name -contains 'description' -and $entry.description) {
            $text = (@($entry.description | ForEach-Object { $_.Text }) -join ' ')
        }

        if ($text) {
            # First sentence only; the full text is available through H.
            $text = ($text -replace '\s+', ' ').Trim()
            $firstStop = $text.IndexOf('. ')
            if ($firstStop -gt 20) { $text = $text.Substring(0, $firstStop + 1) }
            $match[0].Help = $text
        }
    }
}

function Test-GovGuardHelpProperty {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $InputObject) { return $false }
    return (@($InputObject.PSObject.Properties.Name) -contains $Name)
}

function Get-ScriptFileParameter {
    <#
        Reads a script file's param block from the AST. Never executes the file.
        Returns @{ Parameters = @(); SupportsShouldProcess = $bool }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $result = @{ Parameters = @(); SupportsShouldProcess = $false }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)

    if ($errors -and $errors.Count -gt 0) {
        Write-Warning ("{0} has {1} parse error(s); parameter prompts unavailable." -f (Split-Path -Leaf $Path), $errors.Count)
        return $result
    }

    if ($null -eq $ast.ParamBlock) { return $result }

    # [CmdletBinding(SupportsShouldProcess)] means -WhatIf exists without being declared.
    foreach ($attr in @($ast.ParamBlock.Attributes)) {
        if ($attr.TypeName.Name -ne 'CmdletBinding') { continue }
        foreach ($named in @($attr.NamedArguments)) {
            if ($named.ArgumentName -ne 'SupportsShouldProcess') { continue }
            if ($named.ExpressionOmitted) { $result.SupportsShouldProcess = $true; continue }
            if ($named.Argument.Extent.Text -match '\$true') { $result.SupportsShouldProcess = $true }
        }
    }

    $parameters = @()
    foreach ($p in @($ast.ParamBlock.Parameters)) {
        $name = $p.Name.VariablePath.UserPath
        $typeName = 'System.Object'
        if ($null -ne $p.StaticType) { $typeName = $p.StaticType.FullName }

        $isSwitch = ($typeName -eq 'System.Management.Automation.SwitchParameter')
        $isBool = ($typeName -eq 'System.Boolean')
        $isMandatory = $false
        $validateSet = @()

        foreach ($attr in @($p.Attributes)) {
            if ($attr -isnot [System.Management.Automation.Language.AttributeAst]) { continue }

            switch ($attr.TypeName.Name) {
                'Parameter' {
                    foreach ($named in @($attr.NamedArguments)) {
                        if ($named.ArgumentName -ne 'Mandatory') { continue }
                        if ($named.ExpressionOmitted -or $named.Argument.Extent.Text -match '\$true') {
                            $isMandatory = $true
                        }
                    }
                }
                'ValidateSet' {
                    foreach ($pos in @($attr.PositionalArguments)) {
                        if ($pos -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                            $validateSet += $pos.Value
                        }
                    }
                }
            }
        }

        $parameters += New-MenuParameter -Name $name -TypeName $typeName `
            -IsSwitch $isSwitch -IsBool $isBool -IsMandatory $isMandatory -ValidateSet $validateSet
    }

    $result.Parameters = $parameters
    return $result
}

function Get-FunctionParameter {
    <#
        Reads an imported function's parameters from command metadata.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $result = @{ Parameters = @(); SupportsShouldProcess = $false }

    $command = Get-Command -Name $Name -ErrorAction Stop

    $defaultSet = '__AllParameterSets'
    if ($command.PSObject.Properties.Name -contains 'DefaultParameterSet' -and $command.DefaultParameterSet) {
        $defaultSet = $command.DefaultParameterSet
    }

    $common = @([System.Management.Automation.PSCmdlet]::CommonParameters) +
              @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)

    if ($command.Parameters.ContainsKey('WhatIf')) { $result.SupportsShouldProcess = $true }

    $parameters = @()
    foreach ($entry in $command.Parameters.GetEnumerator()) {
        if ($common -contains $entry.Key) { continue }

        $meta = $entry.Value
        $typeName = $meta.ParameterType.FullName

        $isMandatory = $false
        $validateSet = @()

        foreach ($attr in @($meta.Attributes)) {
            if ($attr -is [System.Management.Automation.ParameterAttribute]) {
                # Mandatory only counts in the set we will actually invoke. Without
                # this, a command with an app-only parameter set demands a client id
                # even when the user picked interactive.
                $setName = $attr.ParameterSetName
                $inDefaultSet = ($setName -eq '__AllParameterSets' -or $setName -eq $defaultSet)
                if ($attr.Mandatory -and $inDefaultSet) { $isMandatory = $true }
            }
            if ($attr -is [System.Management.Automation.ValidateSetAttribute]) {
                $validateSet = @($attr.ValidValues)
            }
        }

        $parameters += New-MenuParameter -Name $entry.Key -TypeName $typeName `
            -IsSwitch ($meta.ParameterType -eq [System.Management.Automation.SwitchParameter]) `
            -IsBool ($meta.ParameterType -eq [bool]) `
            -IsMandatory $isMandatory -ValidateSet $validateSet
    }

    $result.Parameters = $parameters
    return $result
}

# ============================================================================
# Discovery
# ============================================================================

function Get-MenuCommandList {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Manifest)

    $discovery = $Manifest.Discovery
    $mode = $discovery.Mode

    switch ($mode) {
        'Files'  { return Get-MenuCommandFromFiles  -Manifest $Manifest }
        'Module' { return Get-MenuCommandFromModule -Manifest $Manifest }
        default  { throw ("Unknown Discovery.Mode '{0}'. Use 'Files' or 'Module'." -f $mode) }
    }
}

function Get-MenuCommandFromFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Manifest)

    $discovery = $Manifest.Discovery
    $root = $Manifest.Root

    if (-not (Test-Path -LiteralPath $root)) {
        throw ("Root path not found: {0}" -f $root)
    }

    $recurse = $false
    if ($discovery.ContainsKey('Recurse')) { $recurse = [bool]$discovery.Recurse }

    $exclude = @()
    if ($discovery.ContainsKey('Exclude')) { $exclude = @($discovery.Exclude) }

    $gciParams = @{ LiteralPath = $root; Filter = '*.ps1'; File = $true }
    if ($recurse) { $gciParams['Recurse'] = $true }

    $files = Get-ChildItem @gciParams | Sort-Object FullName

    $commands = @()
    foreach ($file in $files) {
        $skip = $false
        foreach ($pattern in $exclude) {
            if ($file.Name -like $pattern) { $skip = $true; break }
        }
        if ($skip) { continue }

        $relativeDir = ''
        if ($recurse) {
            $parent = Split-Path -Parent $file.FullName
            if ($parent -ne $root) {
                $relativeDir = $parent.Substring($root.Length).TrimStart('\', '/')
            }
        }

        $group = if ($relativeDir) { $relativeDir } else { 'Root' }

        $commands += [pscustomobject]@{
            Name        = $file.BaseName
            DisplayName = $file.BaseName
            Kind        = 'File'
            Source      = $file.FullName
            Group       = $group
            Metadata    = $null   # loaded lazily; parsing every file at startup is slow
        }
    }

    return $commands
}

function Get-MenuCommandFromModule {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Manifest)

    $discovery = $Manifest.Discovery

    if (-not $discovery.ContainsKey('ModulePath')) {
        throw "Discovery.Mode is 'Module' but Discovery.ModulePath is not set."
    }

    $modulePath = $discovery.ModulePath
    if (-not [System.IO.Path]::IsPathRooted($modulePath)) {
        $modulePath = Join-Path $Manifest.Root $modulePath
    }

    if (-not (Test-Path -LiteralPath $modulePath)) {
        throw ("Module not found: {0}" -f $modulePath)
    }

    # -PassThru returns the module directly. Matching by Path fails here because
    # importing a .psd1 yields a module whose Path is the .psm1.
    $module = Import-Module -Name $modulePath -Force -PassThru -ErrorAction Stop

    $exportedCount = 0
    if ($module -and $module.ExportedFunctions) { $exportedCount = $module.ExportedFunctions.Count }

    if ($exportedCount -eq 0) {
        throw (@(
            ("Module '{0}' imported from {1} but exports no functions." -f $module.Name, $modulePath)
            'A module that dot-sources Private\, Public\ and Rules\ subfolders needs those folders present beside the .psd1.'
            'Flattening every file into one directory imports cleanly and exports nothing, which looks exactly like this.'
            'Check with: Import-Module <path> -Force -PassThru -Verbose'
        ) -join ' ')
    }

    $exclude = @()
    if ($discovery.ContainsKey('Exclude')) { $exclude = @($discovery.Exclude) }

    $commands = @()
    foreach ($functionName in ($module.ExportedFunctions.Keys | Sort-Object)) {
        $skip = $false
        foreach ($pattern in $exclude) {
            if ($functionName -like $pattern) { $skip = $true; break }
        }
        if ($skip) { continue }

        $commands += [pscustomobject]@{
            Name        = $functionName
            DisplayName = $functionName
            Kind        = 'Function'
            Source      = $functionName
            Group       = $module.Name
            Metadata    = $null
        }
    }

    return $commands
}

function Resolve-MenuCommandMetadata {
    <#
        Lazily loads parameter metadata for one command and caches it on the object.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Command)

    if ($null -ne $Command.Metadata) { return $Command.Metadata }

    $metadata = switch ($Command.Kind) {
        'File'     { Get-ScriptFileParameter -Path $Command.Source }
        'Function' { Get-FunctionParameter -Name $Command.Source }
        default    { @{ Parameters = @(); SupportsShouldProcess = $false } }
    }

    if ($metadata.Parameters.Count -gt 0) {
        Add-MenuParameterHelp -Source $Command.Source -Parameters $metadata.Parameters
    }

    $Command.Metadata = $metadata
    return $metadata
}

function Get-DryRunParameter {
    <#
        Returns the parameter object this command uses for a dry run, or $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Command,
        [Parameter(Mandatory)][hashtable]$Manifest,
        [string]$Override
    )

    $metadata = Resolve-MenuCommandMetadata -Command $Command

    if ($Override) {
        $match = @($metadata.Parameters | Where-Object { $_.Name -eq $Override })
        if ($match.Count -gt 0) { return $match[0] }
        Write-Warning ("Manifest names dry-run parameter '{0}' but {1} does not expose it." -f $Override, $Command.Name)
        return $null
    }

    foreach ($candidate in @($Manifest.DryRunNames)) {
        $match = @($metadata.Parameters | Where-Object { $_.Name -eq $candidate })
        if ($match.Count -gt 0) { return $match[0] }
    }

    if ($metadata.SupportsShouldProcess) {
        return (New-MenuParameter -Name 'WhatIf' -TypeName 'System.Management.Automation.SwitchParameter' -IsSwitch $true)
    }

    return $null
}

# ============================================================================
# Tenants
# ============================================================================

function Get-MenuTenantList {
    <#
        Loads the tenant list referenced by the manifest. Returns an empty array
        when the manifest does not configure one.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Manifest)

    if (-not $Manifest.Tenants) { return @() }

    $path = $Manifest.Tenants
    if (-not [System.IO.Path]::IsPathRooted($path)) {
        $path = Join-Path (Split-Path -Parent $Manifest.ManifestPath) $path
    }

    if (-not (Test-Path -LiteralPath $path)) {
        Write-Warning ("Tenant list not found: {0}" -f $path)
        return @()
    }

    $data = Import-PowerShellDataFile -LiteralPath $path
    if (-not $data.ContainsKey('Tenants')) {
        Write-Warning ("{0} has no 'Tenants' key." -f $path)
        return @()
    }

    $tenants = @()
    foreach ($entry in @($data.Tenants)) {
        $tenants += [pscustomobject]@{
            Name       = $entry.Name
            Domain     = $(if ($entry.ContainsKey('Domain')) { $entry.Domain } else { $null })
            Cloud      = $(if ($entry.ContainsKey('Cloud'))  { $entry.Cloud }  else { $null })
            TenantId   = $(if ($entry.ContainsKey('TenantId')) { $entry.TenantId } else { $null })
            Note       = $(if ($entry.ContainsKey('Note')) { $entry.Note } else { '' })
            Source     = 'list'
            Identity   = $null   # what actually gets passed; filled on selection
            Resolved   = $false
        }
    }

    # Remembered ad-hoc tenants come after the curated list. The .psd1 wins on a
    # domain collision - a hand-maintained entry should not be shadowed by one
    # that got picked up in passing.
    $listedDomains = @($tenants | ForEach-Object { $_.Domain })
    foreach ($entry in @(Get-MenuTenantCache -Manifest $Manifest)) {
        if ($listedDomains -contains $entry.Domain) { continue }
        $tenants += [pscustomobject]@{
            Name       = $entry.Name
            Domain     = $entry.Domain
            Cloud      = $entry.Cloud
            TenantId   = $entry.TenantId
            Note       = $entry.Note
            Source     = 'remembered'
            Identity   = $null
            Resolved   = $($null -ne $entry.TenantId)
        }
    }

    return $tenants
}

function Get-MenuTenantCachePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Manifest)

    if (-not $Manifest.TenantCache) { return $null }

    $path = $Manifest.TenantCache
    if (-not [System.IO.Path]::IsPathRooted($path)) {
        $path = Join-Path (Split-Path -Parent $Manifest.ManifestPath) $path
    }
    return $path
}

function Get-MenuTenantCache {
    <#
        Remembered tenants, newest first. Machine-written, so it is JSON rather
        than a .psd1 - the hand-maintained list keeps its comments that way.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Manifest)

    $path = Get-MenuTenantCachePath -Manifest $Manifest
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return @() }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        return @($raw | ConvertFrom-Json) | Sort-Object -Property LastUsedUtc -Descending
    }
    catch {
        Write-Warning ("Could not read tenant cache '{0}': {1}" -f $path, $_.Exception.Message)
        return @()
    }
}

function Save-MenuTenantCache {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Manifest,
        [object[]]$Entries = @()
    )

    $path = Get-MenuTenantCachePath -Manifest $Manifest
    if (-not $path) { return }

    try {
        $dir = Split-Path -Parent $path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -Path $dir -ItemType Directory -Force | Out-Null
        }
        ConvertTo-Json -InputObject @($Entries) -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
    }
    catch {
        Write-Warning ("Could not write tenant cache: {0}" -f $_.Exception.Message)
    }
}

function Set-MenuTenantRemembered {
    <#
        Adds or refreshes one remembered tenant. Keyed on domain, so re-selecting
        an existing entry updates its timestamp instead of duplicating it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Manifest,
        [Parameter(Mandatory)][object]$Tenant
    )

    $cache = @(Get-MenuTenantCache -Manifest $Manifest)
    $kept = @($cache | Where-Object { $_.Domain -ne $Tenant.Domain })

    $kept += [pscustomobject]@{
        Name        = $Tenant.Name
        Domain      = $Tenant.Domain
        Cloud       = $Tenant.Cloud
        TenantId    = $Tenant.TenantId
        Note        = $Tenant.Note
        LastUsedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }

    Save-MenuTenantCache -Manifest $Manifest -Entries $kept
}

function Remove-MenuTenantRemembered {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Manifest,
        [Parameter(Mandatory)][string]$Domain
    )

    $cache = @(Get-MenuTenantCache -Manifest $Manifest)
    Save-MenuTenantCache -Manifest $Manifest -Entries @($cache | Where-Object { $_.Domain -ne $Domain })
}

function Resolve-TenantIdentity {
    <#
        Finds a tenant's GUID and cloud from its domain, without authenticating.

        Same OIDC discovery probe the GovGuard cloud broker uses, reimplemented
        here so the engine stays independent of any one module. Commercial is
        probed first and an answer only counts when the issuer host matches the
        authority asked and carries a real tenant GUID - the sovereign endpoint
        answers for domains that do not live there.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Domain,
        [int]$TimeoutSeconds = 10
    )

    $authorities = [ordered]@{
        'Global' = 'https://login.microsoftonline.com'
        'USGov'  = 'https://login.microsoftonline.us'
    }

    $guidPattern = '[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}'

    foreach ($entry in $authorities.GetEnumerator()) {
        $authorityHost = ([System.Uri]$entry.Value).Host
        $uri = '{0}/{1}/v2.0/.well-known/openid-configuration' -f $entry.Value, $Domain

        try {
            $doc = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec $TimeoutSeconds -ErrorAction Stop
        }
        catch { continue }

        if (-not $doc -or -not $doc.issuer) { continue }

        $issuerHost = $null
        try { $issuerHost = ([System.Uri]$doc.issuer).Host } catch { }
        if ($issuerHost -ne $authorityHost) { continue }
        if ($doc.issuer -notmatch $guidPattern) { continue }

        $guid = ([regex]::Match($doc.issuer, $guidPattern)).Value

        return [pscustomobject]@{
            TenantId = $guid
            Cloud    = $entry.Key
            Issuer   = $doc.issuer
        }
    }

    return $null
}

function Show-TenantPicker {
    <#
        Presents the tenant list, resolves the chosen one, and returns it.
        Returns $null if the operator backs out.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Manifest,
        [Parameter(Mandatory)][object[]]$Tenants,
        [switch]$AllowCancel
    )

    while ($true) {
        Clear-Host
        Write-Host ('=' * 74)
        Write-Host 'SELECT TENANT'
        Write-Host ('=' * 74)
        Write-Host ''

        for ($i = 0; $i -lt $Tenants.Count; $i++) {
            $t = $Tenants[$i]
            $detail = $t.Domain
            if ($t.Cloud) { $detail = '{0}  [{1}]' -f $detail, $t.Cloud }
            $marker = $(if ($t.Source -eq 'remembered') { '*' } else { ' ' })
            Write-Host ('  {0,3}){1}{2,-27}{3}' -f ($i + 1), $marker, $t.Name, $detail)
            if ($t.Note) { Write-Host ('       {0}' -f $t.Note) -ForegroundColor DarkGray }
        }

        $remembered = @($Tenants | Where-Object { $_.Source -eq 'remembered' })
        if ($remembered.Count -gt 0) {
            Write-Host ''
            Write-Host '  * remembered from an earlier lookup' -ForegroundColor DarkGray
        }

        Write-Host ''
        Write-Host '  D)  Enter a domain not on the list'
        if ($remembered.Count -gt 0) { Write-Host '  F)  Forget a remembered tenant' }
        if ($AllowCancel) { Write-Host '  B)  Back' }
        Write-Host '  Q)  Quit'
        Write-Host ''

        $choice = (Read-Host 'choose').Trim()
        if ([string]::IsNullOrWhiteSpace($choice)) { continue }

        $upper = $choice.ToUpperInvariant()
        if ($upper -eq 'Q') { exit 0 }
        if ($upper -eq 'B' -and $AllowCancel) { return $null }

        if ($upper -eq 'F' -and $remembered.Count -gt 0) {
            $answer = (Read-Host '  Number of the remembered tenant to forget').Trim()
            $index = 0
            if ([int]::TryParse($answer, [ref]$index) -and $index -ge 1 -and $index -le $Tenants.Count) {
                $victim = $Tenants[$index - 1]
                if ($victim.Source -ne 'remembered') {
                    Write-Host '  That one is in tenants.psd1 - edit the file to remove it.' -ForegroundColor Yellow
                    Start-Sleep -Milliseconds 1200
                }
                else {
                    Remove-MenuTenantRemembered -Manifest $Manifest -Domain $victim.Domain
                    $Tenants = @(Get-MenuTenantList -Manifest $Manifest)
                    Write-Host ('  Forgot {0}.' -f $victim.Name) -ForegroundColor Green
                    Start-Sleep -Milliseconds 700
                }
            }
            continue
        }

        $selected = $null

        if ($upper -eq 'D') {
            $domain = (Read-Host '  Domain').Trim()
            if ([string]::IsNullOrWhiteSpace($domain)) { continue }
            $selected = [pscustomobject]@{
                Name = $domain; Domain = $domain; Cloud = $null
                TenantId = $null; Note = 'ad hoc'; Source = 'adhoc'
                Identity = $null; Resolved = $false
            }
        }
        else {
            $index = 0
            if (-not [int]::TryParse($choice, [ref]$index) -or $index -lt 1 -or $index -gt $Tenants.Count) {
                Write-Host '  Not an option.' -ForegroundColor Yellow
                Start-Sleep -Milliseconds 700
                continue
            }
            $selected = $Tenants[$index - 1]
        }

        # Resolve the GUID and cloud from the domain, no credentials needed.
        if (-not $selected.Resolved -and $selected.Domain) {
            Write-Host ''
            Write-Host ('  Resolving {0}...' -f $selected.Domain)
            $resolved = Resolve-TenantIdentity -Domain $selected.Domain

            if ($resolved) {
                if (-not $selected.TenantId) { $selected.TenantId = $resolved.TenantId }
                if (-not $selected.Cloud)    { $selected.Cloud = $resolved.Cloud }
                $selected.Resolved = $true

                if ($selected.TenantId -ne $resolved.TenantId) {
                    Write-Host ('  WARNING: list says {0}, discovery says {1}.' -f $selected.TenantId, $resolved.TenantId) -ForegroundColor Yellow
                }
                Write-Host ('  {0}  [{1}]' -f $selected.TenantId, $selected.Cloud) -ForegroundColor Green
            }
            else {
                Write-Host '  Could not resolve that domain. Check spelling, or continue and connect by domain.' -ForegroundColor Yellow
                $answer = Read-Host '  Continue anyway? [y/N]'
                if ($answer -notmatch '^(y|yes)$') { continue }
            }
        }

        # The GUID is unambiguous; fall back to the domain when discovery failed.
        $selected.Identity = $(if ($selected.TenantId) { $selected.TenantId } else { $selected.Domain })

        # Offer to keep an ad-hoc lookup. Asked, never assumed: a prospect domain
        # someone typed once should not silently persist to a file on the share.
        if ($selected.Source -eq 'adhoc' -and $selected.Resolved) {
            Write-Host ''
            $keep = Read-Host '  Remember this tenant for next time? [y/N]'
            if ($keep -match '^(y|yes)$') {
                $friendly = (Read-Host ('  Name to show [{0}]' -f $selected.Domain)).Trim()
                if ($friendly) { $selected.Name = $friendly }
                $selected.Note = ''
                Set-MenuTenantRemembered -Manifest $Manifest -Tenant $selected
                $selected.Source = 'remembered'
                Write-Host '  Saved.' -ForegroundColor Green
            }
        }
        elseif ($selected.Source -eq 'remembered') {
            Set-MenuTenantRemembered -Manifest $Manifest -Tenant $selected   # refresh recency
        }

        Start-Sleep -Milliseconds 400
        return $selected
    }
}

# ============================================================================
# Prompting
# ============================================================================

function Read-MenuValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Parameter,
        [switch]$Required
    )

    $label = $Parameter.Name
    $suffix = if ($Required) { ' (required)' } else { ' (enter to skip)' }

    if ($Parameter.Help) {
        Write-Host ''
        Write-Host ('  {0}' -f $Parameter.Help) -ForegroundColor DarkGray
    }

    if ($Parameter.ValidateSet.Count -gt 0) {
        $isArray = ($Parameter.TypeName -like '*`[`]')

        Write-Host ''
        Write-Host ("  {0}{1}" -f $label, $suffix)
        for ($i = 0; $i -lt $Parameter.ValidateSet.Count; $i++) {
            Write-Host ("    {0}) {1}" -f ($i + 1), $Parameter.ValidateSet[$i])
        }
        if ($isArray) {
            Write-Host '    (several allowed - comma separated, e.g. 1,2)' -ForegroundColor DarkGray
        }

        while ($true) {
            $answer = Read-Host '    choose'
            if ([string]::IsNullOrWhiteSpace($answer)) {
                if ($Required) { Write-Host '    required.' -ForegroundColor Yellow; continue }
                return @{ Provided = $false }
            }

            $picked = @()
            $bad = $false
            foreach ($token in @($answer -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
                $index = 0
                if ([int]::TryParse($token, [ref]$index) -and $index -ge 1 -and $index -le $Parameter.ValidateSet.Count) {
                    $picked += $Parameter.ValidateSet[$index - 1]
                }
                elseif ($Parameter.ValidateSet -contains $token) {
                    $picked += $token
                }
                else {
                    $bad = $true
                    break
                }
            }

            if ($bad -or $picked.Count -eq 0) {
                Write-Host '    not one of the options.' -ForegroundColor Yellow
                continue
            }

            if (-not $isArray -and $picked.Count -gt 1) {
                Write-Host '    this parameter takes a single value.' -ForegroundColor Yellow
                continue
            }

            if ($isArray) { return @{ Provided = $true; Value = @($picked) } }
            return @{ Provided = $true; Value = $picked[0] }
        }
    }

    if ($Parameter.IsSwitch) {
        # A switch is absent or present. Declining means omit it, not pass $false,
        # so the invocation line reflects what was actually chosen.
        while ($true) {
            $answer = Read-Host ("  {0} [y/n]{1}" -f $label, $(if ($Required) { ' (required)' } else { ' (enter to skip)' }))
            if ([string]::IsNullOrWhiteSpace($answer)) {
                if ($Required) { Write-Host '    required.' -ForegroundColor Yellow; continue }
                return @{ Provided = $false }
            }
            switch -Regex ($answer) {
                '^(y|yes|true|1)$' { return @{ Provided = $true; Value = $true } }
                '^(n|no|false|0)$' { return @{ Provided = $false } }
                default            { Write-Host '    answer y or n.' -ForegroundColor Yellow }
            }
        }
    }

    if ($Parameter.IsBool) {
        # A [bool] is different: $false is a real value and often not the default,
        # so declining has to be passed explicitly.
        while ($true) {
            $answer = Read-Host ("  {0} [y/n]{1}" -f $label, $(if ($Required) { ' (required)' } else { ' (enter to skip)' }))
            if ([string]::IsNullOrWhiteSpace($answer)) {
                if ($Required) { Write-Host '    required.' -ForegroundColor Yellow; continue }
                return @{ Provided = $false }
            }
            switch -Regex ($answer) {
                '^(y|yes|true|1)$' { return @{ Provided = $true; Value = $true } }
                '^(n|no|false|0)$' { return @{ Provided = $true; Value = $false } }
                default            { Write-Host '    answer y or n.' -ForegroundColor Yellow }
            }
        }
    }

    $listHint = ''
    if ($Parameter.TypeName -like '*`[`]') { $listHint = ' comma separated' }

    while ($true) {
        $answer = Read-Host ("  {0} <{1}>{2}{3}" -f $label, ($Parameter.TypeName -replace '^System\.', ''), $listHint, $suffix)
        if ([string]::IsNullOrWhiteSpace($answer)) {
            if ($Required) { Write-Host '    required.' -ForegroundColor Yellow; continue }
            return @{ Provided = $false }
        }
        if ($Parameter.TypeName -like '*`[`]') {
            return @{ Provided = $true; Value = @($answer -split ',' | ForEach-Object { $_.Trim() }) }
        }
        return @{ Provided = $true; Value = $answer }
    }
}

function Get-MenuArgument {
    <#
        Builds the splat for one invocation: preset args from the manifest, then
        prompts for whatever is left.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Command,
        [hashtable]$Preset = @{},
        [string[]]$Skip = @()
    )

    $metadata = Resolve-MenuCommandMetadata -Command $Command
    $splat = @{}

    foreach ($key in $Preset.Keys) { $splat[$key] = $Preset[$key] }

    $pending = @($metadata.Parameters | Where-Object {
        -not $splat.ContainsKey($_.Name) -and $Skip -notcontains $_.Name
    })

    if ($pending.Count -eq 0) { return $splat }

    $mandatory = @($pending | Where-Object { $_.IsMandatory })
    $optional  = @($pending | Where-Object { -not $_.IsMandatory })

    if ($mandatory.Count -gt 0) {
        Write-Host ''
        Write-Host '  Required parameters:' -ForegroundColor Cyan
        foreach ($p in $mandatory) {
            $answer = Read-MenuValue -Parameter $p -Required
            if ($answer.Provided) { $splat[$p.Name] = $answer.Value }
        }
    }

    if ($optional.Count -gt 0) {
        # List them. A yes/no on a count the operator cannot see is a guess -
        # showing the names and types costs four lines and removes the guessing.
        Write-Host ''
        Write-Host '  Optional parameters:' -ForegroundColor Cyan

        for ($i = 0; $i -lt $optional.Count; $i++) {
            $p = $optional[$i]

            $type = $p.TypeName -replace '^System\.', ''
            $type = $type -replace '^Management\.Automation\.SwitchParameter$', 'switch'
            $type = $type -replace '^Boolean$', 'bool'
            $type = $type -replace '^String$', 'string'
            $type = $type -replace '^String\[\]$', 'string[]'
            $type = $type -replace '^Int32$', 'int'

            Write-Host ('   {0,2}) {1,-24}{2}' -f ($i + 1), $p.Name, $type)

            if ($p.ValidateSet.Count -gt 0) {
                $shown = @($p.ValidateSet | Select-Object -First 5)
                $suffix = $(if ($p.ValidateSet.Count -gt 5) { ' | ...' } else { '' })
                Write-Host ('        {0}{1}' -f ($shown -join ' | '), $suffix) -ForegroundColor DarkGray
            }
            elseif ($p.TypeName -like '*`[`]') {
                Write-Host '        comma separated' -ForegroundColor DarkGray
            }

            if ($p.Help) {
                $line = $p.Help
                if ($line.Length -gt 66) { $line = $line.Substring(0, 63) + '...' }
                Write-Host ('        {0}' -f $line) -ForegroundColor DarkGray
            }
        }

        Write-Host ''
        Write-Host '   Enter numbers to set (e.g. 1,3), A for all, or Enter to skip.' -ForegroundColor DarkGray
        $more = (Read-Host '   choose').Trim()

        $chosen = @()

        if (-not [string]::IsNullOrWhiteSpace($more)) {
            if ($more -match '^(a|all)$') {
                $chosen = @($optional)
            }
            elseif ($more -match '^(y|yes)$') {
                $chosen = @($optional)   # kept so old habits still work
            }
            else {
                foreach ($token in @($more -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
                    $index = 0
                    if ([int]::TryParse($token, [ref]$index) -and $index -ge 1 -and $index -le $optional.Count) {
                        $chosen += $optional[$index - 1]
                    }
                    else {
                        $named = @($optional | Where-Object { $_.Name -eq $token })
                        if ($named.Count -gt 0) { $chosen += $named[0] }
                        else { Write-Host ('   Ignoring "{0}" - not on the list.' -f $token) -ForegroundColor Yellow }
                    }
                }
            }
        }

        foreach ($p in $chosen) {
            $answer = Read-MenuValue -Parameter $p
            if ($answer.Provided) { $splat[$p.Name] = $answer.Value }
        }
    }

    return $splat
}

# ============================================================================
# Logging
# ============================================================================

function Write-MenuLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Manifest,
        [Parameter(Mandatory)][string]$CommandName,
        [Parameter(Mandatory)][string]$Mode,
        [hashtable]$Arguments = @{},
        [string]$Result = 'Completed',
        [string]$ErrorMessage = '',
        [double]$DurationSeconds = 0
    )

    if ($script:NoLogging) { return }

    $redacted = @{}
    foreach ($key in $Arguments.Keys) {
        $isSecret = $false
        foreach ($pattern in @($Manifest.RedactParameters)) {
            if ($key -like "*$pattern*") { $isSecret = $true; break }
        }
        $redacted[$key] = if ($isSecret) { '[redacted]' } else { ($Arguments[$key] | Out-String).Trim() }
    }

    $entry = [pscustomobject]@{
        TimestampUtc = (Get-Date).ToUniversalTime().ToString('o')
        Set          = $Manifest.Title
        Tenant       = $(if ($script:ActiveTenant) { $script:ActiveTenant.Name } else { '' })
        TenantId     = $(if ($script:ActiveTenant) { $script:ActiveTenant.TenantId } else { '' })
        Operator     = ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME)
        Computer     = $env:COMPUTERNAME
        Command      = $CommandName
        Mode         = $Mode
        Arguments    = $redacted
        Result       = $Result
        Error        = $ErrorMessage
        Seconds      = [math]::Round($DurationSeconds, 2)
    }

    try {
        $logDir = Split-Path -Parent $Manifest.LogPath
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -Path $logDir -ItemType Directory -Force | Out-Null
        }
        $entry | ConvertTo-Json -Depth 6 -Compress | Add-Content -LiteralPath $Manifest.LogPath -Encoding UTF8
    }
    catch {
        Write-Warning ("Could not write launcher log: {0}" -f $_.Exception.Message)
    }
}

# ============================================================================
# Invocation
# ============================================================================

function Invoke-MenuCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Manifest,
        [Parameter(Mandatory)][object]$Command,
        [Parameter(Mandatory)][ValidateSet('Preview', 'Live')][string]$Mode,
        [hashtable]$Preset = @{},
        [string]$DryRunOverride,
        [switch]$RequireConfirmation,
        [switch]$ReadOnly,
        [switch]$NoPause
    )

    # A read-only command changes nothing, so the dry-run parameter is noise -
    # passing -WhatIfMode:$false on an audit makes it read like a live write.
    $dryRunParam = $null
    if (-not $ReadOnly) {
        $dryRunParam = Get-DryRunParameter -Command $Command -Manifest $Manifest -Override $DryRunOverride
    }

    $splat = @{}
    foreach ($key in $Preset.Keys) { $splat[$key] = $Preset[$key] }

    # Dry-run wiring. A [bool] that defaults true must be passed explicitly as
    # false for a live run, or "run for real" quietly previews instead.
    $skip = @()
    if ($dryRunParam) {
        $skip += $dryRunParam.Name
        if ($Mode -eq 'Preview') {
            $splat[$dryRunParam.Name] = $true
        }
        elseif ($dryRunParam.IsBool) {
            $splat[$dryRunParam.Name] = $false
        }
    }

    # Active tenant injection. A command that takes the tenant parameter gets it
    # filled from the selection, so the operator never retypes a GUID and cannot
    # run against a tenant other than the one shown in the banner.
    if ($script:ActiveTenant -and $Manifest.TenantParameter) {
        $metadata = Resolve-MenuCommandMetadata -Command $Command
        $tenantParam = $Manifest.TenantParameter

        if (-not $splat.ContainsKey($tenantParam) -and
            @($metadata.Parameters | Where-Object { $_.Name -eq $tenantParam }).Count -gt 0) {
            $splat[$tenantParam] = $script:ActiveTenant.Identity
            $skip += $tenantParam
        }

        $cloudParam = $Manifest.TenantCloudParameter
        if ($cloudParam -and $script:ActiveTenant.Cloud -and
            -not $splat.ContainsKey($cloudParam) -and
            @($metadata.Parameters | Where-Object { $_.Name -eq $cloudParam }).Count -gt 0) {
            $splat[$cloudParam] = $script:ActiveTenant.Cloud
            $skip += $cloudParam
        }
    }

    $splat = Get-MenuArgument -Command $Command -Preset $splat -Skip $skip

    if ($Mode -eq 'Live' -and -not $ReadOnly) {
        Write-Host ''
        if ($RequireConfirmation) {
            Write-Host ('  This runs {0} for real and it is not reversible.' -f $Command.Name) -ForegroundColor Yellow
            $typed = Read-Host ("  Type the command name to confirm")
            if ($typed -ne $Command.Name) {
                Write-Host '  Cancelled.' -ForegroundColor Yellow
                return
            }
        }
        elseif (-not $dryRunParam) {
            Write-Host ('  {0} has no preview mode. It will run for real.' -f $Command.Name) -ForegroundColor Yellow
            $answer = Read-Host '  Continue? [y/N]'
            if ($answer -notmatch '^(y|yes)$') {
                Write-Host '  Cancelled.' -ForegroundColor Yellow
                return
            }
        }
    }

    $argumentLine = ($splat.Keys | Sort-Object | ForEach-Object { "-$_ $($splat[$_])" }) -join ' '
    Write-Host ''
    Write-Host ('  Running: {0} {1}' -f $Command.Name, $argumentLine).TrimEnd() -ForegroundColor Green
    if ($Mode -eq 'Preview') {
        Write-Host '  Preview mode - no changes will be written.' -ForegroundColor Yellow
    }
    Write-Host ''

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $result = 'Completed'
    $errorMessage = ''

    try {
        switch ($Command.Kind) {
            'File'     { & $Command.Source @splat }
            'Function' { & $Command.Source @splat }
        }
    }
    catch {
        $result = 'Failed'
        $errorMessage = $_.Exception.Message
        Write-Host ''
        Write-Host ('  ERROR: {0}' -f $errorMessage) -ForegroundColor Red
        Write-Host ('  {0}' -f $_.ScriptStackTrace) -ForegroundColor DarkGray
    }
    finally {
        $stopwatch.Stop()
        Write-MenuLog -Manifest $Manifest -CommandName $Command.Name -Mode $Mode `
            -Arguments $splat -Result $result -ErrorMessage $errorMessage `
            -DurationSeconds $stopwatch.Elapsed.TotalSeconds
    }

    if (-not $NoPause) {
        Write-Host ''
        Read-Host '  Press Enter to return to the menu' | Out-Null
    }
}

# ============================================================================
# Session state
# ============================================================================

function Test-MenuSession {
    <#
        Runs the manifest's session probe. A command that throws when there is no
        session - Get-GovGuardContext, for instance - is all the engine needs to
        know whether the set is ready to work.

        Returns $true when connected, $false when not, and $true when no probe is
        configured, so sets without a session concept are unaffected.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Manifest)

    if (-not $Manifest.SessionProbe) { return $true }

    try {
        & $Manifest.SessionProbe -ErrorAction Stop | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

# ============================================================================
# Rendering
# ============================================================================

function Show-MenuHeader {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Manifest)

    $line = '=' * 74
    Write-Host $line
    Write-Host $Manifest.Title
    if ($script:ActiveTenant) {
        $tenantLine = '  TENANT: {0}' -f $script:ActiveTenant.Name
        if ($script:ActiveTenant.Cloud) { $tenantLine += '   [{0}]' -f $script:ActiveTenant.Cloud }
        if ($script:ActiveTenant.TenantId) { $tenantLine += '   {0}' -f $script:ActiveTenant.TenantId }
        Write-Host $tenantLine -ForegroundColor Cyan

        if ($Manifest.SessionProbe) {
            if (Test-MenuSession -Manifest $Manifest) {
                Write-Host '  SESSION: connected' -ForegroundColor Green
            }
            else {
                Write-Host '  SESSION: not connected' -ForegroundColor Yellow
            }
        }
    }
    else {
        Write-Host $Manifest.Root
    }
    Write-Host $line
    if ($Manifest.Notice) {
        Write-Host ''
        Write-Host $Manifest.Notice -ForegroundColor DarkCyan
    }
}

function Show-Menu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Manifest,
        [Parameter(Mandatory)][object[]]$Commands
    )

    Clear-Host
    Show-MenuHeader -Manifest $Manifest

    foreach ($section in @($Manifest.Sections)) {
        Write-Host ''
        $heading = $section.Name
        if ($section.ContainsKey('Note') -and $section.Note) {
            $heading = '{0}  ({1})' -f $section.Name, $section.Note
        }
        Write-Host $heading
        Write-Host ''
        foreach ($item in @($section.Items)) {
            $note = ''
            if ($item.ContainsKey('Note') -and $item.Note) { $note = ' - ' + $item.Note }
            Write-Host ('  {0,-3} {1,-28}{2}' -f ($item.Key + ')'), $item.Label, $note)
        }
    }

    Write-Host ''
    Write-Host 'ALL COMMANDS  (direct)'

    $index = 0
    $lastGroup = $null
    foreach ($command in $Commands) {
        $index++
        if ($command.Group -ne $lastGroup) {
            Write-Host ''
            if ($command.Group -ne 'Root') {
                Write-Host ('  [{0}]' -f $command.Group) -ForegroundColor DarkGray
            }
            $lastGroup = $command.Group
        }
        Write-Host ('  {0,3}) {1}' -f $index, $command.DisplayName)
    }

    Write-Host ''
    Write-Host '  H)  Show help for a command   (Get-Help, full detail)'
    if ($Manifest.Reports) {
        Write-Host '  R)  Open the Reports folder'
    }
    Write-Host '  L)  Show recent launcher log entries'
    if ($script:TenantList.Count -gt 0) {
        Write-Host '  T)  Switch tenant'
    }
    Write-Host '  Q)  Quit'
    Write-Host ''
}

function Show-CommandSubmenu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Manifest,
        [Parameter(Mandatory)][object]$Command
    )

    $dryRunParam = Get-DryRunParameter -Command $Command -Manifest $Manifest

    while ($true) {
        Write-Host ''
        Write-Host ('-' * 62)
        Write-Host $Command.DisplayName
        Write-Host ('-' * 62)
        Write-Host ''

        if ($dryRunParam) {
            Write-Host ('  1)  Preview only  (-{0} - makes no changes)' -f $dryRunParam.Name)
        }
        else {
            Write-Host '  1)  Preview only  (not supported by this command)' -ForegroundColor DarkGray
        }
        Write-Host '  2)  Run for real'
        Write-Host '  3)  Back'
        Write-Host ''

        $choice = Read-Host 'choose'
        switch ($choice) {
            '1' {
                if (-not $dryRunParam) {
                    Write-Host '  This command has no preview parameter.' -ForegroundColor Yellow
                    continue
                }
                Invoke-MenuCommand -Manifest $Manifest -Command $Command -Mode Preview
                return
            }
            '2' {
                Invoke-MenuCommand -Manifest $Manifest -Command $Command -Mode Live
                return
            }
            '3' { return }
            default { Write-Host '  Not an option.' -ForegroundColor Yellow }
        }
    }
}

function Show-CommandHelp {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Commands)

    Write-Host ''
    $answer = Read-Host 'Number of the command to show help for'
    $index = 0
    if (-not [int]::TryParse($answer, [ref]$index) -or $index -lt 1 -or $index -gt $Commands.Count) {
        Write-Host '  Not a valid number.' -ForegroundColor Yellow
        Read-Host '  Press Enter' | Out-Null
        return
    }

    $command = $Commands[$index - 1]
    Write-Host ''
    try {
        Get-Help -Name $command.Source -Full | Out-Host
    }
    catch {
        Write-Host ('  No help available: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
    }
    Read-Host '  Press Enter to return to the menu' | Out-Null
}

function Show-RecentLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Manifest)

    Write-Host ''
    if (-not (Test-Path -LiteralPath $Manifest.LogPath)) {
        Write-Host '  No launcher log yet.' -ForegroundColor Yellow
        Read-Host '  Press Enter' | Out-Null
        return
    }

    Get-Content -LiteralPath $Manifest.LogPath -Tail 15 |
        ForEach-Object { $_ | ConvertFrom-Json } |
        Select-Object TimestampUtc, Operator, Command, Mode, Result |
        Format-Table -AutoSize | Out-Host

    Read-Host '  Press Enter to return to the menu' | Out-Null
}

# ============================================================================
# Main loop
# ============================================================================

$script:NoLogging = [bool]$NoLog

$manifest = Get-MenuManifest -Path $ManifestPath

$script:ActiveTenant = $null
$script:TenantList = @(Get-MenuTenantList -Manifest $manifest)

if ($script:TenantList.Count -gt 0 -and $manifest.RequireTenant) {
    $script:ActiveTenant = Show-TenantPicker -Manifest $manifest -Tenants $script:TenantList
    $script:TenantList = @(Get-MenuTenantList -Manifest $manifest)
}

$commands = @(Get-MenuCommandList -Manifest $manifest)

if ($commands.Count -eq 0) {
    throw ("No commands discovered for '{0}'. Check Discovery settings in {1}." -f $manifest.Title, $manifest.ManifestPath)
}

# Index the curated shortcuts by key for quick lookup.
$shortcuts = @{}
foreach ($section in @($manifest.Sections)) {
    foreach ($item in @($section.Items)) {
        $shortcuts[$item.Key.ToUpperInvariant()] = $item
    }
}

while ($true) {
    Show-Menu -Manifest $manifest -Commands $commands
    $choice = (Read-Host 'choose').Trim()

    if ([string]::IsNullOrWhiteSpace($choice)) { continue }

    $upper = $choice.ToUpperInvariant()

    if ($upper -eq 'Q') { break }

    if ($upper -eq 'H') { Show-CommandHelp -Commands $commands; continue }

    if ($upper -eq 'L') { Show-RecentLog -Manifest $manifest; continue }

    if ($upper -eq 'T' -and $script:TenantList.Count -gt 0 -and -not $shortcuts.ContainsKey('T')) {
        $picked = Show-TenantPicker -Manifest $manifest -Tenants $script:TenantList -AllowCancel
        if ($picked) {
            # Leaving a tenant should end its session, or the next command runs
            # against the previous connection while the banner says otherwise.
            if ($manifest.OnTenantSwitch -and $script:ActiveTenant) {
                $cleanup = @($commands | Where-Object { $_.Name -eq $manifest.OnTenantSwitch })
                if ($cleanup.Count -gt 0) {
                    try { & $cleanup[0].Source | Out-Null }
                    catch { Write-Warning ('Tenant switch cleanup failed: {0}' -f $_.Exception.Message) }
                }
            }
            $script:ActiveTenant = $picked
        }
        $script:TenantList = @(Get-MenuTenantList -Manifest $manifest)
        continue
    }

    if ($upper -eq 'R' -and $manifest.Reports -and -not $shortcuts.ContainsKey('R')) {
        if (Test-Path -LiteralPath $manifest.Reports) {
            Invoke-Item -LiteralPath $manifest.Reports
        }
        else {
            Write-Host '  Reports folder does not exist yet.' -ForegroundColor Yellow
            Read-Host '  Press Enter' | Out-Null
        }
        continue
    }

    if ($shortcuts.ContainsKey($upper)) {
        $item = $shortcuts[$upper]
        $target = @($commands | Where-Object { $_.Name -eq $item.Command })
        if ($target.Count -eq 0) {
            Write-Host ('  Manifest shortcut points at "{0}", which was not discovered.' -f $item.Command) -ForegroundColor Red
            Read-Host '  Press Enter' | Out-Null
            continue
        }

        $preset = @{}
        if ($item.ContainsKey('Args') -and $item.Args) {
            foreach ($key in $item.Args.Keys) { $preset[$key] = $item.Args[$key] }
        }

        $mode = 'Live'
        if ($item.ContainsKey('Mode') -and $item.Mode) { $mode = $item.Mode }

        if ($mode -eq 'Ask') {
            Show-CommandSubmenu -Manifest $manifest -Command $target[0]
            continue
        }

        if ($mode -eq 'Live' -and $item.ContainsKey('LiveArgs') -and $item.LiveArgs) {
            foreach ($key in $item.LiveArgs.Keys) { $preset[$key] = $item.LiveArgs[$key] }
        }

        $confirm = $false
        if ($item.ContainsKey('Confirm')) { $confirm = [bool]$item.Confirm }

        $override = $null
        if ($item.ContainsKey('DryRunParameter')) { $override = $item.DryRunParameter }

        $readOnly = $false
        if ($item.ContainsKey('ReadOnly')) { $readOnly = [bool]$item.ReadOnly }

        # Session gate. Offer to connect rather than letting the command throw.
        $needsSession = $false
        if ($item.ContainsKey('RequiresSession')) { $needsSession = [bool]$item.RequiresSession }

        if ($needsSession -and -not (Test-MenuSession -Manifest $manifest)) {
            Write-Host ''
            Write-Host ('  Not connected. "{0}" needs a session first.' -f $item.Label) -ForegroundColor Yellow

            $connectKey = $manifest.SessionConnectKey
            if ($connectKey -and $shortcuts.ContainsKey($connectKey.ToUpperInvariant())) {
                $answer = Read-Host '  Connect now? [Y/n]'
                if ($answer -match '^(n|no)$') { continue }

                $connectItem = $shortcuts[$connectKey.ToUpperInvariant()]
                $connectTarget = @($commands | Where-Object { $_.Name -eq $connectItem.Command })

                if ($connectTarget.Count -gt 0) {
                    $connectPreset = @{}
                    if ($connectItem.ContainsKey('Args') -and $connectItem.Args) {
                        foreach ($k in $connectItem.Args.Keys) { $connectPreset[$k] = $connectItem.Args[$k] }
                    }
                    # -NoPause: this connect is a step on the way to what the
                    # operator actually asked for, not the end of an action.
                    Invoke-MenuCommand -Manifest $manifest -Command $connectTarget[0] -Mode 'Live' `
                        -Preset $connectPreset -ReadOnly -NoPause
                }

                if (-not (Test-MenuSession -Manifest $manifest)) {
                    Write-Host '  Still not connected - cancelled.' -ForegroundColor Yellow
                    Read-Host '  Press Enter' | Out-Null
                    continue
                }
            }
            else {
                Read-Host '  Press Enter' | Out-Null
                continue
            }
        }

        Invoke-MenuCommand -Manifest $manifest -Command $target[0] -Mode $mode `
            -Preset $preset -DryRunOverride $override -RequireConfirmation:$confirm `
            -ReadOnly:$readOnly
        continue
    }

    $index = 0
    if ([int]::TryParse($choice, [ref]$index) -and $index -ge 1 -and $index -le $commands.Count) {
        Show-CommandSubmenu -Manifest $manifest -Command $commands[$index - 1]
        continue
    }

    Write-Host '  Not an option.' -ForegroundColor Yellow
    Start-Sleep -Milliseconds 700
}

Write-Host ''
Write-Host 'Bye.' -ForegroundColor DarkGray
