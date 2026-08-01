#Requires -Modules Pester

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $script:RepoRoot 'server/modules/PwBridge.Common.psm1') -Force
    Import-Module (Join-Path $script:RepoRoot 'tools/PwBridge.Deps.psm1') -Force
    $script:Manifest = Get-Content (Join-Path $script:RepoRoot 'tools/deps.json') -Raw | ConvertFrom-Json
    $script:Iss = Get-Content (Join-Path $script:RepoRoot 'installer/pwbridge-tab.iss') -Raw
}

Describe 'Dependency manifest' {
    It 'is valid JSON with a components array' {
        $script:Manifest.components | Should -Not -BeNullOrEmpty
        @($script:Manifest.components).Count | Should -BeGreaterThan 0
    }

    It 'declares an allowlist of download hosts' {
        @($script:Manifest.allowedHosts).Count | Should -BeGreaterThan 0
        foreach ($h in $script:Manifest.allowedHosts) { $h | Should -Match '^[a-z0-9.\-]+$' }
    }

    It 'gives every component the fields the installer relies on' {
        foreach ($c in $script:Manifest.components) {
            $c.id | Should -Not -BeNullOrEmpty
            $c.version | Should -Not -BeNullOrEmpty
            $c.url | Should -Not -BeNullOrEmpty
            $c.sha256 | Should -Not -BeNullOrEmpty
            $c.license | Should -Not -BeNullOrEmpty
            @($c.provides).Count | Should -BeGreaterThan 0
        }
    }

    It 'pins a full lowercase SHA-256 for every component' {
        foreach ($c in $script:Manifest.components) {
            $c.sha256 | Should -Match '^[0-9a-f]{64}$' -Because "$($c.id) must be hash-pinned"
        }
    }

    It 'downloads only over HTTPS from allowlisted hosts' {
        foreach ($c in $script:Manifest.components) {
            $c.url | Should -Match '^https://'
            $uri = [Uri]$c.url
            $script:Manifest.allowedHosts | Should -Contain $uri.Host
        }
    }

    It 'pins an exact version in every download URL' {
        foreach ($c in $script:Manifest.components) {
            $c.url | Should -Not -Match '/latest/'
            $c.url | Should -Match ([regex]::Escape($c.version).Replace('\.', '[._r-]'))
        }
    }

    It 'marks Android platform-tools as not redistributable' {
        $pt = $script:Manifest.components | Where-Object { $_.id -eq 'platform-tools' }
        $pt | Should -Not -BeNullOrEmpty
        $pt.redistributable | Should -BeFalse
        $pt.required | Should -BeFalse
    }

    It 'treats scrcpy as the required component and Apache-2.0 licensed' {
        $scrcpy = $script:Manifest.components | Where-Object { $_.id -eq 'scrcpy' }
        $scrcpy.required | Should -BeTrue
        $scrcpy.license | Should -Be 'Apache-2.0'
        $scrcpy.provides | Should -Contain 'scrcpy.exe'
        $scrcpy.provides | Should -Contain 'adb.exe'
    }
}

Describe 'Test-PwBridgeDownloadUrl' {
    It 'accepts the manifest URLs' {
        foreach ($c in $script:Manifest.components) {
            Test-PwBridgeDownloadUrl -Url $c.url -AllowedHosts $script:Manifest.allowedHosts | Should -BeTrue
        }
    }

    It 'rejects plain HTTP even on an allowlisted host' {
        Test-PwBridgeDownloadUrl -Url 'http://github.com/x.zip' -AllowedHosts @('github.com') | Should -BeFalse
    }

    It 'rejects hosts outside the allowlist, including suffix lookalikes' {
        Test-PwBridgeDownloadUrl -Url 'https://evil.example/x.zip' -AllowedHosts @('github.com') | Should -BeFalse
        Test-PwBridgeDownloadUrl -Url 'https://github.com.evil.example/x.zip' -AllowedHosts @('github.com') | Should -BeFalse
    }

    It 'rejects file and UNC style URLs' {
        Test-PwBridgeDownloadUrl -Url 'file:///C:/x.zip' -AllowedHosts @('github.com') | Should -BeFalse
        Test-PwBridgeDownloadUrl -Url 'not a url' -AllowedHosts @('github.com') | Should -BeFalse
    }
}

