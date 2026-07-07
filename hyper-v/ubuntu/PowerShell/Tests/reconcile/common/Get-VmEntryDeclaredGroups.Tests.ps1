<#
.SYNOPSIS
    Unit tests for the shared declared-groups guard.

.DESCRIPTION
    Get-VmEntryDeclaredGroups is a pure function extracted from the two per-VM
    reconcile helpers (Invoke-VmUserCreate / Invoke-VmUserRemove) so the
    optional-'groups' presence check lives in one place. These tests pin the
    three cases both call sites rely on: an absent property yields an empty
    array (not $null), and a present property round-trips as an array whether it
    carries one group or several - the array-ness matters because the callers
    index and .Count the result.
#>

BeforeAll {
    . "$PSScriptRoot\..\..\..\reconcile\common\Get-VmEntryDeclaredGroups.ps1"

    # Builds a VmUsersConfig entry, optionally with a 'groups' property.
    function New-Entry {
        param([object[]] $Groups = $null)
        $entry = [PSCustomObject] @{
            vmName = 'node-01'
            users  = @([PSCustomObject] @{ username = 'u-deploy'; shell = '/bin/bash'; homeDir = '/home/u-deploy' })
        }
        if ($null -ne $Groups) {
            Add-Member -InputObject $entry -MemberType NoteProperty -Name 'groups' -Value $Groups
        }
        $entry
    }
}

Describe 'Get-VmEntryDeclaredGroups' {

    It 'returns an empty array when the entry has no groups property' {
        $result = Get-VmEntryDeclaredGroups -Entry (New-Entry)
        # Must be an enumerable, count 0 - not $null - so callers can .Count it.
        $result | Should -BeNullOrEmpty
        @($result).Count | Should -Be 0
    }

    It 'returns a one-element array for a single declared group' {
        $groups = @([PSCustomObject] @{ groupName = 'docker' })
        $result = Get-VmEntryDeclaredGroups -Entry (New-Entry -Groups $groups)

        $result           | Should -HaveCount 1
        $result[0].groupName | Should -Be 'docker'
    }

    It 'returns all declared groups when several are present' {
        $groups = @(
            [PSCustomObject] @{ groupName = 'docker' },
            [PSCustomObject] @{ groupName = 'sudo' }
        )
        $result = Get-VmEntryDeclaredGroups -Entry (New-Entry -Groups $groups)

        $result              | Should -HaveCount 2
        $result.groupName    | Should -Contain 'docker'
        $result.groupName    | Should -Contain 'sudo'
    }
}
