/* Native details and ordinary anchors also work without this enhancement. */
const languageSwitcher = document.querySelector('.language-switcher');
if (languageSwitcher) {
  const summary = languageSwitcher.querySelector('summary');
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape' && languageSwitcher.open) {
      event.preventDefault();
      languageSwitcher.open = false;
      summary.focus();
    }
  });
  document.addEventListener('click', event => {
    if (!languageSwitcher.contains(event.target)) languageSwitcher.open = false;
  });
}
