$ErrorActionPreference = 'Stop'

function 记($msg) { Write-Host "[$(Get-Date -Format HH:mm:ss)] $msg" }

记 '==== [1/7] depot_tools ===='
if (-not (Test-Path 'C:\depot_tools\gn.bat')) {
    git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git C:\depot_tools
    if ($LASTEXITCODE -ne 0) { throw 'git clone depot_tools failed' }
}
$env:PATH = "C:\depot_tools;$env:PATH"
记 'depot_tools ok'

记 '==== [2/7] Skia ===='
if (-not (Test-Path 'C:\skia\.git')) {
    git clone --depth 1 https://skia.googlesource.com/skia.git C:\skia
    if ($LASTEXITCODE -ne 0) { throw 'git clone skia failed' }
}
Set-Location C:\skia
$ver = (git rev-parse HEAD).Trim()
$ver | Out-File -FilePath VERSION.txt -Encoding ascii
记 "skia commit = $ver"

记 '==== [3/7] third_party deps ===='
python tools/git-sync-deps 2>&1 | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) { throw "git-sync-deps failed (exit $LASTEXITCODE)" }
记 'deps done'

记 '==== [4/7] env info ===='
cl 2>&1 | Select-String 'Microsoft' | Select-Object -First 2
# KEY FIX: gn bootstrap writes to stderr; ErrorActionPreference=Stop would abort here
try { $gnVer = (& gn --version 2>&1 | Out-String).Trim() } catch { $gnVer = "unavailable: $_" }
记 "gn = $gnVer"
try { $nvVer = (& ninja --version 2>&1 | Out-String).Trim() } catch { $nvVer = "unavailable: $_" }
记 "ninja = $nvVer"

记 '==== [5/7] gn gen ===='
$gnArgsLine = 'is_official_build=false is_debug=false target_cpu="x64" is_clang=false cc="cl" cxx="cl" skia_enable_ganesh=true skia_use_direct3d=true skia_use_dawn=false skia_use_harfbuzz=true skia_use_icu=true skia_enable_skparagraph=true skia_use_freetype=true is_component_build=false'
记 "ARGS: $gnArgsLine"
bash -c "cd /c/skia && gn gen out/Rel --args='$gnArgsLine'" 2>&1 | ForEach-Object { Write-Host $_ }
if ($LASTEXITCODE -ne 0) {
    Write-Host '--- gn failed, args.gn: ---'
    if (Test-Path out/Rel/args.gn) { Get-Content out/Rel/args.gn }
    throw "gn gen failed (exit $LASTEXITCODE)"
}
记 'gn gen done'
Get-Content out/Rel/args.gn

记 '==== [6/7] ninja ===='
$env:NINJA_STATUS = '[%f/%t] '
bash -c "cd /c/skia && ninja -C out/Rel skia skparagraph skshaper skunicode 2>&1 | tee BUILD_LOG.txt"
if ($LASTEXITCODE -ne 0) { throw "ninja failed (exit $LASTEXITCODE), see BUILD_LOG.txt" }
记 'ninja done'

记 '==== [7/7] staging ===='
$out = 'staging'
Remove-Item -Recurse -Force $out -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path "$out/lib" | Out-Null
Copy-Item out/Rel/*.lib -Destination "$out/lib/" -Force
New-Item -ItemType Directory -Force -Path "$out/include" | Out-Null
foreach ($d in @('include/core','include/config','include/effects','include/utils','include/codec','include/encode','include/gpu','include/ports')) {
    if (Test-Path $d) { Copy-Item $d -Destination "$out/include/" -Recurse -Force }
}
New-Item -ItemType Directory -Force -Path "$out/include/modules" | Out-Null
foreach ($m in @('skparagraph','skshaper','skunicode')) {
    if (Test-Path "modules/$m/include") { Copy-Item "modules/$m/include" -Destination "$out/include/modules/$m" -Recurse -Force }
}
if (Test-Path 'third_party/externals/harfbuzz/src') { Copy-Item 'third_party/externals/harfbuzz/src' -Destination "$out/include/harfbuzz" -Recurse -Force }
if (Test-Path 'third_party/externals/icu/common/unicode') { Copy-Item 'third_party/externals/icu/common/unicode' -Destination "$out/include/unicode" -Recurse -Force }
Copy-Item out/Rel/args.gn -Destination "$out/args.gn" -Force
Copy-Item VERSION.txt -Destination "$out/VERSION.txt" -Force
Copy-Item BUILD_LOG.txt -Destination "$out/BUILD_LOG.txt" -Force
(cl 2>&1 | Select-String 'Microsoft') | Out-File -FilePath "$out/CL_VERSION.txt" -Encoding ascii
Get-ChildItem "$out/lib/*.lib" | Select-Object Name, @{n='MB';e={[math]::Round($_.Length/1MB,1)}} | Format-Table
Get-ChildItem "$out/lib/*.lib" | Get-FileHash -Algorithm SHA256 | ForEach-Object { "$($_.Hash.ToLower())  $(Split-Path $_.Path -Leaf)" } | Out-File -FilePath "$out/SHA256SUMS.txt" -Encoding ascii
Get-Content "$out/SHA256SUMS.txt"
记 '==== DONE ===='
