# Fixtures

| File | Source |
|---|---|
| `line_space.fs` | A shader with a persistent buffer that passes in VDMX |
| `line_space_layout.fs` | An earlier `line_space.fs` that VDMX rejects. Uses `layout` as a variable name |
| `thin_barcode_layout.fs` | A shader that VDMX rejects. Uses `layout` as an input name |
| `super_polygons_vertex.fs` | A shader that VDMX rejects. Defines a function named `vertex` |
| `vdmx_line_space.vert.glsl` | design.md 3.1, copied from VDMX's error screen for `line_space_layout.fs` |
| `vdmx_line_space.frag.glsl` | design.md 3.2 with the uniform block filled in. VDMX's fragment preamble, the shader body follows it |
| `orientation.fs` | Written for isftool. Red on the right half, green on the top half, blue from the `Tint` input |
| `persistent_orientation.fs` | Written for isftool. Keeps a white top half in a persistent buffer, read through IMG_THIS_PIXEL and IMG_NORM_PIXEL |
| `imported_orientation.fs` | Written for isftool. Shows `top_white.png` through IMG_NORM_PIXEL and IMG_PIXEL |
| `top_white.png` | 8x8, top half opaque white, bottom half transparent |
| `float_accumulate.fs` / `byte_accumulate.fs` | Written for isftool. Accumulate 0.001 per frame in a FLOAT and an 8 bit persistent buffer |
| `float_output.fs` | Written for isftool. A FLOAT last pass at half width, which has to be copied into the 8 bit output |
| `empty.fs` | Written for isftool. Outputs transparent black, for the floor of bench |
