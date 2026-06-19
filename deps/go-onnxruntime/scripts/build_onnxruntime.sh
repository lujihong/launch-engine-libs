#!/bin/bash
# 编译 onnxruntime 1.26.0 静态库
# 用法: ./build_onnxruntime.sh [platform]
# platform: darwin-arm64, darwin-amd64, linux-amd64, linux-arm64, windows-amd64, windows-arm64
# 不指定 platform 则编译当前平台

set -euo pipefail

ORT_VERSION="1.26.0"
ORT_REPO="https://github.com/microsoft/onnxruntime"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/../_build"
LIB_DIR="${SCRIPT_DIR}/../lib"

# 检测当前平台
detect_platform() {
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')
    local arch=$(uname -m)
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
echo "=== 编译 onnxruntime ${ORT_VERSION} for ${PLATFORM} ==="

# 克隆源码
mkdir -p "${BUILD_DIR}"
if [ ! -d "${BUILD_DIR}/onnxruntime" ]; then
    echo ">>> 克隆 onnxruntime 源码..."
    git clone --depth 1 --branch "v${ORT_VERSION}" "${ORT_REPO}" "${BUILD_DIR}/onnxruntime"
fi

cd "${BUILD_DIR}/onnxruntime"

# 平台特定编译参数（--cmake_extra_defines 接受 KEY=VALUE 格式，不要 -D 前缀）
case "$PLATFORM" in
    darwin-arm64)
        CMAKE_EXTRA="CMAKE_OSX_ARCHITECTURES=arm64 CMAKE_OSX_DEPLOYMENT_TARGET=11.0"
        LIB_NAME="libonnxruntime.a"
        ;;
    darwin-amd64)
        CMAKE_EXTRA="CMAKE_OSX_ARCHITECTURES=x86_64 CMAKE_OSX_DEPLOYMENT_TARGET=10.15"
        LIB_NAME="libonnxruntime.a"
        ;;
    linux-amd64)
        CMAKE_EXTRA=""
        LIB_NAME="libonnxruntime.a"
        ;;
    linux-arm64)
        CMAKE_EXTRA="CMAKE_SYSTEM_PROCESSOR=aarch64"
        LIB_NAME="libonnxruntime.a"
        ;;
    windows-amd64)
        CMAKE_EXTRA="CMAKE_GENERATOR_PLATFORM=x64"
        LIB_NAME="onnxruntime.lib"
        ;;
    windows-arm64)
        CMAKE_EXTRA="CMAKE_GENERATOR_PLATFORM=ARM64"
        LIB_NAME="onnxruntime.lib"
        ;;
    *)
        echo "不支持的平台: ${PLATFORM}"
        exit 1
        ;;
esac

echo ">>> 编译中..."
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        # Windows: 使用 build.bat
        ./build.bat \
            --config Release \
            --parallel \
            --skip_tests \
            --skip_submodule_sync \
            --cmake_extra_defines \
                CMAKE_POSITION_INDEPENDENT_CODE=ON \
                BUILD_SHARED_LIBS=OFF \
                onnxruntime_BUILD_UNIT_TESTS=OFF \
                onnxruntime_BUILD_BENCHMARKS=OFF \
                ${CMAKE_EXTRA:+$CMAKE_EXTRA}
        ;;
    *)
        # macOS / Linux: 使用 build.sh
        ./build.sh \
            --config Release \
            --parallel \
            --skip_tests \
            --skip_submodule_sync \
            --cmake_extra_defines \
                CMAKE_POSITION_INDEPENDENT_CODE=ON \
                BUILD_SHARED_LIBS=OFF \
                onnxruntime_BUILD_UNIT_TESTS=OFF \
                onnxruntime_BUILD_BENCHMARKS=OFF \
                ${CMAKE_EXTRA:+$CMAKE_EXTRA}
        ;;
esac

# onnxruntime build.py 不会为所有依赖生成独立 .a 文件。
# re2 等库需要手动补建 target，然后作为独立 .a 拷贝到 lib/（不合并，避免同名 .o 冲突）。
echo ">>> 补建缺失的依赖静态库（re2 等）..."
BUILD_SUBDIR=$(find build -maxdepth 1 -type d ! -name build | head -1)
if [ -n "$BUILD_SUBDIR" ]; then
    CMAKE_BUILD_DIR="${BUILD_SUBDIR}/Release"
    [ -d "$CMAKE_BUILD_DIR" ] || CMAKE_BUILD_DIR="$BUILD_SUBDIR"
    cmake --build "$CMAKE_BUILD_DIR" --target re2 --config Release 2>/dev/null || true
