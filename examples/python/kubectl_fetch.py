#!/usr/bin/env python3
"""Build a corpus from kubectl's own help and the Kubernetes reference docs.

    python3 kubectl_fetch.py                  # local help + kubernetes.io
    python3 kubectl_fetch.py --local-only     # no network at all
    python3 kubectl_fetch.py --refresh        # ignore the cache

Two sources, kept as separate entries on purpose.

**`kubectl <cmd> --help`, from the binary on this machine.** Authoritative for
the version actually installed, which is the version whose flags will work. Docs
on the web describe some release; the binary describes yours, and the gap
between them is exactly where an afternoon goes.

**kubernetes.io/docs/reference/kubectl/generated/**, the published reference for
the same command. Carries prose and examples that the terminal help trims, and
gives an answer somewhere to point that is not this laptop.

Both cite the same command, and every entry keeps the URL of the published page
so an answer can be checked rather than believed. Which source a chunk came from
is on the chunk, because "the flag is called --foo" is a different claim
depending on whether it came from your binary or from a docs page describing a
different release.

The command tree comes from kubectl itself rather than a hardcoded list: this
walks `Available Commands` recursively, so a plugin or a new subcommand in a
later release is picked up without editing anything here.

Everything is cached under corpus/raw/kubectl/. Re-running costs nothing and
fetches nothing.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
CORPUS = os.path.join(HERE, "corpus")
RAW = os.path.join(CORPUS, "raw", "kubectl")
OUT = os.path.join(CORPUS, "kubectl.jsonl")

DOCS_ROOT = "https://kubernetes.io/docs/reference/kubectl/generated"
USER_AGENT = "dAI-example-crawler/0.1 (local RAG demo; contact your operator)"

# Pages that are not per-command but are what people actually reach for.
EXTRA_PAGES = [
    ("kubectl overview", "https://kubernetes.io/docs/reference/kubectl/",
     "Command line tool overview"),
    ("kubectl quick reference", "https://kubernetes.io/docs/reference/kubectl/quick-reference/",
     "Quick reference (cheat sheet)"),
    ("kubectl conventions", "https://kubernetes.io/docs/reference/kubectl/conventions/",
     "Conventions for scripting"),
]


def cached(url: str, refresh: bool, pause: float = 1.0) -> str | None:
    """Fetch one URL through a cache, politely.

    The pause is between real fetches only, so a cached run does not sleep.
    Returns None rather than raising for a page that is not there: the command
    tree comes from the local binary, and a command whose published page has
    moved or does not exist yet is a gap in the docs rather than a reason to
    abandon the corpus.
    """
    os.makedirs(RAW, exist_ok=True)
    key = os.path.join(RAW, hashlib.sha256(url.encode()).hexdigest()[:16] + ".html")
    if not refresh and os.path.exists(key):
        return open(key, encoding="utf-8").read()

    for attempt in range(3):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(request, timeout=60) as response:
                body = response.read().decode("utf-8", errors="replace")
            open(key, "w", encoding="utf-8").write(body)
            time.sleep(pause)
            return body
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            time.sleep(2 * (attempt + 1))
        except Exception:
            time.sleep(2 * (attempt + 1))
    return None


def strip_tags(fragment: str) -> str:
    fragment = re.sub(r"(?is)<(script|style|nav|header|footer)[^>]*>.*?</\1>", " ", fragment)
    fragment = re.sub(r"<br\s*/?>", "\n", fragment, flags=re.I)
    fragment = re.sub(r"(?i)</(p|div|li|tr|h[1-6]|pre)>", "\n", fragment)
    fragment = re.sub(r"<[^>]+>", " ", fragment)
    text = html.unescape(fragment)
    text = re.sub(r"[ \t]+", " ", text)
    return re.sub(r"\n\s*\n+", "\n\n", text).strip()


def main_content(page: str) -> str:
    """The article, without the site furniture.

    A docs page is mostly navigation, and indexing the nav means every command
    retrieves every other command's name. Falls back to the whole page rather
    than to nothing, because a changed template should degrade the corpus, not
    empty it.
    """
    for pattern in (r"(?is)<main[^>]*>(.*?)</main>",
                    r"(?is)<article[^>]*>(.*?)</article>",
                    r'(?is)<div[^>]*class="[^"]*td-content[^"]*"[^>]*>(.*?)</div>\s*</div>'):
        found = re.search(pattern, page)
        if found and len(found.group(1)) > 500:
            return strip_tags(found.group(1))
    return strip_tags(page)


def kubectl_help(path: list[str]) -> str:
    """`kubectl <path> --help`, or empty if the command refuses to explain itself."""
    try:
        done = subprocess.run(["kubectl", *path, "--help"],
                              capture_output=True, text=True, timeout=30)
        return (done.stdout or "").strip()
    except Exception:
        return ""


def children(help_text: str) -> list[str]:
    """Subcommands a command advertises.

    Two shapes, because kubectl uses two. A subcommand lists its children under
    `Available Commands:`; the root instead groups them under headings like
    `Basic Commands (Beginner):` and `Cluster Management Commands:`. Reading only
    the first found nothing at the root, which is where every command is.

    Names are taken from lines indented under a heading and stopping at the
    blank line that ends the block - `Options:` below is full of things that
    look like names and are not commands.
    """
    found, inside = [], False
    for line in help_text.splitlines():
        if re.match(r"^[A-Z][^:]*Commands[^:]*:\s*$", line) or \
           re.match(r"^Available Commands:\s*$", line):
            inside = True
            continue
        if inside:
            if not line.strip():
                inside = False
                continue
            name = re.match(r"\s{2,}([a-z][a-z0-9-]*)\s{2,}\S", line)
            if name:
                found.append(name.group(1))
            elif re.match(r"^\S", line):
                inside = False
    return found


def groups(root_help: str) -> dict[str, str]:
    """Which heading each top-level command sits under.

    "Troubleshooting and Debugging Commands" is the only place the word
    "debugging" appears for `logs`, and a question about debugging has to be
    able to match it. Without the heading the label exists nowhere in the text.
    """
    where, heading = {}, ""
    for line in root_help.splitlines():
        title = re.match(r"^([A-Z][^:]*Commands[^:]*):\s*$", line)
        if title:
            heading = title.group(1)
            continue
        name = re.match(r"\s{2,}([a-z][a-z0-9-]*)\s{2,}\S", line)
        if name and heading:
            where[name.group(1)] = heading
    return where


def docs_url(path: list[str]) -> str:
    """The published page for a command path.

    kubectl_get/ for a top-level command; kubectl_config/kubectl_config_view/
    for a subcommand - the nesting repeats the parent, which is the pattern the
    generated docs use.
    """
    parts, url = [], DOCS_ROOT
    for name in path:
        parts.append(name)
        url += "/kubectl_" + "_".join(parts)
    return url + "/"


def walk(path: list[str], where: dict[str, str], seen: set[str],
         depth: int = 0) -> list[list[str]]:
    """Every command path kubectl admits to, depth first."""
    key = " ".join(path)
    if key in seen or depth > 2:
        return []
    seen.add(key)
    found = [path]
    for child in children(kubectl_help(path)):
        found += walk(path + [child], where, seen, depth + 1)
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--local-only", action="store_true",
                        help="kubectl's own help and nothing from the network")
    parser.add_argument("--refresh", action="store_true", help="ignore the cache")
    parser.add_argument("--out", default=OUT)
    args = parser.parse_args()

    if subprocess.run(["which", "kubectl"], capture_output=True).returncode != 0:
        print("kubectl is not on this machine, and it is the authority for the\n"
              "version whose flags will actually work. Install it, or fetch the\n"
              "published reference alone with a different script.", file=sys.stderr)
        return 1

    version = subprocess.run(["kubectl", "version", "--client"],
                             capture_output=True, text=True).stdout.strip()
    release = re.search(r"Client Version:\s*(\S+)", version)
    release = release.group(1) if release else "unknown"
    print(f"kubectl   {release}")

    root = kubectl_help([])
    where = groups(root)
    paths = walk([], where, set())[1:]          # drop the bare root, kept below
    print(f"commands  {len(paths)} from the local binary")

    records: list[dict] = []

    # The root help: what the tool is, and the list of what it can do.
    records.append({
        "citation": "kubectl", "section": "kubectl",
        "chapter_name": f"command overview (help, {release})",
        "url": "https://kubernetes.io/docs/reference/kubectl/",
        "text": root,
    })

    fetched = 0
    for path in paths:
        name = " ".join(["kubectl"] + path)
        group = where.get(path[0], "Commands")
        url = docs_url(path)

        local = kubectl_help(path)
        if local:
            records.append({
                "citation": name, "section": " ".join(path),
                # Which source, on the chunk. "The flag is --foo" means
                # different things from your binary and from a docs page
                # describing another release.
                "chapter_name": f"{group} (help, {release})",
                "url": url, "text": local,
            })

        if args.local_only:
            continue
        page = cached(url, args.refresh)
        if page:
            body = main_content(page)
            if len(body) > 400:
                fetched += 1
                records.append({
                    "citation": name, "section": " ".join(path),
                    "chapter_name": f"{group} (kubernetes.io reference)",
                    "url": url, "text": body,
                })

    if not args.local_only:
        for title, url, label in EXTRA_PAGES:
            page = cached(url, args.refresh)
            if not page:
                continue
            body = main_content(page)
            if len(body) > 400:
                fetched += 1
                records.append({
                    "citation": title, "section": title,
                    "chapter_name": f"{label} (kubernetes.io)",
                    "url": url, "text": body,
                })
        print(f"docs      {fetched} pages from kubernetes.io")

    os.makedirs(CORPUS, exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        for record in records:
            f.write(json.dumps(record) + "\n")

    chars = sum(len(r["text"]) for r in records)
    print(f"corpus    {len(records)} entries, {chars // 1000}k chars -> {args.out}")
    print()
    print("Next:")
    print(f"  python3 rag_index.py --corpus {args.out} \\")
    print("                       --index corpus/kubectl.db")
    return 0


if __name__ == "__main__":
    sys.exit(main())
