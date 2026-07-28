# O365 Management Toolkit Architecture

## Purpose

The O365 Management Toolkit provides reusable PowerShell automation for Microsoft 365, Entra ID, Intune, Exchange Online, Active Directory, reporting, and user lifecycle management.

## Design Principles

1\. Configuration-driven behavior

2\. Safe defaults

3\. Supports WhatIf and Confirm

4\. Structured logging

5\. Reusable reporting

6\. Microsoft Graph retry handling

7\. Automated Pester testing

8\. No credentials stored in source control

## Repository Structure

```text

O365-Management

│

├── Core

│   ├── Public

│   ├── Private

│   ├── tests

│   ├── O365Toolkit.Core.psd1

│   └── O365Toolkit.Core.psm1

│

├── Modules

│   ├── UserLifecycle

│   ├── Intune

│   ├── Entra

│   ├── Exchange

│   ├── Licensing

│   ├── Reporting

│   └── Security

│

├── PrimaryUserAudit\_Share

│

├── config

├── docs

├── logs

├── reports

└── .github

&#x20;   └── workflows

```
