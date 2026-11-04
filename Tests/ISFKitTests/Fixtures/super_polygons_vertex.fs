/*{
  "ISFVSN": "2",
  "DESCRIPTION": "Projected, noise-deformed supershape wireframe based on vuos/super_polygons.vuo by vidbeat. Uses the superformula and original controls, with approximate value noise and perspective. All edges are visible. Wireframe rendering is capped at 640 pixels wide before upscaling.",
  "CREDIT": "Based on vidbeat's super_polygons Vuo composition (2020); ISF adaptation by k1low",
  "CATEGORIES": ["Generator"],
  "INPUTS": [
    { "NAME": "Lobes", "TYPE": "float", "DEFAULT": 16.0, "MIN": 0.0, "MAX": 16.0 },
    { "NAME": "Exponent", "TYPE": "float", "DEFAULT": 6.6, "MIN": 0.0, "MAX": 10.0 },
    { "NAME": "ShowThirdEdge", "LABEL": "Triangle diagonals", "TYPE": "bool", "DEFAULT": true },
    { "NAME": "NoiseSpeed", "LABEL": "Noise speed", "TYPE": "float", "DEFAULT": -0.1475, "MIN": -0.25, "MAX": 10.0 },
    { "NAME": "NoiseScale", "LABEL": "Noise scale", "TYPE": "float", "DEFAULT": 0.5, "MIN": 0.1, "MAX": 0.5 },
    { "NAME": "Color", "TYPE": "color", "DEFAULT": [1.0, 1.0, 1.0, 1.0] },
    { "NAME": "LineWidth", "LABEL": "Line width", "TYPE": "float", "DEFAULT": 0.25, "MIN": 0.0, "MAX": 1.0 },
    { "NAME": "Scale", "LABEL": "Depth", "TYPE": "float", "DEFAULT": 0.15, "MIN": -0.5, "MAX": 0.5 },
    { "NAME": "Rows", "TYPE": "float", "DEFAULT": 20.0, "MIN": 4.0, "MAX": 20.0 },
    { "NAME": "Columns", "TYPE": "float", "DEFAULT": 20.0, "MIN": 4.0, "MAX": 20.0 }
  ],
  "PASSES": [
    { "TARGET": "vertexPositions", "WIDTH": "20", "HEIGHT": "20" },
    { "TARGET": "wireImage", "WIDTH": "min($WIDTH, 640)", "HEIGHT": "max(1, floor($HEIGHT * min(1, 640 / $WIDTH)))" },
    {}
  ]
}*/

float hash(vec3 point) {
    return fract(sin(dot(point, vec3(127.1, 311.7, 74.7))) * 43758.5453);
}

float noise(vec3 point) {
    vec3 cell = floor(point);
    vec3 t = fract(point);
    t = t * t * (3.0 - 2.0 * t);
    return mix(mix(mix(hash(cell), hash(cell + vec3(1, 0, 0)), t.x),
                   mix(hash(cell + vec3(0, 1, 0)), hash(cell + vec3(1, 1, 0)), t.x), t.y),
               mix(mix(hash(cell + vec3(0, 0, 1)), hash(cell + vec3(1, 0, 1)), t.x),
                   mix(hash(cell + vec3(0, 1, 1)), hash(cell + vec3(1, 1, 1)), t.x), t.y), t.z) * 2.0 - 1.0;
}

vec2 packValue(float value) {
    float encoded = floor(clamp(value, 0.0, 1.0) * 65535.0 + 0.5);
    return vec2(floor(encoded / 256.0), mod(encoded, 256.0)) / 255.0;
}

float unpackValue(vec2 value) {
    return dot(value * 255.0, vec2(256.0, 1.0)) / 65535.0;
}

float radius(float angle) {
    float phase = Lobes * angle * 0.25;
    float base = abs(cos(phase)) + pow(max(abs(sin(phase)), 0.00001), Exponent);
    return 1.0 / max(base, 0.0001);
}

vec2 vertex(float column, float row) {
    vec4 encoded = IMG_PIXEL(vertexPositions, vec2(column + 0.5, row + 0.5));
    return vec2(unpackValue(encoded.rg), unpackValue(encoded.ba)) * 4.0 - 2.0;
}

float segmentDistance(vec2 point, vec2 a, vec2 b) {
    vec2 edge = b - a;
    float t = clamp(dot(point - a, edge) / max(dot(edge, edge), 0.0000001), 0.0, 1.0);
    return length(point - a - t * edge);
}

void main() {
    int rowCount = int(floor(Rows + 0.5));
    int columnCount = int(floor(Columns + 0.5));
    if (PASSINDEX == 0) {
        float columns = float(columnCount);
        float rows = float(rowCount);
        vec2 index = floor(gl_FragCoord.xy);
        float u = -3.1415927 + 6.2831853 * min(index.x, columns - 1.0) / (columns - 1.0);
        float v = -1.5707963 + 3.1415927 * min(index.y, rows - 1.0) / (rows - 1.0);
        float ru = radius(u);
        float rv = radius(v);
        vec3 position = vec3(ru * sin(u) * rv * cos(v), rv * sin(v), ru * cos(u) * rv * cos(v)) * 0.5;
        vec3 samplePoint = position / NoiseScale + vec3(TIME * NoiseSpeed);
        position += vec3(noise(samplePoint), noise(samplePoint + vec3(17.3, 5.1, 9.2)), noise(samplePoint + vec3(8.2, 23.7, 2.4))) * 0.5;
        vec2 projected = position.xy * 2.1 / max(2.5 - position.z - Scale, 0.25);
        gl_FragColor = vec4(packValue(projected.x * 0.25 + 0.5), packValue(projected.y * 0.25 + 0.5));
        return;
    }

    if (PASSINDEX == 2) {
        gl_FragColor = IMG_NORM_PIXEL(wireImage, isf_FragNormCoord.xy);
        return;
    }

    vec2 point = (isf_FragNormCoord.xy - 0.5) * vec2(1.0, RENDERSIZE.y / RENDERSIZE.x) * 2.0;
    float pixelSize = 2.0 / RENDERSIZE.x;
    float distanceToWire = 100.0;
    for (int row = 0; row < 19; row++) {
        if (row >= rowCount - 1) break;
        for (int column = 0; column < 19; column++) {
            if (column >= columnCount - 1) break;
            float x = float(column);
            float y = float(row);
            vec2 a = vertex(x, y);
            vec2 b = vertex(x + 1.0, y);
            vec2 c = vertex(x, y + 1.0);
            vec2 d = vertex(x + 1.0, y + 1.0);
            vec2 lower = min(min(a, b), min(c, d)) - pixelSize * 4.0;
            vec2 upper = max(max(a, b), max(c, d)) + pixelSize * 4.0;
            if (point.x < lower.x || point.x > upper.x || point.y < lower.y || point.y > upper.y) continue;
            distanceToWire = min(distanceToWire, segmentDistance(point, a, b));
            distanceToWire = min(distanceToWire, segmentDistance(point, a, c));
            if (ShowThirdEdge) distanceToWire = min(distanceToWire, segmentDistance(point, b, c));
            if (row == rowCount - 2) distanceToWire = min(distanceToWire, segmentDistance(point, c, d));
            if (column == columnCount - 2) distanceToWire = min(distanceToWire, segmentDistance(point, b, d));
        }
    }
    float alpha = (1.0 - smoothstep(LineWidth * pixelSize * 2.0, (LineWidth * 2.0 + 0.75) * pixelSize, distanceToWire)) * Color.a;
    if (LineWidth <= 0.0) alpha = 0.0;
    gl_FragColor = vec4(Color.rgb, alpha);
}
