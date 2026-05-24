#!/bin/bash
set -e
###############################################################################
# Build a clean COLMAP dataset from in-air images, aiming for 100% registration.
#
# Strategy: try progressively more aggressive settings until 100% reg or
# we exhaust all attempts. Each attempt overwrites the previous DB/sparse.
#
# Usage:
#   bash run_colmap_clean.sh <input_image_dir> <output_dir>
#
# Env override:
#   CAMERA_MODEL=SIMPLE_RADIAL    # use PINHOLE if input already undistorted
#   SINGLE_CAMERA=1               # all images share one intrinsics
#   MATCHER_PRIMARY=sequential    # sequential | exhaustive | vocab_tree
#   SEQ_OVERLAP=10                # for sequential
#   MAX_IMAGE_SIZE=3200           # SIFT max image size
#   ATTEMPTS="default exhaustive exhaustive_aggressive"
#                                 # ordered list of attempt names to try
#
# Output:
#   <output_dir>/images/                              # all frames (symlinks)
#   <output_dir>/database.db
#   <output_dir>/sparse/0/{cameras,images,points3D}.bin   # standard COLMAP
#   <output_dir>/registration_report.json             # per-attempt stats
###############################################################################

INPUT_DIR="${1:?Usage: $0 <input_image_dir> <output_dir>}"
OUTPUT_DIR="${2:?missing output_dir}"

CAMERA_MODEL="${CAMERA_MODEL:-SIMPLE_RADIAL}"
SINGLE_CAMERA="${SINGLE_CAMERA:-1}"
MATCHER_PRIMARY="${MATCHER_PRIMARY:-sequential}"
SEQ_OVERLAP="${SEQ_OVERLAP:-10}"
MAX_IMAGE_SIZE="${MAX_IMAGE_SIZE:-3200}"
ATTEMPTS="${ATTEMPTS:-default exhaustive exhaustive_aggressive}"

INPUT_DIR=$(realpath "$INPUT_DIR")
OUTPUT_DIR=$(realpath -m "$OUTPUT_DIR")
mkdir -p "$OUTPUT_DIR/images" "$OUTPUT_DIR/sparse"

echo "=== Step 1: Symlink all images ==="
find "$OUTPUT_DIR/images" -maxdepth 1 -type l -delete 2>/dev/null || true
shopt -s nullglob
for f in "$INPUT_DIR"/*.{jpg,jpeg,JPG,JPEG,png,PNG,tif,tiff,TIF,TIFF}; do
    [ -f "$f" ] && ln -sf "$f" "$OUTPUT_DIR/images/$(basename "$f")"
done
shopt -u nullglob
N_TOTAL=$(ls "$OUTPUT_DIR/images" | wc -l)
echo "  $N_TOTAL frames linked"
[ "$N_TOTAL" -eq 0 ] && { echo "ERROR: no image files found"; exit 1; }

# Helper: count images registered in sparse/0..N
count_registered() {
    python3 -c "
import struct, glob, os
total = 0
for d in sorted(glob.glob('$OUTPUT_DIR/sparse/*')):
    ib = os.path.join(d, 'images.bin')
    if os.path.exists(ib):
        with open(ib, 'rb') as f:
            total += struct.unpack('<Q', f.read(8))[0]
print(total)"
}
count_components() {
    ls -d "$OUTPUT_DIR"/sparse/*/ 2>/dev/null | wc -l
}

REPORT_TMP=$(mktemp)
echo "[" > "$REPORT_TMP"

