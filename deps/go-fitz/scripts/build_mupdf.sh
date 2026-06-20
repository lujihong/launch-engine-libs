#!/bin/bash
# 编译 MuPDF 静态库(MSVC /MT)给 go-fitz 用——产出 mupdf_windows_<arch>.lib + mupdfthird_windows_<arch>.lib。
# 用法: ./build_mupdf.sh windows-amd64 | windows-arm64
#
# 为什么:go-fitz(gen2brain/go-fitz)只自带 MinGW .a,MSVC lld-link 用不了。我们走 go-fitz **默认模式**
#   (#cgo CFLAGS:-Iinclude 用其自带 1.24.9 头;LDFLAGS:-lmupdf_windows_<arch> -lmupdfthird_windows_<arch>),
#   只需在链接路径放同名的 **MSVC /MT 静态 .lib** 顶替即可(clang-msvc 把 -lfoo 译成 foo.lib,不会误选 .a)。
# 版本铁律:MuPDF 必须 1.24.9——与 go-fitz v1.24.15 自带头 FZ_VERSION "1.24.9" 严格一致(结构体 ABI)。
# CRT 铁律:必须 /MT(MultiThreaded),与 onnx/sherpa/cgo 全家桶一致,否则撞 RuntimeLibrary mismatch。
set -euo pipefail

MUPDF_VERSION="1.24.9"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/../_build"
LIB_DIR="${SCRIPT_DIR}/../lib"

PLATFORM="${1:?用法: build_mupdf.sh windows-amd64|windows-arm64}"
case "$PLATFORM" in
    windows-amd64) MSB_PLAT="x64";   ARCH="amd64" ;;
    windows-arm64) MSB_PLAT="ARM64"; ARCH="arm64" ;;
    *) echo "不支持的平台: $PLATFORM(本脚本只编 Windows mupdf)"; exit 1 ;;
esac
echo "=== 编译 MuPDF ${MUPDF_VERSION} for ${PLATFORM}(MSVC /MT 静态) ==="

# 克隆 MuPDF + submodule(thirdparty:freetype/harfbuzz/jbig2dec/openjpeg/... 必需)
mkdir -p "${BUILD_DIR}"
SRC="${BUILD_DIR}/mupdf"
if [ ! -d "${SRC}/.git" ]; then
    echo ">>> 克隆 MuPDF ${MUPDF_VERSION} + submodule(较大,首次慢)..."
    git clone --depth 1 --branch "${MUPDF_VERSION}" --recurse-submodules --shallow-submodules \
        https://github.com/ArtifexSoftware/mupdf "${SRC}"
fi
cd "${SRC}"
WIN32="platform/win32"

