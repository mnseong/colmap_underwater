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

# --- GPU 선택 (RTX 6000 Ada = GPU 1) ---
export CUDA_VISIBLE_DEVICES=1

echo "=== Step 1: conda 환경 생성 + 의존성 설치 ==="
echo "  gxx_linux-64 를 설치하지 않음 (sysroot 충돌 방지)"
echo "  시스템 GCC: $(gcc --version | head -1)"

# 기존 환경 제거 후 재생성
conda remove -n $ENV_NAME --all -y 2>/dev/null || true
conda create -n $ENV_NAME -y python=3.10
eval "$(conda shell.bash hook)"
conda activate $ENV_NAME

# gxx_linux-64 없이 라이브러리만 설치
conda install -y -c conda-forge \
    cmake \
    ninja \
    boost-cpp \
    eigen=3.4.0 \
    ceres-solver \
    glog \
    gflags \
    freeimage \
    flann \
    sqlite \
    metis \
    cgal-cpp \
    glew \
    lz4-c \
    mesa-libgl-devel-cos7-x86_64 \
    mesalib \
    libglvnd-devel-cos7-x86_64

echo "=== Step 1.5: conda sysroot 무력화 ==="
# 일부 conda 패키지가 sysroot를 의존성으로 가져올 수 있음
# 시스템 헤더와 충돌하므로 sysroot include를 비활성화
CONDA_SYSROOT="$CONDA_PREFIX/x86_64-conda-linux-gnu/sysroot"
if [ -d "$CONDA_SYSROOT/usr/include" ]; then
    echo "  conda sysroot 발견 — include 디렉토리 이름 변경"
    mv "$CONDA_SYSROOT/usr/include" "$CONDA_SYSROOT/usr/include.bak"
fi

# conda cross-compiler 환경변수 제거 (cmake가 참조하지 않도록)
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
unset CMAKE_SYSROOT
unset CONDA_BUILD_SYSROOT
unset BUILD_PREFIX
unset NVCC_PREPEND_FLAGS

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
    -DCMAKE_CXX_FLAGS="-I$CONDA_PREFIX/include" \
    -DCMAKE_C_FLAGS="-I$CONDA_PREFIX/include"

echo "=== Step 3: 빌드 ==="
ninja -j$(nproc)

echo "=== Step 4: 설치 ==="
ninja install

# conda 환경에 PATH 자동 등록
mkdir -p "$CONDA_PREFIX/etc/conda/activate.d"
cat > "$CONDA_PREFIX/etc/conda/activate.d/colmap.sh" << 'ACTIVATE_EOF'
export PATH="$HOME/colmap_underwater_install/bin:$PATH"
export LD_LIBRARY_PATH="/usr/local/cuda-12.4/lib64:$CONDA_PREFIX/lib:$LD_LIBRARY_PATH"
export CUDA_VISIBLE_DEVICES=1
ACTIVATE_EOF

echo ""
echo "=== 빌드 완료! ==="
echo ""
echo "사용법:"
echo "  conda activate $ENV_NAME"
echo "  colmap -h"
echo ""
