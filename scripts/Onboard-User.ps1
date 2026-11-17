#Requires -Version 7.0

<#
.SYNOPSIS
    Onboards a new Microsoft 365 user in one command.

.DESCRIPTION
    Creates the user, assigns a license, and adds the user to groups and a team, using
    Microsoft Graph. Every check runs before any change, so a failed check leaves the
    tenant untouched. Run with -WhatIf first to preview every change without making it.

    The temporary password is shown on screen once and is never written to the log.

.PARAMETER FirstName
    The user's first name. Used for the display name and the sign-in name.

.PARAMETER LastName
    The user's last name. Used for the display name and the sign-in name.

.PARAMETER Department
    Optional. The user's department.

.PARAMETER JobTitle
    Optional. The user's job title.

.PARAMETER UsageLocation
    Two-letter country code, for example US. Microsoft 365 cannot assign a license without it.

.PARAMETER LicenseSku
    The license's SKU part number. SPB is Microsoft 365 Business Premium.

.PARAMETER Groups
    Display names of the groups to add the user to.

.PARAMETER TeamName
    Display name of the team to add the user to.

.EXAMPLE
    ./scripts/Onboard-User.ps1 -FirstName Alex -LastName Example -Department Sales -WhatIf

    Previews onboarding alex.example@<your-domain>.onmicrosoft.com. Nothing is changed.

.EXAMPLE
    ./scripts/Onboard-User.ps1 -FirstName Alex -LastName Example -Department Sales -JobTitle 'Account Manager'

    Creates the user, assigns Business Premium, and adds the user to Lab-AllStaff and Lab Onboarding Team.

.EXAMPLE
    ./scripts/Onboard-User.ps1 -FirstName Alex -LastName Example -Groups 'Lab-AllStaff', 'Lab-Sales'

    Adds the user to two groups instead of the default one.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$FirstName,

    [Parameter(Mandatory)]
    [string]$LastName,

    [string]$Department,

    [string]$JobTitle,

    [ValidatePattern('^[A-Z]{2}$')]
    [string]$UsageLocation = 'US',

    [string]$LicenseSku = 'SPB',

    [string[]]$Groups = @('Lab-AllStaff'),

    [string]$TeamName = 'Lab Onboarding Team'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/LabCommon.ps1"

function ConvertTo-UpnPart {
    <#
    .SYNOPSIS
        Turns a name into the lowercase letters and digits used in a sign-in name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    # Splitting each accented letter into "letter + accent mark" and dropping the marks turns
    # an accented e into a plain e, instead of deleting the letter entirely.
    $withoutAccents = $Name.Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', ''
    $withoutAccents.ToLowerInvariant() -replace '[^a-z0-9]', ''
}

function Get-RandomPassword {
    <#
    .SYNOPSIS
        Returns a random password that meets the Microsoft Entra ID complexity rules.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [int]$Length = 16
    )

    # Look-alike characters (0 and O, 1 and l and I) are left out, so the password
    # is easy to read out to a new hire.
    $characterSets = @(
        'ABCDEFGHJKLMNPQRSTUVWXYZ'
        'abcdefghijkmnopqrstuvwxyz'
        '23456789'
        '!@#$%^&*-_=+?'
    )
    $allCharacters = -join $characterSets

    # RandomNumberGenerator is a cryptographically secure source. Get-Random is not meant
    # for secrets, so it is not used here.
    $rng = [System.Security.Cryptography.RandomNumberGenerator]

    # One character from each set guarantees uppercase, lowercase, digit, and symbol.
    $chars = [System.Collections.Generic.List[char]]::new()
    foreach ($set in $characterSets) {
        $chars.Add($set[$rng::GetInt32($set.Length)])
    }
    while ($chars.Count -lt $Length) {
        $chars.Add($allCharacters[$rng::GetInt32($allCharacters.Length)])
    }

    # Shuffle (Fisher-Yates) so the guaranteed characters are not always the first four.
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = $rng::GetInt32($i + 1)
        $chars[$i], $chars[$j] = $chars[$j], $chars[$i]
    }

    -join $chars
}

Start-LabLog -Name 'onboard'

# Declared before try so that catch and finally can tell whether the user was created.
$newUser = $null
$password = $null
$upn = $null

