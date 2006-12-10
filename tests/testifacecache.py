#!/usr/bin/env python2.3
import sys, tempfile, os, shutil
import unittest
import data
from logging import getLogger, DEBUG, INFO
#getLogger().setLevel(DEBUG)

sys.path.insert(0, '..')
from zeroinstall.injector import basedir, download, model, gpg, trust
from zeroinstall.injector.namespaces import *
from zeroinstall.injector.iface_cache import iface_cache, PendingFeed

class TestIfaceCache(unittest.TestCase):
	def setUp(self):
		self.config_home = tempfile.mktemp()
		self.cache_home = tempfile.mktemp()
		self.gnupg_home = tempfile.mktemp()
		os.environ['XDG_CONFIG_HOME'] = self.config_home
		os.environ['XDG_CACHE_HOME'] = self.cache_home
		os.environ['XDG_CACHE_DIRS'] = ''
		os.environ['GNUPGHOME'] = self.gnupg_home
		reload(basedir)

		os.mkdir(self.config_home, 0700)
		os.mkdir(self.cache_home, 0700)
		os.mkdir(self.gnupg_home, 0700)

		iface_cache.__init__()
	
	def tearDown(self):
		shutil.rmtree(self.config_home)
		shutil.rmtree(self.cache_home)
		shutil.rmtree(self.gnupg_home)

	def testList(self):
		self.assertEquals([], iface_cache.list_all_interfaces())
		iface_dir = basedir.save_cache_path(config_site, 'interfaces')
		file(os.path.join(iface_dir, 'http%3a%2f%2ffoo'), 'w').close()
		self.assertEquals(['http://foo'],
				iface_cache.list_all_interfaces())
		# TODO: test overrides

	def testCheckSigned(self):
		trust.trust_db.trust_key(
			'92429807C9853C0744A68B9AAE07828059A53CC1')
		iface = iface_cache.get_interface('http://foo')
		src = tempfile.TemporaryFile()

		# Unsigned
		src.write("hello")
		src.flush()
		src.seek(0)
		try:
			PendingFeed(iface.uri, src)
			assert 0
		except model.SafeException:
			pass

		stream = tempfile.TemporaryFile()
		stream.write(data.thomas_key)
		stream.seek(0)

		gpg.import_key(stream)

		# Signed
		src.seek(0)
		src.write(data.foo_signed)
		src.flush()
		src.seek(0)

		pending = PendingFeed(iface.uri, src)
		iface_cache.add_pending(pending)
		assert iface_cache.update_interface_if_trusted(iface, pending.sigs, pending.new_xml)

		self.assertEquals(['http://foo'],
				iface_cache.list_all_interfaces())

		self.assertEquals(1116788178,  iface.last_modified)

		# mtimes are unreliable because copying often changes them -
		# check that we stored the mtime in an attribute
		upstream_dir = basedir.save_cache_path(config_site, 'interfaces')
		cached = os.path.join(upstream_dir, model.escape(iface.uri))
		os.utime(cached, None)

		iface_cache.__init__()
		iface = iface_cache.get_interface('http://foo')
		self.assertEquals(1116788178,  iface.last_modified)

	def testXMLupdate(self):
		trust.trust_db.trust_key(
			'92429807C9853C0744A68B9AAE07828059A53CC1')
		stream = tempfile.TemporaryFile()
		stream.write(data.thomas_key)
		stream.seek(0)
		gpg.import_key(stream)

		iface = iface_cache.get_interface('http://foo')
		src = tempfile.TemporaryFile()
		src.write(data.foo_signed_xml)
		src.seek(0)
		pending = PendingFeed(iface.uri, src)
		iface_cache.add_pending(pending)
		assert iface_cache.update_interface_if_trusted(iface, pending.sigs, pending.new_xml)

		iface_cache.__init__()
		iface = iface_cache.get_interface('http://foo')
		assert iface.last_modified == 1154850229

		# mtimes are unreliable because copying often changes them -
		# check that we extract the time from the signature when upgrading
		upstream_dir = basedir.save_cache_path(config_site, 'interfaces')
		cached = os.path.join(upstream_dir, model.escape(iface.uri))
		os.utime(cached, None)

		iface_cache.__init__()
		iface = iface_cache.get_interface('http://foo')
		assert iface.last_modified > 1154850229

		src = tempfile.TemporaryFile()
		src.write(data.new_foo_signed_xml)
		src.seek(0)

		pending = PendingFeed(iface.uri, src)
		iface_cache.add_pending(pending)
		assert iface_cache.update_interface_if_trusted(iface, pending.sigs, pending.new_xml)

		# Can't 'update' to an older copy
		src = tempfile.TemporaryFile()
		src.write(data.foo_signed_xml)
		src.seek(0)
		try:
			pending = PendingFeed(iface.uri, src)
			iface_cache.add_pending(pending)
			assert iface_cache.update_interface_if_trusted(iface, pending.sigs, pending.new_xml)

			assert 0
		except model.SafeException:
			pass

	def testTimes(self):
		stream = tempfile.TemporaryFile()
		stream.write(data.thomas_key)
		stream.seek(0)
		gpg.import_key(stream)

		upstream_dir = basedir.save_cache_path(config_site, 'interfaces')
		cached = os.path.join(upstream_dir, model.escape('http://foo'))

		stream = file(cached, 'w')
		stream.write(data.foo_signed_xml)
		stream.close()

		signed = iface_cache._get_signature_date('http://foo')
		assert signed == None

		trust.trust_db.trust_key(
			'92429807C9853C0744A68B9AAE07828059A53CC1')

		signed = iface_cache._get_signature_date('http://foo')
		assert signed == 1154850229

		stream = file(cached, 'w+')
		stream.seek(0)
		stream.write('Hello')
		stream.close()

		# When the signature is invalid, we just return None.
		# This is because versions < 0.22 used to corrupt the signatue
		# by adding an attribute to the XML
		signed = iface_cache._get_signature_date('http://foo')
		assert signed == None

suite = unittest.makeSuite(TestIfaceCache)
if __name__ == '__main__':
	sys.argv.append('-v')
	unittest.main()
