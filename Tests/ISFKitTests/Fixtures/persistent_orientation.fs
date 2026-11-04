/*{
  "DESCRIPTION": "Frame 0 writes white to the top half of a persistent buffer. Later frames copy the buffer onto itself, the left half through IMG_THIS_PIXEL and the right half through IMG_NORM_PIXEL. The top half stays white only if buffers are read the right way up.",
  "PASSES": [
    { "TARGET": "buf", "PERSISTENT": true },
    {}
  ]
}*/

void main() {
    vec2 uv = isf_FragNormCoord.xy;
    vec4 previous = uv.x < 0.5 ? IMG_THIS_PIXEL(buf) : IMG_NORM_PIXEL(buf, uv);
    if (PASSINDEX == 0) {
        gl_FragColor = FRAMEINDEX == 0 ? vec4(step(0.5, uv.y)) : previous;
    } else {
        gl_FragColor = previous;
    }
}
