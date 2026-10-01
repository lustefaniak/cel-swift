# Vendored skills

Third-party agent skills, copied verbatim (MIT, licence file in each directory). Re-sync by copying the
skill directory from upstream again; do not edit them in place, put repo-specific overrides in `CLAUDE.md`.

| Skill | Upstream | Commit |
|---|---|---|
| `swift-concurrency-pro` | https://github.com/twostraws/Swift-Concurrency-Agent-Skill | bee3f69 |
| `swift-testing-pro` | https://github.com/twostraws/Swift-Testing-Agent-Skill | 2d6bba1 |
| `swift-api-design-guidelines` | https://github.com/Erikote04/Swift-API-Design-Guidelines-Agent-Skill | 36cdc1b |

The only local change: the API design skill's `name:` dropped the `-skill` suffix.
