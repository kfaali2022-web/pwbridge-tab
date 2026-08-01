#Requires -Modules Pester

BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    Import-Module (Join-Path $repoRoot 'server/modules/PwBridge.Android.psm1') -Force
}

Describe 'ConvertFrom-AdbDeviceList' {
    It 'returns an empty array for no output' {
        @(ConvertFrom-AdbDeviceList -Output '').Count | Should -Be 0
        @(ConvertFrom-AdbDeviceList -Output $null).Count | Should -Be 0
    }

    It 'skips the header and daemon chatter' {
        $output = @(
            '* daemon not running; starting now at tcp:5037'
            '* daemon started successfully'
            'List of devices attached'
            ''
        ) -join "`n"
        @(ConvertFrom-AdbDeviceList -Output $output).Count | Should -Be 0
    }

    It 'parses an authorized device with model and product' {
        $output = "List of devices attached`nR5CT30ABCDE            device product:q5qxxx model:SM_F946B device:q5q transport_id:3"
        $devices = @(ConvertFrom-AdbDeviceList -Output $output)
        $devices.Count | Should -Be 1
        $devices[0].Serial | Should -Be 'R5CT30ABCDE'
        $devices[0].State | Should -Be 'device'
        $devices[0].Model | Should -Be 'SM_F946B'
        $devices[0].Product | Should -Be 'q5qxxx'
        $devices[0].Authorized | Should -BeTrue
    }

    It 'marks unauthorized and offline devices as not authorized' {
        $output = "List of devices attached`nABC123 unauthorized`nDEF456 offline"
        $devices = @(ConvertFrom-AdbDeviceList -Output $output)
        $devices.Count | Should -Be 2
        @($devices | Where-Object { $_.Authorized }).Count | Should -Be 0
        $devices[0].State | Should -Be 'unauthorized'
        $devices[1].State | Should -Be 'offline'
    }

    It 'normalises the multi-word "no permissions" state' {
        $output = "List of devices attached`nABC123 no permissions (user in plugdev group); see [http://developer.android.com/tools/device.html]"
        $devices = @(ConvertFrom-AdbDeviceList -Output $output)
        $devices[0].State | Should -Be 'no-permissions'
        $devices[0].Authorized | Should -BeFalse
    }

    It 'handles CRLF output' {
        $output = "List of devices attached`r`nABC123`tdevice`r`n"
        @(ConvertFrom-AdbDeviceList -Output $output).Count | Should -Be 1
    }

    It 'rejects lines whose serial is not serial-shaped' {
        $output = "List of devices attached`n`$(rm -rf /) device"
        @(ConvertFrom-AdbDeviceList -Output $output).Count | Should -Be 0
    }

    It 'parses emulators alongside physical devices' {
        $output = "List of devices attached`nemulator-5554 device product:sdk model:Android_SDK`nR5CT30ABCDE device model:SM_F946B"
        @(ConvertFrom-AdbDeviceList -Output $output).Count | Should -Be 2
    }
}

