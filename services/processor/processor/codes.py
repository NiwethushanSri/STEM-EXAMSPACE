"""Copy-code helpers shared with the web app and database (phase 1A)."""
import re

# Mirrors apps/web/src/lib/paper-payload.ts.
_PAYLOAD = re.compile(r"SX1\.([0-9A-HJKMNP-TV-Z*~$=U]{9})\.([1-9][0-9]{0,2})")

ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
CHECK_ALPHABET = ALPHABET + "*~$=U"


def parse_payload(text: str) -> tuple[str, int] | None:
    """Split a QR payload "SX1.<code>.<page>" into (code, page), or None."""
    m = _PAYLOAD.fullmatch(text)
    return (m.group(1), int(m.group(2))) if m else None


def code_valid(code: str) -> bool:
    """Port of public.copy_code_valid: 8 base-32 characters plus a mod-37 check."""
    if len(code) != 9 or any(c not in ALPHABET for c in code[:8]):
        return False
    value = 0
    for c in code[:8]:
        value = value * 32 + ALPHABET.index(c)
    return code[8] == CHECK_ALPHABET[value % 37]
