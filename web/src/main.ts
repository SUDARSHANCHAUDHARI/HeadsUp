/* Plain-DOM stand-in for robot-heads' React wrapper (RobotHead.tsx): one
   head on one canvas, driven by window.setState() and window.setLook()
   from the Swift side. */
import type { RobotHeadShape, RobotHeadState } from './types';
import { getShape } from './tv/geometry';
import { RobotSim, restPose } from './tv/sim';
import { RobotRenderer, frameFor, type Palette } from './tv/render';
import { linear } from './tv/light';
import { parseColor } from './color';
import { subscribe, pointer } from './ticker';

const STATES: RobotHeadState[] = ['idle', 'thinking', 'searching', 'listening', 'speaking', 'working', 'happy', 'error', 'sleeping'];
const SHAPES: RobotHeadShape[] = ['rectangle', 'square', 'circle', 'hexagon'];
const SIZE = 120;

/* The named swatches from robot-heads' own playground (site/src/App.tsx),
   so a preset here looks like the same preset there. Swift sends the name;
   the hex never crosses the bridge. */
const SHELLS: Record<string, string> = {
  Cobalt: '#2b49a3',
  Tomato: '#c8372d',
  Tangerine: '#e2762a',
  Mustard: '#e0ad1f',
  Mint: '#2f8f58',
  Teal: '#1f8189',
  Grape: '#6a45b8',
  Bubblegum: '#d9558f',
  Graphite: '#3a3d44',
  Porcelain: '#e6e6ea',
};
const TRIMS: Record<string, string> = {
  Steel: '#93a6c8',
  Silver: '#c4c9d2',
  Brass: '#c9a45c',
  Copper: '#c27a52',
  Black: '#2a2c31',
};
const SCREENS: Record<string, string> = {
  White: '#e8f2ff',
  Ice: '#7fe7ff',
  Matrix: '#7dff9a',
  Amber: '#ffc46b',
  Neon: '#ff8fd0',
};

interface Look {
  shape: RobotHeadShape;
  shell: string;
  trim: string;
  screen: string;
  speed: number;
  paused: boolean;
  antenna: boolean;
}

const look: Look = { shape: 'rectangle', shell: 'Cobalt', trim: 'Steel', screen: 'White', speed: 1, paused: false, antenna: true };

/* Materials are robot-heads' own (RobotHead.tsx palette()); a swatch only
   changes the albedo. */
function paletteFor(l: Look): Palette {
  const shell = parseColor(SHELLS[l.shell]) ?? [43, 73, 163];
  const trim = parseColor(TRIMS[l.trim]) ?? [147, 166, 200];
  const led = parseColor(SCREENS[l.screen]) ?? [232, 242, 255];
  return {
    shell: { albedo: linear(shell), f0: 0.05, metal: 0.15, spec: 0.55, shininess: 70, rim: 0.9 },
    trim: { albedo: linear(trim), f0: 0.2, metal: 0.65, spec: 0.8, shininess: 45, rim: 0.7 },
    led,
  };
}

const canvas = document.getElementById('head') as HTMLCanvasElement;
const ctx = canvas.getContext('2d')!;
const renderer = new RobotRenderer();
let state: RobotHeadState = 'idle';
const sim = new RobotSim(Math.random(), state);
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;
const dpr = Math.min(2, devicePixelRatio || 1);

/* Rebuilt whenever the look changes. The Shape object is held, not re-made
   per frame: the renderer re-bakes the head whenever its identity changes. */
let shape = getShape(look.shape);
let frame = frameFor(shape, look.antenna, SIZE);
let palette = paletteFor(look);

function paint(animated: boolean) {
  renderer.draw(ctx, frame, dpr, animated ? sim.pose : restPose(state), animated ? sim : null, state, shape, palette, { floorShadow: false, antenna: look.antenna });
}

/** Size the canvas to the current frame; returns its CSS size. */
function resize(): [number, number] {
  const cssW = frame.box + 2 * frame.padSide;
  const cssH = frame.box + frame.padTop + frame.padBottom;
  canvas.width = Math.round(cssW * dpr);
  canvas.height = Math.round(cssH * dpr);
  canvas.style.width = `${cssW}px`;
  canvas.style.height = `${cssH}px`;
  return [cssW, cssH];
}

// Swift calls this with the content of the state file; unknown values fall back to idle.
(window as unknown as { setState: (s: string) => void }).setState = (s: string) => {
  state = (STATES as string[]).includes(s) ? (s as RobotHeadState) : 'idle';
  sim.setState(state);
  // Paused and reduced motion both sit outside the ticker, so repaint here.
  if (reducedMotion || look.paused) paint(false);
};

/**
 * Swift calls this with any subset of the look; anything missing or
 * unknown keeps its current value. Returns the canvas's CSS size, so the
 * window can follow a shape or antenna change that moves the head's bounds.
 */
(window as unknown as { setLook: (next: unknown) => [number, number] }).setLook = (next: unknown) => {
  const n = (next ?? {}) as Partial<Record<keyof Look, unknown>>;
  if (typeof n.shape === 'string' && (SHAPES as string[]).includes(n.shape)) look.shape = n.shape as RobotHeadShape;
  if (typeof n.shell === 'string' && n.shell in SHELLS) look.shell = n.shell;
  if (typeof n.trim === 'string' && n.trim in TRIMS) look.trim = n.trim;
  if (typeof n.screen === 'string' && n.screen in SCREENS) look.screen = n.screen;
  if (typeof n.speed === 'number' && n.speed > 0 && n.speed <= 4) look.speed = n.speed;
  if (typeof n.paused === 'boolean') look.paused = n.paused;
  if (typeof n.antenna === 'boolean') look.antenna = n.antenna;

  shape = getShape(look.shape);
  frame = frameFor(shape, look.antenna, SIZE);
  palette = paletteFor(look);
  const size = resize();
  paint(!reducedMotion && !look.paused);
  return size;
};

canvas.addEventListener('click', () => sim.poke());

resize();
if (reducedMotion) paint(false);
else
  subscribe((dt) => {
    // Paused freezes the head on the frame it is already showing.
    if (look.paused) return;
    if (Number.isFinite(pointer.x)) {
      const box = canvas.getBoundingClientRect();
      sim.pointer = { x: pointer.x - (box.left + box.width / 2), y: pointer.y - (box.top + frame.cy) };
    } else sim.pointer = null;
    sim.update(dt * look.speed);
    paint(true);
  });
