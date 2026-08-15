"""Check that every quotation in an answer appears in the sources it cites.

Written because the model got this wrong on a statute, twice, in the way that is
hardest to notice. Asked who is eligible for regional center services, it wrote
this inside quotation marks and attributed it to WIC 4512:

    "(i) Self-care. (ii) Language and speech."

The statute says "Receptive and expressive language". A second run produced
"Language and communication". Both are reasonable paraphrases and neither is the
law, and both were punctuated as though they were.

Retrieval was not at fault - the correct section was supplied both times. The
model paraphrased while wearing quotation marks, which is the failure mode that
matters most for a reading aid: a wrong citation invites checking, and a
confident quotation does the opposite.

So this checks the one thing a program can check. Not whether the answer is
right - that needs a lawyer - but whether the text presented as copied was
copied. It is a spell-checker for honesty, not a proofreader for law.
"""

from __future__ import annotations

import re
import unicodedata

# Quotation marks a model might use, all meaning the same thing to a reader.
OPENERS = '"“‘«'
CLOSERS = '"”’»'

# Below this, a "quote" is a term of art rather than a passage - "eligible",
# "substantial disability". Those are how anybody writes about a statute and
# flagging them would bury the passages that matter in noise.
MIN_QUOTE_CHARS = 25


def normalise(text: str) -> str:
    """Reduce text to what a reader would call the same words.

    Whitespace, quote style and dash style all differ between a statute as
    published and a model's rendering of it without either being a
    misquotation. Case is deliberately kept: the statute's own capitalisation
    carries meaning in defined terms, and a model that changed it changed
    something.
    """
    text = unicodedata.normalize('NFKC', text)
    for ch in '“”‘’«»':
        text = text.replace(ch, '"' if ch in OPENERS + CLOSERS else "'")
    text = text.replace('—', '-').replace('–', '-')
    # An ellipsis marks elision by the quoter, which is legitimate. Splitting on
    # it lets each surviving fragment be checked on its own.
    text = text.replace('…', '...')
    return re.sub(r'\s+', ' ', text).strip()


def quotes_in(answer: str) -> list[str]:
    """Every passage the answer presents as copied.

    Deliberately generous about what counts as a quotation mark and strict about
    length, because the cost of missing a fabricated passage is far higher than
    the cost of checking a real one twice.
    """
    found: list[str] = []
    pattern = re.compile(f'[{re.escape(OPENERS)}]([^{re.escape(OPENERS + CLOSERS)}]+)'
                         f'[{re.escape(CLOSERS)}]')
    for match in pattern.finditer(answer):
        span = match.group(1).strip()
        if len(span) >= MIN_QUOTE_CHARS:
            found.append(span)
    return found


def divergence(quote: str, haystack: str) -> tuple[str, str]:
    """Where a quotation stops matching: what held, and the first word that did not.

    A verdict of "not found" sends somebody to read the whole section. Naming the
    point of departure puts them on the word, which is usually one word and
    usually the one the answer turns on.
    """
    words = quote.split(' ')
    good = 0
    for i in range(1, len(words) + 1):
        if ' '.join(words[:i]) in haystack:
            good = i
        else:
            break
    matched = ' '.join(words[:good])
    rest = ' '.join(words[good:])
    return matched, rest


class Verdict:
    def __init__(self, quote: str, ok: bool, matched: str = '', diverged: str = ''):
        self.quote = quote
        self.ok = ok
        self.matched = matched
        self.diverged = diverged


def check(answer: str, sources: list[str]) -> list[Verdict]:
    """Every quotation in the answer, against the text that was supplied.

    Fragments split on an ellipsis are checked separately, because eliding the
    middle of a passage is ordinary quoting and refusing it would train whoever
    reads this to ignore the warnings.
    """
    haystack = ' '.join(normalise(s) for s in sources)
    out: list[Verdict] = []
    for raw in quotes_in(answer):
        for fragment in normalise(raw).split('...'):
            fragment = fragment.strip()
            if len(fragment) < MIN_QUOTE_CHARS:
                continue
            if fragment in haystack:
                out.append(Verdict(fragment, True))
            else:
                matched, diverged = divergence(fragment, haystack)
                out.append(Verdict(fragment, False, matched, diverged))
    return out


def report(verdicts: list[Verdict]) -> str:
    """What to print under the answer.

    Silent when there is nothing quoted, because a report saying "0 of 0 checked"
    on every paraphrased answer is a line people learn to skip - and the whole
    value here is being read on the day it says something.
    """
    if not verdicts:
        return ''
    bad = [v for v in verdicts if not v.ok]
    lines = ['--- quotations checked against the sections supplied ---']
    if not bad:
        lines.append(f'  all {len(verdicts)} quoted passages appear in the statute')
        return '\n'.join(lines)

    lines.append(f'  {len(bad)} of {len(verdicts)} quoted passages are NOT in the statute.')
    lines.append('  The answer presents these as copied text. They are not.')
    for v in bad:
        lines.append('')
        if v.matched:
            lines.append(f'    matches to:  "{v.matched}"')
            lines.append(f'    then claims: "{v.diverged}"')
        else:
            lines.append(f'    not found:   "{v.quote[:90]}"')
    lines.append('')
    lines.append('  Read the cited sections directly before relying on any of it.')
    return '\n'.join(lines)
