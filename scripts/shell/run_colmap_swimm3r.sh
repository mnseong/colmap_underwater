#!/bin/bash
set -e
###############################################################################
# Run COLMAP Underwater matched to Swimm3R setup (Track A: no refraction)
#
# Spec source: Swimm3R Train/Test Split Protocol
#   - LLFF-style hold-out, llffhold=8 (frame index 0, 8, 16, ... = test)
#   - alphabetical sort by basename, then hold-out (deterministic)
#   - swin winsize=5  →  sequential_matcher overlap=10 (= 2*winsize, conservative)
#   - Train frames only enter feature_extractor/matcher/mapper
#   - All frames live in images/ for downstream localization eval
#   - Camera model PINHOLE (input is already in-air-undistorted)
#
# Usage:
#   bash run_colmap_swimm3r.sh <input_image_dir> <output_dir> [options]
#
# Options (positional, in order):
#   $3 = LLFF_HOLD (default 8)
#   $4 = SEQ_OVERLAP (default 10  = 2 * winsize=5)
#
# Env override:
#   SPLIT_JSON=<path>           # Use Swimm3R split.json as source of truth
#                               # (its train_files/test_files override LLFF gen)
#   PSEUDO_GT=1                 # Build pseudo-GT map with ALL frames (no split)
#   CAMERA_MODEL=PINHOLE
#   ENABLE_REFRACTION=0         # =1 for Track B (needs refrac model/params)
#   CAMERA_REFRAC_MODEL=FLATPORT
#   CAMERA_REFRAC_PARAMS="0,0,1,0.03,0.01,1.0,1.49,1.334"
#
# Output:
#   <output_dir>/images/                              # all frames (symlinks)
#   <output_dir>/splits/{all,train,test}.txt
#   <output_dir>/split.json                           # Swimm3R-compatible split
#   <output_dir>/database.db
#   <output_dir>/sparse/0/{cameras,images,points3D}.bin    # standard COLMAP
###############################################################################

INPUT_DIR="${1:?Usage: $0 <input_image_dir> <output_dir> [hold=8] [overlap=10]}"
OUTPUT_DIR="${2:?missing output_dir}"
LLFF_HOLD="${3:-8}"
SEQ_OVERLAP="${4:-10}"

SPLIT_JSON="${SPLIT_JSON:-}"
PSEUDO_GT="${PSEUDO_GT:-0}"
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

echo "=== Step 2: Train/test split ==="
ls "$OUTPUT_DIR/images" | sort > "$OUTPUT_DIR/splits/all.txt"

if [ "$PSEUDO_GT" = "1" ]; then
    echo "  PSEUDO_GT=1 → using ALL frames as train (no hold-out)"
    cp "$OUTPUT_DIR/splits/all.txt" "$OUTPUT_DIR/splits/train.txt"
    : > "$OUTPUT_DIR/splits/test.txt"
elif [ -n "$SPLIT_JSON" ] && [ -f "$SPLIT_JSON" ]; then
    echo "  Reading split from $SPLIT_JSON (Swimm3R source of truth)"
    python3 -c "
import json, sys
s = json.load(open('$SPLIT_JSON'))
open('$OUTPUT_DIR/splits/train.txt','w').write('\n'.join(s['train_files'])+'\n')
open('$OUTPUT_DIR/splits/test.txt','w').write('\n'.join(s['test_files'])+'\n')
print(f'    llffhold={s.get(\"llffhold\")} all={len(s[\"all_files\"])} '
      f'train={len(s[\"train_files\"])} test={len(s[\"test_files\"])}')"
else
    echo "  Generating LLFF holdout (dust3r convention, 0-indexed, hold=$LLFF_HOLD)"
    # idx % hold == 0  →  test  (frame 0, 8, 16, ...)
    awk -v h="$LLFF_HOLD" '(NR-1)%h==0' "$OUTPUT_DIR/splits/all.txt" > "$OUTPUT_DIR/splits/test.txt"
    awk -v h="$LLFF_HOLD" '(NR-1)%h!=0' "$OUTPUT_DIR/splits/all.txt" > "$OUTPUT_DIR/splits/train.txt"
fi

N_TRAIN=$(wc -l < "$OUTPUT_DIR/splits/train.txt")
N_TEST=$(wc -l < "$OUTPUT_DIR/splits/test.txt")
echo "  total=$N_TOTAL  train=$N_TRAIN  test=$N_TEST"

# Write Swimm3R-compatible split.json for sanity checks
python3 -c "
import json
all_f = open('$OUTPUT_DIR/splits/all.txt').read().splitlines()
tr_f  = open('$OUTPUT_DIR/splits/train.txt').read().splitlines()
te_f  = open('$OUTPUT_DIR/splits/test.txt').read().splitlines()
json.dump({'all_files': all_f, 'train_files': tr_f, 'test_files': te_f,
           'llffhold': $LLFF_HOLD, 'pseudo_gt': bool($PSEUDO_GT)},
          open('$OUTPUT_DIR/split.json','w'), indent=2)"

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

echo "=== Step 4: Sequential matching (overlap=$SEQ_OVERLAP) ==="
# Note: overlap=10 mirrors Swimm3R spec (= 2 * winsize=5), slightly larger
# neighborhood than swin to be conservative for COLMAP's sparse SIFT.
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
echo "=== Sanity check ==="
python3 -c "
import json, struct, os
s = json.load(open('$OUTPUT_DIR/split.json'))
print(f'  split: all={len(s[\"all_files\"])} train={len(s[\"train_files\"])} test={len(s[\"test_files\"])} llffhold={s[\"llffhold\"]}')
img_bin = '$OUTPUT_DIR/sparse/0/images.bin'
if os.path.exists(img_bin):
    with open(img_bin,'rb') as f:
        n = struct.unpack('<Q', f.read(8))[0]
    print(f'  registered in sparse/0: {n}  (should == train_files = {len(s[\"train_files\"])})')
    if n == len(s['train_files']):
        print('  ✓ all train frames registered')
    elif n < len(s['train_files']):
        print(f'  ⚠ {len(s[\"train_files\"])-n} train frame(s) failed to register')
    else:
        print(f'  ✗ LEAK: {n - len(s[\"train_files\"])} extra image(s) — test frames may have entered')
else:
    print(f'  ⚠ {img_bin} not found (mapper may have split into multiple components)')
    import glob
    for d in sorted(glob.glob('$OUTPUT_DIR/sparse/*')):
        if os.path.exists(os.path.join(d,'images.bin')):
            with open(os.path.join(d,'images.bin'),'rb') as f:
                n = struct.unpack('<Q', f.read(8))[0]
            print(f'    {d}: {n} images')
"

echo ""
echo "=== Done ==="
echo "Layout:"
echo "  $OUTPUT_DIR/images/         all $N_TOTAL frames (symlinked)"
echo "  $OUTPUT_DIR/split.json      Swimm3R-compatible split"
echo "  $OUTPUT_DIR/splits/{train,test}.txt"
echo "  $OUTPUT_DIR/sparse/0/       standard cameras.bin/images.bin/points3D.bin"
