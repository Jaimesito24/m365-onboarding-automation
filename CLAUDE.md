# M365 Onboarding Automation (Home Lab)

PowerShell scripts that onboard and offboard a Microsoft 365 user in one command using Microsoft Graph. Built in a home lab on a Microsoft 365 Business Premium trial tenant to practice Microsoft 365 administration and automation for systems administrator and platform roles.

## How I want you to work

- I will be interviewed on this code. Keep it easy to read, and explain each decision in plain words: what it does and why it was done this way instead of another way.
- Work in small steps. After each step, tell me what changed and suggest a commit message. Small commits, not one giant one.
- Ask before changing the repo structure, adding a dependency, or changing a script's parameters.
- Never run anything against my tenant yourself. Give me the command, starting with a `-WhatIf` preview, and I will run it.
- Never put secrets, passwords, tenant IDs, or real people's names in code, docs, commits, or test data. Use placeholders like `<your-domain>.onmicrosoft.com`.

## Tech stack

| Component | Purpose |
| --- | --- |
| PowerShell 7 | Runtime. Target 7.x only, not Windows PowerShell 5.1 |
| Microsoft.Graph.Authentication | `Connect-MgGraph`, `Get-MgContext` |
| Microsoft.Graph.Users | `New-MgUser`, `Get-MgUser`, `Update-MgUser`, `Remove-MgUser`, `Get-MgUserMemberOf`, `Get-MgUserLicenseDetail` |
| Microsoft.Graph.Users.Actions | `Set-MgUserLicense`, `Revoke-MgUserSignInSession` |
| Microsoft.Graph.Groups | `Get-MgGroup`, `New-MgGroupMember`, `Remove-MgGroupMemberByRef` |
| Microsoft.Graph.Identity.DirectoryManagement | `Get-MgSubscribedSku`, `Get-MgOrganization` |
| Pester 5 | Unit tests, with every Graph command mocked |
| PSScriptAnalyzer | Linting |
| GitHub Actions | CI: lint and test on every push and pull request |

Install only the Graph submodules listed above, not the full `Microsoft.Graph` module. It installs faster, and the README should explain that choice.

## Repo layout

```
scripts/
  LabCommon.ps1         shared helpers: logging, sign-in, retries
  Onboard-User.ps1
  Offboard-User.ps1
tests/
  Onboard-User.Tests.ps1
  Offboard-User.Tests.ps1
docs/
  runbook.md            how an admin runs onboarding and offboarding, step by step
  screenshots/          added by me after testing in the tenant
logs/                   one log file per run; ignored by Git
.github/workflows/ci.yml
.gitignore
README.md
CLAUDE.md
```

## What the scripts do

### LabCommon.ps1 (dot-sourced by both scripts)

- `$script:RequiredScopes`: `User.ReadWrite.All`, `Group.ReadWrite.All`, `GroupMember.Read.All`, `Organization.Read.All`
- `Start-LabLog -Name`: creates `logs/<name>-<yyyyMMdd-HHmmss>.log`
- `Write-Log -Message -Level INFO|WARN|ERROR`: one timestamped line to the screen and the log file
- `Connect-Lab`: calls `Connect-MgGraph` only if there is no session or a scope is missing; logs the tenant and account
- `Invoke-WithRetry -Action -Description`: up to 5 tries, 5 seconds apart, because a brand-new user can take a few seconds to appear everywhere

### Onboard-User.ps1

Parameters: `-FirstName`, `-LastName` (required), `-Department`, `-JobTitle`, `-UsageLocation` (default `US`), `-LicenseSku` (default `SPB`, Business Premium), `-Groups` (default `Lab-AllStaff`), `-TeamName` (default `Lab Onboarding Team`).

1. Build the sign-in name as `first.last@<default domain>`, lowercase, letters, digits and dots only.
2. Run every check before any change: the user doesn't already exist, the license exists and has a free seat, and each group and the team match exactly one group by display name. Any failed check stops the script with nothing changed.
3. Create the user with `UsageLocation` set (license assignment fails without it), a random 16-character temporary password, and a forced change at first sign-in.
4. Assign the license (inside `Invoke-WithRetry`).
5. Add the user to each group and to the team. A team is a Microsoft 365 group, so the team is added with `New-MgGroupMember` like any other group (inside `Invoke-WithRetry`).
6. Print the temporary password to the screen only. Never log it.

### Offboard-User.ps1

Parameters: `-UserPrincipalName` (required), `-DeleteUser` (switch).

1. Block sign-in (`AccountEnabled = $false`).
2. Revoke sign-in sessions. Block first, then revoke, following Microsoft's guidance.
3. Log the user's groups and licenses before removing anything. This is the audit trail.
4. Remove every group membership, including the team. Skip dynamic groups with a WARN line.
5. Remove all directly assigned licenses.
6. If `-DeleteUser` is set, delete the user (a soft delete, restorable for 30 days).
7. Running it twice on the same user must finish cleanly.

## Design rules to keep

- `[CmdletBinding(SupportsShouldProcess)]` on both scripts, and every change wrapped in `$PSCmdlet.ShouldProcess`, so `-WhatIf` previews everything.
- Logging commands use `-WhatIf:$false`, so a preview run still writes its log.
- `$ErrorActionPreference = 'Stop'`, with a `try`/`catch` that logs the error and rethrows it.
- Comment-based help (`.SYNOPSIS`, `.DESCRIPTION`, `.EXAMPLE`) at the top of each script.
- Approved PowerShell verbs only (`Get-Verb`), and PSScriptAnalyzer must pass with no warnings.
- Comments explain why, not what.

## Testing and CI

- Pester 5 tests mock every `Mg` command and never touch a real tenant.
- Test at least: `-WhatIf` makes no changes; onboarding stops before creating anything when a group is missing, the license has no free seats, or the user already exists; offboarding blocks sign-in before revoking sessions; offboarding skips dynamic groups; the temporary password never appears in the log file.
- `.github/workflows/ci.yml` runs on `ubuntu-latest`, installs Pester and PSScriptAnalyzer, runs the analyzer on `scripts/`, then runs `Invoke-Pester`. The build fails on any analyzer warning or failed test.

## Docs

- `README.md`: what it does, demo screenshots, how to run, design decisions, the permissions table, what I'd add for production (app-only sign-in with a certificate run from Azure Automation, HR CSV input, Temporary Access Pass, mailbox and OneDrive handoff on offboarding), and a "What I learned" section that I'll write myself.
- `docs/runbook.md`: written for an admin on a ticket queue. Prerequisites, how to preview, how to run, how to verify in the Microsoft 365, Entra, and Teams admin centers, and what to do for each common error.

## First task

1. If `scripts/` already has the three scripts, review them against this file and list anything that doesn't match. Don't rewrite them unless I agree.
2. If it doesn't, create them to match this file.
3. Add `.gitignore` (`logs/`, `*.log`).
4. Add the Pester tests and get them passing.
5. Add the CI workflow.
6. Draft `docs/runbook.md` and `README.md`.

Stop after each numbered step so I can review it and commit.
