"""Tests for the quotation check.

The case that prompted all of this is first, in the model's own words, against
the statute's own words. Everything after it exists so the check stays useful:
a checker that cries wolf about ordinary quoting gets ignored, and one that
misses a fabricated passage is worse than none.

    python3 -m pytest examples/python/test_quotecheck.py
"""

from __future__ import annotations

import quotecheck

# WIC 4512, verbatim from the corpus.
STATUTE = (
    'if the child has a disability that is not solely physical in nature and has '
    'significant functional limitations in at least two of the following areas of '
    'major life activity, as determined by a regional center and as appropriate to '
    'the age of the child: (i) Self-care. (ii) Receptive and expressive language. '
    '(iii) Learning. (iv) Mobility. (v) Self-direction. (B) To be provisionally '
    'eligible, a child is not required to have one of the developmental '
    'disabilities listed in paragraph (1).'
)


class TestTheAnswersThatPromptedThis:
    def test_catches_the_fabricated_list(self):
        # What the 30B actually returned, quotation marks and all. The statute
        # says "Receptive and expressive language".
        answer = 'WIC 4512 states: "(i) Self-care. (ii) Language and speech. (iii) Learning."'
        bad = [v for v in quotecheck.check(answer, [STATUTE]) if not v.ok]
        assert len(bad) == 1

    def test_catches_the_other_fabrication_too(self):
        # A second run of the same question produced a different invention. Two
        # plausible paraphrases, neither the law, both in quotation marks.
        answer = 'The statute lists "(i) Self-care. (ii) Language and communication. (iii) Learning."'
        assert any(not v.ok for v in quotecheck.check(answer, [STATUTE]))

    def test_names_the_word_that_departs(self):
        # "Not found" sends somebody to read a whole section. Naming where it
        # stops matching puts them on the word the answer turns on.
        answer = '"(i) Self-care. (ii) Language and speech. (iii) Learning."'
        bad = [v for v in quotecheck.check(answer, [STATUTE]) if not v.ok][0]
        assert 'Self-care' in bad.matched
        assert 'Language and speech' in bad.diverged

    def test_accepts_the_statute_quoted_properly(self):
        answer = 'It requires "significant functional limitations in at least two of the following areas".'
        assert all(v.ok for v in quotecheck.check(answer, [STATUTE]))


class TestItDoesNotCryWolf:
    def test_paraphrase_without_quotes_is_not_checked(self):
        # Paraphrasing is fine and is most of a good answer. Only text presented
        # as copied is the checker's business.
        answer = 'A child may qualify with limitations in at least two areas of major life activity.'
        assert quotecheck.check(answer, [STATUTE]) == []

    def test_ignores_terms_of_art(self):
        # "eligible", "substantial disability" - this is how anybody writes about
        # a statute, and flagging it would bury the passages that matter.
        answer = 'The test is whether the child is "provisionally eligible" under the Act.'
        assert quotecheck.check(answer, [STATUTE]) == []

    def test_allows_elision(self):
        # Cutting the middle of a passage is ordinary quoting. Refusing it would
        # train whoever reads this to skip the warnings.
        answer = '"significant functional limitations in at least two ... (iii) Learning. (iv) Mobility."'
        assert all(v.ok for v in quotecheck.check(answer, [STATUTE]))

    def test_survives_curly_quotes_and_reflowed_whitespace(self):
        answer = ('“significant functional limitations in at least\ntwo of the '
                  'following   areas”')
        assert all(v.ok for v in quotecheck.check(answer, [STATUTE]))

    def test_checks_across_every_section_supplied(self):
        # Retrieval hands over several sections and an answer may quote any of
        # them, so the haystack is all of them.
        other = 'This division shall be known and may be cited as the Lanterman Developmental Disabilities Services Act.'
        answer = '"may be cited as the Lanterman Developmental Disabilities Services Act"'
        assert all(v.ok for v in quotecheck.check(answer, [STATUTE, other]))


class TestTheReport:
    def test_says_nothing_when_nothing_was_quoted(self):
        # A line reading "0 of 0 checked" under every paraphrased answer is a
        # line people learn to skip, and the value here is being read on the day
        # it says something.
        assert quotecheck.report([]) == ''

    def test_confirms_when_the_quotes_hold(self):
        answer = 'It requires "significant functional limitations in at least two of the following areas".'
        out = quotecheck.report(quotecheck.check(answer, [STATUTE]))
        assert 'appear in the statute' in out

    def test_is_unmissable_when_they_do_not(self):
        answer = '"(i) Self-care. (ii) Language and speech. (iii) Learning."'
        out = quotecheck.report(quotecheck.check(answer, [STATUTE]))
        assert 'NOT in the statute' in out
        assert 'Read the cited sections directly' in out


class TestCapitalisationAndDefinedTerms:
    def test_case_change_is_a_change(self):
        # Capitalisation carries meaning in a statute's defined terms, so a model
        # that altered it altered something worth seeing.
        answer = '"Significant Functional Limitations in at least two of the following areas"'
        assert any(not v.ok for v in quotecheck.check(answer, [STATUTE]))
