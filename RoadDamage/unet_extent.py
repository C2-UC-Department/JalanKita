"""Measure how much of a detector box is actually damaged, with ../road_seg's U-Net.

A YOLO box says *where* and *what*. It is a poor answer to *how much*: `area_frac = w * h` treats a
hairline diagonal crack as if it filled its own bounding rectangle. Measured against hand-brushed
Surabaya frames, tight boxes drawn around the **human's own** brush strokes score only **24,48 %**
pixel precision — that is the ceiling for any box, before a detector makes a single mistake. Honest
for a pothole, which really does fill its box; wrong for a crack.

So the box stays in charge of *whether* and *which class*, and this module answers only *how much*,
**inside** each box. That split is the whole point (JalanKita ADR-021): the segmenter is measurably
more accurate than the detector on asphalt (13,45 % vs 0,85 % pixel precision) yet cannot replace
it, because it fires on 958 of 958 frames, has no per-defect unit, and has no `alligator` class.
Constrained to a region the detector has already committed to, it is 83,77 % precise — six times
the mask alone, and the best number measured anywhere in that evaluation.

**This is a vendored, trimmed copy of `../../road_seg/engine.py`'s inference path**, in the same
spirit as `severity.py`. Re-vendor it if that file's inference arithmetic changes.

**How to verify a re-vendor** — decode one frame to an `.npy` so the JPEG decoder drops out of the
comparison, then run it through both implementations *in one process* and require
`logits.argmax` to differ by **zero** pixels. Verified 2026-08-13 on
`IMG_0040_f000030_t0001000`: resize, pad and normalised tensor all `array_equal`, logits
`max|delta| = 0.000e+00`, argmax 0 px.

⚠️ **Across the two venvs that equality does not hold, and it is not this file's fault.** This
worker pins `opencv-python==4.10.0.84` for detector parity while `../road_seg` runs 5.0; their
`cv2.resize(..., INTER_AREA)` disagree by one level on 443 of 5.591.040 channel values (0,0079 %)
when scaling 1080 -> 1024 px of width, which moves **16 of 2.073.600** label pixels (0,0008 %).
Same family as the JPEG-decode drift `requirements.txt` already documents. It is far below the
precision of anything measured here, but do not expect a label map produced by this worker to be
byte-identical to one in `../road_seg/outputs/`, and do not "fix" it by unpinning cv2 — that pin
protects the detector numbers, which are the ones with a published contract.

What was deliberately left behind, and why:

* **`albumentations`** — used upstream only for `A.Normalize() + ToTensorV2()`. Reproduced here in
  four lines. ⚠️ Note the *reciprocal* multiply below; `/ std` differs in the last bit.
* **the SegFormer road gate** (`roadmask.py`) — pointless here. Its job is to stop the U-Net
  claiming damage off the carriageway, and a detector box is a far tighter prior than a road mask.
  Dropping it also drops `transformers` entirely, and removes the `gate_failed_open` failure mode.
* **`min_prob` / `min_area_frac`** — road_seg ADR-020 measured both and rejected both: crack
  precision is flat at 36-37 % across the whole threshold range while recall collapses 82 % -> 5 %.
  Pure argmax is the shipped operating point, not laziness.
* **`resize` and `tile` modes** — `tile` costs 2,6x `full` for +0 mIoU.

⚠️ **One image per call.** ADR-021 measured that ultralytics letterboxes a batch to a shape derived
from the batch, moving a real frame's `conf` 0,4558 -> 0,5288. Nothing here batches either, and the
worker must not start.
"""

from __future__ import annotations

from pathlib import Path

import cv2
import numpy as np
import torch

CLASS_NAMES = ("background", "crack", "pothole")
NUM_CLASSES = len(CLASS_NAMES)

#: Any non-background class counts toward a box's extent.
#:
#: 🔥 Class-**agnostic** on purpose. The U-Net predicts background/crack/pothole and has no
#: `alligator`, while 40 % of the detector's boxes are alligator. Matching classes would score
#: every one of those boxes at exactly zero extent — not because the road is intact, but because
#: the two models use different vocabularies. The detector already decided what the defect is.
DEFECT_CLASSES = (1, 2)

#: `../road_seg` ADR-008: "1024" means 1024 px of *horizontal* extent, not of the long side — the
#: scale sweep that chose it ran on landscape frames. Both Indonesian sources are portrait, so
#: normalising the long side instead would feed only 768 px of width and miss the measured peak.
PRE_SCALE_WIDTH = 1024

# ImageNet statistics, pre-multiplied to uint8 scale. `albucore` normalises by multiplying by the
# reciprocal of the standard deviation rather than dividing by it, so reproducing it as `/ std`
# disagrees in the final bit on some pixels. Kept in this shape to stay bit-identical upstream.
_MEAN = np.float32([0.485, 0.456, 0.406]) * 255.0
_DENOM = np.reciprocal(np.float32([0.229, 0.224, 0.225]) * 255.0)


def build_model(encoder: str = "resnet34"):
    """A randomly-initialised U-Net with the architecture `unet_resnet34.pt` was trained as.

    ⚠️ `encoder_weights=None` is load-bearing, and it is **not** upstream's default. `build_model`
    in `engine.py` defaults to `"imagenet"`, which reaches for the network on first call — fine in
    a notebook, fatal in a worker that may run offline or inside a sandboxed app bundle. Every
    tensor is overwritten by `load_model` a moment later anyway, so the pretrained weights would be
    downloaded only to be discarded.
    """
    import segmentation_models_pytorch as smp

    return smp.Unet(encoder_name=encoder, encoder_weights=None,
                    in_channels=3, classes=NUM_CLASSES)


