#!/usr/bin/env python3
"""Build the buddy's animation clips for the app from the keyed footage of the desk-buddy-real video project.

Usage: make_clips.py <desk-buddy-real project dir> [clip names…]   (names: only re-render those)
Needs Pillow + numpy + scipy (e.g. the video-kit venv) and ffmpeg with hevc_videotoolbox (macOS).

Every clip is drawn on the same transparent stage, in output pixels (2x points): its left edge is the screen edge,
he stands with his head at HEAD_X and his soles on FEET_Y, and he is FIG px tall in every clip (each clip is scaled
by its own measured figure height), so the app switches clips without the figure jumping.
Walking in and out comes from static-camera footage where he really crosses the frame (enter_wide, leave_wide,
leave_drunk_wide), so his feet stay planted; nothing is slid sideways.
-> Resources/clips/{walkin,idle,drink,leave}.mov (water, with the glass),
   {enter_empty,idle_empty,lookfar,leave_empty}.mov (eye and movement breaks), sad{,_empty}.mov ("Not Now")  (HEVC with alpha, 24 fps)
   dangle/land (picking him up), sit/climbin/sityes/sitno (sitting on a window), each also _empty
   + Resources/clips/stage.json"""
import json, os, shutil, subprocess, sys, tempfile
import numpy as np
from PIL import Image
from scipy import ndimage

src = sys.argv[1]
ONLY = set(sys.argv[2:])
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLIPS = os.path.join(src, 'src/assets/clips')
OUT = os.environ.get('CLIP_OUT') or os.path.join(ROOT, 'Resources/clips')   # CLIP_OUT: render somewhere else (tests)
BITRATE = os.environ.get('CLIP_BITRATE', '4M')   # 4M: face error 0.94/255 vs a 20M reference (6M: 0.72), ~30% smaller
os.makedirs(OUT, exist_ok=True)

STAGE_W, STAGE_H = 960, 760   # output px (= 480 x 380 pt; room on the right for flailing arms)
FIG = 620                     # his height, hair to soles
FEET_Y = 738
HEAD_X = 640                  # where he stands: 320 pt in from the screen's left edge
FPS = 24
DRINK_CUT = 154               # last frame of drink_exit used: the thumbs-up leave_drunk_wide starts from

_meta = {}
def meta(name):
    if name not in _meta:
        _meta[name] = json.load(open(os.path.join(CLIPS, name + '.json')))
    return _meta[name]


