#!/usr/bin/env python2.3
from basetest import BaseTest
import sys, tempfile, os, shutil, logging
from StringIO import StringIO
import unittest
from logging import getLogger, DEBUG, INFO

sys.path.insert(0, '..')

config_home = tempfile.mktemp()
cache_home = tempfile.mktemp()
os.environ['XDG_CONFIG_HOME'] = config_home
os.environ['XDG_CACHE_HOME'] = cache_home
os.environ['XDG_CACHE_DIRS'] = ''

from zeroinstall import NeedDownload
from zeroinstall.injector import model, basedir, autopolicy, gpg, iface_cache, namespaces, reader
import data
reload(basedir)

foo_iface_uri = 'http://foo'

logger = logging.getLogger()

class TestAutoPolicy(BaseTest):
	def setUp(self):
		BaseTest.setUp(self)
		stream = tempfile.TemporaryFile()
		stream.write(data.thomas_key)
		stream.seek(0)
		gpg.import_key(stream)
	
	def cache_iface(self, name, data):
		cached_ifaces = basedir.save_cache_path('0install.net',
							'interfaces')

		f = file(os.path.join(cached_ifaces, model.escape(name)), 'w')
		f.write(data)
		f.close()

	def testNoNeedDl(self):
		policy = autopolicy.AutoPolicy(foo_iface_uri,
						download_only = False)
		policy.freshness = 0
		assert policy.need_download()
		self.cache_iface(foo_iface_uri,
"""<?xml version="1.0" ?>
<interface last-modified="1110752708"
 uri="%s"
 xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Foo</name>
  <summary>Foo</summary>
  <description>Foo</description>
</interface>""" % foo_iface_uri)
		iface_cache.iface_cache._interfaces = {}
		assert not policy.need_download()
	
	def testUnknownAlg(self):
		self.cache_iface(foo_iface_uri,
"""<?xml version="1.0" ?>
<interface
 uri="%s"
 xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Foo</name>
  <summary>Foo</summary>
  <description>Foo</description>
  <implementation id='unknown=123' version='1.0'>
    <archive href='http://foo/foo.tgz' size='100'/>
  </implementation>
</interface>""" % foo_iface_uri)
		policy = autopolicy.AutoPolicy(foo_iface_uri,
						download_only = False)
		policy.freshness = 0
		try:
			assert policy.need_download()
			assert False
		except model.SafeException, ex:
			assert 'Unknown digest algorithm' in str(ex)
	
	def testDownload(self):
		tmp = tempfile.NamedTemporaryFile()
		tmp.write(
"""<?xml version="1.0" ?>
<interface
 main='ThisBetterNotExist'
 xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Foo</name>
  <summary>Foo</summary>
  <description>Foo</description>
  <implementation version='1.0' id='/bin'/>
</interface>""")
		tmp.flush()
		policy = autopolicy.AutoPolicy(tmp.name, False, False)
		try:
			policy.download_and_execute(['Hello'])
			assert 0
		except model.SafeException, ex:
			assert "ThisBetterNotExist" in str(ex)
		tmp.close()

	def testNoMain(self):
		tmp = tempfile.NamedTemporaryFile()
		tmp.write(
"""<?xml version="1.0" ?>
<interface
 xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Foo</name>
  <summary>Foo</summary>
  <description>Foo</description>
  <implementation version='1.0' id='/bin'/>
</interface>""")
		tmp.flush()
		policy = autopolicy.AutoPolicy(tmp.name, False, False)
		try:
			policy.download_and_execute(['Hello'])
			assert 0
		except model.SafeException, ex:
			assert "library" in str(ex)
		tmp.close()

	def testNeedDL(self):
		self.cache_iface(foo_iface_uri,
"""<?xml version="1.0" ?>
<interface last-modified="0"
 uri="%s"
 main='ThisBetterNotExist'
 xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Foo</name>
  <summary>Foo</summary>
  <description>Foo</description>
  <implementation version='1.0' id='sha1=123'>
    <archive href='http://foo/foo.tgz' size='100'/>
  </implementation>
</interface>""" % foo_iface_uri)
		policy = autopolicy.AutoPolicy(foo_iface_uri, False, True)
		policy.freshness = 0
		policy.network_use = model.network_full
		policy.recalculate()
		assert policy.need_download()
		try:
			policy.start_downloading_impls()
			assert False
		except NeedDownload, ex:
			pass

	def testBinding(self):
		tmp = tempfile.NamedTemporaryFile()
		tmp.write(
"""<?xml version="1.0" ?>
<interface
 main='testautopolicy.py'
 xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Bar</name>
  <summary>Bar</summary>
  <description>Bar</description>
  <group>
    <requires interface='%s'>
      <environment name='FOO_PATH' insert='.'/>
      <environment name='BAR_PATH' insert='.' default='/a:/b'/>
      <environment name='XDG_DATA_DIRS' insert='.'/>
    </requires>
    <implementation version='1.0' id='%s'/>
  </group>
</interface>""" % (foo_iface_uri, os.path.dirname(os.path.abspath(__file__))))
		tmp.flush()
		self.cache_iface(foo_iface_uri,
"""<?xml version="1.0" ?>
<interface last-modified="0"
 uri="%s"
 xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Foo</name>
  <summary>Foo</summary>
  <description>Foo</description>
  <implementation version='1.0' id='sha1=123'/>
</interface>""" % foo_iface_uri)
		cached_impl = basedir.save_cache_path('0install.net',
							'implementations',
							'sha1=123')
		policy = autopolicy.AutoPolicy(tmp.name, False,
						dry_run = True)
		policy.network_use = model.network_offline
		os.environ['FOO_PATH'] = "old"
		old, sys.stdout = sys.stdout, StringIO()
		try:
			policy.download_and_execute(['Hello'])
		finally:
			sys.stdout = old
		self.assertEquals(cached_impl + '/.:old',
				os.environ['FOO_PATH'])
		self.assertEquals(cached_impl + '/.:/a:/b',
				os.environ['BAR_PATH'])

		del os.environ['FOO_PATH']
		if 'XDG_DATA_DIRS' in os.environ:
			del os.environ['XDG_DATA_DIRS']
		os.environ['BAR_PATH'] = '/old'
		old, sys.stdout = sys.stdout, StringIO()
		try:
			policy.download_and_execute(['Hello'])
		finally:
			sys.stdout = old
		self.assertEquals(cached_impl + '/.',
				os.environ['FOO_PATH'])
		self.assertEquals(cached_impl + '/.:/old',
				os.environ['BAR_PATH'])
		self.assertEquals(cached_impl + '/.:/usr/local/share:/usr/share',
				os.environ['XDG_DATA_DIRS'])
	
	def testFeeds(self):
		self.cache_iface(foo_iface_uri,
"""<?xml version="1.0" ?>
<interface last-modified="0"
 uri="%s"
 xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Foo</name>
  <summary>Foo</summary>
  <description>Foo</description>
  <feed src='http://bar'/>
</interface>""" % foo_iface_uri)
		self.cache_iface('http://bar',
"""<?xml version="1.0" ?>
<interface last-modified="0"
 uri="http://bar"
 xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <feed-for interface='%s'/>
  <name>Bar</name>
  <summary>Bar</summary>
  <description>Bar</description>
  <implementation version='1.0' id='sha1=123'/>
</interface>""" % foo_iface_uri)
		policy = autopolicy.AutoPolicy(foo_iface_uri, False,
							dry_run = True)
		policy.freshness = 0
		policy.network_use = model.network_full
		policy.recalculate()
		assert policy.ready
		foo_iface = policy.get_interface(foo_iface_uri)
		self.assertEquals('sha1=123', policy.implementation[foo_iface].id)

	def testBadConfig(self):
		path = basedir.save_config_path(namespaces.config_site,
						namespaces.config_prog)
		glob = os.path.join(path, 'global')
		assert not os.path.exists(glob)
		stream = file(glob, 'w')
		stream.write('hello!')
		stream.close()

		logger.setLevel(logging.ERROR)
		policy = autopolicy.AutoPolicy(foo_iface_uri,
						download_only = False)
		logger.setLevel(logging.WARN)

	def testRanking(self):
		self.cache_iface('http://bar',
"""<?xml version="1.0" ?>
<interface last-modified="1110752708"
 uri="http://bar"
 xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Bar</name>
  <summary>Bar</summary>
  <description>Bar</description>
  <implementation id='sha1=125' version='1.0' arch='odd-weird' stability='buggy'/>
  <implementation id='sha1=126' version='1.0'/>
</interface>""")
		self.cache_iface(foo_iface_uri,
"""<?xml version="1.0" ?>
<interface last-modified="1110752708"
 uri="%s"
 xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Foo</name>
  <summary>Foo</summary>
  <description>Foo</description>
  <feed src='http://example.com' arch='odd-unknown'/>
  <feed src='http://bar'/>
  <implementation id='sha1=123' version='1.0' arch='odd-strange'/>
  <implementation id='sha1=124' version='1.0' arch='odd-weird'/>
</interface>""" % foo_iface_uri)
		policy = autopolicy.AutoPolicy(foo_iface_uri,
						download_only = False)
		policy.network_use = model.network_full
		policy.freshness = 0
		impls = policy.get_ranked_implementations(
				policy.get_interface(policy.root))
		assert len(impls) == 4

		logger.setLevel(logging.ERROR)
		policy.network_use = model.network_offline # Changes sort order tests
		policy.recalculate()			   # Triggers feed-for warning
		logger.setLevel(logging.WARN)

	def testNoLocal(self):
		self.cache_iface(foo_iface_uri,
"""<?xml version="1.0" ?>
<interface last-modified="1110752708"
 uri="%s"
 xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Foo</name>
  <summary>Foo</summary>
  <description>Foo</description>
  <feed src='/etc/passwd'/>
</interface>""" % foo_iface_uri)
		policy = autopolicy.AutoPolicy(foo_iface_uri,
						download_only = False)
		policy.network_use = model.network_offline
		try:
			policy.get_interface(foo_iface_uri)
			assert False
		except reader.InvalidInterface, ex:
			assert 'Invalid feed URL' in str(ex)

	def testDLfeed(self):
		self.cache_iface(foo_iface_uri,
"""<?xml version="1.0" ?>
<interface last-modified="1110752708"
 uri="%s"
 xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Foo</name>
  <summary>Foo</summary>
  <description>Foo</description>
  <feed src='http://example.com'/>
</interface>""" % foo_iface_uri)
		policy = autopolicy.AutoPolicy(foo_iface_uri, dry_run = True)
		policy.network_use = model.network_full
		policy.freshness = 0

		try:
			policy.recalculate()
			assert False
		except NeedDownload, ex:
			pass

		iface = policy.get_interface(foo_iface_uri)
		iface.feeds = [model.Feed('/BadFeed', None, False)]

		logger.setLevel(logging.ERROR)
		policy.recalculate()	# Triggers warning
		logger.setLevel(logging.WARN)

	def testBestUnusable(self):
		self.cache_iface(foo_iface_uri,
"""<?xml version="1.0" ?>
<interface last-modified="1110752708"
 uri="%s"
 xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Foo</name>
  <summary>Foo</summary>
  <description>Foo</description>
  <implementation id='sha1=123' version='1.0' arch='odd-weird'/>
</interface>""" % foo_iface_uri)
		policy = autopolicy.AutoPolicy(foo_iface_uri,
						download_only = False)
		policy.network_use = model.network_offline
		policy.recalculate()
		assert not policy.ready
		try:
			policy.download_and_execute([])
			assert False
		except model.SafeException, ex:
			assert "Can't find all required implementations" in str(ex)

	def testNoArchives(self):
		self.cache_iface(foo_iface_uri,
"""<?xml version="1.0" ?>
<interface last-modified="1110752708"
 uri="%s"
 xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Foo</name>
  <summary>Foo</summary>
  <description>Foo</description>
  <implementation id='sha1=123' version='1.0'/>
</interface>""" % foo_iface_uri)
		policy = autopolicy.AutoPolicy(foo_iface_uri,
						download_only = False)
		policy.freshness = 0
		policy.recalculate()
		assert policy.ready
		try:
			policy.download_and_execute([])
			assert False
		except model.SafeException, ex:
			assert 'no download locations' in str(ex)

	def testCycle(self):
		self.cache_iface(foo_iface_uri,
"""<?xml version="1.0" ?>
<interface last-modified="1110752708"
 uri="%s"
 xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Foo</name>
  <summary>Foo</summary>
  <description>Foo</description>
  <group>
    <requires interface='%s'/>
    <implementation id='sha1=123' version='1.0'/>
  </group>
</interface>""" % (foo_iface_uri, foo_iface_uri))
		policy = autopolicy.AutoPolicy(foo_iface_uri,
						download_only = False)
		policy.recalculate()

	def testConstraints(self):
		self.cache_iface('http://bar',
"""<?xml version="1.0" ?>
<interface last-modified="1110752708"
 uri="http://bar"
 xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Bar</name>
  <summary>Bar</summary>
  <description>Bar</description>
  <implementation id='sha1=100' version='1.0'/>
  <implementation id='sha1=150' stability='developer' version='1.5'/>
  <implementation id='sha1=200' version='2.0'/>
</interface>""")
		self.cache_iface(foo_iface_uri,
"""<?xml version="1.0" ?>
<interface last-modified="1110752708"
 uri="%s"
 xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Foo</name>
  <summary>Foo</summary>
  <description>Foo</description>
  <group>
   <requires interface='http://bar'>
    <version/>
   </requires>
   <implementation id='sha1=123' version='1.0'/>
  </group>
</interface>""" % foo_iface_uri)
		policy = autopolicy.AutoPolicy(foo_iface_uri,
						download_only = False)
		policy.network_use = model.network_full
		policy.freshness = 0
		#logger.setLevel(logging.DEBUG)
		policy.recalculate()
		#logger.setLevel(logging.WARN)
		foo_iface = policy.get_interface(foo_iface_uri)
		bar_iface = policy.get_interface('http://bar')
		assert policy.implementation[bar_iface].id == 'sha1=200'

		dep = policy.implementation[foo_iface].dependencies['http://bar']
		assert len(dep.restrictions) == 1
		restriction = dep.restrictions[0]

		restriction.before = model.parse_version('2.0')
		policy.recalculate()
		assert policy.implementation[bar_iface].id == 'sha1=100'

		restriction.not_before = model.parse_version('1.5')
		policy.recalculate()
		assert policy.implementation[bar_iface].id == 'sha1=150'

suite = unittest.makeSuite(TestAutoPolicy)
if __name__ == '__main__':
	sys.argv.append('-v')
	unittest.main()