Describe 'Third-party notices' {
    BeforeAll {
        $script:Notices = Get-Content (Join-Path $script:RepoRoot 'THIRD-PARTY-NOTICES.md') -Raw
    }

    It 'names every component in the manifest' {
        foreach ($c in $script:Manifest.components) {
            # "platform-tools" is written "Platform-Tools" in prose; allow a space too.
            $pattern = ($c.id.Split('-') | ForEach-Object { [regex]::Escape($_) }) -join '[- ]'
            $script:Notices | Should -Match $pattern -Because "$($c.id) needs a licence notice"
        }
    }

    It 'records that no third-party binaries are bundled' {
        $script:Notices | Should -Match '(?i)no third-party binaries are bundled'
    }
}

Describe 'Inno Setup script' {
    It 'installs per-user without requesting administrator rights' {
        $script:Iss | Should -Match 'PrivilegesRequired=lowest'
    }

    It 'shows the live-shell warning before installing' {
        $script:Iss | Should -Match 'InfoBeforeFile=WARNING\.txt'
        $warning = Get-Content (Join-Path $script:RepoRoot 'installer/WARNING.txt') -Raw
        $warning | Should -Match '(?i)REAL, LIVE COMMAND PROMPT'
        $warning | Should -Match '127\.0\.0\.1'
    }

    It 'references only files that exist in the repository' {
        $found = [regex]::Matches($script:Iss, '(?im)^\s*Source:\s*"([^"]+)"')
        $found.Count | Should -BeGreaterThan 0
        foreach ($m in $found) {
            $relative = $m.Groups[1].Value
            $full = [System.IO.Path]::GetFullPath((Join-Path (Join-Path $script:RepoRoot 'installer') ($relative -replace '\\', [System.IO.Path]::DirectorySeparatorChar)))
            if ($full -match '\*') {
                $parent = Split-Path -Parent $full
                @(Get-ChildItem -Path $parent -Filter (Split-Path -Leaf $full) -ErrorAction SilentlyContinue).Count |
                    Should -BeGreaterThan 0 -Because "$relative should match at least one file"
            } else {
                Test-Path -LiteralPath $full | Should -BeTrue -Because "$relative is referenced by the installer"
            }
        }
    }

    It 'points every shortcut at a file the installer actually places' {
        $found = [regex]::Matches($script:Iss, '(?im)^\s*Name:\s*"[^"]+";\s*Filename:\s*"\{app\}\\([^"]+)"')
        $found.Count | Should -BeGreaterThan 0
        foreach ($m in $found) {
            $target = $m.Groups[1].Value
            $leaf = Split-Path -Leaf $target
            $script:Iss | Should -Match ([regex]::Escape($leaf)) -Because "$target must be one of the installed files"
        }
    }

    It 'stops a running bridge on upgrade and on uninstall' {
        $script:Iss | Should -Match '(?s)\[UninstallRun\].*pwbridge\.cmd.*stop'
        $script:Iss | Should -Match '(?s)ssInstall.*stop'
    }

    It 'declares the same version as the module' {
        $declared = Get-PwBridgeVersion
        $script:Iss | Should -Match ([regex]::Escape("#define AppVersion `"$declared`""))
    }
}

Describe 'Build workflows' {
    BeforeAll {
        $script:Workflows = @('.github/workflows/ci.yml', '.github/workflows/release.yml') | ForEach-Object {
            [pscustomobject]@{
                Name = $_
                Text = Get-Content (Join-Path $script:RepoRoot $_) -Raw
            }
        }
    }

    It 'resolves the compiler through Ensure-InnoSetup.ps1' {
        Test-Path -LiteralPath (Join-Path $script:RepoRoot 'installer/Ensure-InnoSetup.ps1') | Should -BeTrue
        foreach ($workflow in $script:Workflows) {
            $workflow.Text | Should -Match 'installer/Ensure-InnoSetup\.ps1 -Install' -Because "$($workflow.Name) must not install Inno Setup by hand"
        }
    }

    It 'never pins an Inno Setup version, which would force a downgrade on a newer runner image' {
        foreach ($workflow in $script:Workflows) {
            $workflow.Text | Should -Not -Match 'innosetup[^\r\n]*--version' -Because "$($workflow.Name) would fail on a runner that already has a newer Inno Setup"
        }
    }
}

Describe 'Inno Setup version gate' {
    BeforeAll {
        # The script resolves a compiler when it runs, so lift out just the
        # comparison and exercise that.
        $path = Join-Path $script:RepoRoot 'installer/Ensure-InnoSetup.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        $definition = $ast.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-IsccVersion'
            }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    It 'accepts a compiler newer than the minimum' {
        Test-IsccVersion -VersionText '6.7.1' -Minimum '6.3' | Should -BeTrue
        Test-IsccVersion -VersionText '6.3' -Minimum '6.3' | Should -BeTrue
    }

    It 'rejects a compiler too old for ArchitecturesAllowed=x64compatible' {
        Test-IsccVersion -VersionText '6.2.2' -Minimum '6.3' | Should -BeFalse
        Test-IsccVersion -VersionText '5' -Minimum '6.3' | Should -BeFalse
    }

    It 'falls back to the major version when the banner carries only that' {
        Test-IsccVersion -VersionText '6' -Minimum '6.3' | Should -BeTrue
    }

    It 'uses a compiler whose version cannot be read rather than failing the build' {
        Test-IsccVersion -VersionText $null -Minimum '6.3' | Should -BeTrue
        Test-IsccVersion -VersionText '' -Minimum '6.3' | Should -BeTrue
    }
}

Describe 'Version consistency' {
    It 'uses major.minor.patch' {
        Get-PwBridgeVersion | Should -Match '^\d+\.\d+\.\d+$'
    }

    It 'matches the version quoted in the build docs' {
        $docs = Get-Content (Join-Path $script:RepoRoot 'docs/BUILD-RELEASE.md') -Raw
        $docs | Should -Match ([regex]::Escape((Get-PwBridgeVersion)))
    }
}

Describe 'Launcher' {
    BeforeAll {
        $script:Cmd = Get-Content (Join-Path $script:RepoRoot 'tools/pwbridge.cmd') -Raw
        $script:Cli = Get-Content (Join-Path $script:RepoRoot 'tools/pwbridge.ps1') -Raw
    }

    It 'runs under in-box Windows PowerShell so no prerequisite is needed' {
        $script:Cmd | Should -Match 'powershell\.exe'
        $script:Cmd | Should -Match '-NoProfile'
        $script:Cmd | Should -Match '-ExecutionPolicy Bypass'
    }

    It 'supports the commands the Start menu shortcuts invoke' {
        foreach ($verb in @('start', 'stop', 'doctor', 'setup', 'diagnostics')) {
            $script:Cli | Should -Match "'$verb'"
        }
    }

    It 'warns that the shell tab is live local shell access' {
        $script:Cli | Should -Match '(?i)live shell'
    }
}

Describe 'Web assets' {
    It 'keeps the token out of the address bar' {
        $app = Get-Content (Join-Path $script:RepoRoot 'web/app.js') -Raw
        $app | Should -Match 'history\.replaceState'
    }

    It 'has no inline script or style, so the CSP can stay strict' {
        $html = Get-Content (Join-Path $script:RepoRoot 'web/index.html') -Raw
        $html | Should -Not -Match '<script(?![^>]*\ssrc=)[^>]*>'
        $html | Should -Not -Match '<style'
        $html | Should -Not -Match '\son(click|load|error|change)='
    }

    It 'references only local assets' {
        $html = Get-Content (Join-Path $script:RepoRoot 'web/index.html') -Raw
        $html | Should -Not -Match '(?i)(src|href)="https?://'
    }
}
