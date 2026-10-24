# =====================================================================
#  Skia Win x64 D3D12 static library build (v5)
# ---------------------------------------------------------------------
#  Root causes of previous failures and fixes:
#   run#1  jlumbroso/free-disk-space does not support Windows   -> removed
#   run#2  C:/depot_tools/gn.exe does not exist (only gn.bat)   -> use gn from PATH
#   run#3  gn --version stderr treated as terminating error    -> Continue + try
#   run#4  2>&1 turned python stderr into terminating error    -> no 2>&1 on pipes
#   v5     1) no --args on command line at all; write out/Rel/args.gn directly
#             (PowerShell/cmd/bash all re-parse quoted args; args.gn is GN's
#              standard config file, one key = value per line, zero escaping)
#          2) ninja uses *> redirection (pipe pollutes $LASTEXITCODE)
#          3) capture $LASTEXITCODE into a local variable right after each call
#          4) on failure print log tail so it shows up in Actions output even
#             when artifact upload is skipped
#  All identifiers are ASCII on purpose: a UTF-8-without-BOM script with
#  non-ASCII identifiers may fail to parse depending on the PowerShell host.
# =====================================================================

$ErrorActionPreference = 'Continue'

function Log($msg) {
    Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg)
}

function Check($code, $what) {
    if ($code -ne 0) { throw ("$what FAILED, exit=$code") }
}

# ---------------- 0/7 environment ----------------
Log '==== [0/7] environment ===='
Log ("PSVersion : " + $PSVersionTable.PSVersion.ToString())
Log ("python    : " + ((& python --version) 2>&1 | Out-String).Trim())
Log ("git       : " + ((& git --version) 2>&1 | Out-String).Trim())
Get-PSDrive C | Select-Object Name, @{n='FreeGB';e={[math]::Round($_.Free/1GB,1)}} | Format-Table

# ---------------- 1/7 depot_tools ----------------
Log '==== [1/7] depot_tools ===='
if (-not (Test-Path 'C:\depot_tools\gn.bat')) {
    & git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git C:\depot_tools
    $c = $LASTEXITCODE
    Check $c 'clone depot_tools'
}
$env:PATH = "C:\depot_tools;$env:PATH"
Log ("gn.bat    = " + (Test-Path 'C:\depot_tools\gn.bat'))
Log ("ninja.bat = " + (Test-Path 'C:\depot_tools\ninja.bat'))

# ---------------- 2/7 skia source ----------------
Log '==== [2/7] skia source ===='
if (-not (Test-Path 'C:\skia\.git')) {
    & git clone --depth 1 https://skia.googlesource.com/skia.git C:\skia
    $c = $LASTEXITCODE
    Check $c 'clone skia'
}
Set-Location C:\skia
$skiaVer = ((& git rev-parse HEAD) | Out-String).Trim()
$skiaVer | Out-File -FilePath VERSION.txt -Encoding ascii
Log ("skia commit = " + $skiaVer)

# ---------------- 3/7 third_party deps ----------------
Log '==== [3/7] third_party deps ===='
& python tools/git-sync-deps
$c = $LASTEXITCODE
Check $c 'git-sync-deps'
Log 'deps done'

# ---------------- 4/7 toolchain info ----------------
Log '==== [4/7] toolchain info ===='
& cl 2>&1 | Select-String 'Microsoft' | Select-Object -First 2
try { $gnVer = ((& gn --version) 2>&1 | Out-String).Trim() } catch { $gnVer = 'unavailable' }
Log ("gn    = " + $gnVer)
try { $nvVer = ((& ninja --version) 2>&1 | Out-String).Trim() } catch { $nvVer = 'unavailable' }
Log ("ninja = " + $nvVer)

# ---------------- 5/7 gn gen ----------------
Log '==== [5/7] gn gen ===='
New-Item -ItemType Directory -Force -Path out/Rel | Out-Null

$argsGn = @'
is_official_build = false
is_debug = false
target_cpu = "x64"
is_clang = false
cc = "cl"
cxx = "cl"
skia_enable_ganesh = true
skia_use_direct3d = true
skia_use_dawn = false
skia_use_harfbuzz = true
skia_use_icu = true
skia_enable_skparagraph = true
skia_use_freetype = true
is_component_build = false
'@
$argsGn | Out-File -FilePath out/Rel/args.gn -Encoding utf8
Log '--- args.gn ---'
Get-Content out/Rel/args.gn

& gn gen out/Rel
$c = $LASTEXITCODE
if ($c -ne 0) {
    Write-Host '--- gn gen FAILED, args.gn: ---'
    Get-Content out/Rel/args.gn
    throw "gn gen FAILED, exit=$c"
}
Log 'gn gen done'

# ---------------- 6/7 ninja ----------------
Log '==== [6/7] ninja build ===='
$env:NINJA_STATUS = '[%f/%t] '
& ninja -C out/Rel skia skparagraph skshaper skunicode *> BUILD_LOG.txt
$c = $LASTEXITCODE
Log ("ninja exit = " + $c)
if ($c -ne 0) {
    Write-Host '--- BUILD_LOG tail (last 120 lines) ---'
    Get-Content BUILD_LOG.txt -Tail 120
    throw "ninja FAILED, exit=$c"
}
Log 'build done'

# ---------------- 7/7 staging ----------------
Log '==== [7/7] staging ===='
$out = 'staging'
if (Test-Path $out) { Remove-Item -Recurse -Force $out }
New-Item -ItemType Directory -Force -Path "$out/lib" | Out-Null
Copy-Item out/Rel/*.lib -Destination "$out/lib/" -Force

New-Item -ItemType Directory -Force -Path "$out/include" | Out-Null
foreach ($d in @('include/core','include/config','include/effects','include/utils',
                 'include/codec','include/encode','include/gpu','include/ports')) {
    if (Test-Path $d) { Copy-Item $d -Destination "$out/include/" -Recurse -Force }
}
New-Item -ItemType Directory -Force -Path "$out/include/modules" | Out-Null
foreach ($m in @('skparagraph','skshaper','skunicode')) {
    if (Test-Path "modules/$m/include") {
        Copy-Item "modules/$m/include" -Destination "$out/include/modules/$m" -Recurse -Force
    }
}
if (Test-Path 'third_party/externals/harfbuzz/src') {
    Copy-Item 'third_party/externals/harfbuzz/src' -Destination "$out/include/harfbuzz" -Recurse -Force
}
if (Test-Path 'third_party/externals/icu/common/unicode') {
    Copy-Item 'third_party/externals/icu/common/unicode' -Destination "$out/include/unicode" -Recurse -Force
}

Copy-Item out/Rel/args.gn -Destination "$out/args.gn" -Force
Copy-Item VERSION.txt     -Destination "$out/VERSION.txt" -Force
if (Test-Path BUILD_LOG.txt) { Copy-Item BUILD_LOG.txt -Destination "$out/BUILD_LOG.txt" -Force }

Log '--- lib files ---'
Get-ChildItem "$out/lib/*.lib" | Select-Object Name, @{n='MB';e={[math]::Round($_.Length/1MB,1)}} | Format-Table

Log '--- sha256 ---'
Get-ChildItem "$out/lib/*.lib" | Get-FileHash -Algorithm SHA256 |
    ForEach-Object { ($_.Hash.ToLower() + '  ' + (Split-Path $_.Path -Leaf)) } |
    Out-File -FilePath "$out/SHA256SUMS.txt" -Encoding ascii
Get-Content "$out/SHA256SUMS.txt"

Log '==== ALL DONE ===='
