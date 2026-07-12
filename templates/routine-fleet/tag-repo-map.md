---
type: reference
slug: tag-repo-map
title: Tag to Repo Map - <PROJECT_NAME>
status: active
tags: routines, portability, config, fkanban
---
# Tag to Repo Map - <PROJECT_NAME>

Mapping used by board-grooming and program-driving routines when a card has
tags but lacks a `Repo:` header. Keep mappings conservative: a wrong repo is
worse than no repo.

## Rules

- `Repo:` must be one clean `owner/name` token alone on its own line.
- One tag may map to one default repo only.
- Ambiguous tags stay unmapped; the groom report should ask a human to choose.
- Routines do not infer repos from prose when this map is silent.

## Map

<!-- tag: the exact fkanban tag without "#". -->
<!-- Repo: the owner/name token used in task card headers. -->
<!-- notes: optional boundary or ambiguity note. -->

| tag | Repo: | notes |
|---|---|---|
| `<TAG_1>` | `<OWNER>/<REPO_1>` | `<WHEN_THIS_MAPPING_IS_VALID>` |
| `<TAG_2>` | `<OWNER>/<REPO_2>` | `<WHEN_THIS_MAPPING_IS_VALID>` |
| `<AMBIGUOUS_TAG>` | `(unmapped)` | `<WHY_A_HUMAN_MUST_PICK>` |

## Validation

- Every mapped repo appears in `repo-venue-map`.
- Every project-critical tag that should create pickup-ready cards appears here.
- No tag maps to a deprecated, archived, mirror-only, or hands-off repo.
