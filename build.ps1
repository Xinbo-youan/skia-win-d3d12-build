# =====================================================================
#  Skia Win x64 D3D12 构建
# ---------------------------------------------------------------------
# 【为什么不用 ErrorActionPreference=Stop】
#   PowerShell 在 Stop 模式下，把外部程序的 stderr 当成 ErrorRecord；
#   git-sync-deps / gn / ninja 都会往 stderr 写进度，一写就抛异常。
#   改用 Continue + 逐个检查 $LASTEXITCODE（2026-10-25 run#3/#4 两次翻车）。
# =====================================================================
$ErrorActionPreference = 'Continue'

function 记($m) { Write-Host "[$([datetime]::Now.ToString('HH:mm:ss'))] $m" }
function 必须($code, $what) {
    if ($code -ne 0) { throw "$what 失败，exit=$code" }
}

记 '==== [1/7] depot_tools ===='
if (-not (Test-Path 'C:\depot_tools\gn.bat')) {
    git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git C:\depot_tools
    必须 $LASTEXITCODE 'clone depot_tools'
}
$env:PATH = "C:\depot_tools;$env:PATH"
记 'depot_tools ok'

记 '==== [2/7] Skia 源码 ===='
if (-not (Test-Path 'C:\skia\.git')) {
    git clone --depth 1 https://skia.googlesource.com/skia.git C:\skia
    必须 $LASTEXITCODE 'clone skia'
}
Set-Location C:\skia
$ver = (git rev-parse HEAD).Trim()
$ver | Out-File -FilePath VERSION.txt -Encoding ascii
记 "skia commit = $ver"

记 '==== [3/7] third_party 依赖（45 个）===='
python tools/git-sync-deps
必须 $LASTEXITCODE 'git-sync-deps'
记 '依赖完成'

记 '==== [4/7] 环境信息 ===='
cl | Select-String 'Microsoft' | Select-Object -First 2
try { $g = (& gn --version | Out-String).Trim() } catch { $g = "不可用" }
记 "gn = $g"
try { $n = (& ninja --version | Out-String).Trim() } catch { $n = "不可用" }
记 "ninja = $n"

记 '==== [5/7] gn gen ===='
$gnArgsLine = 'is_official_build=false is_debug=false target_cpu="x64" is_clang=false cc="cl" cxx="cl" skia_enable_ganesh=true skia_use_direct3d=true skia_use_dawn=false skia_use_harfbuzz=true skia_use_icu=true skia_enable_skparagraph=true skia_use_freetype=true is_component_build=false'
记 "ARGS: $gnArgsLine"
# 用 bash 传 --args：PowerShell 会吃掉参数里的双引号并按空格拆分
bash -c "cd /c/skia && gn gen out/Rel --args='$gnArgsLine'"
if ($LASTEXITCODE -ne 0) {
    Write-Host '--- gn 失败，args.gn ---'
    if (Test-Path out/Rel/args.gn) { Get-Content out/Rel/args.gn }
    throw "gn gen 失败 exit=$LASTEXITCODE"
}
记 'gn gen 完成'
Get-Content out/Rel/args.gn

记 '==== [6/7] ninja 编译 ===='
$env:NINJA_STATUS = '[%f/%t] '
bash -c "cd /c/skia && ninja -C out/Rel skia skparagraph skshaper skunicode | tee BUILD_LOG.txt"
if ($LASTEXITCODE -ne 0) { throw "ninja 失败 exit=$LASTEXITCODE，详见 BUILD_LOG.txt" }
记 '编译完成'

记 '==== [7/7] 打包 ===='
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
(cl | Select-String 'Microsoft') | Out-File -FilePath "$out/CL_VERSION.txt" -Encoding ascii
Get-ChildItem "$out/lib/*.lib" | Select-Object Name, @{n='MB';e={[math]::Round($_.Length/1MB,1)}} | Format-Table
Get-ChildItem "$out/lib/*.lib" | Get-FileHash -Algorithm SHA256 | ForEach-Object { "$($_.Hash.ToLower())  $(Split-Path $_.Path -Leaf)" } | Out-File -FilePath "$out/SHA256SUMS.txt" -Encoding ascii
Get-Content "$out/SHA256SUMS.txt"
记 '==== 完成 ===='
