---
name: user-vocabulary
description: |
  Speak to the user with ASD-STE100 and the user's word list. Use when you
  write to the user about the database or a change, when the user says vocab,
  vocabulary, word list, or ASD-STE100, when you add a word, or when the user
  runs /user-vocabulary.
allowed-tools:
  - Bash
  - Read
triggers:
  - vocab
  - vocabulary
  - word list
  - user-vocabulary
  - asd-ste100
  - add a word
---

# User vocabulary

Claude, Codex, and Grok use this skill. The word list is one file. The harness block is a copy of that file.

## Before you write to the user

1. Read the `last-stack:asd-ste100` block in the harness file. Follow those rules.
2. Read the `last-stack:user-vocabulary` block. Use those words for the database and for a change.
3. Describe a change in this order: current state, the change, the result, the next action.
4. Do not invent a word. A missing word stays out of the text until the user adds it.

## Add a word

Add a word only when the user asks for that word. Run:

```
last-stack-vocab add "WORD" --means "MEANING" --section database
```

The section is `database`, `change`, or `unapproved`.

For a word that belongs to one repo, run the same command with `--project` inside that repo. A project word does not enter the user file.

Then run `last-stack-vocab path` and confirm the new row.

## Do not

- Do not edit the harness copy. The next setup replaces that block.
- Do not put a project word in the user file.
