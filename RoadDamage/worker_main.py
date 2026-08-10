#!/usr/bin/env python3
"""NDJSON worker for the road-damage (Peninjauan) vertical — Protocol A.

One JSON object per stdin line in, one per stdout line out. **stdout carries
responses and nothing else**; model-loading chatter, Ultralytics' banner, and
structured `{"type": ...}` progress events all go to stderr. That split is the
whole protocol: `RoadDamageWorkerProcess` decodes stdout strictly and would treat
a stray `print()` as a malformed response. Ultralytics prints on import and on
first predict, so the load is wrapped in `redirect_stdout(sys.stderr)`.

Deliberately the SAME protocol as `PythonWorker/`'s `serve_worker` (ADR-001), not
`CarDetection`'s one-shot file contract (ADR-009). Peninjauan is a photo -> findings
flow like Tinjauan Parkir: a warm process amortises the multi-second model load
across every frame the reviewer opens, and there is no long-running job that needs
a file handoff. See ADR-016 for why this couldn't simply join `PythonWorker`.

Request  (type "analyze", the default when "type" is omitted):
    {"id": str, "image_path": str, "conf"?: float, "imgsz"?: int}
Response:
    {"id": str, "ok": bool, "image_width"?: int, "image_height"?: int,
     "condition"?: int, "grade"?: str, "start_score"?: int,
     "boxes"?: [{"box_index": int, "cls": str, "cx": float, "cy": float,
                 "w": float, "h": float, "conf": float, "area_pct": float,
                 "in_wheelpath": bool, "deduct_raw": float,
                 "deduct_effective": float}],
     "warnings"?: str, "error"?: str}

Stderr events: {"type": "ready"} once loaded, then
    {"type": "progress", "id": str, "stage": str, "state": str}
    {"type": "error", "error": str}

⚠️ Schema truth is this docstring paired with `RoadDamageModels.swift`. Per
CLAUDE.md's hard rule the two change together, in one commit — never one side.

Defaults match how `outputs/quantify/per_box.csv` was produced (conf 0.20,
imgsz 1280), so a frame analysed live here lands on the same boxes, and therefore
the same condition score, as the same frame read from the Stage 0 dataset. Change
one and Stage 0 and Stage 1 start disagreeing about the same road.

Usage::

    python3 worker_main.py --serve
    echo '{"id":"t","image_path":"/path/frame.jpg"}' | python3 worker_main.py --serve
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import severity  # noqa: E402

# Matches prelabel_report.json — the run that produced the Stage 0 CSVs.
DEFAULT_CONF = 0.20
DEFAULT_IMGSZ = 1280


def _emit(event: dict) -> None:
    """Structured event on stderr. stdout is reserved for responses."""
    print(json.dumps(event), file=sys.stderr, flush=True)


def pick_device() -> str:
    """CUDA -> MPS -> CPU, with an app-settable override.

    `JALANKITA_ROAD_DAMAGE_FORCE_CPU=1` mirrors `PYTHONWORKER_FORCE_CPU` in
    `PythonWorker/src/common.py`: the app sets it so a GPU backend crash in one
    vertical can't take the console down (ADR-012 documents the reproducible MPS
    SIGABRT that forced this for the disturbance worker). A CLI run without the
    variable still gets MPS, so app-vs-terminal timings are not comparable.
    """
    if os.environ.get("JALANKITA_ROAD_DAMAGE_FORCE_CPU") == "1":
        print("[device] cpu (forced by JALANKITA_ROAD_DAMAGE_FORCE_CPU)", file=sys.stderr)
        return "cpu"
    import torch

    if torch.cuda.is_available():
        return "0"
    if torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def resolve_checkpoint(explicit: str | None = None) -> Path:
    """Locate `server_trained.pt`, or raise. NEVER falls back to random weights.

    Ultralytics happily constructs a model from a config with untrained weights,
    which is how a missing checkpoint turns into confident nonsense instead of an
    error — the exact failure `PythonWorker` hit with `ofrsnet_best.pt` (CLAUDE.md
    fact 9). So a missing file is fatal here, loudly, at startup.
    """
    candidates = [
        Path(explicit) if explicit else None,
        Path(os.environ["JALANKITA_ROAD_DAMAGE_CKPT"])
        if os.environ.get("JALANKITA_ROAD_DAMAGE_CKPT") else None,
        ROOT / "models" / "server_trained.pt",
        # Dev convenience: the sibling checkout this model is trained in.
        ROOT.parent.parent / "test-road-damage-detection" / "models" / "server_trained.pt",
    ]
    for candidate in candidates:
        if candidate and candidate.is_file():
            return candidate
    searched = "\n  ".join(str(c) for c in candidates if c)
    raise FileNotFoundError(
        "Checkpoint deteksi kerusakan jalan tidak ditemukan. Lokasi yang dicari:\n  "
        + searched
        + "\nSetel JALANKITA_ROAD_DAMAGE_CKPT atau salin server_trained.pt ke models/."
    )


def build_remap(model_names: dict) -> dict[int, int]:
    """Map the model's own class ids onto the merged 3-class taxonomy.

    Raises rather than guessing: a silent mislabel here would put a pothole's
    46-point deduction behind a crack's 8, and the score would look plausible.
    """
    names = {int(k): str(v).lower() for k, v in model_names.items()}
    merged = {v: k for k, v in severity.CLASS_ID_TO_NAME.items()}
    legacy = {"d00": "crack", "d10": "crack", "d20": "alligator", "d40": "pothole"}

    remap: dict[int, int] = {}
    for model_id, name in names.items():
        target = name if name in merged else legacy.get(name)
        if target is None:
            raise ValueError(
                f"class {model_id!r}={name!r} maps to neither the merged taxonomy "
                f"{list(merged)} nor the legacy RDD set {list(legacy)}"
            )
        remap[model_id] = merged[target]
    return remap


def load_model(ckpt: Path):
    """Load YOLO with all of its stdout chatter pushed to stderr."""
    from ultralytics import YOLO

    with contextlib.redirect_stdout(sys.stderr):
        model = YOLO(str(ckpt))
    return model


def analyze(model, remap: dict[int, int], cfg: severity.SeverityConfig,
            image_path: Path, device: str, conf: float, imgsz: int) -> dict:
    """Run the detector on one frame and grade it. Returns the response payload."""
    from PIL import Image

    with Image.open(image_path) as im:
        width, height = im.size

    with contextlib.redirect_stdout(sys.stderr):
        results = model.predict([str(image_path)], conf=conf, imgsz=imgsz,
                                device=device, verbose=False)

    dets: list[severity.Detection] = []
    result = results[0]
    if result.boxes is not None:
        for cls, xywhn, box_conf in zip(result.boxes.cls.tolist(),
                                        result.boxes.xywhn.tolist(),
                                        result.boxes.conf.tolist()):
            merged_id = remap.get(int(cls))
            if merged_id is None:
                continue
            cx, cy, w, h = xywhn
            dets.append(severity.Detection(severity.CLASS_ID_TO_NAME[merged_id],
                                           cx, cy, w, h, box_conf))

    graded = severity.grade_segment(dets, cfg)
    effective = severity.effective_deductions(dets, cfg)

    boxes = [
        {
            "box_index": i,
            "cls": d.cls,
            "cx": round(d.cx, 6),
            "cy": round(d.cy, 6),
            "w": round(d.w, 6),
            "h": round(d.h, 6),
            "conf": round(d.conf, 4),
            "area_pct": round(100.0 * d.area_frac, 4),
            "in_wheelpath": bool(d.in_wheelpath(cfg)),
            "deduct_raw": round(severity.score_detection(d, cfg), 3),
            "deduct_effective": round(eff, 3),
        }
        for i, (d, eff) in enumerate(zip(dets, effective))
    ]

    # Ship the caveat with the number, per this repo's wire convention. The
    # detector's 0.53 mAP is a Japan+India figure and has never been measured
    # against Indonesian box labels; it under-fires here rather than over-fires.
    warnings = ("Model RDD2022 belum divalidasi pada data Indonesia — jumlah temuan "
                "adalah batas bawah, bukan kebenaran.")

    return {
        "image_width": width,
        "image_height": height,
        "condition": graded.condition,
        "grade": graded.grade,
        "start_score": 100,
        "boxes": boxes,
        "warnings": warnings,
    }


def serve_worker(ckpt: str | None, conf: float, imgsz: int) -> None:
    """Read one JSON request per stdin line; write one JSON response per stdout line."""
    checkpoint = resolve_checkpoint(ckpt)
    device = pick_device()
    print(f"[device] {device}", file=sys.stderr)
    print(f"[ok] checkpoint {checkpoint}", file=sys.stderr)

    cfg = severity.SeverityConfig.from_yaml()
    model = load_model(checkpoint)
    remap = build_remap(model.names)
    print(f"[ok] remap {remap} -> {severity.CLASS_ID_TO_NAME}", file=sys.stderr)

    _emit({"type": "ready"})

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError as e:
            _emit({"type": "error", "error": f"invalid JSON request: {e}"})
            continue

        req_id = req.get("id", "")
        req_type = req.get("type", "analyze")

        if req_type != "analyze":
            print(json.dumps({"id": req_id, "ok": False,
                              "error": f"unknown request type {req_type!r}"}), flush=True)
            continue

        try:
            image_path = Path(req["image_path"])
            if not image_path.is_file():
                raise FileNotFoundError(f"gambar tidak ditemukan: {image_path}")

            _emit({"type": "progress", "id": req_id, "stage": "detect", "state": "active"})
            payload = analyze(model, remap, cfg, image_path, device,
                              float(req.get("conf", conf)), int(req.get("imgsz", imgsz)))
            _emit({"type": "progress", "id": req_id, "stage": "detect", "state": "done"})
            _emit({"type": "progress", "id": req_id, "stage": "severity", "state": "done"})

            response = {"id": req_id, "ok": True, **payload}
        except Exception as e:  # noqa: BLE001 — one bad frame must not kill the worker
            _emit({"type": "error", "error": str(e)})
            response = {"id": req_id, "ok": False, "error": str(e)}

        print(json.dumps(response), flush=True)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--serve", action="store_true", help="run the NDJSON worker loop")
    ap.add_argument("--ckpt", help="detector checkpoint (else env, then models/)")
    ap.add_argument("--conf", type=float, default=DEFAULT_CONF, help="confidence threshold")
    ap.add_argument("--imgsz", type=int, default=DEFAULT_IMGSZ, help="inference size")
    ap.add_argument("--selftest", action="store_true",
                    help="checkpoint + config + taxonomy check, no model load")
    args = ap.parse_args()

    if args.selftest:
        ckpt = resolve_checkpoint(args.ckpt)
        cfg = severity.SeverityConfig.from_yaml()
        print(f"[ok] checkpoint  {ckpt} ({ckpt.stat().st_size / 1e6:.1f} MB)")
        print(f"[ok] taxonomy    {severity.CLASS_ID_TO_NAME}")
        print(f"[ok] bands       IGNORE>={cfg.ignore_min:g} MONITOR>={cfg.monitor_min:g}")
        print(f"[ok] wheelpath   x{cfg.wheelpath_mult:g}  decay {cfg.density_decay:g}")
        # The anchor cases from the upstream repo's own demo, so a bad re-vendor
        # of severity.yaml is caught here rather than on screen.
        big = [severity.Detection("pothole", 0.5, 0.75, 0.34, 0.33)]
        hair = [severity.Detection("crack", 0.12, 0.30, 0.03, 0.01)]
        assert severity.grade_segment(big, cfg).grade == "URGENT", "large near pothole must be URGENT"
        assert severity.grade_segment(hair, cfg).grade == "IGNORE", "hairline crack must be IGNORE"
        print("[ok] anchors     large near pothole -> URGENT, hairline crack -> IGNORE")
        return

    if not args.serve:
        ap.error("nothing to do — pass --serve (or --selftest)")

    serve_worker(args.ckpt, args.conf, args.imgsz)


if __name__ == "__main__":
    main()
