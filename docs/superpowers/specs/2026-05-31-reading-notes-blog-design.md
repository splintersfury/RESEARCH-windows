# Reading-Notes Blog — Design

**Date:** 2026-05-31
**Status:** Approved

## Purpose

A personal GitHub Pages blog for capturing notes while reading technical blogs/articles.
For each article read, record: the **source**, **running thoughts** as I read, **learning
points**, and **pivot topics** (new things to dive into next as my interest branches off).

## Decisions

- **Hosting:** GitHub Pages (published, public site).
- **Generator:** Jekyll (native to GitHub Pages, builds on push, no CI config needed).
- **Theme:** Chirpy — provides tags, categories, full-text search, per-post table of
  contents, dark mode, and a sidebar out of the box. Well suited to technical reading notes.
- **Pivot topics:** Captured *both* inline at the end of each post *and* rolled up into a
  single central backlog page so the reading queue is never lost.

## Repo Structure

```
RESEARCH-windows/
├── _config.yml              # site title, author handle, theme + plugin settings
├── _posts/                  # one markdown file per article read (YYYY-MM-DD-title.md)
├── _tabs/
│   └── backlog.md           # central "topics to dive into" page (nav tab)
├── _drafts/                 # optional in-progress notes not yet published
├── new-post.sh              # helper: stamp a dated post from the template
├── templates/
│   └── post.md              # the canonical per-post skeleton used by new-post.sh
└── (Chirpy theme files: assets, _data, etc.)
```

## Per-Post Template

```markdown
---
title: "<Title of the article>"
date: YYYY-MM-DD HH:MM:SS +0800
categories: [Reading Notes]
tags: []                      # topic tags, e.g. [windows, kernel]
source: "https://original-blog-url"
---

> **Source:** [Author / Site](https://original-blog-url)

## Summary
One or two lines on what the article is about.

## Notes & thoughts as I read
- Running commentary, quotes, reactions, questions.

## Learning points
- Concrete takeaways.

## Pivot topics — dive into next
- [ ] Topic X — why it caught my attention
- [ ] Topic Y
```

Pivot-topic checkboxes are also copied into `_tabs/backlog.md` so there is one running
cross-post queue of what to read/explore next.

## Workflow

1. Read an article.
2. Run `./new-post.sh "Article Title" "https://source-url"` → creates a dated file in
   `_posts/` pre-filled from `templates/post.md`.
3. Fill in summary, notes, learning points, pivot topics while/after reading.
4. Add any pivot topics to `_tabs/backlog.md`.
5. `git commit && git push` → GitHub Pages rebuilds and publishes automatically.

## new-post.sh Behavior

- Args: `"Title"` (required), `"source-url"` (optional).
- Slugifies the title (lowercase, spaces→dashes, strip punctuation).
- Prepends today's date → `_posts/YYYY-MM-DD-slug.md`.
- Substitutes title, date, and source URL into the template.
- Refuses to overwrite an existing file; prints the created path.

## Out of Scope (YAGNI)

- Comments system, analytics, custom domain — can be added later if wanted.
- Automated extraction of pivot topics into the backlog (done manually for now).

## Success Criteria

- Pushing a post to `main` results in it appearing on the published Pages site.
- Starting a new reading note is a single command.
- Every post has source, thoughts, learning points, and pivot topics.
- A central backlog page lists topics to explore next.
