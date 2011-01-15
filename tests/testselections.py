#!/usr/bin/env python
from basetest import BaseTest
from StringIO import StringIO
import sys, os
import unittest

sys.path.insert(0, '..')
from zeroinstall.injector import selections, model, policy, namespaces, qdom

mydir = os.path.dirname(os.path.abspath(__file__))

class TestSelections(BaseTest):
	def testSelections(self):
		p = policy.Policy('http://foo/Source.xml', src = True, config = self.config)
		source = self.config.iface_cache.get_interface('http://foo/Source.xml')
		compiler = self.config.iface_cache.get_interface('http://foo/Compiler.xml')
		self.import_feed(source.uri, 'Source.xml')
		self.import_feed(compiler.uri, 'Compiler.xml')

		p.freshness = 0
		p.network_use = model.network_full
		#import logging
		#logging.getLogger().setLevel(logging.DEBUG)
		assert p.need_download()

		def assertSel(s):
			self.assertEquals('http://foo/Source.xml', s.interface)
			self.assertEquals(2, len(s.selections))

			sels = [(sel.interface, sel) for sel in s.selections.values()]
			sels.sort()
			sels = [sel for uri,sel in sels]
			
			self.assertEquals('http://foo/Compiler.xml', sels[0].interface)
			self.assertEquals('http://foo/Source.xml', sels[1].interface)

			self.assertEquals("sha1=345", sels[0].id)
			self.assertEquals("1.0", sels[0].version)

			self.assertEquals('sha1=234', sels[1].id)
			self.assertEquals("1.0", sels[1].version)
			self.assertEquals("bar", sels[1].attrs['http://namespace foo'])
			self.assertEquals("1.0", sels[1].attrs['version'])
			assert 'version-modifier' not in sels[1].attrs

			self.assertEquals(0, len(sels[0].bindings))
			self.assertEquals(0, len(sels[0].dependencies))

			self.assertEquals(1, len(sels[1].bindings))
			self.assertEquals('.', sels[1].bindings[0].insert)

			self.assertEquals(1, len(sels[1].dependencies))
			dep = sels[1].dependencies[0]
			self.assertEquals('http://foo/Compiler.xml', dep.interface)
			self.assertEquals(1, len(dep.bindings))
			self.assertEquals(["sha1=345"], sels[0].digests)

		s1 = selections.Selections(p)
		s1.selections['http://foo/Source.xml'].attrs['http://namespace foo'] = 'bar'
		assertSel(s1)

		xml = s1.toDOM().toxml("utf-8")
		root = qdom.parse(StringIO(xml))
		self.assertEquals(namespaces.XMLNS_IFACE, root.uri)

		s2 = selections.Selections(root)
		assertSel(s2)
	
	def testLocalPath(self):
		# 0launch --get-selections Local.xml
		iface = os.path.join(mydir, "Local.xml")
		p = policy.Policy(iface, config = self.config)
		p.need_download()
		s1 = selections.Selections(p)
		xml = s1.toDOM().toxml("utf-8")

		# Reload selections and check they're the same
		root = qdom.parse(StringIO(xml))
		s2 = selections.Selections(root)
		local_path = s2.selections[iface].local_path
		assert os.path.isdir(local_path), local_path
		assert not s2.selections[iface].digests, s2.selections[iface].digests

		# Add a newer implementation and try again
		feed = self.config.iface_cache.get_feed(iface)
		impl = model.ZeroInstallImplementation(feed, "foo bar=123", local_path = None)
		impl.version = model.parse_version('1.0')
		impl.commands["run"] = model.Command(qdom.Element(namespaces.XMLNS_IFACE, 'command', {'path': 'dummy'}), None)
		impl.add_download_source('http://localhost/bar.tgz', 1000, None)
		feed.implementations = {impl.id: impl}
		assert p.need_download()
		assert p.ready, p.solver.get_failure_reason()
		s1 = selections.Selections(p)
		xml = s1.toDOM().toxml("utf-8")
		root = qdom.parse(StringIO(xml))
		s2 = selections.Selections(root)
		xml = s2.toDOM().toxml("utf-8")
		qdom.parse(StringIO(xml))
		assert s2.selections[iface].local_path is None
		assert not s2.selections[iface].digests, s2.selections[iface].digests
		assert s2.selections[iface].id == 'foo bar=123'

	def testCommands(self):
		iface = os.path.join(mydir, "Command.xml")
		p = policy.Policy(iface, config = self.config)
		p.need_download()
		assert p.ready

		impl = p.solver.selections[self.config.iface_cache.get_interface(iface)]
		assert impl.id == 'c'
		assert impl.main == 'runnable/missing'

		dep_impl_uri = impl.commands['run'].requires[0].interface
		dep_impl = p.solver.selections[self.config.iface_cache.get_interface(dep_impl_uri)]
		assert dep_impl.id == 'sha1=256'

		s1 = selections.Selections(p)
		assert s1.commands[0].path == 'runnable/missing'
		xml = s1.toDOM().toxml("utf-8")
		root = qdom.parse(StringIO(xml))
		s2 = selections.Selections(root)

		assert s2.commands[0].path == 'runnable/missing'
		impl = s2.selections[iface]
		assert impl.id == 'c'

		assert s2.commands[0].qdom.attrs['http://custom attr'] == 'namespaced'
		custom_element = s2.commands[0].qdom.childNodes[0]
		assert custom_element.name == 'child'

		dep_impl = s2.selections[dep_impl_uri]
		assert dep_impl.id == 'sha1=256'

if __name__ == '__main__':
	unittest.main()
