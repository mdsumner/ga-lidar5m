#!/bin/bash -l
#SBATCH --job-name=ga5m-cog
#SBATCH --account=pawsey1362
#SBATCH --partition=work
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --time=12:00:00
#SBATCH --array=0-11
#SBATCH --output=%x-%a.out
#
# Stage 1b: zip'd TIFF -> COG, one zone per array task.
#
# Probe (2026-10-01) confirmed each zip holds one internally-uncompressed
# striped Float32 tif (up to 354GB uncompressed for nationalz55_ag), so by
# default we translate STRAIGHT FROM /vsizip/ -- a single sequential
# streaming inflate, no extraction, no ~1TB of intermediate scratch. The
# COG driver reads its source exactly once, which is the one access
# pattern a DEFLATE zip entry handles well. Set EXTRACT=1 to fall back to
# unzip-then-translate if any zip misbehaves.
#
#   sbatch --chdir=$MYSCRATCH/ga-lidar-5m 02_cogify.sbatch /path/to/zones.tsv
#
# GDAL comes from a container by default (swap GDAL_IMAGE for your own
# gdal-builds image, or replace RUN with a module load if a system gdal
# suits). Time/mem are sized for the 10.8GB zone-55 zip with headroom;
# the small zones will finish in minutes.

set -euo pipefail
MANIFEST="${1:?pass zones.tsv path as the sbatch argument}"
BASEDIR="${BASEDIR:-$MYSCRATCH/ga-lidar-5m}"
mkdir -p "$BASEDIR/cog" "$BASEDIR/work"

module load singularity/4.1.0-slurm
## default to the local sif convention ("extra" shell); LD_LIBRARY_PATH is
## cleared to avoid clashes with host software. Override SIF to use another
## image, e.g. SIF=docker://ghcr.io/osgeo/gdal:ubuntu-full-latest sbatch ...
SIF="${SIF:-$MYSOFTWARE/sif_lib/gdal-r-python-extras_latest.sif}"
RUN="singularity exec --env LD_LIBRARY_PATH= --bind $BASEDIR $SIF"

line=$(grep -v '^#' "$MANIFEST" | sed -n "$((SLURM_ARRAY_TASK_ID + 1))p")
IFS=$'\t' read -r idx name epsg tag size_hint url <<< "$line"
zip="$BASEDIR/zips/$name.zip"
out="$BASEDIR/cog/ga_lidar5m_${tag}_${name}.tif"
[ -s "$zip" ] || { echo "missing $zip -- run 01_download first"; exit 1; }
[ -s "$out" ] && { echo "$out exists, skipping"; exit 0; }

if [ "${EXTRACT:-0}" = "1" ]; then
  work="$BASEDIR/work/$name"; rm -rf "$work"; mkdir -p "$work"
  ( cd "$work" && python3 -m zipfile -e "$zip" . )
  grid=$(find "$work" -name "*.tif" | head -1)
  [ -n "$grid" ] || { echo "no tif in $name -- check probe"; exit 1; }
  echo "$name: extracted to $grid"
else
  work=""
  grid="/vsizip/$zip/$name.tif"
  echo "$name: streaming from $grid"
fi

## probe showed the inner tifs are TILED 128x128 (not striped): translate
## swaths still advance monotonically, but a large block cache + swath
## size guarantees no backward seek ever reaches the DEFLATE stream (a
## backward seek on /vsizip restarts inflation from byte zero).
SECONDS=0
$RUN gdal_translate "$grid" "$out" \
  --config GDAL_CACHEMAX 16384 --config GDAL_SWATH_SIZE 4000000000 \
  -of COG \
  -co COMPRESS=ZSTD -co PREDICTOR=YES -co SPARSE_OK=YES \
  -co BLOCKSIZE=512 -co OVERVIEWS=IGNORE_EXISTING -co RESAMPLING=AVERAGE \
  -co BIGTIFF=IF_SAFER -co NUM_THREADS="$SLURM_CPUS_PER_TASK" \
  -a_srs "EPSG:$epsg"

$RUN gdalinfo "$out" | grep -E "Size is|Block=|NoData|Type=|Overviews" || true
[ -n "$work" ] && rm -rf "$work"
echo "$name: done in ${SECONDS}s -> $out ($(stat -c%s "$out") bytes)"
