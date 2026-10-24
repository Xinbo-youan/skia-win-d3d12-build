# =====================================================================
#  Skia Win x64 D3D12 static library build (v7)
#  v7 vs v6: full-transcript logging (captures native stdout/stderr so a
#  failed run's pushed build.log is actually diagnosable), freetype off,
#  success also commits SHA256SUMS/args.gn/VERSION. Workflow unchanged.
# =====================================================================

$ErrorActionPreference = 'Continue'

$wsRoot = $env:GITHUB_WORKSPACE; if (-not $wsRoot) { $wsRoot = (Get-Location).Path }
$TRANSCRIPT = Join-Path $wsRoot 'logs\transcript.log'
try { New-Item -ItemType Directory -Force -Path (Split-Path $TRANSCRIPT) | Out-Null; Start-Transcript -Path $TRANSCRIPT -Force | Out-Null } catch { Write-Host ('transcript start failed: ' + $_) }

# ---- failure reporter: runs on any terminating error ----
trap {
    $errText = ($_ | Out-String)
    Write-Host "==== TRAPPED ERROR ====\n$errText"
    try {
        $ws = $env:GITHUB_WORKSPACE
        if (-not $ws) { $ws = (Get-Location).Path }
        Set-Location $ws
        try { Stop-Transcript | Out-Null } catch {}
        $src = $null
        if (Test-Path 'C:\skia\BUILD_LOG.txt') { $src = 'C:\skia\BUILD_LOG.txt' }
        elseif (Test-Path $TRANSCRIPT) { $src = $TRANSCRIPT }
        if ($src) { Get-Content $src -Tail 400 | Out-File 'build.log' -Encoding utf8 } else { 'no log produced' | Out-File 'build.log' -Encoding utf8 }
        $st = "STATUS: FAILED`n`ntime: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC`nrun: $env:GITHUB_RUN_ID`n`n--- error ---`n$errText"
        $st | Out-File 'STATUS.md' -Encoding utf8
        & git add -A
        & git -c user.email=ci@local -c user.name=ci commit -m "ci: failed run $env:GITHUB_RUN_ID"
        & git push origin HEAD:main
        Write-Host 'failure report pushed'
    } catch {
        Write-Host ("push failure report failed: " + ($_ | Out-String))
    }
    exit 1
}

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
skia_use_freetype = false
is_component_build = false
'@
$argsGn | Out-File -FilePath out/Rel/args.gn -Encoding utf8
Log '--- args.gn ---'
Get-Content out/Rel/args.gn

& gn gen out/Rel
$c = $LASTEXITCODE
if ($c -ne 0) {
    Write-Host '--- gn gen FAILED ---'
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

# ---- success: publish status ----
Log '==== publishing STATUS.md ===='
try {
    $ws = $env:GITHUB_WORKSPACE
    if (-not $ws) { $ws = (Get-Location).Path }
    Set-Location $ws
    try { Stop-Transcript | Out-Null } catch {}
    $libs = (Get-ChildItem 'C:\skia\staging\lib\*.lib' | Select-Object -ExpandProperty Name) -join ', '
    ("STATUS: BUILT`n`ntime: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC`nrun: $env:GITHUB_RUN_ID`nskia: " + (Get-Content 'C:\skia\VERSION.txt')) |
        Out-File 'STATUS.md' -Encoding utf8
    "libs: $libs" | Out-File 'STATUS.md' -Append -Encoding utf8
    Copy-Item 'C:\skia\staging\SHA256SUMS.txt' 'SHA256SUMS.txt' -Force -ErrorAction SilentlyContinue
    Copy-Item 'C:\skia\staging\args.gn' 'args.gn' -Force -ErrorAction SilentlyContinue
    Copy-Item 'C:\skia\VERSION.txt' 'VERSION.txt' -Force -ErrorAction SilentlyContinue
    if (Test-Path $TRANSCRIPT) { Get-Content $TRANSCRIPT -Tail 400 | Out-File 'build.log' -Encoding utf8 }
    & git add -A
    & git -c user.email=ci@local -c user.name=ci commit -m "ci: built run $env:GITHUB_RUN_ID"
    & git push origin HEAD:main
    Log 'STATUS.md pushed'
} catch {
    Log ("push STATUS failed: " + ($_ | Out-String))
}

Log '==== ALL DONE ===='
