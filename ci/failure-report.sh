#!/bin/bash
# ci/failure-report.sh LOG -- the part of a failed build that someone fixing it
# needs, as plain text: which run, which packages, each failed package's own
# makepkg output, and the end of the whole log.
#
# The build workflow uploads it to the ci-failures release as failure-<arch>.log.
# Release assets of a public repo download without a token, which job logs do
# not, so omarchy-artix-autofix on the autopin box reads it from there and
# matches the "run:" line against the run it is looking at.
#
# Unlike a job log, a release asset is not masked by GitHub, so anything that
# looks like a credential is blanked on the way out.
set -u
log=${1:-build.log}
scrub() {
  sed -E -e 's#(x-access-token:)[^@[:space:]]+@#\1***@#g' \
         -e 's#(gh[pousr]_|github_pat_)[A-Za-z0-9_]+#\1***#g' \
         -e '/BEGIN PGP PRIVATE KEY/,/END PGP PRIVATE KEY/d'
}
exec > >(scrub)
echo "run: ${GITHUB_RUN_ID:-?} attempt ${GITHUB_RUN_ATTEMPT:-?} sha ${GITHUB_SHA:-?} arch ${ARCH:-?}"
echo "url: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-?}/actions/runs/${GITHUB_RUN_ID:-?}"
failed=$(tr "\n" " " 2>/dev/null <out/failed || true)
echo "failed: ${failed:-(no package failed; a step outside the package builds did)}"
for name in $failed; do
  echo
  echo "==== $name: its build output (last 200 lines)"
  awk -v n="$name" 'index($0, "::group::" n " ") == 1 { on = 1 } on { print } on && /^::endgroup::/ { exit }' "$log" | tail -200
done
echo
echo "==== end of the whole log (last 150 lines)"
tail -150 "$log" 2>/dev/null
