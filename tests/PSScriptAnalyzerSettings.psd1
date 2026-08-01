@{
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # The tester CLI is an interactive console tool; Write-Host is the point.
        'PSAvoidUsingWriteHost'

        # PowerShell 5.1 has no ArgumentList on ProcessStartInfo and no
        # Start-ThreadJob, so Invoke-Expression-free direct process construction
        # and positional New-Object are unavoidable in the process helpers.
        'PSUseShouldProcessForStateChangingFunctions'

        # Several functions intentionally return $null-safe defaults rather than
        # writing to the pipeline one object at a time.
        'PSUseOutputTypeCorrectly'

        # Get-AndroidDevices and Write-PwBridgeBytes really do act on many
        # things; renaming them to a singular would be less accurate.
        'PSUseSingularNouns'

        # False positives on script-level parameters that are read from inside
        # nested functions (for example -NoBrowser in tools/pwbridge.ps1).
        'PSReviewUnusedParameter'
    )

    Rules        = @{
        PSAvoidUsingCmdletAliases  = @{ Whitelist = @() }
        PSUseCompatibleSyntax      = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
    }
}
