# gwt-gwc.zsh
# Git worktree helpers:
#   gwt <name> [from] [--root <path>]  -> creates worktree at <root>/<name>
#                                       and creates new branch <name> from <from>/HEAD
#   gwc <name> [--root <path>]         -> cd into <root>/<name>
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
gwc() {
  local name dest gitdir

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
  )

  _arguments -s -S \
    $opts \
    '1:worktree:__gwc_complete_name' \
    '*:: :->rest'

  return 0
}
compdef _gwc gwc
