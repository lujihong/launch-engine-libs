#!/bin/bash
# 编译 sherpa-onnx 静态库（链接自编译的 onnxruntime 1.25.0）
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

# 固定 sherpa-onnx 版本，确保各平台编译产出一致
SHERPA_VERSION="v1.12.39"

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
    windows-amd64) CMAKE_EXTRA="-DCMAKE_GENERATOR_PLATFORM=x64" ;;
    windows-arm64) CMAKE_EXTRA="-DCMAKE_GENERATOR_PLATFORM=ARM64" ;;
    *) CMAKE_EXTRA="" ;;
esac

# 通过环境变量让 sherpa-onnx 使用我们自编译的 onnxruntime 1.25.0 静态库
# 参见 cmake/onnxruntime.cmake 中的 SHERPA_ONNXRUNTIME_INCLUDE_DIR / SHERPA_ONNXRUNTIME_LIB_DIR
# 头文件目录需包含 onnxruntime_cxx_api.h（sherpa-onnx 源码用 #include "onnxruntime_cxx_api.h"）
export SHERPA_ONNXRUNTIME_INCLUDE_DIR="${ORT_PKG_DIR}/include"
export SHERPA_ONNXRUNTIME_LIB_DIR="${ORT_LIB_DIR}"

echo ">>> 使用外部 onnxruntime:"
echo "    头文件: ${SHERPA_ONNXRUNTIME_INCLUDE_DIR}"
echo "    静态库: ${SHERPA_ONNXRUNTIME_LIB_DIR}"

echo ">>> 编译中（含 TTS 支持）..."
cmake -S . -B build \
    -DBUILD_SHARED_LIBS=OFF \
    -DSHERPA_ONNX_USE_PRE_INSTALLED_ONNXRUNTIME_IF_AVAILABLE=ON \
    -DCMAKE_CXX_FLAGS="-DSHERPA_ONNX_DISABLE_COREML" \
    -DCMAKE_C_FLAGS="-DSHERPA_ONNX_DISABLE_COREML" \
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
