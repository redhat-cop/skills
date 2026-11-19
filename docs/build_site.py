#!/usr/bin/env python3
"""Build the documentation site into _site/ (deployed to GitHub Pages).

Markdown stays the source of truth in the repo; this renders it into the
Red Hat-branded theme extracted from the j8fns post-mortem. The skill
catalog on the home page is generated from skills/*/SKILL.md frontmatter
at build time, so the site can never drift from the skills.

Stdlib + `markdown` + `pyyaml` (for the shared frontmatter parser).
"""
from __future__ import annotations

import html
import re
import shutil
import sys
from datetime import UTC, datetime
from pathlib import Path

import markdown

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
OUT = ROOT / "_site"

# make the generated-catalog helper importable
sys.path.insert(0, str(ROOT / "scripts"))
import generate_index

REPO_URL = "https://github.com/redhat-cop/skills"

PAGES = [
    {
        "slug": "index",
        "output": "index.html",
        "title": "Red Hat CoP Skills",
        "page_title": "Red Hat CoP Skills — agent skills for Red Hat technologies",
        "eyebrow": "Red Hat Community of Practice · Agent Skills · agentskills.io spec",
        "dek": "Field-contributed agent skills for Red Hat technologies — reusable "
               "SKILL.md-style automations for AI coding agents, installed in one "
               "command into Claude Code, Codex, Cursor, OpenCode, Pi, Hermes, "
               "OpenClaw, OpenHands and DeepSeek.",
        "meta": [
            'Spec: <a href="https://agentskills.io/specification">Agent Skills</a>',
            f'License: <a href="{REPO_URL}/blob/main/LICENSE">Apache-2.0</a>',
            "Install: <code>npx skills add redhat-cop/skills</code>",
        ],
        "source": None,  # assembled in code
    },
    {
        "slug": "install",
        "output": "install.html",
        "title": "Install",
        "page_title": "Install — Red Hat CoP Skills",
        "eyebrow": "Red Hat CoP Skills · install",
        "dek": "One command, every harness. The skills CLI scans this repo, detects "
               "your installed agents, and links the skills where each one reads them.",
        "meta": ["CLI: <code>npx skills add redhat-cop/skills</code>"],
        "source": "pages/install.md",
    },
    {
        "slug": "authoring",
        "output": "authoring.html",
        "title": "Authoring a skill",
        "page_title": "Authoring a skill — Red Hat CoP Skills",
        "eyebrow": "Red Hat CoP Skills · authoring",
        "dek": "The frontmatter contract, house rules and quality bar. The full text "
               "lives in CONTRIBUTING.md — this page is the rendered companion.",
        "meta": [
            f'Full contract: <a href="{REPO_URL}/blob/main/CONTRIBUTING.md">CONTRIBUTING.md</a>',
            f'Starter: <a href="{REPO_URL}/tree/main/template">template/skill-name/</a>',
        ],
        "source": "pages/authoring.md",
    },
    {
        "slug": "governance",
        "output": "governance.html",
        "title": "Governance",
        "page_title": "Governance — Red Hat CoP Skills",
        "eyebrow": "Red Hat CoP Skills · governance",
        "dek": "PR-only, tiered approvals, per-skill ownership enforced by CI. "
               "Maintainers: eformat, hultzj.",
        "meta": [
            f'Full model: <a href="{REPO_URL}/blob/main/MAINTAINERS.md">MAINTAINERS.md</a>',
            f'Ownership: <a href="{REPO_URL}/blob/main/CODEOWNERS">CODEOWNERS</a>',
        ],
        "source": "pages/governance.md",
    },
    {
        "slug": "pr-workflow",
        "output": "pr-workflow.html",
        "title": "PR workflow",
        "page_title": "PR workflow — Red Hat CoP Skills",
        "eyebrow": "Red Hat CoP Skills · PR workflow",
        "dek": "Phase cards, an automated reviewer, guarded merges. What happens to "
               "your PR the moment you open it — and the two commands maintainers use "
               "to steer it.",
        "meta": [
            f'Agent skills: <a href="{REPO_URL}/tree/main/skills/pr-agent">skills/pr-agent</a>',
            f'Contract: <a href="{REPO_URL}/blob/main/CONTRIBUTING.md">CONTRIBUTING.md</a>',
        ],
        "source": "pages/pr-workflow.md",
    },
    {
        "slug": "faq",
        "output": "faq.html",
        "title": "FAQ",
        "page_title": "FAQ — Red Hat CoP Skills",
        "eyebrow": "Red Hat CoP Skills · faq",
        "dek": "Which agents, how evals work, versioning, and why there is no marketplace (yet).",
        "meta": [],
        "source": "pages/faq.md",
    },
]

FOOTER = (
    "Red Hat CoP Skills · community-maintained under Apache-2.0 · "
    "not an official Red Hat product · site generated "
    + datetime.now(UTC).strftime("%Y-%m-%d %H:%M UTC")
)

MATURITY_DOT = {
    "stable": '<span class="maturity stable"><span class="dot"></span>stable</span>',
    "experimental": '<span class="maturity experimental"><span class="dot"></span>experimental</span>',
    "deprecated": '<span class="maturity deprecated"><span class="dot"></span>deprecated</span>',
}


def md_to_html(text: str) -> str:
    return markdown.markdown(text, extensions=["extra", "sane_lists", "smarty", "toc"])


def wrap_sections(page_html: str) -> str:
    """Wrap h2-delimited chunks in <section> so the theme's section styling
    (56px padding, hairline separators) applies — markdown emits bare h2s."""
    parts = re.split(r"(?=<h2\b)", page_html)
    wrapped = [f"<section>\n{p.strip()}\n</section>" for p in parts if p.strip()]
    return "\n\n".join(wrapped)


