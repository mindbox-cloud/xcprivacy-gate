#!/usr/bin/env bash
set -euo pipefail

main() {
  : "${BRANCH:?}" "${BASE_BRANCH:?}" "${REVIEWER:?}" "${BODY:?}"
  local rules_directory
  rules_directory=$(cd "$(dirname "${BASH_SOURCE[0]}")/../Rules" && pwd)
  local open_prs
  open_prs=$(gh pr list --head "$BRANCH" --state open --json number --jq length)
  if [ "$open_prs" != "0" ]; then
    git fetch --quiet origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH"
    git switch --quiet -C "$BRANCH" "origin/$BRANCH"
  else
    git switch --quiet -C "$BRANCH"
  fi
  "$@"
  git add -- "$rules_directory/rules.json" "$rules_directory/apple"
  if git diff --cached --quiet; then
    echo "Apple's pages match the rules on $BRANCH"
    return 0
  fi
  git -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit --quiet -m "MOBILE-0000: Refresh Apple privacy rules"
  if [ "$open_prs" != "0" ]; then
    git push --quiet origin "$BRANCH"
    gh pr comment "$BRANCH" --body-file "$BODY"
  else
    git push --quiet --force origin "$BRANCH"
    gh pr create --base "$BASE_BRANCH" --head "$BRANCH" --title "MOBILE-0000: Refresh Apple privacy rules" \
      --body-file "$BODY" --reviewer "$REVIEWER"
  fi
}

main "$@"