def figure(name):
    """scale to FIG and soles offset, from the clip's median standing height"""
    fr = [f for f in meta(name)['frames'] if f]
    tops = sorted(f['top'] for f in fr); feet = sorted(f['feet'] for f in fr)
    h = feet[len(feet) // 2] - tops[len(tops) // 4]          # a low quartile of tops: standing tall, not bending
    s = FIG / h
    return s, FEET_Y - feet[len(feet) // 2] * s


def hx(name, i, r=2):
    f = meta(name)['frames']
    v = [f[k]['hx'] for k in range(i - r, i + r + 1) if 0 <= k < len(f) and f[k]]
    return sum(v) / len(v)


def feet(name, i, r=8):
    """smoothed sole height: the planted foot, averaged over a step or so"""
    f = meta(name)['frames']
    v = [f[k]['feet'] for k in range(i - r, i + r + 1) if 0 <= k < len(f) and f[k]]
    return sum(v) / len(v) if v else None


def place(name, frame_i, head_x):
    """layer spec that puts clip `name` so its frame `frame_i` has the head at head_x"""
    s, y = figure(name)
    return {'name': name, 's': s, 'x': head_x - hx(name, frame_i) * s, 'y': y}


def y_at(p, i):
    """keep his soles on FEET_Y frame by frame: in the wide clips he drifts a little toward the camera as he walks"""
    if p.get('fixed_y'):
        return p['y']
    f = feet(p['name'], i)
    return FEET_Y - f * p['s'] if f is not None else p['y']


def head_on_stage(p, i):
    return p['x'] + hx(p['name'], i) * p['s']


def clean(stage):
    """No halo: choke the outline by a pixel, clamp any green left on him, and give the invisible pixels around him his nearest solid colour, since
    the video stores colour at half resolution and would otherwise mix the empty area's colour into his outline."""
    a = np.asarray(stage, dtype=np.float32)
    alpha = a[..., 3] / 255
    if not (alpha >= 0.6).any():
        return stage
    # choke: drop the outermost ring of edge pixels (their colour is never fully free of the screen) and re-soften
    alpha = ndimage.gaussian_filter(ndimage.minimum_filter(alpha, size=3), 0.6)
    a[..., 3] = alpha * 255
    rgb = a[..., :3]
    rgb[..., 1] = np.minimum(rgb[..., 1], (rgb[..., 0] + rgb[..., 2]) / 2)   # average despill (max(R, B) leaves teal)
    iy, ix = ndimage.distance_transform_edt(alpha < 0.6, return_distances=False, return_indices=True)
    faint = alpha < 0.15
    rgb[faint] = rgb[iy[faint], ix[faint]]
    return Image.fromarray(np.dstack([rgb, a[..., 3:]]).clip(0, 255).astype(np.uint8), 'RGBA')


def render(out_name, frames):
    """frames: list of (placement, frame index)"""
    if ONLY and out_name not in ONLY:
        return
    tmp = tempfile.mkdtemp()
    try:
        def layer(p, i):
            im = Image.open(os.path.join(CLIPS, p['name'], f'{i:04d}.webp')).convert('RGBA')
            im = im.resize((round(im.width * p['s']), round(im.height * p['s'])), Image.LANCZOS)
            stage = Image.new('RGBA', (STAGE_W, STAGE_H))
            stage.paste(im, (round(p['x']), round(y_at(p, i))))   # one layer on an empty stage: copy as is (crops off-stage)
            return stage
        for k, fr in enumerate(frames):
            stage = layer(fr[0], fr[1])
            if len(fr) == 5:                                       # (p, i, p2, i2, w): cross-dissolve into a second frame
                stage = Image.blend(stage, layer(fr[2], fr[3]), fr[4])
            clean(stage).save(os.path.join(tmp, f'{k:04d}.png'))
        dst = os.path.join(OUT, out_name + '.mov')
        subprocess.run(['ffmpeg', '-v', 'error', '-y', '-framerate', str(FPS), '-i', os.path.join(tmp, '%04d.png'),
                        '-c:v', 'hevc_videotoolbox', '-alpha_quality', '0.9', '-b:v', BITRATE, '-tag:v', 'hvc1',
                        '-pix_fmt', 'bgra', dst], check=True)
        print(f'{out_name}.mov  {len(frames)} frames  {os.path.getsize(dst) / 1e6:.1f} MB')
    finally:
        shutil.rmtree(tmp)


n = lambda name: meta(name)['n']
enter = place('enter_wide', n('enter_wide') - 1, HEAD_X)     # ends standing at HEAD_X
idle = place('idle_glass', 0, HEAD_X)
drink = place('drink_exit', 0, HEAD_X)
drunk = place('leave_drunk_wide', 0, head_on_stage(drink, DRINK_CUT))   # carries on from the thumbs-up
leave = place('leave_wide', 0, HEAD_X)

def visible(name):
    fr = meta(name)['frames']; on = [i for i, f in enumerate(fr) if f]
    return on[0], on[-1]

e0, _ = visible('enter_wide')                      # the wide clips start/end on an empty frame: trim those
_, l1 = visible('leave_wide')
_, d1 = visible('leave_drunk_wide')
render('walkin', [(enter, i) for i in range(max(0, e0 - 2), n('enter_wide'))])
render('idle', [(idle, i) for i in range(n('idle_glass'))])
# Okay 🙌: "cheers!" toast, drinks, thumbs up (ends on the pose leave_drunk_wide starts from), then he walks off
cheer = place('cheers', 0, HEAD_X)
drunk = place('leave_drunk_wide', 0, head_on_stage(cheer, n('cheers') - 1))
render('drink', [(cheer, i) for i in range(n('cheers'))] + [(drunk, i) for i in range(1, min(d1 + 3, n('leave_drunk_wide')))])
render('leave', [(leave, i) for i in range(24, min(l1 + 3, n('leave_wide')))])   # one second of "OK" before he turns

# eye and movement breaks: empty hands
enter_e = place('enter_empty_wide', n('enter_empty_wide') - 1, HEAD_X)
idle_e = place('idle_empty', 0, HEAD_X)
look = place('lookfar', 0, HEAD_X)       # its head tracking picks up the shading hand, so place it by frame 0 only
leave_e = place('leave_empty_wide', 0, HEAD_X)
ee0, _ = visible('enter_empty_wide')
_, le1 = visible('leave_empty_wide')
render('enter_empty', [(enter_e, i) for i in range(max(0, ee0 - 2), n('enter_empty_wide'))])
render('idle_empty', [(idle_e, i) for i in range(n('idle_empty'))])
render('leave_empty', [(leave_e, i) for i in range(30, min(le1 + 3, n('leave_empty_wide')))])   # straight into the wave

# lookfar: hand up within ~0.75 s, hold the far-away gaze (ping-pong) until 20 s after the click, then turn back
LOOK_START, HOLD_A, HOLD_B, LOOK_END, LOOK_SECONDS = 30, 48, 110, 172, 20.0
seq = list(range(LOOK_START, HOLD_A))
hold, k = round(LOOK_SECONDS * FPS) - len(seq), 0
span = HOLD_B - HOLD_A
while len(seq) < round(LOOK_SECONDS * FPS):
    ph = k % (2 * span)
    seq.append(HOLD_A + (ph if ph < span else 2 * span - ph)); k += 1
# carry on from wherever the ping-pong stopped back to the end of the hold, then the turn back
last = seq[-1]
seq += list(range(last + 1, HOLD_B)) if last < HOLD_B else []
seq += list(range(HOLD_B, LOOK_END))
render('lookfar', [(look, i) for i in seq])

# "Not Now": a sad face, a sigh, then he shuffles off head down (with the glass for water, empty-handed for breaks)
for out_name, src_name in [('sad', 'sad_glass_wide'), ('sad_empty', 'sad_empty_wide')]:
    p = place(src_name, 0, HEAD_X)
    _, last = visible(src_name)
    render(out_name, [(p, i) for i in range(6, min(last + 3, n(src_name)))])

# poking him while he waits: each reaction starts and ends in the waiting pose
def motion_range(name, lead=1, threshold=5.0, settle=8.0):
    """(first, last) frames of the actual movement: the generated reactions open with a second of standing still and
    close with slow settling, which made pokes feel late. Change is measured against the first and last frames
    (mean colour difference over his silhouette), and the clip keeps `lead` frames of rest on either side."""
    def load(i):
        return np.asarray(Image.open(os.path.join(CLIPS, name, f'{i:04d}.webp')).convert('RGBA'))[::3, ::3].astype(np.float32)
    def diff(a, b):
        al = np.maximum(a[..., 3], b[..., 3]) / 255
        return float((np.abs(a[..., :3] - b[..., :3]).mean(-1) * al).sum() / max(al.sum(), 1))
    N = n(name); first, final = load(0), load(N - 1)
    frames = [load(i) for i in range(N)]
    start = next((i for i in range(N) if diff(frames[i], first) > threshold), 0)
    end = next((i for i in range(N - 1, -1, -1) if diff(frames[i], final) > settle), N - 1)   # nearly still = done
    return max(0, start - lead), min(N - 1, end + lead)

POKES = ['giggle', 'hey', 'silly']   # 'flinch' came out too subtle: add it back once regenerated
for r in POKES:
    for src_name, out_name in [(f'{r}_glass', r), (f'{r}_empty', f'{r}_empty')]:
        if ONLY and out_name not in ONLY:
            continue
        a, b = motion_range(src_name)
        print(f'{out_name}: motion frames {a}-{b} of {n(src_name)} ({(b - a + 1) / FPS:.2f} s)')
        render(out_name, [(place(src_name, 0, HEAD_X), i) for i in range(a, b + 1)])

# peekaboo: a close-up lean-in from the left edge, scaled so his head is a little bigger than usual, tucked into the
# bottom-left corner (his shoulder runs off the bottom of the screen), then the lean-in played back to duck away
PEEK_HEAD = 100     # px, his head height on stage (about 80 when he stands)
fr = meta('peek')['frames']; on = [i for i, f in enumerate(fr) if f]
head_h = 0.27 * meta('peek')['h']          # the peek pose's head is ~27% of the frame height
ps = PEEK_HEAD / head_h
peek = {'name': 'peek', 's': ps, 'x': 0, 'y': STAGE_H - meta('peek')['h'] * ps, 'fixed_y': True}
wave_end = n('peek') - 1
lean = list(range(max(0, on[0] - 2), n('peek')))
back = [i for i in reversed(lean) if i <= on[0] + int(0.45 * (wave_end - on[0]))]   # duck back out (the lean-in, reversed)
render('peek', [(peek, i) for i in lean + [wave_end] * 12 + back])

# prayer time: the second character, in traditional Yemeni dress
y_in = place('y_enter_wide', n('y_enter_wide') - 1, HEAD_X)
y0, _ = visible('y_enter_wide')
render('y_enter', [(y_in, i) for i in range(max(0, y0 - 2), n('y_enter_wide'))])
render('y_idle', [(place('y_idle', 0, HEAD_X), i) for i in range(n('y_idle'))])
for src_name, out_name in [('y_go_wide', 'y_go'), ('y_later_wide', 'y_later'), ('y_sad_wide', 'y_sad')]:
    _, last = visible(src_name)
    render(out_name, [(place(src_name, 0, HEAD_X), i) for i in range(min(last + 3, n(src_name)))])

s, y = figure('idle_glass')
head_top = round(min(f['top'] for f in meta('idle_glass')['frames'] if f) * s + y)
# picking him up, and sitting on a window. These clips come from stills with the idle clip's camera framing, so they
# all use the idle clip's placement as is (no per-clip re-centring): the land clip then ends exactly in his waiting
# pose, and the sitting pose keeps his real size. The ledge he sits on was a darker green, keyed out with the rest.
LEDGE = json.load(open(os.path.join(src, 'build/gen/sit_ledge.json')))   # ledge line, as a fraction of frame height
sit_info, grab_info, land_info = {}, {}, {}
for v, idle_name, sfx in [('glass', 'idle_glass', ''), ('empty', 'idle_empty', '_empty')]:
    base = place(idle_name, 0, HEAD_X)
    same = lambda name: {'name': name, 's': base['s'], 'x': base['x'], 'y': base['y'], 'fixed_y': True}
    for clip, out_name in [('dangle', 'dangle'), ('sitloop', 'sit')]:
        render(out_name + sfx, [(same(f'{clip}_{v}'), i) for i in range(n(f'{clip}_{v}'))])
    # landing: from the frame his feet touch the ground (the generated clip first hovers him in the dangling pose and
    # drops him again, which read as a pause after the fall) until he has stood back up
    lf = meta(f'land_{v}')['frames']
    feet_l = [f['feet'] if f else 0 for f in lf]
    ground = max(feet_l[-24:])                                  # standing, at the end
    touch = next(i for i, f in enumerate(feet_l) if f >= ground - 20)
    tops = [f['top'] if f else 0 for f in lf]
    bottom = max(range(touch, len(tops)), key=lambda i: tops[i])                 # deepest point of the crouch
    up = next(i for i in range(bottom, len(tops)) if abs(tops[i] - tops[-1]) <= 6) + 2   # back to his full height
    render('land' + sfx, [(same(f'land_{v}'), i) for i in range(touch - 1, up + 1)])
    dangle_feet = sorted(f['feet'] for f in meta(f'dangle_{v}')['frames'] if f)
    land_info[v] = {'gap': round((feet_l[touch] - dangle_feet[len(dangle_feet) // 2]) * base['s'], 1),
                    'bottom': round((bottom - touch + 1) / FPS, 3), 'up': round((up - touch + 1) / FPS, 3)}
    print(f'land{sfx}: frames {touch - 1}-{up} (touchdown {touch}, crouch {bottom}, up {up}); dangling feet hang {land_info[v]["gap"]} px above the landing')
    c0, _ = visible(f'climbin_{v}')
    render('climbin' + sfx, [(same(f'climbin_{v}'), i) for i in range(max(0, c0 - 2), n(f'climbin_{v}'))])
    for clip in ['sityes', 'sitno']:
        _, last = visible(f'{clip}_{v}')
        render(clip + sfx, [(same(f'{clip}_{v}'), i) for i in range(min(last + 3, n(f'{clip}_{v}')))])
    st = lambda x, y: (round(base['x'] + x * base['s'], 1), round(base['y'] + y * base['s'], 1))
    f0 = meta(f'sitloop_{v}')['frames'][0]
    hx0, top0 = st(f0['hx'], f0['top'])
    _, seat = st(0, LEDGE[v] * meta(f'sitloop_{v}')['h'])
    bx0, by0 = st(f0['x0'], f0['top']); bx1, by1 = st(f0['x1'], f0['feet'])
    sit_info[v] = {'headX': hx0, 'headTop': top0, 'seatY': seat, 'body': [bx0, by0, bx1, by1]}
    d0 = meta(f'dangle_{v}')['frames'][0]
    gx, gy = st(d0['hx'], d0['top'])
    grab_info[v] = [gx, gy + 70]                     # his collar, just under the chin
    print(v, 'sit', sit_info[v], 'grab', grab_info[v])

# walking off from anywhere: an in-place walk cycle cut from each walk-off clip's own steps. The app switches to it
# mid-walk (same frame, so no seam) and moves the window at his measured walking speed until he's off the screen edge.
def mask(name, i, k=4):
    a = np.asarray(Image.open(os.path.join(CLIPS, name, f'{i:04d}.webp')).convert('RGBA'))[::k, ::k, 3] > 128
    return a

def iou(name, a, b, k=4):
    ma, mb = mask(name, a, k), mask(name, b, k)
    shift = round((hx(name, b, 0) - hx(name, a, 0)) / k)
    mb = np.roll(mb, -shift, axis=1)
    return (ma & mb).sum() / max(1, (ma | mb).sum())

WALK_X = HEAD_X
walk_info = {}
def walk_loop(exit_name, src_name, P, first_src, out_offset, direction=-1, strides=range(22, 40)):
    """exit_name: the app's clip; its output frame for source frame f is f - first_src + out_offset.
    direction: -1 he walks off to the left, +1 to the right. strides: loop lengths to try (a full stride, both legs)."""
    fr = meta(src_name)['frames']; w = meta(src_name)['w']
    full = [i for i, f in enumerate(fr) if f and f['x0'] > 6 and f['x1'] < w - 6]
    hxs = [hx(src_name, i) if fr[i] else None for i in range(len(fr))]
    V = max(i for i in full if i > first_src)
    W = next(i for i in range(first_src + 2, V) if all(hxs[j + 1] is not None and hxs[j - 1] is not None
                                                        and (hxs[j + 1] - hxs[j - 1]) * direction > 4 for j in range(i, i + 4)))
    # the loop: a full stride [ks, ks + L) whose end flows back into its start; search every start and length
    K = 4                                   # frames cross-dissolved at the seam
    cache = {}
    def m(i):
        if i not in cache: cache[i] = mask(src_name, i, 3)
        return cache[i]
    def match(a, b):
        ma, mb = m(a), np.roll(m(b), -round((hx(src_name, b, 0) - hx(src_name, a, 0)) / 3), axis=1)
        return (ma & mb).sum() / max(1, (ma | mb).sum())
    best = None
    for L in strides:                       # a full stride (both legs), so the near and far leg never swap at the seam
        for ks in range(W + K, V - L + 1):
            score = match(ks, ks + L)
            if best is None or score > best[0]:
                best = (score, L, ks)
    score, L, ks = best
    b, a = np.polyfit(np.arange(ks - K, ks + L + 1), [hxs[i] for i in range(ks - K, ks + L + 1)], 1)
    s_ = P['s']
    pl = lambda f: {'name': src_name, 's': s_, 'x': WALK_X - (a + b * f) * s_, 'y': P['y']}
    loop = []
    for f in range(ks, ks + L):
        j = f - (ks + L - K)                 # the last K frames fade into the K frames that lead into ks
        if j >= 0:
            g = f - L                        # one stride earlier: ks - K .. ks - 1
            loop.append((pl(f), f, pl(g), g, (j + 1) / (K + 1)))   # both in place, so they line up
        else:
            loop.append((pl(f), f))
    render('walk_' + exit_name, loop)
    # align on where his head really is at the switch frame (he may still be speeding up, off the straight-line fit)
    h = hx(src_name, ks, 1)
    walk_info[exit_name] = {'switchAt': round((ks - first_src + out_offset) / FPS, 3),
                            'clipHeadX': round(P['x'] + h * s_, 1), 'loopHeadX': round(WALK_X + (h - a - b * ks) * s_, 1),
                            'speed': round(abs(b) * s_ * FPS, 1), 'dir': direction, 'frame': ks,
                            'loop': 'walk_' + exit_name}
    print(f'walk_{exit_name}: frames {ks}-{ks + L} of {src_name} (match {score:.2f}), switch at {walk_info[exit_name]["switchAt"]} s,'
          f' {walk_info[exit_name]["speed"]} px/s')

walk_loop('leave', 'leave_wide', leave, 24, 0)
walk_loop('sad', 'sad_glass_wide', place('sad_glass_wide', 0, HEAD_X), 6, 0)
walk_loop('leave_empty', 'leave_empty_wide', leave_e, 30, 0)
walk_loop('sad_empty', 'sad_empty_wide', place('sad_empty_wide', 0, HEAD_X), 6, 0)

# real footage for the right-hand exits (no mirroring), and a happy jog after drinking, both ways. Each is used once
# its source clip has been generated and keyed; until then the app walks him off to the left.
have = lambda name: os.path.exists(os.path.join(CLIPS, name + '.json'))
RUN = range(12, 30)                       # a running stride is shorter than a walking one
def continuing(name, i, prev, j):
    """placement for clip `name` from its frame i so that it carries on from clip placement `prev` at its frame j:
    same height and head position on stage (no size pop at the join, whatever poses the rest of the clip has)"""
    a, b = meta(prev['name'])['frames'][j], meta(name)['frames'][i]
    s_ = (a['feet'] - a['top']) * prev['s'] / (b['feet'] - b['top'])
    y_ = FEET_Y - sorted(f['feet'] for f in meta(name)['frames'] if f)[len(meta(name)['frames']) // 2] * s_
    return {'name': name, 's': s_, 'x': head_on_stage(prev, j) - hx(name, i) * s_, 'y': y_}

if have('run_left_glass'):
    go = max(1, motion_range('run_left_glass', lead=2)[0])          # skip the standing still before he turns
    run_l = continuing('run_left_glass', go, cheer, n('cheers') - 1)
    render('drink', [(cheer, i) for i in range(n('cheers'))] + [(run_l, i) for i in range(go, visible('run_left_glass')[1] + 3)])
    walk_loop('drink', 'run_left_glass', run_l, go, n('cheers'), -1, RUN)
else:
    walk_loop('drink', 'leave_drunk_wide', drunk, 1, n('cheers'))
if have('run_right_glass'):
    go = max(1, motion_range('run_right_glass', lead=2)[0])
    run_r = continuing('run_right_glass', go, cheer, n('cheers') - 1)
    render('drink_r', [(cheer, i) for i in range(n('cheers'))] + [(run_r, i) for i in range(go, visible('run_right_glass')[1] + 3)])
    walk_loop('drink_r', 'run_right_glass', run_r, go, n('cheers'), 1, RUN)
for out_name, src_name, first in [('sad_r', 'sad_right_glass', 6), ('sad_empty_r', 'sad_right_empty', 6),
                                  ('leave_empty_r', 'leave_right_empty', 24)]:
    if have(src_name):
        first = max(first, motion_range(src_name, lead=2)[0] - 2)
        print(f'{out_name}: from frame {first} of {src_name}')
        P = place(src_name, 0, HEAD_X)
        render(out_name, [(P, i) for i in range(first, min(visible(src_name)[1] + 3, n(src_name)))])
        walk_loop(out_name, src_name, P, first, 0, 1)

# long walks: a continuous, non-repeating walk filmed as a tracking shot (he stays centred, the flat green hides the camera
# move), starting on the exact frame where the walk-off clip hands over. The planted foot slides backward in the frame
# at the camera's speed, so measuring it frame by frame tells the app how far to move the window for each frame: his
# feet stay put on the screen and nothing repeats.
def ground_speed(name, direction, scale):
    """per frame, how far (stage px) the window must move so the shoe on the ground stays put on the screen. A planted
    shoe slides backward in the frame at the camera's speed and the swinging shoe moves forward, so for each frame the
    shoe that moved backward the most is the planted one, and that's the step. No smoothing (it would blur the real
    speed changes within a stride and make the feet skate); single-frame detector glitches (shoes merging into one
    blob) are replaced by the median of their neighbours."""
    fr = meta(name)['frames']; N = len(fr)
    band_px, min_area = 60 / scale, 150 / scale ** 2              # the same feet band and blob size as on stage
    shoes = []
    for i in range(N):
        a = np.asarray(Image.open(os.path.join(CLIPS, name, f'{i:04d}.webp')).convert('RGBA'))[..., 3] > 128
        if not a.any():
            shoes.append([]); continue
        feet = np.where(a)[0].max()
        lab, k = ndimage.label(a[int(feet - band_px): feet + 1])
        shoes.append([float(np.where(lab == b)[1].mean()) * scale for b in range(1, k + 1) if (lab == b).sum() > min_area])
    v = []
    for i in range(N - 1):
        best = None
        for x in shoes[i]:
            if not shoes[i + 1]:
                continue
            nx = min(shoes[i + 1], key=lambda t: abs(t - x))
            back = (x - nx) * direction
            if abs(nx - x) <= 40 and (best is None or back > best):
                best = back
        v.append(best if best is not None and -2 <= best < 30 else np.nan)
    v = np.array(v); ok = ~np.isnan(v)
    v = np.interp(np.arange(len(v)), np.where(ok)[0], v[ok])
    for _ in range(2):
        med = ndimage.median_filter(v, size=5)
        v = np.where(np.abs(v - med) > 2.0, med, v)                # > 1 pt off its neighbours: a detector glitch
    return list(v), float(np.median(v))

long_info = {}
def long_walk(exit_name, src_name, prev, prev_frame, direction):
    if not have(src_name):
        return
    P = continuing(src_name, 0, prev, prev_frame)
    _, last = visible(src_name)
    render('walklong_' + exit_name, [(dict(P, fixed_y=True), i) for i in range(0, last + 1)])
    v, med = ground_speed(src_name, direction, P['s'])
    offs = [0.0]
    for x in v[:last]:
        offs.append(offs[-1] + x)
    long_info[exit_name] = {'clip': 'walklong_' + exit_name, 'headX': round(P['x'] + hx(src_name, 0, 1) * P['s'], 1),
                            'offsets': [round(o, 1) for o in offs]}
    print(f'walklong_{exit_name}: {last + 1} frames ({(last + 1) / FPS:.1f} s), ground {med * FPS:.0f} px/s, '
          f'covers {offs[-1]:.0f} px')

for exit_name, src_name, exit_src, direction in [('sad_r', 'sadwalk_r_glass', 'sad_right_glass', 1),
                                                 ('sad', 'sadwalk_l_glass', 'sad_glass_wide', -1),
                                                 ('sad_empty', 'sadwalk_l_empty', 'sad_empty_wide', -1),
                                                 ('sad_empty_r', 'sadwalk_r_empty', 'sad_right_empty', 1)]:
    if exit_name in walk_info:      # continues from the frame where that exit hands over to its walk
        long_walk(exit_name, src_name, place(exit_src, 0, HEAD_X), walk_info[exit_name]['frame'], direction)

json.dump({'width': STAGE_W, 'height': STAGE_H, 'fps': FPS, 'headX': HEAD_X, 'headTop': head_top, 'feetY': FEET_Y,
           'long': long_info,
           'sit': sit_info, 'grab': grab_info, 'walk': walk_info, 'land': land_info},
          open(os.path.join(OUT, 'stage.json'), 'w'), indent=1)
print('stage', STAGE_W, 'x', STAGE_H, 'head top', head_top)
