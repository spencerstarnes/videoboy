#!/usr/bin/env python3
#
# beatnet-export.py — make App/Resources/BeatNet/beatnet-model1.bin from BeatNet.
#
# Purpose : Converts BeatNet's model-1 PyTorch weights, and the madmom filterbank
#           its features use, into the one flat file the Swift port reads; and
#           writes Core/Tests/Fixtures/beatnet-reference.json, the Python's own
#           features and activations for a synthetic signal, which BeatNetTests
#           holds the port to. A developer-machine tool; nothing here ships.
# Inputs  : argv[1] a BeatNet checkout (default ./BeatNet). Needs torch, madmom,
#           librosa — see docs/BEATNET.md for the environment.
# Outputs : beatnet-model1.bin and beatnet-reference.json in the current folder.
#
# File layout (little-endian): b"BNET", u32 version=1, u32 tensor count, then per
# tensor: u32 rank, u32 dims[rank], float32 values, row-major. Order: filterbank
# (705,136), conv1.weight, conv1.bias, linear0.weight, linear0.bias, LSTM layer 0
# W_ih W_hh b_ih b_hh, layer 1 the same, linear.weight, linear.bias.
#
import os, sys, struct, json
import numpy as np, torch
BEATNET = sys.argv[1] if len(sys.argv) > 1 else 'BeatNet'
sys.path.insert(0, os.path.join(BEATNET, 'src'))
from BeatNet.log_spect import LOG_SPECT
from BeatNet.model import BDA

SR, HOP, WIN = 22050, 441, 1411
proc = LOG_SPECT(sample_rate=SR, win_length=WIN, hop_size=HOP, n_bands=[24], mode='online')

# Dig the filterbank and diff frames out of the madmom pipeline.
seq = proc.pipe.processors[1].processors[0]
frames, stft, filt, spec, diff = seq.processors
print('diff_ratio', diff.diff_ratio, 'diff_frames attr', getattr(diff, 'diff_frames', None))

def synth(seconds=12.0):
    t = np.arange(int(SR * seconds)) / SR
    x = np.zeros_like(t)
    for k in range(int(seconds / 0.5) + 1):
        tb = k * 0.5
        d = t - tb
        m = d >= 0
        x[m] += 0.8 * np.exp(-d[m] * 25) * np.sin(2 * np.pi * 55 * d[m])
        tb2 = tb + 0.25
        d2 = t - tb2
        m2 = d2 >= 0
        x[m2] += 0.2 * np.exp(-d2[m2] * 120) * np.sin(2 * np.pi * 6000 * d2[m2])
    return x.astype(np.float32)

x = synth()
feats = proc.process_audio(x).T          # (N, 272)
from madmom.audio.spectrogram import FilteredSpectrogram
fb = None
# Build a filtered spectrogram once to get the actual filterbank object.
from madmom.audio.signal import FramedSignal
fs = FramedSignal(x, frame_size=WIN, hop_size=HOP, sample_rate=SR)
from madmom.audio.stft import ShortTimeFourierTransform
st = ShortTimeFourierTransform(fs)
from madmom.audio.spectrogram import Spectrogram
sp = Spectrogram(st)
fsp = FilteredSpectrogram(sp, num_bands=24, fmin=30, fmax=17000, norm_filters=True)
fb = np.asarray(fsp.filterbank, dtype=np.float32)
print('filterbank', fb.shape, 'frames', len(fs), 'feats', feats.shape)
print('window', stft.window if hasattr(stft, 'window') else None)
# Check first/last framing convention.
print('frame0 first nonzero idx', np.flatnonzero(fs[0])[:1], 'frame1 == x[441-705 ...]?',
      np.allclose(fs[1][705 - 441:], x[:WIN - (705 - 441)]))

model = BDA(272, 150, 2, 'cpu')
sd = torch.load(os.path.join(BEATNET, 'src/BeatNet/models/model_1_weights.pt'), map_location='cpu')
model.load_state_dict(sd); model.eval()
with torch.no_grad():
    out = model(torch.from_numpy(feats).unsqueeze(0))[0]
    act = model.final_pred(out).numpy().T   # (N, 3)

order = ['conv1.weight', 'conv1.bias', 'linear0.weight', 'linear0.bias',
         'lstm.weight_ih_l0', 'lstm.weight_hh_l0', 'lstm.bias_ih_l0', 'lstm.bias_hh_l0',
         'lstm.weight_ih_l1', 'lstm.weight_hh_l1', 'lstm.bias_ih_l1', 'lstm.bias_hh_l1',
         'linear.weight', 'linear.bias']
tensors = [fb] + [sd[k].numpy().astype(np.float32) for k in order]
with open('beatnet-model1.bin', 'wb') as f:
    f.write(b'BNET'); f.write(struct.pack('<II', 1, len(tensors)))
    for t in tensors:
        f.write(struct.pack('<I', t.ndim)); f.write(struct.pack('<%dI' % t.ndim, *t.shape))
        f.write(np.ascontiguousarray(t, dtype='<f4').tobytes())

rows = [0, 1, 2, 3, 50, 100, 200, 300, 400, 550]
ref = {'numFrames': int(feats.shape[0]),
       'featureRows': {str(r): feats[r].tolist() for r in rows},
       'activations': act[:, :3].tolist()}
json.dump(ref, open('beatnet-reference.json', 'w'))
print('act max beat', act[:, 0].max(), 'down', act[:, 1].max())
