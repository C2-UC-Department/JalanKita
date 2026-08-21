# Third-party notices

JalanKita's own code is proprietary (see [LICENSE](LICENSE)). It also bundles, depends on, or was
trained using the third-party models, libraries, and datasets listed below. Each of these carries
its own license, independent of JalanKita's — using or redistributing this repository does not
grant any rights to them beyond what their own upstream license allows. **Verify current terms with
each upstream project before any public release, redistribution, or commercial use of this
repository.**

## Needs attention: AGPL-licensed models

- **Ultralytics YOLO** (`yolov8n-seg.pt` in `CarDetection/`, the sign/crosswalk detector base
  architecture, and the `YOLO11s` road-damage detector in `RoadDamage/`) — licensed AGPL-3.0 by
  Ultralytics, or available under a paid Ultralytics Enterprise License for organizations that
  can't comply with AGPL's terms (which include a requirement to open-source any application that
  uses the model over a network, among other conditions). This is the one item on this list with
  direct, immediate legal weight for how JalanKita as a whole can be distributed or operated — get
  this resolved (Enterprise license, or an AGPL-compliant distribution plan) before shipping to
  anyone outside the team.

## Other bundled/used components

Listed by name and where they're used — check each project's own repository for its current
license text rather than relying on a paraphrase here:

- **ByteTrack** — multi-object tracking, used in `CarDetection/pipeline_v13.py`.
- **YOLOP** — road segmentation, auto-downloaded via `torch.hub` by `CarDetection/`.
- **MiDaS / MiDaS_small** (Intel ISL) — monocular depth, auto-downloaded via `torch.hub`, used in
  `CarDetection/depth/` and as a tiebreaker signal in the parked-status decision.
- **Mask2Former** — semantic/instance segmentation, used in `PythonWorker/` for scene understanding.
- **Depth-Anything-V2** — monocular depth estimation, used in `PythonWorker/` (note: this project
  publishes some model sizes under Apache-2.0 and others under a non-commercial license — confirm
  which checkpoint variant is actually in use here before assuming either).

## Datasets used for training/evaluation, not bundled as code

- **KITTI Road** (Karlsruhe Institute of Technology) — public road-segmentation dataset, part of
  the training data for the OFRSNet road-reconstruction model (`PythonWorker/`). KITTI's benchmark
  data has historically been released for non-commercial research use — confirm this covers the
  intended use of any model trained on it.
- **RDD2022 (Road Damage Dataset 2022)** — Japan + India subset, used to train the road-damage
  YOLO11s detector in `RoadDamage/`.
- **Roboflow community datasets** — 7 combined public datasets used to train the sign/crosswalk
  detector in `CarDetection/` (crosswalks; Dataset Rambu Lalu Lintas; Rambu-rambu lalu lintas; No
  Parking Sings; Traffic Sign Indonesia 3; Traffic sign in Indonesia; Traffic Sign in Indonesia
  Detection). Each Roboflow Universe dataset sets its own license individually — check each one's
  page on Roboflow Universe rather than assuming a shared default.

## Custom-trained models (JalanKita's own weights)

- `CarDetection/models/signs_crosswalk_v10_hardneg_r3_best.pt` — sign/crosswalk detector, trained
  on the Roboflow-derived dataset above.
- `PythonWorker/checkpoints/ofrsnet_best.pt` — OFRSNet, trained on KITTI Road + own street footage.
- `RoadDamage/models/server_trained.pt` — road-damage detector, trained on RDD2022.
- `RoadDamage/models/unet_resnet34.pt` — defect-extent segmentation model.

These are JalanKita's own trained weights (covered by [LICENSE](LICENSE)), but their *architectures*
and any base/pretrained weights they were fine-tuned from still carry the upstream licenses noted
above.
