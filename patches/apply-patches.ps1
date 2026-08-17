# apply-patches.ps1
# Applies the required patches into the project's zig-pkg cache so the pinned
# upstream packages build correctly for Windows/x86_64. Idempotent: safe to run
# repeatedly.
#
# Patches:
#   - donate.h (text replace): guards xmrig's donate.h constants so the dev
#     donation can be disabled at build time (-Dno_donation).
#
# Requirements: git on PATH. Run from anywhere; the script locates the project.
#
# After a fresh clone:
#   powershell -File patches\apply-patches.ps1
#   zig build -Drelease=true

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$project   = Split-Path -Parent $scriptDir

Push-Location $project
try {
    # 1. Ensure dependencies are fetched into zig-pkg (no-op if already present)
    & zig build --fetch
    if ($LASTEXITCODE -ne 0) { throw "zig build --fetch failed (exit $LASTEXITCODE)" }

    # 2. xmrig: locate package dir (identified by src/donate.h) and apply the
    #    donate.h change by deterministic text replacement.
    $xmr = Get-ChildItem -Path 'zig-pkg' -Directory | Where-Object {
        Test-Path (Join-Path $_.FullName 'src\donate.h')
    } | Select-Object -First 1
    if (-not $xmr) { throw 'xmrig package not found in zig-pkg' }

    $donateFile = Join-Path $xmr.FullName 'src\donate.h'
    $donateText = [System.IO.File]::ReadAllText($donateFile)
    if ($donateText -match 'XMRIG_NO_DONATION') {
        Write-Host "xmrig already patched ($($xmr.Name))"
    }
    else {
        $old = "constexpr const int kDefaultDonateLevel = 1;`nconstexpr const int kMinimumDonateLevel = 1;"
        $new = "#ifndef XMRIG_NO_DONATION`nconstexpr const int kDefaultDonateLevel = 1;`nconstexpr const int kMinimumDonateLevel = 1;`n#else`nconstexpr const int kDefaultDonateLevel = 0;`nconstexpr const int kMinimumDonateLevel = 0;`n#endif"
        if (-not $donateText.Contains($old)) { throw 'donate.h does not contain the expected default donation lines' }

        $patched = $donateText.Replace($old, $new)
        [System.IO.File]::WriteAllText($donateFile, $patched, (New-Object System.Text.UTF8Encoding $false))
        Write-Host "xmrig patched OK ($($xmr.Name))"
    }
}
finally {
    Pop-Location
}
