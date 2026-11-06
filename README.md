# isftool

Check, render and benchmark [ISF](https://isf.video) shaders on macOS through the same path VDMX6 takes: VIDVOX's ISFGLSLGenerator writes the GLSL, glslang turns it into SPIR-V, SPIRV-Cross turns that into Metal, and Metal draws it the way VIDVOX's ISFMSLScene does.

A WebGL preview runs a different compiler and a different GPU API, so it cannot show two things that matter in VDMX. isftool shows both.

- Whether a shader compiles in VDMX at all. Metal keywords such as `level` break a shader that WebGL accepts.
- How much GPU time a shader takes per frame, with its inputs at their defaults, or fed an envelope of VDMX's Audio Analysis, or at their maximum.

## Install

**homebrew tap:**

```console
$ brew install k1LoW/tap/isftool
```

The release binary is for Apple Silicon and needs macOS 14 or later. glslang and SPIRV-Cross are built in, so nothing else is needed.

**From source:**

Building needs Swift 6 (Xcode or the Command Line Tools).

```console
$ git clone --recursive https://github.com/101000lab/isftool.git
$ cd isftool
$ swift build -c release
$ cp .build/release/isftool /usr/local/bin/
```

ISFGLSLGenerator, glslang and SPIRV-Cross are git submodules under `Vendor/`. If you cloned without `--recursive`, run `git submodule update --init` before building.

## Usage

### check

Compiles a shader to Metal and reports the first stage that fails (`parse`, `glsl`, `spirv-cross`, `metal` or `unbound`, the last one for a Metal function argument the ISF host cannot fill, such as a `uniform` the shader declares itself). The exit code is 1 when the shader fails.

```sh
isftool check shaders/line_space.fs
isftool check --json shaders/super_polygons_vertex.fs
```

```
ok    shaders/line_space.fs  (parse 0ms, glsl 14ms, spirv_cross 1ms, metal 0ms)
FAIL  shaders/super_polygons_vertex.fs  [metal frag] program_source:126:15: error: expected unqualified-id
float2 vertex(thread const float& column, thread const float& row, constant VVISF_UNIFORMS& _277, texture2d<float> vertexPositions, sampler vertexPositionsSmplr)
              ^
```

To check many shaders, run it once per shader, for example `find shaders -name '*.fs' | xargs -n 1 isftool check`.

### render

Draws frames to PNG. Frames before `--at` are drawn too, so persistent buffers have filled up by the first frame written.

```sh
isftool render shaders/line_space.fs --out line_space.png --at 5
isftool render shaders/ripples.fs --out frames/ --frames 120 --feed-envelope --set Switch=5
```

With more than one frame, `--out` is a directory and the files are named `<shader>_00000.png` and so on.

### bench

Measures the GPU time of each frame of a shader.

```sh
isftool bench shaders/line_space.fs --size 1280x720 --repeat 3
isftool bench shaders/ripples.fs --size 1280x720 --feed-envelope
```

```
  shader                 mode     median   p95  passes  spread  vs prev  note
  shaders/line_space.fs  default    0.17  0.24       2    4.6%
```

Without `--feed-envelope` the shader is measured once with every input at its DEFAULT value. With it, the inputs matching `--feed-envelope-pattern` are measured in three modes.

| Mode | Matched inputs |
|---|---|
| `default` | their DEFAULT values |
| `envelope` | the envelope, one band per input in definition order, wrapping around after the last band |
| `max` | their MAX values |

The envelope is the per-band loudness of VDMX's Audio Analysis on a microphone, 16 bands for 30 seconds, built into isftool. Each band holds its last value until the next one, and the envelope loops. The value is scaled from 0 to 1 onto the input's MIN to MAX. `render --feed-envelope` draws with the envelope too.

`--feed-envelope-pattern` is a regular expression for Float input names, by default `^(Level|Lv)(?![a-z]|Gain$)`. `info` marks the matched inputs with `[envelope]`. `--set NAME=VALUE` is applied after the mode, so it can pick a variant of a shader that has a switch.

Every result is appended to `.isftool/results.jsonl`. The next run compares each row with the latest earlier result for the same shader path, size, mode and frame count, and prints the change in the `vs prev` column. The path is compared as given, so run bench from the same directory to compare runs.

### info and dump

`info` lists inputs, pass sizes, the uniform layout and the Metal argument indices. `dump` prints one generated artifact, for example the GLSL to diff with VDMX's error screen or the Metal source.

```sh
isftool info shaders/line_space.fs
isftool dump shaders/super_polygons_vertex.fs msl-frag
```

`--keep-intermediates DIR` saves every generated GLSL, SPIR-V and Metal file.

## Reading the numbers

- A number is the GPU time of one frame of this shader alone, from the start to the end of its command buffer. It does not include VDMX's compositing, layer effects or Syphon output, so it is not VDMX's frame rate. Use it to rank shaders and to compare a shader before and after a change.
- `median` is the median frame and `p95` the 95th percentile frame. With `--repeat N`, `median` is the median of the repeats' medians and `spread` is the range of those medians as a percentage of it.
- `!` marks a median over 8.33 ms (120 fps) and `!!` one over 16.67 ms (60 fps).
- A shader that draws more when the sound is loud is only heavy in `envelope` or `max` mode. In `default` mode most of its matched inputs are 0 and many shaders skip their drawing, so `default` alone makes them look light.
- A large gap between `median` and `p95` usually means the cost changes over time, for example as a persistent buffer fills up or the envelope gets loud.

## Limits

- glslang and SPIRV-Cross are built in at the commits VDMX6 Plus 6.1.3.6 ships, and give the same SPIR-V and Metal source as VDMX's copies, byte for byte, on over 400 shaders. `isftool --version` shows them. A later VDMX may ship other versions.
- Image, audio and audioFFT inputs get a blank 64x64 texture, as ISFMSLScene gives when no source is connected. bench notes these shaders in the `note` column.
- Cube inputs are not supported.
- GPU clocks drop when the Mac gets hot. For long runs use `--repeat` and check that `spread` stays small.

## Benchmarking a collection

Run bench once per shader, from the same directory every time so each run is compared with the previous one. Every result goes to `.isftool/results.jsonl`, so a ranking across shaders can be read from there.

```sh
find isfs -name '*.fs' | xargs -n 1 isftool bench --size 1280x720
```

A full run takes a while, since every shader is checked first and then drawn for `--warmup` plus `--frames` frames in each mode. Lower both for a quick ranking.
