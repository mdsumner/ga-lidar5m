# GA LiDAR 5m DEM (eCat 89644) -- COG-ification on Setonix (pawsey1362)

Recipes and job scripts for turning the GA national 5m LiDAR DEM zip
distribution into per-zone COGs, toward hosted streaming access and sds
registry rows. Data and run artefacts live on scratch, never here.

See docs/slurm-array-accounting.md for reading sacct on the array jobs.

Working root: `$MYSCRATCH/ga-lidar-5m` (zips/ cog/ work/ manifests/ probe/).
All stages read the same `zones.tsv` (12 rows: AUSGeoid set idx 0-8,
quasigeoid MDB set idx 9-11; the two vertical datums are never mixed).

## Now: stage 0 (login node, <100MB transfer)

    mkdir -p $MYSCRATCH/ga-lidar-5m && cd $MYSCRATCH/ga-lidar-5m
    bash 00_probe.sh zones.tsv | tee probe-report.txt

What it does: reads every zip's central directory remotely via HTTP
ranges (a few KB per file, zip64-aware) so we see every inner file,
size, and compression method for all 12 zips without downloading them;
then fully fetches the two island zips (2.5MB + 17MB) and runs gdalinfo
to confirm the inner dataset (expected: ArcInfo Binary Grid, hdr.adf).
Bring probe-report.txt back before anything bigger moves.

## Ready when you are: stage 1a (downloads, copy partition)

    sbatch --chdir=$MYSCRATCH/ga-lidar-5m 01_download.sbatch $PWD/zones.tsv

Array 0-11 on the data-mover partition, ~30GB total, size-verified
against Content-Length, resumable, appends manifests/downloaded.tsv.
Safe to re-run; complete files are skipped.

## Probe results (2026-10-01)

Each zip holds one internally-uncompressed striped Float32 tif (plus an
occasional metadata docx). True uncompressed sizes: waz50 148.8GB,
waz51 36.7GB (588:1 -- nearly all nodata), z54ag 270.2GB, z55ag 354.2GB,
z56ag 115.3GB, mdba qg 25.0/86.4/3.4GB, ntz 0.96/2.55GB, islands tiny.
~1.04TB total. Embedded CRS metadata is inconsistent (ESRI-mangled in
some), so the manifest -a_srs stamp is load-bearing. NoData value still
to be confirmed from the first small COG.

## Loaded, not fired: stage 1b (COGs, work partition)

    sbatch --chdir=$MYSCRATCH/ga-lidar-5m 02_cogify.sbatch $PWD/zones.tsv

One zone per task: gdal_translate to COG (ZSTD, PREDICTOR=YES,
SPARSE_OK, 512 blocks, AVERAGE overviews), native zone CRS stamped from
the manifest, reading STRAIGHT FROM /vsizip/ by default -- a single
sequential streaming inflate, so no 354GB extraction on scratch
(EXTRACT=1 falls back to unzip-then-translate). GDAL via your sif
convention (singularity/4.1.0-slurm, gdal-r-python-extras, LD_LIBRARY_PATH
cleared); SIF= overrides. 12h walltime sized for the 270-354GB
inflate-throughs; the small zones finish in minutes.

## Later (not in this kit)

Warped per-zone VRTs into EPSG:3577 + parent mosaic (ag and qg kept
separate), rema-ovr-style repo, COGs to source.coop, sds registry rows.
The earlier ga-lidar5m-pipeline.sh has the composite recipe.

## Knobs

- BASEDIR: override the working root (default $MYSCRATCH/ga-lidar-5m)
- GDAL_IMAGE: container for stage 1b (default osgeo/gdal ubuntu-full)
- GDAL_BIN in 00_probe: point at a container gdalinfo if the login node
  has no GDAL
