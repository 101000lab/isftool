/*{
  "ISFVSN": "2",
  "DESCRIPTION": "Thin lines at random positions, angles and opacities, all re-rolled at once on each tick like random_line.fs. Barcodes are drawn in vertical stripes, horizontal stripes or a grid of squares, centered on the screen with an adjustable size and gap; each stripe or square has its own barcode and the gaps stay empty. Transparent background",
  "CREDIT": "k1low",
  "CATEGORIES": ["Generator"],
  "INPUTS": [
    { "NAME": "layout", "LABEL": "Layout", "TYPE": "long", "DEFAULT": 0, "VALUES": [0, 1, 2], "LABELS": ["Vertical Stripes", "Horizontal Stripes", "Squares"] },
    { "NAME": "gridCols", "LABEL": "Columns", "TYPE": "float", "DEFAULT": 5.0, "MIN": 1.0, "MAX": 32.0 },
    { "NAME": "gridRows", "LABEL": "Rows", "TYPE": "float", "DEFAULT": 5.0, "MIN": 1.0, "MAX": 32.0 },
    { "NAME": "cellGap", "LABEL": "Gap", "TYPE": "float", "DEFAULT": 0.05, "MIN": 0.0, "MAX": 0.5 },
    { "NAME": "cellSize", "LABEL": "Size", "TYPE": "float", "DEFAULT": 0.2, "MIN": 0.02, "MAX": 1.0 },
    { "NAME": "orientation", "LABEL": "Orientation", "TYPE": "long", "DEFAULT": 0, "VALUES": [0, 1, 2], "LABELS": ["Vertical", "Horizontal", "Random per cell"] },
    { "NAME": "angleSpread", "LABEL": "Angle Spread (deg)", "TYPE": "float", "DEFAULT": 30.0, "MIN": 0.0, "MAX": 180.0 },
    { "NAME": "speed", "LABEL": "Speed", "TYPE": "float", "DEFAULT": 1.0, "MIN": 0.0, "MAX": 3.0 },
    { "NAME": "lineCount", "LABEL": "Line Count", "TYPE": "float", "DEFAULT": 150.0, "MIN": 1.0, "MAX": 300.0 },
    { "NAME": "lineWidth", "LABEL": "Line Width (px)", "TYPE": "float", "DEFAULT": 1.0, "MIN": 0.1, "MAX": 6.0 }
  ]
}*/

// Hash without sin() so the pattern is identical across GPUs.
float hash21(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// Places `count` cells of `size` separated by `gap`, centered on 0. Returns
// the cell index, the 0..1 position inside it and whether coord falls in one.
void axisCell(float coord, float count, float size, float gap, out float idx, out float within, out float ok) {
    float total = count * size + (count - 1.0) * gap;
    float l = coord + total * 0.5;
    float pitch = size + gap;
    idx = floor(l / pitch);
    float local = l - idx * pitch;
    within = local / size;
    ok = step(0.0, l) * step(idx, count - 1.0) * step(local, size);
    idx = clamp(idx, 0.0, count - 1.0);
}

void main() {
    vec2 uv = isf_FragNormCoord;
    float aspect = RENDERSIZE.x / RENDERSIZE.y;
    float cols = floor(gridCols + 0.5);
    float rows = floor(gridRows + 0.5);
    vec2 q = (uv - 0.5) * vec2(aspect, 1.0);

    // cell is the cell index, cellUv is 0..1 inside it, inside is 0 in the gaps
    vec2 cell = vec2(0.0);
    vec2 cellUv = uv;
    vec2 cellPx = RENDERSIZE.xy;
    float inside = 1.0;
    float okX = 1.0;
    float okY = 1.0;
    if (layout != 1) {
        axisCell(q.x, cols, cellSize, cellGap, cell.x, cellUv.x, okX);
        cellPx.x = cellSize * RENDERSIZE.y;
    }
    if (layout != 0) {
        axisCell(q.y, rows, cellSize, cellGap, cell.y, cellUv.y, okY);
        cellPx.y = cellSize * RENDERSIZE.y;
    }
    inside = okX * okY;

    bool horizontal = orientation == 1 || (orientation == 2 && hash21(cell + 91.7) > 0.5);
    // Work in a frame where the lines always run along v
    vec2 c = horizontal ? cellUv.yx : cellUv;
    vec2 framePx = horizontal ? cellPx.yx : cellPx;
    vec2 p = c * framePx;

    // Speed 1.0 re-rolls 10 times per second, same as random_line.fs
    float frame = mod(floor(TIME * speed * 10.0), 4096.0);
    float n = 0.0;

    for (int i = 0; i < 300; i++) {
        if (float(i) >= lineCount) break;
        vec2 id = vec2(float(i) + cell.x * 300.0, frame + cell.y * 4096.0);
        float x = hash21(id + vec2(0.0, 1.1));
        float center = hash21(id + vec2(0.0, 2.2));
        float opacity = hash21(id + vec2(0.0, 4.4));

        // Lines are not shortened; the cell edge is what clips them
        // Each line is tilted around its own center
        float ang = (hash21(id + vec2(0.0, 5.5)) - 0.5) * radians(angleSpread);
        vec2 dir = vec2(-sin(ang), cos(ang));
        vec2 d = p - vec2(x, center) * framePx;
        float distPx = abs(d.x * dir.y - d.y * dir.x);
        float a = 1.0 - smoothstep(lineWidth * 0.5, lineWidth * 0.5 + 1.0, distPx);
        n = max(n, a * opacity);
    }
    n *= inside;

    // RGB must be 0 where alpha is 0 (VDMX treats the output as premultiplied)
    gl_FragColor = vec4(vec3(step(0.00001, n)), n);
}
