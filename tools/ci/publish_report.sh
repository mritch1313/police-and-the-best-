#!/usr/bin/env bash
# Publishes a CI report file back into the repository so it can be read from any
# environment, including environments where GitHub's raw job logs are unreachable.
#
# usage: tools/ci/publish_report.sh <report-name> <file-with-content>
#
# The commit message carries "[skip ci]" so that publishing a report never triggers
# another workflow run, and the push is retried after a rebase because several jobs may
# publish at the same time.
set -uo pipefail

name="${1:?report name required}"
src="${2:?content file required}"
branch="${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD)}"
run_id="${GITHUB_RUN_ID:-local}"
dest="ci-reports/${name}-latest.txt"

mkdir -p ci-reports
{
  echo "run_id: ${run_id}"
  echo "commit: $(git rev-parse HEAD)"
  echo "ref: ${branch}"
  echo "generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "----------------------------------------------------------------------"
  cat "${src}"
} > "${dest}"

git config user.name "arena-ci-bot"
git config user.email "ci-bot@users.noreply.github.com"
git add -f "${dest}"
if git diff --cached --quiet; then
  echo "publish_report: nothing changed for ${name}"
  exit 0
fi
git commit -q -m "ci(report): ${name} run ${run_id} [skip ci]" || true

for attempt in 1 2 3; do
  if git push -q origin "HEAD:${branch}"; then
    echo "publish_report: pushed ${dest} (attempt ${attempt})"
    exit 0
  fi
  echo "publish_report: push failed, retrying after rebase (attempt ${attempt})"
  git fetch -q origin "${branch}" || true
  git rebase -q "origin/${branch}" || git rebase --abort || true
  sleep 3
done

echo "publish_report: could not push ${dest} (not fatal, the log also went to the step summary)"
exit 0
