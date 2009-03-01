#!/usr/bin/env python2.5
from basetest import BaseTest
import sys, tempfile, logging
import unittest

sys.path.insert(0, '..')

from zeroinstall.injector import model, gpg, reader
import data

foo_iface_uri = 'http://foo'
bar_iface_uri = 'http://localhost/bar'

logger = logging.getLogger()

class TestReader(BaseTest):
	def setUp(self):
		BaseTest.setUp(self)

		stream = tempfile.TemporaryFile()
		stream.write(data.thomas_key)
		stream.seek(0)
		gpg.import_key(stream)
	
	def write_with_version(self, version):
		tmp = tempfile.NamedTemporaryFile(prefix = 'test-')
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
		except reader.InvalidInterface, ex:
			assert "1000" in str(ex)
	
	def testRequiresVersion(self):
		tmp = tempfile.NamedTemporaryFile(prefix = 'test-')
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
		reader.update(iface, tmp.name)
		impl = iface.implementations['sha1=123']
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
		tmp = tempfile.NamedTemporaryFile(prefix = 'test-')
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
   </requires>
   <implementation id='sha1=123' version='1'>
     <environment name='SELF' insert='.' mode='replace'/>
   </implementation>
  </group>
</interface>""")
		tmp.flush()
		iface = model.Interface(foo_iface_uri)
		reader.update(iface, tmp.name, local = True)
		impl = iface.implementations['sha1=123']

		assert len(impl.bindings) == 1
		self.assertEquals(model.EnvironmentBinding.REPLACE, impl.bindings[0].mode)

		assert len(impl.requires) == 1
		dep = impl.requires[0]

		assert len(dep.bindings) == 4
		for b in dep.bindings:
			self.assertEquals('PATH', b.name)
			self.assertEquals('bin', b.insert)
		self.assertEquals(model.EnvironmentBinding.PREPEND, dep.bindings[0].mode)
		self.assertEquals(model.EnvironmentBinding.PREPEND, dep.bindings[1].mode)
		self.assertEquals(model.EnvironmentBinding.APPEND, dep.bindings[2].mode)
		self.assertEquals(model.EnvironmentBinding.REPLACE, dep.bindings[3].mode)

		self.assertEquals(None, dep.bindings[1].default)
		self.assertEquals('/bin', dep.bindings[2].default)

	def testVersions(self):
		tmp = tempfile.NamedTemporaryFile(prefix = 'test-')
		tmp.write(
"""<?xml version="1.0" ?>
<interface
 uri="%s"
 xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Foo</name>
  <summary>Foo</summary>
  <description>Foo</description>
  <implementation id='sha1=123' version='1.0-rc3' version-modifier='-pre'/>
</interface>""" % foo_iface_uri)
		tmp.flush()
		iface = model.Interface(foo_iface_uri)
		reader.update(iface, tmp.name)
		impl = iface.implementations['sha1=123']
		assert impl.version == [[1, 0], -1, [3], -2]
	
	def testAbsMain(self):
		tmp = tempfile.NamedTemporaryFile(prefix = 'test-')
		tmp.write(
"""<?xml version="1.0" ?>
<interface last-modified="1110752708"
 uri="%s"
 xmlns="http://zero-install.sourceforge.net/2004/injector/interface">
  <name>Foo</name>
  <summary>Foo</summary>
  <description>Foo</description>
  <group main='/bin/sh'>
   <implementation id='sha1=123' version='1'/>
  </group>
</interface>""" % foo_iface_uri)
		tmp.flush()
		iface = model.Interface(foo_iface_uri)
		try:
			reader.update(iface, tmp.name)
			assert False
		except reader.InvalidInterface, ex:
			assert 'main' in str(ex)
	
	def testAttrs(self):
		tmp = tempfile.NamedTemporaryFile(prefix = 'test-')
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
		reader.update(iface, tmp.name)

		assert len(iface.implementations) == 2

		assert iface.implementations['sha1=123'].metadata['foo'] == 'foovalue'
		assert iface.implementations['sha1=123'].metadata['main'] == 'bin/sh'
		assert iface.implementations['sha1=123'].metadata['http://bob bob'] == 'newbobvalue'

		assert iface.implementations['sha1=124'].metadata['http://bob bob'] == 'bobvalue'
		assert iface.implementations['sha1=124'].metadata['main'] == 'next'
	
	def testNative(self):
		tmp = tempfile.NamedTemporaryFile(prefix = 'test-')
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
		reader.update(iface, tmp.name, True)

		assert len(iface.implementations) == 1

		impl = iface.implementations['package:deb:python-bittorrent:3.4.2-10']
		assert impl.id == 'package:deb:python-bittorrent:3.4.2-10'
		assert impl.upstream_stability == model.packaged
		assert impl.user_stability == None
		assert impl.requires == []
		assert impl.main == '/usr/bin/pbt'
		assert impl.metadata['foo'] == 'bar'
		assert impl.feed == iface._main_feed
	
	def testLang(self):
		tmp = tempfile.NamedTemporaryFile(prefix = 'test-')
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

		iface = model.Interface(foo_iface_uri)
		reader.update(iface, tmp.name, True)

		assert len(iface.implementations) == 3
		assert len(iface.feeds) == 1, iface.feeds

		self.assertEquals('fr en_GB', iface.feeds[0].langs)

		self.assertEquals('fr', iface.implementations['sha1=124'].langs)
		self.assertEquals('fr en_GB', iface.implementations['sha1=234'].langs)
		self.assertEquals(None, iface.implementations['sha1=345'].langs)
	
suite = unittest.makeSuite(TestReader)
if __name__ == '__main__':
	sys.argv.append('-v')
	unittest.main()
