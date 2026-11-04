/*{
  "DESCRIPTION": "Adds 0.001 per frame to a persistent buffer with FLOAT false and shows it. A float buffer reaches about 0.1 after 100 frames, while an 8 bit buffer rounds every step back to 0. Starts over every 600 frames so it can be watched in VDMX.",
  "PASSES": [
    { "TARGET": "acc", "PERSISTENT": true, "FLOAT": false },
    {}
  ]
}*/

void main() {
    vec4 previous = IMG_THIS_PIXEL(acc);
    bool restart = int(mod(float(FRAMEINDEX), 600.0)) == 0;
    gl_FragColor = PASSINDEX == 0 ? vec4((restart ? vec3(0.0) : previous.rgb) + 0.001, 1.0) : previous;
}
