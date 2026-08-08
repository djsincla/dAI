"""
E2 interactive workload: a Blender EEVEE viewport orbit, measured per frame.

Run via Blender, not directly:
    /Applications/Blender.app/Contents/MacOS/Blender \
        --python blender_viewport.py -- --out result.json --frames 300

Why the viewport and not a Cycles render: a render is a batch job with the same
shape as a compiled build, so it would tell us nothing new. The viewport is the
thing a person actually feels, and it competes with MLX for the same GPU rather
than only for memory bandwidth.

Why percentiles and not mean fps: mean fps hides stutter, and stutter is exactly
what people notice. A viewport averaging 55fps while periodically hitching to
200ms reads as broken; one steady at 45fps reads as fine. p95/p99 and hitch
count capture that; an average does not.

Playback runs with sync_mode NONE ("play every frame") so Blender never drops
frames to keep up. Frame interval then directly measures render cost instead of
being clamped to the scene's frame rate.
"""

import json
import math
import statistics
import sys
import time

import bpy

# The scene MUST be heavy enough that GPU time dominates the display refresh
# interval. Two caps bite otherwise, and both silently produce a flat, useless
# measurement:
#   - Blender's scene frame rate (fixed above by raising render.fps)
#   - display vsync — 8.33ms on a 120Hz ProMotion panel
# If frame time lands suspiciously near 1/refresh with near-zero variance, the
# scene is too light and the run is measuring vsync, not contention.
# Target p50 of roughly 30-50ms. Heavier machines need a bigger grid, so these
# are tunable rather than constants.
GRID = 6
SUBSURF_LEVELS = 4
TAA_SAMPLES = 64
SHADOW_LIGHTS = 4
WARMUP_FRAMES = 40   # EEVEE shader compilation leaks well past the first frames


def parse_args():
    argv = sys.argv
    argv = argv[argv.index("--") + 1:] if "--" in argv else []
    args = {
        "out": "/tmp/blender_viewport.json",
        "frames": 300,
        "label": "unlabeled",
        "grid": GRID,
        "subsurf": SUBSURF_LEVELS,
        "samples": TAA_SAMPLES,
        "lights": SHADOW_LIGHTS,
        "volumetrics": 1,
    }
    ints = {"frames", "grid", "subsurf", "samples", "lights", "volumetrics"}
    for i in range(0, len(argv) - 1, 2):
        key = argv[i].lstrip("-")
        if key in args:
            args[key] = int(argv[i + 1]) if key in ints else argv[i + 1]
    return args


def _active():
    """Object just created by an operator.

    bpy.context.active_object is unavailable early in startup, and even later it
    is only valid with the right area context. The view layer is authoritative
    and always present; bpy.data is the last-resort fallback.
    """
    obj = getattr(bpy.context, "view_layer", None)
    obj = obj.objects.active if obj else None
    return obj or (bpy.data.objects[-1] if bpy.data.objects else None)


def build_scene(grid, subsurf_levels, samples, shadow_lights, volumetrics):
    """Deterministic, moderately heavy scene. Fixed geometry so runs compare."""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene

    scene.render.engine = "BLENDER_EEVEE"
    scene.eevee.taa_samples = samples
    scene.eevee.use_ssr = True          # screen-space reflections: real GPU cost
    scene.eevee.use_ssr_refraction = True
    scene.eevee.use_gtao = True         # ambient occlusion
    scene.eevee.use_bloom = True
    scene.frame_start = 1
    scene.frame_end = 100000            # long enough that we stop, not playback
    scene.sync_mode = "NONE"            # play every frame; never drop to keep up

    # Uncap playback. At Blender's default 24fps every frame interval pins to
    # exactly 41.67ms with near-zero variance, because the GPU finishes early
    # and waits — the benchmark then measures the frame-rate cap, not render
    # cost, and only detects contention severe enough to fall below 24fps.
    # A high target lets frame interval equal actual GPU time.
    scene.render.fps = 240

    for x in range(grid):
        for y in range(grid):
            bpy.ops.mesh.primitive_monkey_add(location=(x * 3 - grid * 1.5, y * 3 - grid * 1.5, 0))
            obj = _active()
            sub = obj.modifiers.new("Subsurf", "SUBSURF")
            sub.levels = subsurf_levels
            sub.render_levels = subsurf_levels
            # Set smoothing on mesh data rather than via the operator, which
            # needs an area context we do not reliably have here. foreach_set
            # is a bulk C-level write; the equivalent Python loop is millions
            # of interpreter iterations at large grid sizes and dominates
            # startup.
            polys = obj.data.polygons
            polys.foreach_set("use_smooth", [True] * len(polys))

            mat = bpy.data.materials.new(f"Mat_{x}_{y}")
            mat.use_nodes = True
            bsdf = mat.node_tree.nodes["Principled BSDF"]
            bsdf.inputs["Base Color"].default_value = (
                (x + 1) / grid, (y + 1) / grid, 0.6, 1.0)
            bsdf.inputs["Metallic"].default_value = 0.8
            bsdf.inputs["Roughness"].default_value = 0.25
            obj.data.materials.append(mat)

    bpy.ops.object.light_add(type="SUN", location=(5, 5, 12))
    _active().data.energy = 4.0

    # Per-frame render cost, not scene-construction cost. Geometry is the wrong
    # knob for weighting this benchmark: subdividing further costs minutes of
    # Python-side build time for every run. Shadow-casting lights and
    # volumetrics are near-free to construct and expensive to render, which is
    # exactly the trade we want when tuning toward a target frame time.
    for i in range(shadow_lights):
        angle = 6.28318 * i / max(shadow_lights, 1)
        bpy.ops.object.light_add(
            type="POINT",
            location=(12 * math.cos(angle), 12 * math.sin(angle), 6),
        )
        light = _active().data
        light.energy = 3000.0
        light.use_shadow = True
        light.shadow_buffer_clip_start = 0.05

    if volumetrics:
        scene.eevee.use_volumetric_shadows = True
        scene.eevee.volumetric_samples = 128
        bpy.ops.mesh.primitive_cube_add(size=40, location=(0, 0, 6))
        fog = _active()
        mat = bpy.data.materials.new("Fog")
        mat.use_nodes = True
        nodes, links = mat.node_tree.nodes, mat.node_tree.links
        nodes.remove(nodes["Principled BSDF"])
        scatter = nodes.new("ShaderNodeVolumeScatter")
        scatter.inputs["Density"].default_value = 0.012
        links.new(scatter.outputs["Volume"], nodes["Material Output"].inputs["Volume"])
        fog.data.materials.append(mat)

    # Orbit an empty-parented camera so every frame forces a full redraw.
    bpy.ops.object.empty_add(location=(0, 0, 0))
    pivot = _active()
    bpy.ops.object.camera_add(location=(0, -18, 9), rotation=(1.1, 0, 0))
    cam = _active()
    cam.parent = pivot
    scene.camera = cam

    pivot.rotation_euler = (0, 0, 0)
    pivot.keyframe_insert("rotation_euler", frame=1)
    pivot.rotation_euler = (0, 0, 6.28318)
    pivot.keyframe_insert("rotation_euler", frame=240)
    for fcurve in pivot.animation_data.action.fcurves:
        for kp in fcurve.keyframe_points:
            kp.interpolation = "LINEAR"
    if pivot.animation_data.action:
        pivot.animation_data.action.use_cyclic = True


