# Reading-Notes Blog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up a published GitHub Pages blog (Jekyll + Chirpy theme) for capturing reading notes, with a one-command new-post helper and a central pivot-topic backlog.

**Architecture:** Bootstrap from the official `chirpy-starter` (gem-based Chirpy theme). The site builds via the GitHub Actions workflow bundled with the starter and deploys to GitHub Pages. A `templates/post.md` skeleton plus a `new-post.sh` script make starting a reading note a single command. A `_tabs/backlog.md` page holds the running cross-post queue.

**Tech Stack:** Ruby, Bundler, Jekyll, `jekyll-theme-chirpy` gem, GitHub Actions, GitHub Pages.

---

## Prerequisites & Notes

- The Chirpy gem theme is **not** in GitHub Pages' built-in allowed-themes list, so it builds via the GitHub Actions workflow shipped in the starter (`.github/workflows/pages-deploy.yml`). This still means "push → it builds and publishes automatically," just through Actions rather than the native Pages Jekyll builder.
- Local preview requires Ruby + Bundler. If `bundle` is unavailable in this environment, the local-build verification steps can be skipped and verification deferred to the live Actions build after push — note this if it happens rather than silently skipping.
- The working directory `/home/splintersfury/RESEARCH-windows` already has a git repo (with the design spec committed). We layer the blog on top of it.

## File Structure

```
RESEARCH-windows/
├── _config.yml                       # site identity + Chirpy settings (from starter, edited)
├── Gemfile                           # jekyll + jekyll-theme-chirpy (from starter)
├── _tabs/
│   ├── about.md                      # from starter
│   └── backlog.md                    # NEW: central pivot-topic queue
├── _posts/
│   └── 2026-05-31-welcome.md         # NEW: first sample reading note (smoke test)
├── templates/
│   └── post.md                       # NEW: canonical per-post skeleton
├── new-post.sh                       # NEW: stamp a dated post from the template
├── .github/workflows/pages-deploy.yml # from starter (Actions build/deploy)
└── (other Chirpy starter files: assets/, _data/, _plugins/, tools/, etc.)
```

---

### Task 1: Bootstrap the Chirpy starter into the repo

**Files:**
- Create: many (Chirpy starter contents) at repo root.
- Preserve: existing `docs/`, `.gitignore`, git history.

- [ ] **Step 1: Clone the starter into a temp dir**

```bash
cd /tmp && rm -rf chirpy-starter && \
git clone --depth 1 https://github.com/cotes2020/chirpy-starter.git chirpy-starter
```
Expected: clone succeeds, `/tmp/chirpy-starter` populated.

- [ ] **Step 2: Copy starter contents into the repo (without its .git)**

```bash
rm -rf /tmp/chirpy-starter/.git
cp -rn /tmp/chirpy-starter/. /home/splintersfury/RESEARCH-windows/
```
Expected: `_config.yml`, `Gemfile`, `_tabs/`, `.github/`, `assets/`, `tools/` now exist in the repo. `-n` (no-clobber) protects the existing `.gitignore`/`docs/`.

- [ ] **Step 3: Merge starter .gitignore entries**

Ensure the repo `.gitignore` contains the Jekyll ignores (already present from the spec commit: `_site/`, `.jekyll-cache/`, `vendor/`, `.bundle/`, `Gemfile.lock`). If the starter shipped extra entries not present, append them. Verify:

Run: `cat /home/splintersfury/RESEARCH-windows/.gitignore`
Expected: includes `_site/` and `.jekyll-cache/`.

- [ ] **Step 4: Commit the bootstrap**

```bash
cd /home/splintersfury/RESEARCH-windows
git add -A
git commit -m "Bootstrap Chirpy starter"
```

---

### Task 2: Configure site identity in _config.yml

**Files:**
- Modify: `_config.yml`

- [ ] **Step 1: Set the core identity fields**

Edit `_config.yml` and set these keys (leave other Chirpy defaults as-is):

```yaml
title: RESEARCH-windows
tagline: Reading notes & thoughts on Windows internals and security
description: >-
  Notes, reactions, and learning points captured while reading technical blogs.
url: "https://<github-username>.github.io"
github:
  username: <github-username>
social:
  name: <your name>
  email: csdpahmadabdillahbinzaini@gmail.com
timezone: Asia/Singapore
theme_mode: # leave blank = follow system (light/dark toggle available)
```

Replace `<github-username>` and `<your name>` with real values. If the repo will be published at `https://<user>.github.io/RESEARCH-windows`, also set `baseurl: "/RESEARCH-windows"`; if it's the user/org root site, leave `baseurl` empty.

