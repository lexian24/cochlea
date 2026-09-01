import time
import pytest
from cochlea.lexicon import (EXPIRY_SECONDS, MAX_BOOST, HomophoneRejected, Lexicon,
                            detect_variants, extract_phrases, extract_terms,
                            terms_from_correction)


def test_boost_is_capped():
    """F2: magnitude cap is not advisory."""
    assert Lexicon().add("kubectl", boost=1000.0).boost == MAX_BOOST


def test_homophone_entries_are_rejected():
    """F5: boosting a homophone creates errors instead of fixing them."""
    lx = Lexicon()
    with pytest.raises(HomophoneRejected):
        lx.add("their")
    assert "their" not in lx.entries


def test_near_homophone_proper_noun_is_still_admitted():
    """The F5 guard must not swallow the terms the product exists to fix."""
    assert Lexicon().add("Giang").boost > 1.0


def test_negative_signal_decays_an_over_trigger():
    """F2 acceptance: a deliberately-induced over-trigger decays within N."""
    lx = Lexicon()
    lx.add("nginx", boost=MAX_BOOST)
    n = 0
    while "nginx" in lx.entries and n < 10:
        lx.record_rejection("nginx"); n += 1
    assert "nginx" not in lx.entries, "over-trigger never decayed"
    assert n <= 3, f"took {n} rejections to decay; too slow to be useful"


def test_unused_entries_expire():
    lx = Lexicon()
    e = lx.add("transient")
    e.last_used_at = time.time() - EXPIRY_SECONDS - 1
    assert lx.expire() == ["transient"] and lx.boost_for("transient") == 1.0


def test_hits_keep_an_entry_alive():
    lx = Lexicon()
    e = lx.add("kubectl")
    e.last_used_at = time.time() - EXPIRY_SECONDS - 1
    lx.record_hit("kubectl")
    assert lx.expire() == []


def test_term_extraction_finds_project_vocabulary():
    samples = ["bump nginx to 1.25", "fix nginx retry", "kubectl apply", "kubectl get pods"]
    terms = dict(extract_terms(samples, min_count=2))
    assert "nginx" in terms and "kubectl" in terms
    assert terms["nginx"] == 2


def test_orthography_variants_are_detected():
    """F6: the canonicalization prompt."""
    variants = detect_variants(["ok la", "yes la", "fine lah", "sure lah"], min_count=2)
    assert ("la", "lah") in [(a, b) for a, b, _, _ in variants]


def test_canonicalization_rewrites_text():
    lx = Lexicon()
    lx.canonicalize("la", "lah")
    assert lx.apply_canonical("ok la and la") == "ok lah and lah"


# --- regressions found by running the P2 journey against a real repo ---------

def test_common_words_are_not_extracted_as_terms():
    """The lexicon filled with 'are', 'open', 'mode', 'was' before this."""
    samples = ["the mode was open and are ready"] * 3
    assert extract_terms(samples, min_count=2) == []


def test_redaction_placeholders_never_become_terms():
    """Importing a corpus containing PII must not teach the word 'EMAIL'."""
    from cochlea.privacy import redact
    samples = [redact("ping alice@example.com and bob@example.com")] * 3
    assert not [t for t, _ in extract_terms(samples, min_count=2)
                if t in {"EMAIL", "URL", "NUMBER", "POSTAL"}]


def test_technical_identifiers_survive_extraction():
    samples = ["use mlx-tune on large-v3", "mlx-tune with large-v3 again"]
    terms = dict(extract_terms(samples, min_count=2))
    assert "mlx-tune" in terms and "large-v3" in terms


@pytest.mark.parametrize("a,b", [("la", "lah"), ("ok", "okay"), ("colour", "color")])
def test_real_orthography_variants_are_detected(a, b):
    samples = [f"x {a}"] * 2 + [f"y {b}"] * 2
    pairs = {tuple(sorted((x, y))) for x, y, _, _ in detect_variants(samples, min_count=2)}
    assert tuple(sorted((a, b))) in pairs


@pytest.mark.parametrize("a,b", [
    ("now", "no"),        # two common words, not one word spelled twice
    ("open", "opus"),     # unrelated, distance 2, no prefix relation
    ("warm", "was"),      # unrelated
    ("invariant", "invariants"),   # plural, not a spelling variant
])
def test_unrelated_pairs_are_not_reported_as_variants(a, b):
    samples = [f"x {a}"] * 3 + [f"y {b}"] * 3
    pairs = {tuple(sorted((x, y))) for x, y, _, _ in detect_variants(samples, min_count=2)}
    assert tuple(sorted((a, b))) not in pairs


# -- phrases -------------------------------------------------------------------


