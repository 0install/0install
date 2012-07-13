#!/usr/bin/env python
from basetest import BaseTest
from io import BytesIO
import sys, os
import unittest

sys.path.insert(0, '..')
from zeroinstall.injector import selections, model, namespaces, qdom, requirements
from zeroinstall.injector.requirements import Requirements
from zeroinstall.injector.driver import Driver

mydir = os.path.dirname(os.path.abspath(__file__))
runexec = os.path.join(mydir, 'runnable', 'RunExec.xml')
runnable = os.path.join(mydir, 'runnable', 'Runnable.xml')

class TestSelections(BaseTest):
	def testSelections(self):
		requirements = Requirements('http://foo/Source.xml')
		requirements.source = True
		requirements.command = 'compile'
		driver = Driver(requirements = requirements, config = self.config)
		source = self.config.iface_cache.get_interface('http://foo/Source.xml')
		compiler = self.config.iface_cache.get_interface('http://foo/Compiler.xml')
		self.import_feed(source.uri, 'Source.xml')
		self.import_feed(compiler.uri, 'Compiler.xml')

		self.config.network_use = model.network_full
		#import logging
		#logging.getLogger().setLevel(logging.DEBUG)
		assert driver.need_download()

		def assertSel(s):
			self.assertEqual('http://foo/Source.xml', s.interface)
			self.assertEqual(2, len(s.selections))

			sels = [(sel.interface, sel) for sel in s.selections.values()]
			sels.sort()
			sels = [sel for uri,sel in sels]
			
			self.assertEqual('http://foo/Compiler.xml', sels[0].interface)
			self.assertEqual('http://foo/Source.xml', sels[1].interface)

			self.assertEqual("sha1=345", sels[0].id)
			self.assertEqual("1.0", sels[0].version)

			self.assertEqual('sha1=234', sels[1].id)
			self.assertEqual("1.0", sels[1].version)
			self.assertEqual("bar", sels[1].attrs['http://namespace foo'])
			self.assertEqual("1.0", sels[1].attrs['version'])
			assert 'version-modifier' not in sels[1].attrs

			self.assertEqual(0, len(sels[0].bindings))
			self.assertEqual(0, len(sels[0].dependencies))

			self.assertEqual(2, len(sels[1].bindings))
			self.assertEqual('.', sels[1].bindings[0].insert)
			self.assertEqual('/', sels[1].bindings[1].mount_point)

			self.assertEqual(1, len(sels[1].dependencies))
			dep = sels[1].dependencies[0]
			self.assertEqual('http://foo/Compiler.xml', dep.interface)
			self.assertEqual(3, len(dep.bindings))
			self.assertEqual('bin', dep.bindings[0].insert)
			self.assertEqual('PATH', dep.bindings[0].name)
			self.assertEqual('prepend', dep.bindings[0].mode)
			assert dep.bindings[0].separator in ';:'

			self.assertEqual('bin', dep.bindings[1].value)
			self.assertEqual('NO_PATH', dep.bindings[1].name)
			self.assertEqual(',', dep.bindings[1].separator)

			self.assertEqual('bin', dep.bindings[2].insert)
			self.assertEqual('BINDIR', dep.bindings[2].name)
			self.assertEqual('replace', dep.bindings[2].mode)

			self.assertEqual(["sha1=345", 'sha256new_345'], sels[0].digests)

		assert driver.solver.ready, driver.solver.get_failure_reason()
		s1 = driver.solver.selections
		s1.selections['http://foo/Source.xml'].attrs['http://namespace foo'] = 'bar'
		assertSel(s1)

		xml = s1.toDOM().toxml("utf-8")
		root = qdom.parse(BytesIO(xml))
		self.assertEqual(namespaces.XMLNS_IFACE, root.uri)

		s2 = selections.Selections(root)
		assertSel(s2)
	
	def testLocalPath(self):
		# 0launch --get-selections Local.xml
		iface = os.path.join(mydir, "Local.xml")
		driver = Driver(requirements = Requirements(iface), config = self.config)
		driver.need_download()
		assert driver.solver.ready
		s1 = driver.solver.selections
		xml = s1.toDOM().toxml("utf-8")

		# Reload selections and check they're the same
		root = qdom.parse(BytesIO(xml))
		s2 = selections.Selections(root)
		local_path = s2.selections[iface].local_path
		assert os.path.isdir(local_path), local_path
		assert not s2.selections[iface].digests, s2.selections[iface].digests

		# Add a newer implementation and try again
		feed = self.config.iface_cache.get_feed(iface)
		impl = model.ZeroInstallImplementation(feed, "foo bar=123", local_path = None)
		impl.version = model.parse_version('1.0')
		impl.commands["run"] = model.Command(qdom.Element(namespaces.XMLNS_IFACE, 'command', {'path': 'dummy', 'name': 'run'}), None)
		impl.add_download_source('http://localhost/bar.tgz', 1000, None)
		feed.implementations = {impl.id: impl}
		assert driver.need_download()
		assert driver.solver.ready, driver.solver.get_failure_reason()
		s1 = driver.solver.selections
		xml = s1.toDOM().toxml("utf-8")
		root = qdom.parse(BytesIO(xml))
		s2 = selections.Selections(root)
		xml = s2.toDOM().toxml("utf-8")
		qdom.parse(BytesIO(xml))
		assert s2.selections[iface].local_path is None
		assert not s2.selections[iface].digests, s2.selections[iface].digests
		assert s2.selections[iface].id == 'foo bar=123'

	def testCommands(self):
		iface = os.path.join(mydir, "Command.xml")
		driver = Driver(requirements = Requirements(iface), config = self.config)
		driver.need_download()
		assert driver.solver.ready

		impl = driver.solver.selections[self.config.iface_cache.get_interface(iface)]
		assert impl.id == 'c'
		assert impl.main == 'test-gui'

		dep_impl_uri = impl.commands['run'].requires[0].interface
		dep_impl = driver.solver.selections[self.config.iface_cache.get_interface(dep_impl_uri)]
		assert dep_impl.id == 'sha1=256'

		s1 = driver.solver.selections
		assert s1.commands[0].path == 'test-gui'
		xml = s1.toDOM().toxml("utf-8")
		root = qdom.parse(BytesIO(xml))
		s2 = selections.Selections(root)

		assert s2.commands[0].path == 'test-gui'
		impl = s2.selections[iface]
		assert impl.id == 'c'

		assert s2.commands[0].qdom.attrs['http://custom attr'] == 'namespaced'
		custom_element = s2.commands[0].qdom.childNodes[0]
		assert custom_element.name == 'child'

		dep_impl = s2.selections[dep_impl_uri]
		assert dep_impl.id == 'sha1=256'

		d = Driver(self.config, requirements.Requirements(runexec))
		need_download = d.need_download()
		assert need_download == False

		xml = d.solver.selections.toDOM().toxml("utf-8")
		root = qdom.parse(BytesIO(xml))
		s3 = selections.Selections(root)
		runnable_impl = s3.selections[runnable]
		assert 'foo' in runnable_impl.commands
		assert 'run' in runnable_impl.commands

	def testOldCommands(self):
		command_feed = os.path.join(mydir, 'old-selections.xml')
		with open(command_feed, 'rb') as stream:
			s1 = selections.Selections(qdom.parse(stream))
		self.assertEqual("run", s1.command)
		self.assertEqual(2, len(s1.commands))
		self.assertEqual("bin/java", s1.commands[1].path)

		xml = s1.toDOM().toxml("utf-8")
		root = qdom.parse(BytesIO(xml))
		s2 = selections.Selections(root)

		self.assertEqual("run", s2.command)
		self.assertEqual(2, len(s2.commands))
		self.assertEqual("bin/java", s2.commands[1].path)


if __name__ == '__main__':
	unittest.main()
