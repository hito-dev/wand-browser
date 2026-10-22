"""Offline tests of published routes, localization completeness and release exports."""
import copy
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest
import xml.etree.ElementTree as ET
from html.parser import HTMLParser

spec = importlib.util.spec_from_file_location('build_site', Path(__file__).resolve().parents[1] / 'scripts/build-site.py')
site = importlib.util.module_from_spec(spec)
spec.loader.exec_module(site)

class Document(HTMLParser):
    def __init__(self,text):
        super().__init__(); self.elements=[]; self.feed(text)
    def handle_starttag(self,tag,attrs): self.elements.append((tag,dict(attrs)))
    def matching(self,tag,**attrs):
        return [a for t,a in self.elements if t==tag and all(a.get(k)==v for k,v in attrs.items())]

class SiteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp=tempfile.TemporaryDirectory(); cls.root=Path(cls.tmp.name)
        cls.output=cls.root/'web'; cls.metadata=cls.root/'metadata'
        cls.urls=site.build(cls.output,cls.metadata)
        cls.registry,cls.content=site.load_content()
    @classmethod
    def tearDownClass(cls): cls.tmp.cleanup()
    def test_all_indexable_routes_and_discovery(self):
        expected={site.ORIGIN+u for u in self.urls}|{site.ORIGIN+'/privacy/'}
        self.assertEqual(len(expected),126)
        xml=ET.parse(self.output/'sitemap.xml')
        self.assertEqual({e.text for e in xml.findall('.//{*}loc')},expected)
        for r in self.registry:
            for page in site.PAGES:
                url=site.route(r,page)
                text=site.file_for(self.output,url).read_text()
                doc=Document(text)
                self.assertEqual(doc.matching('html')[0]['lang'],r['lang'])
                self.assertEqual(doc.matching('html')[0]['dir'],r['dir'])
                self.assertEqual(doc.matching('link',rel='canonical'),[{'rel':'canonical','href':site.ORIGIN+url}])
                alternatives=doc.matching('link',rel='alternate')
                self.assertEqual({a['hreflang']:a['href'] for a in alternatives if 'hreflang' in a},
                                 {**{x['lang']:site.ORIGIN+site.route(x,page) for x in self.registry},'x-default':site.ORIGIN+site.route(self.registry[0],page)})
                self.assertEqual(len(doc.matching('h1')),1)
                self.assertFalse(doc.matching('meta',name='robots',content='noindex'))
                for key in (() if page=='support' else ('requirements',)):
                    self.assertIn(site.esc(self.content[r['code']][key]) if page!='fixture' else site.esc(self.content[r['code']]['fixtureIntro']),text)
                for x in self.registry:
                    self.assertTrue(doc.matching('a',href=site.route(x,page),hreflang=x['lang']))
                mirror=next(a['href'] for a in alternatives if a.get('type')=='text/markdown')
                md=site.file_for(self.output,mirror).read_text()
                self.assertIn(self.content[r['code']][page],md)
                self.assertIn(site.ORIGIN+url,md)
                llms=self.output/('' if r['code']=='en' else r['code'])/'llms.txt'
                self.assertIn(site.ORIGIN+mirror,llms.read_text())
    def test_support_page_and_discovery(self):
        for locale in self.registry:
            d=self.content[locale['code']]
            url=site.route(locale,'support')
            text=site.file_for(self.output,url).read_text()
            doc=Document(text)
            self.assertEqual(doc.matching('meta',name='description')[0]['content'],d['supportDescription'])
            self.assertEqual(len(doc.matching('h2')),5)
            for href in ('mailto:support-wand@hito.ai',site.SOURCE+'/issues',
                         'https://hito.ai/wand/','/privacy/',site.route(locale,'fixture')):
                self.assertTrue(doc.matching('a',href=href),href)
            for label in ('Site controls','Clear website data','Recent pages','Clear'):
                self.assertIn(label,text)
            for page in site.PAGES:
                page_doc=Document(site.file_for(self.output,site.route(locale,page)).read_text())
                self.assertTrue(page_doc.matching('a',href=url))
                self.assertEqual(len(page_doc.matching('details',**{'class':'language-switcher'})),1)
                self.assertEqual(page_doc.matching('summary')[0]['aria-label'],d['languages'])
                language_links=[a for a in page_doc.matching('a') if 'hreflang' in a]
                self.assertEqual(len(language_links),25)
                self.assertEqual([a['href'] for a in language_links if a.get('aria-current')=='page'],[site.route(locale,page)])
            mirror=site.file_for(self.output,url+'index.md').read_text()
            for section in site.SUPPORT_SECTIONS:
                self.assertIn('## '+d['support'+section.title()+'Title'],mirror)
            self.assertIn('mailto:support-wand@hito.ai',mirror)
            prefix='' if locale['code']=='en' else locale['code']
            self.assertIn(site.ORIGIN+url,(self.output/prefix/'llms.txt').read_text())
            if locale['code']!='en':
                for key in self.content['en']:
                    if key.startswith('support'):
                        self.assertNotEqual(d[key],self.content['en'][key],(locale['code'],key))
        self.assertEqual(set(site.FLAGS),{r['code'] for r in self.registry})
        self.assertEqual(site.badge({'code':'pt-br'}),'<span aria-hidden="true">🇧🇷</span> <b>PT</b>')
        self.assertEqual(site.badge({'code':'pt-pt'}),'<span aria-hidden="true">🇵🇹</span> <b>PT</b>')
    def test_fixture_contract_and_utilities(self):
        for r in self.registry:
            doc=Document(site.file_for(self.output,site.route(r,'fixture')).read_text())
            for id in ('ble','scan','abort','text','write','binary','console','console-divider','log','child'):
                self.assertEqual(len([a for _,a in doc.elements if a.get('id')==id]),1)
            self.assertEqual(doc.matching('iframe')[0]['src'],'/fixtures/child.html')
            self.assertIn('hidden',doc.matching('iframe')[0])
            url=site.route(r,'fixture').replace('bridge.html','second.html')
            utility=Document(site.file_for(self.output,url).read_text())
            self.assertTrue(utility.matching('meta',name='robots',content='noindex'))
        self.assertTrue(Document((self.output/'fixtures/child.html').read_text()).matching('meta',name='robots',content='noindex'))
        self.assertEqual((self.output/'privacy/index.html').read_bytes(),(site.ROOT/'ios/WandBrowser/Resources/PrivacyPolicy.html').read_bytes())
    def test_metadata_mapping_and_limits(self):
        self.assertEqual(len(list(self.metadata.glob('*/metadata.json'))),20)
        for r in self.registry:
            if not r['apple']: continue
            data=json.loads((self.metadata/r['apple']/'metadata.json').read_text())
            self.assertEqual(data['marketingUrl'],site.ORIGIN+site.route(r,'home'))
            self.assertEqual(data['feedbackEmail'],'support-wand@hito.ai')
            for key in ('betaAppDescription','whatToTest'):
                self.assertLessEqual(len(data[key]),4000)
                self.assertEqual((self.metadata/r['apple']/(key+'.txt')).read_text(),data[key]+'\n')
        self.assertFalse((self.output/'metadata').exists())
    def test_missing_keys_placeholders_mappings_and_links_fail(self):
        with tempfile.TemporaryDirectory() as temp:
            src=Path(temp)/'site'; shutil.copytree(site.ROOT/'site',src)
            target=src/'locales/de.json'; original=target.read_text()
            bad=json.loads(original); del bad['scan']; target.write_text(json.dumps(bad))
            with self.assertRaisesRegex(AssertionError,'Missing translation'): site.load_content(src)
            bad=json.loads(original); bad['selected']='Missing placeholder'; target.write_text(json.dumps(bad))
            with self.assertRaisesRegex(AssertionError,'Placeholder'): site.load_content(src)
            target.write_text(original)
            registry=json.loads((src/'languages.json').read_text()); del registry[1]['apple']
            (src/'languages.json').write_text(json.dumps(registry))
            with self.assertRaises((AssertionError,KeyError)): site.load_content(src)
        broken=self.output/'broken.html'; broken.write_text('<a href="/missing-page/">broken</a>')
        try:
            with self.assertRaisesRegex(AssertionError,'Broken internal link'): site.validate(self.output,self.urls)
        finally: broken.unlink()

if __name__=='__main__': unittest.main()
