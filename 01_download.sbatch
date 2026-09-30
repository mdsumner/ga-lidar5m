#!/bin/bash -l
#SBATCH --job-name=ga5m-dl
#SBATCH --account=pawsey1362
#SBATCH --partition=copy
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=4G
#SBATCH --time=06:00:00
#SBATCH --array=0-11
#SBATCH --output=%x-%a.out
#
# Stage 1a: pull the 12 zone zips onto scratch. One array task per zip,
# on the data-mover (copy) partition where transfers belong. ~30GB total;
# the biggest single file is 10.8GB (nationalz55_ag).
#
#   sbatch --chdir=$MYSCRATCH/ga-lidar-5m 01_download.sbatch /path/to/zones.tsv
#
# Re-running is safe: existing files are size-checked against the server
# and only refetched on mismatch (curl -C - resumes partials).

set -euo pipefail
MANIFEST="${1:?pass zones.tsv path as the sbatch argument}"
BASEDIR="${BASEDIR:-$MYSCRATCH/ga-lidar-5m}"
mkdir -p "$BASEDIR/zips" "$BASEDIR/manifests"

line=$(grep -v '^#' "$MANIFEST" | sed -n "$((SLURM_ARRAY_TASK_ID + 1))p")
IFS=$'\t' read -r idx name epsg tag size_hint url <<< "$line"
zip="$BASEDIR/zips/$name.zip"

remote=$(curl -fsSIL "$url" | awk 'tolower($1)=="content-length:"{print $2}' | tr -d '\r' | tail -1)
local_size=0; [ -f "$zip" ] && local_size=$(stat -c%s "$zip")

if [ -n "$remote" ] && [ "$local_size" = "$remote" ]; then
  echo "$name: already complete ($local_size bytes)"
else
  echo "$name: fetching ($size_hint, remote=$remote, have=$local_size)"
  curl -fL --retry 5 --retry-all-errors -C - -o "$zip" "$url"
fi

final=$(stat -c%s "$zip")
[ -z "$remote" ] || [ "$final" = "$remote" ] || { echo "SIZE MISMATCH $name: $final != $remote"; exit 1; }
printf '%s\t%s\t%s\t%s\n' "$name" "$final" "$(date -u +%FT%TZ)" "$url" \
  >> "$BASEDIR/manifests/downloaded.tsv"
echo "$name: ok"
