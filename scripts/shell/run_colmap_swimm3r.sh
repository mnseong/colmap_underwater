#!/bin/bash
set -e
###############################################################################
# Run COLMAP Underwater matched to Swimm3R setup (Track A: no refraction)
#
# - Swimm3R uses LLFF holdout (every 8th frame = test). COLMAP matches/maps
#   on train frames only, but all frames live in images/ for later query use.
# - swin winsize=5 (±5) is equivalent to sequential_matcher overlap=5.
# - Camera model PINHOLE (input is already undistorted).
#
# Usage:
#   bash run_colmap_swimm3r.sh <input_image_dir> <output_dir> [hold=8] [overlap=5]
#
# Env override:
#   CAMERA_MODEL=PINHOLE
#   ENABLE_REFRACTION=0       (set to 1 for Track B; needs CAMERA_REFRAC_MODEL/PARAMS)
#   CAMERA_REFRAC_MODEL=FLATPORT
#   CAMERA_REFRAC_PARAMS="0,0,1,0.03,0.01,1.0,1.49,1.334"
#
# Output:
#   <output_dir>/images/                              # all frames (symlinks)
#   <output_dir>/splits/{all,train,test}.txt
#   <output_dir>/database.db
#   <output_dir>/sparse/0/{cameras,images,points3D}.bin    # standard COLMAP
###############################################################################

INPUT_DIR="${1:?Usage: $0 <input_image_dir> <output_dir> [hold=8] [overlap=5]}"
OUTPUT_DIR="${2:?missing output_dir}"
LLFF_HOLD="${3:-8}"
SEQ_OVERLAP="${4:-5}"

CAMERA_MODEL="${CAMERA_MODEL:-PINHOLE}"
ENABLE_REFRACTION="${ENABLE_REFRACTION:-0}"
CAMERA_REFRAC_MODEL="${CAMERA_REFRAC_MODEL:-}"
CAMERA_REFRAC_PARAMS="${CAMERA_REFRAC_PARAMS:-}"

INPUT_DIR=$(realpath "$INPUT_DIR")
OUTPUT_DIR=$(realpath -m "$OUTPUT_DIR")

mkdir -p "$OUTPUT_DIR"/{images,splits,sparse}

echo "=== Step 1: Symlinking all frames to images/ ==="
find "$OUTPUT_DIR/images" -maxdepth 1 -type l -delete 2>/dev/null || true
shopt -s nullglob
for f in "$INPUT_DIR"/*.{jpg,jpeg,JPG,JPEG,png,PNG,tif,tiff,TIF,TIFF}; do
    [ -f "$f" ] && ln -sf "$f" "$OUTPUT_DIR/images/$(basename "$f")"
done
shopt -u nullglob
N_TOTAL=$(ls "$OUTPUT_DIR/images" | wc -l)
echo "  $N_TOTAL frames linked"
if [ "$N_TOTAL" -eq 0 ]; then
    echo "  ERROR: no image files found in $INPUT_DIR"
    exit 1
fi

echo "=== Step 2: LLFF holdout split (dust3r convention, 0-indexed) ==="
# dust3r/Swimm3R convention: idx % hold == 0  →  test
# i.e. frame 0, 8, 16, ... are test; remainder are train
ls "$OUTPUT_DIR/images" | sort > "$OUTPUT_DIR/splits/all.txt"
awk -v h="$LLFF_HOLD" '(NR-1)%h==0' "$OUTPUT_DIR/splits/all.txt" > "$OUTPUT_DIR/splits/test.txt"
awk -v h="$LLFF_HOLD" '(NR-1)%h!=0' "$OUTPUT_DIR/splits/all.txt" > "$OUTPUT_DIR/splits/train.txt"
N_TRAIN=$(wc -l < "$OUTPUT_DIR/splits/train.txt")
N_TEST=$(wc -l < "$OUTPUT_DIR/splits/test.txt")
echo "  total=$N_TOTAL  train=$N_TRAIN  test=$N_TEST  (hold=$LLFF_HOLD)"

echo "=== Step 3: Feature extraction (train only, $CAMERA_MODEL) ==="
FE_ARGS=(
    --database_path "$OUTPUT_DIR/database.db"
    --image_path "$OUTPUT_DIR/images"
    --image_list_path "$OUTPUT_DIR/splits/train.txt"
    --ImageReader.camera_model "$CAMERA_MODEL"
    --ImageReader.single_camera 1
    --SiftExtraction.use_gpu 1
)
if [ "$ENABLE_REFRACTION" = "1" ]; then
    if [ -z "$CAMERA_REFRAC_MODEL" ] || [ -z "$CAMERA_REFRAC_PARAMS" ]; then
        echo "  ERROR: ENABLE_REFRACTION=1 requires CAMERA_REFRAC_MODEL and CAMERA_REFRAC_PARAMS"
        exit 1
    fi
    FE_ARGS+=(--ImageReader.camera_refrac_model "$CAMERA_REFRAC_MODEL")
    FE_ARGS+=(--ImageReader.camera_refrac_params "$CAMERA_REFRAC_PARAMS")
fi
colmap feature_extractor "${FE_ARGS[@]}"

echo "=== Step 4: Sequential matching (overlap=$SEQ_OVERLAP, swin±5 equiv) ==="
colmap sequential_matcher \
    --database_path "$OUTPUT_DIR/database.db" \
    --SequentialMatching.overlap "$SEQ_OVERLAP" \
    --SiftMatching.use_gpu 1

echo "=== Step 5: Mapper (incremental SfM) ==="
MAPPER_ARGS=(
    --database_path "$OUTPUT_DIR/database.db"
    --image_path "$OUTPUT_DIR/images"
    --output_path "$OUTPUT_DIR/sparse"
)
if [ "$ENABLE_REFRACTION" = "1" ]; then
    MAPPER_ARGS+=(--Mapper.enable_refraction 1)
fi
colmap mapper "${MAPPER_ARGS[@]}"

echo ""
echo "=== Done ==="
echo "  Standard COLMAP output:  $OUTPUT_DIR/sparse/0/"
ls "$OUTPUT_DIR/sparse/0/" 2>/dev/null || echo "  (mapper may have produced multiple components; check $OUTPUT_DIR/sparse/)"
echo ""
echo "Layout:"
echo "  $OUTPUT_DIR/images/         all $N_TOTAL frames (symlinked)"
echo "  $OUTPUT_DIR/splits/train.txt   $N_TRAIN frames"
echo "  $OUTPUT_DIR/splits/test.txt    $N_TEST frames"
echo "  $OUTPUT_DIR/sparse/0/         standard cameras.bin/images.bin/points3D.bin"
