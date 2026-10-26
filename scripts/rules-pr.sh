#!/usr/bin/env bash
set -euo pipefail

main() {
  : "${BRANCH:?}" "${BASE_BRANCH:?}" "${BODY:?}"
  local gate=${1:?usage: rules-pr.sh <path of the built xcprivacy-gate>}
  local pull_request
  pull_request=$(gh pr list --head "$BRANCH" --state open --json number,isCrossRepository \
    --jq 'map(select(.isCrossRepository | not)) | .[0].number // empty')
  if [ -n "$pull_request" ]; then
    git fetch --quiet origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"
    git switch --quiet -C "$BRANCH" "origin/$BRANCH"
  else
    git switch --quiet -C "$BRANCH"
  fi
  "$gate" refresh --rules-directory Rules --out-pr-body "$BODY"
  git add -- Rules/rules.json Rules/apple
  if git diff --cached --quiet; then
    echo "Apple's pages match the rules on $BRANCH"
    return 0
  fi
  git -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit --quiet -m "feat: refresh Apple privacy rules"
  if [ -n "$pull_request" ]; then
    git push --quiet origin "$BRANCH"
    gh pr comment "$pull_request" --body-file "$BODY"
  else
    git push --quiet --force origin "$BRANCH"
    gh pr create --base "$BASE_BRANCH" --head "$BRANCH" --title "feat: refresh Apple privacy rules" --body-file "$BODY"
  fi
}

main "$@"
