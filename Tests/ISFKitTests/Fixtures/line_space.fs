/*{
  "ISFVSN": "2",
  "DESCRIPTION": "Drifting vertical line segments based on vuos/line_space.vuo. Lines are added one at a time, Growth lines per second, until there are Items of them; after that every new line replaces the oldest one, so the field keeps renewing itself. Lowering Items removes the oldest at once. Clear goes back to a single line, restarts the drift and rolls a new random layout, like Clear in the composition. Transparent background.",
  "CREDIT": "k1low",
  "CATEGORIES": ["Generator"],
  "INPUTS": [
    { "NAME": "Items", "LABEL": "Items", "TYPE": "float", "DEFAULT": 53.0, "MIN": 0.0, "MAX": 100.0 },
    { "NAME": "Growth", "LABEL": "Growth (lines/s)", "TYPE": "float", "DEFAULT": 2.0, "MIN": 0.0, "MAX": 30.0 },
    { "NAME": "Clear", "LABEL": "Clear", "TYPE": "event" },
    { "NAME": "Speed", "LABEL": "Speed", "TYPE": "float", "DEFAULT": 0.05, "MIN": 0.05, "MAX": 20.0 },
    { "NAME": "Opacity", "LABEL": "Opacity", "TYPE": "float", "DEFAULT": 0.88, "MIN": 0.0, "MAX": 1.0 },
    { "NAME": "Width", "LABEL": "Width", "TYPE": "float", "DEFAULT": 0.002, "MIN": 0.002, "MAX": 0.1 }
  ],
  "PASSES": [
    { "TARGET": "lineState", "PERSISTENT": true, "WIDTH": "4", "HEIGHT": "1" },
    {}
  ]
}*/

// Lines are numbered in the order they are added and the visible ones are those from the tail
// up to the head. lineState pixel 0 holds the head and pixel 3 the tail, both as 12.12 fixed
// point that wraps at 4096 lines; the 1/4096 steps are exact in float, so when the field is full
// and the tail is the head minus Items, both cross a whole number on the same frame and a line
// is never dropped before its replacement arrives. Pixel 1 holds the drift time in milliseconds
// as two 16-bit halves and pixel 2 the layout generation. The drift time is integrated from
// Speed rather than taken as TIME * Speed, so moving the Speed slider does not make every line
// jump, and it restarts at 0 on Clear like Change Speed's reset.

const float WRAP = 4096.0;

vec2 packValue(float value) {
    float encoded = floor(clamp(value, 0.0, 1.0) * 65535.0 + 0.5);
    return vec2(floor(encoded / 256.0), mod(encoded, 256.0)) / 255.0;
}

float unpackValue(vec2 value) {
    return dot(value * 255.0, vec2(256.0, 1.0)) / 65535.0;
}

vec3 packFixed(float value) {
    float encoded = floor(mod(value, WRAP) * 4096.0 + 0.5);
    float high = floor(encoded / 65536.0);
    float mid = floor((encoded - high * 65536.0) / 256.0);
    return vec3(high, mid, encoded - high * 65536.0 - mid * 256.0) / 255.0;
}

float unpackFixed(vec3 value) {
    return dot(floor(value * 255.0 + 0.5), vec3(65536.0, 256.0, 1.0)) / 4096.0;
}

float unpack16(vec2 value) {
    return floor(unpackValue(value) * 65535.0 + 0.5);
}

float randomValue(float index, float channel) {
    return fract(sin(index * 12.9898 + channel * 78.233) * 43758.5453);
}

void main() {
    vec4 timePixel = IMG_PIXEL(lineState, vec2(1.5, 0.5));
    float head = unpackFixed(IMG_PIXEL(lineState, vec2(0.5, 0.5)).rgb);
    float tail = unpackFixed(IMG_PIXEL(lineState, vec2(3.5, 0.5)).rgb);
    float items = floor(Items + 0.5);
    float generation = unpack16(IMG_PIXEL(lineState, vec2(2.5, 0.5)).rg);
    float driftMs = unpack16(timePixel.rg) * 65536.0 + unpack16(timePixel.ba);

    if (PASSINDEX == 0) {
        bool reset = FRAMEINDEX == 0 || Clear;
        // Like the composition, a fresh start or a Clear begins with one line rather than none.
        float added = floor(min(TIMEDELTA, 0.25) * Growth * 4096.0 + 0.5) / 4096.0;
        head = reset ? 1.0 : mod(head + added, WRAP);
        tail = reset ? 0.0 : tail;
        if (mod(head - tail, WRAP) > items) tail = mod(head - items, WRAP);
        if (reset && FRAMEINDEX > 0) generation = mod(generation + 1.0, 65536.0);
        driftMs = reset ? 0.0 : driftMs + min(TIMEDELTA, 0.25) * Speed * 1000.0;
        float high = floor(driftMs / 65536.0);
        float low = driftMs - high * 65536.0;
        if (gl_FragCoord.x < 1.0) gl_FragColor = vec4(packFixed(head), 1.0);
        else if (gl_FragCoord.x < 2.0) gl_FragColor = vec4(packValue(high / 65535.0), packValue(low / 65535.0));
        else if (gl_FragCoord.x < 3.0) gl_FragColor = vec4(packValue(generation / 65535.0), 0.0, 1.0);
        else gl_FragColor = vec4(packFixed(tail), 1.0);
        return;
    }

    vec2 point = (isf_FragNormCoord.xy - 0.5) * 2.0;
    point.y *= RENDERSIZE.y / RENDERSIZE.x;
    float pixelSize = 2.0 / RENDERSIZE.x;
    float drift = driftMs / 1000.0;
    // Kept small so the hash input stays precise however many times Clear is pressed.
    float layoutSalt = mod(generation, 97.0) * 101.0;
    float alpha = 0.0;

    float newest = floor(head) - 1.0;
    int itemCount = int(min(mod(floor(head) - floor(tail), WRAP), items));
    for (int i = 0; i < 100; i++) {
        if (i >= itemCount) break;
        float index = mod(newest - float(i), WRAP) + 1.0 + layoutSalt;
        float x = mix(-1.0, 1.0, randomValue(index, 1.0));
        float offset = mix(-2.0, 0.0, randomValue(index, 2.0));
        float y = mod(offset + drift * (1.0 + 0.2 * offset), 2.0) - 1.0;
        float height = 0.5 * mix(0.5, 1.2, randomValue(index, 3.0));
        vec2 distanceToEdge = abs(point - vec2(x, y)) - vec2(Width, height) * 0.5;
        vec2 coverage = 1.0 - smoothstep(vec2(-pixelSize * 0.5), vec2(pixelSize * 0.5), distanceToEdge);
        float lineAlpha = coverage.x * coverage.y * Opacity;
        alpha += lineAlpha * (1.0 - alpha);
    }

    gl_FragColor = vec4(vec3(step(0.00001, alpha)), alpha);
}
