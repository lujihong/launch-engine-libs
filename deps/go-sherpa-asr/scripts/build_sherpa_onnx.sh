#!/bin/bash
# 编译 sherpa-onnx 静态库（链接自编译的 onnxruntime 1.27.0）
# 用法: ./build_sherpa_onnx.sh [platform]
# platform: darwin-arm64, darwin-amd64, linux-amd64, linux-arm64, windows-amd64, windows-arm64
# 不指定则编译当前平台
#
# 前提：go-onnxruntime/lib/{platform}/libonnxruntime.a 已编译完成

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ORT_PKG_DIR="${SCRIPT_DIR}/../../go-onnxruntime"
BUILD_DIR="${SCRIPT_DIR}/../_build"
LIB_DIR="${SCRIPT_DIR}/../lib"

detect_platform() {
    local os arch
    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    arch=$(uname -m)
    case "$os" in
        darwin) os="darwin" ;;
        linux)  os="linux" ;;
        mingw*|msys*|cygwin*) os="windows" ;;
    esac
    case "$arch" in
        x86_64|amd64) arch="amd64" ;;
        arm64|aarch64) arch="arm64" ;;
    esac
    echo "${os}-${arch}"
}

PLATFORM="${1:-$(detect_platform)}"
echo "=== 编译 sherpa-onnx for ${PLATFORM} ==="

# 验证 onnxruntime 静态库存在
ORT_LIB_DIR="${ORT_PKG_DIR}/lib/${PLATFORM}"
if [ "$PLATFORM" = "windows-amd64" ] || [ "$PLATFORM" = "windows-arm64" ]; then
    ORT_STATIC="${ORT_LIB_DIR}/onnxruntime.lib"
else
    ORT_STATIC="${ORT_LIB_DIR}/libonnxruntime.a"
fi
if [ ! -f "$ORT_STATIC" ]; then
    echo "错误: 未找到 onnxruntime 静态库: $ORT_STATIC"
    echo "请先运行 go-onnxruntime/scripts/build_onnxruntime.sh ${PLATFORM}"
    exit 1
fi

# 固定 sherpa-onnx 版本，确保各平台编译产出一致。
# v1.13.3 起内置 NVIDIA Nemotron-3.5 streaming ASR（多语种，按流 SetOption("language",…)）——
# 切换版本后须删 _build/sherpa-onnx 旧 clone 让其重拉对应 tag。
SHERPA_VERSION="v1.13.3"

# 克隆 sherpa-onnx 源码
mkdir -p "${BUILD_DIR}"
if [ ! -d "${BUILD_DIR}/sherpa-onnx" ]; then
    echo ">>> 克隆 sherpa-onnx ${SHERPA_VERSION} 源码..."
    git clone --depth 1 --branch "${SHERPA_VERSION}" https://github.com/k2-fsa/sherpa-onnx "${BUILD_DIR}/sherpa-onnx"
fi

cd "${BUILD_DIR}/sherpa-onnx"

# 平台特定 cmake 参数
case "$PLATFORM" in
    darwin-arm64)  CMAKE_EXTRA="-DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0" ;;
    darwin-amd64)  CMAKE_EXTRA="-DCMAKE_OSX_ARCHITECTURES=x86_64 -DCMAKE_OSX_DEPLOYMENT_TARGET=10.15" ;;
    linux-arm64)   CMAKE_EXTRA="-DCMAKE_SYSTEM_PROCESSOR=aarch64" ;;
    linux-amd64)   CMAKE_EXTRA="" ;;
    windows-amd64) CMAKE_EXTRA="-G Ninja" ;; # Ninja + msvc-dev-cmd 的 cl.exe(x64)，避开 VS 生成器找不到 VS
    windows-arm64) CMAKE_EXTRA="-G Ninja" ;; # arm64 由 amd64_arm64 交叉 cl.exe 提供
    *) CMAKE_EXTRA="" ;;
esac

# 通过环境变量让 sherpa-onnx 使用我们自编译的 onnxruntime 1.27.0 静态库
# 参见 cmake/onnxruntime.cmake 中的 SHERPA_ONNXRUNTIME_INCLUDE_DIR / SHERPA_ONNXRUNTIME_LIB_DIR
# 头文件目录需包含 onnxruntime_cxx_api.h（sherpa-onnx 源码用 #include "onnxruntime_cxx_api.h"）
export SHERPA_ONNXRUNTIME_INCLUDE_DIR="${ORT_PKG_DIR}/include"
export SHERPA_ONNXRUNTIME_LIB_DIR="${ORT_LIB_DIR}"

echo ">>> 使用外部 onnxruntime:"
echo "    头文件: ${SHERPA_ONNXRUNTIME_INCLUDE_DIR}"
echo "    静态库: ${SHERPA_ONNXRUNTIME_LIB_DIR}"

# Windows 纯静态：sherpa 上游 cmake/onnxruntime.cmake 在 Win 写死假设 onnxruntime 是 DLL
# （add_library SHARED IMPORTED + 非 GPU 分支 IMPORTED_IMPLIB 为空 → 报参数不全）。
# 喂我们预编译的静态 onnxruntime.lib 会崩。patch 成 STATIC IMPORTED + 去掉空 IMPLIB：
# sherpa 只需 onnxruntime 头文件来编译自身静态库；onnxruntime 符号在最终 Go app 链接时解析。
if [ "$PLATFORM" = "windows-amd64" ] || [ "$PLATFORM" = "windows-arm64" ]; then
    echo ">>> patch cmake/onnxruntime.cmake 接受静态 onnxruntime（Windows 纯静态）"
    python - <<'PYEOF'
