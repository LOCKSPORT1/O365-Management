# ---------------------------------------------------------------------------
# Module Root: O365Toolkit.Security
# Track: NEUTRAL
# ---------------------------------------------------------------------------

$publicFiles = Get-ChildItem -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Public\*.ps1') -ErrorAction SilentlyContinue
foreach ($file in $publicFiles) {
    . $file.FullName
}

$privateFiles = Get-ChildItem -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Private\*.ps1') -ErrorAction SilentlyContinue
foreach ($file in $privateFiles) {
    . $file.FullName
}

Export-ModuleMember -Function @(
    'Get-ToolkitConditionalAccessPolicy'
    'Get-ToolkitAuditLogEntry'
)