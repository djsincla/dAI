#!/usr/bin/env python3
"""What the fleet can serve, and what a prompt would cost.

The first thing to run. It proves the credential works, the certificate
verifies, and something is actually loaded somewhere - which is the whole of
"is this thing on" for a serving gateway.

    python3 demo_01_models.py
"""

from dai_gateway import Gateway, GatewayError


def main() -> int:
    gateway = Gateway()
    print(f"gateway   {gateway.base_url}")
    print(f"key       {'set' if gateway.api_key else 'MISSING - set DAI_API_KEY'}")
    print(f"TLS       {gateway.describe_tls()}")
    print()

    models = gateway.models()
    if not models:
        print("No models resident. Push one from the console and try again.")
        return 1

    print(f"{len(models)} model(s) resident in the fleet:")
    for model in models:
        print(f"  {model['id']}  (owned_by: {model.get('owned_by', '-')})")

    # The LM Studio shape carries the context window, which OpenAI's does not.
    # It matters for anything that stuffs retrieved text into a prompt: it is
    # the budget the RAG example spends.
    print()
    detailed = gateway.models_detailed()
    if detailed:
        print("context windows, as loaded:")
        for model in detailed:
            context = model.get("loaded_context_length") or model.get("max_context_length")
            kind = model.get("type", "-")
            print(f"  {model.get('id')}  {kind}  context={context}")

    # Counted by the node's own tokeniser rather than guessed here. The chat
    # template is part of the prompt and it is not free.
    model = models[0]["id"]
    print()
    for label, messages in [
        ("a short question", [{"role": "user", "content": "What is the Lanterman Act?"}]),
        ("the same, with a system prompt", [
            {"role": "system", "content": "You answer only from the provided sources."},
            {"role": "user", "content": "What is the Lanterman Act?"},
        ]),
    ]:
        try:
            print(f"{gateway.count_tokens(model, messages):>6} input tokens  {label}")
        except GatewayError as error:
            print(f"     ?  {label}: {error}")

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except GatewayError as error:
        print(f"\n{error}")
        raise SystemExit(1)
