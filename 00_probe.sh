#!/usr/bin/env bash
# Stage 0: probe. Login-node safe -- total transfer is well under 100MB.
#
# Two things, no big downloads:
#   (a) remote central-directory read of ALL 12 zips via HTTP ranges
#       (a few KB from the tail of each), so we know every inner file,
#       its size, and its compression method before any real pull;
#   (b) full fetch + gdalinfo of the two island zips (2.5MB + 17MB) to
#       confirm GDAL opens the inner dataset and what it really is
#       (expected: ArcInfo Binary Grid directory with hdr.adf).
#
# Usage on Setonix:
#   cd $MYSCRATCH && mkdir -p ga-lidar-5m && cd ga-lidar-5m
#   bash /path/to/00_probe.sh /path/to/zones.tsv | tee probe-report.txt

set -euo pipefail
MANIFEST="${1:?usage: 00_probe.sh zones.tsv}"
BASEDIR="${BASEDIR:-$MYSCRATCH/ga-lidar-5m}"
mkdir -p "$BASEDIR/zips" "$BASEDIR/probe"

echo "== (a) remote zip directories (ranged reads) =="
python3 - "$MANIFEST" <<'PY'
import sys, urllib.request, struct, zipfile, io

def tail(url, n):
    req = urllib.request.Request(url, headers={"Range": f"bytes=-{n}"})
    with urllib.request.urlopen(req) as r:
        clen = r.headers.get("Content-Range", "")
        total = int(clen.split("/")[-1]) if "/" in clen else None
        return r.read(), total

def ranged(url, start, length):
    req = urllib.request.Request(url, headers={"Range": f"bytes={start}-{start+length-1}"})
    with urllib.request.urlopen(req) as r:
        return r.read()

for line in open(sys.argv[1]):
    if line.startswith("#") or not line.strip():
        continue
    idx, name, epsg, tag, size_hint, url = line.split("\t")
    url = url.strip()
    try:
        # EOCD lives in the last 22..(22+64K) bytes
        data, total = tail(url, 66000)
        eocd = data.rfind(b"PK\x05\x06")
        if eocd < 0:
            print(f"{name}: no EOCD in tail (zip64-only or odd layout), total={total}")
            continue
        n_entries, cd_size, cd_offset = struct.unpack("<HII", data[eocd+10:eocd+20])
        zip64 = cd_offset == 0xFFFFFFFF or n_entries == 0xFFFF
        if zip64:
            # zip64 EOCD locator sits just before EOCD
            loc = data.rfind(b"PK\x06\x07", 0, eocd)
            if loc >= 0:
                z64_off = struct.unpack("<Q", data[loc+8:loc+16])[0]
                z64 = ranged(url, z64_off, 56)
                n_entries, = struct.unpack("<Q", z64[32:40])
                cd_size, cd_offset = struct.unpack("<QQ", z64[40:56])
        cd = ranged(url, cd_offset, cd_size)
        # parse central directory records
        print(f"{name}: total={total:,} bytes, entries={n_entries}")
        off = 0
        methods = {0: "STORED", 8: "DEFLATE"}
        while off + 46 <= len(cd) and cd[off:off+4] == b"PK\x01\x02":
            method, = struct.unpack("<H", cd[off+10:off+12])
            csize, usize = struct.unpack("<II", cd[off+20:off+28])
            nlen, elen, clen = struct.unpack("<HHH", cd[off+28:off+34])
            fname = cd[off+46:off+46+nlen].decode("utf8", "replace")
            # zip64: 0xFFFFFFFF fields defer to the id-0x0001 extra block,
            # 8-byte values in fixed order (usize, csize, offset, disk)
            extra = cd[off+46+nlen:off+46+nlen+elen]
            eo = 0
            while eo + 4 <= len(extra):
                hid, hlen = struct.unpack("<HH", extra[eo:eo+4])
                if hid == 0x0001:
                    z = extra[eo+4:eo+4+hlen]; zo = 0
                    if usize == 0xFFFFFFFF:
                        usize, = struct.unpack("<Q", z[zo:zo+8]); zo += 8
                    if csize == 0xFFFFFFFF:
                        csize, = struct.unpack("<Q", z[zo:zo+8]); zo += 8
                    break
                eo += 4 + hlen
            print(f"    {fname}  {usize:>15,}  ({methods.get(method, method)}, {csize:,} stored)")
            off += 46 + nlen + elen + clen
    except Exception as ex:
        print(f"{name}: PROBE FAILED: {ex}")
PY

echo
echo "== (b) open the two small zips with GDAL =="
GDAL_BIN="${GDAL_BIN:-gdalinfo}"   # or: singularity exec $SIF gdalinfo
while IFS=$'\t' read -r idx name epsg tag size_hint url; do
  [ "${idx:0:1}" = "#" ] && continue
  case "$name" in cocosislandz47|christmasislandz48) ;; *) continue ;; esac
  zip="$BASEDIR/probe/$name.zip"
  [ -s "$zip" ] || curl -fsSL --retry 3 -o "$zip" "$url"
  echo "-- $name --"
  # let GDAL find the dataset inside; if it needs the inner path, take it
  # from the (a) listing above: /vsizip/$zip/<inner-grid-dir>
  $GDAL_BIN "/vsizip/$zip" 2>&1 | sed -n '1,25p' || true
done < "$MANIFEST"

echo
echo "probe complete; report the (a) listing back before launching 01_download."
