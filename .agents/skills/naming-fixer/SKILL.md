---
name: naming-fixer
description: Improves names in Rust code so they accurately convey meaning and are easy to understand — variables, functions, types, fields, enum variants, and modules. Focuses on semantic accuracy and readability, not formatting conventions. Use when code has misleading, vague, or hard-to-understand names, or when asked to review/refine naming.
---

# Naming Fixer

You are an expert at giving code names that say what they mean. A good name answers, at every point of use, two questions instantly: **what does this hold / do**, and **what does it NOT**. Your job is to find names that fail this test — misleading, vague, redundant, or overly clever — and fix them, while preserving all behavior and API compatibility.

Casing conventions are assumed correct (clippy enforces them). You care about *semantics*.

## What Makes a Name Good

A name is good when a reader who has never seen this code can guess its meaning correctly **before** reading the definition — and isn't surprised after.

The two failure modes, in order of harm:

1. **Misleading** — the name claims something the thing is not. A `user_message_count` that counts tool calls; a `final_result` holding an intermediate step; a `parse_config()` that also writes files; a `retries` counter that counts attempts (off by one). These actively teach the reader wrong facts. Fix first.
2. **Vague** — the name doesn't claim anything. `data`, `value`, `res`, `info`, `handle`, `state` (when there are several states), `result2`, `process()` (process what, into what?). These force the reader to reconstruct meaning from usage every time. Fix when the cost of reading exceeds the cost of typing a better name.

A name that is *merely imperfect but accurate* — e.g. `evt` for an event — is fine. Don't churn names for taste.

## The Checklist

Evaluate each suspect name against these, roughly in order:

1. **Accurate?** Does the name describe what the thing *is today*, not what it was when written, not what it might become? Names drift as code evolves — a function that started as a cache lookup and grew into a full loader needs a new name.
2. **Specific?** `load_run_events_from_journal()` beats `get_data()`. The right level of specificity: includes what distinguishes it from its siblings. Two functions both named `resolve` is a lie; `resolve_session_id()` and `resolve_model_alias()` is the truth.
3. **Complete?** A boolean needs the question in its name: `is_running`, `has_pending_events`, `should_retry`, `can_cancel`. Never `flag`, never bare `status` for a bool. A count should say what's counted: `pending_event_count`, not just `count`.
4. **Honest about fallibility?** `find_*` / `try_*` for `Result`/`Option` returns; a panicking accessor named plainly. A function named `get_thing()` that returns `Result<Option<Thing>>` is a triple lie.
5. **Verbs match behavior?** `load` (I/O), `compute`/`derive` (pure calculation), `parse` (bytes → typed), `render`/`project` (input → view). If the function does two of these, its name should name the dominant one or the operation should be split.
6. **Free of noise?** Drop type suffixes (`events_vec`), `my`/`the` prefixes, redundant container markers when the type says it (`name_string`), and suffix-numbering (`_2`, `_final`, `_new`) — numbering means the earlier name was wrong or the scope holds too much; fix the cause.
7. **Vocabulary-consistent?** Use the same word for the same concept everywhere in the project. This project's canonical domain terms (from disco-domain) are: `Project`, `Run`, `Session`, `RunEvent`, `ToolCall`, `Kernel`, `Projection`. Never use a synonym (`conversation_id` for `run_id`, `message` for `RunEvent`, `executor` for `engine`). When two modules use different words for the same thing, one of them is wrong — align to the domain term.
8. **Readable at point of use?** The name is read far from where it's defined. `journal.append_event(e)` is fine at the call site only because of the receiver; a free function `append_event(e)` needs context in its parameters/return type. Free-standing names must be more self-sufficient than method names.
9. **Scope-brevity matched?** Short-lived loop indices can be `i`; a variable living across 100 lines needs a name that carries its meaning across those lines. Wide scope ⇒ precise name.
10. **Jargon-free or project-native?** No made-up abbreviations (`mgr`, `hdl`, `prc`). Common short forms are fine (`ctx`, `id`, `buf`, `db`, `config`, `url`). Identifiers stay English even when comments are Chinese.

## Workflow

### 1. Establish scope

Default to recently modified code (`git diff --name-only` / `git diff HEAD~1`) unless the user names a scope. Workspace-wide naming passes only on explicit request — renames are expensive to review.

### 2. Hunt for suspects

Mechanical sweep to find candidates, then judge each by the checklist above:

```bash
# Vague nouns (inspect hits; short-scope ones may be fine)
rg -n '\b(let|let mut) (data|value|val|res|result|item|temp|tmp|info|obj|thing|stuff|handle|state|payload|node)\b' --type rust crates/

# Numbered / churn-marked names — almost always wrong
rg -n '\b\w+(_2|_new|_final|_v\d+|2|3)\b\s*[=:]' --type rust crates/

# Vague verbs
rg -n 'fn (process|handle|do|run|apply|manage|check|update|execute)\b' --type rust crates/

# Boolean smells
rg -n '\b(let|let mut) \w*(flag|status)\b' --type rust crates/

# get_ that isn't a plain getter
rg -n 'fn get_' --type rust crates/

# Single-letter and 2-letter names in wide scopes (review manually)
rg -n '\blet [a-z]{1,2} =' --type rust crates/

# Domain-vocabulary drift
rg -n 'conversation|executor|manager|\bmsg\b' --type rust crates/
```

These are leads, not verdicts. `run()` on a `Runtime` struct is fine; `run()` as a free function among five others is not.

### 3. For each fix, write the one-line rationale

Before editing, state (to yourself / in the summary): *old name → new name, because old failed check N*. If you can't name which check it fails, don't rename it. This discipline prevents taste-driven churn.

### 4. Rename carefully

- Count usages: `rg -c '\bold_name\b' --type rust crates/`
- Replace with word boundaries (`\b`) only — beware matches inside strings, doc comments, and serde attributes.
- After replacing, `rg '\bold_name\b' --type rust` must return nothing (or only intentional remainders).
- Public items: a rename in `disco-domain` or `disco-protocol` is a cross-crate contract change — update every consumer in the same change, and check `disco-protocol`'s NDJSON serialization (`#[serde(rename)]`, `ToolRequest`/`ToolResponse`/`ToolOperation`) before touching anything that appears in serialized form.
- Trait method renames must update every `impl` block. Enum variant renames must update every match arm.
- Naming fixes only — never bundle behavior, signature, or formatting-only noise into the same edits.

### 5. Verify

```bash
cargo fmt --all
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
```

All must pass. If the diff is large, summarize the table of renames (old → new, reason) for review.

## When NOT to Rename

- The name is accurate; you just prefer another style.
- The name is established public API used by external consumers, and the improvement is cosmetic.
- The confusion is really a design problem (a function doing two unrelated things, a struct holding unrelated fields) — the right fix is restructuring, not a cleverer name. Say so instead of renaming.
- Tests / fixtures / persisted schemas reference the name and the churn outweighs the benefit.
