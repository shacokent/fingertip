# Bundled experimental nail-segmentation model

`nail_segmentation.onnx` is a real trained U-Net checkpoint converted to ONNX,
not a placeholder or a hand-template mask. Upstream model card declares MIT.
Attribution, source revision and dataset statements are retained under
`third_party/nail_model/`.

## Tensor contract

* Input name: `image`
* Input type/shape: float32, `[1, 3, 128, 128]`, NCHW
* Input image: the complete RGB working image, stretched to 128 × 128, no letterbox
* App runtime resize: Dart `package:image` `Interpolation.average`
* Upstream inference/conversion-validation reference: PIL `Image.Resampling.BILINEAR`
* Per-channel normalization: `(channel / 255.0 - 0.5) / 0.5`
* Output name: `probabilities`
* Output type/shape: float32, `[1, 1, 128, 128]`
* Sigmoid is already included; do not apply it again
* Runtime V2 candidate probability threshold: 0.38
* Component cleanup in each view and after fusion: at least 3 mask pixels,
  mean foreground probability at least 0.57, and no component larger than
  8% of the model mask; users must still inspect and correct the result

## Runtime V2: free-pose, two-view inference

The model weights and 128 × 128 tensor shape are unchanged. The App runs the
complete prepared image twice: at 0° and 180°. Reversing each 16,384-element
NCHW color plane gives the 180° input; reverse the corresponding 16,384 output
probabilities to align them with the original image.

For each view, eight-connected foreground components use threshold 0.38,
minimum mean probability 0.57, minimum area 3 model pixels and maximum area
8% of the model mask. Rejected components are set to zero. The retained maps
are inverse-aligned and fused by pixelwise maximum, followed by the same
component filter. Overlapping tiles and four-way rotation are not enabled.

Hand landmarks are a best-effort aid for naming and direction. A candidate is
not discarded merely because no hand is found, fingertip matching is uncertain,
or another candidate has the same nearest fingertip. Up to 12 regions may be
shown; there is no enforced five-finger template or fixed pose. Missing nails
must still be added/corrected by the user rather than synthesized.

On nine upstream examples, a Python PIL BOX approximation to the runtime
area-average preprocessing gave mean pixel Dice 0.570 → 0.690 and GT-component
coverage recall 0.578 → 0.711 versus the previous single-view filtering. No
false components were measured for the selected configuration on those nine
examples; black, white, gray and seeded-noise sanity inputs retained no regions.
These parameters were explored on the same examples: the figures are **not an
independent recognition-accuracy benchmark**, calibrated confidence, or a
promise of complete detection. Coverage recall here only requires covering
20% of a supplied GT component and is not detection AP. Short bare nails still
have substantial misses.

The experiment used PIL BOX as a practical approximation to Dart
`Interpolation.average`; the inputs are not claimed to be pixel-identical.
Historical PyTorch/ONNX parity and original reference metrics still use PIL
bilinear, as documented below. Method, per-image measurements, alternative
rotation/tile results and negative checks are archived in
`third_party/nail_model/RECALL_VALIDATION_V2.json`.

## Runtime preprocessing versus reference validation

The App bakes EXIF orientation into the image and reduces images whose longer
edge exceeds 1600 pixels using `Interpolation.average`. It then uses the same
area-average option to stretch the complete working RGB image to 128 × 128.
The tensor contract, channel normalization and output interpretation are
unchanged.

The upstream inference code and this export's PyTorch/ONNX numerical comparison
use PIL bilinear downsampling. PIL's scale-aware bilinear downsampling is not
equivalent to Dart's `Interpolation.linear`; the App deliberately uses
`Interpolation.average` as a closer approximation. It is still not a
pixel-identical implementation of PIL.

Dart image 4.12.0 was compared on nine upstream photos against the PIL-prepared
reference. Mean input absolute error in 8-bit channel units was 1.15 for area
averaging versus 4.23 for Dart linear; average binary-mask Dice **agreement with
the reference implementation** at threshold 0.5 was 0.929 versus 0.802. These
numbers measure preprocessing consistency, not recognition accuracy on an
independent test set. Details are retained in
`third_party/nail_model/PREPROCESS_VALIDATION.json` and in the manifest's
`runtimePreprocess` and `preprocessComparison` fields. All historical
`experiments` entries in the manifest use the PIL reference resizer.

The model is semantic segmentation: it does not output finger identities,
handedness, three-dimensional nail shape or nail length. It was validated at
128 × 128. Increasing the input size without retraining materially worsened the
provided examples, so do not silently change it to 256 × 256.

## Validation and limitations

ONNX checker passed. ONNX Runtime CPU was compared against the loaded PyTorch
state and maximum absolute output error was below 0.000002. Exact hashes and
environment-side observations are in `model_manifest.json`.

The nine upstream photos are examples/training material, not an independent
test set. The model misses nails and sometimes selects skin or background.
The application must present it as experimental, support manual correction,
and avoid claiming production segmentation accuracy.

`assets/samples/hand.jpg` is the upstream `nail_test_001636.jpg`. The source
repository's `ethics.txt` declares its dataset CC0; the original statement is
included in the attribution directory.
