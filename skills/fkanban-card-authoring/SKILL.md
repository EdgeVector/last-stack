---
name: fkanban-card-authoring
description: Compatibility shim for old fkanban-card-authoring prompts. Use the kanban skill for current card authoring and board-management guidance.
---

# fkanban-card-authoring compatibility

`fkanban-card-authoring` was renamed into the current `kanban` skill family.

For card authoring, filing, header shape, and board CRUD rules, use the
`kanban` skill. New prompts should say `kanban`; this file exists so older
automations that still request `fkanban-card-authoring` resolve to a real skill
file after setup.