try {
    Connect-Lab

    # Step 1: build the sign-in name (first.last@<default domain>).
    $firstPart = ConvertTo-UpnPart -Name $FirstName
    $lastPart = ConvertTo-UpnPart -Name $LastName
    if (-not $firstPart -or -not $lastPart) {
        throw "Could not build a sign-in name from '$FirstName $LastName'. Each name needs at least one letter (a-z) or digit."
    }

    $organization = Get-MgOrganization
    $defaultDomain = ($organization.VerifiedDomains | Where-Object { $_.IsDefault }).Name
    $mailNickname = "$firstPart.$lastPart"
    $upn = "$mailNickname@$defaultDomain"
    Write-Log "Onboarding $FirstName $LastName as $upn."

    # Step 2: run every check before changing anything.
    # Problems are collected instead of stopping at the first one, so the admin sees
    # everything that needs fixing after a single run.
    $problems = [System.Collections.Generic.List[string]]::new()

    if (Get-MgUser -Filter "userPrincipalName eq '$upn'") {
        $problems.Add("A user with the sign-in name $upn already exists.")
    }

    $sku = Get-MgSubscribedSku | Where-Object { $_.SkuPartNumber -eq $LicenseSku }
    if (-not $sku) {
        $problems.Add("License $LicenseSku was not found in this tenant.")
    }
    else {
        $freeSeats = $sku.PrepaidUnits.Enabled - $sku.ConsumedUnits
        if ($freeSeats -lt 1) {
            $problems.Add("License $LicenseSku has no free seats ($($sku.ConsumedUnits) of $($sku.PrepaidUnits.Enabled) in use).")
        }
    }

    # A team is a Microsoft 365 group, so it is looked up and added exactly like a group.
    $targetGroups = [System.Collections.Generic.List[object]]::new()
    foreach ($groupName in @($Groups) + $TeamName) {
        # Single quotes are doubled because the name goes inside a quoted OData filter.
        $escapedName = $groupName -replace "'", "''"
        $found = @(Get-MgGroup -Filter "displayName eq '$escapedName'" -All)

        if ($found.Count -eq 1) {
            $targetGroups.Add($found[0])
        }
        elseif ($found.Count -eq 0) {
            $problems.Add("Group '$groupName' was not found.")
        }
        else {
            # Display names are not unique in Microsoft 365. Guessing could add the user to the wrong group.
            $problems.Add("Group name '$groupName' matches $($found.Count) groups. Rename them so the name is unique.")
        }
    }

    if ($problems.Count -gt 0) {
        foreach ($problem in $problems) {
            Write-Log -Level ERROR $problem
        }
        throw "Stopped before making any changes: $($problems.Count) check(s) failed."
    }
    Write-Log 'All checks passed.'

    # Step 3: create the user.
    if ($PSCmdlet.ShouldProcess($upn, 'Create user')) {
        $password = Get-RandomPassword -Length 16
        $userParams = @{
            AccountEnabled    = $true
            DisplayName       = "$FirstName $LastName"
            GivenName         = $FirstName
            Surname           = $LastName
            MailNickname      = $mailNickname
            UserPrincipalName = $upn
            # Set at creation because Microsoft 365 refuses to assign a license to a user without one.
            UsageLocation     = $UsageLocation.ToUpperInvariant()
            PasswordProfile   = @{
                Password                      = $password
                ForceChangePasswordNextSignIn = $true
            }
        }
        # Optional fields are only sent when given, so the user does not end up with empty values.
        if ($Department) { $userParams.Department = $Department }
        if ($JobTitle) { $userParams.JobTitle = $JobTitle }

        $newUser = New-MgUser @userParams
        Write-Log "Created user $upn (id $($newUser.Id))."
    }

    # Step 4: assign the license. Retried because the new user may not be visible yet.
    if ($PSCmdlet.ShouldProcess($upn, "Assign license $LicenseSku")) {
        Invoke-WithRetry -Description "Assign license $LicenseSku" -Action {
            Set-MgUserLicense -UserId $newUser.Id -AddLicenses @(@{ SkuId = $sku.SkuId }) -RemoveLicenses @() | Out-Null
        }
        Write-Log "Assigned license $LicenseSku."
    }

    # Step 5: add the user to each group and the team. Retried for the same reason as step 4.
    foreach ($group in $targetGroups) {
        if ($PSCmdlet.ShouldProcess($group.DisplayName, "Add $upn as a member")) {
            Invoke-WithRetry -Description "Add to group '$($group.DisplayName)'" -Action {
                New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $newUser.Id
            }
            Write-Log "Added to group '$($group.DisplayName)'."
        }
    }

    if ($WhatIfPreference) {
        Write-Log 'Preview finished. No changes were made.'
    }
    else {
        Write-Log "Onboarding of $upn finished."
    }
}
catch {
    Write-Log -Level ERROR $_.Exception.Message
    if ($newUser) {
        Write-Log -Level WARN "User $upn was created before the error. Finish the remaining steps by hand (see docs/runbook.md)."
    }
    throw
}
finally {
    # Step 6: show the temporary password.
    # It goes to the screen only and never through Write-Log, so it can never end up in a log file.
    # It is in finally so it still appears if a later step failed; otherwise nobody could sign in as the new user.
    if ($newUser) {
        Write-Information -MessageData "Temporary password for ${upn}: $password (must be changed at first sign-in)" -InformationAction Continue
    }
}
