#!/usr/bin/env python
from basetest import BaseTest
import sys, tempfile, os, logging
from io import StringIO
import unittest

sys.path.insert(0, '..')

from zeroinstall.injector import model, gpg, namespaces, reader, run, fetch
from zeroinstall.injector.requirements import Requirements
from zeroinstall.injector.driver import Driver
from zeroinstall.support import basedir, tasks
import data

foo_iface_uri = 'http://foo'

logger = logging.getLogger()

def recalculate(driver):
	driver.need_download()

def download_and_execute(driver, prog_args, main = None, dry_run = True):
	downloaded = driver.solve_and_download_impls()
	if downloaded:
		tasks.wait_for_blocker(downloaded)
	run.execute_selections(driver.solver.selections, prog_args, stores = driver.config.stores, main = main, dry_run = dry_run)

class TestDriver(BaseTest):
	def setUp(self):
		BaseTest.setUp(self)
		stream = tempfile.TemporaryFile(mode = 'w+t')
		stream.write(data.thomas_key)
		stream.seek(0)
		gpg.import_key(stream)
		stream.close()
	
	def cache_iface(self, name, data):
		cached_ifaces = basedir.save_cache_path('0install.net',
							'interfaces')

		f = open(os.path.join(cached_ifaces, model.escape(name)), 'w')
		f.write(data)
		f.close()

	def testNoNeedDl(self):
		driver = Driver(requirements = Requirements(foo_iface_uri), config = self.config)
		assert driver.need_download()

		driver = Driver(requirements = Requirements(os.path.abspath('Foo.xml')), config = self.config)
		assert not driver.need_download()
		assert driver.solver.ready
	
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
		driver = Driver(requirements = Requirements(foo_iface_uri), config = self.config)
		try:
			assert driver.need_download()
			download_and_execute(driver, [])
		except model.SafeException as ex:
			assert 'Unknown digest algorithm' in str(ex)
	
	def testDownload(self):
		tmp = tempfile.NamedTemporaryFile(mode = 'wt')
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
		driver = Driver(requirements = Requirements(tmp.name), config = self.config)
		try:
			download_and_execute(driver, ['Hello'])
			assert 0
		except model.SafeException as ex:
			assert "ThisBetterNotExist" in str(ex)
		tmp.close()

	def testNoMain(self):
		tmp = tempfile.NamedTemporaryFile(mode = 'wt')
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
		driver = Driver(requirements = Requirements(tmp.name), config = self.config)
		try:
			download_and_execute(driver, ['Hello'])
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
		driver = Driver(requirements = Requirements(foo_iface_uri), config = self.config)
		self.config.network_use = model.network_full
		recalculate(driver)
		assert driver.need_download()
		assert driver.solver.ready

	def testBinding(self):
		local_impl = os.path.dirname(os.path.abspath(__file__))
		tmp = tempfile.NamedTemporaryFile(mode = 'wt')
		tmp.write(
"""<?xml version="1.0" ?>
<interface
 main='testdriver.py'
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
		driver = Driver(requirements = Requirements(tmp.name), config = self.config)
		self.config.network_use = model.network_offline
		os.environ['FOO_PATH'] = "old"
		old, sys.stdout = sys.stdout, StringIO()
		try:
			download_and_execute(driver, ['Hello'])
		finally:
			sys.stdout = old
		self.assertEqual(cached_impl + '/.:old',
				os.environ['FOO_PATH'])
		self.assertEqual(cached_impl + '/.:/a:/b',
				os.environ['BAR_PATH'])
		self.assertEqual('val', os.environ['NO_PATH'])
		
		self.assertEqual(os.path.join(local_impl, 'group'), os.environ['SELF_GROUP'])
		self.assertEqual(os.path.join(local_impl, 'impl'), os.environ['SELF_IMPL'])

		del os.environ['FOO_PATH']
		if 'XDG_DATA_DIRS' in os.environ:
			del os.environ['XDG_DATA_DIRS']
		os.environ['BAR_PATH'] = '/old'
		old, sys.stdout = sys.stdout, StringIO()
		try:
			download_and_execute(driver, ['Hello'])
		finally:
			sys.stdout = old
		self.assertEqual(cached_impl + '/.',
				os.environ['FOO_PATH'])
		self.assertEqual(cached_impl + '/.:/old',
				os.environ['BAR_PATH'])
		self.assertEqual(cached_impl + '/.:/usr/local/share:/usr/share',
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
		driver = Driver(requirements = Requirements(foo_iface_uri), config = self.config)
		self.config.network_use = model.network_full
		recalculate(driver)
		assert driver.solver.ready
		foo_iface = self.config.iface_cache.get_interface(foo_iface_uri)
		self.assertEqual('sha1=123', driver.solver.selections[foo_iface].id)

	def testBadConfig(self):
		path = basedir.save_config_path(namespaces.config_site,
						namespaces.config_prog)
		glob = os.path.join(path, 'global')
		assert not os.path.exists(glob)
		stream = open(glob, 'w')
		stream.write('hello!')
		stream.close()

		logger.setLevel(logging.ERROR)
		Driver(requirements = Requirements(foo_iface_uri), config = self.config)
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
		driver = Driver(requirements = Requirements(foo_iface_uri), config = self.config)
		self.config.network_use = model.network_full

		assert driver.need_download()

		feed = self.config.iface_cache.get_feed(foo_iface_uri)
		feed.feeds = [model.Feed('/BadFeed', None, False)]

		logger.setLevel(logging.ERROR)
		assert driver.need_download()	# Triggers warning
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
		driver = Driver(requirements = Requirements(foo_iface_uri), config = self.config)
		self.config.network_use = model.network_offline
		recalculate(driver)
		assert not driver.solver.ready, driver.implementation
		try:
			download_and_execute(driver, [])
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
		driver = Driver(requirements = Requirements(foo_iface_uri), config = self.config)
		recalculate(driver)
		assert not driver.solver.ready

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
		driver = Driver(requirements = Requirements(foo_iface_uri), config = self.config)
		recalculate(driver)

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
		driver = Driver(requirements = Requirements(foo_iface_uri), config = self.config)
		self.config.network_use = model.network_full
		#logger.setLevel(logging.DEBUG)
		recalculate(driver)
		#logger.setLevel(logging.WARN)
		foo_iface = self.config.iface_cache.get_interface(foo_iface_uri)
		bar_iface = self.config.iface_cache.get_interface('http://bar')
		assert driver.solver.selections[bar_iface].id == 'sha1=200'

		dep = driver.solver.selections[foo_iface].dependencies['http://bar']
		assert len(dep.restrictions) == 1
		restriction = dep.restrictions[0]

		restriction.before = model.parse_version('2.0')
		recalculate(driver)
		assert driver.solver.selections[bar_iface].id == 'sha1=100'

		restriction.not_before = model.parse_version('1.5')
		recalculate(driver)
		assert driver.solver.selections[bar_iface].id == 'sha1=150'

	def testSource(self):
		iface_cache = self.config.iface_cache

		foo = iface_cache.get_interface('http://foo/Binary.xml')
		self.import_feed(foo.uri, 'Binary.xml')
		foo_src = iface_cache.get_interface('http://foo/Source.xml')
		self.import_feed(foo_src.uri, 'Source.xml')
		compiler = iface_cache.get_interface('http://foo/Compiler.xml')
		self.import_feed(compiler.uri, 'Compiler.xml')

		self.config.freshness = 0
		self.config.network_use = model.network_full
		driver = Driver(requirements = Requirements('http://foo/Binary.xml'), config = self.config)
		tasks.wait_for_blocker(driver.solve_with_downloads())
		assert driver.solver.selections[foo].id == 'sha1=123'

		# Now ask for source instead
		driver.requirements.source = True
		driver.requirements.command = 'compile'
		tasks.wait_for_blocker(driver.solve_with_downloads())
		assert driver.solver.ready, driver.solver.get_failure_reason()
		assert driver.solver.selections[foo].id == 'sha1=234'		# The source
		assert driver.solver.selections[compiler].id == 'sha1=345'	# A binary needed to compile it

if __name__ == '__main__':
	unittest.main()
