# Primary User Audit

A PowerShell module that analyzes Microsoft Intune managed Windows devices and Microsoft Entra sign-in evidence to recommend the most appropriate primary user for each device.

The module is currently audit-only. It generates recommendations and reports but does not modify primary-user assignments.

## Features

- Connects to Microsoft Graph
- Retrieves Intune-managed Windows devices
- Collects device sign-in evidence
- Compares current and observed users
- Calculates user dominance percentages
- Identifies devices with no usable evidence
- Recommends primary-user assignment changes
- Flags ambiguous devices for manual review
- Exports results to CSV
- Includes Pester automated tests
- Includes GitHub Actions continuous integration

## Project Structure

```text
PrimaryUserAudit_Share/
├── Private/
├── Public/
├── tests/
├── PrimaryUserAudit.psd1
├── PrimaryUserAudit.psm1
└── README.md
