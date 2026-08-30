MobileNetV2 integration

Steps to obtain and add MobileNetV2 (Core ML) to the app bundle:

1. Download a MobileNetV2 Core ML model

- Option A: Apple's Model Gallery / Create ML / third-party sources may provide MobileNet variants in .mlmodel or .mlmodelc format.
- Option B: Convert a TensorFlow/Keras MobileNetV2 to Core ML using `coremltools` (Python).

Example conversion (requires Python and coremltools):

```bash
python -m pip install coremltools
python convert_mobilenetv2.py
```

Where `convert_mobilenetv2.py` might contain:

```python
import coremltools as ct
from tensorflow.keras.applications import MobileNetV2

model = MobileNetV2(weights='imagenet')
# example input shape (1,224,224,3) - adjust if needed
example_input = ct.ImageType(shape=(1,224,224,3))

mlmodel = ct.convert(model, inputs=[example_input])
mlmodel.save('MobileNetV2.mlmodel')
```

2. Add the model to the Xcode project

- Drag `MobileNetV2.mlmodel` into your Xcode project (usually under the `Models/` group). Xcode will compile it into `MobileNetV2.mlmodelc` automatically at build time.

3. Confirm the model is bundled

- After building the app, confirm that `MobileNetV2.mlmodelc` exists in the app bundle.

4. Usage

- The `OptimizedImageRecognizer` has a convenience initializer that will automatically attempt to load `MobileNetV2` from the main bundle:

```swift
let recognizer = OptimizedImageRecognizer() // will try to load MobileNetV2 if present
```

- Alternatively, explicitly provide the model URL:

```swift
if let url = Bundle.main.url(forResource: "MobileNetV2", withExtension: "mlmodelc") {
    let recognizer = OptimizedImageRecognizer(coreMLModelURL: url)
}
```

Notes:
- To ensure Neural Engine usage, Xcode will build the model; however you should also set `MLModelConfiguration().computeUnits = .all` when loading programmatically (the recognizer does this for you).
- If you cannot bundle a model, the recognizer falls back to Vision's `VNClassifyImageRequest` (system classifier), but you will not be able to control hardware selection in that case.

Troubleshooting:
- If the model fails to load, ensure the compiled `.mlmodelc` is present in the built app bundle (check `Products` → `Show in Finder` and inspect `*.app/` contents).
- For large models, ensure App Thinning and size constraints are considered.
