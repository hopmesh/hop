#!/usr/bin/env python
"""Assemble preview.html: lottie-web + the animation JSON, fully inlined."""
from pathlib import Path

HERE = Path(__file__).parent
ljs = HERE / "lottie.min.js"
if not ljs.exists():
    import urllib.request
    urllib.request.urlretrieve(
        "https://unpkg.com/lottie-web@5.12.2/build/player/lottie.min.js", ljs)
player = ljs.read_text()
anim = (HERE / "hop-wordmark-drawon.json").read_text()

html = """<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>hop wordmark draw-on</title>
<style>
  :root { color-scheme: dark; }
  body { margin: 0; background: #101418; color: #d7e0e6; font: 14px/1.5 -apple-system, system-ui, sans-serif;
         min-height: 100vh; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 18px; }
  body.light { background: #f4f6f5; color: #22302b; }
  #stage { width: min(90vw, 980px); }
  #controls { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; justify-content: center; }
  button, select { background: #1d242b; color: inherit; border: 1px solid #2e3942; border-radius: 8px;
           padding: 7px 14px; font: inherit; cursor: pointer; }
  body.light button, body.light select { background: #fff; border-color: #c8d2cd; }
  button:hover { border-color: #2bf0a0; }
  input[type=range] { width: 260px; accent-color: #2bf0a0; }
</style>
</head>
<body>
<div id="stage"></div>
<div id="controls">
  <button id="replay">Replay</button>
  <button id="pause">Pause</button>
  <input id="scrub" type="range" min="0" max="1000" value="0">
  <select id="speed">
    <option value="0.5">0.5x</option>
    <option value="1" selected>1x</option>
    <option value="1.5">1.5x</option>
  </select>
  <label><input id="loop" type="checkbox"> loop</label>
  <button id="theme">Light/dark</button>
</div>
<script>__LOTTIE_PLAYER__</script>
<script>
const data = __ANIM_DATA__;
const anim = lottie.loadAnimation({
  container: document.getElementById('stage'),
  renderer: 'svg', loop: false, autoplay: true, animationData: data,
});
const scrub = document.getElementById('scrub');
let scrubbing = false;
anim.addEventListener('enterFrame', () => {
  if (!scrubbing) scrub.value = Math.round(1000 * anim.currentFrame / (anim.totalFrames - 1));
});
scrub.addEventListener('input', e => {
  scrubbing = true;
  anim.goToAndStop((anim.totalFrames - 1) * e.target.value / 1000, true);
});
scrub.addEventListener('change', () => { scrubbing = false; });
document.getElementById('replay').onclick = () => { scrubbing = false; anim.stop(); anim.play(); };
document.getElementById('pause').onclick = e => {
  if (anim.isPaused) { anim.play(); e.target.textContent = 'Pause'; }
  else { anim.pause(); e.target.textContent = 'Play'; }
};
document.getElementById('speed').onchange = e => anim.setSpeed(parseFloat(e.target.value));
document.getElementById('loop').onchange = e => { anim.loop = e.target.checked; };
document.getElementById('theme').onclick = () => document.body.classList.toggle('light');
</script>
</body>
</html>
"""
html = html.replace("__LOTTIE_PLAYER__", player).replace("__ANIM_DATA__", anim)
(HERE / "preview.html").write_text(html)
print("preview.html", (HERE / "preview.html").stat().st_size // 1024, "KB")
