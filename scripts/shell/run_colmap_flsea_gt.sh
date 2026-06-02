#!/bin/bash
set -e
###############################################################################
# Build COLMAP GT reconstruction for FLSea test scenes, matching the existing
# colmap_full/ structure of sub_pier and tiny_canyon.
#
# Existing reference structure (sub_pier 1091 frames, tiny_canyon 958 frames):
#   <scene>/colmap_full/
#     ├── database.db                  ← at root
#     ├── images/                      ← 6-digit names, all frames (symlinks)
#     └── sparse/0/{cameras,images,points3D}.bin
#   - No distorted/ subdir
#   - Input filenames are already 000000.jpg-style 6-digit padded
#
# Therefore the pipeline is straight 3-step (no image_undistorter needed,
# since input is already undistorted PINHOLE):
#   1. feature_extractor (PINHOLE, single_camera)
#   2. sequential_matcher (overlap=20)
#   3. mapper → sparse/0/
#
# Usage:
#   bash run_colmap_flsea_gt.sh <input_image_dir> <output_dir>
#
# Env override:
#   CAMERA_MODEL=PINHOLE
#   SEQ_OVERLAP=20
#   MATCHER=sequential            # or exhaustive
#   MAPPER_LOOSE=0                # =1 to enable loose registration thresholds
###############################################################################

INPUT_DIR="${1:?Usage: $0 <input_image_dir> <output_dir>}"
OUTPUT_DIR="${2:?missing output_dir}"

CAMERA_MODEL="${CAMERA_MODEL:-PINHOLE}"
SEQ_OVERLAP="${SEQ_OVERLAP:-20}"
MATCHER="${MATCHER:-sequential}"
MAPPER_LOOSE="${MAPPER_LOOSE:-0}"

INPUT_DIR=$(realpath "$INPUT_DIR")
OUTPUT_DIR=$(realpath -m "$OUTPUT_DIR")

mkdir -p "$OUTPUT_DIR/images" "$OUTPUT_DIR/sparse"

echo "=== Step 1: Symlink input → images/ (no renumbering — already 6-digit) ==="
find "$OUTPUT_DIR/images" -maxdepth 1 -type l -delete 2>/dev/null || true
shopt -s nullglob
for f in "$INPUT_DIR"/*.jpg "$INPUT_DIR"/*.JPG "$INPUT_DIR"/*.png "$INPUT_DIR"/*.PNG; do
    [ -f "$f" ] && ln -sf "$f" "$OUTPUT_DIR/images/$(basename "$f")"
done
shopt -u nullglob
N_TOTAL=$(ls "$OUTPUT_DIR/images" | wc -l)
echo "  $N_TOTAL frames linked"
[ "$N_TOTAL" -eq 0 ] && { echo "ERROR: no images"; exit 1; }

echo "=== Step 2: feature_extractor ($CAMERA_MODEL, single_camera) ==="
colmap feature_extractor \
    --database_path "$OUTPUT_DIR/database.db" \
    --image_path "$OUTPUT_DIR/images" \
    --ImageReader.camera_model "$CAMERA_MODEL" \
    --ImageReader.single_camera 1 \
    --SiftExtraction.use_gpu 1

echo "=== Step 3: ${MATCHER}_matcher ==="
if [ "$MATCHER" = "sequential" ]; then
    colmap sequential_matcher \
        --database_path "$OUTPUT_DIR/database.db" \
        --SequentialMatching.overlap "$SEQ_OVERLAP" \
        --SiftMatching.use_gpu 1
elif [ "$MATCHER" = "exhaustive" ]; then
    colmap exhaustive_matcher \
        --database_path "$OUTPUT_DIR/database.db" \
        --SiftMatching.use_gpu 1
else
    echo "ERROR: MATCHER must be sequential or exhaustive"; exit 1
fi

echo "=== Step 4: mapper → sparse/0/ ==="
MAPPER_ARGS=(
    --database_path "$OUTPUT_DIR/database.db"
    --image_path "$OUTPUT_DIR/images"
    --output_path "$OUTPUT_DIR/sparse"
)
if [ "$MAPPER_LOOSE" = "1" ]; then
    MAPPER_ARGS+=(
        --Mapper.min_num_matches 10
        --Mapper.abs_pose_min_num_inliers 15
        --Mapper.init_min_num_inliers 50
    )
fi
colmap mapper "${MAPPER_ARGS[@]}"

echo "=== Sanity check ==="
python3 -c "
import struct, glob, os
total = 0
for d in sorted(glob.glob('$OUTPUT_DIR/sparse/*')):
    ib = os.path.join(d, 'images.bin')
    if os.path.exists(ib):
        with open(ib,'rb') as f:
            n = struct.unpack('<Q', f.read(8))[0]
        print(f'  {d}: {n} images')
        total += n
print(f'  TOTAL registered: {total}/$N_TOTAL ({100*total/$N_TOTAL:.1f}%)')"

echo ""
echo "Output structure:"
echo "  $OUTPUT_DIR/database.db"
echo "  $OUTPUT_DIR/images/         ($N_TOTAL files, symlinks)"
echo "  $OUTPUT_DIR/sparse/0/       cameras.bin/images.bin/points3D.bin"