def toc_from_html(page_html: str) -> tuple[str, str]:
    """Extract <h2 id=…> entries into TOC list items and a nav block."""
    items = []
    for m in re.finditer(r'<h2 id="([^"]+)">(.*?)</h2>', page_html):
        items.append(f'    <li><a href="#{m.group(1)}">{m.group(2)}</a></li>')
    return "\n".join(items)


def nav_items(current_slug: str) -> str:
    labels = {"index": "Home", "install": "Install", "authoring": "Authoring",
              "pr-workflow": "PR workflow", "governance": "Governance", "faq": "FAQ"}
    parts = []
    for p in PAGES:
        cls = ' class="active"' if p["slug"] == current_slug else ""
        parts.append(f'      <li><a{cls} href="{p["output"]}">{labels[p["slug"]]}</a></li>')
    return "\n".join(parts)


def kpi_row(skills: list[dict]) -> str:
    total = len(skills)
    stable = sum(1 for s in skills if s["maturity"] == "stable")
    experimental = sum(1 for s in skills if s["maturity"] == "experimental")
    return f"""  <div class="kpis">
    <div class="kpi"><p class="kpi-label">Skills in the collection</p><p class="kpi-value num">{total}</p><p class="kpi-ctx">all Agent Skills spec compliant, harness-neutral</p></div>
    <div class="kpi"><p class="kpi-label">Stable</p><p class="kpi-value num">{stable}</p><p class="kpi-ctx">field-proven, owned, review-gated</p></div>
    <div class="kpi"><p class="kpi-label">Experimental</p><p class="kpi-value num">{experimental}</p><p class="kpi-ctx">new, maturing in the field</p></div>
    <div class="kpi"><p class="kpi-label">Install one</p><p class="kpi-value cmd">npx skills add redhat-cop/skills</p><p class="kpi-ctx">auto-detects your agents; <code>-a</code> to pick</p></div>
  </div>"""


def catalog_table(skills: list[dict]) -> str:
    if not skills:
        return ("<p>No skills yet — be the first! See the "
                f'<a href="{REPO_URL}/blob/main/CONTRIBUTING.md">authoring guide</a>.</p>')
    rows = []
    for s in skills:
        desc = html.escape(s["description"])
        dot = MATURITY_DOT.get(s["maturity"], html.escape(s["maturity"]))
        owner = f'<a href="https://github.com/{s["owner"]}">@{s["owner"]}</a>' if s["owner"] else ""
        rows.append(
            f'<tr><td><a href="{REPO_URL}/tree/main/{s["path"]}">{s["name"]}</a></td>'
            f'<td>{desc}</td><td class="num">{html.escape(s["version"])}</td>'
            f'<td>{dot}</td><td>{owner}</td></tr>'
        )
    return (
        '<div class="tbl-wrap"><table>\n<thead><tr><th>Skill</th><th>Description</th>'
        '<th>Version</th><th>Maturity</th><th>Owner</th></tr></thead>\n<tbody>\n'
        + "\n".join(rows) + "\n</tbody></table></div>"
    )


def build_index() -> tuple[str, str]:
    skills = generate_index.collect_skills()
    intro_md = (HERE / "pages" / "_index-intro.md").read_text(encoding="utf-8")
    content = md_to_html(intro_md)
    content += "\n" + kpi_row(skills)
    content += "\n" + catalog_table(skills)
    content = wrap_sections(content)
    toc = toc_from_html(content)
    return content, toc


def render_page(page: dict, content: str, toc: str) -> str:
    template = (HERE / "theme" / "template.html").read_text(encoding="utf-8")
    meta = "\n".join(f"      <li>{m}</li>" for m in page["meta"]) or "      <li>&nbsp;</li>"
    out = template
    for key, value in {
        "PAGE_TITLE": page["page_title"],
        "EYEBROW": page["eyebrow"],
        "TITLE": page["title"],
        "DEK": page["dek"],
        "META": meta,
        "NAV": nav_items(page["slug"]),
        "TOC": toc or "    <li><a href=\"#top\">Top</a></li>",
        "CONTENT": content,
        "FOOTER": FOOTER,
        "ROOT": "",
    }.items():
        out = out.replace("{{" + key + "}}", value)
    return out


def main() -> int:
    if OUT.exists():
        shutil.rmtree(OUT)
    OUT.mkdir()

    # theme assets
    shutil.copy(HERE / "theme" / "theme.css", OUT / "theme.css")
    shutil.copy(HERE / "theme" / "theme.js", OUT / "theme.js")

    # pages
    for page in PAGES:
        if page["slug"] == "index":
            content, toc = build_index()
        else:
            src = HERE / page["source"]
            page_html = md_to_html(src.read_text(encoding="utf-8"))
            toc = toc_from_html(page_html)
            content = wrap_sections(page_html)
        (OUT / page["output"]).write_text(render_page(page, content, toc), encoding="utf-8")

    # agent-friendly: ship the markdown sources alongside the rendered pages
    for md in ["README.md", "CONTRIBUTING.md", "MAINTAINERS.md", "AGENTS.md", "CODEOWNERS"]:
        if (ROOT / md).is_file():
            shutil.copy(ROOT / md, OUT / md)
    pages_md = OUT / "pages-md"
    pages_md.mkdir()
    for page in PAGES:
        if page["source"]:
            shutil.copy(HERE / page["source"], pages_md / Path(page["source"]).name)

    built = sorted(p.name for p in OUT.iterdir())
    print(f"built _site/ with {len(built)} entries: {', '.join(built)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
