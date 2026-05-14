#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <branch> [base]" >&2
  exit 1
fi

BRANCH="$1"
BASE="${2:-main}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_NAME="$(basename "$REPO_DIR")"
PARENT_DIR="$(dirname "$REPO_DIR")"
WORKTREE_DIR="$PARENT_DIR/${REPO_NAME}-wt-${BRANCH//\//-}"

if [[ -e "$WORKTREE_DIR" ]]; then
  echo "Worktree path already exists: $WORKTREE_DIR" >&2
  exit 1
fi

cd "$REPO_DIR"
git fetch origin "$BASE"
git worktree add "$WORKTREE_DIR" -b "$BRANCH" "origin/$BASE"
echo "$WORKTREE_DIR"
