# Reading sacct for array jobs

The download and cogify jobs here are Slurm arrays (`--array=0-11`), and
`sacct` output for them multiplies twice: once by array task, once by
step within each task. Knowing the shape saves squinting.

## Multiplication one: array tasks

`--array=0-11` is twelve jobs sharing a parent JobID. Each task shows as
`JOBID_N`, and in this repo N is exactly the `zones.tsv` row index, so
`JOBID_7` is `nationalz55_ag` and its log is `ga5m-dl-7.out` (the
`%x-%a` output pattern). Pending tasks are not materialized
individually: they appear as one compact row like `JOBID_[8-11]` that
unfolds into real rows as tasks start, which is why the listing grows
as the job runs.

## Multiplication two: steps

Every running task carries sub-rows:

- `JOBID_N` -- the allocation: overall state, elapsed, requested
  resources
- `JOBID_N.batch` -- the script itself; real resource accounting
  (MaxRSS etc) attaches here
- `JOBID_N.extern` -- bookkeeping Slurm adds on systems with
  PrologFlags=contain (Setonix included), accounting for anything
  outside the batch step. Near-zero resources, always present, ignore.

Scripts that call `srun` add numbered `.0`, `.1` steps; ours do not.
So: three rows per task, twelve tasks, 36 rows per sbatch.

## The antidote

`-X` (`--allocations`) suppresses step rows, one line per zone:

    sacct -j JOBID -X --format=JobID,JobName%10,State,Elapsed,ExitCode

Narrow to one zone with `sacct -j JOBID_7`. Resource questions go to
`.batch` (`--format=...,MaxRSS` -- interesting on the cogify job, where
the GDAL block cache has a 16GB allowance); done-or-failed questions go
to the parent row.

## ExitCode semantics in this repo

- download: `0:0` means size-verified complete; `FAILED 1:0` is the
  script's own Content-Length mismatch guard, distinct from curl
  failures (which surface only after five retries)
- cogify: `1:0` covers the missing-zip and no-tif guards; the log names
  which

One quirk: parent-row Elapsed includes queue-to-start overhead within
the allocation, so `.batch` Elapsed is the truer work time (noise at
this scale, but worth knowing).
