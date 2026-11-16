// hex's views on the web (host/web/native-glue.js), so the web bake (scripts/publish) serves every
// tag app.json names. hex Exact lives on iOS (modules/apple/Hex.swift); here each view is a plain
// stand-in: hex-orb a still disc in the persona's tint, hex-media a quiet box (the web holds no
// token to read hex's copy with), hex-color the browser's own colour input.
export const abi = 1;
export const roster = { 'hex-orb': { snapshot: false }, 'hex-media': { snapshot: false }, 'hex-color': { snapshot: false } };

function draw(h, props) {
  if (h.tag === 'hex-orb') {
    const tint = props.tint || '#8E8E93';
    h.box.style.background = `radial-gradient(circle at 35% 30%, #fff8, ${tint} 55%, #000a)`;
    h.box.style.opacity = props.silenced === 'true' ? '0.5' : '1';
  }
  if (h.tag === 'hex-color' && props.hue) h.input.value = props.hue;
}

export function create(tag, element, json, event) {
  const props = JSON.parse(json);
  const root = element.shadowRoot ?? element.attachShadow({ mode: 'open' });
  const box = document.createElement('div');
  box.style.cssText = 'width:100%;height:100%;box-sizing:border-box';
  const h = { tag, box };
  if (tag === 'hex-orb') box.style.borderRadius = '50%';
  if (tag === 'hex-media') box.style.cssText += ';background:#8E8E9333;border-radius:8px';
  if (tag === 'hex-color') {
    h.input = document.createElement('input');
    h.input.type = 'color';
    h.input.style.cssText = 'width:100%;height:100%;padding:0;border:0;border-radius:50%;background:none;cursor:pointer';
    h.input.addEventListener('change', () => event(1, h.input.value.toUpperCase()));
    box.append(h.input);
  }
  root.replaceChildren(box);
  draw(h, props);
  return h;
}

export function setProps(h, json) {
  draw(h, JSON.parse(json));
}

export function destroy() {}
