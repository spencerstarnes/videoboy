/*{
    "DESCRIPTION": "Videoboy built-in transform: scale, position, rotation and flips, about the centre. Outside the frame is black, not a smeared edge. Ported from the native transform_fragment, restated in ISF's y-up coordinates.",
    "CREDIT": "Videoboy",
    "ISFVSN": "2",
    "CATEGORIES": ["Geometry Adjustment", "Videoboy"],
    "VIDEOBOY": { "IDENTITY_AT_DEFAULTS": true },
    "INPUTS": [
        { "NAME": "inputImage", "TYPE": "image" },
        { "NAME": "scale", "LABEL": "scale", "TYPE": "float", "MIN": 0.1, "MAX": 4.0, "DEFAULT": 1.0, "VIDEOBOY_CODE": "11A" },
        { "NAME": "positionX", "LABEL": "pos X", "TYPE": "float", "MIN": -1.0, "MAX": 1.0, "DEFAULT": 0.0, "VIDEOBOY_CODE": "12A" },
        { "NAME": "positionY", "LABEL": "pos Y", "TYPE": "float", "MIN": -1.0, "MAX": 1.0, "DEFAULT": 0.0, "VIDEOBOY_CODE": "13A" },
        { "NAME": "rotation", "LABEL": "rotate", "TYPE": "float", "MIN": 0.0, "MAX": 1.0, "DEFAULT": 0.0, "VIDEOBOY_CODE": "14A" },
        { "NAME": "flipH", "LABEL": "flip H", "TYPE": "bool", "DEFAULT": false, "VIDEOBOY_CODE": "15A" },
        { "NAME": "flipV", "LABEL": "flip V", "TYPE": "bool", "DEFAULT": false, "VIDEOBOY_CODE": "16A" }
    ]
}*/

// Sampling runs BACKWARDS: for each output pixel, ask where in the source it came
// from. So every step below is the INVERSE of what you see on screen — to make the
// picture twice as big, sample half as far from the centre.
//
// Coordinates here are ISF's (y up). The native shader works y-down, so two signs
// differ from it: the rotation angle (flipping y reverses rotation direction) and
// positionY (positive still moves the picture DOWN the screen, as it does natively).

void main() {
    vec2 centred = isf_FragNormCoord - 0.5;

    // Flips first; each is its own inverse.
    if (flipH) { centred.x = -centred.x; }
    if (flipV) { centred.y = -centred.y; }

    // Inverse rotation.
    float angle = rotation * 6.28318530718;
    float c = cos(angle);
    float s = sin(angle);
    vec2 rotated = vec2(centred.x * c - centred.y * s,
                        centred.x * s + centred.y * c);

    // Inverse scale: divide.
    vec2 uv = rotated / max(scale, 0.01) + 0.5;

    // Inverse offset.
    uv.x -= positionX;
    uv.y += positionY;

    if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) {
        gl_FragColor = vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }
    gl_FragColor = vec4(IMG_NORM_PIXEL(inputImage, uv).rgb, 1.0);
}
