$moduleRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

Get-ChildItem -Path (Join-Path $moduleRoot 'core') -Filter '*.ps1' | ForEach-Object { . $_.FullName }
Get-ChildItem -Path (Join-Path $moduleRoot 'exchange') -Filter '*.ps1' | ForEach-Object { . $_.FullName }
Get-ChildItem -Path (Join-Path $moduleRoot 'lifecycle') -Filter '*.ps1' | ForEach-Object { . $_.FullName }
Get-ChildItem -Path (Join-Path $moduleRoot 'intune') -Filter '*.ps1' | ForEach-Object { . $_.FullName }
Get-ChildItem -Path (Join-Path $moduleRoot 'entra') -Filter '*.ps1' | ForEach-Object { . $_.FullName }
Get-ChildItem -Path (Join-Path $moduleRoot 'azure') -Filter '*.ps1' | ForEach-Object { . $_.FullName }
Get-ChildItem -Path (Join-Path $moduleRoot 'hybrid') -Filter '*.ps1' | ForEach-Object { . $_.FullName }
Get-ChildItem -Path (Join-Path $moduleRoot 'bulk') -Filter '*.ps1' | ForEach-Object { . $_.FullName }
Get-ChildItem -Path (Join-Path $moduleRoot 'sharepoint') -Filter '*.ps1' | ForEach-Object { . $_.FullName }
Get-ChildItem -Path (Join-Path $moduleRoot 'teams') -Filter '*.ps1' | ForEach-Object { . $_.FullName }
Get-ChildItem -Path (Join-Path $moduleRoot 'security') -Filter '*.ps1' | ForEach-Object { . $_.FullName }
Get-ChildItem -Path (Join-Path $moduleRoot 'reporting') -Filter '*.ps1' | ForEach-Object { . $_.FullName }

Get-ChildItem -Path (Join-Path $moduleRoot 'public') -Filter '*.ps1' | ForEach-Object { . $_.FullName }