def find_view3d():
    for window in bpy.context.window_manager.windows:
        for area in window.screen.areas:
            if area.type == "VIEW_3D":
                region = next((r for r in area.regions if r.type == "WINDOW"), None)
                return window, area, region
    return None, None, None


class Recorder:
    def __init__(self, args):
        self.args = args
        self.stamps = []
        self.started = None

    def on_frame(self, scene, depsgraph=None):
        now = time.perf_counter()
        self.stamps.append(now)
        if len(self.stamps) >= self.args["frames"]:
            self.finish()

    def finish(self):
        intervals = [
            (b - a) * 1000.0
            for a, b in zip(self.stamps, self.stamps[1:])
        ]
        # Drop the warmup window: EEVEE compiles shaders lazily, and volumetrics
        # in particular produce a single ~600ms frame well after playback
        # starts. That is startup cost, not steady-state interactive
        # performance, and left in it dominates p99 and fakes a hitch.
        intervals = intervals[WARMUP_FRAMES:]

        result = {"label": self.args["label"], "frames_measured": len(intervals)}
        if intervals:
            ordered = sorted(intervals)
            median = statistics.median(ordered)
            result.update({
                "mean_ms": round(statistics.fmean(ordered), 2),
                "p50_ms": round(median, 2),
                "p95_ms": round(ordered[int(len(ordered) * 0.95)], 2),
                "p99_ms": round(ordered[min(int(len(ordered) * 0.99), len(ordered) - 1)], 2),
                "max_ms": round(ordered[-1], 2),
                "mean_fps": round(1000.0 / statistics.fmean(ordered), 1),
                # A hitch is a frame taking >2x the median — the visible stutter
                # that an average frame rate would completely conceal.
                "hitches": sum(1 for v in intervals if v > 2 * median),
                "hitch_pct": round(
                    100.0 * sum(1 for v in intervals if v > 2 * median) / len(intervals), 2),
            })
        else:
            result["error"] = "no frame intervals recorded"

        with open(self.args["out"], "w") as f:
            json.dump(result, f, indent=2)
        print("E2_VIEWPORT_RESULT " + json.dumps(result), flush=True)
        bpy.ops.wm.quit_blender()


def main():
    args = parse_args()
    recorder = Recorder(args)

    def bail(message):
        with open(args["out"], "w") as f:
            json.dump({"label": args["label"], "error": message}, f, indent=2)
        print("E2_VIEWPORT_RESULT " + json.dumps({"error": message}), flush=True)
        bpy.ops.wm.quit_blender()
        return None

    def start():
        """Everything deferred: at --python time bpy.context has no view layer,
        so both scene construction and playback have to wait for the UI."""
        try:
            build_scene(args["grid"], args["subsurf"], args["samples"],
                        args["lights"], bool(args["volumetrics"]))
        except Exception as exc:
            import traceback
            traceback.print_exc()
            return bail(f"scene build failed: {exc!r}")

        window, area, region = find_view3d()
        if area is None:
            return bail("no VIEW_3D area; Blender must run with a GUI, not -b")

        area.spaces[0].shading.type = "MATERIAL"   # force EEVEE, not solid shading
        area.spaces[0].region_3d.view_perspective = "CAMERA"

        bpy.app.handlers.frame_change_post.append(recorder.on_frame)
        recorder.started = time.perf_counter()
        try:
            with bpy.context.temp_override(window=window, area=area, region=region):
                bpy.ops.screen.animation_play()
        except Exception as exc:
            return bail(f"animation_play failed: {exc!r}")

        # Watchdog: if playback never advances frames, quit rather than hang the
        # harness forever waiting for a handler that will not fire.
        def watchdog():
            if len(recorder.stamps) < 2:
                return bail("playback never advanced a frame")
            return None
        bpy.app.timers.register(watchdog, first_interval=30.0)
        return None  # unregister the timer

    # 2s of slack so the window is mapped and the first draw has happened.
    bpy.app.timers.register(start, first_interval=2.0)


main()
