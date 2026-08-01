<#
.SYNOPSIS
    Parses every PowerShell file in the repository.

.DESCRIPTION
    Run this under Windows PowerShell 5.1 as well as PowerShell 7: it is what
    catches PS7-only syntax (ternaries, null-coalescing, pipeline chains) that
    would otherwise only fail on a tester's machine.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$files = Get-ChildItem -Path $repoRoot -Recurse -File -Include '*.ps1', '*.psm1' |
    Where-Object { $_.FullName -notmatch '[\\/](\.git|dist|node_modules)[\\/]' } |
    Sort-Object FullName

$failed = 0
foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    $relative = $file.FullName.Substring($repoRoot.Length).TrimStart('\', '/')
    if ($errors -and $errors.Count -gt 0) {
        $failed++
        Write-Host "FAIL $relative" -ForegroundColor Red
        foreach ($e in $errors) {
            Write-Host ("     line {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message) -ForegroundColor Red
        }
    } else {
        Write-Host "ok   $relative"
    }
}

Write-Host ''
Write-Host ("{0} file(s) parsed, {1} failed." -f $files.Count, $failed)
if ($failed -gt 0) { exit 1 }
exit 0
