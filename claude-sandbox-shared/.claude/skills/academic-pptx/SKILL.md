---
name: academic-pptx
description: "Use this skill whenever the user wants to create or improve a presentation for an academic context — conference papers, seminar talks, thesis defenses, grant briefings, lab meetings, invited lectures, or any presentation where the audience will evaluate reasoning and evidence. Triggers include: 'conference talk', 'seminar slides', 'thesis defense', 'research presentation', 'academic deck', 'academic presentation'. Also triggers when the user asks to 'make slides' in combination with academic content (e.g., 'make slides for my paper on X', 'create a presentation for my dissertation defense', 'build a deck for my grant proposal'). This skill governs CONTENT and STRUCTURE decisions. For the technical work of creating or editing the .pptx file itself, also read the pptx SKILL.md."
license: Proprietary. LICENSE.txt has complete terms
---

# Academic Presentations Skill

## How This Skill Works

This skill has two layers:

1. **This file** — governs content, argument structure, and design standards for academic presentations. Read it fully before planning any slides.
2. **PPTX skill** — governs the technical implementation (creating, editing, and QA-ing the .pptx file). Read it too.

**Always read both before writing any code or creating any files.**

---

## Quick Reference

| Task | Guide |
|------|-------|
| Content planning, argument structure, slide-by-slide rules | [content_guidelines.md](content_guidelines.md) |
| Per-slide-type patterns (title, methods, results, etc.) | [slide_patterns.md](slide_patterns.md) |
| Technical creation from scratch | PPTX skill → `pptxgenjs.md` |
| Technical editing of an existing file | PPTX skill → `editing.md` |

---

## Step 1: Identify Presentation Type

Before planning a single slide, determine which mode applies.

### Structured Argument (default for academic work)

Use for: conference papers, seminar talks, thesis defenses, dissertation chapters, grant briefings, internal lab presentations, policy briefings, consulting-style research deliverables.

**Priority order: argument structure → data → layout → aesthetics.**

Follow [content_guidelines.md](content_guidelines.md) in full.

### Visual / Narrative

Use for: public engagement talks, science communication to non-specialist audiences, funding pitches to lay panels, event keynotes.

Follow the PPTX skill's design-forward guidelines. Argument structure still matters, but visual storytelling and emotional engagement take priority.

### When in doubt

Default to **Structured Argument**. If the user mentions a paper, a study, a dataset, a thesis, a grant, or a conference, they almost certainly want structured argument mode.

---

## Step 2: Plan the Deck Before Creating Any Slides

Produce a slide-by-slide outline (title, action title, exhibit type) and confirm with the user if the deck is more than 10 slides or if the content is complex. Do not start building until the outline is agreed.

Use the ghost deck test during planning: read only the proposed action titles in sequence. They must tell the complete argument. If they don't, fix the outline before building.

---

## Step 3: Apply Design Standards

Academic presentations use **communication-first design**. These rules override the PPTX skill's design-forward defaults.

### Color

