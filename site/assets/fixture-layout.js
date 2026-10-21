
const output = document.querySelector("#log");
const followingOutput = () => output.scrollHeight - output.clientHeight - output.scrollTop <= 24;
function log(text) {
  const follow = followingOutput();
  output.append(document.createTextNode("\n" + text));
  if (follow) output.scrollTop = output.scrollHeight;
}

const divider = document.querySelector("#console-divider");
let consoleRatio = 0.2;
function resizeConsole(ratio = consoleRatio) {
  const height = document.body.getBoundingClientRect().height;
  if (!height) return;
  const minimum = Math.min(80, height / 2);
  const consoleHeight = Math.min(height - minimum, Math.max(minimum, height * ratio));
  document.body.style.setProperty("--console-height", `${consoleHeight}px`);
  divider.setAttribute("aria-valuemin", String(Math.round(minimum / height * 100)));
  divider.setAttribute("aria-valuemax", String(Math.round((height - minimum) / height * 100)));
  divider.setAttribute("aria-valuenow", String(Math.round(consoleHeight / height * 100)));
  divider.setAttribute("aria-valuetext", t("height", {percent: Math.round(consoleHeight / height * 100)}));
  return consoleHeight / height;
}
let drag = null;
divider.addEventListener("pointerdown", event => {
  if (drag || !event.isPrimary || event.button !== 0) return;
  event.preventDefault();
  const bounds = document.body.getBoundingClientRect();
  drag = { id: event.pointerId, offset: bounds.bottom - event.clientY - document.querySelector("#console").getBoundingClientRect().height };
  divider.setPointerCapture(event.pointerId);
});
divider.addEventListener("pointermove", event => {
  if (!drag || event.pointerId !== drag.id) return;
  const bounds = document.body.getBoundingClientRect();
  const follow = followingOutput();
  consoleRatio = resizeConsole((bounds.bottom - event.clientY - drag.offset) / bounds.height);
  if (follow) output.scrollTop = output.scrollHeight;
});
function endDrag(event) {
  if (!drag || event.pointerId !== drag.id) return;
  drag = null;
  if (divider.hasPointerCapture(event.pointerId)) divider.releasePointerCapture(event.pointerId);
}
divider.addEventListener("pointerup", endDrag);
divider.addEventListener("pointercancel", endDrag);
divider.addEventListener("lostpointercapture", endDrag);
divider.addEventListener("keydown", event => {
  const currentRatio = document.querySelector("#console").getBoundingClientRect().height / document.body.getBoundingClientRect().height;
  let ratio;
  if (event.key === "ArrowUp") ratio = currentRatio + 0.05;
  else if (event.key === "ArrowDown") ratio = currentRatio - 0.05;
  else if (event.key === "Home") ratio = 0;
  else if (event.key === "End") ratio = 1;
  else return;
  event.preventDefault();
  const follow = followingOutput();
  consoleRatio = resizeConsole(ratio);
  if (follow) output.scrollTop = output.scrollHeight;
});

function updateViewport() {
  const viewport = window.visualViewport;
  // Leave pinch zoom to the browser; only fit unzoomed viewport/keyboard changes.
  if (viewport && viewport.scale !== 1) return;
  const follow = followingOutput();
  document.documentElement.style.setProperty("--viewport-height", `${viewport?.height ?? window.innerHeight}px`);
  document.documentElement.style.setProperty("--viewport-top", `${viewport?.offsetTop ?? 0}px`);
  resizeConsole();
  requestAnimationFrame(() => {
    if (follow) output.scrollTop = output.scrollHeight;
    const focused = document.activeElement;
    if (focused?.matches("input") && document.querySelector("#controls").contains(focused)) {
      focused.scrollIntoView({ block: "nearest", inline: "nearest" });
    }
  });
}
window.visualViewport?.addEventListener("resize", updateViewport);
window.visualViewport?.addEventListener("scroll", updateViewport);
window.addEventListener("resize", updateViewport);
document.addEventListener("fullscreenchange", updateViewport);
updateViewport();

