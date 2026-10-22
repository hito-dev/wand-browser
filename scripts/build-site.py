#!/usr/bin/env python3
"""Build the static website and optional TestFlight handoff using only stdlib."""
import argparse
import html
import json
from pathlib import Path
import re
import shutil
from string import Formatter, Template
from urllib.parse import urljoin, urlparse, unquote
from html.parser import HTMLParser
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
ORIGIN = 'https://wand.hito.ai'
SOURCE = 'https://github.com/hito-dev/wand-browser'
PAGES = {'home': '', 'fixture': 'fixtures/bridge.html', 'bluetooth': 'web-bluetooth-iphone/', 'nfc': 'web-nfc-iphone/', 'support': 'support/'}
LOG_KEYS = ('selected', 'connected', 'disconnected', 'read', 'unavailable', 'readingError', 'active', 'written', 'binaryWritten', 'height')

def load_content(source=ROOT / 'site'):
    registry = json.loads((source / 'languages.json').read_text())
    codes = [r['code'] for r in registry]
    assert len(set(codes)) == len(codes) and codes[0] == 'en', 'Duplicate locales or missing English source'
    assert len({r['lang'] for r in registry}) == len(registry), 'Duplicate hreflang'
    apple = [r['apple'] for r in registry if r['apple']]
    assert len(set(apple)) == len(apple), 'Duplicate Apple locale'
    assert set(p.stem for p in (source / 'locales').glob('*.json')) == set(codes), 'Locale registry mismatch'
    content = {c: json.loads((source / 'locales' / (c + '.json')).read_text()) for c in codes}
    base = content['en']
    for r in registry:
        assert set(r) == {'code', 'lang', 'apple', 'dir'}, 'Missing locale mapping'
        assert re.fullmatch('[a-z]+(?:-[a-z]+)*', r['code']), 'Invalid URL locale'
        assert r['dir'] in ('ltr', 'rtl')
        for key, value in content[r['code']].items():
            assert isinstance(value, str) and value.strip(), (r['code'], key, 'Empty translation')
            expected = {f for _, f, _, _ in Formatter().parse(base.get(key, '')) if f}
            actual = {f for _, f, _, _ in Formatter().parse(value) if f}
            assert actual == expected, (r['code'], key, 'Placeholder mismatch')
        assert content[r['code']].keys() == base.keys(), (r['code'], 'Missing translation keys')
    return registry, content

def route(locale, page):
    return '/' + (locale['code'] + '/' if locale['code'] != 'en' else '') + PAGES[page]

def file_for(output, path):
    return output / (path.lstrip('/') + ('index.html' if path.endswith('/') else ''))

def write(output, path, value):
    dest = file_for(output, path)
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(value, encoding='utf-8')

def esc(value):
    return html.escape(value, quote=True)

FLAGS = dict(zip(('en','de','es','zh-hans','ja','pt-br','pt-pt','fr','ru','it','nl','pl','tr','ko','vi','hi','id','ms','uk','ar','af','sw','ha','yo','am'), ('🇺🇸','🇩🇪','🇪🇸','🇨🇳','🇯🇵','🇧🇷','🇵🇹','🇫🇷','🇷🇺','🇮🇹','🇳🇱','🇵🇱','🇹🇷','🇰🇷','🇻🇳','🇮🇳','🇮🇩','🇲🇾','🇺🇦','🇸🇦','🇿🇦','🇹🇿','🇳🇬','🇳🇬','🇪🇹')))

def badge(locale):
    return '<span aria-hidden="true">{}</span> <b>{}</b>'.format(FLAGS[locale['code']], locale['code'].split('-')[0][:2].upper())

def switcher(locale, page, d, registry, content):
    langs = ''.join('<a lang="{lang}" dir="{dir}" hreflang="{lang}" href="{url}"{current}>{badge} <span>{name}</span></a>'.format(**r, url=route(r,page), badge=badge(r), name=esc(content[r['code']]['name']), current=' aria-current="page"' if r==locale else '') for r in registry)
    return '<details class="language-switcher"><summary aria-label="{}">{}</summary><div class="languages">{}</div></details>'.format(esc(d['languages']), badge(locale), langs)

def nav(locale, page, d):
    links = ''.join('<a href="{}"{}>{}</a>'.format(route(locale, p), ' aria-current="page"' if p == page else '', esc(d[p])) for p in PAGES)
    return '<nav>{}</nav>'.format(links)

SUPPORT_SECTIONS = ('start', 'ble', 'nfc', 'permissions', 'data')

def support_blocks(d, locale):
    values = dict(email='[support-wand@hito.ai](mailto:support-wand@hito.ai)', issues='[{}]({}/issues)'.format(d['supportIssues'],SOURCE), fixture='[{}]({}{})'.format(d['fixture'],ORIGIN,route(locale,'fixture')), product='[{}](https://hito.ai/wand/)'.format(d['supportProduct']))
    return [d['supportDescription'], d['supportContact'].format(**values), d['supportSafety']] + ['## '+d['support'+key.title()+'Title']+'\n\n'+d['support'+key.title()].format(**values) for key in SUPPORT_SECTIONS]

