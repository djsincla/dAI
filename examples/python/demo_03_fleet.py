#!/usr/bin/env python3
"""Which machines exist, what they are doing, and who is sitting at them.

The other demos use the fleet. This one looks at it, and it is the script that
shows what is actually different here: every answer came off a named machine
that belongs to somebody, and that machine takes itself away when its owner
comes back.

Needs a key with admin rights. A serving-only key will be refused, which is the
correct outcome and is reported as such.

    python3 demo_03_fleet.py
"""

from dai_gateway import Gateway, GatewayError


def bar(fraction: float, width: int = 24) -> str:
    filled = max(0, min(width, round(fraction * width)))
    return "#" * filled + "." * (width - filled)


def main() -> int:
    gateway = Gateway()

    try:
        summary = gateway.fleet_summary()
    except GatewayError as error:
        if error.status in (401, 403):
            print("This key cannot read the fleet; it is a serving credential.\n"
                  "Mint an admin key, or run demo_01 and demo_02, which need no admin rights.")
            return 1
        raise

    print("=== fleet ===")
    for key in ("nodes", "online", "approved", "pending", "paused"):
        if key in summary:
            print(f"  {key:<10} {summary[key]}")
    for key, value in summary.items():
        if key not in ("nodes", "online", "approved", "pending", "paused") \
                and isinstance(value, (int, float, str)):
            print(f"  {key:<10} {value}")

    nodes = gateway.nodes()
    if not nodes:
        print("\nNo machines enrolled yet.")
        return 0

    print(f"\n=== {len(nodes)} machine(s) ===")
    for node in nodes:
        name = node.get("name") or node.get("hostname") or node.get("id", "?")
        state = node.get("presenceState") or node.get("state") or "-"
        status = node.get("status", "-")
        serving = node.get("servingModel") or node.get("model") or ""
        print(f"  {name:<22} {status:<10} presence={state:<10} {serving}")

    # Presence is the whole argument. A machine that is ACTIVE has somebody at
    # it and is not available for GPU work, and that is the promise being kept
    # rather than capacity being lost.
    states = {}
    for node in nodes:
        states[node.get("presenceState") or "unknown"] = \
            states.get(node.get("presenceState") or "unknown", 0) + 1
    print("\n=== presence ===")
    total = sum(states.values())
    for state, count in sorted(states.items(), key=lambda kv: -kv[1]):
        print(f"  {state:<12} {bar(count / total)} {count}")

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except GatewayError as error:
        print(f"\n{error}")
        raise SystemExit(1)
