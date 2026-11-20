from processor.codes import ALPHABET, CHECK_ALPHABET, code_valid, parse_payload


def make_code(body: str) -> str:
    """The 1A algorithm: 8 base-32 characters plus a mod-37 check character."""
    value = 0
    for ch in body:
        value = value * 32 + ALPHABET.index(ch)
    return body + CHECK_ALPHABET[value % 37]


GOOD = [make_code(b) for b in ("01234567", "ABCDEFGH", "ZZZZZZZZ", "0000000A")]


def test_parse_payload_accepts_nine_character_codes():
    assert parse_payload("SX1.ABCDEFGH*.3") == ("ABCDEFGH*", 3)
    assert parse_payload("SX1.012345678.999") == ("012345678", 999)


def test_parse_payload_rejects_ten_character_code():
    assert parse_payload("SX1.0123456789.3") is None


def test_parse_payload_rejects_bad_input():
    assert parse_payload("SX1.ABCDEFGH*.0") is None
    assert parse_payload("SX1.ABCDEFGH*.1000") is None
    assert parse_payload("sx1.ABCDEFGH*.3") is None
    assert parse_payload("SX1.ABCDEFGI*.3") is None  # I is not in the alphabet
    assert parse_payload("SX1.ABCDEFGH*.3\n") is None
    assert parse_payload("") is None


def test_code_valid_true_for_built_codes():
    for c in GOOD:
        assert code_valid(c)


def test_code_valid_false_when_any_character_changes():
    for c in GOOD:
        for i in range(len(c)):
            for repl in ALPHABET + "*~$=U":
                if repl == c[i]:
                    continue
                assert not code_valid(c[:i] + repl + c[i + 1:]), (c, i, repl)


def test_code_valid_rejects_wrong_length_and_case():
    assert not code_valid("")
    assert not code_valid(GOOD[0][:8])
    assert not code_valid(GOOD[0] + "0")
    assert not code_valid(GOOD[1].lower())


def test_fixture_codes_are_valid():
    import json
    from pathlib import Path

    data = json.loads((Path(__file__).parent / "fixtures" / "codes.json").read_text())
    assert code_valid(data["codeA"]) and code_valid(data["codeB"])
    assert data["codeA"] != data["codeB"]
