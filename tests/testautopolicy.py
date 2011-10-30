#!/usr/bin/env python
from basetest import BaseTest
import sys, tempfile, os, logging
from StringIO import StringIO
import unittest

sys.path.insert(0, '..')

from zeroinstall.injector import model, gpg, namespaces, reader, run, fetch
from zeroinstall.injector.policy import Policy
from zeroinstall.support import basedir
import data

foo_iface_uri = 'http://foo'

logger = logging.getLogger()

def recalculate(policy):
	policy.need_download()

def download_and_execute(policy, prog_args, main = None, dry_run = True):
	downloaded = policy.solve_and_download_impls()
	if downloaded:
		policy.config.handler.wait_for_blocker(downloaded)
	run.execute_selections(policy.solver.selections, prog_args, stores = policy.config.stores, main = main, dry_run = dry_run)

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

		f = open(os.path.join(cached_ifaces, model.escape(name)), 'w')
		f.write(data)
		f.close()

	def testNoNeedDl(self):
		policy = Policy(foo_iface_uri, config = self.config)
		policy.freshness = 0
		assert policy.need_download()

		policy = Policy(os.path.abspath('Foo.xml'), config = self.config)
		assert not policy.need_download()
		assert policy.ready
	
	def testUnknownAlg(self):
		self.cache_iface(foo_iface_uri,
"""<?xml version="1.0" ?>
<interface
 uri="%s"
 xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Foo</name>
  <summary>Foo</summary>
  <description>Foo</description>
  <implementation main='.' id='unknown=123' version='1.0'>
    <archive href='http://foo/foo.tgz' size='100'/>
  </implementation>
</interface>""" % foo_iface_uri)
		self.config.fetcher = fetch.Fetcher(self.config)
		policy = Policy(foo_iface_uri, config = self.config)
		policy.freshness = 0
		try:
			assert policy.need_download()
			download_and_execute(policy, [])
		except model.SafeException as ex:
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
		policy = Policy(tmp.name, config = self.config)
		try:
			download_and_execute(policy, ['Hello'])
			assert 0
		except model.SafeException as ex:
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
		policy = Policy(tmp.name, config = self.config)
		try:
			download_and_execute(policy, ['Hello'])
			assert 0
		except model.SafeException as ex:
			assert "library" in str(ex), ex
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
		policy = Policy(foo_iface_uri, config = self.config)
		policy.freshness = 0
		policy.network_use = model.network_full
		recalculate(policy)
		assert policy.need_download()
		assert policy.ready

	def testBinding(self):
		local_impl = os.path.dirname(os.path.abspath(__file__))
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
      <environment name='NO_PATH' value='val'/>
      <environment name='XDG_DATA_DIRS' insert='.'/>
    </requires>
    <environment name='SELF_GROUP' insert='group' mode='replace'/>
    <implementation version='1.0' id='%s'>
      <environment name='SELF_IMPL' insert='impl' mode='replace'/>
    </implementation>
  </group>
</interface>""" % (foo_iface_uri, local_impl))
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
		policy = Policy(tmp.name, config = self.config)
		policy.network_use = model.network_offline
		os.environ['FOO_PATH'] = "old"
		old, sys.stdout = sys.stdout, StringIO()
		try:
			download_and_execute(policy, ['Hello'])
		finally:
			sys.stdout = old
		self.assertEquals(cached_impl + '/.:old',
				os.environ['FOO_PATH'])
		self.assertEquals(cached_impl + '/.:/a:/b',
				os.environ['BAR_PATH'])
		self.assertEquals('val', os.environ['NO_PATH'])
		
		self.assertEquals(os.path.join(local_impl, 'group'), os.environ['SELF_GROUP'])
		self.assertEquals(os.path.join(local_impl, 'impl'), os.environ['SELF_IMPL'])

		del os.environ['FOO_PATH']
		if 'XDG_DATA_DIRS' in os.environ:
			del os.environ['XDG_DATA_DIRS']
		os.environ['BAR_PATH'] = '/old'
		old, sys.stdout = sys.stdout, StringIO()
		try:
			download_and_execute(policy, ['Hello'])
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
  <implementation version='1.0' id='sha1=123' main='dummy'>
    <archive href='foo' size='10'/>
  </implementation>
</interface>""" % foo_iface_uri)
		policy = Policy(foo_iface_uri, config = self.config)
		policy.freshness = 0
		policy.network_use = model.network_full
		recalculate(policy)
		assert policy.ready
		foo_iface = self.config.iface_cache.get_interface(foo_iface_uri)
		self.assertEquals('sha1=123', policy.implementation[foo_iface].id)

	def testBadConfig(self):
		path = basedir.save_config_path(namespaces.config_site,
						namespaces.config_prog)
		glob = os.path.join(path, 'global')
		assert not os.path.exists(glob)
		stream = open(glob, 'w')
		stream.write('hello!')
		stream.close()

		logger.setLevel(logging.ERROR)
		Policy(foo_iface_uri, config = self.config)
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
		self.config.network_use = model.network_offline
		try:
			self.config.iface_cache.get_interface(foo_iface_uri)
			assert False
		except reader.InvalidInterface as ex:
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
		policy = Policy(foo_iface_uri, config = self.config)
		policy.network_use = model.network_full
		policy.freshness = 0

		assert policy.need_download()

		feed = self.config.iface_cache.get_feed(foo_iface_uri)
		feed.feeds = [model.Feed('/BadFeed', None, False)]

		logger.setLevel(logging.ERROR)
		assert policy.need_download()	# Triggers warning
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
  <implementation id='sha1=123' version='1.0' arch='odd-weird' main='dummy'/>
