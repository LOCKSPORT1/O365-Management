<#
.SYNOPSIS
Builds a simple HTML dashboard summarizing the CSV reports produced by other toolbox scripts.
.DESCRIPTION
Scans a report folder for CSV files and renders an HTML page listing each file, its last-write
time, and its size. Intended as a lightweight landing page after running one or more reporting
or bulk scripts, not a replacement for detailed per-workload reports.
.PARAMETER TenantName
Tenant name from config\tenants.json. Used only for display in the dashboard header and log lines.
.PARAMETER ReportFolder
Folder to scan for CSV files to list on the dashboard.
.PARAMETER OutputHtml
Path to write the generated HTML dashboard file.
.PARAMETER ReportTitle
Title text displayed at the top of the dashboard page.
.EXAMPLE
.\reporting\New-HtmlDashboardReport.ps1 -TenantName Tenant-Example-NA
.EXAMPLE
.\reporting\New-HtmlDashboardReport.ps1 -TenantName Tenant-Example-Cloud -ReportFolder .\reports -OutputHtml .\reports\MultiTenantDashboard.html
#>
param(
    [Parameter(Mandatory)][string]$TenantName,
    [string]$ReportFolder = '.\reports',
    [string]$OutputHtml = '.\reports\AdminDashboardReport.html'
)

# ============================================================
# CONFIGURATION - adjust these values for your environment
# ============================================================
# Heading text shown at the top of the generated dashboard page.
$ReportTitle = 'Admin Dashboard Report'

. (Join-Path $PSScriptRoot '..\core\Common.ps1')
$outputFolder = Split-Path $OutputHtml -Parent
if ($outputFolder) { Ensure-Directory -Path $outputFolder }
Ensure-Directory -Path $ReportFolder

$csvFiles = Get-ChildItem -Path $ReportFolder -Filter '*.csv' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
$rows = foreach ($f in $csvFiles) {
    [pscustomobject]@{
        FileName = $f.Name
        LastWriteTime = $f.LastWriteTime
        SizeKB = [math]::Round($f.Length / 1KB, 2)
    }
}
$json = ($rows | ConvertTo-Json -Depth 3)
$html = @"
<!doctype html>
<html lang='en'>
<head>
<meta charset='utf-8'>
<meta name='viewport' content='width=device-width,initial-scale=1'>
<title>$ReportTitle - $TenantName</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;background:#0f172a;color:#e2e8f0;margin:0;padding:24px}
.container{max-width:1100px;margin:0 auto}
.card{background:#111827;border:1px solid #334155;border-radius:14px;padding:20px;margin-bottom:20px}
h1,h2{margin:0 0 12px}
table{width:100%;border-collapse:collapse}
th,td{padding:10px;border-bottom:1px solid #334155;text-align:left}
.badge{display:inline-block;padding:4px 8px;border-radius:999px;background:#0ea5e9;color:#082f49;font-weight:700}
.small{color:#94a3b8;font-size:14px}
</style>
</head>
<body>
<div class='container'>
  <div class='card'>
    <h1>$ReportTitle</h1>
    <p class='small'>Tenant: $TenantName</p>
    <p class='small'>Generated: $(Get-Date)</p>
  </div>
  <div class='card'>
    <h2>Discovered CSV Reports</h2>
    <table>
      <thead><tr><th>File</th><th>Last Updated</th><th>Size (KB)</th></tr></thead>
      <tbody id='reportRows'></tbody>
    </table>
  </div>
</div>
<script>
const rows = $json;
const target = document.getElementById('reportRows');
for (const row of rows) {
  const tr = document.createElement('tr');
  tr.innerHTML = `<td>${row.FileName}</td><td>${row.LastWriteTime}</td><td>${row.SizeKB}</td>`;
  target.appendChild(tr);
}
</script>
</body>
</html>
"@
Set-Content -Path $OutputHtml -Value $html -Encoding UTF8
Write-ToolboxLog -TenantName $TenantName -Level 'SUCCESS' -Message "HTML dashboard report written to $OutputHtml"
