# gwt-zsh

Zsh functions for streamlined git worktree management.

## Why worktrees?

Git worktrees let you check out multiple branches simultaneously in separate directories. This is useful when you need to:

- Work on a feature while keeping another branch ready for quick fixes
- Compare implementations across branches side-by-side
- Run tests on one branch while developing on another
- Avoid constant stashing and branch switching

## Installation

```zsh
# Clone to your zsh config directory
git clone https://github.com/AKuederle/gwt-zsh.git ~/.zsh/gwt-zsh

# Source in your .zshrc
echo 'source ~/.zsh/gwt-zsh/gwt.zsh' >> ~/.zshrc
```

## Commands

### `gwt <name> [from] [--root <path>]`

Create a new worktree and branch, then cd into it.

```zsh
# Create worktree with new branch 'feature-x' from HEAD
gwt feature-x

# Create worktree with new branch from specific ref
gwt feature-x main
gwt bugfix-y v1.2.0

# Use existing branch (if 'feature-x' already exists)
gwt feature-x

# Custom worktree location
gwt feature-x --root ~/projects/myrepo-worktrees
```

### `gwc [name] [--root <path>]`

Change directory to an existing worktree.

```zsh
# cd to worktree 'feature-x'
gwc feature-x

# cd back to main repository
gwc
```

## Directory structure

By default, worktrees are created in a sibling directory named `<repo>-trees`:

```
~/projects/
  myrepo/           # Main repository
  myrepo-trees/     # Worktree container (auto-created)
    feature-x/      # Worktree for feature-x branch
    bugfix-y/       # Worktree for bugfix-y branch
```

This keeps worktrees organized and separate from the main repo.

## Config file copying

When creating a new worktree, `gwt` automatically copies common gitignored config files from the main repository:

**Environment & Secrets**
- `.env`, `.env.local`, `.env.*.local`
- `local.settings.json`
- `.secrets/`, `secrets/`

**Editor/IDE Settings**
- `.vscode/`
- `.idea/`

**AI Assistant Config**
- `.claude/`
- `.cursor/`
- `.copilot/`

Copied files are reported:
```
gwt: copied configs: .env, .vscode, .claude
```

## Tab completion

Both commands support zsh tab completion:

- `gwt <tab>` - complete branch name
- `gwt name <tab>` - complete ref (branches, tags)
- `gwc <tab>` - complete existing worktree names

## Worktree workflow

```zsh
# Start in main repo
cd ~/projects/myrepo

# Create worktree for new feature
gwt new-feature
# Now in ~/projects/myrepo-trees/new-feature

# Work on feature...
# ...

# Switch to another worktree
gwc other-feature

# Return to main repo
gwc

# Clean up when done (standard git command)
git worktree remove ../myrepo-trees/new-feature
```

## License

MIT
