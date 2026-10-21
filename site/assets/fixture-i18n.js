const fixtureMessages = JSON.parse(document.querySelector('#fixture-messages').textContent);
function t(key, values = {}) {
  return fixtureMessages[key].replace(/\{(\w+)\}/g, (_, name) => String(values[name]));
}
