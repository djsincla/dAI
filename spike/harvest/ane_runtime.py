#!/usr/bin/env python3
"""
Core ML / ANE runtime for the harvest worker.

E2 established that no GPU setting is imperceptible while a user is present, and
the harvest worker then found background QoS costs ~26x on bursty work. Together
those made GPU harvesting viable only in LOCKED and ABSENT, leaving a logged-in
machine contributing nothing at all across three of five presence states.

E5 measured a saturating ANE workload as statistically indistinguishable from no
load (p95 -16%, inside a 36% noise floor) while equivalent GPU work cost +59% to
+100%. The Neural Engine is separate silicon an artist's viewport never touches.
This runtime is what turns those three dead states into working ones.

The safety property is placement verification. Core ML treats `CPU_AND_NE` as a
*preference*: unsupported ops, dtypes or shapes fall back to CPU silently. A
harvest worker that believed it was running on the ANE while actually running on
the CPU would be disturbing the very user it is trying to avoid — and it would
look fine in every log. So placement is checked with MLComputePlan at load and
the runtime refuses to start below a threshold.
"""

import pathlib
import time

import numpy as np
import coremltools as ct

# Below this share of compute ops on the ANE, the model is not doing what the
# policy assumes and the runtime refuses to run it.
MIN_ANE_SHARE = 0.8


class ANEPlacementError(RuntimeError):
    """Raised when a model is not sufficiently ANE-resident to be safe to run."""


class ANERuntime:
    """Runs a Core ML model with GPU excluded.

    CPU_AND_NE rather than ALL is deliberate: ALL would let Core ML schedule onto
    the GPU and silently reintroduce exactly the contention this runtime exists
    to avoid.
    """

    def __init__(self, model_path, verify=True):
        self.model_path = pathlib.Path(model_path)
        self.verify = verify
        self.model = None
        self.input_name = None
        self.input_shape = None
        self.placement = None

    @property
    def loaded(self):
        return self.model is not None

    def load(self):
        if self.loaded:
            return 0.0
        t0 = time.perf_counter()
        self.model = ct.models.MLModel(str(self.model_path),
                                       compute_units=ct.ComputeUnit.CPU_AND_NE)
        spec = self.model.get_spec()
        inp = spec.description.input[0]
        self.input_name = inp.name
        self.input_shape = tuple(int(d) for d in inp.type.multiArrayType.shape)

        if self.verify:
            self.placement = self._verify_placement()
            share = self.placement["ane_share"]
            if share < MIN_ANE_SHARE:
                self.model = None
                raise ANEPlacementError(
                    f"only {share:.0%} of compute ops are on the ANE "
                    f"(need >={MIN_ANE_SHARE:.0%}). Running anyway would disturb "
                    f"the user while reporting ANE-safe operation.")

        # First predict pays compilation; do it here so it is attributed to load
        # rather than to the first work item.
        self.model.predict({self.input_name: self._blank_batch()})
        return time.perf_counter() - t0

    def _blank_batch(self):
        return np.zeros(self.input_shape, dtype=np.float32)

    def _verify_placement(self):
        """Report which compute device each operation actually landed on.

        MLComputePlan needs a compiled .mlmodelc, not the .mlpackage — handed the
        package it aborts the process at the C++ level rather than raising. The
        compiled artifact lives in a temp directory owned by the MLModel, so that
        reference must stay alive while the plan is read.
        """
        from coremltools.models.compute_plan import MLComputePlan

        compiled = self.model.get_compiled_model_path()
        plan = MLComputePlan.load_from_path(
            str(compiled), compute_units=ct.ComputeUnit.CPU_AND_NE)

        program = getattr(plan.model_structure, "program", None)
        if program is None:
            raise ANEPlacementError("no compute plan available; placement unverifiable")

        counts, total = {}, 0
        for function in program.functions.values():
            for op in function.block.operations:
                if getattr(op, "operator_name", "") == "const":
                    continue  # metadata, not compute
                usage = plan.get_compute_device_usage_for_mlprogram_operation(op)
                if usage is None:
                    continue
                device = type(getattr(usage, "preferred_compute_device", None)).__name__
                counts[device] = counts.get(device, 0) + 1
                total += 1

        if not total:
            raise ANEPlacementError("compute plan reported no operations")
        ane = sum(n for d, n in counts.items() if "NeuralEngine" in d)
        return {"devices": counts, "total_ops": total, "ane_share": ane / total}

    def unload(self):
        if not self.loaded:
            return 0.0
        t0 = time.perf_counter()
        self.model = None
        return time.perf_counter() - t0

    def run(self, item):
        """Process one work item.

        The payload shape is fixed by the model, so an item supplies data rather
        than a prompt. Text arrives as `text` and is hashed into the input
        tensor — a stand-in until a real embedding model is converted. The
        mechanism, placement verification and policy integration are what this
        exercises; swapping in a converted embedding model changes only this
        method.
        """
        text = item.get("prompt") or item.get("text") or ""
        rng = np.random.default_rng(abs(hash(text)) % (2**32))
        batch = rng.standard_normal(self.input_shape).astype(np.float32)
        out = self.model.predict({self.input_name: batch})
        return {"id": item.get("id"), "keys": list(out.keys())}