def load_model(checkpoint: Path, device, encoder: str = "resnet34"):
    """Build and load, or raise. Never silently returns random weights.

    `strict=True` is the guard that matters. The checkpoint was written by
    `segmentation-models-pytorch` 0.5.0; a different minor version can rename decoder submodules,
    and a non-strict load would accept the mismatch, leave those blocks random, and produce
    plausible-looking garbage. Loud failure here is the whole reason `requirements.txt` pins smp to
    an exact version.
    """
    state = torch.load(str(checkpoint), map_location="cpu", weights_only=False)
    model = build_model(encoder)
    model.load_state_dict(state["model"], strict=True)
    return model.to(device).eval()


def _pad_to_multiple(image: np.ndarray, mult: int = 32):
    """Replicate-pad bottom/right up to a multiple of `mult` (a U-Net needs a /32 input).

    `smp.Unet.forward` raises outright on a non-multiple, so this is not an optimisation.
    """
    h, w = image.shape[:2]
    ph, pw = (-h) % mult, (-w) % mult
    if ph or pw:
        image = cv2.copyMakeBorder(image, 0, ph, 0, pw, cv2.BORDER_REPLICATE)
    return image, h, w


def _resize_for_scale(image: np.ndarray, pre_scale_width: int | None):
    """Resample to `pre_scale_width` px of horizontal extent. Returns `(image, applied)`.

    `INTER_AREA` on the way down is not interchangeable with `INTER_LINEAR`: linear decimation
    aliases, and aliased aggregate texture looks exactly like the hairline cracking this model is
    supposed to find.
    """
    if pre_scale_width is None:
        return image, False
    h, w = image.shape[:2]
    scale = pre_scale_width / w
    if abs(scale - 1.0) < 1e-6:
        return image, False
    nh, nw = max(1, int(round(h * scale))), max(1, int(round(w * scale)))
    interp = cv2.INTER_AREA if scale < 1.0 else cv2.INTER_LINEAR
    return cv2.resize(image, (nw, nh), interpolation=interp), True


def _to_tensor(image: np.ndarray, device) -> torch.Tensor:
    """RGB uint8 HWC -> normalised NCHW float32 on `device`."""
    x = (image.astype(np.float32) - _MEAN) * _DENOM
    return torch.from_numpy(x.transpose(2, 0, 1)).unsqueeze(0).to(device)


@torch.no_grad()
def predict_label(model, image: np.ndarray, device,
                  pre_scale_width: int | None = PRE_SCALE_WIDTH) -> np.ndarray:
    """RGB uint8 frame -> uint8 label map in {0,1,2} at the frame's **native** resolution.

    ⚠️ `image` must be **RGB**. `cv2.imread` returns BGR, and feeding that degrades the output
    without erroring — the model still predicts, just worse, on every frame.

    The order is load-bearing and matches upstream exactly: argmax at model resolution, then
    `INTER_NEAREST` back to native. Never resize a label map with anything that interpolates —
    averaging class ids invents classes that were never predicted.
    """
    if image.ndim != 3 or image.shape[2] != 3 or image.dtype != np.uint8:
        raise ValueError(f"expected RGB uint8 HxWx3, got {image.shape} {image.dtype}")

    h, w = image.shape[:2]
    scaled, applied = _resize_for_scale(image, pre_scale_width)
    padded, h0, w0 = _pad_to_multiple(scaled)

    logits = model(_to_tensor(padded, device))
    label = logits.argmax(1)[0].cpu().numpy().astype(np.uint8)[:h0, :w0]

    if applied:
        label = cv2.resize(label, (w, h), interpolation=cv2.INTER_NEAREST)
    return label


def box_pixel_rect(cx: float, cy: float, w: float, h: float,
                   width: int, height: int) -> tuple[int, int, int, int]:
    """Normalised YOLO `xywh` -> half-open pixel rect `(x0, y0, x1, y1)`, clamped to the frame.

    Deliberately the same arithmetic `RoadDamageService.makeFrame` uses to turn a box into a
    `CGRect`, so the number the reviewer reads describes the rectangle the reviewer sees.
    """
    x0 = max(0, int(round((cx - w / 2.0) * width)))
    y0 = max(0, int(round((cy - h / 2.0) * height)))
    x1 = min(width, int(round((cx + w / 2.0) * width)))
    y1 = min(height, int(round((cy + h / 2.0) * height)))
    return x0, y0, x1, y1


def extent_frac(label: np.ndarray, cx: float, cy: float, w: float, h: float) -> float:
    """Fraction of the **whole frame** that is predicted damage inside this box.

    Frame-relative, not box-relative, so it is directly comparable with `area_frac = w * h` and can
    replace it later without changing units (`severity.yaml`'s size term is calibrated in
    fractions-of-frame). Box-relative would read as "how full is this box", a different question.

    A box with no predicted damage inside returns `0.0`, and that is reported as-is. It means the
    detector and the segmenter disagree about this rectangle, which is information the reviewer is
    entitled to see — not a defect to paper over with the box area.
    """
    height, width = label.shape[:2]
    x0, y0, x1, y1 = box_pixel_rect(cx, cy, w, h, width, height)
    if x1 <= x0 or y1 <= y0:
        return 0.0
    window = label[y0:y1, x0:x1]
    hit = int(np.isin(window, DEFECT_CLASSES).sum())
    return hit / float(height * width)
