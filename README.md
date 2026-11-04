# isftool

Check, render and benchmark [ISF](https://isf.video) shaders on macOS through the same path VDMX6 takes: VIDVOX's ISFGLSLGenerator writes the GLSL, glslang turns it into SPIR-V, SPIRV-Cross turns that into Metal, and Metal draws it the way VIDVOX's ISFMSLScene does.

A WebGL preview runs a different compiler and a different GPU API, so it cannot show two things that matter in VDMX. isftool shows both.

- Whether a shader compiles in VDMX at all. Metal keywords such as `level` break a shader that WebGL accepts.
- How much GPU time a shader takes per frame, with Level inputs at their defaults, at their maximum, or driven by a recording of VDMX's Audio Analysis.

## Requirements

- macOS 14 or later on a Mac with Metal.
- Swift 6 (Xcode or the Command Line Tools).
- glslang and spirv-cross on `PATH`, or given with `--glslang` and `--spirv-cross`.

```sh
brew install glslang spirv-cross
```

## Install

```sh
git clone --recursive https://github.com/101000lab/isftool.git
cd isftool
swift build -c release
cp .build/release/isftool /usr/local/bin/
```

ISFGLSLGenerator is a git submodule under `Vendor/`. If you cloned without `--recursive`, run `git submodule update --init` before building.

## Usage

### check

Compiles shaders to Metal and reports the first stage that fails (`parse`, `lint`, `glsl`, `spirv-cross`, `metal` or `unbound`, the last one for a Metal function argument the ISF host cannot fill, such as a `uniform` the shader declares itself). The exit code is 1 when any shader fails.

```sh
isftool check isfs/**/*.fs
isftool check --json isfs/depth/nested_frames_3d.fs
```

```
ok    isfs/lines/line_space.fs  (parse 1ms, glsl 174ms, spirv_cross 142ms, metal 2ms)
FAIL  isfs/depth/nested_frames_3d.fs  [metal frag] program_source:110:21: error: reference to 'level' is ambiguous
```

The `lint` stage catches names that the Homebrew SPIRV-Cross leaves alone but that clash with Metal. `--no-lint` turns it off.

### render

Draws frames to PNG. Frames before `--at` are drawn too, so persistent buffers have filled up by the first frame written.

```sh
isftool render isfs/lines/line_space.fs --out line_space.png --at 5
isftool render isfs/geometry/ripple_shapes.fs --out frames/ --frames 120 --levels max --set Switch=5
```

With more than one frame, `--out` is a directory and the files are named `<shader>_00000.png` and so on.

### bench

Measures the GPU time of each frame and ranks the shaders, slowest first.

```sh
isftool bench isfs/systems/*.fs --size 1280x720
isftool bench --from list.txt --recording recordings/vdmx_mic.jsonl --repeat 3
```

```
    shader                           mode       median    p95  passes  vs prev  note
!!  isfs/systems/randomgravities.fs  max         30.48  32.97       1
!   isfs/depth/line_cloud_3d.fs      max         12.37  13.34       1
    isfs/sprites/fullmoon.fs         max          0.15   0.16       1           audio: blank texture
```

Each shader is measured in every mode given by `--modes`. The default is `default,max`, plus `recording` when `--recording` is given.

| Mode | Level inputs |
|---|---|
| `default` | their DEFAULT values |
| `max` | their MAX values |
| `recording` | the recording's `/Filter N` channels, assigned in definition order and wrapping around after the last channel |

A recording is JSON Lines of `{"t": seconds, "address": "/Filter 3", "value": 0.0 to 1.0}`, such as VDMX's Audio Analysis values captured over OSC. Each channel holds its last value until the next one, and the recording loops. The value is scaled from 0 to 1 onto the input's MIN to MAX.

Level inputs are Float inputs whose names match `--level-pattern` (default `^(Level|Lv)(?![a-z]|Gain$)`). `--set NAME=VALUE` is applied after the mode, so it can pick a variant of a shader that has a switch.

Every result is appended to `.isftool/results.jsonl`. The next run compares each row with the latest earlier result for the same shader path, size, mode and frame count, and prints the change in the `vs prev` column. The path is compared as given, so run bench from the same directory to compare runs.

### info and dump

`info` lists inputs, pass sizes, the uniform layout and the Metal argument indices. `dump` prints one generated artifact, for example the GLSL to diff with VDMX's error screen or the Metal source.

```sh
isftool info isfs/lines/line_space.fs
isftool dump isfs/depth/nested_frames_3d.fs msl-frag
```

`--keep-intermediates DIR` saves every generated GLSL, SPIR-V and Metal file.

## Reading the numbers

- A number is the GPU time of one frame of this shader alone, from the start to the end of its command buffer. It does not include VDMX's compositing, layer effects or Syphon output, so it is not VDMX's frame rate. Use it to rank shaders and to compare a shader before and after a change.
- `median` is the median frame and `p95` the 95th percentile frame. With `--repeat N`, `median` is the median of the repeats' medians and `spread` is the range of those medians as a percentage of it.
- `!` marks a median over 8.33 ms (120 fps) and `!!` one over 16.67 ms (60 fps).
- A shader that draws more when the sound is loud is only heavy in `max` or `recording` mode. In `default` mode most Level inputs are 0 and many shaders skip their drawing, so `default` alone makes them look light.
- A large gap between `median` and `p95` usually means the cost changes over time, for example as a persistent buffer fills up or a recording gets loud.

## Limits

- isftool uses the Homebrew glslang and SPIRV-Cross, while VDMX uses older versions modified by VIDVOX. Most shaders come out the same, but a name that one version renames and the other does not can compile here and fail in VDMX. The `lint` stage covers the cases found so far.
- Image, audio and audioFFT inputs get a blank 64x64 texture, as ISFMSLScene gives when no source is connected. bench notes these shaders in the `note` column.
- Cube inputs are not supported.
- Shaders with a custom vertex shader (`.vs`) compile and render, but the lint does not look at the `.vs`.
- GPU clocks drop when the Mac gets hot. For long runs use `--repeat` and check that `spread` stays small.

## Benchmarking a collection

Pass the shaders with `--from`, one path per line, and run bench from the same directory every time so each run is compared with the previous one.

```sh
find isfs -name '*.fs' | isftool bench --from - --size 1280x720
```

A full run takes a while, since every shader is checked first and then drawn for `--warmup` plus `--frames` frames in each mode. Lower both for a quick ranking.