import re
p = "cmake/onnxruntime.cmake"
s = open(p, encoding="utf-8").read()
assert "add_library(onnxruntime SHARED IMPORTED)" in s, "上游结构变了，需重核 patch"
s = s.replace("add_library(onnxruntime SHARED IMPORTED)",
              "add_library(onnxruntime STATIC IMPORTED)")
s = re.sub(r'\n[ \t]*IMPORTED_IMPLIB \$\{location_onnxruntime_lib2\}', '', s)
open(p, "w", encoding="utf-8").write(s)
print("    patched: SHARED->STATIC, removed empty IMPORTED_IMPLIB")
PYEOF
fi

# CoreML：darwin 开启（不传 DISABLE_COREML，用 onnxruntime 的 CoreML 后端，需 onnx 也 --use_coreml 编）；
# windows/linux CoreML 不可用，传 DISABLE 避免编无关代码。
if [[ "$PLATFORM" == darwin-* ]]; then
    COREML_CXX_FLAGS=""
else
    COREML_CXX_FLAGS="-DSHERPA_ONNX_DISABLE_COREML"
fi

echo ">>> 编译中（含 TTS 支持）..."
# 清旧构建目录:防残留 CMakeCache 把上次的 Debug/CRT 配置粘进来(IDL=2 在 CI 复现的常见真因之一)。
rm -rf build install
# -DCMAKE_BUILD_TYPE=Release:**必须显式给**。Windows 用 -G Ninja(单配置生成器),后面的
#   `cmake --build --config Release` 是 no-op,build type 只在 configure 期由本变量定;不给则可能落到
#   含 _DEBUG 的配置 → _ITERATOR_DEBUG_LEVEL=2,与 onnx(Release,IDL=0)撞 /failifmismatch。
# -DSHERPA_ONNX_USE_STATIC_CRT=ON:锁死 /MT 静态 CRT(sherpa 默认已 ON,显式化防上游改默认;非 MSVC 平台无副作用)。
cmake -S . -B build \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_BUILD_TYPE=Release \
    -DSHERPA_ONNX_USE_STATIC_CRT=ON \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DSHERPA_ONNX_USE_PRE_INSTALLED_ONNXRUNTIME_IF_AVAILABLE=ON \
    -DCMAKE_CXX_FLAGS="${COREML_CXX_FLAGS}" \
    -DCMAKE_C_FLAGS="${COREML_CXX_FLAGS}" \
    -DSHERPA_ONNX_ENABLE_C_API=ON \
    -DSHERPA_ONNX_ENABLE_TTS=ON \
    -DSHERPA_ONNX_ENABLE_WEBSOCKET=OFF \
    -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF \
    -DSHERPA_ONNX_ENABLE_PYTHON=OFF \
    -DSHERPA_ONNX_ENABLE_TESTS=OFF \
    -DSHERPA_ONNX_ENABLE_BINARY=OFF \
    -DCMAKE_INSTALL_PREFIX=./install \
    ${CMAKE_EXTRA}

cmake --build build --config Release -j "$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
cmake --install build --config Release

# 拷贝静态库到 lib/ 目录（排除 libonnxruntime.a，由 go-onnxruntime 提供）
TARGET_DIR="${LIB_DIR}/${PLATFORM}"
mkdir -p "${TARGET_DIR}"

echo ">>> 拷贝静态库（排除 libonnxruntime.a）..."
for lib in install/lib/*.a; do
    [ -f "$lib" ] || continue  # Windows 无 .a(产 .lib)；glob 未匹配会保留字面量,跳过避免 cp 报错+set -e 退出
    libname="$(command basename "$lib")"
    if [ "$libname" = "libonnxruntime.a" ]; then
        echo "    跳过: $libname（由 go-onnxruntime 提供）"
        continue
    fi
    cp "$lib" "${TARGET_DIR}/"
    echo "    拷贝: $libname"
done

# Windows .lib 文件
for lib in install/lib/*.lib; do
    [ -f "$lib" ] || continue
    libname="$(command basename "$lib")"
    if [ "$libname" = "onnxruntime.lib" ]; then
        echo "    跳过: $libname（由 go-onnxruntime 提供）"
        continue
    fi
    cp "$lib" "${TARGET_DIR}/"
    echo "    拷贝: $libname"
done

# 更新 c-api.h（先确保目标文件可写）
if [ -f install/include/sherpa-onnx/c-api/c-api.h ]; then
    chmod u+w "${SCRIPT_DIR}/../c-api.h" 2>/dev/null || true
    cp install/include/sherpa-onnx/c-api/c-api.h "${SCRIPT_DIR}/../c-api.h"
    echo ">>> c-api.h 已更新"
fi

echo "=== 完成: ${PLATFORM} ==="
echo "静态库位于: ${TARGET_DIR}/"
ls -lh "${TARGET_DIR}/"
