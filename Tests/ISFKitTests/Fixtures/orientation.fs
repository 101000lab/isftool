/*{
  "DESCRIPTION": "Red where x > 0.5, green where y > 0.5, and blue from a Color input, to check which way the output faces.",
  "INPUTS": [
    { "NAME": "Tint", "TYPE": "color", "DEFAULT": [0.0, 0.0, 0.0, 1.0] }
  ]
}*/

void main() {
    vec2 uv = isf_FragNormCoord.xy;
    gl_FragColor = vec4(step(0.5, uv.x), step(0.5, uv.y), Tint.b, 1.0);
}
