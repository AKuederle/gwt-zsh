# gwt-gwc.zsh
# Git worktree helpers:
#   gwt <name> [from] [--root <path>]  -> creates worktree at <root>/<name>
#                                       and creates new branch <name> from <from>/HEAD
#   gwc <name> [--root <path>]         -> cd into <root>/<name>
#   gwc --cleanup [-a|--all]           -> interactive cleanup of merged worktrees
#                                         -a/--all: delete all merged+clean without prompt
#
# Default root: ../<projname>-trees where projname is the repo folder name.


# If these names are already aliases, remove them so functions can be defined.
unalias gwt 2>/dev/null
unalias gwc 2>/dev/null

__gwt_default_root() {
  local gitdir mainroot repo
  gitdir=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
  # git-common-dir points to main repo's .git; parent is the main repo root
  mainroot="${gitdir:A:h}"
  repo="${mainroot:t}"
  print -r -- "${mainroot:h}/${repo}-trees"
}

# Copy gitignored config files from source repo to new worktree
# Usage: __gwt_copy_configs <source_repo> <dest_worktree>
__gwt_copy_configs() {
  local src="$1" dest="$2"
  local -a copied=()

  # Files to copy (glob patterns relative to repo root)
  local -a config_files=(
    # Environment & Secrets
    '.env'
    '.env.local'
    '.env.development.local'
    '.env.production.local'
    '.env.test.local'
    'local.settings.json'
    '.secrets'
    'secrets'
    # Editor/IDE Settings
    '.vscode'
    '.idea'
    # AI/Assistant Config
    '.claude'
    '.cursor'
    '.copilot'
  )

  local item srcpath
  for item in "${config_files[@]}"; do
    srcpath="$src/$item"
    if [[ -e "$srcpath" ]]; then
      cp -R -- "$srcpath" "$dest/"
      copied+=("$item")
    fi
  done

  if (( ${#copied[@]} )); then
    print -u2 "gwt: copied configs: ${(j:, :)copied}"
  fi
}

# Globals used to return values from __gwt_parse_root
typeset -g _GWT_ROOT
typeset -ga _GWT_REST

# Parse --root <path> or --root=<path>.
# Sets _GWT_ROOT and _GWT_REST globals. Returns 1 if no root can be determined.
__gwt_parse_root() {
  local -a rest
  local root=""
  rest=()

  while (( $# )); do
    case "$1" in
      --root)
        shift
        root="${1:-}"
        shift
        ;;
      --root=*)
        root="${1#--root=}"
        shift
        ;;
      *)
        rest+=("$1")
        shift
        ;;
    esac
  done

  if [[ -z "$root" ]]; then
    root="$(__gwt_default_root)" || return 1
  fi

  _GWT_ROOT="$root"
  _GWT_REST=("${rest[@]}")
}

# Complete <from> with local branches + tags (good enough for most use)
__gwt_complete_from() {
  local -a refs
  refs=("${(@f)$(git for-each-ref --format='%(refname:short)' refs/heads refs/tags 2>/dev/null)}")
  _describe -t refs "git ref" refs
}

# Get the default branch (main/master)
__gwt_default_branch() {
  local ref branch
  # Priority order: main > master > develop > origin/HEAD > first branch
  # Check common default branch names first (most reliable)
  for branch in main master develop; do
    if git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
      print -r -- "$branch"
      return
    fi
  done
  # Try local origin HEAD symref (may be stale)
  ref=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)
  if [[ -n "$ref" ]]; then
    print -r -- "${ref##refs/remotes/origin/}"
    return
  fi
  # Fallback: check local branches
  for branch in main master develop; do
    if git show-ref --verify --quiet "refs/heads/$branch"; then
      print -r -- "$branch"
      return
    fi
  done
  # Last resort: use the first branch found
  branch=$(git for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null | head -1)
  if [[ -n "$branch" ]]; then
    print -r -- "$branch"
    return
  fi
  return 1
}

# Check if branch is merged into default branch
# Usage: __gwt_is_merged <branch> <default_branch>
__gwt_is_merged() {
  git merge-base --is-ancestor "$1" "$2" 2>/dev/null
}

# Check if worktree has uncommitted changes
# Usage: __gwt_is_dirty <worktree_path>
__gwt_is_dirty() {
  local output
  output=$(git -C "$1" status --porcelain 2>/dev/null)
  [[ -n "$output" ]]
}

# Get relative time since last commit in worktree
# Usage: __gwt_last_commit_age <worktree_path>
__gwt_last_commit_age() {
  git -C "$1" log -1 --format='%cr' 2>/dev/null || print "unknown"
}

# Cleanup worktrees interactively or automatically
# Usage: __gwt_cleanup [--all]
__gwt_cleanup() {
  local delete_all=0
  [[ "$1" == "--all" || "$1" == "-a" ]] && delete_all=1

  local root default_branch mainrepo current_dir
  root="$(__gwt_default_root)" || {
    print -u2 "gwc: not inside a git repo"
    return 1
  }

  if ! command -v gum >/dev/null 2>&1 && (( ! delete_all )); then
    print -u2 "gwc: gum is required for interactive cleanup"
    print -u2 "     install gum (pacman -S gum) or use --all for non-interactive mode"
    return 1
  fi

  default_branch=$(__gwt_default_branch) || {
    print -u2 "gwc: could not determine default branch"
    return 1
  }

  mainrepo="$(git rev-parse --git-common-dir 2>/dev/null)"
  mainrepo="${mainrepo:A:h}"
  current_dir="$PWD"

  [[ -d "$root" ]] || {
    print -u2 "gwc: no worktrees directory found at $root"
    return 0
  }

  # Clean up stale worktree entries first
  git worktree prune 2>/dev/null

  # Get worktrees from git (more reliable than ls)
  # Format: /path/to/worktree  commit  [branch]
  local -a worktree_lines
  worktree_lines=("${(@f)$(git worktree list 2>/dev/null)}")
  (( ${#worktree_lines[@]} )) || {
    print -u2 "gwc: no worktrees found"
    return 0
  }

  # Build list of worktrees with status
  # Sort order: merged (safe) → unmerged → dirty (dangerous, at end)
  local -a merged_items unmerged_items dirty_items all_items
  local -a merged_clean_paths
  # Note: avoid 'path' as variable name - it's special in zsh (tied to PATH)
  local name wt_path branch is_merged is_dirty age item wt_line

  for wt_line in "${worktree_lines[@]}"; do
    # Parse: /path/to/worktree  hexsha  [branchname] or (detached HEAD)
    # Use awk for reliable parsing with variable whitespace
    wt_path=$(print -r -- "$wt_line" | awk '{print $1}')

    # Skip if not in our trees directory
    [[ "$wt_path" == "$root"/* ]] || continue

    name="${wt_path:t}"

    # Extract branch from [branchname] at end of line
    if [[ "$wt_line" == *"["*"]"* ]]; then
      branch="${wt_line##*\[}"
      branch="${branch%%\]*}"
    else
      # Detached HEAD or other state
      branch=""
    fi

    [[ -n "$branch" ]] || continue
    age=$(__gwt_last_commit_age "$wt_path")

    is_merged=0
    is_dirty=0
    __gwt_is_merged "$branch" "$default_branch" && is_merged=1
    __gwt_is_dirty "$wt_path" && is_dirty=1

    if (( is_dirty )); then
      item="⚠ DIRTY     ${name}  (${age})"
      dirty_items+=("$item")
    elif (( is_merged )); then
      item="✓ merged    ${name}  (${age})"
      merged_items+=("$item")
      merged_clean_paths+=("$wt_path")
    else
      item="• unmerged  ${name}  (${age})"
      unmerged_items+=("$item")
    fi
  done

  all_items=("${merged_items[@]}" "${unmerged_items[@]}" "${dirty_items[@]}")

  (( ${#all_items[@]} )) || {
    print -u2 "gwc: no worktrees found"
    return 0
  }

  if (( delete_all )); then
    # Non-interactive: delete all merged+clean
    if (( ! ${#merged_clean_paths[@]} )); then
      print -u2 "gwc: no merged+clean worktrees to delete"
      return 0
    fi
    print -u2 "gwc: deleting ${#merged_clean_paths[@]} merged worktree(s)..."
    local p need_cd=0
    for p in "${merged_clean_paths[@]}"; do
      [[ "$current_dir" == "$p"* ]] && need_cd=1
      print -u2 "  removing: ${p:t}"
      git worktree remove --force "$p" 2>&1 | sed 's/^/    /'
    done
    if (( need_cd )); then
      print -u2 "gwc: current directory was deleted, changing to main repo"
      cd -- "$mainrepo"
    fi
    return 0
  fi

  # Interactive: use gum choose with --selected for merged items
  # Build gum command with --selected flags for each merged item
  local -a gum_args
  gum_args=(choose --no-limit --height 20 --header "Select worktrees to DELETE (space=toggle, enter=confirm)")

  # Add --selected for each merged item (pre-select them)
  for item in "${merged_items[@]}"; do
    gum_args+=(--selected "$item")
  done

  # Run gum with all items
  local selected
  selected=$(gum "${gum_args[@]}" -- "${all_items[@]}")

  [[ -z "$selected" ]] && {
    print -u2 "gwc: cancelled"
    return 0
  }

  # Parse selected entries and delete
  local need_cd=0
  local line wt_name
  while IFS= read -r line; do
    # Extract worktree name from format: "✓ merged    name  (age)"
    # The name is between the status text and the (age)
    wt_name=$(print -r -- "$line" | sed -E 's/^[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+([^[:space:]]+)[[:space:]]+\(.*/\1/')
    wt_path="$root/$wt_name"

    [[ -d "$wt_path" ]] || continue

    [[ "$current_dir" == "$wt_path"* ]] && need_cd=1

    print -u2 "gwc: removing $wt_name"
    git worktree remove --force "$wt_path" 2>&1 | sed 's/^/  /'
  done <<< "$selected"

  if (( need_cd )); then
    print -u2 "gwc: current directory was deleted, changing to main repo"
    cd -- "$mainrepo"
  fi
}

# gwt <name> [from] [--root <path>]
gwt() {
  local name from dest branch_exists=0

  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    print -u2 "gwt: not inside a git repo"
    return 1
  }

  __gwt_parse_root "$@" || return 1

  name="${_GWT_REST[1]}"
  from="${_GWT_REST[2]:-HEAD}"

  if [[ -z "$name" ]]; then
    print -u2 "usage: gwt <name> [from] [--root <path>]"
    return 2
  fi

  if git show-ref --verify --quiet "refs/heads/$name"; then
    branch_exists=1
  fi

  mkdir -p -- "$_GWT_ROOT" || return 1
  dest="${_GWT_ROOT}/${name}"

  # Worktree already exists: just cd to it
  if [[ -d "$dest" ]] && git -C "$dest" rev-parse --git-dir >/dev/null 2>&1; then
    print -u2 "gwt: worktree already exists, changing to: $dest"
    cd -- "$dest"
    return
  fi

  if [[ -e "$dest" ]]; then
    print -u2 "gwt: destination exists but is not a worktree: $dest"
    return 1
  fi

  # Get main repo path for copying configs
  local mainrepo
  mainrepo="$(git rev-parse --git-common-dir 2>/dev/null)"
  mainrepo="${mainrepo:A:h}"

  if (( branch_exists )); then
    print -u2 "gwt: branch '$name' exists, creating worktree for it"
    print -u2 "gwt: git worktree add $dest $name"
    git worktree add -- "$dest" "$name" && {
      __gwt_copy_configs "$mainrepo" "$dest"
      cd -- "$dest"
    }
  else
    print -u2 "gwt: git worktree add -b $name $dest $from"
    git worktree add -b "$name" -- "$dest" "$from" && {
      __gwt_copy_configs "$mainrepo" "$dest"
      cd -- "$dest"
    }
  fi
}

# gwc [name] [--root <path>]
# gwc --cleanup [-a|--all]
# gwc -c [-a|--all]
gwc() {
  local name dest gitdir
  local cleanup=0 cleanup_all=""

  # Check for cleanup mode first
  local -a args
  args=("$@")
  local i=1
  while (( i <= ${#args[@]} )); do
    case "${args[$i]}" in
      --cleanup|-c)
        cleanup=1
        ;;
      --all|-a)
        cleanup_all="--all"
        ;;
    esac
    (( i++ ))
  done

  if (( cleanup )); then
    __gwt_cleanup $cleanup_all
    return $?
  fi

  __gwt_parse_root "$@" || return 1
  name="${_GWT_REST[1]}"

  # No name given: cd to main repo folder
  if [[ -z "$name" ]]; then
    gitdir="$(git rev-parse --git-common-dir 2>/dev/null)" || {
      print -u2 "gwc: not inside a git repo"
      return 1
    }
    # git-common-dir returns path to .git dir; parent is the main repo
    dest="${gitdir:A:h}"
    cd -- "$dest"
    return
  fi

  dest="${_GWT_ROOT}/${name}"
  [[ -d "$dest" ]] || {
    print -u2 "gwc: not a directory: $dest"
    return 1
  }

  cd -- "$dest"
}

# --- completions ---

_gwt() {
  local -a opts
  opts=(
    '--root=[worktree root directory]:directory:_files -/'
  )

  _arguments -s -S \
    $opts \
    '1:name: ' \
    '2:from:__gwt_complete_from' \
    '*:: :->rest'

  return 0
}
compdef _gwt gwt

__gwc_complete_name() {
  local root
  root="$(__gwt_default_root 2>/dev/null)" || return 0

  local -a entries only
  entries=()
  only=()

  if [[ -d "$root" ]]; then
    entries=("${(@f)$(command ls -1 "$root" 2>/dev/null)}")
    local e
    for e in "${entries[@]}"; do
      [[ -d "$root/$e" ]] && only+=("$e")
    done
    _describe -t worktrees "worktree" only
  fi
}

_gwc() {
  local -a opts
  opts=(
    '--root=[worktree root directory]:directory:_files -/'
    '(-c --cleanup)'{-c,--cleanup}'[interactive cleanup of merged worktrees]'
    '(-a --all)'{-a,--all}'[delete all merged+clean worktrees without prompt]'
  )

  _arguments -s -S \
    $opts \
    '1:worktree:__gwc_complete_name' \
    '*:: :->rest'

  return 0
}
compdef _gwc gwc
