# Window 9 Simulator CPU adapter

These patches select genuine upstream MLX CPU allocation, synchronization and operations in
iOS Simulator. They do not emulate model output or change the checkpoint. Mac and physical
iOS targets retain their upstream Metal backend. Physical devices have not been tested.

Pinned sources:

- `mlx-swift` 0.32.3, `19601207e9a0de51e03ee6ec0c3c5f3784275075`.
- `mlx-swift-lm` 3.32.3, `3b339ad6e3b3f44c8121ecff5131c7fd55e075e6`.

Run from the Window 9 worktree before resolving or building the app/Qwen package:

```sh
python3 tools/prepare_qwen_runtime.py --checkouts /Users/vicwei/Library/Developer/Xcode/DerivedData/HearingSense-atnppvsqqyobzydcyysiplnfhywb/SourcePackages/checkouts
```

`--checkouts` must contain existing repositories at those revisions, including their initialized
vendored submodules. Another existing Xcode `SourcePackages/checkouts` folder can be supplied.
The script exports the exact committed objects recursively and patches the exports. It never
changes the source cache, downloads weights, or includes weights in the generated dependencies.
`packages/RuntimeDependencies/` is ignored; commit the preparation script and patches instead.
Each export records its revision, patch hash, combined adapter hash (including the native
helper) and source-tree hash. A repeat run verifies the export and refuses an unknown or edited
directory. After a deliberate adapter update, `--refresh` verifies the old export before
replacing changed source files in place; it preserves unchanged files and build metadata.

The MLX adapter covers availability, GPU device discovery, allocation, events and fences.
Merely setting the default device to CPU is insufficient: the Apple build otherwise allocates
Metal heaps and shared events even for CPU evaluation. GPU event implementation symbols remain
available to unused compiled Metal code, while Simulator evaluation uses upstream CPU events.
Qwen's gated delta computation selects the existing operations implementation whenever the
default device is CPU; it cannot instantiate the custom Metal kernel on that path.

Simulator affine 4-bit/group-64 matrix multiplication uses `hs_affine_q4.h`. Prefill unpacks
each matrix once into temporary float32 storage and calls the upstream Accelerate matmul;
single-token decode reads the packed weights directly with native vector operations. Both
accumulate in float32 and restore the promoted output dtype. This avoids scalar bfloat16
accumulation and repeated broadcast copies of packed weights. Expanded weights are not written
to disk or retained as a second model. Native temporary vectors are outside MLX's memory
counter, so its reported peak is not the application's full resident memory. iOS Debug C++
dependencies use `-O3` without fast-math; the
app remains Debug and its synthetic self-test is available. Release optimization is unchanged.
Large Simulator float32 matrix products split independent output columns across four native
workers; each BLAS call retains the original leading dimensions and dot products. This bounded
pool avoids the single-worker bottleneck observed in Simulator BLAS. Matrix tests cover both
transposed and contiguous inputs. Simulator prefill uses 64-token chunks to check cancellation
more frequently; Mac/device prefill remains upstream default.

The application rejects a Simulator backend that still reports GPU before loading any arrays.
The tiny Simulator array tests catch the earlier allocation/event crashes; the running-app
runtime probe additionally exercises the real cached Qwen checkpoint and parses a real summary.
This is a project-maintained compatibility adapter, not upstream MLX Simulator GPU support.
