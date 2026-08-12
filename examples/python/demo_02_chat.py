#!/usr/bin/env python3
"""One completion, in both shapes, and what a refusal means.

The gateway speaks OpenAI's shape and Anthropic's shape over the same routing,
the same policy caps and the same nodes. That is deliberate: the clients people
already have should work against this fleet without being patched, because
asking somebody to modify their tooling to try something is a good way to have
nobody try it.

    python3 demo_02_chat.py "your question here"
"""

import sys

from dai_gateway import Gateway, GatewayError, NoCapacity, pick_model, text_of, who_answered

QUESTION = "In two sentences, what is a regional center in California?"


def main() -> int:
    gateway = Gateway()
    question = sys.argv[1] if len(sys.argv) > 1 else QUESTION
    model = pick_model(gateway)
    print(f"model     {model}")
    print(f"question  {question}\n")

    # ---- OpenAI shape ----------------------------------------------------
    completion = gateway.chat(model, [{"role": "user", "content": question}],
                              max_tokens=300)
    print("--- /v1/chat/completions ---")
    print(text_of(completion).strip())
    usage = completion.get("usage", {})
    print(f"\nanswered by {who_answered(completion)}")
    print(f"tokens: {usage.get('prompt_tokens')} in, {usage.get('completion_tokens')} out")

    # The node may have returned fewer tokens than asked for. That is presence
    # policy, not truncation by accident: a completion cannot be paused, so its
    # length is the only lever bounding how long a returning user waits.
    if completion.get("choices", [{}])[0].get("finish_reason") == "length":
        print("stopped on length; the answering node capped this by its policy")

    # ---- Anthropic shape -------------------------------------------------
    print("\n--- /v1/messages ---")
    reply = gateway.messages(model, [{"role": "user", "content": question}],
                             max_tokens=300,
                             system="Answer plainly and do not speculate.")
    print(text_of(reply).strip())
    print(f"\nanswered by {who_answered(reply)}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except NoCapacity as error:
        # Handled separately from every other failure because it is not one.
        print(error)
        raise SystemExit(0)
    except GatewayError as error:
        print(f"\n{error}")
        raise SystemExit(1)