Describe 'Resolve-AndroidDevice' {
    BeforeAll {
        function New-Device {
            param($Serial, $State, $Model = '')
            [PSCustomObject]@{
                Serial     = $Serial
                State      = $State
                Model      = $Model
                Product    = ''
                Authorized = ($State -eq 'device')
            }
        }
    }

    It 'reports none when nothing is attached' {
        $r = Resolve-AndroidDevice -Devices @()
        $r.Status | Should -Be 'none'
        $r.Serial | Should -BeNullOrEmpty
        $r.Hint | Should -Match 'USB data cable'
    }

    It 'tolerates a null device list' {
        (Resolve-AndroidDevice -Devices $null).Status | Should -Be 'none'
    }

    It 'auto-selects the single authorized device without any hard-coded serial' {
        $r = Resolve-AndroidDevice -Devices @(New-Device 'R5CT30ABCDE' 'device' 'SM_F946B')
        $r.Status | Should -Be 'ready'
        $r.Serial | Should -Be 'R5CT30ABCDE'
    }

    It 'reports multiple when more than one device is authorized' {
        $r = Resolve-AndroidDevice -Devices @((New-Device 'A1' 'device'), (New-Device 'B2' 'device'))
        $r.Status | Should -Be 'multiple'
        $r.Serial | Should -BeNullOrEmpty
        $r.Message | Should -Match '2 authorized'
    }

    It 'honours a preferred serial when it is authorized' {
        $r = Resolve-AndroidDevice -Devices @((New-Device 'A1' 'device'), (New-Device 'B2' 'device' 'Pixel')) -PreferredSerial 'B2'
        $r.Status | Should -Be 'ready'
        $r.Serial | Should -Be 'B2'
        $r.Message | Should -Match 'Pixel'
    }

    It 'ignores a preferred serial that is not authorized' {
        $r = Resolve-AndroidDevice -Devices @((New-Device 'A1' 'device'), (New-Device 'B2' 'unauthorized')) -PreferredSerial 'B2'
        $r.Status | Should -Be 'ready'
        $r.Serial | Should -Be 'A1'
    }

    It 'reports unauthorized with an actionable hint' {
        $r = Resolve-AndroidDevice -Devices @(New-Device 'A1' 'unauthorized')
        $r.Status | Should -Be 'unauthorized'
        $r.Hint | Should -Match 'Allow USB debugging'
    }

    It 'reports offline' {
        (Resolve-AndroidDevice -Devices @(New-Device 'A1' 'offline')).Status | Should -Be 'offline'
    }

    It 'reports no-permissions' {
        (Resolve-AndroidDevice -Devices @(New-Device 'A1' 'no-permissions')).Status | Should -Be 'no-permissions'
    }

    It 'prefers unauthorized over offline when both are present' {
        $r = Resolve-AndroidDevice -Devices @((New-Device 'A1' 'offline'), (New-Device 'B2' 'unauthorized'))
        $r.Status | Should -Be 'unauthorized'
    }

    It 'always supplies a human-readable message' {
        foreach ($state in @('device', 'unauthorized', 'offline', 'no-permissions')) {
            (Resolve-AndroidDevice -Devices @(New-Device 'A1' $state)).Message | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Input validation' {
    It 'accepts allowlisted keycodes' {
        Test-AndroidKeycode -Keycode 'KEYCODE_HOME' | Should -BeTrue
        Test-AndroidKeycode -Keycode 'KEYCODE_VOLUME_UP' | Should -BeTrue
    }

    It 'rejects keycodes that are not in the allowlist' {
        foreach ($bad in @('KEYCODE_HOME; rm -rf /', 'KEYCODE_FAKE', '$(id)', '', 'KEYCODE_HOME KEYCODE_BACK')) {
            Test-AndroidKeycode -Keycode $bad | Should -BeFalse
        }
    }

    It 'exposes an allowlist that contains no shell metacharacters' {
        foreach ($code in Get-AndroidKeycodeAllowlist) {
            $code | Should -Match '^KEYCODE_[A-Z_]+$'
        }
    }

    It 'accepts ordinary text' {
        Test-AndroidInputText -Text 'hello world 123' | Should -BeTrue
        Test-AndroidInputText -Text '' | Should -BeTrue
    }

    It 'rejects text containing shell metacharacters' {
        foreach ($bad in @('a; rm -rf /', 'a$(id)', 'a`id`', 'a|b', 'a&b', 'a>b', 'a<b', 'a\b', 'a"b', "a'b", 'a*b')) {
            Test-AndroidInputText -Text $bad | Should -BeFalse
        }
    }

    It 'rejects text longer than 500 characters' {
        Test-AndroidInputText -Text ('a' * 501) | Should -BeFalse
        Test-AndroidInputText -Text ('a' * 500) | Should -BeTrue
    }

    It 'encodes spaces for adb input text' {
        ConvertTo-AndroidInputText -Text 'hello world' | Should -Be 'hello%sworld'
    }

    It 'throws rather than escaping when text is unsafe' {
        { ConvertTo-AndroidInputText -Text 'oops; reboot' } | Should -Throw
    }

    It 'accepts serial-shaped strings' {
        foreach ($ok in @('R5CT30ABCDE', 'emulator-5554', '192.168.1.5:5555', 'abc.def_1')) {
            Test-AndroidSerial -Serial $ok | Should -BeTrue
        }
    }

    It 'rejects serials containing separators or metacharacters' {
        foreach ($bad in @('', ' ', 'a b', 'a;b', 'a&b', 'a|b', '$(id)', '../etc', ('a' * 65))) {
            Test-AndroidSerial -Serial $bad | Should -BeFalse
        }
    }

    It 'rejects out-of-range coordinates before touching adb' {
        { Invoke-AndroidInput -Serial 'A1' -AdbPath 'adb' -Action 'tap' -X -1 -Y 0 } | Should -Throw
        { Invoke-AndroidInput -Serial 'A1' -AdbPath 'adb' -Action 'tap' -X 0 -Y 99999 } | Should -Throw
    }

    It 'rejects an out-of-range swipe duration' {
        { Invoke-AndroidInput -Serial 'A1' -AdbPath 'adb' -Action 'swipe' -X 1 -Y 1 -X2 2 -Y2 2 -DurationMs 0 } | Should -Throw
        { Invoke-AndroidInput -Serial 'A1' -AdbPath 'adb' -Action 'swipe' -X 1 -Y 1 -X2 2 -Y2 2 -DurationMs 99999 } | Should -Throw
    }

    It 'rejects a disallowed keycode before touching adb' {
        { Invoke-AndroidInput -Serial 'A1' -AdbPath 'adb' -Action 'key' -Keycode 'KEYCODE_NOPE' } | Should -Throw
    }
}

Describe 'ConvertFrom-AdbWmSize' {
    It 'parses a physical size' {
        $r = ConvertFrom-AdbWmSize -Output 'Physical size: 1080x2340'
        $r.Width | Should -Be 1080
        $r.Height | Should -Be 2340
    }

    It 'prefers the override size when the device reports one' {
        $r = ConvertFrom-AdbWmSize -Output "Physical size: 1812x2176`nOverride size: 906x1088"
        $r.Width | Should -Be 906
        $r.Height | Should -Be 1088
    }

    It 'returns zeroes for unparseable output' {
        (ConvertFrom-AdbWmSize -Output 'error: no devices').Width | Should -Be 0
        (ConvertFrom-AdbWmSize -Output '').Height | Should -Be 0
    }
}

Describe 'Test-PngHeader' {
    It 'accepts a valid PNG signature' {
        Test-PngHeader -Bytes ([byte[]]@(137, 80, 78, 71, 13, 10, 26, 10, 0, 0)) | Should -BeTrue
    }

    It 'rejects short, null and non-PNG payloads' {
        Test-PngHeader -Bytes $null | Should -BeFalse
        Test-PngHeader -Bytes ([byte[]]@(137, 80)) | Should -BeFalse
        Test-PngHeader -Bytes ([byte[]]@(101, 114, 114, 111, 114, 58, 32, 32)) | Should -BeFalse
    }
}

Describe 'ConvertTo-ProcessArgumentString' {
    It 'leaves simple arguments unquoted' {
        ConvertTo-ProcessArgumentString -ArgumentList @('devices', '-l') | Should -Be 'devices -l'
    }

    It 'quotes arguments containing spaces' {
        ConvertTo-ProcessArgumentString -ArgumentList @('--window-title', 'pwbridge-tab phone') |
            Should -Be '--window-title "pwbridge-tab phone"'
    }

    It 'escapes embedded quotes' {
        ConvertTo-ProcessArgumentString -ArgumentList @('a"b') | Should -Be '"a\"b"'
    }

    It 'returns an empty string for no arguments' {
        ConvertTo-ProcessArgumentString -ArgumentList @() | Should -Be ''
    }
}
