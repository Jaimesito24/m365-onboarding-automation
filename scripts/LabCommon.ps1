<#
.SYNOPSIS
    Shared helpers for Onboard-User.ps1 and Offboard-User.ps1.

.DESCRIPTION
    Dot-source this file from a script. It provides:
      - Start-LabLog and Write-Log: one log file per run, with the same lines shown on screen.
      - Connect-Lab: signs in to Microsoft Graph only when it is needed.
      - Invoke-WithRetry: retries a step that can fail while a new user is still being set up.

    Both scripts share this file so they log, sign in, and retry the same way.
    A fix made here fixes both scripts.
#>

# Delegated permissions the scripts ask for. Chosen to cover only what the scripts do,
# instead of a broad permission like Directory.ReadWrite.All.
$script:RequiredScopes = @(
    'User.ReadWrite.All'
    'Group.ReadWrite.All'
    'GroupMember.Read.All'
    'Organization.Read.All'
)

# Set by Start-LabLog. Write-Log only writes to a file once this has a value.
$script:LogFile = $null

function Start-LabLog {
    <#
    .SYNOPSIS
        Creates logs/<Name>-<yyyyMMdd-HHmmss>.log for this run.
    #>
    # PSScriptAnalyzer expects Start-* functions to support -WhatIf. This one must not:
    # a preview run still needs its log, and creating a local file changes nothing in the tenant.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'The log must be written even during a -WhatIf preview.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    $logFolder = Join-Path -Path $repoRoot -ChildPath 'logs'
    $fileName = '{0}-{1}.log' -f $Name, (Get-Date -Format 'yyyyMMdd-HHmmss')

    # -WhatIf:$false and -Confirm:$false stop a -WhatIf or -Confirm run of the main script
    # from skipping or prompting for the log itself.
    New-Item -Path $logFolder -ItemType Directory -Force -WhatIf:$false -Confirm:$false | Out-Null
    $script:LogFile = Join-Path -Path $logFolder -ChildPath $fileName
    New-Item -Path $script:LogFile -ItemType File -Force -WhatIf:$false -Confirm:$false | Out-Null

    Write-Log "Log file: $script:LogFile"
}

function Write-Log {
    <#
    .SYNOPSIS
        Writes one timestamped line to the screen and to the log file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    # Write-Information instead of Write-Host: it shows on screen the same way, but it can be
    # captured or silenced by the caller, and PSScriptAnalyzer does not flag it.
    Write-Information -MessageData $line -InformationAction Continue

    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value $line -WhatIf:$false -Confirm:$false
    }
}

function Connect-Lab {
    <#
    .SYNOPSIS
        Signs in to Microsoft Graph, reusing the current session when it already has every required scope.
    #>
    [CmdletBinding()]
    param()

    $context = Get-MgContext
    $missingScopes = if ($context) {
        @($script:RequiredScopes | Where-Object { $_ -notin $context.Scopes })
    }
    else {
        $script:RequiredScopes
    }

    # Reusing a good session avoids a sign-in prompt on every run.
    if ($missingScopes) {
        Write-Log 'Signing in to Microsoft Graph...'
        Connect-MgGraph -Scopes $script:RequiredScopes -NoWelcome
        $context = Get-MgContext
    }

    # Logged so every run records which tenant and which admin account made the changes.
    Write-Log "Connected to tenant $($context.TenantId) as $($context.Account)."
}

function Invoke-WithRetry {
    <#
    .SYNOPSIS
        Runs a script block and retries it if it fails.
    .DESCRIPTION
        A brand-new user can take a few seconds to appear in every Microsoft 365 service.
        During that time, assigning a license or adding a group member can fail with
        "not found" even though the user exists. Waiting and trying again fixes that.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Action,

        [Parameter(Mandatory)]
        [string]$Description,

        [int]$MaxAttempts = 5,

        [int]$DelaySeconds = 5
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return & $Action
        }
        catch {
            if ($attempt -eq $MaxAttempts) {
                Write-Log -Level WARN "$Description failed $MaxAttempts times. Giving up."
                throw
            }
            Write-Log -Level WARN "$Description failed (attempt $attempt of $MaxAttempts): $($_.Exception.Message) Retrying in $DelaySeconds seconds."
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}
