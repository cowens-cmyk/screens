# Metal

Everything that goes on a screen or out a cable is drawn by one
`Compositor` (RenderEngine) on one command queue. Display windows and
previews present through `CAMetalLayer`; NDI and DeckLink feeds
(`OutputMirror`) render into their own textures and hand on IOSurface pixel
buffers. Text is drawn on the CPU (`TextRasterizer`) and uploaded; the
DeckLink helper converts to YUV on the CPU (`decklink_shim.cpp`).

## Command buffers

Every command buffer is made by `GPUFaults.makeCommandBuffer(on:label:)`:

- **Named** (`compositor.render.texture`, `compositor.present.drawable`,
  `outputEngine.mirror.gpuConvert`…), and so are the encoders and render
  targets, so a Metal System Trace or a frame capture says which work it was.
- **Checked.** A command buffer the GPU failed is written to Diagnostics as
  `gpu.error` with its name and the error: the first five, then one in a
  hundred. On screen a fault shows only as a black or stale frame. With
  `MTL_DEBUG_LAYER=1` the buffer also asks for each encoder's status, and
  the line names the encoder that faulted.

## Feeds

A feed's frame is one submission. `OutputMirror` takes a pool buffer first
(`PixelBufferConverter.directFrame`), and the compositor encodes the SDR
conversion (linear half-float Display P3 to 8-bit BGRA, `GPUFrameConverter`)
into the render's own command buffer (`encodingAfter:`). The completion hands
the buffer on; nothing waits on the GPU. It used to be a second command
buffer per frame with `waitUntilCompleted` on the feed's queue. In
`perf.pulse`, a feed's "convert avg" is now the whole frame's GPU time
(render and conversion). HLG feeds still convert on the CPU.

The converter's kernel is compiled once per GPU and shared by every feed.

## State

`Compositor.setPipeline(_:on:)` sets a pipeline only when it differs from
the one last set on that encoder. Every pipeline set in the compositor goes
through it, and it runs under `encodeLock` (the two `present` calls take it
too). Metal's validation layer counted about 300 redundant sets across the
RenderEngine tests before.

## Validation

```bash
apps/mac/scripts/perf/metal-validate.sh            # RenderEngine, OutputEngine, MediaEngine
apps/mac/scripts/perf/metal-validate.sh RenderEngine
```

Runs the packages' tests with API validation (`MTL_DEBUG_LAYER`) and shader
validation (`MTL_SHADER_VALIDATION`), fails on any validation error, and
counts the layer's performance warnings by kind. Logs go to
`~/Library/Caches/mxu-slides-perf/metal-validate/`. Clean as of 0.38.3.

The app itself, sandboxed with its own library and no network, under the
same layers:

```bash
MXU_PERF_BUILD_ONLY=1 apps/mac/scripts/perf/run.sh <commit>
MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 apps/mac/scripts/perf/present.sh <commit>
```

A GPU trace of the same run: `xcrun xctrace record --template 'Metal System
Trace' --attach <pid> --time-limit 10s --output <file>.trace`, then
`xcrun xctrace export --input <file>.trace --toc` to see its tables. Never
run either against the live church library.

The shaders are compiled from source at launch (`ShaderSource.metal`,
`GPUFrameConverter.source`): about 0.5 s the first launch after an update,
about 1 ms after that from Metal's cache. To check them with every warning:
extract the string and `xcrun -sdk macosx metal -c -Weverything
-Wno-c++98-compat -Wno-c++98-compat-pedantic file.metal -o /dev/null`. What's
left is the old `vertex`/`fragment` keyword style and one unused `in`.
