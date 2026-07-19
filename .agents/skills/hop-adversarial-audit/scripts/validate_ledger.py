from __future__ import annotations

import argparse
import sys

from ledger import load_ledger, validate_ledger


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate a HOP adversarial audit ledger")
    parser.add_argument("ledger", help="Path to the JSON ledger")
    parser.add_argument(
        "--allow-incomplete",
        action="store_true",
        help="Allow pending coverage and candidate findings in a working ledger",
    )
    args = parser.parse_args()

    try:
        data = load_ledger(args.ledger)
    except (OSError, ValueError) as error:
        print(f"ledger validation failed: {error}", file=sys.stderr)
        return 1

    errors = validate_ledger(data, allow_incomplete=args.allow_incomplete)
    if errors:
        print(f"ledger validation failed with {len(errors)} error(s):", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print("ledger validation: passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
