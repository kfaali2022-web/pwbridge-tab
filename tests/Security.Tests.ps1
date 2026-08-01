#Requires -Modules Pester

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'server/modules/PwBridge.Common.psm1') -Force
    Import-Module (Join-Path $repoRoot 'server/modules/PwBridge.Http.psm1') -Force

    function New-FakeRequest {
        param([hashtable]$Headers = @{}, [hashtable]$Query = @{})
        $h = New-Object System.Collections.Specialized.NameValueCollection
        foreach ($k in $Headers.Keys) { $h.Add($k, $Headers[$k]) }
        $q = New-Object System.Collections.Specialized.NameValueCollection
        foreach ($k in $Query.Keys) { $q.Add($k, $Query[$k]) }
        return [PSCustomObject]@{ Headers = $h; QueryString = $q }
    }
}

Describe 'New-PwBridgeToken' {
    It 'produces a URL-safe token of at least 32 characters' {
        $token = New-PwBridgeToken
        $token.Length | Should -BeGreaterOrEqual 32
        $token | Should -Match '^[A-Za-z0-9_-]+$'
    }

    It 'produces a different token every time' {
        $tokens = 1..25 | ForEach-Object { New-PwBridgeToken }
        ($tokens | Select-Object -Unique).Count | Should -Be 25
    }
}

Describe 'Test-PwBridgeTokenMatch' {
    It 'matches an identical token' {
        Test-PwBridgeTokenMatch -Expected 'abc123' -Actual 'abc123' | Should -BeTrue
    }

    It 'rejects a wrong, empty, prefix or extended token' {
        Test-PwBridgeTokenMatch -Expected 'abc123' -Actual 'abc124' | Should -BeFalse
        Test-PwBridgeTokenMatch -Expected 'abc123' -Actual '' | Should -BeFalse
        Test-PwBridgeTokenMatch -Expected 'abc123' -Actual $null | Should -BeFalse
        Test-PwBridgeTokenMatch -Expected 'abc123' -Actual 'abc' | Should -BeFalse
        Test-PwBridgeTokenMatch -Expected 'abc123' -Actual 'abc1234' | Should -BeFalse
    }

    It 'treats an unset expected token as open (token disabled)' {
        Test-PwBridgeTokenMatch -Expected '' -Actual 'anything' | Should -BeTrue
    }
}

Describe 'Test-PwBridgeOrigin' {
    It 'allows loopback origins on the bridge port' {
        foreach ($origin in @('http://127.0.0.1:8765', 'http://localhost:8765', 'http://[::1]:8765', 'http://127.0.0.1:8765/')) {
            Test-PwBridgeOrigin -Origin $origin -Port 8765 | Should -BeTrue
        }
    }

    It 'allows a missing Origin, which same-origin fetches and WebSocket handshakes omit' {
        Test-PwBridgeOrigin -Origin '' -Port 8765 | Should -BeTrue
        Test-PwBridgeOrigin -Origin $null -Port 8765 | Should -BeTrue
    }

    It 'rejects cross-site origins, including lookalikes' {
        foreach ($origin in @(
                'http://evil.example',
                'https://127.0.0.1:8765',
                'http://127.0.0.1:8766',
                'http://127.0.0.1.evil.example:8765',
                'http://localhost:8000'
            )) {
            Test-PwBridgeOrigin -Origin $origin -Port 8765 | Should -BeFalse
        }
    }
}

Describe 'Get-PwBridgeRequestToken' {
    It 'prefers the header' {
        $req = New-FakeRequest -Headers @{ 'X-PwBridge-Token' = 'from-header' } -Query @{ token = 'from-query' }
        Get-PwBridgeRequestToken -Request $req | Should -Be 'from-header'
    }

    It 'falls back to the query string, which is all a WebSocket handshake can carry' {
        Get-PwBridgeRequestToken -Request (New-FakeRequest -Query @{ token = 'from-query' }) | Should -Be 'from-query'
    }

    It 'returns an empty string when no token is supplied' {
        Get-PwBridgeRequestToken -Request (New-FakeRequest) | Should -Be ''
    }
}

