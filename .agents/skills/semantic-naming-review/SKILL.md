---
name: semantic-naming-review
description: Review code to ensure all identifiers (variables, functions, types, constants) accurately reflect their semantic meaning. Use after writing or modifying code to catch misleading names, inconsistencies, or names that don't match their purpose.
---

# Semantic Naming Review

Review code to ensure all identifiers accurately reflect their semantic meaning. Focus on recently modified code unless instructed otherwise.

## Core Principles

Names should be **intention-revealing**, not implementation-revealing. A name should tell you *what* something is or does, not *how* it does it.

## What to Check

### Variables & Constants

- **Accuracy**: Does the name match what it holds? `userCount` should be a count, not a list
- **Scope alignment**: Short names (`i`, `x`) for tiny scopes; descriptive names for larger scopes
- **Units/clarity**: `timeoutMs` not `timeout`; `fileSizeBytes` not `size`
- **No magic values**: Extract named constants for literals that appear more than once

### Functions & Methods

- **Verb-noun pattern**: `calculateTotal()`, `fetchUser()`, `validateEmail()`
- **Single responsibility**: If a name contains "And" or "Or", consider splitting
- **Return value clarity**: `getUser()` should return a user, not a boolean
- **Side effects**: `saveUser()` implies mutation; `userToString()` implies pure

### Booleans

- **Predicate clarity**: `isValid`, `hasPermission`, `canExecute` — not `status`, `flag`, `check`
- **Avoid negation**: `isEnabled` not `isNotDisabled`
- **Question form**: Name should read naturally as a yes/no question

### Collections

- **Pluralization**: `users` for arrays/lists, `userMap` for dictionaries
- **Element type**: `userList` is redundant if type is `List<User>`; prefer `users`
- **Key-value clarity**: `userById` not `map` or `data`

### Types & Classes

- **Noun-based**: `UserRepository`, `PaymentProcessor`, `HttpClient`
- **Avoid implementation details**: `UserStore` not `UserHashMap`
- **Consistency**: Same concept = same name across codebase (`client` vs `customer` = bad)

### General Checks

- **No abbreviations** (except universally known ones: `id`, `url`, `http`)
- **No single-letter names** outside loop counters or lambdas
- **No misleading names**: `data` and `info` are too vague; `response` should be a response object
- **Consistent terminology**: Pick one term per concept and stick to it

## Review Process

1. Identify recently modified code sections
2. For each identifier, ask: "If I only saw this name, would I understand what it represents?"
3. Check for consistency with existing codebase terminology
4. Flag names that are vague, misleading, or inconsistent
5. Suggest specific improvements with rationale

## Output Format

For each issue found:

```
❌ Current: `data`
✓ Suggested: `userProfile`
Reason: "data" is too vague; this holds user profile information
```

Only flag issues that genuinely impact readability or could mislead future readers. Don't nitpick if the name is acceptable, even if a slightly better name exists.
