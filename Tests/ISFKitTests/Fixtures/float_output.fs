/*{
  "DESCRIPTION": "The only pass is a FLOAT persistent buffer at half the output width, as in Comet Trail. Red marks the left half of the buffer and green accumulates 0.001 per frame, starting over every 600 frames.",
  "PASSES": [
    { "TARGET": "trail", "PERSISTENT": true, "FLOAT": true, "WIDTH": "floor($WIDTH/2.0)" }
  ]
}*/

void main() {
    vec2 uv = isf_FragNormCoord.xy;
    vec4 previous = IMG_THIS_PIXEL(trail);
    bool restart = int(mod(float(FRAMEINDEX), 600.0)) == 0;
    gl_FragColor = vec4(uv.x < 0.5 ? 1.0 : 0.0, (restart ? 0.0 : previous.g) + 0.001, 0.0, 1.0);
}