Describe 'Test-PwBridgeAuthorized' {
    It 'authorizes a correct token from a loopback origin' {
        $req = New-FakeRequest -Headers @{ 'X-PwBridge-Token' = 'secret'; 'Origin' = 'http://127.0.0.1:8765' }
        Test-PwBridgeAuthorized -Request $req -Token 'secret' -Port 8765 | Should -BeTrue
    }

    It 'refuses a correct token presented from a foreign origin' {
        $req = New-FakeRequest -Headers @{ 'X-PwBridge-Token' = 'secret'; 'Origin' = 'http://evil.example' }
        Test-PwBridgeAuthorized -Request $req -Token 'secret' -Port 8765 | Should -BeFalse
    }

    It 'refuses a wrong or missing token' {
        $req = New-FakeRequest -Headers @{ 'X-PwBridge-Token' = 'nope' }
        Test-PwBridgeAuthorized -Request $req -Token 'secret' -Port 8765 | Should -BeFalse
        Test-PwBridgeAuthorized -Request (New-FakeRequest) -Token 'secret' -Port 8765 | Should -BeFalse
    }
}

Describe 'Get-PwBridgeBodyValue' {
    It 'reads a present property' {
        Get-PwBridgeBodyValue -Body ([PSCustomObject]@{ x = 5 }) -Name 'x' | Should -Be 5
    }

    It 'returns the default for missing, null and absent bodies' {
        Get-PwBridgeBodyValue -Body ([PSCustomObject]@{ x = 5 }) -Name 'y' -Default 9 | Should -Be 9
        Get-PwBridgeBodyValue -Body ([PSCustomObject]@{ x = $null }) -Name 'x' -Default 9 | Should -Be 9
        Get-PwBridgeBodyValue -Body $null -Name 'x' -Default 9 | Should -Be 9
    }
}

Describe 'Get-PwBridgeContentType' {
    It 'maps the extensions the web UI serves' {
        Get-PwBridgeContentType -Path 'a/index.html' | Should -Be 'text/html; charset=utf-8'
        Get-PwBridgeContentType -Path 'a/app.js' | Should -Be 'text/javascript; charset=utf-8'
        Get-PwBridgeContentType -Path 'a/styles.CSS' | Should -Be 'text/css; charset=utf-8'
    }

    It 'falls back to octet-stream for anything else' {
        Get-PwBridgeContentType -Path 'a/secrets.ps1' | Should -Be 'application/octet-stream'
    }
}

Describe 'Server binding' {
    It 'refuses to bind to a non-loopback address' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $source = Get-Content (Join-Path $repoRoot 'server/server.ps1') -Raw
        $source | Should -Match "Refusing to bind to a non-loopback address"
        $source | Should -Match "\`$Bind -ne '127\.0\.0\.1'"
    }

    It 'defaults the bind address to loopback' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $source = Get-Content (Join-Path $repoRoot 'server/server.ps1') -Raw
        $source | Should -Match "\`$Bind\s*=\s*'127\.0\.0\.1'"
    }
}

Describe 'Diagnostics privacy' {
    It 'hashes device serials rather than recording them' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $source = Get-Content (Join-Path $repoRoot 'server/modules/PwBridge.Http.psm1') -Raw
        $source | Should -Match 'Get-PwBridgeShortHash'
    }

    It 'produces a stable, short, non-reversible hash' {
        $a = Get-PwBridgeShortHash -Value 'R5CT30ABCDE'
        $b = Get-PwBridgeShortHash -Value 'R5CT30ABCDE'
        $a | Should -Be $b
        $a | Should -Not -Match 'R5CT30'
        $a.Length | Should -BeLessOrEqual 16
        Get-PwBridgeShortHash -Value 'other' | Should -Not -Be $a
    }
}

Describe 'No hard-coded device identity' {
    It 'ships no device serial in any packaged file' {
        # Only the shipped tree is scanned: the test fixtures above deliberately
        # contain serial-shaped strings.
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $roots = @('server', 'tools', 'web', 'installer') | ForEach-Object { Join-Path $repoRoot $_ }
        $files = Get-ChildItem -Path $roots -Recurse -File -Include '*.ps1', '*.psm1', '*.js', '*.json', '*.iss', '*.cmd', '*.html'
        foreach ($file in $files) {
            $text = Get-Content $file.FullName -Raw
            # Samsung serials look like R5CT30ABCDE; emulator/IP targets are fine.
            $text | Should -Not -Match '\bR[0-9][A-Z0-9]{9}\b' -Because "$($file.Name) must not pin a device serial"
        }
    }

    It 'selects the device from what is attached, not from configuration' {
        $repoRoot = Split-Path -Parent $PSScriptRoot
        $config = Get-Content (Join-Path $repoRoot 'server/modules/PwBridge.Common.psm1') -Raw
        $config | Should -Not -Match "(?i)'serial'\s*=\s*'[A-Za-z0-9]"
    }
}
