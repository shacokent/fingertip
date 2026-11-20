# Nail segmentation model attribution

Source: https://huggingface.co/nngeek195/nail-segmentation-v1
Author identifier: nngeek195
Checkpoint: model/nail_segmentation_model-01.pt
Declared upstream license: MIT (model-card YAML metadata).
The upstream snapshot did not contain a separate LICENSE file. The model card
and data notice are retained verbatim alongside this notice.

The ONNX file included with this demo is a format-only conversion of the
upstream trained tensor state, using the same U-Net architecture and inference
normalization. The mobile runtime uses Dart image Interpolation.average as an
approximation of the upstream PIL bilinear downsampling; the numerical export
validation itself uses the PIL-prepared reference input. No claim of model
ownership or production accuracy is made.

The bundled example photo originates from the same upstream repository. The
repository's ethics.txt identifies the training data as Muhammad Hammad's
Kaggle Nail Segmentation Dataset and declares its terms CC0. The Kaggle public metadata API independently lists the dataset license as
"CC0: Public Domain"; its relevant metadata is preserved in
DATASET_LICENSE_METADATA.json.

This experimental model may miss nails, include skin, or fail under different
lighting/poses. Allow users to inspect and correct the result.
