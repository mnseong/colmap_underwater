#!/bin/bash
set -e
###############################################################################
# Batch-run Swimm3R-matched COLMAP for Barbados video1..video4
#
# Paths (per the dataset layout):
#   split.json : /data/minseong/datasets/Barbados_swimm3r/videoN/split.json
#   input imgs : /data/minseong/datasets/Barbados_colmap/videoN_undist/images
#   output     : /data/minseong/datasets/Barbados_colmap/videoN/
#                 ├── images/      all frames (symlinks)
#                 └── sparse/0/    train-only COLMAP map (standard format)
#
# Usage:
#   bash run_colmap_swimm3r_barbados.sh                # all of video1..video4
#   bash run_colmap_swimm3r_barbados.sh 1 3            # only video1 and video3
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$SCRIPT_DIR/run_colmap_swimm3r.sh"

SWIMM3R_ROOT="/data/minseong/datasets/Barbados_swimm3r"
COLMAP_ROOT="/data/minseong/datasets/Barbados_colmap"

# Which videos to run (default: 1 2 3 4)
if [ $# -gt 0 ]; then
    VIDEOS=("$@")
else
    VIDEOS=(1 2 3 4)
fi

for N in "${VIDEOS[@]}"; do
    echo ""
    echo "############################################################"
    echo "###  video$N"
    echo "############################################################"
    SPLIT="$SWIMM3R_ROOT/video$N/split.json"
    INPUT="$COLMAP_ROOT/video${N}_undist/images"
    OUTPUT="$COLMAP_ROOT/video$N"

    if [ ! -f "$SPLIT" ]; then
        echo "  SKIP: split.json missing at $SPLIT"
        continue
    fi
    if [ ! -d "$INPUT" ]; then
        echo "  SKIP: input image dir missing at $INPUT"
        continue
    fi

    SPLIT_JSON="$SPLIT" bash "$RUNNER" "$INPUT" "$OUTPUT"
done

echo ""
echo "=== All requested videos done ==="
