# skills

Claude Code skills monorepo by [@mikeshoes](https://github.com/mikeshoes).

## Skills

| Skill | Description |
|---|---|
| [`agent-orchestrator/`](agent-orchestrator/) | Multi-role (PM/BE/FE/QA) tmux orchestration with a file-based comms protocol |
| [`project-anchor/`](project-anchor/) | Anti-drift mechanism: north-star anchor, periodic drift audit, formal pivot ceremony |

## Install one skill

Symlink (recommended — keeps the skill auto-updated when you `git pull`):

```bash
git clone git@github.com:mikeshoes/skills.git ~/code/skills
ln -s ~/code/skills/agent-orchestrator ~/.claude/skills/agent-orchestrator
```

Or copy:

```bash
git clone git@github.com:mikeshoes/skills.git /tmp/skills
cp -r /tmp/skills/agent-orchestrator ~/.claude/skills/
```

## License

Each skill carries its own LICENSE file (currently MIT for all).
