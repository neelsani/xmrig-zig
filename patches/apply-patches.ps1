# apply-patches.ps1
# Applies the openssl-zig patches into the project's zig-pkg cache so the
# (incomplete) upstream openssl-zig package at the pinned commit builds for
# Windows/x86_64. Idempotent: safe to run repeatedly.
#
# Requirements: git on PATH. Run from anywhere; the script locates the project.
#
# After a fresh clone:
#   zig build --fetch          # or run this script (it does this itself)
#   powershell -File patches\apply-patches.ps1
#   zig build -Drelease=true

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$project   = Split-Path -Parent $scriptDir
$patchFile = Join-Path $scriptDir 'openssl-zig.patch'

Push-Location $project
try {
    # 1. Ensure dependencies are fetched into zig-pkg (no-op if already present)
    & zig build --fetch
    if ($LASTEXITCODE -ne 0) { throw "zig build --fetch failed (exit $LASTEXITCODE)" }

    # 2. Locate the openssl-zig package dir (uniquely identified by its x509 header)
    $ossl = Get-ChildItem -Path 'zig-pkg' -Directory | Where-Object {
        Test-Path (Join-Path $_.FullName 'crypto\x509\standard_exts.h')
    } | Select-Object -First 1
    if (-not $ossl) { throw 'openssl-zig package not found in zig-pkg' }

    # 3. Idempotency check: patched if the generated file exists AND build.zig carries our marker
    $markerFile = Join-Path $ossl.FullName 'providers\implementations\ciphers\ciphercommon.c'
    $buildZig   = Get-Content (Join-Path $ossl.FullName 'build.zig') -Raw -ErrorAction SilentlyContinue
    $already    = (Test-Path $markerFile) -and ($buildZig -match 'ENGINESDIR')
    if ($already) {
        Write-Host "openssl-zig already patched ($($ossl.Name))"
        return
    }

    # 4. Apply the patch (relative a/ b/ paths, so run inside the package dir)
    Push-Location $ossl.FullName
    try {
        & git apply --whitespace=nowarn $patchFile
        if ($LASTEXITCODE -ne 0) { throw 'git apply failed' }
    }
    finally { Pop-Location }

    # 5. Verify
    $buildZig = Get-Content (Join-Path $ossl.FullName 'build.zig') -Raw
    if (-not (Test-Path $markerFile)) { throw 'patch applied but ciphercommon.c is missing' }
    if ($buildZig -notmatch 'ENGINESDIR') { throw 'patch applied but build.zig marker is missing' }
    Write-Host "openssl-zig patched OK ($($ossl.Name))"
}
finally {
    Pop-Location
}