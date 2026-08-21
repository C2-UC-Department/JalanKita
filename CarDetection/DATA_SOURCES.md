# Training data sources

External datasets used to train `models/signs_crosswalk_v10_hardneg_r3_best.pt`
(the sign/crosswalk detector referenced in [README.md](README.md)). Listed here to satisfy the
attribution terms of the CC BY 4.0 sources below — each entry credits the Roboflow workspace it
came from, per the dataset's own URL.

| Source | Creator (Roboflow workspace) | Images (source total) | License |
|---|---|---|---|
| [Crosswalks](https://universe.roboflow.com/yolo-datasets-f9og9/crosswalks-zn9wq-kfndo) | yolo-datasets-f9og9 | 1,214 | CC BY 4.0 |
| [Dataset Rambu Lalu Lintas](https://universe.roboflow.com/gregorius-nicholas/dataset-rambu-lalu-lintas) | gregorius-nicholas | 813 | Public Domain |
| [Rambu-rambu lalu lintas](https://universe.roboflow.com/project-adas/rambu-rambu-lalu-lintas) | project-adas | 377 | CC BY 4.0 |
| [No Parking Sings](https://universe.roboflow.com/training-model-azvgn/no-parking-sings) | training-model-azvgn | 105 | CC BY 4.0 |
| [Traffic Sign Indonesia 3](https://universe.roboflow.com/kuliah-rwptj/traffic-sign-indonesia-3) | kuliah-rwptj | 1,482 | Public Domain |
| [Traffic sign in Indonesia](https://universe.roboflow.com/umy-35d0e/traffic-sign-in-indonesia) | umy-35d0e | 1,468 | CC BY 4.0 |
| [Traffic Sign in Indonesia Detection](https://universe.roboflow.com/putri-mawaring-wening-lwwcx/traffic-sign-in-indonesia-detection) | putri-mawaring-wening-lwwcx | 4,649 | CC BY 4.0 |

**Modifications:** `signs_crosswalk_v10_hardneg_r3_best.pt` is a custom model fine-tuned on a
merged/filtered subset of the above, not a redistribution of the source datasets themselves.

> ⚠️ The source table had a fifth column cut off in the screenshot this file was built from —
> possibly "images actually used in the training set" (as opposed to the source's total) or a
> per-dataset license link. Fill it in here once you have it.
