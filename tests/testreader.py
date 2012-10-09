#!/usr/bin/env python
from basetest import BaseTest
import sys, tempfile, logging
import unittest
import os

sys.path.insert(0, '..')

from zeroinstall.injector import model, gpg, reader
import data

foo_iface_uri = 'http://foo'
bar_iface_uri = 'http://localhost/bar'

logger = logging.getLogger()

class TestReader(BaseTest):
	def setUp(self):
		BaseTest.setUp(self)

		stream = tempfile.TemporaryFile(mode = 'wb')
		stream.write(data.thomas_key)
		stream.seek(0)
		gpg.import_key(stream)
		stream.close()
	
	def write_with_version(self, version):
		tmp = tempfile.NamedTemporaryFile(mode = 'wt', prefix = 'test-')
		tmp.write(
"""<?xml version="1.0" ?>
<interface last-modified="1110752708"
 uri="%s" %s
 xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Foo</name>
  <summary>Foo</summary>
  <description>Foo</description>
</interface>""" % (foo_iface_uri, version))
		tmp.flush()
		return tmp

	def write_with_bindings(self, bindings):
		tmp = tempfile.NamedTemporaryFile(mode = 'wt', prefix = 'test-')
		tmp.write(
"""<?xml version="1.0" ?>
<interface last-modified="1110752708"
 uri="%s"
 xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Foo</name>
  <summary>Foo</summary>
  <description>Foo</description>
  <group>
   <requires interface='%s2'>
     %s
   </requires>
   <implementation id='sha1=123' version='1'/>
  </group>
</interface>""" % (foo_iface_uri, foo_iface_uri, bindings))
		tmp.flush()
		return tmp
	
	def testNoVersion(self):
		tmp = self.write_with_version('')
		reader.check_readable(foo_iface_uri, tmp.name)
	
	def testNewEnough(self):
		tmp = self.write_with_version('min-injector-version="0.19"')
		reader.check_readable(foo_iface_uri, tmp.name)
	
	def testTooOld(self):
		tmp = self.write_with_version('min-injector-version="1000"')
		try:
			reader.check_readable(foo_iface_uri, tmp.name)
			self.fail()
		except reader.InvalidInterface as ex:
			assert "1000" in str(ex)
	
	def testCantUseBothInsertAndValueInEnvironmentBinding(self):
		tmp = self.write_with_bindings("""
			<environment name="DATA" value="" insert=""/>
		""")
		try:
			reader.check_readable(foo_iface_uri, tmp.name)
			self.fail()
		except reader.InvalidInterface as ex:
			assert "Binding contains both 'insert' and 'value'" in str(ex)

	def testRequiresVersion(self):
		tmp = tempfile.NamedTemporaryFile(mode = 'wt', prefix = 'test-')
		tmp.write(
"""<?xml version="1.0" ?>
<interface last-modified="1110752708"
 uri="%s"
 xmlns="http://zero-install.sourceforge.net/2004/injector/interface"
 xmlns:my='http://my/namespace'>
  <name>Foo</name>
  <summary>Foo</summary>
  <description>Foo</description>
  <group>
   <requires interface='%s' my:foo='test'>
     <version not-before='2.3.4' before='3.4.5'/>
   </requires>
   <implementation id='sha1=123' version='1'/>
   <requires interface='%s2'/>
  </group>
</interface>""" % (foo_iface_uri, bar_iface_uri, bar_iface_uri))
		tmp.flush()
		iface = model.Interface(foo_iface_uri)
		reader.update(iface, tmp.name, iface_cache = self.config.iface_cache)
		feed = self.config.iface_cache.get_feed(foo_iface_uri)

		impl = feed.implementations['sha1=123']
		assert len(impl.dependencies) == 2
		dep = impl.dependencies[bar_iface_uri]
		assert len(dep.restrictions) == 1
		res = dep.restrictions[0]
		assert res.not_before == [[2, 3, 4], 0]
		assert res.before == [[3, 4, 5], 0]
		dep2 = impl.dependencies[bar_iface_uri + '2']
		assert len(dep2.restrictions) == 0
		str(dep)
		str(dep2)

		assert dep.metadata.get('http://my/namespace foo') == 'test'
		assert dep.metadata.get('http://my/namespace food', None) == None
	
	def testBindings(self):
		tmp = tempfile.NamedTemporaryFile(mode = 'wt', prefix = 'test-')
		tmp.write(
"""<?xml version="1.0" ?>
<interface xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Foo</name>
  <summary>Foo</summary>
  <description>Foo</description>
  <group>
   <requires interface='http://example.com/foo.xml'>
     <environment name='PATH' insert='bin'/>
     <environment name='PATH' insert='bin' mode='prepend'/>
     <environment name='PATH' insert='bin' default='/bin' mode='append'/>
     <environment name='PATH' insert='bin' mode='replace'/>
     <environment name='PATH' insert='bin' separator=',' />
   </requires>
   <implementation id='sha1=123' version='1'>
     <environment name='SELF' insert='.' mode='replace'/>
   </implementation>
  </group>
</interface>""")
		tmp.flush()
		iface = model.Interface(foo_iface_uri)
		reader.update(iface, tmp.name, local = True, iface_cache = self.config.iface_cache)

		feed = self.config.iface_cache.get_feed(foo_iface_uri)

		impl = feed.implementations['sha1=123']

		assert len(impl.bindings) == 1
		self.assertEqual(model.EnvironmentBinding.REPLACE, impl.bindings[0].mode)

		assert len(impl.requires) == 1
		dep = impl.requires[0]

		assert len(dep.bindings) == 5
		for b in dep.bindings:
			self.assertEqual('PATH', b.name)
			self.assertEqual('bin', b.insert)
		self.assertEqual(model.EnvironmentBinding.PREPEND, dep.bindings[0].mode)
		self.assertEqual(model.EnvironmentBinding.PREPEND, dep.bindings[1].mode)
		self.assertEqual(model.EnvironmentBinding.APPEND, dep.bindings[2].mode)
		self.assertEqual(model.EnvironmentBinding.REPLACE, dep.bindings[3].mode)
		self.assertEqual(model.EnvironmentBinding.PREPEND, dep.bindings[4].mode)

		self.assertEqual(os.path.join('/impl', 'bin:current'), 
				dep.bindings[0].get_value('/impl', 'current'))
		self.assertEqual(os.path.join('/impl', 'bin,current'), 
			dep.bindings[4].get_value('/impl', 'current'))

		self.assertEqual(None, dep.bindings[1].default)
		self.assertEqual('/bin', dep.bindings[2].default)

	def testVersions(self):
		tmp = tempfile.NamedTemporaryFile(mode = 'wt', prefix = 'test-')
		tmp.write(
"""<?xml version="1.0" ?>
<interface
 uri="%s"
 xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Foo</name>
  <summary>Foo</summary>
  <description>Foo</description>
  <implementation id='sha1=123' version='1.0-rc3' version-modifier='-pre'/>
  <implementation id='skipped' if-0install-version='..!1 | 2'/>
  <implementation id='used' version='2' if-0install-version='1..'/>
</interface>""" % foo_iface_uri)
		tmp.flush()
		iface = model.Interface(foo_iface_uri)
		reader.update(iface, tmp.name, iface_cache = self.config.iface_cache)
		feed = self.config.iface_cache.get_feed(foo_iface_uri)
		impl = feed.implementations['sha1=123']
		assert impl.version == [[1, 0], -1, [3], -2]
		assert len(feed.implementations) == 2
		assert feed.implementations['used'].get_version() == '2'

	def testAttrs(self):
		iface_cache = self.config.iface_cache
		tmp = tempfile.NamedTemporaryFile(mode = 'wt', prefix = 'test-')
		tmp.write(
"""<?xml version="1.0" ?>
<interface last-modified="1110752708"
 uri="%s"
 xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Foo</name>
  <summary>Foo</summary>
  <description>Foo</description>
  <group main='bin/sh' foo='foovalue' xmlns:bobpre='http://bob' bobpre:bob='bobvalue'>
   <implementation id='sha1=123' version='1' bobpre:bob='newbobvalue'/>
   <implementation id='sha1=124' version='2' main='next'/>
  </group>
</interface>""" % foo_iface_uri)
		tmp.flush()
		iface = model.Interface(foo_iface_uri)
		reader.update(iface, tmp.name, iface_cache = self.config.iface_cache)

		feed = iface_cache.get_feed(foo_iface_uri)

		assert len(feed.implementations) == 2

		assert feed.implementations['sha1=123'].metadata['foo'] == 'foovalue'
		assert feed.implementations['sha1=123'].metadata['main'] == 'bin/sh'
		assert feed.implementations['sha1=123'].metadata['http://bob bob'] == 'newbobvalue'

		assert feed.implementations['sha1=124'].metadata['http://bob bob'] == 'bobvalue'
		assert feed.implementations['sha1=124'].metadata['main'] == 'next'
	
	def testNative(self):
		iface_cache = self.config.iface_cache
		tmp = tempfile.NamedTemporaryFile(mode = 'wt', prefix = 'test-')
		tmp.write(
"""<?xml version="1.0" ?>
<interface xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Foo</name>
  <summary>Foo</summary>
  <description>Foo</description>
  <package-implementation package='gimp'/>
  <package-implementation package='python-bittorrent' foo='bar' main='/usr/bin/pbt'/>
</interface>""")
		tmp.flush()

		iface = model.Interface(foo_iface_uri)
		reader.update(iface, tmp.name, True, iface_cache = self.config.iface_cache)

		master_feed = iface_cache.get_feed(foo_iface_uri)
		assert len(master_feed.implementations) == 0
		distro_feed_url = master_feed.get_distro_feed()

		feed = iface_cache.get_feed(distro_feed_url)
		assert len(feed.implementations) == 1

		impl = feed.implementations['package:deb:python-bittorrent:3.4.2-10:*']
		assert impl.id == 'package:deb:python-bittorrent:3.4.2-10:*'
		assert impl.upstream_stability == model.packaged
		assert impl.user_stability == None
		assert impl.requires == []
		assert impl.main == '/usr/bin/pbt'
		assert impl.metadata['foo'] == 'bar'
		assert impl.feed == feed
	
	def testLang(self):
		tmp = tempfile.NamedTemporaryFile(mode = 'wt', prefix = 'test-')
		tmp.write(
"""<?xml version="1.0" ?>
<interface xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Foo</name>
  <summary>Foo</summary>
  <description>Foo</description>
  <feed langs='fr en_GB' src='http://localhost/feed.xml'/>
  <group>
    <group langs='fr en_GB'>
      <implementation id='sha1=124' version='2' langs='fr'/>
      <implementation id='sha1=234' version='2'/>
    </group>
    <implementation id='sha1=345' version='2'/>
  </group>
</interface>""")
		tmp.flush()

		feed = reader.load_feed(tmp.name, local = True)

		assert len(feed.implementations) == 3
		assert len(feed.feeds) == 1, feed.feeds

		self.assertEqual('fr en-GB', feed.feeds[0].langs)

		self.assertEqual('fr', feed.implementations['sha1=124'].langs)
		self.assertEqual('fr en-GB', feed.implementations['sha1=234'].langs)
		self.assertEqual('', feed.implementations['sha1=345'].langs)
	
if __name__ == '__main__':
	unittest.main()
