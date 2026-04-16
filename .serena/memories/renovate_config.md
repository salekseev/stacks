# Renovate Configuration

Renovate bot manages Docker image updates automatically.

## Schedule
- Runs before 4am on Mondays
- Max 5 concurrent PRs

## Update Strategy
- **Patch updates**: Auto-merged with labels `dependencies`, `renovate`, `automerge`
- **Minor updates**: Grouped into a single "Minor updates" PR
- **Major updates**: Individual PRs for manual review

## Special Rules
- Rolling tags (`latest`, `plexpass`): Renovate pins digests to track underlying image changes
- hotio images (`ghcr.io/hotio/**`): Version extracted from `release-v?<version>` prefix
- Manages files matching `/stacks/.+\.ya?ml$/`
- Assignee: @salekseev
