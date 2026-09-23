/*{
    "DESCRIPTION": "Videoboy built-in echo / trails: a luma-keyed, decaying history glowing behind the live picture. Behavioural emulation of VDMX-style feedback echo, not a signal model. Ported from the native echo_fragment; the history is the previous OUTPUT, held in a persistent buffer.",
    "CREDIT": "Videoboy",
    "ISFVSN": "2",
    "CATEGORIES": ["Stylize", "Videoboy"],
    "PASSES": [
        { "TARGET": "history", "PERSISTENT": true }
    ],
    "INPUTS": [
        { "NAME": "inputImage", "TYPE": "image" },
        { "NAME": "decay", "LABEL": "decay", "TYPE": "float", "MIN": 0.0, "MAX": 1.0, "DEFAULT": 0.8, "VIDEOBOY_CODE": "21A" },
        { "NAME": "trail", "LABEL": "length", "TYPE": "float", "MIN": 0.0, "MAX": 1.0, "DEFAULT": 0.6, "VIDEOBOY_CODE": "22A" },
        { "NAME": "threshold", "LABEL": "thresh", "TYPE": "float", "MIN": 0.0, "MAX": 1.0, "DEFAULT": 0.15, "VIDEOBOY_CODE": "23A" }
    ]
}*/

float lumaOf(vec3 c) {
    return dot(c, vec3(0.299, 0.587, 0.114));
}

void main() {
    vec3 now = IMG_THIS_PIXEL(inputImage).rgb;
    // The single pass writes `history` and reads it: the host hands this pass the
    // PREVIOUS frame's output, which is what makes it a trail.
    vec3 past = IMG_THIS_PIXEL(history).rgb;

    // Luma key: only bright enough pixels leave a tail, so the frame does not turn
    // to mud.
    float key = step(threshold, lumaOf(now));

    // Keyed contribution or decayed history, whichever is brighter. `max`, not a
    // sum, so trails settle instead of clipping to white. Decay stops short of 1 so
    // a trail always eventually fades.
    vec3 accumulated = max(now * key, past * min(decay, 0.999));

    // The live picture with the trail showing through behind it.
    vec3 result = max(now, accumulated * trail);
    gl_FragColor = vec4(clamp(result, 0.0, 1.0), 1.0);
}
