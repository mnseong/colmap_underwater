#!/bin/bash
set -e

###############################################################################
# colmap_underwater 빌드 스크립트 (sudo/docker 없이, conda 기반)
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
CUDA_PATH="/usr/local/cuda-12.4"    # 서버에 있는 CUDA 경로
CUDA_ARCH="89"                       # RTX 6000 Ada = 8.9
INSTALL_PREFIX="$HOME/colmap_underwater_install"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Step 1: conda 환경 생성 + 의존성 설치 ==="
conda create -n $ENV_NAME -y python=3.10
eval "$(conda shell.bash hook)"
conda activate $ENV_NAME

conda install -y -c conda-forge \
    cmake \
    ninja \
    gxx_linux-64 \
    boost-cpp \
    eigen \
    ceres-solver \
    glog \
    gflags \
    freeimage \
    flann \
    sqlite \
    metis \
    cgal-cpp \
    glew \
    lz4-c

echo "=== Step 2: cmake 구성 ==="
cd "$SRC_DIR"
rm -rf build
mkdir build && cd build

export CUDA_HOME="$CUDA_PATH"
export PATH="$CUDA_PATH/bin:$PATH"
export LD_LIBRARY_PATH="$CUDA_PATH/lib64:$CONDA_PREFIX/lib:$LD_LIBRARY_PATH"
export CMAKE_PREFIX_PATH="$CONDA_PREFIX:$CMAKE_PREFIX_PATH"

cmake .. -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX" \
    -DCMAKE_PREFIX_PATH="$CONDA_PREFIX" \
    -DCMAKE_C_COMPILER="$(which x86_64-conda-linux-gnu-gcc)" \
    -DCMAKE_CXX_COMPILER="$(which x86_64-conda-linux-gnu-g++)" \
    -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH" \
    -DCUDA_TOOLKIT_ROOT_DIR="$CUDA_PATH" \
    -DGUI_ENABLED=OFF \
    -DTESTS_ENABLED=OFF \
    -DOPENGL_ENABLED=OFF

echo "=== Step 3: 빌드 ==="
ninja -j$(nproc)

echo "=== Step 4: 설치 ==="
ninja install

# conda 환경에 PATH 자동 등록
mkdir -p "$CONDA_PREFIX/etc/conda/activate.d"
echo "export PATH=\"$INSTALL_PREFIX/bin:\$PATH\"" > "$CONDA_PREFIX/etc/conda/activate.d/colmap.sh"
echo "export LD_LIBRARY_PATH=\"$CUDA_PATH/lib64:$CONDA_PREFIX/lib:\$LD_LIBRARY_PATH\"" >> "$CONDA_PREFIX/etc/conda/activate.d/colmap.sh"

echo ""
echo "=== 빌드 완료! ==="
echo ""
echo "사용법:"
echo "  conda activate $ENV_NAME"
echo "  colmap -h"
echo ""
