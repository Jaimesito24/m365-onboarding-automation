#Requires -Version 7.0

<#
.SYNOPSIS
    Offboards a Microsoft 365 user: blocks sign-in, revokes sessions, and removes groups and licenses.

.DESCRIPTION
    Runs the offboarding steps in a security-first order. Sign-in is blocked and existing
    sessions are revoked before anything else, so the user loses access straight away.
    The user's groups and licenses are written to the log before they are removed, which
    gives an audit trail. Run with -WhatIf first to preview every change without making it.

    Safe to run more than once on the same user. A second run finishes cleanly, even if the
    first run deleted the user.

.PARAMETER UserPrincipalName
    The sign-in name of the user to offboard, for example alex.example@<your-domain>.onmicrosoft.com.

.PARAMETER DeleteUser
    Also delete the user at the end. This is a soft delete: the user can be restored from
    Deleted users for 30 days.

.EXAMPLE
    ./scripts/Offboard-User.ps1 -UserPrincipalName alex.example@<your-domain>.onmicrosoft.com -WhatIf

    Previews the offboarding and writes the user's current groups and licenses to the log. Nothing is changed.

.EXAMPLE
    ./scripts/Offboard-User.ps1 -UserPrincipalName alex.example@<your-domain>.onmicrosoft.com

    Blocks sign-in, revokes sessions, and removes groups and licenses. The user is kept.

.EXAMPLE
    ./scripts/Offboard-User.ps1 -UserPrincipalName alex.example@<your-domain>.onmicrosoft.com -DeleteUser

    Does everything above, then deletes the user.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$UserPrincipalName,

    [switch]$DeleteUser
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/LabCommon.ps1"

Start-LabLog -Name 'offboard'

try {
    Connect-Lab

    # A filter returns nothing for a missing user instead of throwing an error. That lets a
    # second run, after the user was already deleted, finish cleanly.
    $escapedUpn = $UserPrincipalName -replace "'", "''"
    $user = Get-MgUser -Filter "userPrincipalName eq '$escapedUpn'" -Property 'Id', 'DisplayName', 'UserPrincipalName', 'LicenseAssignmentStates'
    if (-not $user) {
        Write-Log -Level WARN "User $UserPrincipalName was not found. It may already be deleted. Nothing to do."
        return
    }
    $upn = $user.UserPrincipalName
    Write-Log "Offboarding $($user.DisplayName) ($upn)."

    # Steps 1 and 2: cut off access before anything else.
    # Block first, then revoke, as Microsoft recommends. If sessions were revoked first, the
    # user could sign in again and get new tokens before the block took effect.
    if ($PSCmdlet.ShouldProcess($upn, 'Block sign-in')) {
        Update-MgUser -UserId $user.Id -AccountEnabled:$false
        Write-Log 'Blocked sign-in.'
    }

    if ($PSCmdlet.ShouldProcess($upn, 'Revoke sign-in sessions')) {
        Revoke-MgUserSignInSession -UserId $user.Id | Out-Null
        Write-Log 'Revoked sign-in sessions.'
    }

    # Step 3: audit trail. Recorded before anything is removed, so the log shows exactly
    # what the user had if access ever needs to be restored.
    # memberOf also returns directory roles and administrative units; only groups are kept.
    $groups = @(Get-MgUserMemberOf -UserId $user.Id -All |
            Where-Object { $_.AdditionalProperties['@odata.type'] -eq '#microsoft.graph.group' })
    $licenses = @(Get-MgUserLicenseDetail -UserId $user.Id -All)

    Write-Log "Groups before offboarding: $($groups.Count)"
    foreach ($group in $groups) {
        Write-Log "  Group: $($group.AdditionalProperties['displayName']) ($($group.Id))"
    }
    Write-Log "Licenses before offboarding: $($licenses.Count)"
    foreach ($license in $licenses) {
        Write-Log "  License: $($license.SkuPartNumber) ($($license.SkuId))"
    }

    # Step 4: remove every group membership, including the team.
    foreach ($group in $groups) {
        $groupName = $group.AdditionalProperties['displayName']

        # A dynamic group's members are set by its rule, so Microsoft 365 refuses manual removal.
        if ($group.AdditionalProperties['groupTypes'] -contains 'DynamicMembership') {
            Write-Log -Level WARN "Skipped dynamic group '$groupName'. Its membership rule decides who is in it."
            continue
        }

        if ($PSCmdlet.ShouldProcess($groupName, "Remove $upn from group")) {
            Remove-MgGroupMemberByRef -GroupId $group.Id -DirectoryObjectId $user.Id
            Write-Log "Removed from group '$groupName'."
        }
    }

    # Step 5: remove directly assigned licenses.
    # A license that comes from a group cannot be removed from the user directly. It goes away
    # on its own once the user has left that group in step 4.
    $directSkuIds = @($user.LicenseAssignmentStates |
            Where-Object { -not $_.AssignedByGroup } |
            ForEach-Object { $_.SkuId } |
            Select-Object -Unique)

    if ($directSkuIds.Count -eq 0) {
        Write-Log 'No directly assigned licenses to remove.'
    }
    else {
        $directNames = ($licenses | Where-Object { $_.SkuId -in $directSkuIds } | ForEach-Object { $_.SkuPartNumber }) -join ', '
        if ($PSCmdlet.ShouldProcess($upn, "Remove licenses: $directNames")) {
            Set-MgUserLicense -UserId $user.Id -AddLicenses @() -RemoveLicenses $directSkuIds | Out-Null
            Write-Log "Removed licenses: $directNames."
        }
    }

    # Step 6: delete the user, only when asked to.
    if ($DeleteUser -and $PSCmdlet.ShouldProcess($upn, 'Delete user (restorable for 30 days)')) {
        Remove-MgUser -UserId $user.Id
        Write-Log 'Deleted user. It can be restored from Deleted users for 30 days.'
    }

    if ($WhatIfPreference) {
        Write-Log 'Preview finished. No changes were made.'
    }
    else {
        Write-Log "Offboarding of $upn finished."
    }
}
catch {
    Write-Log -Level ERROR $_.Exception.Message
    throw
}
