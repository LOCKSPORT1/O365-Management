# O365Toolkit.Exchange Module Root
$privateFiles = Get-ChildItem -Path "$PSScriptRoot\Private" -Filter "*.ps1" -ErrorAction SilentlyContinue
foreach ($file in $privateFiles) { . $file.FullName }

$publicFiles = Get-ChildItem -Path "$PSScriptRoot\Public" -Filter "*.ps1" -ErrorAction SilentlyContinue
foreach ($file in $publicFiles) { . $file.FullName }
