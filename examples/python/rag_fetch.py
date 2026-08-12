#!/usr/bin/env python3
"""Fetch the Lanterman Act and related laws, as a corpus to retrieve over.

Starts at the page the Department of Developmental Services publishes:

    https://www.dds.ca.gov/transparency/laws-regulations/lanterman-act-and-related-laws/

That page is a portal, not the law. It names the three divisions of the Welfare
and Institutions Code that make up the Lanterman Act and its neighbours, and
points at the Legislature's own site for the text. So this follows those links
rather than scraping the portal, which means the corpus is the statute as
published by the body that enacted it.

Chapters are fetched whole rather than section by section. The Legislature
serves a chapter's full text at one URL, so a corpus of some hundreds of
sections costs some tens of requests instead of hundreds. That is the polite
way round and it is also the fast one.

Everything is cached under corpus/raw/. Re-running costs nothing and fetches
nothing, which matters because the next two scripts are the ones worth
iterating on.

    python3 rag_fetch.py                 # the default three divisions
    python3 rag_fetch.py --divisions 4.5 # just the Lanterman Act itself
    python3 rag_fetch.py --refresh       # ignore the cache

California statutes are public records and are reproduced here for a local
index; the source URL is kept on every section so an answer can point back at
the authority rather than ask to be believed.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

PORTAL = ("https://www.dds.ca.gov/transparency/laws-regulations/"
          "lanterman-act-and-related-laws/")
LEGINFO = "https://leginfo.legislature.ca.gov/faces"
USER_AGENT = "dAI-example-crawler/0.1 (local RAG demo; contact your operator)"

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "corpus")
RAW = os.path.join(CORPUS, "raw")

# What the portal points at. Kept as a fallback rather than the source of truth:
# the portal is read first, and this is used only if its markup changes.
KNOWN_DIVISIONS = {
    "4.1": "Early intervention services",
    "4.5": "Lanterman Developmental Disabilities Services Act",
    "4.7": "Area boards on developmental disabilities",
}


def fetch(url: str, refresh: bool = False, pause: float = 1.0) -> str:
    """Fetch one URL, through a cache, politely.

    The pause is between real fetches only. A cached run does not sleep, so
    rebuilding the corpus after a parser change is immediate.
    """
    os.makedirs(RAW, exist_ok=True)
    key = hashlib.sha256(url.encode()).hexdigest()[:16]
    path = os.path.join(RAW, f"{key}.html")
    if os.path.exists(path) and not refresh:
        with open(path, encoding="utf-8") as handle:
            return handle.read()

    request = urllib.request.Request(url, headers={
        "user-agent": USER_AGENT,
        "accept": "text/html,application/xhtml+xml",
    })
    last: Exception | None = None
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                body = response.read().decode("utf-8", errors="replace")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(body)
            time.sleep(pause)
            return body
        except (urllib.error.URLError, TimeoutError) as error:
            last = error
            time.sleep(2 * (attempt + 1))
    raise RuntimeError(f"could not fetch {url}: {last}")


def divisions_from_portal(refresh: bool) -> dict[str, str]:
    """Which divisions the department itself points at."""
    try:
        page = fetch(PORTAL, refresh)
    except RuntimeError as error:
        print(f"  portal unreachable ({error}); using the known divisions")
        return dict(KNOWN_DIVISIONS)

    found = {}
    for match in re.finditer(r"codes_displayexpandedbranch\.xhtml\?tocCode=WIC&(?:amp;)?division=([0-9.]+)", page):
        number = match.group(1).rstrip(".")
        found[number] = KNOWN_DIVISIONS.get(number, f"Welfare and Institutions Code division {number}")
    if not found:
        print("  portal markup changed; using the known divisions")
        return dict(KNOWN_DIVISIONS)
    return found


def chapters_of(division: str, refresh: bool) -> list[dict]:
    """Every chapter and article of a division, from its table of contents."""
    url = (f"{LEGINFO}/codes_displayexpandedbranch.xhtml?tocCode=WIC"
           f"&division={division}.&title=&part=&chapter=&article=")
    page = fetch(url, refresh)

    seen, chapters = set(), []
    pattern = (r"codes_displayText\.xhtml\?lawCode=WIC&(?:amp;)?division=([^&\"']*)"
               r"&(?:amp;)?title=([^&\"']*)&(?:amp;)?part=([^&\"']*)"
               r"&(?:amp;)?chapter=([^&\"']*)&(?:amp;)?article=([^&\"']*)")
    for div, title, part, chapter, article in re.findall(pattern, page):
        key = (div, title, part, chapter, article)
        if key in seen:
            continue
        seen.add(key)
        chapters.append({"division": div, "title": title, "part": part,
                         "chapter": chapter, "article": article})
    return chapters


def strip_tags(fragment: str) -> str:
    fragment = re.sub(r"<br\s*/?>", "\n", fragment, flags=re.I)
    fragment = re.sub(r"<[^>]+>", " ", fragment)
    text = html.unescape(fragment).replace("\xa0", " ")
    text = re.sub(r"[ \t]+", " ", text)
    return re.sub(r"\n\s*\n+", "\n", text).strip()


def headings_in(page: str) -> dict:
    """The division, chapter and article a page of sections sits under.

    Worth the extra parsing because these titles are the only topical labels the
    corpus has. Section text says what the rule is; only the heading says that
    Chapter 1.3 is the Bill of Rights. A question asking about rights matches
    that phrase and nothing in the sections themselves, so a chunk without its
    heading is invisible to exactly the question it should answer.
    """
    found = {}
    for kind, text in re.findall(
            r">\s*((?:DIVISION|PART|CHAPTER|ARTICLE))\s+([^<]{2,120})<", page):
        title = html.unescape(text).replace("\xa0", " ").strip()
        # Trim the section range the site appends, eg "[4500 - 4894]".
        title = re.sub(r"\s*\[[0-9.\s\-]+\]\s*$", "", title).strip()
        # Leading number, then the name: "1.3. Persons With ... Bill of Rights".
        number, _, name = title.partition(" ")
        found[kind.lower()] = {"number": number.rstrip("."), "name": name.strip()}
    return found


def sections_in(page: str) -> list[dict]:
    """Pull the sections out of a chapter page.

    Split on the section headings rather than parsed as a tree. The markup here
    nests a <p> inside a <p> and leaves tags unclosed, so a strict parser makes
    a worse job of it than a split on the one landmark that is reliable.
    """
    start = page.find('id="manylawsections"')
    if start < 0:
        return []
    end = page.find("</BODY>", start)
    segment = page[start:end if end > 0 else len(page)]

    out = []
    pieces = re.split(r"<h6[^>]*>", segment)[1:]
    for piece in pieces:
        heading, _, rest = piece.partition("</h6>")
        number = strip_tags(heading).strip().rstrip(".")
        if not number:
            continue

        # The italic tail is the enactment history: which bill added or amended
        # the section. Kept out of the retrievable text - it is citation, not
        # substance, and it matches every query about dates for the wrong reason.
        history = ""
        notes = list(re.finditer(r"<i>(.*?)</i>", rest, re.S))
        if notes:
            last = notes[-1]
            candidate = strip_tags(last.group(1))
            # Only if it reads like an enactment note. Statutes italicise other
            # things, and swallowing a defined term because it was the last
            # italic on the page would quietly remove it from the index.
            if re.match(r"^\(\s*(Added|Amended|Repealed|Renumbered|Enacted|Note)", candidate):
                history = candidate
                rest = rest[:last.start()]

        body = strip_tags(rest)
        if body:
            out.append({"section": number, "text": body, "history": history})
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--divisions", nargs="*", default=None,
                        help="WIC divisions to fetch (default: whatever the portal names)")
    parser.add_argument("--refresh", action="store_true", help="ignore the cache")
    parser.add_argument("--pause", type=float, default=1.0,
                        help="seconds between real fetches (default 1.0)")
    args = parser.parse_args()

    os.makedirs(CORPUS, exist_ok=True)

    print(f"portal    {PORTAL}")
    divisions = ({d: KNOWN_DIVISIONS.get(d, f"division {d}") for d in args.divisions}
                 if args.divisions else divisions_from_portal(args.refresh))
    print(f"divisions {', '.join(sorted(divisions))}\n")

    out_path = os.path.join(CORPUS, "sections.jsonl")
    total, skipped = 0, 0
    with open(out_path, "w", encoding="utf-8") as out:
        for division in sorted(divisions):
            name = divisions[division]
            try:
                chapters = chapters_of(division, args.refresh)
            except RuntimeError as error:
                print(f"division {division}: {error}")
                continue
            print(f"division {division} - {name}: {len(chapters)} chapter(s)")

            for chapter in chapters:
                url = (f"{LEGINFO}/codes_displayText.xhtml?lawCode=WIC"
                       f"&division={chapter['division']}&title={chapter['title']}"
                       f"&part={chapter['part']}&chapter={chapter['chapter']}"
                       f"&article={chapter['article']}")
                try:
                    page = fetch(url, args.refresh, args.pause)
                except RuntimeError as error:
                    print(f"    {error}")
                    skipped += 1
                    continue

                sections = sections_in(page)
                headings = headings_in(page)
                label = f"ch {chapter['chapter'] or '-'}"
                if chapter["article"]:
                    label += f" art {chapter['article']}"
                print(f"  {label:<18} {len(sections):>4} section(s)")

                for section in sections:
                    # A link to the section itself, which is what a citation
                    # should point at: stable, and the authority's own copy.
                    citation = (f"{LEGINFO}/codes_displaySection.xhtml"
                                f"?lawCode=WIC&sectionNum={urllib.parse.quote(section['section'])}")
                    out.write(json.dumps({
                        "code": "WIC",
                        "division": chapter["division"].rstrip("."),
                        "division_name": name,
                        "chapter": chapter["chapter"].rstrip("."),
                        "chapter_name": headings.get("chapter", {}).get("name", ""),
                        "article": chapter["article"].rstrip("."),
                        "article_name": headings.get("article", {}).get("name", ""),
                        "section": section["section"],
                        "citation": f"WIC § {section['section']}",
                        "history": section["history"],
                        "url": citation,
                        "chapter_url": url,
                        "text": section["text"],
                    }) + "\n")
                    total += 1

    print(f"\n{total} sections -> {out_path}")
    if skipped:
        print(f"{skipped} chapter(s) could not be fetched")
    if total == 0:
        print("Nothing was written. Run with --refresh, or check network access.")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