CHAT = [
    "I opened a pull request against main and the eval gate failed",
    "The eval gate has to pass before promotion, every time",
    "Can you review the pull request when the eval gate is green",
    "We should run kubectl apply and check the nginx logs",
    "kubectl apply is fine but the eval gate still blocks it",
    "Run kubectl apply again after the pull request lands",
]


def test_extract_phrases_finds_what_the_user_repeats():
    found = dict(extract_phrases(CHAT, min_count=2))
    assert found["eval gate"] == 4
    assert found["kubectl apply"] == 3


def test_a_phrase_of_words_the_model_already_knows_is_not_admitted():
    # "pull request" recurs three times in CHAT and is still rejected, because
    # both of its words are ordinary English. Whisper does not get them wrong,
    # so a boost cannot help -- it can only push the phrase over something the
    # user actually said, which is F2 exactly.
    assert "pull request" not in dict(extract_phrases(CHAT, min_count=2))


def test_a_phrase_said_once_is_a_sentence_not_a_habit():
    assert extract_phrases(["the eval gate failed once"], min_count=2) == []


def test_windows_that_fell_in_the_wrong_place_are_not_admitted():
    # "the eval gate" and "eval gate has" are artefacts of where the window
    # landed. Admitting all three spends three entries to say one thing, and
    # F2 punishes a large lexicon of weak entries much harder than a small one
    # of strong entries.
    found = dict(extract_phrases(CHAT, min_count=2))
    assert "the eval gate" not in found
    assert "eval gate has" not in found
    assert "eval gate is" not in found


def test_phrases_of_entirely_ordinary_words_are_rejected():
    # These recur in anyone's writing. Boosting them biases the decoder
    # towards nothing in particular at the cost of every word they compete
    # with.
    texts = ["we have to go there", "we have to be here", "we have to know"]
    assert extract_phrases(texts, min_count=2) == []


def test_a_phrase_is_never_assembled_across_punctuation():
    # "logs. Deploy the" is not something anyone says, and a phrase that spans
    # a sentence boundary can never be matched at decode time either.
    texts = ["check the nginx logs. Deploy kubectl now"] * 3
    found = dict(extract_phrases(texts, min_count=2))
    assert not any("logs" in p and "Deploy" in p for p in found)


def test_redactions_never_become_phrases():
    # PLACEHOLDERS mark text the privacy pass removed. Reconstructing them
    # into a lexicon entry would put them back.
    from cochlea.privacy import PLACEHOLDERS

    placeholder = sorted(PLACEHOLDERS)[0]
    texts = [f"send it to {placeholder} tomorrow please"] * 4
    assert not any(placeholder in p for p, _ in extract_phrases(texts, min_count=2))


def test_a_longer_phrase_its_parts_already_account_for_is_dropped():
    # Every occurrence of "check the nginx logs" is an occurrence of "nginx
    # logs", so the longer one carries no evidence the shorter does not -- it
    # costs an entry, and a share of the damage F2 bounds, to say the same
    # thing.
    texts = ["check the nginx logs today"] * 3
    found = dict(extract_phrases(texts, min_count=2))
    assert "nginx logs" in found
    assert "check the nginx logs" not in found
    assert "nginx logs today" not in found


def test_a_longer_phrase_that_is_genuinely_rarer_survives():
    # Subsumption must not swallow a real compound. Occurring less often than
    # its parts is exactly what makes a longer phrase worth its own entry.
    texts = ["run kubectl apply now"] * 4 + ["run kubectl apply manifest"] * 2
    found = dict(extract_phrases(texts, min_count=2))
    assert found["kubectl apply"] == 6
    assert found["kubectl apply now"] == 4


def test_single_character_words_are_not_part_of_a_phrase():
    # `_WORD` requires a leading letter, so the flag in "kubectl apply -f"
    # arrives as a bare "f" and produced "apply f" and "f now" as candidates.
    texts = ["run kubectl apply -f now"] * 3
    found = dict(extract_phrases(texts, min_count=2))
    assert not any(len(w) < 2 for p in found for w in p.split())


def test_max_words_bounds_the_phrase_length():
    texts = ["kubectl apply the nginx deployment manifest today"] * 3
    assert all(len(p.split()) <= 3
               for p, _ in extract_phrases(texts, min_count=2, max_words=3))


def test_a_phrase_can_be_admitted_to_the_lexicon_and_boosted():
    # The end the extraction exists for: a phrase is a lexicon entry like any
    # other, and biasing treats a single word as the one-element case.
    lexicon = Lexicon()
    for phrase, _ in extract_phrases(CHAT, min_count=3):
        lexicon.add(phrase)
    assert "eval gate" in lexicon.entries


# -- persistence ---------------------------------------------------------------


