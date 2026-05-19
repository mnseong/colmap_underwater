#!/bin/bash
set -e
###############################################################################
# Batch-run Swimm3R-matched COLMAP for Barbados video1..video4
#
# Paths (per the dataset layout):
#   split.json : /data/minseong/datasets/Barbados_swimm3r/videoN/split.json
#   input imgs : /data/minseong/datasets/Barbados_colmap/videoN_undist/images
#   output     : ${COLMAP_ROOT:-/data/minseong/datasets/Barbados_colmap_v2}/videoN/
#                 ├── images/      all frames (symlinks)
#                 └── sparse/0/    COLMAP map (standard format)
#
# Usage:
#   bash run_colmap_swimm3r_barbados.sh                # all of video1..video4
#   bash run_colmap_swimm3r_barbados.sh 1 3            # only video1 and video3
#
# Env override (forwarded to run_colmap_swimm3r.sh):
#   COLMAP_ROOT=...         # output root  (default: Barbados_colmap_v2)
#   PSEUDO_GT=1             # use ALL frames (train+test) for SfM
#   ENABLE_REFRACTION=1     # Track B (needs CAMERA_REFRAC_MODEL/PARAMS)
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$SCRIPT_DIR/run_colmap_swimm3r.sh"

SWIMM3R_ROOT="/data/minseong/datasets/Barbados_swimm3r"
COLMAP_ROOT="${COLMAP_ROOT:-/data/minseong/datasets/Barbados_colmap_v2}"
INPUT_ROOT="${INPUT_ROOT:-/data/minseong/datasets/Barbados_colmap}"
# Image subdir under each videoN_undist/  (default: images, UIE: images_uie)
INPUT_SUBDIR="${INPUT_SUBDIR:-images}"

# Which videos to run (default: 1 2 3 4)
if [ $# -gt 0 ]; then
    VIDEOS=("$@")
else
    VIDEOS=(1 2 3 4)
fi

echo "=== Batch config ==="
echo "  INPUT_ROOT=$INPUT_ROOT  INPUT_SUBDIR=$INPUT_SUBDIR"
echo "  COLMAP_ROOT=$COLMAP_ROOT"
echo "  PSEUDO_GT=${PSEUDO_GT:-0}"
echo "  ENABLE_REFRACTION=${ENABLE_REFRACTION:-0}"
echo "  videos: ${VIDEOS[*]}"

for N in "${VIDEOS[@]}"; do
    echo ""
    echo "############################################################"
    echo "###  video$N"
    echo "############################################################"
    SPLIT="$SWIMM3R_ROOT/video$N/split.json"
    INPUT="$INPUT_ROOT/video${N}_undist/$INPUT_SUBDIR"
    OUTPUT="$COLMAP_ROOT/video$N"

    if [ ! -f "$SPLIT" ]; then
        echo "  SKIP: split.json missing at $SPLIT"
        continue
    fi
    if [ ! -d "$INPUT" ]; then
        echo "  SKIP: input image dir missing at $INPUT"
        continue
    fi

    # PSEUDO_GT=1 then we ignore SPLIT_JSON (run_colmap_swimm3r.sh will use
    # all frames as train). Otherwise pass split.json as source of truth.
    if [ "${PSEUDO_GT:-0}" = "1" ]; then
        bash "$RUNNER" "$INPUT" "$OUTPUT"
    else
        SPLIT_JSON="$SPLIT" bash "$RUNNER" "$INPUT" "$OUTPUT"
    fi
done

echo ""
echo "=== All requested videos done ==="
