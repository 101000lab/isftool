/*{
  "DESCRIPTION": "Shows top_white.png, whose top half is opaque white and bottom half transparent, through IMG_NORM_PIXEL on the left and IMG_PIXEL on the right.",
  "IMPORTED": { "topWhite": { "PATH": "top_white.png" } }
}*/

void main() {
    vec2 uv = isf_FragNormCoord.xy;
    gl_FragColor = uv.x < 0.5 ? IMG_NORM_PIXEL(topWhite, uv) : IMG_PIXEL(topWhite, uv * IMG_SIZE(topWhite));
}
