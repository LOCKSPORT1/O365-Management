$ErrorActionPreference = 'Stop'

# 1. Clean module session cache & re-import frameworks
Get-Module O365Toolkit* | Remove-Module -Force -ErrorAction SilentlyContinue
Import-Module ".\Core\O365Toolkit.Core.psd1" -Force
Import-Module ".\Modules\O365Toolkit.Entra\O365Toolkit.Entra.psd1" -Force

# 2. Run quality gate check
$entraTest = Invoke-Pester -Path ".\Modules\O365Toolkit.Entra\Tests" -PassThru
if ($entraTest.FailedCount -gt 0) { throw "Tests failed!" }

# 3. Import NotebookLM tool module & build fresh full export package
Import-Module ".\Tools\O365Toolkit.NotebookLM\O365Toolkit.NotebookLM.psd1" -Force
$exportResult = New-ToolkitNotebookExport -ExportVersion 'v0.3' -NextFeature 'Get-ToolkitGroupMember'

# 4. Commit and push clean tenant-agnostic code to GitHub root of truth
git add .
git commit -m "chore(sync): end-of-day checkpoint export v0.3 and project synchronization"
git push origin feature/notebooklm-module-books

Write-Host "SUCCESS: Repository synced to GitHub and fresh export bundle ready at: $($exportResult.ZipPath)" -ForegroundColor Green