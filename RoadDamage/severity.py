"""Box-based, PCI-*informed* severity scoring — trimmed copy for the JalanKita worker.

Vendored from `../test-road-damage-detection/src/severity.py` at the same point
`outputs/quantify/per_box.csv` was generated, and deliberately kept byte-for-byte
equivalent in its arithmetic. Trimmed of the CLI, the demo fixtures, and the
cross-directory import of `convert_voc_to_yolo.ID_TO_NAME` (inlined below), so
this module imports with nothing but `yaml` on the path.

⚠️ **This file and `severity.yaml` must stay in step with the upstream pair.**
The whole point of ADR-016 is that ONE severity implementation exists: Stage 0
reads `condition` and `deduct_effective` out of CSVs the upstream copy produced,
and Stage 1 recomputes them here. If the two drift, a frame analysed live will
score differently from the same frame read from the dataset, and the console will
show two numbers for one road with nothing to say which is right. Re-vendor both
files together, never one alone.

Kept identical to upstream, including the parts that look wrong until you read
the config: the wheel-path multiplier is **1.22** (not the 1.4 the old Swift mock
displayed), same-class repeats decay by **0.82^rank** (not ÷3), there IS a size
term `0.65 + 4.5*min(area_frac, 0.15)`, and the final clamp is `[2, 98]` — so a
perfectly clean frame scores 98, never 100.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

import yaml

# Inlined from scripts/convert_voc_to_yolo.py's ID_TO_NAME — the merged 3-class
# taxonomy after RDD2022's D00 (longitudinal) + D10 (transverse) collapse into one
# `crack` class. Must match data/local_prelabeled/data.yaml exactly.
CLASS_ID_TO_NAME: dict[int, str] = {0: "crack", 1: "alligator", 2: "pothole"}
CLASS_LABEL: dict[str, str] = {
    "crack": "crack",
    "alligator": "alligator crack",
    "pothole": "pothole",
}
GRADES = ("IGNORE", "MONITOR", "URGENT")

DEFAULT_CONFIG = Path(__file__).resolve().parent / "severity.yaml"


@dataclass(frozen=True)
class SeverityConfig:
    """Tunable weights loaded from ``severity.yaml`` (no code edits to change)."""

    segment_length_m: float
    class_deduct: dict[str, float]
    size_floor: float
    size_gain: float
    size_cap: float
    wheelpath_mult: float
    wheelpath_x: tuple[float, float]
    wheelpath_y_min: float
    density_decay: float
    ignore_min: float
    monitor_min: float

    @classmethod
    def from_yaml(cls, path: Path = DEFAULT_CONFIG) -> "SeverityConfig":
        cfg = yaml.safe_load(Path(path).read_text())
        size, wp, grades = cfg["size"], cfg["wheelpath"], cfg["grades"]
        return cls(
            segment_length_m=float(cfg["segment_length_m"]),
            class_deduct={k: float(v) for k, v in cfg["class_deduct"].items()},
            size_floor=float(size["floor"]),
            size_gain=float(size["gain"]),
            size_cap=float(size["cap"]),
            wheelpath_mult=float(wp["multiplier"]),
            wheelpath_x=(float(wp["x_min"]), float(wp["x_max"])),
            wheelpath_y_min=float(wp["y_min"]),
            density_decay=float(cfg["density_decay"]),
            ignore_min=float(grades["ignore_min"]),
            monitor_min=float(grades["monitor_min"]),
        )


@dataclass
class Detection:
    """One YOLO box in normalized frame coordinates (centre x/y, width, height)."""

    cls: str
    cx: float
    cy: float
    w: float
    h: float
    conf: float = 1.0

    @property
    def area_frac(self) -> float:
        """Box area as a fraction of the frame (extent proxy — no depth)."""
        return max(0.0, self.w) * max(0.0, self.h)

    def in_wheelpath(self, cfg: SeverityConfig) -> bool:
        """True if the box centre sits in the lower-central frame band."""
        x0, x1 = cfg.wheelpath_x
        return x0 <= self.cx <= x1 and self.cy >= cfg.wheelpath_y_min


@dataclass
class SegmentSeverity:
    """Result of grading one frame's detections."""

    condition: int
    grade: str
    worst_class: str | None
    defect_count: int
    total_deduct: float
    rationale: str
    class_counts: dict[str, int] = field(default_factory=dict)


def score_detection(det: Detection, cfg: SeverityConfig) -> float:
    """PCI deduction for a single detection: class hazard x size x wheel-path."""
    base = cfg.class_deduct.get(det.cls, 0.0)
    size_mult = cfg.size_floor + cfg.size_gain * min(det.area_frac, cfg.size_cap)
    pos_mult = cfg.wheelpath_mult if det.in_wheelpath(cfg) else 1.0
    return base * size_mult * pos_mult


def grade_condition(condition: float, cfg: SeverityConfig) -> str:
    """Map a 0-100 condition to a priority grade (lower = worse)."""
    if condition >= cfg.ignore_min:
        return "IGNORE"
    if condition >= cfg.monitor_min:
        return "MONITOR"
    return "URGENT"


def effective_deductions(dets: list[Detection], cfg: SeverityConfig) -> list[float]:
    """Per-detection deduction AFTER same-class density decay, aligned with ``dets``.

    The console renders these as its "Skor awal 100 -> deductions -> Skor kondisi"
    panel, so they must sum to exactly what :func:`grade_segment` subtracted.
    """
    by_class: dict[str, list[tuple[float, int]]] = {}
    for i, d in enumerate(dets):
        by_class.setdefault(d.cls, []).append((score_detection(d, cfg), i))

    out = [0.0] * len(dets)
    for pairs in by_class.values():
        pairs.sort(key=lambda p: p[0], reverse=True)
        for rank, (val, i) in enumerate(pairs):
            out[i] = val * (cfg.density_decay ** rank)
    return out


def grade_segment(dets: list[Detection], cfg: SeverityConfig) -> SegmentSeverity:
    """Aggregate detections into a condition score + priority grade.

    condition = clamp(100 - sum(effective_deductions), 2, 98).
    """
    if not dets:
        return SegmentSeverity(98, "IGNORE", None, 0, 0.0, "No detections in frame.", {})

    class_counts: dict[str, int] = {}
    for d in dets:
        class_counts[d.cls] = class_counts.get(d.cls, 0) + 1

    total = sum(effective_deductions(dets, cfg))
    condition = int(round(max(2.0, min(98.0, 100.0 - total))))
    grade = grade_condition(condition, cfg)
    worst = max(class_counts, key=lambda c: cfg.class_deduct.get(c, 0.0))
    n = sum(class_counts.values())
    wheel = any(d.in_wheelpath(cfg) for d in dets)
    rationale = (
        f"Worst defect: {CLASS_LABEL.get(worst, worst)}; {n} defect(s) in frame"
        + (", in the wheel-path" if wheel else "")
        + f". Deductions sum to {total:.1f} -> condition {condition} -> {grade}."
    )
    return SegmentSeverity(condition, grade, worst, n, round(total, 2), rationale, class_counts)
