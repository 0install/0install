#!/usr/bin/env python2.3
from basetest import BaseTest
import sys, tempfile, os, shutil
from StringIO import StringIO
import unittest, signal
from logging import getLogger, DEBUG, INFO, WARN
#getLogger().setLevel(DEBUG)

sys.path.insert(0, '..')

from zeroinstall.injector import model, basedir, autopolicy, gpg, iface_cache, download, reader, trust
from zeroinstall.zerostore import Store; Store._add_with_helper = lambda *unused: False
import data

import server

class Reply:
	def __init__(self, reply):
		self.reply = reply

	def readline(self):
		return self.reply

class TestDownload(BaseTest):
	def setUp(self):
		BaseTest.setUp(self)

		stream = tempfile.TemporaryFile()
		stream.write(data.thomas_key)
		stream.seek(0)
		gpg.import_key(stream)
		self.child = None

		trust.trust_db.watchers = []
	
	def tearDown(self):
		BaseTest.tearDown(self)
		if self.child is not None:
			os.kill(self.child, signal.SIGTERM)
			os.waitpid(self.child, 0)
			self.child = None
	
	def testRejectKey(self):
		old_out = sys.stdout
		try:
			sys.stdout = StringIO()
			self.child = server.handle_requests('Hello', '6FCF121BE2390E0B.gpg')
			policy = autopolicy.AutoPolicy('http://localhost:8000/Hello', download_only = False)
			assert policy.need_download()
			sys.stdin = Reply("N\n")
			try:
				policy.download_and_execute(['Hello'])
				assert 0
			except model.SafeException, ex:
				if "Not signed with a trusted key" not in str(ex):
					raise ex
		finally:
			sys.stdout = old_out
	
	def testRejectKeyXML(self):
		old_out = sys.stdout
		try:
			sys.stdout = StringIO()
			self.child = server.handle_requests('Hello.xml', '6FCF121BE2390E0B.gpg')
			policy = autopolicy.AutoPolicy('http://localhost:8000/Hello.xml', download_only = False)
			assert policy.need_download()
			sys.stdin = Reply("N\n")
			try:
				policy.download_and_execute(['Hello'])
				assert 0
			except model.SafeException, ex:
				if "Not signed with a trusted key" not in str(ex):
					raise
		finally:
			sys.stdout = old_out
	
	def testImport(self):
		old_out = sys.stdout
		try:
			from zeroinstall.injector import cli
			import logging

			rootLogger = getLogger()
			rootLogger.disabled = True
			try:
				try:
					cli.main(['--import', '-v', 'NO-SUCH-FILE'])
					assert 0
				except model.SafeException, ex:
					assert 'NO-SUCH-FILE' in str(ex)
			finally:
				rootLogger.disabled = False
				rootLogger.setLevel(WARN)

			hello = iface_cache.iface_cache.get_interface('http://localhost:8000/Hello')
			self.assertEquals(0, len(hello.implementations))

			sys.stdout = StringIO()
			self.child = server.handle_requests('6FCF121BE2390E0B.gpg', 'HelloWorld.tgz')
			sys.stdin = Reply("Y\n")

			assert not trust.trust_db.is_trusted('DE937DD411906ACF7C263B396FCF121BE2390E0B')
			try:
				cli.main(['--import', 'Hello'])
				assert 0
			except SystemExit, ex:
				assert ex.code == 0
			assert trust.trust_db.is_trusted('DE937DD411906ACF7C263B396FCF121BE2390E0B')

			# Check we imported the interface after trusting the key
			reader.update_from_cache(hello)
			self.assertEquals(1, len(hello.implementations))

			# Shouldn't need to prompt the second time
			sys.stdin = None
			try:
				cli.main(['--import', 'Hello'])
				assert 0
			except SystemExit, ex:
				assert ex.code == 0
		finally:
			sys.stdout = old_out
	
	def testAcceptKey(self):
		old_out = sys.stdout
		try:
			sys.stdout = StringIO()
			self.child = server.handle_requests('Hello', '6FCF121BE2390E0B.gpg', 'HelloWorld.tgz')
			policy = autopolicy.AutoPolicy('http://localhost:8000/Hello', download_only = False)
			assert policy.need_download()
			sys.stdin = Reply("Y\n")
			try:
				policy.download_and_execute(['Hello'], main = 'Missing')
				assert 0
			except model.SafeException, ex:
				if "HelloWorld/Missing" not in str(ex):
					raise ex
		finally:
			sys.stdout = old_out
	
	def testRecipe(self):
		old_out = sys.stdout
		try:
			sys.stdout = StringIO()
			self.child = server.handle_requests(('HelloWorld.tar.bz2', 'dummy_1-1_all.deb'))
			policy = autopolicy.AutoPolicy(os.path.abspath('Recipe.xml'), download_only = False)
			try:
				policy.download_and_execute([])
				assert False
			except model.SafeException, ex:
				if "HelloWorld/Missing" not in str(ex):
					raise ex
		finally:
			sys.stdout = old_out

	def testAutopackage(self):
		old_out = sys.stdout
		try:
			sys.stdout = StringIO()
			self.child = server.handle_requests('HelloWorld.autopackage')
			policy = autopolicy.AutoPolicy(os.path.abspath('Autopackage.xml'), download_only = False)
			try:
				policy.download_and_execute([])
				assert False
			except model.SafeException, ex:
				if "HelloWorld/Missing" not in str(ex):
					raise ex
		finally:
			sys.stdout = old_out

	def testRecipeFailure(self):
		old_out = sys.stdout
		try:
			sys.stdout = StringIO()
			self.child = server.handle_requests('*')
			policy = autopolicy.AutoPolicy(os.path.abspath('Recipe.xml'), download_only = False)
			try:
				policy.download_and_execute([])
				assert False
			except download.DownloadError, ex:
				if "Connection" not in str(ex):
					raise ex
		finally:
			sys.stdout = old_out

suite = unittest.makeSuite(TestDownload)
if __name__ == '__main__':
	sys.argv.append('-v')
	unittest.main()
