/* Plain-DOM stand-in for robot-heads' React wrapper (RobotHead.tsx): one
   head on one canvas, driven by window.setState() from the Swift side. */
import type { RobotHeadState } from './types';
import { getShape } from './tv/geometry';
import { RobotSim, restPose } from './tv/sim';
import { RobotRenderer, frameFor, type Palette } from './tv/render';
import { linear } from './tv/light';
import { subscribe, pointer } from './ticker';

const STATES: RobotHeadState[] = ['idle', 'thinking', 'searching', 'listening', 'speaking', 'working', 'happy', 'error', 'sleeping'];
const SIZE = 120;

const palette: Palette = {
  shell: { albedo: linear([43, 73, 163]), f0: 0.05, metal: 0.15, spec: 0.55, shininess: 70, rim: 0.9 },
  trim: { albedo: linear([147, 166, 200]), f0: 0.2, metal: 0.65, spec: 0.8, shininess: 45, rim: 0.7 },
  led: [232, 242, 255],
};

const shape = getShape('rectangle');
const frame = frameFor(shape, true, SIZE);
const canvas = document.getElementById('head') as HTMLCanvasElement;
const ctx = canvas.getContext('2d')!;
const renderer = new RobotRenderer();
let state: RobotHeadState = 'idle';
const sim = new RobotSim(Math.random(), state);

const dpr = Math.min(2, devicePixelRatio || 1);
const cssW = frame.box + 2 * frame.padSide;
const cssH = frame.box + frame.padTop + frame.padBottom;
canvas.width = Math.round(cssW * dpr);
canvas.height = Math.round(cssH * dpr);
canvas.style.width = `${cssW}px`;
canvas.style.height = `${cssH}px`;

const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;

function paint(animated: boolean) {
  renderer.draw(ctx, frame, dpr, animated ? sim.pose : restPose(state), animated ? sim : null, state, shape, palette, { floorShadow: false, antenna: true });
}

// Swift calls this with the content of the state file; unknown values fall back to idle.
(window as unknown as { setState: (s: string) => void }).setState = (s: string) => {
  state = (STATES as string[]).includes(s) ? (s as RobotHeadState) : 'idle';
  sim.setState(state);
  if (reducedMotion) paint(false);
};

canvas.addEventListener('click', () => sim.poke());

if (reducedMotion) paint(false);
else
  subscribe((dt) => {
    if (Number.isFinite(pointer.x)) {
      const box = canvas.getBoundingClientRect();
      sim.pointer = { x: pointer.x - (box.left + box.width / 2), y: pointer.y - (box.top + frame.cy) };
    } else sim.pointer = null;
    sim.update(dt);
    paint(true);
  });
