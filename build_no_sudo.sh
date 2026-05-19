#!/bin/bash
set -e

###############################################################################
# colmap_underwater 빌드 스크립트 (sudo/docker 없이, conda 기반)
#
# 요구사항:
#   - conda (miniconda/anaconda)
#   - 시스템 GCC (11.x 권장, /usr/bin/gcc)
#   - CUDA toolkit (시스템 설치)
#
# 사용법:
#   cd /data/minseong/src/colmap_underwater
#   bash build_no_sudo.sh
#
# 빌드 완료 후:
#   conda activate colmap_build
#   colmap -h
###############################################################################

# --- 설정 ---
ENV_NAME="colmap_build"
CUDA_PATH="/usr/local/cuda-12.4"
CUDA_ARCH="89"                       # RTX 6000 Ada = 8.9
INSTALL_PREFIX="$HOME/colmap_underwater_install"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- GPU 선택 (RTX 6000 Ada, UUID로 지정 — index는 환경마다 바뀔 수 있음) ---
GPU_UUID="GPU-6d227fd1-fa09-a654-2a56-036811cd2b43"
export CUDA_VISIBLE_DEVICES="$GPU_UUID"

echo "=== Step 1: conda 환경 준비 ==="
echo "  gxx_linux-64 를 설치하지 않음 (sysroot 충돌 방지)"
echo "  시스템 GCC: $(gcc --version | head -1)"

eval "$(conda shell.bash hook)"

# 환경이 없을 때만 생성 (재실행 시 기존 환경 재사용)
if ! conda env list | awk '{print $1}' | grep -qx "$ENV_NAME"; then
    echo "  환경 '$ENV_NAME' 생성 중..."
    conda create -n $ENV_NAME -y python=3.10
else
    echo "  환경 '$ENV_NAME' 이미 존재 — 재사용"
fi
conda activate $ENV_NAME

# 필요한 패키지 목록 (이미 설치된 건 conda가 알아서 skip)
REQUIRED_PKGS=(
    cmake
    ninja
    boost-cpp
    "eigen=3.4.0"
    ceres-solver
    glog
    gflags
    freeimage
    flann
    sqlite
    metis
    cgal-cpp
    glew
    lz4-c
    mesa-libgl-devel-cos7-x86_64
    mesalib
    libglvnd-devel-cos7-x86_64
)

# 누락된 패키지만 추출해서 설치 (있는 건 skip — 빠르게 진행)
MISSING_PKGS=()
INSTALLED=$(conda list -n $ENV_NAME --no-pip 2>/dev/null | awk 'NR>3 {print $1}')
for pkg in "${REQUIRED_PKGS[@]}"; do
    name="${pkg%%=*}"
    if ! echo "$INSTALLED" | grep -qx "$name"; then
        MISSING_PKGS+=("$pkg")
    fi
done