def support_html(d, locale):
    values = dict(email='<a href="mailto:support-wand@hito.ai">support-wand@hito.ai</a>', issues='<a href="'+SOURCE+'/issues">'+esc(d['supportIssues'])+'</a>', fixture='<a href="'+route(locale,'fixture')+'">'+esc(d['fixture'])+'</a>', product='<a href="https://hito.ai/wand/">'+esc(d['supportProduct'])+'</a>')
    result = '<p>'+esc(d['supportContact']).format(**values)+'</p>'+paragraphs(d['supportSafety'])
    for key in SUPPORT_SECTIONS:
        result += '<h2>'+esc(d['support'+key.title()+'Title'])+'</h2><p>'+esc(d['support'+key.title()]).format(**values)+'</p>'
    return result

def paragraphs(*texts):
    return ''.join('<p>{}</p>'.format(esc(s)) for s in texts)

def build(output, metadata=None, source=ROOT / 'site'):
    registry, content = load_content(source)
    output.mkdir(parents=True, exist_ok=True)
    assert not any(output.iterdir()), 'Use an empty output directory'
    shutil.copytree(source / 'assets', output / 'assets')
    shutil.copyfile(ROOT / 'tests/fixtures/favicon.png', output / 'favicon.png')
    shutil.copyfile(ROOT / 'LICENSE', output / 'LICENSE.txt')
    shutil.copyfile(source / 'robots.txt', output / 'robots.txt')
    write(output, '/privacy/', (ROOT / 'ios/WandBrowser/Resources/PrivacyPolicy.html').read_text())
    write(output, '/.nojekyll', '')
    for name in ('child.html', 'hito_ble_transport.js', 'sdk-provenance.json'):
        dest = output / 'fixtures' / name
        dest.parent.mkdir(exist_ok=True)
        text = (ROOT / 'tests/fixtures' / name).read_text()
        if name.endswith('.html'):
            text = text.replace('<html', '<meta name="robots" content="noindex">\n<html', 1)
        dest.write_text(text)
    urls = []
    for locale in registry:
        d = content[locale['code']]
        prefix = '/' + (locale['code'] + '/' if locale['code'] != 'en' else '')
        llms = '# {}\n\n{}\n\n{}\n\n'.format(d['home'], d['intro'], d['requirements'])
        for page in PAGES:
            url = route(locale, page)
            assert url not in urls, 'Duplicate route: ' + url
            urls.append(url)
            navigation = nav(locale, page, d)
            blocks = {'home': [d['intro'], d['requirements'], d['install']], 'fixture': [d['fixtureIntro'], d['bleGuide'], d['nfcGuide'], d['trouble']], 'bluetooth': [d['bleGuide'], d['requirements'], d['trouble']], 'nfc': [d['nfcGuide'], d['requirements'], d['trouble']]}
            blocks['support'] = support_blocks(d, locale)
            description = blocks[page][0]
            mirror = url + ('index.md' if url.endswith('/') else '.md')
            head = '<!doctype html>\n<html lang="{}" dir="{}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover"><title>{}</title><meta name="description" content="{}"><link rel="canonical" href="{}">'.format(locale['lang'],locale['dir'],esc(d[page]),esc(description), ORIGIN+url)
            head += ''.join('<link rel="alternate" hreflang="{}" href="{}">'.format(r['lang'],ORIGIN+route(r,page)) for r in registry)
            head += '<link rel="alternate" hreflang="x-default" href="{}"><link rel="alternate" type="text/markdown" href="{}"><link rel="describedby" type="text/plain" href="{}llms.txt"><link rel="icon" type="image/png" sizes="64x64" href="/favicon.png"><link rel="stylesheet" href="/assets/site.css">'.format(ORIGIN+route(registry[0],page),mirror,prefix)
            head += '<script defer src="https://stat.hito.ai/script.js" data-website-id="8453ddb7-edef-41fa-8684-79e94f6940cf"></script>'
            language_control = switcher(locale, page, d, registry, content)
            footer = '<footer><a href="{0}">{1}</a> · <a href="{3}">{4}</a> · <a href="/privacy/">{2}</a> · <a href="/LICENSE.txt">MIT</a></footer>'.format(SOURCE,esc(d['source']),esc(d['privacy']),route(locale,'support'),esc(d['support']))
            if page == 'fixture':
                head += '<link rel="stylesheet" href="/assets/fixture.css"><script defer src="/assets/languages.js"></script></head><body>'
                # Keep the trusted scripts separate from translated data. Escape < even inside JSON.
                data = json.dumps({k:d[k] for k in LOG_KEYS},ensure_ascii=False).replace('<','\\u003c')
                init = '<script id="fixture-messages" type="application/json">'+data+'</script><script src="/assets/fixture-i18n.js"></script><script src="/assets/fixture-layout.js"></script><script type="module" src="/assets/fixture-actions.js"></script>'
                body = Template((source / 'templates/fixture.html').read_text()).substitute(**{k:esc(v) for k,v in d.items()},navigation=navigation+paragraphs(d['bleGuide'],d['nfcGuide'],d['trouble'])+footer)
                body = language_control + body + init
            else:
                head += '<script defer src="/assets/languages.js"></script></head><body>'
                body = '<main><h1>{}</h1>{}{}'.format(esc(d[page]),navigation,support_html(d,locale) if page == 'support' else paragraphs(*blocks[page]))
                body = language_control + body
                body += '<p><a href="{}">{}</a> · <a href="{}#readme">{}</a></p>'.format(route(locale,'fixture'),esc(d['fixture']),SOURCE,esc(d['source']))
                if page == 'home' and (output / 'assets/screenshots/home.png').exists():
                    body += '<div class="gallery">'+''.join('<figure><a href="/assets/screenshots/{0}.png"><img src="/assets/screenshots/{0}.png" alt="{1}" width="1206" height="2622" loading="lazy"></a><figcaption>{1}</figcaption></figure>'.format(name,esc(d[label])) for name,label in [('home','home'),('fixture','fixture'),('site-controls','siteControls')])+'</div>'
                body += footer+'</main>'
            write(output,url,head+body+'</body></html>\n')
            md = '# {}\n\n{}\n\n'.format(d[page], '\n\n'.join(blocks[page]))
            md += '\n'.join('- [{}]({})'.format(d[p],ORIGIN+route(locale,p)) for p in PAGES)+'\n\n[{}]({})\n[{}]({}/privacy/)\n'.format(d['source'],SOURCE,d['privacy'],ORIGIN)
            if page=='fixture':
                md += '\n'+'\n'.join('- '+d[k] for k in ('choose','scan','stop','text','write','binary','resize','console'))+'\n'
            write(output,mirror,md)
            llms += '- [{}]({}) — [Markdown]({})\n'.format(d[page], ORIGIN+url, ORIGIN+mirror)
        llms += '\n[{}]({})\n[{}]({}/privacy/)\n[MIT]({}/LICENSE.txt)\n'.format(d['source'],SOURCE,d['privacy'],ORIGIN,ORIGIN)
        if locale['code']=='en':
            llms += '\n## Languages\n'+''.join('- [{}]({}{}llms.txt)\n'.format(content[r['code']]['name'],ORIGIN,'/'+r['code']+'/') for r in registry[1:])
        write(output,prefix+'llms.txt',llms)
        utility = '<!doctype html><html lang="{}" dir="{}"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex"><link rel="icon" href="/favicon.png"><title>{}</title><h1>{}</h1><a href="./bridge.html">{}</a></html>'.format(locale['lang'],locale['dir'],esc(d['second']),esc('Second page' if locale['code']=='en' else d['second']),esc(d['fixture']))
        write(output,prefix+'fixtures/second.html',utility)
        if metadata and locale['apple']:
            directory = metadata / locale['apple']
            directory.mkdir(parents=True,exist_ok=True)
            fields = {'betaAppDescription':d['intro']+'\n\n'+d['requirements'], 'whatToTest': d['testing']+'\n\n'+d['bleGuide']+'\n\n'+d['nfcGuide']+'\n\n'+d['trouble'], 'feedbackEmail':'support-wand@hito.ai', 'marketingUrl':ORIGIN+route(locale,'home'), 'privacyPolicyUrl':ORIGIN+'/privacy/'}
            for key in ('betaAppDescription','whatToTest'):
                assert len(fields[key]) <= 4000, (locale['code'],key,'Apple field too long')
            (directory / 'metadata.json').write_text(json.dumps(fields,ensure_ascii=False,indent=2)+'\n')
            for key in ('betaAppDescription','whatToTest'):
                (directory / (key+'.txt')).write_text(fields[key]+'\n')
    sitemap = ET.Element('urlset',xmlns='http://www.sitemaps.org/schemas/sitemap/0.9')
    for url in urls+['/privacy/']:
        ET.SubElement(ET.SubElement(sitemap,'url'),'loc').text=ORIGIN+url
    (output / 'sitemap.xml').write_bytes(ET.tostring(sitemap,encoding='utf-8',xml_declaration=True))
    validate(output,urls)
    return urls

class Links(HTMLParser):
    def __init__(self):
        super().__init__(); self.links=[]
    def handle_starttag(self,tag,attrs):
        a=dict(attrs)
        for k in ('src','href'):
            if a.get(k): self.links.append(a[k])

def validate(output, urls):
    for page in output.rglob('*.html'):
        parsed=Links(); parsed.feed(page.read_text())
        url='/'+str(page.relative_to(output))
        for link in parsed.links:
            target=urlparse(urljoin(ORIGIN+url,link))
            if target.netloc != urlparse(ORIGIN).netloc: continue
            path=unquote(target.path)
            assert file_for(output,path).is_file(), (url,link,'Broken internal link')
    assert len(urls)==len(set(urls)), 'Duplicate routes'

if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--metadata-output',type=Path)
    args=parser.parse_args()
    build(args.output,args.metadata_output)
