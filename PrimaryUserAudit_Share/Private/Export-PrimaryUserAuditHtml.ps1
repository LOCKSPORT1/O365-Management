function Export-PrimaryUserAuditHtml {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object[]]$InputObject,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$OutputPath,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Title = 'Primary User Audit Dashboard'
    )

    if (-not $InputObject -or $InputObject.Count -eq 0) {
        throw 'InputObject does not contain any audit records.'
    }

    $OutputDirectory = Split-Path -Path $OutputPath -Parent

    if (-not [string]::IsNullOrWhiteSpace($OutputDirectory)) {
        $null = New-Item `
            -Path $OutputDirectory `
            -ItemType Directory `
            -Force
    }

    function ConvertTo-HtmlSafeValue {
        param (
            [AllowNull()]
            [object]$Value
        )

        if ($null -eq $Value) {
            return ''
        }

        return [System.Net.WebUtility]::HtmlEncode([string]$Value)
    }

    $TotalCount = $InputObject.Count

    $ActionCounts = @{}

    foreach ($Action in @(
        'NoChange',
        'Change',
        'Assign',
        'Review',
        'NoEvidence'
    )) {
        $ActionCounts[$Action] = @(
            $InputObject |
                Where-Object RecommendedAction -eq $Action
        ).Count
    }

    $GeneratedAt = Get-Date -Format 'MMMM d, yyyy h:mm tt'

    $Rows = foreach ($Record in $InputObject) {
        $Action = [string]$Record.RecommendedAction

        $ActionClass = switch ($Action) {
            'NoChange'     { 'nochange' }
            'Change'       { 'change' }
            'Assign'       { 'assign' }
            'Review' { 'manualreview' }
            'NoEvidence'   { 'noevidence' }
            default        { 'unknown' }
        }

        $DeviceName               = ConvertTo-HtmlSafeValue $Record.DeviceName
        $CurrentUserName          = ConvertTo-HtmlSafeValue $Record.CurrentUserName
        $CurrentUserPrincipal     = ConvertTo-HtmlSafeValue $Record.CurrentUserPrincipal
        $RecommendedUserName      = ConvertTo-HtmlSafeValue $Record.RecommendedUserName
        $RecommendedUserPrincipal = ConvertTo-HtmlSafeValue $Record.RecommendedUserPrincipal
        $Confidence               = ConvertTo-HtmlSafeValue $Record.Confidence
        $DominancePercent         = ConvertTo-HtmlSafeValue $Record.DominancePercent
        $TotalSignIns             = ConvertTo-HtmlSafeValue $Record.TotalSignIns
        $SerialNumber             = ConvertTo-HtmlSafeValue $Record.SerialNumber
        $Manufacturer             = ConvertTo-HtmlSafeValue $Record.Manufacturer
        $Model                    = ConvertTo-HtmlSafeValue $Record.Model
        $ComplianceState          = ConvertTo-HtmlSafeValue $Record.ComplianceState
        $LastSyncDateTime         = ConvertTo-HtmlSafeValue $Record.LastSyncDateTime
        $Reason                   = ConvertTo-HtmlSafeValue $Record.Reason
        $SafeAction               = ConvertTo-HtmlSafeValue $Action

        @"
<tr class="audit-row $ActionClass" data-action="$SafeAction">
    <td>
        <button class="expand-button" type="button" aria-label="Show device details">+</button>
    </td>
    <td>$DeviceName</td>
    <td>$CurrentUserName</td>
    <td>$RecommendedUserName</td>
    <td>$DominancePercent%</td>
    <td>$Confidence</td>
    <td><span class="status $ActionClass">$SafeAction</span></td>
    <td>$Reason</td>
</tr>
<tr class="detail-row $ActionClass" data-action="$SafeAction">
    <td colspan="8">
        <div class="detail-grid">
            <div><strong>Device:</strong><br>$DeviceName</div>
            <div><strong>Serial number:</strong><br>$SerialNumber</div>
            <div><strong>Manufacturer:</strong><br>$Manufacturer</div>
            <div><strong>Model:</strong><br>$Model</div>
            <div><strong>Compliance:</strong><br>$ComplianceState</div>
            <div><strong>Last sync:</strong><br>$LastSyncDateTime</div>
            <div><strong>Current user:</strong><br>$CurrentUserName<br>$CurrentUserPrincipal</div>
            <div><strong>Recommended user:</strong><br>$RecommendedUserName<br>$RecommendedUserPrincipal</div>
            <div><strong>Total qualifying sign-ins:</strong><br>$TotalSignIns</div>
            <div><strong>Dominance:</strong><br>$DominancePercent%</div>
            <div><strong>Confidence:</strong><br>$Confidence</div>
            <div><strong>Reason:</strong><br>$Reason</div>
        </div>
    </td>
</tr>
"@
    }

    $Template = @'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>__TITLE__</title>

    <style>
        :root {
            color-scheme: dark;
            font-family: "Segoe UI", Arial, sans-serif;
        }

        * {
            box-sizing: border-box;
        }

        body {
            margin: 0;
            background: #0f172a;
            color: #e5e7eb;
        }

        header {
            padding: 28px 32px;
            background: #111827;
            border-bottom: 1px solid #334155;
        }

        h1 {
            margin: 0 0 8px;
            font-size: 30px;
        }

        .subtitle {
            color: #94a3b8;
        }

        main {
            padding: 24px 32px 40px;
        }

        .cards {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
            gap: 14px;
            margin-bottom: 24px;
        }

        .card {
            padding: 18px;
            background: #1e293b;
            border: 1px solid #334155;
            border-radius: 10px;
        }

        .card-label {
            color: #94a3b8;
            font-size: 13px;
            text-transform: uppercase;
        }

        .card-value {
            margin-top: 5px;
            font-size: 30px;
            font-weight: 700;
        }

        .controls {
            display: flex;
            flex-wrap: wrap;
            gap: 10px;
            margin-bottom: 18px;
        }

        input,
        button {
            border: 1px solid #475569;
            border-radius: 7px;
            background: #1e293b;
            color: #e5e7eb;
        }

        input {
            min-width: 270px;
            padding: 10px 12px;
        }

        button {
            padding: 9px 12px;
            cursor: pointer;
        }

        button:hover,
        button.active {
            background: #2563eb;
            border-color: #3b82f6;
        }

        .table-container {
            overflow-x: auto;
            background: #111827;
            border: 1px solid #334155;
            border-radius: 10px;
        }

        table {
            width: 100%;
            border-collapse: collapse;
            min-width: 1050px;
        }

        th,
        td {
            padding: 12px 14px;
            text-align: left;
            border-bottom: 1px solid #263449;
        }

        th {
            position: sticky;
            top: 0;
            background: #1e293b;
            color: #cbd5e1;
            cursor: pointer;
        }

        tbody tr.audit-row:hover {
            background: #172033;
        }

        .status {
            display: inline-block;
            padding: 5px 9px;
            border-radius: 999px;
            font-weight: 600;
            white-space: nowrap;
        }

        .status.nochange {
            background: #14532d;
            color: #bbf7d0;
        }

        .status.change {
            background: #7f1d1d;
            color: #fecaca;
        }

        .status.assign {
            background: #1e3a8a;
            color: #bfdbfe;
        }

        .status.manualreview {
            background: #78350f;
            color: #fde68a;
        }

        .status.noevidence {
            background: #374151;
            color: #d1d5db;
        }

        .detail-row {
            display: none;
            background: #0b1220;
        }

        .detail-row.visible {
            display: table-row;
        }

        .detail-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
            gap: 16px;
            padding: 14px;
        }

        .detail-grid > div {
            padding: 12px;
            background: #172033;
            border-radius: 7px;
        }

        .expand-button {
            width: 30px;
            height: 30px;
            padding: 0;
            font-size: 18px;
        }

        .hidden {
            display: none !important;
        }

        footer {
            padding-top: 20px;
            color: #64748b;
            font-size: 13px;
        }

        @media print {
            .controls,
            .expand-button {
                display: none;
            }

            body {
                background: white;
                color: black;
            }

            .table-container,
            header,
            .card {
                border-color: #cccccc;
            }
        }
    </style>
</head>

<body>
<header>
    <h1>__TITLE__</h1>
    <div class="subtitle">
        Generated __GENERATED_AT__
    </div>
</header>

<main>
    <section class="cards">
        <div class="card">
            <div class="card-label">Devices</div>
            <div class="card-value">__TOTAL__</div>
        </div>

        <div class="card">
            <div class="card-label">No Change</div>
            <div class="card-value">__NO_CHANGE__</div>
        </div>

        <div class="card">
            <div class="card-label">Change</div>
            <div class="card-value">__CHANGE__</div>
        </div>

        <div class="card">
            <div class="card-label">Assign</div>
            <div class="card-value">__ASSIGN__</div>
        </div>

        <div class="card">
            <div class="card-label">Manual Review</div>
            <div class="card-value">__MANUAL_REVIEW__</div>
        </div>

        <div class="card">
            <div class="card-label">No Evidence</div>
            <div class="card-value">__NO_EVIDENCE__</div>
        </div>
    </section>

    <section class="controls">
        <input id="searchBox" type="search" placeholder="Search devices or users">

        <button type="button" class="filter-button active" data-filter="All">All</button>
        <button type="button" class="filter-button" data-filter="Change">Change</button>
        <button type="button" class="filter-button" data-filter="Assign">Assign</button>
        <button type="button" class="filter-button" data-filter="Review">Manual review</button>
        <button type="button" class="filter-button" data-filter="NoEvidence">No evidence</button>
        <button type="button" class="filter-button" data-filter="NoChange">No change</button>
        <button type="button" onclick="window.print()">Print</button>
    </section>

    <section class="table-container">
        <table id="auditTable">
            <thead>
                <tr>
                    <th></th>
                    <th>Device</th>
                    <th>Current user</th>
                    <th>Recommended user</th>
                    <th>Dominance</th>
                    <th>Confidence</th>
                    <th>Action</th>
                    <th>Reason</th>
                </tr>
            </thead>

            <tbody>
                __TABLE_ROWS__
            </tbody>
        </table>
    </section>

    <footer>
        Primary User Audit is operating in audit-only mode. No Intune assignments were modified.
    </footer>
</main>

<script>
    const searchBox = document.getElementById('searchBox');
    const filterButtons = document.querySelectorAll('.filter-button');
    const auditRows = document.querySelectorAll('.audit-row');

    let activeFilter = 'All';

    function applyFilters() {
        const searchValue = searchBox.value.toLowerCase();

        auditRows.forEach(row => {
            const action = row.dataset.action;
            const detailRow = row.nextElementSibling;
            const matchesFilter = activeFilter === 'All' || action === activeFilter;
            const matchesSearch = row.innerText.toLowerCase().includes(searchValue);
            const shouldShow = matchesFilter && matchesSearch;

            row.classList.toggle('hidden', !shouldShow);

            if (!shouldShow) {
                detailRow.classList.remove('visible');
                row.querySelector('.expand-button').textContent = '+';
            }
        });
    }

    searchBox.addEventListener('input', applyFilters);

    filterButtons.forEach(button => {
        button.addEventListener('click', () => {
            filterButtons.forEach(item => item.classList.remove('active'));
            button.classList.add('active');
            activeFilter = button.dataset.filter;
            applyFilters();
        });
    });

    document.querySelectorAll('.expand-button').forEach(button => {
        button.addEventListener('click', () => {
            const auditRow = button.closest('.audit-row');
            const detailRow = auditRow.nextElementSibling;
            const visible = detailRow.classList.toggle('visible');

            button.textContent = visible ? '−' : '+';
        });
    });

    document.querySelectorAll('#auditTable th').forEach((header, columnIndex) => {
        if (columnIndex === 0) {
            return;
        }

        header.addEventListener('click', () => {
            const tableBody = document.querySelector('#auditTable tbody');
            const pairs = [];

            document.querySelectorAll('.audit-row').forEach(row => {
                pairs.push({
                    audit: row,
                    detail: row.nextElementSibling
                });
            });

            const ascending = header.dataset.sort !== 'asc';

            pairs.sort((left, right) => {
                const leftValue =
                    left.audit.children[columnIndex].innerText.trim();

                const rightValue =
                    right.audit.children[columnIndex].innerText.trim();

                return ascending
                    ? leftValue.localeCompare(rightValue, undefined, { numeric: true })
                    : rightValue.localeCompare(leftValue, undefined, { numeric: true });
            });

            pairs.forEach(pair => {
                tableBody.appendChild(pair.audit);
                tableBody.appendChild(pair.detail);
            });

            header.dataset.sort = ascending ? 'asc' : 'desc';
        });
    });
</script>
</body>
</html>
'@

    $Html = $Template.
        Replace('__TITLE__', (ConvertTo-HtmlSafeValue $Title)).
        Replace('__GENERATED_AT__', (ConvertTo-HtmlSafeValue $GeneratedAt)).
        Replace('__TOTAL__', [string]$TotalCount).
        Replace('__NO_CHANGE__', [string]$ActionCounts.NoChange).
        Replace('__CHANGE__', [string]$ActionCounts.Change).
        Replace('__ASSIGN__', [string]$ActionCounts.Assign).
        Replace('__MANUAL_REVIEW__', [string]$ActionCounts.Review).
        Replace('__NO_EVIDENCE__', [string]$ActionCounts.NoEvidence).
        Replace('__TABLE_ROWS__', ($Rows -join [Environment]::NewLine))

    Set-Content `
        -Path $OutputPath `
        -Value $Html `
        -Encoding utf8

    Get-Item -Path $OutputPath
}
