# pr-vi-history

Reusable GitHub workflow that treats pull requests as the VI history analysis surface.

## What this repository provides

- `.github/workflows/pr-vi-history.yml` (reusable workflow)
- Local `tools/*` scripts required to generate manifest, run history compare,
  and render PR summaries.

## Downstream usage

```yaml
name: PR VI History Analysis

on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review, labeled]
    paths:
      - '**/*.vi'

permissions:
  contents: read
  pull-requests: write

jobs:
  vi-history:
    if: ${{ !github.event.pull_request.draft }}
    uses: svelderrainruiz/pr-vi-history/.github/workflows/pr-vi-history.yml@main
    with:
      pr_number: ${{ github.event.pull_request.number }}
      fetch_depth: '20'
      max_pairs: '6'
      compare_modes: 'default,attributes'
      include_merge_parents: false
      upload_artifact: true
      post_comment: true
    secrets: inherit
```

## Notes

- The workflow is self-contained and executes from this repository only.
- Once a stable tag is published, prefer pinning consumers to `@v1`.