- White background for all content slides.
- One sans-serif font throughout (Arial, Calibri, or Helvetica — confirm with user or match their institution's template if provided).
- Maximum three colors: one primary, one accent, one for emphasis or alerts. Default: dark navy primary (`1F4E79`), mid-blue accent (`2E75B6`), white or off-white background.
- No decorative color gradients, no themed color palettes unless the user explicitly requests them.
- Use color to **direct attention** — highlight the key finding on a chart, mark a callout box — not for decoration.

### Typography

| Element | Size | Weight |
|---------|------|--------|
| Title-slide main title | 36 pt | Regular |
| Title-slide subtitle | 18 pt | Regular |
| Content-slide action title | 24 pt | Bold |
| Section header (within slide) | 16 pt | Bold |
| Body bullets (main, level 0) | 18 pt | Regular |
| Body bullets (sub, level 1) | 15 pt | Regular |
| Chart labels / annotations | 14–16 pt | Regular |
| Source citations on slides | 10–12 pt | Regular, muted color |
| Footer (author, page #) | 9–10 pt | Regular, muted color |

The blue title band (or equivalent title region) must be tall enough to fit **two lines of the content-slide title at 24 pt**, with normal line spacing and small top/bottom padding. For 24 pt × 1.2 line-height = 0.4" per line → band height ≥ ~1.0".

Single font face. Use size and weight for hierarchy — never multiple typefaces.

### Layout

- Left-align all body text. Center only slide titles and axis labels.
- Consistent grid: all text boxes and figures align to the same margins (minimum 0.5" from slide edges).
- For result slides: figure on the left, interpretive bullets on the right. This matches natural left-to-right reading.
- White space is a signal of analytical clarity — do not fill every inch.
- 16:9 widescreen is the default. Confirm with the user if they know the venue's aspect ratio.

### Avoid (Academic-Specific)

- **No decorative icons** — icons in colored circles, stock images, clip art are inappropriate for analytical academic presentations.
- **No accent lines under titles** — use whitespace instead.
- **No color palettes chosen for aesthetic interest** — use institution colors or the minimal defaults above.
- **No full-bleed background images on content slides** — reserve for title/section dividers only if desired.
- **No text-heavy slides** — if the audience is reading, they are not listening. Maximum ~40 words of body text per content slide.

---

## Step 3.3: Optional Branding / Logos

Templates may declare a `branding` config (logo paths + sizes). The renderer applies branding ONLY if the image files exist on disk — if they're missing, the slide renders without the logo, with no warning and no crash. This keeps decks portable: the same builder works on a machine with the logo files and on one without.

Convention:
- Drop logo PNGs (transparent background preferred) in a known assets directory (e.g. `slides/assets/`).
- Each template's `branding` dict points at filenames in that directory + heights for placement.
- Logos appear on title + conclusions slides (lower-right, ~0.5–0.7" tall) and optionally as a small mark in the footer of every content slide (~0.22" tall).
- A README in the assets directory must list each filename, where it appears, and the recommended size.

To turn branding off entirely for a template, set the relevant paths to `None` in the `branding` dict (or simply do not ship the asset files).

When implementing branding in a builder, every renderer must accept a `branding=None` kwarg and either use it (title + conclusions + footer) or ignore it. Never make branding mandatory.

---

## Step 3.4: Template Selection

Builders may ship more than one visual template (e.g. `academic` minimalist, `senegal` blue-band). Templates share the same content schema (action titles, bullets, figures, citations) — they only differ in chrome (canvas size, colors, fonts, header treatment, footer).

Selection mechanism:
- Builders expose a registry (e.g. a `TEMPLATES` dict) and a default template.
- Choice is plumbed via env var (e.g. `SLIDE_TEMPLATE=academic python3 build.py`) or an explicit CLI flag — never hardcoded.
- The user-facing harness (Claude Code, claude.ai) does NOT have a built-in template picker. To switch templates the user either (a) tells Claude to switch and rebuild, or (b) sets the env var themselves and re-runs the build script.
- The action-title rule, ghost-deck test, and citation discipline apply across ALL templates. Templates change appearance, not argument structure.

When changing templates, regenerate all four artifacts (.pptx / .md / .pdf / .ppt) so the on-disk set is internally consistent.

---

## Step 3.5: Always Emit Markdown Companion AND PDF Render

Every build of an academic deck must produce three artifacts side-by-side at the same base path:

| Artifact | Purpose |
|----------|---------|
| `deck.pptx` | Editable source of truth |
| `deck.md`   | Human-readable Marp-flavored content mirror — scan, diff, paste-review without PowerPoint |
| `deck.pdf`  | Frozen render for sharing, archiving, and visual review without local PowerPoint |

The PDF is generated from the .pptx via headless LibreOffice (`soffice --headless --convert-to pdf`) or an equivalent renderer. If neither LibreOffice nor an alternative is available, print a warning and continue — do NOT silently skip the pptx + md outputs.

**Font dependency (critical for fidelity):** the fonts the deck uses (Open Sans, Arial, etc.) must be installed on the system that runs LibreOffice — otherwise soffice substitutes them with system defaults (Liberation/DejaVu) that have different character widths, causing text reflow and misaligned wraps in the PDF/PPT outputs. The PPTX itself stays correct because PowerPoint embeds the font reference, not the rendered glyphs. Before declaring the build done, verify the PDF visually matches the PPTX. If they differ, install the missing fonts (e.g. `apt install fonts-open-sans fonts-liberation`) and re-render.

Conventions for the markdown file:

- Marp frontmatter at the top so it renders directly:
  ```
  ---
  marp: true
  theme: default
  paginate: true
  size: 16:9
  ---
  ```
- One slide per `---` separator. First-line `# ` (or `## `) heading on each slide is the **action title** verbatim from the .pptx.
- Bullet structure mirrors the .pptx bullets (one `-` per main bullet, two-space indent for sub-bullets).
- Figure references use markdown image syntax with the same paths the .pptx uses: `![](/abs/path/to/figure.png)`.
- Callout / annotation text appears on its own line as `> **Note:** …` blockquote so it stands out in plain rendering.
- Citation footer appears as the last line of the slide, italicized: `*Source: …*`.
- Skip the dark-background sandwich treatment in the markdown — markdown is for content review, not design fidelity.

Generation rules:

- Build both files in a single pass — keep the slide content in one data structure (list of dicts, slide objects, etc.) and dispatch to a `render_pptx` and a `render_markdown` function so the two outputs cannot drift.
- Apply the same skip-if-exists check: if either output already exists, print a warning and exit without overwriting.
- The markdown is a derived artifact, not a source. Editing the .md does not regenerate the .pptx; the Python (or pptxgenjs) builder is the source of truth.

---

## Step 4: Build and QA

Follow the PPTX skill's QA procedure in full, including:
- Content QA via `markitdown`
- Visual QA via slide images (subagents if available)
- Fix-and-verify loop until a full pass reveals no new issues

**Additionally, run the academic-specific checks:**

```
Academic QA checklist:
□ Every content slide has an action title (complete sentence stating the takeaway)
□ Ghost deck test passes (action titles alone tell the full argument)
□ One exhibit per results slide; each exhibit has a "so what" annotation
□ Every borrowed figure or data point has an in-slide citation
□ A References slide exists at the end
□ Conclusions slide is the last non-appendix slide (not "Thank You" or a blank)
□ Contact information and/or QR code/link on the final slide
□ Font sizes are readable from the back of a room (≥ 20 pt body text)
□ No decorative elements that don't carry content
□ Section dividers or breadcrumb bar present for decks > 15 slides
□ Companion .md file written alongside the .pptx (Marp frontmatter, action titles, mirrored bullets, citations as italics)
□ PDF render (.pdf) of the .pptx written alongside, via headless LibreOffice
```

---

## Key Principles (Summary)

**Action titles, not topic labels.** Every slide title is a complete sentence stating the takeaway. Reading titles alone should tell the whole argument (ghost deck test).

**One argument, made well.** Don't present your whole paper. Pick the claim that can be made convincingly in the allotted time. Everything else goes in the appendix.

**One insight per slide.** One exhibit per results slide. Highlight the key finding directly on the chart — don't make the audience hunt for it.

**Slides support speech; they don't replace it.** Body text is for orientation, not information transfer. The presenter carries the argument; the slide carries the evidence.

**Cite everything borrowed.** Academic integrity applies to slides. In-text citations on the slide, full references on the References slide.

**End on conclusions.** The conclusions slide stays on screen during Q&A. Never end on "Thank You" or a blank slide.

---

## Dependencies

Same as PPTX skill:
- `pip install "markitdown[pptx]"` — text extraction
- `npm install -g pptxgenjs` — creating from scratch
- LibreOffice (`soffice`) — PDF conversion
- Poppler (`pdftoppm`) — PDF to images