- [ ] **Step 2: Verify YAML parses**

Run: `cd /home/splintersfury/RESEARCH-windows && ruby -ryaml -e "YAML.load_file('_config.yml'); puts 'OK'"`
Expected: `OK` (no parse error). If Ruby is unavailable, visually confirm indentation is intact.

- [ ] **Step 3: Commit**

```bash
git add _config.yml
git commit -m "Configure site identity"
```

---

### Task 3: Add the per-post template

**Files:**
- Create: `templates/post.md`

- [ ] **Step 1: Write the template**

Create `templates/post.md` with exactly:

```markdown
---
title: "TITLE_PLACEHOLDER"
date: DATE_PLACEHOLDER
categories: [Reading Notes]
tags: []
source: "SOURCE_PLACEHOLDER"
---

> **Source:** [Original article](SOURCE_PLACEHOLDER)

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

The `*_PLACEHOLDER` tokens are substituted by `new-post.sh` (Task 4).

- [ ] **Step 2: Commit**

```bash
git add templates/post.md
git commit -m "Add per-post reading-note template"
```

---

### Task 4: Add the new-post.sh helper

**Files:**
- Create: `new-post.sh`

- [ ] **Step 1: Write the script**

Create `new-post.sh` with exactly:

```bash
#!/usr/bin/env bash
# Usage: ./new-post.sh "Article Title" ["https://source-url"]
set -euo pipefail

TITLE="${1:-}"
SOURCE="${2:-}"

if [ -z "$TITLE" ]; then
  echo "Usage: $0 \"Article Title\" [\"https://source-url\"]" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="$ROOT/templates/post.md"
[ -f "$TEMPLATE" ] || { echo "Template not found: $TEMPLATE" >&2; exit 1; }

DATE_YMD="$(date +%Y-%m-%d)"
DATE_FULL="$(date '+%Y-%m-%d %H:%M:%S %z')"

# slug: lowercase, non-alphanumeric -> dash, collapse/trim dashes
SLUG="$(printf '%s' "$TITLE" \
  | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"

OUT="$ROOT/_posts/${DATE_YMD}-${SLUG}.md"
[ -e "$OUT" ] && { echo "Refusing to overwrite existing file: $OUT" >&2; exit 1; }

mkdir -p "$ROOT/_posts"

# Substitute placeholders (use a delimiter unlikely to appear in URLs/titles)
sed \
  -e "s|TITLE_PLACEHOLDER|${TITLE}|g" \
  -e "s|DATE_PLACEHOLDER|${DATE_FULL}|g" \
  -e "s|SOURCE_PLACEHOLDER|${SOURCE}|g" \
  "$TEMPLATE" > "$OUT"

echo "Created: $OUT"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x /home/splintersfury/RESEARCH-windows/new-post.sh
```

- [ ] **Step 3: Smoke-test the script**

```bash
cd /home/splintersfury/RESEARCH-windows
./new-post.sh "Welcome to my reading notes" "https://example.com/article"
```
Expected: prints `Created: .../_posts/2026-05-31-welcome-to-my-reading-notes.md`, and the file exists with placeholders replaced (title, date, source filled in). Verify:

Run: `head -10 _posts/2026-05-31-welcome-to-my-reading-notes.md`
Expected: front matter shows the real title, a dated timestamp, and the source URL — no `*_PLACEHOLDER` tokens remain.

- [ ] **Step 4: Replace the smoke-test post with a real welcome post**

Remove the smoke-test file and create a clean first post named `2026-05-31-welcome.md`:

```bash
rm -f _posts/2026-05-31-welcome-to-my-reading-notes.md
./new-post.sh "Welcome" "https://github.com"
mv _posts/2026-05-31-welcome.md _posts/2026-05-31-welcome.md 2>/dev/null || true
```
Then edit `_posts/2026-05-31-welcome.md` to fill the Summary with one line: "First post — this blog collects my notes while reading technical articles." Leave the other sections as the template prompts.

- [ ] **Step 5: Commit**

```bash
git add new-post.sh _posts/2026-05-31-welcome.md
git commit -m "Add new-post.sh helper and first post"
```

---

### Task 5: Add the central backlog page

**Files:**
- Create: `_tabs/backlog.md`

- [ ] **Step 1: Write the backlog tab**

Create `_tabs/backlog.md` with exactly:

```markdown
---
# the default layout is 'page'
icon: fas fa-list-check
order: 5
title: Backlog
---