def test_a_lexicon_round_trips(tmp_path):
    lexicon = Lexicon()
    lexicon.add("kubectl")
    lexicon.add("eval gate")
    lexicon.record_hit("kubectl")
    lexicon.canonicalize("kube-ctl", "kubectl")
    path = lexicon.save(tmp_path / "lexicon.json")

    back = Lexicon.load(path)
    assert sorted(back.entries) == ["eval gate", "kubectl"]
    assert back.entries["kubectl"].hits == 1
    assert back.entries["kubectl"].boost == lexicon.entries["kubectl"].boost
    assert back.apply_canonical("run kube-ctl now") == "run kubectl now"


def test_the_file_is_readable_only_by_its_owner(tmp_path):
    # These are terms lifted out of the user's private messages.
    import os
    import stat

    path = Lexicon().save(tmp_path / "lexicon.json")
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600


def test_a_missing_lexicon_is_an_empty_one_not_an_error(tmp_path):
    # The normal state before the first import. Biasing improves ASR; it is
    # never a prerequisite for it.
    assert Lexicon.load(tmp_path / "nothing.json").entries == {}


def test_a_corrupt_lexicon_does_not_stop_dictation(tmp_path):
    path = tmp_path / "lexicon.json"
    path.write_text("{ this is not json")
    assert Lexicon.load(path).entries == {}


def test_loading_does_not_re_run_the_admission_check(tmp_path):
    # F5 admission is a decision already taken. Re-taking it on load would
    # silently drop entries if the homophone table ever grew, and the user
    # would have no way to tell that from the file not having been written.
    from cochlea.lexicon import Entry

    lexicon = Lexicon()
    lexicon.entries["knew"] = Entry(term="knew", boost=1.5)
    path = lexicon.save(tmp_path / "lexicon.json")
    assert "knew" in Lexicon.load(path).entries


def test_a_saved_boost_is_still_capped_on_load(tmp_path):
    # F2's cap is not advisory, and a hand-edited file is exactly where an
    # uncapped number would come from.
    path = tmp_path / "lexicon.json"
    path.write_text('{"entries": [{"term": "kubectl", "boost": 1000}]}')
    assert Lexicon.load(path).entries["kubectl"].boost == MAX_BOOST


def test_a_partial_write_never_replaces_a_good_lexicon(tmp_path):
    # Written to a temporary file and renamed. A lexicon truncated by a crash
    # mid-write loads without error and biases towards a fragment.
    lexicon = Lexicon()
    lexicon.add("kubectl")
    path = lexicon.save(tmp_path / "lexicon.json")
    assert not list(tmp_path.glob("*.tmp"))
    assert Lexicon.load(path).entries


# -- learning from a correction ------------------------------------------------


def test_a_correction_yields_the_term_the_recogniser_missed():
    # The M1 -> M2 link. Without it a correction lands in the store, waits for
    # a trainer that does not exist, and the next utterance mishears the same
    # word again.
    assert terms_from_correction(
        "check the ginks logs", "check the nginx logs") == ["nginx"]
    assert terms_from_correction(
        "deploy with qbeckle", "deploy with kubectl") == ["kubectl"]


def test_only_the_replacement_is_a_candidate():
    # The word that was wrong is not the word to boost.
    assert "ginks" not in terms_from_correction(
        "check the ginks logs", "check the nginx logs")


def test_an_ordinary_word_the_model_already_knows_is_not_learned():
    # "fell" heard for "failed" is an acoustic confusion between two words
    # Whisper knows perfectly well. A lexicon entry cannot fix that and could
    # make it worse -- F2 through the correction path instead of the import
    # one.
    assert terms_from_correction(
        "the deployment fell at midnight",
        "the deployment failed at midnight") == []


def test_a_homophone_is_never_learned_from_a_correction():
    # F5 at the other door. Biasing cannot separate "there" from "their", so
    # boosting one actively creates errors.
    assert terms_from_correction(
        "put it over there", "put it over their") == []


def test_an_identifier_is_learned_even_if_it_looks_ordinary():
    assert terms_from_correction(
        "run em l x tune", "run mlx-tune") == ["mlx-tune"]


def test_nothing_is_learned_when_nothing_changed():
    assert terms_from_correction("same text", "same text") == []


def test_the_number_of_terms_is_bounded():
    # A correction that rewrote half a sentence is a revision by another name,
    # and admitting every word of it is how a lexicon fills with noise (F25).
    learned = terms_from_correction(
        "aaa bbb ccc ddd eee",
        "kubectl nginx mlx-tune metaphone pinyin",
        max_terms=3)
    assert len(learned) == 3


def test_learned_terms_can_be_admitted_to_a_lexicon():
    lexicon = Lexicon()
    for term in terms_from_correction("check the ginks logs",
                                      "check the nginx logs"):
        lexicon.add(term)
    assert "nginx" in lexicon.entries
