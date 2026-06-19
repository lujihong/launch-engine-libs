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
# EXTRA_BUILD_FLAGS：build.py 的额外 flags（CoreML / KleidiAI 等），按平台设，默认空。
EXTRA_BUILD_FLAGS=""
case "$PLATFORM" in
    darwin-arm64)
        # --use_coreml：开 CoreML 执行后端（Apple 芯片走神经引擎 ANE 加速 ASR/嵌入/视觉）。
        # CMAKE_SKIP_INSTALL_RULES=ON：CoreML+静态下 onnxruntime 的 install(EXPORT) 引用了未导出的
        # coreml_proto 会在 generate 报错；我们不用它的 install(自己从 build/ 捞 .a 合并)，跳过即绕开。
        CMAKE_EXTRA="CMAKE_OSX_ARCHITECTURES=arm64 CMAKE_OSX_DEPLOYMENT_TARGET=11.0 CMAKE_SKIP_INSTALL_RULES=ON"
        LIB_NAME="libonnxruntime.a"
        EXTRA_BUILD_FLAGS="--use_coreml"
        ;;
    darwin-amd64)
        # --use_coreml：CoreML 后端（Intel Mac 走 CPU/GPU，Apple 芯片经 Rosetta 跑时仍可用）。
        # CMAKE_SKIP_INSTALL_RULES=ON：同 arm64，绕开 CoreML install(EXPORT) coreml_proto 报错。
        CMAKE_EXTRA="CMAKE_OSX_ARCHITECTURES=x86_64 CMAKE_OSX_DEPLOYMENT_TARGET=10.15 CMAKE_SKIP_INSTALL_RULES=ON"
        LIB_NAME="libonnxruntime.a"
        EXTRA_BUILD_FLAGS="--use_coreml"
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
        # Ninja + msvc-dev-cmd 的 cl.exe(x64)。x86 上 KleidiAI/SVE 不参与，关闭（与已验证配置一致）。
        CMAKE_EXTRA=""
        LIB_NAME="onnxruntime.lib"
        EXTRA_BUILD_FLAGS="--no_kleidiai --no_sve"
        ;;
    windows-arm64)
        # arm64 用 clang-cl（clang 的 MSVC 驱动）：能编 KleidiAI/SVE 的 GNU 汇编/intrinsics（MSVC cl.exe 编不了），
        # 且产 MSVC ABI 库（与后续 clang-MSVC app 链接一致）。KleidiAI/SVE 保留（性能），故不传 --no_kleidiai/--no_sve。
        # CMAKE_RC_COMPILER=llvm-rc：clang-cl 工具链下编译标志(/bigobj 等)会漏传给 rc.exe(报 RC1106)，
        # 改用 LLVM 配套的 llvm-rc(对这些标志宽容；VS 的 Llvm/ARM64 自带，与 clang-cl 同目录)。
        # CMAKE_ASM_MARMASM_COMPILER=clang-cl：KleidiAI 的 .S 是 GNU AArch64 汇编(含 .arch 指令)，
        # 微软 armasm64 语法不同且不认 /arch→报 A2029；改用 clang-cl 集成汇编器汇编这些 .S。
        CMAKE_EXTRA="CMAKE_C_COMPILER=clang-cl CMAKE_CXX_COMPILER=clang-cl CMAKE_RC_COMPILER=llvm-rc CMAKE_ASM_MARMASM_COMPILER=clang-cl"
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
        # Windows: build.bat。--cmake_generator Ninja：直接用已激活的编译器，不走 "Visual Studio 17 2022"
        # 生成器（其 vswhere 在已激活 vcvars 环境下会报 could not find VS）。
        # EXTRA_BUILD_FLAGS（见上 case）：amd64=--no_kleidiai --no_sve（x86 无关）；arm64 空（用 clang-cl 保留 KleidiAI/SVE）。
        # CMAKE_EXTRA（arm64）= clang-cl 编译器（KleidiAI 的 GNU 汇编 MSVC 编不了，clang 可以）。
        ./build.bat \
            --config Release \
            --parallel \
            --skip_tests \
            --skip_submodule_sync \
            --cmake_generator Ninja \
            --compile_no_warning_as_error \
            ${EXTRA_BUILD_FLAGS} \
            --cmake_extra_defines \
                CMAKE_POSITION_INDEPENDENT_CODE=ON \
                BUILD_SHARED_LIBS=OFF \
                onnxruntime_BUILD_UNIT_TESTS=OFF \
                onnxruntime_BUILD_BENCHMARKS=OFF \
                CMAKE_POLICY_VERSION_MINIMUM=3.5 \
                ${CMAKE_EXTRA:+$CMAKE_EXTRA}
        ;;
    *)
        # macOS / Linux: 使用 build.sh。EXTRA_BUILD_FLAGS（见上 case）：darwin=--use_coreml（CoreML 后端）。
        ./build.sh \
            --config Release \
            --parallel \
            --skip_tests \
            --skip_submodule_sync \
            --compile_no_warning_as_error \
            ${EXTRA_BUILD_FLAGS} \
            --cmake_extra_defines \
                CMAKE_POSITION_INDEPENDENT_CODE=ON \
                BUILD_SHARED_LIBS=OFF \
                onnxruntime_BUILD_UNIT_TESTS=OFF \
                onnxruntime_BUILD_BENCHMARKS=OFF \
                CMAKE_POLICY_VERSION_MINIMUM=3.5 \
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
        # Windows: lib.exe 合并所有 .lib。Git Bash 会把 "/OUT:" 误当 POSIX 路径转换
        # （→ C:\Program Files\Git\OUT;… 触发 LNK1104）。用 "-OUT:"（短横不触发转换）
        # + cygpath -w 输出绝对 Windows 路径；MSYS_NO_PATHCONV=1 关参数路径转换，输入 .lib
        # 用相对正斜杠路径（lib.exe 接受，cwd=onnxruntime 仓根）。
        OUT_WIN=$(cygpath -w "${TARGET_DIR}/${LIB_NAME}")
        MSYS_NO_PATHCONV=1 lib.exe "-OUT:${OUT_WIN}" ${ALL_LIBS}
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