Running queue of topics to dive into next, pulled from the **Pivot topics** section of
each post. Check items off as you write them up.

## To explore

- [ ] _(example)_ Windows object headers — surfaced while reading the welcome post

## Done

- [x] _(example)_ Set up this blog
```

The `order: 5` places it after the default Chirpy tabs; adjust if it collides with an existing tab's order.

- [ ] **Step 2: Verify front matter order is unique**

Run: `grep -rh '^order:' /home/splintersfury/RESEARCH-windows/_tabs/`
Expected: each `order:` value is distinct. If `5` is taken, bump `backlog.md` to the next free integer.

- [ ] **Step 3: Commit**

```bash
git add _tabs/backlog.md
git commit -m "Add central pivot-topic backlog page"
```

---

### Task 6: Verify the site builds locally

**Files:** none (build verification only)

- [ ] **Step 1: Install dependencies**

```bash
cd /home/splintersfury/RESEARCH-windows
bundle install
```
Expected: gems install, including `jekyll-theme-chirpy`. If `bundle` is unavailable, record that and skip to Task 7 (verification deferred to the live Actions build).

- [ ] **Step 2: Build the site**

```bash
bundle exec jekyll build
```
Expected: "done in X.XX seconds", `_site/` generated, no errors. Warnings about the example/welcome post are acceptable.

- [ ] **Step 3: Confirm key pages rendered**

Run: `ls _site/ && ls _site/posts/ 2>/dev/null; test -f _site/index.html && echo INDEX_OK`
Expected: `INDEX_OK` printed; the welcome post and a backlog page exist under `_site/`.

- [ ] **Step 4: (Optional) Serve and eyeball**

```bash
bundle exec jekyll serve --livereload
```
Open `http://127.0.0.1:4000`. Confirm: home lists the welcome post, the Backlog tab appears in the sidebar, dark/light toggle works. Ctrl-C to stop. No commit (nothing changed).

---

### Task 7: Publish to GitHub Pages

**Files:** none (remote setup)

- [ ] **Step 1: Create the GitHub repo and push**

If using the GitHub CLI:

```bash
cd /home/splintersfury/RESEARCH-windows
gh repo create RESEARCH-windows --public --source=. --remote=origin --push
```
Otherwise create the repo on github.com, then:

```bash
git remote add origin https://github.com/<github-username>/RESEARCH-windows.git
git branch -M main
git push -u origin main
```
Expected: `main` pushed; the bundled `.github/workflows/pages-deploy.yml` appears under the repo's Actions tab.

- [ ] **Step 2: Enable Pages with GitHub Actions as the source**

In the repo: **Settings → Pages → Build and deployment → Source → GitHub Actions**. (The Chirpy workflow deploys via the Pages Actions pipeline, so the source must be "GitHub Actions," not "Deploy from a branch.")

- [ ] **Step 3: Confirm the deploy succeeded**

Watch the Actions run (or `gh run watch`). Expected: the "Build and Deploy" workflow goes green.

- [ ] **Step 4: Verify the live site**

Visit `https://<github-username>.github.io/` (or `/RESEARCH-windows/` if `baseurl` was set). Expected: the blog loads, the welcome post is listed, the Backlog tab is present.

---

## Self-Review

**Spec coverage:**
- GitHub Pages publishing → Task 7.
- Jekyll generator → Tasks 1, 6.
- Chirpy theme (tags, categories, search, ToC, dark mode) → Task 1 (starter ships all of these).
- Pivot topics inline → Task 3 template's "Pivot topics" section.
- Pivot topics central backlog → Task 5.
- Per-post structure (source, thoughts, learning points, pivots) → Task 3 template.
- one-command new post → Task 4 `new-post.sh`.
- Refuse to overwrite existing post → Task 4 Step 1 (`[ -e "$OUT" ]` guard).
- Slugify title → Task 4 Step 1 (`tr`/`sed` pipeline).
- Success criteria (push → publish; single-command post; every post has the four sections; backlog page) → Tasks 4–7.

No gaps found.

**Placeholder scan:** The only `*_PLACEHOLDER` tokens are intentional template substitution markers consumed by `new-post.sh`; not plan placeholders. No TBD/TODO/"handle edge cases" present.

**Type/name consistency:** Template tokens `TITLE_PLACEHOLDER` / `DATE_PLACEHOLDER` / `SOURCE_PLACEHOLDER` are defined in Task 3 and substituted by the matching `sed` expressions in Task 4. Paths (`templates/post.md`, `_posts/`, `_tabs/backlog.md`, `new-post.sh`) are consistent across tasks.
