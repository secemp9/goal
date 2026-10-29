"""Read JSONC (comments and trailing commas) and emit strict JSON for jq."""

import json
import re
import sys


def loads(text):
    # Match strings first so comment markers and commas inside them survive.
    tokens = r'"(?:[^"\\]|\\.)*"|//[^\n]*|/\*.*?\*/'
    text = re.sub(
        tokens,
        lambda match: match[0] if match[0].startswith('"') else ' ',
        text,
        flags=re.DOTALL,
    )
    text = re.sub(
        r'"(?:[^"\\]|\\.)*"|,(\s*[}\]])',
        lambda match: match[1] if match[1] is not None else match[0],
        text,
    )
    return json.loads(text)


if __name__ == "__main__":
    json.dump(loads(sys.stdin.read()), sys.stdout, indent=2)
    print()