fi

# onnxruntime 的多个组件库合并为单一 libonnxruntime.a
# 注意：re2 不合并（同名 .o 冲突），单独拷贝到 lib/ 由 CGO LDFLAGS -lre2 链接
echo ">>> 合并静态库..."
TARGET_DIR="${LIB_DIR}/${PLATFORM}"
mkdir -p "${TARGET_DIR}"

# 收集所有静态库文件（macOS/Linux 为 .a，Windows 为 .lib）
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        ALL_LIBS=$(find build -name "*.lib" 2>/dev/null)
        ;;
    *)
        # 排除 libre2.a（同名 .o 冲突，单独拷贝）
        ALL_LIBS=$(find build -name "*.a" ! -name "libre2.a" 2>/dev/null)
        ;;
esac

LIB_COUNT=$(echo "$ALL_LIBS" | grep -c . || true)

if [ "$LIB_COUNT" -eq 0 ]; then
    echo "错误: 未找到任何静态库文件"
    exit 1
fi
echo "    找到 ${LIB_COUNT} 个静态库，合并中..."

case "$(uname -s)" in
    Darwin)
        # macOS: 使用 libtool 合并所有 .a 为单一静态库
        libtool -static -o "${TARGET_DIR}/${LIB_NAME}" ${ALL_LIBS}
        ;;
    Linux)
        # Linux: 使用 ar MRI 脚本合并
        MRI_SCRIPT=$(mktemp)
        echo "CREATE ${TARGET_DIR}/${LIB_NAME}" > "$MRI_SCRIPT"
        for lib in ${ALL_LIBS}; do
            echo "ADDLIB $lib" >> "$MRI_SCRIPT"
        done
        echo "SAVE" >> "$MRI_SCRIPT"
        echo "END" >> "$MRI_SCRIPT"
        ar -M < "$MRI_SCRIPT"
        rm "$MRI_SCRIPT"
        ranlib "${TARGET_DIR}/${LIB_NAME}"
        ;;
    MINGW*|MSYS*|CYGWIN*)
        # Windows: 使用 lib.exe 合并所有 .lib
        lib.exe /OUT:"${TARGET_DIR}/${LIB_NAME}" ${ALL_LIBS}
        ;;
esac

echo ">>> 静态库已合并到 ${TARGET_DIR}/${LIB_NAME}"
ls -lh "${TARGET_DIR}/${LIB_NAME}"

# 单独拷贝 libre2.a（不合并，避免同名 .o 文件冲突）
RE2_LIB=$(find build -name "libre2.a" 2>/dev/null | head -1)
if [ -n "$RE2_LIB" ]; then
    cp "$RE2_LIB" "${TARGET_DIR}/libre2.a"
    echo ">>> libre2.a 已单独拷贝到 ${TARGET_DIR}/"
fi

# 拷贝头文件到 include/ 目录（供 go-onnxruntime 自身和 sherpa-onnx 编译使用）
INCLUDE_DIR="${SCRIPT_DIR}/../include"
mkdir -p "${INCLUDE_DIR}"

# 拷贝所有公开头文件到 include/ 根目录（无子目录结构）
# sherpa-onnx 用 #include "onnxruntime_cxx_api.h" / "coreml_provider_factory.h" 等无路径前缀
find include/onnxruntime -name "*.h" -exec cp {} "${INCLUDE_DIR}/" \;

# 同步更新 go-onnxruntime 包根目录的 C API 头文件（CGO 编译用）
# 先确保目标文件可写（历史上曾出现只读属性导致 cp 静默失败、头文件未升级的问题）
PKG_ROOT="${SCRIPT_DIR}/.."
chmod u+w "${PKG_ROOT}/onnxruntime_c_api.h" "${PKG_ROOT}/onnxruntime_ep_c_api.h" 2>/dev/null || true
cp "${INCLUDE_DIR}/onnxruntime_c_api.h" "${PKG_ROOT}/"
[ -f "${INCLUDE_DIR}/onnxruntime_ep_c_api.h" ] && cp "${INCLUDE_DIR}/onnxruntime_ep_c_api.h" "${PKG_ROOT}/"

echo ">>> 头文件已更新到 ${INCLUDE_DIR}/"
ls "${INCLUDE_DIR}/"

echo "=== 完成: ${PLATFORM} ==="
