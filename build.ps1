$ErrorActionPreference = 'Stop'

Write-Host '==== [1/7] depot_tools ===='
if (-not (Test-Path 'C:\depot_tools\gn.bat')) {
    git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git C:\depot_tools
}
$env:PATH = "C:\depot_tools;$env:PATH"

Write-Host '==== [2/7] Skia 源码 ===='
if (-not (Test-Path 'C:\skia\.git')) {
    git clone --depth 1 https://skia.googlesource.com/skia.git C:\skia
}
Set-Location C:\skia
$ver = git rev-parse HEAD
$ver | Out-File -FilePath VERSION.txt -Encoding ascii
Write-Host "Skia commit: $ver"

Write-Host '==== [3/7] 第三方依赖 ===='
python tools/git-sync-deps
if ($LASTEXITCODE -ne 0) { throw "git-sync-deps failed" }

Write-Host '==== [4/7] 环境信息 ===='
cl 2>&1 | Select-String 'Microsoft' | Select-Object -First 2
Write-Host "gn version: $((gn --version 2>&1))"
Write-Host "ninja version: $((ninja --version 2>&1))"

Write-Host '==== [5/7] gn gen ===='
$gnArgsLine = 'is_official_build=false is_debug=false target_cpu="x64" is_clang=false cc="cl" cxx="cl" skia_enable_ganesh=true skia_use_direct3d=true skia_use_dawn=false skia_use_harfbuzz=true skia_use_icu=true skia_enable_skparagraph=true skia_use_freetype=true is_component_build=false'
Write-Host "ARGS: $gnArgsLine"
bash -c "cd /c/skia && gn gen out/Rel --args='$gnArgsLine'"
if ($LASTEXITCODE -ne 0) { throw "gn gen failed" }
Write-Host '--- args.gn ---'
Get-Content out/Rel/args.gn

Write-Host '==== [6/7] 编译 ===='
$env:NINJA_STATUS = '[%f/%t] '
bash -c "cd /c/skia && ninja -C out/Rel skia skparagraph skshaper skunicode 2>&1 | tee BUILD_LOG.txt"
if ($LASTEXITCODE -ne 0) { throw "ninja failed" }

Write-Host '==== [7/7] 打包 ===='
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
if (Test-Path 'third_party/externals/icu/common') { Copy-Item 'third_party/externals/icu/common/unicode' -Destination "$out/include/unicode" -Recurse -Force }
Copy-Item out/Rel/args.gn -Destination "$out/args.gn" -Force
Copy-Item VERSION.txt -Destination "$out/VERSION.txt" -Force
Copy-Item BUILD_LOG.txt -Destination "$out/BUILD_LOG.txt" -Force
(cl 2>&1 | Select-String 'Microsoft') | Out-File -FilePath "$out/CL_VERSION.txt" -Encoding ascii
Get-ChildItem "$out/lib/*.lib" | Select-Object Name, @{n='MB';e={[math]::Round($_.Length/1MB,1)}} | Format-Table
Get-ChildItem "$out/lib/*.lib" | Get-FileHash -Algorithm SHA256 | ForEach-Object { "$($_.Hash.ToLower())  $(Split-Path $_.Path -Leaf)" } | Out-File -FilePath "$out/SHA256SUMS.txt" -Encoding ascii
Get-Content "$out/SHA256SUMS.txt"
Write-Host '==== 完成 ===='
