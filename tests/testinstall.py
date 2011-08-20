#!/usr/bin/env python
from basetest import BaseTest, TestStores
import sys, os, tempfile
from StringIO import StringIO
import unittest

sys.path.insert(0, '..')
from zeroinstall import cmd
from zeroinstall.injector import model, selections, qdom, reader, policy, handler, gpg

mydir = os.path.dirname(__file__)

class Reply:
	def __init__(self, reply):
		self.reply = reply

	def readline(self):
		return self.reply

class TestInstall(BaseTest):
	def run_0install(self, args):
		old_stdout = sys.stdout
		old_stderr = sys.stderr
		try:
			sys.stdout = StringIO()
			sys.stderr = StringIO()
			ex = None
			try:
				cmd.main(args, config = self.config)
			except NameError:
				raise
			except SystemExit:
				pass
			except TypeError:
				raise
			except AttributeError:
				raise
			except AssertionError:
				raise
			except Exception as ex:
				pass
			out = sys.stdout.getvalue()
			err = sys.stderr.getvalue()
			if ex is not None:
				err += str(ex.__class__)
		finally:
			sys.stdout = old_stdout
			sys.stderr = old_stderr
		return (out, err)

	def testHelp(self):
		out, err = self.run_0install([])
		assert out.lower().startswith("usage:")
		assert 'add-feed' in out
		assert '--version' in out
		assert not err, err

		out2, err = self.run_0install(['--help'])
		assert not err, err
		assert out2 == out

		out, err = self.run_0install(['--version'])
		assert 'Thomas Leonard' in out
		assert not err, err

		out, err = self.run_0install(['foobar'])
		assert 'Unknown sub-command' in err, err

	def testSelect(self):
		out, err = self.run_0install(['select'])
		assert out.lower().startswith("usage:")
		assert '--xml' in out

		out, err = self.run_0install(['select', 'Local.xml'])
		assert not err, err
		assert 'Version: 0.1' in out

		out, err = self.run_0install(['select', 'Local.xml', '--command='])
		assert not err, err
		assert 'Version: 0.1' in out

		local_uri = model.canonical_iface_uri('Local.xml')
		out, err = self.run_0install(['select', 'Local.xml'])
		assert not err, err
		assert 'Version: 0.1' in out

		out, err = self.run_0install(['select', 'Local.xml', '--xml'])
		sels = selections.Selections(qdom.parse(StringIO(str(out))))
		assert sels.selections[local_uri].version == '0.1'

		out, err = self.run_0install(['select', 'selections.xml'])
		assert not err, err
		assert 'Version: 1\n' in out
		assert '(not cached)' in out

		out, err = self.run_0install(['select', 'runnable/RunExec.xml'])
		assert not err, err
		assert 'Runner' in out, out

	def testDownload(self):
		out, err = self.run_0install(['download'])
		assert out.lower().startswith("usage:")
		assert '--show' in out

		out, err = self.run_0install(['download', 'Local.xml', '--show'])
		assert not err, err
		assert 'Version: 0.1' in out

		local_uri = model.canonical_iface_uri('Local.xml')
		out, err = self.run_0install(['download', 'Local.xml', '--xml'])
		assert not err, err
		sels = selections.Selections(qdom.parse(StringIO(str(out))))
		assert sels.selections[local_uri].version == '0.1'

		out, err = self.run_0install(['download', 'Local.xml', '--show', '--with-store=/foo'])
		assert not err, err
		assert self.config.stores.stores[-1].dir == '/foo'

		out, err = self.run_0install(['download', '--offline', 'selections.xml'])
		assert 'Would download' in err
		self.config.network_use = model.network_full

		self.config.stores = TestStores()
		digest = 'sha1=3ce644dc725f1d21cfcf02562c76f375944b266a'
		self.config.fetcher.allow_download(digest)
		out, err = self.run_0install(['download', 'Hello.xml', '--show'])
		assert not err, err
		assert self.config.stores.lookup_any([digest]).startswith('/fake')
		assert 'Version: 1\n' in out

		out, err = self.run_0install(['download', '--offline', 'selections.xml', '--show'])
		assert '/fake_store' in out
		self.config.network_use = model.network_full

	def testDownloadSelections(self):
		self.config.stores = TestStores()
		digest = 'sha1=3ce644dc725f1d21cfcf02562c76f375944b266a'
		self.config.fetcher.allow_download(digest)
		hello = reader.load_feed('Hello.xml')
		self.config.fetcher.allow_feed_download('http://example.com:8000/Hello.xml', hello)
		out, err = self.run_0install(['download', 'selections.xml', '--show'])
		assert not err, err
		assert self.config.stores.lookup_any([digest]).startswith('/fake')
		assert 'Version: 1\n' in out

	def testUpdate(self):
		out, err = self.run_0install(['update'])
		assert out.lower().startswith("usage:")
		assert '--message' in out, out

		# Updating a local feed with no dependencies
		out, err = self.run_0install(['update', 'Local.xml'])
		assert not err, err
		assert 'No updates found' in out, out

		# Using a remote feed for the first time
		self.config.stores = TestStores()
		binary_feed = reader.load_feed('Binary.xml')
		self.config.fetcher.allow_download('sha1=123')
		self.config.fetcher.allow_feed_download('http://foo/Binary.xml', binary_feed)
		out, err = self.run_0install(['update', 'http://foo/Binary.xml'])
		assert not err, err
		assert 'Binary.xml: new -> 1.0' in out, out

		# No updates.
		self.config.fetcher.allow_feed_download('http://foo/Binary.xml', binary_feed)
		out, err = self.run_0install(['update', 'http://foo/Binary.xml'])
		assert not err, err
		assert 'No updates found' in out, out

		# New binary release available.
		new_binary_feed = reader.load_feed('Binary.xml')
		new_binary_feed.implementations['sha1=123'].version = model.parse_version('1.1')
		self.config.fetcher.allow_feed_download('http://foo/Binary.xml', new_binary_feed)
		out, err = self.run_0install(['update', 'http://foo/Binary.xml'])
		assert not err, err
		assert 'Binary.xml: 1.0 -> 1.1' in out, out

		# Compiling from source for the first time.
		source_feed = reader.load_feed('Source.xml')
		compiler_feed = reader.load_feed('Compiler.xml')
		self.config.fetcher.allow_download('sha1=234')
		self.config.fetcher.allow_download('sha1=345')
		self.config.fetcher.allow_feed_download('http://foo/Compiler.xml', compiler_feed)
		self.config.fetcher.allow_feed_download('http://foo/Binary.xml', binary_feed)
		self.config.fetcher.allow_feed_download('http://foo/Source.xml', source_feed)
		out, err = self.run_0install(['update', 'http://foo/Binary.xml', '--source'])
		assert not err, err
		assert 'Binary.xml: new -> 1.0' in out, out
		assert 'Compiler.xml: new -> 1.0' in out, out

		# New compiler released.
		new_compiler_feed = reader.load_feed('Compiler.xml')
		new_compiler_feed.implementations['sha1=345'].version = model.parse_version('1.1')
		self.config.fetcher.allow_feed_download('http://foo/Compiler.xml', new_compiler_feed)
		self.config.fetcher.allow_feed_download('http://foo/Binary.xml', binary_feed)
		self.config.fetcher.allow_feed_download('http://foo/Source.xml', source_feed)
		out, err = self.run_0install(['update', 'http://foo/Binary.xml', '--source'])
		assert not err, err
		assert 'Compiler.xml: 1.0 -> 1.1' in out, out

		# A dependency disappears.
		new_source_feed = reader.load_feed('Source.xml')
		new_source_feed.implementations['sha1=234'].requires = []
		self.config.fetcher.allow_feed_download('http://foo/Compiler.xml', new_compiler_feed)
		self.config.fetcher.allow_feed_download('http://foo/Binary.xml', binary_feed)
		self.config.fetcher.allow_feed_download('http://foo/Source.xml', new_source_feed)
		out, err = self.run_0install(['update', 'http://foo/Binary.xml', '--source'])
		assert not err, err
		assert 'No longer used: http://foo/Compiler.xml' in out, out

	def testConfig(self):
		out, err = self.run_0install(['config', '--help'])
		assert out.lower().startswith("usage:")
		assert '--console' in out

		out, err = self.run_0install(['config'])
		assert not err, err
		assert 'full' in out, out
		assert 'freshness = 0' in out, out
		assert 'help_with_testing = False' in out, out

		out, err = self.run_0install(['config', 'help_with_testing'])
		assert out == 'False\n', out

		file_config = policy.load_config(handler.Handler())
		def get_value(name):
			old_stdout = sys.stdout
			sys.stdout = StringIO()
			try:
				cmd.config.handle(file_config, None, [name])
				cmd_output = sys.stdout.getvalue()
			finally:
				sys.stdout = old_stdout
			return cmd_output

		assert get_value('freshness') == '30d\n'
		assert get_value('network_use') == 'full\n'
		assert get_value('help_with_testing') == 'False\n'

		cmd.config.handle(file_config, None, ['freshness', '5m'])
		cmd.config.handle(file_config, None, ['help_with_testing', 'True'])
		cmd.config.handle(file_config, None, ['network_use', 'minimal'])
		assert file_config.freshness == 5 * 60
		assert file_config.network_use == model.network_minimal
		assert file_config.help_with_testing == True

		file_config2 = policy.load_config(handler.Handler())
		assert file_config2.freshness == 5 * 60
		assert file_config2.network_use == model.network_minimal
		assert file_config2.help_with_testing == True

		cmd.config.handle(file_config, None, ['help_with_testing', 'falsE'])
		assert file_config.help_with_testing == False

		for period in ['1s', '2d', '3.5m', '4h', '5d']:
			secs = cmd.config.TimeInterval.parse(period)
			assert cmd.config.TimeInterval.format(secs) == period

	def testAddFeed(self):
		binary_iface = self.config.iface_cache.get_interface('http://foo/Binary.xml')

		out, err = self.run_0install(['list-feeds', binary_iface.uri])
		assert "(no feeds)" in out, out
		assert not err, err

		out, err = self.run_0install(['add-feed'])
		assert out.lower().startswith("usage:")
		assert 'NEW-FEED' in out

		sys.stdin = Reply('1')
		assert binary_iface.extra_feeds == []

		out, err = self.run_0install(['add-feed', 'Source.xml'])
		assert not err, err
		assert "Add as feed for 'http://foo/Binary.xml'" in out, out
		assert len(binary_iface.extra_feeds) == 1

		out, err = self.run_0install(['list-feeds', binary_iface.uri])
		assert "Source.xml" in out
		assert not err, err

		out, err = self.run_0install(['remove-feed', 'Source.xml'])
		assert not err, err
		assert "Remove as feed for 'http://foo/Binary.xml'" in out, out
		assert len(binary_iface.extra_feeds) == 0

		source_feed = reader.load_feed('Source.xml')
		self.config.fetcher.allow_feed_download('http://foo/Source.xml', source_feed)
		out, err = self.run_0install(['add-feed', 'http://foo/Source.xml'])
		assert not err, err
		assert 'Downloading feed; please wait' in out, out
		assert len(binary_iface.extra_feeds) == 1

	def testImport(self):
		out, err = self.run_0install(['import'])
		assert out.lower().startswith("usage:")
		assert 'FEED' in out

		stream = file('6FCF121BE2390E0B.gpg')
		gpg.import_key(stream)
		stream.close()
		sys.stdin = Reply('Y\n')
		out, err = self.run_0install(['import', 'Hello.xml'])
		assert not out, out
		assert 'Trusting DE937DD411906ACF7C263B396FCF121BE2390E0B for example.com:8000' in err, out

	def testList(self):
		out, err = self.run_0install(['list', 'foo', 'bar'])
		assert out.lower().startswith("usage:")
		assert 'PATTERN' in out

		out, err = self.run_0install(['list'])
		assert not err, err
		assert '' == out, repr(out)

		self.testImport()

		out, err = self.run_0install(['list'])
		assert not err, err
		assert 'http://example.com:8000/Hello.xml\n' == out, repr(out)

		out, err = self.run_0install(['list', 'foo'])
		assert not err, err
		assert '' == out, repr(out)

		out, err = self.run_0install(['list', 'hello'])
		assert not err, err
		assert 'http://example.com:8000/Hello.xml\n' == out, repr(out)

	def testRun(self):
		out, err = self.run_0install(['run'])
		assert out.lower().startswith("usage:")
		assert 'URI' in out, out

		out, err = self.run_0install(['run', '--dry-run', 'runnable/Runnable.xml', '--help'])
		assert not err, err
		assert 'arg-for-runner' in out, out
		assert '--help' in out, out

	def testDigest(self):
		hw = os.path.join(mydir, 'HelloWorld.tgz')
		out, err = self.run_0install(['digest', '--algorithm=sha1', hw])
		assert out == 'sha1=3ce644dc725f1d21cfcf02562c76f375944b266a\n', out
		assert not err, err

		out, err = self.run_0install(['digest', hw])
		assert out == 'sha1new=290eb133e146635fe37713fd58174324a16d595f\n', out
		assert not err, err

		out, err = self.run_0install(['digest', hw, 'HelloWorld'])
		assert out == 'sha1new=491678c37f77fadafbaae66b13d48d237773a68f\n', out
		assert not err, err

		tmp = tempfile.mkdtemp(prefix = '0install')
		out, err = self.run_0install(['digest', tmp])
		assert out == 'sha1new=da39a3ee5e6b4b0d3255bfef95601890afd80709\n', out
		assert not err, err
		os.rmdir(tmp)

if __name__ == '__main__':
	unittest.main()
