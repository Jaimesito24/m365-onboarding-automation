# Next steps

Temporary notes for picking this project up on another computer. Delete this file once the first task in `CLAUDE.md` is finished.

## Where things stand (2026-11-16)

- Done: step 2 of the first task in `CLAUDE.md`. The three scripts in `scripts/` are written.
- Not done yet: the scripts have **not been run or linted**. PowerShell 7 wasn't installed on the Mac.
- Nothing has been committed or pushed yet.
- No Microsoft 365 tenant yet. That's fine: steps 3 to 6 don't need one, because the tests never connect to a tenant.

## 1. Before leaving the Mac: commit and push

Run these from the project folder. Without this, the PC won't have the code.

```bash
git add CLAUDE.md
git commit -m "Add project instructions"

git add scripts/LabCommon.ps1
git commit -m "Add shared helpers for logging, Graph sign-in, and retries"

git add scripts/Onboard-User.ps1
git commit -m "Add onboarding script with pre-checks and -WhatIf support"

git add scripts/Offboard-User.ps1
git commit -m "Add offboarding script with audit log and safe re-runs"

git add NEXT-STEPS.md
git commit -m "Add notes for the remaining setup steps"

gh repo create m365-onboarding-automation --public --source . --push
```

Optional, before the first commit: the repo is public, so every commit shows the email from your Git settings. To hide it, use GitHub's noreply address (GitHub > Settings > Emails), then run `git config user.email "<your-noreply-address>"`.

## 2. Set up the PC (Windows)

Open **Windows Terminal** and install the tools:

```powershell
winget install --id Microsoft.PowerShell --source winget
winget install --id Git.Git --source winget
winget install --id GitHub.cli --source winget
winget install --id Microsoft.VisualStudioCode --source winget
```

Close and reopen the terminal, then sign in to GitHub and get the code:

```powershell
gh auth login
gh repo clone <your-github-username>/m365-onboarding-automation
cd m365-onboarding-automation
git config user.name "<your-name>"
git config user.email "<your-email-or-noreply-address>"
```

Open **PowerShell 7** (`pwsh`, not the older "Windows PowerShell") and install the test and lint tools:

```powershell
Install-Module Pester -MinimumVersion 5.0 -Force -SkipPublisherCheck -Scope CurrentUser
Install-Module PSScriptAnalyzer -Scope CurrentUser
```

Why `-SkipPublisherCheck`: Windows comes with an old Pester 3.4 signed by a different publisher, and without this flag the install of Pester 5 refuses to replace it.

In VS Code, install the **PowerShell** and **Claude Code** extensions, then open the project folder.

## 3. First thing on the PC: lint the scripts

The scripts have never been through the linter. Run this in `pwsh` from the project folder:

```powershell
Invoke-ScriptAnalyzer -Path ./scripts -Recurse
```

No output means no warnings. If anything shows up, fix it before moving on.

## 4. Remaining steps from the first task

Do one at a time, review, and commit after each.

- [ ] **Step 3: `.gitignore`** with `logs/` and `*.log`.
- [ ] **Step 4: Pester tests** in `tests/Onboard-User.Tests.ps1` and `tests/Offboard-User.Tests.ps1`. Already decided:
  - Run each test against a copy of `scripts/` in Pester's `TestDrive:` folder. The log then lands in `TestDrive:/logs`, where the test can read it, and the real `logs/` folder stays clean.
  - Define empty stand-in functions (for example `function Get-MgUser {}`) before mocking each Graph command. Pester can only mock a command that exists, and this way CI doesn't need the Graph modules installed.
  - Mock `Start-Sleep` so the retry tests don't wait 5 seconds per try.
  - Tests required by `CLAUDE.md`:
    - `-WhatIf` makes no changes.
    - Onboarding creates nothing when a group is missing.
    - Onboarding creates nothing when the license has no free seats.
    - Onboarding creates nothing when the user already exists.
    - Offboarding blocks sign-in before it revokes sessions.
    - Offboarding skips dynamic groups.
    - The temporary password never appears in the log file.
  - Run them with `Invoke-Pester -Path ./tests -Output Detailed`.
- [ ] **Step 5: CI workflow** in `.github/workflows/ci.yml`. It runs on `ubuntu-latest`, installs Pester and PSScriptAnalyzer, runs the analyzer on `scripts/`, then runs `Invoke-Pester`. The build fails on any warning or failed test.
- [ ] **Step 6: docs.** Draft `docs/runbook.md` and `README.md` as described in `CLAUDE.md`. The "What I learned" section is yours to write.

## 5. Later: set up the lab tenant and run the scripts for real

1. Sign up for a **Microsoft 365 Business Premium** free trial. This creates a `<your-domain>.onmicrosoft.com` tenant.
2. In the Microsoft 365 admin center, create a group named **Lab-AllStaff**.
3. In Teams, create a team named **Lab Onboarding Team**.
4. Install only the Graph modules the scripts need:

   ```powershell
   Install-Module Microsoft.Graph.Authentication, Microsoft.Graph.Users, Microsoft.Graph.Users.Actions, Microsoft.Graph.Groups, Microsoft.Graph.Identity.DirectoryManagement -Scope CurrentUser
   ```

5. Always preview first:

   ```powershell
   ./scripts/Onboard-User.ps1 -FirstName Alex -LastName Example -Department Sales -WhatIf
   ```

6. If the preview looks right, run the same command without `-WhatIf`. Then try offboarding the same way, starting with `-WhatIf`.
7. Take screenshots for `docs/screenshots/`. The log shows the tenant ID, so blur it first.

## Ideas left out on purpose (possible improvements, good interview talking points)

- Onboarding doesn't check whether a target group is dynamic. Adding a member to one fails after the user is already created.
- Offboarding doesn't handle distribution lists or mail-enabled security groups. Graph can't change their members; they're managed in Exchange.
- Listing the same group twice in `-Groups` (or repeating the team name) makes the second add fail.
- If `first.last` already exists, onboarding stops. A production version would try `first.last2` and so on.

## How to restart Claude Code on the PC

Claude's memory from the Mac doesn't carry over, so start with:

> Read CLAUDE.md and NEXT-STEPS.md. The scripts are written but haven't been linted. Start with the lint, then do step 3.