run_attempt() {
    local name="$1"
    echo ""
    echo "############################################################"
    echo "###  Attempt: $name"
    echo "############################################################"

    rm -f "$OUTPUT_DIR/database.db"
    rm -rf "$OUTPUT_DIR/sparse"
    mkdir -p "$OUTPUT_DIR/sparse"

    # Per-attempt settings
    local matcher="$MATCHER_PRIMARY"
    local seq_overlap="$SEQ_OVERLAP"
    local peak_thresh="0.0066"
    local edge_thresh="10"
    local max_num_features="8192"

    case "$name" in
        default)
            ;;
        exhaustive)
            matcher="exhaustive"
            ;;
        exhaustive_aggressive)
            matcher="exhaustive"
            peak_thresh="0.004"          # lower → more keypoints
            edge_thresh="20"
            max_num_features="16384"
            ;;
        *)
            echo "  unknown attempt name: $name"; return 1 ;;
    esac

    echo "  matcher=$matcher  peak_thresh=$peak_thresh  max_features=$max_num_features"

    echo "  -- feature_extractor --"
    colmap feature_extractor \
        --database_path "$OUTPUT_DIR/database.db" \
        --image_path "$OUTPUT_DIR/images" \
        --ImageReader.camera_model "$CAMERA_MODEL" \
        --ImageReader.single_camera "$SINGLE_CAMERA" \
        --SiftExtraction.use_gpu 1 \
        --SiftExtraction.max_image_size "$MAX_IMAGE_SIZE" \
        --SiftExtraction.max_num_features "$max_num_features" \
        --SiftExtraction.peak_threshold "$peak_thresh" \
        --SiftExtraction.edge_threshold "$edge_thresh"

    echo "  -- ${matcher}_matcher --"
    if [ "$matcher" = "sequential" ]; then
        colmap sequential_matcher \
            --database_path "$OUTPUT_DIR/database.db" \
            --SequentialMatching.overlap "$seq_overlap" \
            --SiftMatching.use_gpu 1
    elif [ "$matcher" = "exhaustive" ]; then
        colmap exhaustive_matcher \
            --database_path "$OUTPUT_DIR/database.db" \
            --SiftMatching.use_gpu 1
    elif [ "$matcher" = "vocab_tree" ]; then
        echo "  ERROR: vocab_tree needs --VocabTreeMatching.vocab_tree_path; not auto-configured"
        return 1
    fi

    echo "  -- mapper --"
    colmap mapper \
        --database_path "$OUTPUT_DIR/database.db" \
        --image_path "$OUTPUT_DIR/images" \
        --output_path "$OUTPUT_DIR/sparse"

    local reg=$(count_registered)
    local comps=$(count_components)
    local rate=$(python3 -c "print(f'{100*$reg/$N_TOTAL:.1f}')")
    echo ""
    echo "  Result: registered=$reg/$N_TOTAL ($rate%)  components=$comps"

    echo "  {\"attempt\":\"$name\",\"registered\":$reg,\"total\":$N_TOTAL,\"rate\":$rate,\"components\":$comps}," >> "$REPORT_TMP"

    [ "$reg" -eq "$N_TOTAL" ] && [ "$comps" -eq 1 ]
}

SUCCESS=0
for attempt in $ATTEMPTS; do
    if run_attempt "$attempt"; then
        SUCCESS=1
        echo ""
        echo "✓ 100% registration achieved with single component on attempt '$attempt'"
        break
    fi
done

# Finalize report
sed -i '$ s/,$//' "$REPORT_TMP"
echo "]" >> "$REPORT_TMP"
mv "$REPORT_TMP" "$OUTPUT_DIR/registration_report.json"

echo ""
echo "=== Done ==="
cat "$OUTPUT_DIR/registration_report.json"
echo ""
if [ "$SUCCESS" -eq 1 ]; then
    echo "Layout (100% registered):"
    echo "  $OUTPUT_DIR/images/         all $N_TOTAL frames"
    echo "  $OUTPUT_DIR/sparse/0/       cameras.bin/images.bin/points3D.bin"
else
    REG=$(count_registered)
    echo "⚠ Did not reach 100%. Best: $REG/$N_TOTAL"
    echo "  $OUTPUT_DIR/sparse/         multiple components or partial registration"
    echo "  Consider:"
    echo "    - Lower MAX_IMAGE_SIZE if memory-bound"
    echo "    - Different CAMERA_MODEL (current: $CAMERA_MODEL)"
    echo "    - Visual inspection of failed frames"
    exit 2
fi