# ---- patch 1:全部 lib 工程 (a) /MD→/MT(纯静态 CRT) (b) 关 /GL 全程序优化 ----
# /GL(WholeProgramOptimization=true)产的 .obj 是 IL 中间格式(非原生 COFF),只有 MSVC link.exe 能消费,
# lld-link 报 "is not a native COFF file. Recompile without /GL"。关掉 → 原生 COFF(且库体积从数百 MB 砍到几十 MB)。
echo ">>> patch: MultiThreadedDLL→MultiThreaded + WholeProgramOptimization(/GL) true→false(全 .vcxproj)"
for vcx in "${WIN32}"/*.vcxproj; do
    sed -i \
        -e 's#<RuntimeLibrary>MultiThreadedDLL</RuntimeLibrary>#<RuntimeLibrary>MultiThreaded</RuntimeLibrary>#g' \
        -e 's#<RuntimeLibrary>MultiThreadedDebugDLL</RuntimeLibrary>#<RuntimeLibrary>MultiThreadedDebug</RuntimeLibrary>#g' \
        -e 's#<WholeProgramOptimization>true</WholeProgramOptimization>#<WholeProgramOptimization>false</WholeProgramOptimization>#g' \
        "$vcx"
done

# ---- patch 2(仅 arm64):官方 1.24.9 .sln/.vcxproj 无 ARM64 平台 + bin2coff.c 不认 ARM64 ----
# 注:此段为 best-effort,首跑大概率要按 CI 日志迭代(.sln 平台映射 / bin2coff 机器码传参细节)。
if [ "$MSB_PLAT" = "ARM64" ]; then
    echo ">>> patch(arm64): .vcxproj 复制 x64 配置块为 ARM64 + mupdf.sln 加 ARM64 平台 + bin2coff.c 支持 AArch64"
    PYTHONUTF8=1 PYTHONIOENCODING=utf-8 python3 - "$WIN32" <<'PYEOF'
import sys, re, glob, os
win32 = sys.argv[1]

# 1) 每个 .vcxproj:把 |x64 的 ProjectConfiguration + 条件 PropertyGroup/ItemDefinitionGroup 复制一份成 |ARM64
for vcx in glob.glob(os.path.join(win32, "*.vcxproj")):
    s = open(vcx, encoding="utf-8", errors="replace").read()
    if "|ARM64" in s:
        continue  # 已有 ARM64 配置,跳过
    pcs = re.findall(r'(\s*<ProjectConfiguration Include="[^"]*\|x64">.*?</ProjectConfiguration>)', s, re.S)
    add = "".join(b.replace("|x64", "|ARM64").replace(">x64<", ">ARM64<") for b in pcs)
    if add:
        s = s.replace("</ItemGroup>", add + "\n  </ItemGroup>", 1)
    conds = re.findall(r"(\s*<(PropertyGroup|ItemDefinitionGroup)[^>]*Condition=\"'\$\(Configuration\)\|\$\(Platform\)'=='[^']*\|x64'\"[^>]*>.*?</\2>)", s, re.S)
    addc = "".join(b[0].replace("|x64'", "|ARM64'") for b in conds)
    if addc:
        s = s.replace("</Project>", addc + "\n</Project>", 1)
    # 去掉所有 ProjectReference:ARM64 下 MSBuild 的 AssignProjectConfiguration 跨工程解析触发 MSB3107。
    # 我们各库独立编 + 手动合并 .lib,根本不需要级联引用(静态库不链接依赖,只归档自身 .obj)。
    s = re.sub(r"[ \t]*<ProjectReference\b[^>]*>.*?</ProjectReference>\s*\r?\n?", "", s, flags=re.S)
    open(vcx, "w", encoding="utf-8").write(s)
    print("  vcxproj +ARM64 / -ProjectReference:", os.path.basename(vcx))

# 2) mupdf.sln:加 Release|ARM64 解决方案配置 + 每工程的 Release|ARM64 → Release|ARM64 映射
#    (含 bin2coff:在 arm64 原生 runner 上原生编 arm64,运行 + 经 patch 后的 bin2coff.c 出 ARM64 字体目标)
sln = os.path.join(win32, "mupdf.sln")
s = open(sln, encoding="utf-8", errors="replace").read()
if "Release|ARM64 = Release|ARM64" not in s:
    # SolutionConfigurationPlatforms:在 Release|x64 行后插 Release|ARM64
    s = re.sub(r"(\t\tRelease\|x64 = Release\|x64\r?\n)",
               r"\1\t\tRelease|ARM64 = Release|ARM64\r\n", s, count=1)
    # ProjectConfigurationPlatforms:每条 {GUID}.Release|x64.(ActiveCfg|Build.0) = Release|(x64|Win32) 后
    # 追加一条 .Release|ARM64.<同> = Release|ARM64(全部工程都编 ARM64)
    s = re.sub(
        r"(\t\t(\{[0-9A-Fa-f-]+\})\.Release\|x64\.(ActiveCfg|Build\.0) = Release\|(?:x64|Win32))(\r?\n)",
        lambda m: m.group(1) + m.group(4) + "\t\t" + m.group(2) + ".Release|ARM64." + m.group(3) + " = Release|ARM64" + m.group(4),
        s)
    open(sln, "w", encoding="utf-8").write(s)
    print("  mupdf.sln +Release|ARM64 (solution config + all project mappings)")
PYEOF
    # bin2coff.c:增加 ARM64(0xAA64)机器码;原 1.24.9 仅 I386/AMD64。仅 arm64 构建走此分支,故无条件出 ARM64。
    if ! grep -q "IMAGE_FILE_MACHINE_ARM64" scripts/bin2coff.c; then
        sed -i \
            -e 's@#define IMAGE_FILE_MACHINE_AMD64\(\s*\)0x8664@#define IMAGE_FILE_MACHINE_AMD64\1 0x8664\n#define IMAGE_FILE_MACHINE_ARM64 0xAA64@' \
            -e 's@file_header->Machine = (x86_32)?IMAGE_FILE_MACHINE_I386:IMAGE_FILE_MACHINE_AMD64;@file_header->Machine = IMAGE_FILE_MACHINE_ARM64;@' \
            scripts/bin2coff.c
        echo "  patched bin2coff.c → ARM64"
    fi
fi

# ---- 编译 libmupdf(经 ProjectReference 级联编 thirdparty/resources/harfbuzz/pkcs7/extract/tesseract) ----
# **必须走 .sln(而非直接 .vcxproj)**:.sln 有 per-project 配置映射,把宿主工具 bin2coff 的
# 「方案 Release|x64」正确映射成它自己的 Release|Win32(bin2coff 只有 Win32 配置,是 x86 宿主小工具)。
# 直接 msbuild libmupdf.vcxproj 会把 x64 强加给被引用的 bin2coff → MSB8013 "doesn't contain Release|x64"。
# 不强制 PlatformToolset(用 runner 的 VS 默认;之前各工程已能编,说明默认 toolset 可用)。
if [ "$MSB_PLAT" = "ARM64" ]; then
    # arm64:已去掉所有 ProjectReference(避开 ARM64 跨工程解析 MSB3107),故**各工程逐个独立编**。
    # bin2coff 先编(libresources 字体生成的 CustomBuild 命令是 `Release\bin2coff.exe ... $(Platform)`):
    #   其 OutDir=$(SolutionDir)$(Configuration)\,直编需显式给 SolutionDir 指向 win32 目录,bin2coff.exe 才落到
    #   win32/Release/(=字体命令找的相对 Release\)。bin2coff 编成 ARM64,在 arm64 runner 原生跑,出 ARM64 字体目标。
    WIN32_ABS=$(cygpath -m "$(pwd)/${WIN32}")
    echo ">>> arm64:先编 bin2coff(SolutionDir=${WIN32_ABS}/)..."
    MSBuild.exe "${WIN32}/bin2coff.vcxproj" -p:Configuration=Release -p:Platform=ARM64 -p:SolutionDir="${WIN32_ABS}/" -m -v:minimal -nologo
    for proj in libthirdparty libharfbuzz libleptonica libtesseract libpkcs7 libextract libresources libmupdf; do
        echo ">>> arm64:编 ${proj}.vcxproj..."
        MSBuild.exe "${WIN32}/${proj}.vcxproj" -p:Configuration=Release -p:Platform=ARM64 -p:SolutionDir="${WIN32_ABS}/" -m -v:minimal -nologo
    done
else
    # amd64:走 .sln -t:libmupdf。bin2coff 仅 Win32 配置,.sln 把它的 Release|x64 映射成 Release|Win32,
    # 让这个 x86 宿主工具正确按 Win32 编(直编 .vcxproj 会把 x64 强加给它 → MSB8013)。
    echo ">>> MSBuild mupdf.sln -t:libmupdf(Release|x64)..."
    MSBuild.exe "${WIN32}/mupdf.sln" -t:libmupdf -p:Configuration=Release -p:Platform=x64 -m -v:minimal -nologo
fi

# ---- 收集 .lib:libmupdf → mupdf_windows_<arch>.lib;其余全部合并 → mupdfthird_windows_<arch>.lib ----
echo ">>> 收集 + 合并静态库..."
TARGET_DIR="${LIB_DIR}/${PLATFORM}"
mkdir -p "${TARGET_DIR}"

ALL_LIBS=$(find "${WIN32}" -name "*.lib" -path "*${MSB_PLAT}/Release*" 2>/dev/null)
[ -n "$ALL_LIBS" ] || { echo "✗ 未在 ${WIN32}/**/Release 下找到任何 .lib"; find "${WIN32}" -name "*.lib" | head; exit 1; }
echo "找到的 .lib:"; echo "$ALL_LIBS" | sed 's#.*/##' | sort -u

CORE=$(echo "$ALL_LIBS" | grep -iE "/libmupdf\.lib$" | head -1)
[ -n "$CORE" ] || { echo "✗ 未找到 libmupdf.lib(核心库)"; exit 1; }
cp "$CORE" "${TARGET_DIR}/mupdf_windows_${ARCH}.lib"
echo "  核心: $(basename "$CORE") → mupdf_windows_${ARCH}.lib"

# 其余(libthirdparty/libresources/libharfbuzz/libpkcs7/libextract/libtesseract/libleptonica...)合并为 third
THIRD_INPUTS=$(echo "$ALL_LIBS" | grep -ivE "/libmupdf\.lib$")
OUT_THIRD=$(cygpath -w "${TARGET_DIR}/mupdfthird_windows_${ARCH}.lib")
# shellcheck disable=SC2086
MSYS_NO_PATHCONV=1 lib.exe "-OUT:${OUT_THIRD}" $THIRD_INPUTS
echo "  其余库合并 → mupdfthird_windows_${ARCH}.lib"

echo "=== 完成: ${PLATFORM} ==="
ls -lh "${TARGET_DIR}/"