if [ ${#MISSING_PKGS[@]} -eq 0 ]; then
    echo "  모든 conda 의존성이 이미 설치됨 — skip"
else
    echo "  누락된 패키지 설치: ${MISSING_PKGS[*]}"
    conda install -y -c conda-forge "${MISSING_PKGS[@]}"
fi

echo "=== Step 1.5: conda sysroot 전체 무력화 ==="
# sysroot/usr/include 는 시스템 헤더와 충돌
# sysroot/usr/lib 는 GLIBC_PRIVATE 심볼 참조로 시스템 glibc 2.35와 링크 실패
# (예: librt.so가 __libc_dlopen_mode@GLIBC_PRIVATE 참조)
# 따라서 sysroot 디렉토리 전체를 이름 변경해서 cmake가 못 찾게 만듦
CONDA_SYSROOT="$CONDA_PREFIX/x86_64-conda-linux-gnu/sysroot"
if [ -d "$CONDA_SYSROOT" ] && [ ! -L "$CONDA_SYSROOT" ]; then
    echo "  conda sysroot 발견 — 전체 디렉토리 이름 변경"
    mv "$CONDA_SYSROOT" "$CONDA_SYSROOT.bak"
elif [ -d "$CONDA_SYSROOT.bak" ]; then
    echo "  conda sysroot 이미 무력화됨 — skip"
else
    echo "  conda sysroot 없음 — skip"
fi

# conda cross-compiler 환경변수 제거 (cmake가 참조하지 않도록)
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
unset CMAKE_SYSROOT
unset CONDA_BUILD_SYSROOT
unset BUILD_PREFIX
unset NVCC_PREPEND_FLAGS

echo "=== Step 1.7: OpenGL preference 패치 (GLVND -> LEGACY) ==="
FIND_DEPS="$SRC_DIR/cmake/FindDependencies.cmake"
if grep -q "OpenGL_GL_PREFERENCE GLVND" "$FIND_DEPS"; then
    sed -i 's/OpenGL_GL_PREFERENCE GLVND/OpenGL_GL_PREFERENCE LEGACY/' "$FIND_DEPS"
    echo "  $FIND_DEPS 패치 완료"
else
    echo "  이미 패치됨 또는 GLVND 라인 없음 — skip"
fi

echo "=== Step 1.8: libGL 위치 탐색 (sysroot 우회) ==="
LIBGL=""
for candidate in \
    "$CONDA_PREFIX/lib/libGL.so" \
    "$CONDA_PREFIX/lib/libGL.so.1" \
    "/usr/lib/x86_64-linux-gnu/libGL.so" \
    "/usr/lib/x86_64-linux-gnu/libGL.so.1" \
    "/usr/lib64/libGL.so" \
    "/usr/lib64/libGL.so.1" ; do
    if [ -e "$candidate" ]; then
        LIBGL="$candidate"
        break
    fi
done

LIBGL_INC=""
for candidate in \
    "$CONDA_PREFIX/include" \
    "/usr/include" ; do
    if [ -f "$candidate/GL/gl.h" ]; then
        LIBGL_INC="$candidate"
        break
    fi
done

if [ -z "$LIBGL" ] || [ -z "$LIBGL_INC" ]; then
    echo "  ERROR: libGL.so 또는 GL/gl.h 를 못 찾음"
    echo "    libGL: $LIBGL"
    echo "    GL/gl.h dir: $LIBGL_INC"
    echo "  시스템에 OpenGL 런타임/헤더가 필요합니다."
    exit 1
fi
echo "  libGL: $LIBGL"
echo "  GL include dir: $LIBGL_INC"

echo "=== Step 2: cmake 구성 ==="
cd "$SRC_DIR"
rm -rf build
mkdir build && cd build

export CUDA_HOME="$CUDA_PATH"
export PATH="$CUDA_PATH/bin:$PATH"
export LD_LIBRARY_PATH="$CUDA_PATH/lib64:$CONDA_PREFIX/lib:$LD_LIBRARY_PATH"

cmake .. -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
    -DCMAKE_PREFIX_PATH="$CONDA_PREFIX" \
    -DCMAKE_C_COMPILER="/usr/bin/gcc" \
    -DCMAKE_CXX_COMPILER="/usr/bin/g++" \
    -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH" \
    -DCUDA_TOOLKIT_ROOT_DIR="$CUDA_PATH" \
    -DCMAKE_CUDA_HOST_COMPILER="/usr/bin/g++" \
    -DEigen3_DIR="$CONDA_PREFIX/share/eigen3/cmake" \
    -DGUI_ENABLED=OFF \
    -DTESTS_ENABLED=OFF \
    -DOPENGL_ENABLED=OFF \
    -DOPENGL_gl_LIBRARY="$LIBGL" \
    -DOPENGL_INCLUDE_DIR="$LIBGL_INC" \
    -DCMAKE_CXX_FLAGS="-I$CONDA_PREFIX/include" \
    -DCMAKE_C_FLAGS="-I$CONDA_PREFIX/include"

echo "=== Step 3: 빌드 ==="
ninja -j$(nproc)

echo "=== Step 4: 설치 ==="
ninja install

# conda 환경에 PATH 자동 등록
mkdir -p "$CONDA_PREFIX/etc/conda/activate.d"
cat > "$CONDA_PREFIX/etc/conda/activate.d/colmap.sh" << ACTIVATE_EOF
export PATH="\$HOME/colmap_underwater_install/bin:\$PATH"
export LD_LIBRARY_PATH="/usr/local/cuda-12.4/lib64:\$CONDA_PREFIX/lib:\$LD_LIBRARY_PATH"
# RTX 6000 Ada — UUID로 고정 (서버에서 index가 바뀌어도 안전)
export CUDA_VISIBLE_DEVICES="$GPU_UUID"
ACTIVATE_EOF

echo ""
echo "=== 빌드 완료! ==="
echo ""
echo "사용법:"
echo "  conda activate $ENV_NAME"
echo "  colmap -h"
echo ""