</interface>""" % foo_iface_uri)
		policy = Policy(foo_iface_uri, config = self.config)
		policy.network_use = model.network_offline
		recalculate(policy)
		assert not policy.ready, policy.implementation
		try:
			download_and_execute(policy, [])
			assert False
		except model.SafeException as ex:
			assert "has no usable implementations" in str(ex), ex

	def testNoArchives(self):
		self.cache_iface(foo_iface_uri,
"""<?xml version="1.0" ?>
<interface last-modified="1110752708"
 uri="%s"
 xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Foo</name>
  <summary>Foo</summary>
  <description>Foo</description>
  <implementation id='sha1=123' version='1.0' main='dummy'/>
</interface>""" % foo_iface_uri)
		policy = Policy(foo_iface_uri, config = self.config)
		policy.freshness = 0
		recalculate(policy)
		assert not policy.ready

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
    <implementation id='sha1=123' version='1.0'>
      <archive href='foo' size='10'/>
    </implementation>
  </group>
</interface>""" % (foo_iface_uri, foo_iface_uri))
		policy = Policy(foo_iface_uri, config = self.config)
		policy.freshness = 0
		recalculate(policy)

	def testConstraints(self):
		self.cache_iface('http://bar',
"""<?xml version="1.0" ?>
<interface last-modified="1110752708"
 uri="http://bar"
 xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Bar</name>
  <summary>Bar</summary>
  <description>Bar</description>
  <implementation id='sha1=100' version='1.0'>
    <archive href='foo' size='10'/>
  </implementation>
  <implementation id='sha1=150' stability='developer' version='1.5'>
    <archive href='foo' size='10'/>
  </implementation>
  <implementation id='sha1=200' version='2.0'>
    <archive href='foo' size='10'/>
  </implementation>
</interface>""")
		self.cache_iface(foo_iface_uri,
"""<?xml version="1.0" ?>
<interface last-modified="1110752708"
 uri="%s"
 xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Foo</name>
  <summary>Foo</summary>
  <description>Foo</description>
  <group main='dummy'>
   <requires interface='http://bar'>
    <version/>
   </requires>
   <implementation id='sha1=123' version='1.0'>
    <archive href='foo' size='10'/>
   </implementation>
  </group>
</interface>""" % foo_iface_uri)
		policy = Policy(foo_iface_uri, config = self.config)
		policy.network_use = model.network_full
		policy.freshness = 0
		#logger.setLevel(logging.DEBUG)
		recalculate(policy)
		#logger.setLevel(logging.WARN)
		foo_iface = self.config.iface_cache.get_interface(foo_iface_uri)
		bar_iface = self.config.iface_cache.get_interface('http://bar')
		assert policy.implementation[bar_iface].id == 'sha1=200'

		dep = policy.implementation[foo_iface].dependencies['http://bar']
		assert len(dep.restrictions) == 1
		restriction = dep.restrictions[0]

		restriction.before = model.parse_version('2.0')
		recalculate(policy)
		assert policy.implementation[bar_iface].id == 'sha1=100'

		restriction.not_before = model.parse_version('1.5')
		recalculate(policy)
		assert policy.implementation[bar_iface].id == 'sha1=150'

if __name__ == '__main__':
	unittest.main()
