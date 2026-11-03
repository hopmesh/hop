# Cross-Harness Installation

This package uses the portable Agent Skills layout and only common frontmatter fields.

## Canonical user installation

Install the real directory at:

```text
~/.agents/skills/hop-adversarial-audit/
```

Current OpenCode and Codex releases discover that path directly.

Expose the same directory to Claude Code with a directory symlink:

```text
~/.claude/skills/hop-adversarial-audit
  -> ../../.agents/skills/hop-adversarial-audit
```

Link the whole skill directory, not only `SKILL.md`. Some harnesses deliberately ignore file-level skill symlinks.

## Repository installation

The canonical checked-in package lives at:

```text
.agents/skills/hop-adversarial-audit/
```

OpenCode and Codex can discover it there. This repository includes `.claude/skills/hop-adversarial-audit` as a directory link to the canonical package for Claude Code. Installations that do not preserve links can use the copied user-level layout above.

## Portable archive

Distribute the skill directory as an ordinary archive or use a `.skill` package for products that support it. Keep real files inside the package; do not rely on internal symlinks surviving ZIP downloads or Windows extraction.

## Compatibility limits

- Harness-specific permission, hook, tool-name, and manual-invocation fields are intentionally absent.
- Harnesses without subagents run reviewer lanes sequentially.
- Mutating lanes need harness-provided isolation or equivalent mutation isolation. OMP supplies isolated child tasks with `isolated: true` and a default patch handoff; it does not require manually managed worktrees.
- Local user skills do not automatically appear in cloud or sandbox sessions.
- Skill configuration is usually loaded at process start. Restart the harness after installation or updates.
