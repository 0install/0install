#!/usr/bin/env python
from basetest import BaseTest, TestStores, StringIO, BytesIO, ExecMan, BackgroundException
import sys, os, tempfile, subprocess, shutil, shlex
import unittest

sys.path.insert(0, '..')
from zeroinstall import cmd, logger, apps, alias
from zeroinstall.injector import model, selections, qdom, handler, gpg, config

mydir = os.path.dirname(__file__)
ocaml_0install = os.path.join(mydir, '..', 'build', 'ocaml', '0install')

class Reply:
	def __init__(self, reply):
		self.reply = reply

	def readline(self):
		return self.reply

class TestInstall(BaseTest):
	def run_ocaml(self, args):
		child = subprocess.Popen([ocaml_0install] + args, stdout = subprocess.PIPE, stderr = subprocess.PIPE, universal_newlines = True)
		out, err = child.communicate()
		child.wait()
		return out, err

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

	def testShow(self):
		out, err = self.run_ocaml(['show'])
		assert out.lower().startswith("usage:")
		assert '--xml' in out

		out, err = self.run_ocaml(['show', 'selections.xml'])
		assert not err, err
		assert 'Version: 1\n' in out
		assert '(not cached)' in out

		out, err = self.run_ocaml(['show', 'selections.xml', '-r'])
		assert not err, err
		self.assertEqual("http://example.com:8000/Hello.xml\n", out)

	def testSelect(self):
		out, err = self.run_ocaml(['select'])
		assert out.lower().startswith("usage:")
		assert '--xml' in out

		out, err = self.run_ocaml(['select', 'Local.xml'])
		assert not err, err
		assert 'Version: 0.1' in out

		out, err = self.run_ocaml(['select', 'Local.xml', '--command='])
		assert not err, err
		assert 'Version: 0.1' in out

		local_uri = model.canonical_iface_uri('Local.xml')
		out, err = self.run_ocaml(['select', 'Local.xml'])
		assert not err, err
		assert 'Version: 0.1' in out

		out, err = self.run_ocaml(['select', 'Local.xml', '--xml'])
		sels = selections.Selections(qdom.parse(BytesIO(str(out).encode('utf-8'))))
		assert sels.selections[local_uri].version == '0.1'

		# This now triggers a download to fetch the feed.
		#out, err = self.run_ocaml(['select', 'selections.xml'])
		#assert not err, err
		#assert 'Version: 1\n' in out
		#assert '(not cached)' in out

		out, err = self.run_ocaml(['select', 'runnable/RunExec.xml'])
		assert not err, err
		assert 'Runner' in out, out

	def testDownload(self):
		out, err = self.run_ocaml(['download'])
		assert out.lower().startswith("usage:")
		assert '--show' in out

		out, err = self.run_ocaml(['download', 'Local.xml', '--show'])
		assert not err, err
		assert 'Version: 0.1' in out

		local_uri = model.canonical_iface_uri('Local.xml')
		out, err = self.run_ocaml(['download', 'Local.xml', '--xml'])
		assert not err, err
		sels = selections.Selections(qdom.parse(BytesIO(str(out).encode('utf-8'))))
		assert sels.selections[local_uri].version == '0.1'

		out, err = self.run_ocaml(['download', 'Local.xml', '--show', '--with-store=/foo'])
		assert not err, err
		#assert self.config.stores.stores[-1].dir == '/foo'

		out, err = self.run_ocaml(['download', '--offline', 'selections.xml'])
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
		assert '/fake_store' in out, (out, err)
		self.config.network_use = model.network_full

	def testDownloadSelections(self):
		self.config.stores = TestStores()
		digest = 'sha1=3ce644dc725f1d21cfcf02562c76f375944b266a'
		self.config.fetcher.allow_download(digest)
		with open('Hello.xml') as stream: hello = stream.read()
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
		with open('Binary.xml') as stream: binary_feed = stream.read()
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
		new_binary_feed = binary_feed.replace("version='1.0'", "version='1.1'")
		assert binary_feed != new_binary_feed
		self.config.fetcher.allow_feed_download('http://foo/Binary.xml', new_binary_feed)
		out, err = self.run_0install(['update', 'http://foo/Binary.xml'])
		assert not err, err
		assert 'Binary.xml: 1.0 -> 1.1' in out, out

		# Compiling from source for the first time.
		with open('Source.xml') as stream: source_feed = stream.read()
		with open('Compiler.xml') as stream: compiler_feed = stream.read()
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
		new_compiler_feed = compiler_feed.replace(
				"id='sha1=345' version='1.0'",
				"id='sha1=345' version='1.1'")
		assert new_compiler_feed != compiler_feed
		self.config.fetcher.allow_feed_download('http://foo/Compiler.xml', new_compiler_feed)
		self.config.fetcher.allow_feed_download('http://foo/Binary.xml', binary_feed)
		self.config.fetcher.allow_feed_download('http://foo/Source.xml', source_feed)
		out, err = self.run_0install(['update', 'http://foo/Binary.xml', '--source'])
		assert not err, err
		assert 'Compiler.xml: 1.0 -> 1.1' in out, out

		# A dependency disappears.
		with open('Source-missing-req.xml') as stream: new_source_feed = stream.read()
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

		file_config = config.load_config(handler.Handler())
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

		file_config2 = config.load_config(handler.Handler())
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

		#assert 'file\n' in self.complete(["remove-feed", ""], 2)
		#assert "Source.xml" in self.complete(["remove-feed", binary_iface.uri], 3)

		out, err = self.run_0install(['remove-feed', 'Source.xml'])
		assert not err, err
		assert "Remove as feed for 'http://foo/Binary.xml'" in out, out
		assert len(binary_iface.extra_feeds) == 0

		with open('Source.xml') as stream: source_feed = stream.read()
		self.config.fetcher.allow_feed_download('http://foo/Source.xml', source_feed)
		out, err = self.run_0install(['add-feed', 'http://foo/Source.xml'])
		assert not err, err
		assert 'Downloading feed; please wait' in out, out
		assert len(binary_iface.extra_feeds) == 1

	def testImport(self):
		out, err = self.run_0install(['import'])
		assert out.lower().startswith("usage:")
		assert 'FEED' in out

		stream = open('6FCF121BE2390E0B.gpg')
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
		out, err = self.run_ocaml(['run'])
		assert out.lower().startswith("usage:")
		assert 'URI' in out, out


		out, err = self.run_ocaml(['run', '--dry-run', 'runnable/Runnable.xml', '--help'])
		assert not err, err
		assert 'arg-for-runner' in out, out
		assert '--help' in out, out

	def testDigest(self):
		hw = os.path.join(mydir, 'HelloWorld.tgz')
		out, err = self.run_0install(['digest', '--algorithm=sha1', hw])
		assert out == 'sha1=3ce644dc725f1d21cfcf02562c76f375944b266a\n', out
		assert not err, err

		out, err = self.run_0install(['digest', '-m', '--algorithm=sha256new', hw])
		assert out == 'D /HelloWorld\nX 4a6dfb4375ee2a63a656c8cbd6873474da67e21558f2219844f6578db8f89fca 1126963163 27 main\n', out
		assert not err, err

		out, err = self.run_0install(['digest', '-d', '--algorithm=sha256new', hw])
		assert out == 'sha256new_RPUJPVVHEWJ673N736OCN7EMESYAEYM2UAY6OJ4MDFGUZ7QACLKA\n', out
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
	
	def testApps(self):
		out, err = self.run_0install(['add', 'local-app'])
		assert out.lower().startswith("usage:")

		out, err = self.run_0install(['destroy', 'local-app', 'uri'])
		assert out.lower().startswith("usage:")

		local_feed = os.path.join(mydir, 'Local.xml')

		out, err = self.run_0install(['add', 'local:app', local_feed])
		assert not out, out
		assert "Invalid application name 'local:app'" in err, err

		out, err = self.run_0install(['add', '--dry-run', 'local-app', local_feed])
		assert out.startswith("[dry-run] would create directory "), out
		assert "[dry-run] would write launcher script " in out, out
		assert not err, err

		out, err = self.run_0install(['add', 'local-app', local_feed])
		assert not out, out
		assert not err, err

		out, err = self.run_0install(['add', 'local-app', local_feed])
		assert not out, out
		assert "Application 'local-app' already exists" in err, err

		self.check_man(['local-app'], 'tests/test-echo.1')

		#assert 'local-app' in self.complete(['select'], 2)
		out, err = self.run_ocaml(['select', 'local-app'])
		assert "Version: 0.1" in out, out
		assert not err, err

		out, err = self.run_ocaml(['show', 'local-app'])
		assert "Version: 0.1" in out, out
		assert not err, err

		out, err = self.run_0install(['update', 'local-app'])
		assert "No updates found. Continuing with version 0.1." in out, out
		assert not err, err

		# Run
		out, err = self.run_ocaml(['run', '--dry-run', 'local-app'])
		assert '[dry-run] would execute:' in out, out
		assert '/test-echo' in out, out
		assert not err, err

		# restrictions
		path = os.path.dirname(model.canonical_iface_uri(local_feed))
		out, err = self.run_0install(['update', 'local-app', '--version=10..'])
		self.assertEqual("Can't find all required implementations:\n"
				 "- {path}/Local.xml -> (problem)\n"
				 "    User requested version 10..\n"
				 "    No usable implementations:\n"
				 "      sha1=256 (0.1): Incompatible with user-specified requirements\n".format(path = path), err)
		assert not out, out

		out, err = self.run_0install(['update', 'local-app', '--version=0.1..'])
		assert "No updates found. Continuing with version 0.1." in out, out
		assert not err, err

		out, err = self.run_ocaml(['select', 'local-app'])
		assert not err, err
		self.assertEqual("User-provided restrictions in force:\n"
				 "  {path}/Local.xml: 0.1..\n"
				 "\n"
				 "- URI: {path}/Local.xml\n"
				 "  Version: 0.1\n"
				 "  Path: {path}\n".format(path = path), out)

		# remove restrictions [dry-run]
		out, err = self.run_0install(['update', '--dry-run', 'local-app', '--version-for', path + '/Local.xml', ''])
		assert "No updates found. Continuing with version 0.1." in out, out
		assert "[dry-run] would write " in out, out
		assert not err, err

		# remove restrictions
		out, err = self.run_0install(['update', 'local-app', '--version-for', path + '/Local.xml', ''])
		assert "No updates found. Continuing with version 0.1." in out, out
		assert not err, err

		out, err = self.run_ocaml(['select', 'local-app'])
		assert not err, err
		self.assertEqual("- URI: {path}/Local.xml\n"
				 "  Version: 0.1\n"
				 "  Path: {path}\n".format(path = path), out)


		# whatchanged
		#assert 'local-app' in self.complete(['whatchanged'], 2)
		out, err = self.run_0install(['whatchanged', 'local-app', 'uri'])
		assert out.lower().startswith("usage:")

		out, err = self.run_0install(['whatchanged', 'local-app'])
		assert "No previous history to compare against." in out, out
		assert not err, err

		app = self.config.app_mgr.lookup_app('local-app')
		with open(os.path.join(app.path, "selections.xml")) as stream:
			old_local = stream.read()
		new_local = old_local.replace('0.1', '0.1-pre')
		with open(os.path.join(app.path, "selections-2012-01-01.xml"), 'w') as stream:
			stream.write(new_local)

		out, err = self.run_0install(['whatchanged', 'local-app'])
		assert "Local.xml: 0.1-pre -> 0.1" in out, out
		assert not err, err

		out, err = self.run_0install(['whatchanged', 'local-app', '--full'])
		assert "--- 2012-01-01" in out, out
		assert not err, err

		# select detects changes
		new_local = old_local.replace('0.1', '0.1-pre2')
		with open(os.path.join(app.path, "selections.xml"), 'w') as stream:
			stream.write(new_local)
		out, err = self.run_ocaml(['show', 'local-app'])
		assert "Version: 0.1-pre2" in out, out
		assert not err, err
		out, err = self.run_ocaml(['select', 'local-app'])
		assert "Local.xml: 0.1-pre2 -> 0.1" in out, out
		assert "(note: use '0install update' instead to save the changes)" in out, out
		assert not err, err

		#assert 'local-app' in self.complete(['man'], 2)
		#assert 'local-app' in self.complete(['destroy'], 2)
		#self.assertEqual('', self.complete(['destroy', ''], 3))

		out, err = self.run_0install(['destroy', 'local-app'])
		assert not out, out
		assert not err, err

		out, err = self.run_0install(['destroy', 'local-app'])
		assert not out, out
		assert "No such application 'local-app'" in err, err

	def check_man(self, args, expected):
		out, err = self.run_ocaml(['--dry-run', 'man'] + args)
		assert '[dry-run] man' in out, (out, err)
		args = out[len('[dry-run] man '):]

		man_args = tuple(['man'] + shlex.split(args))
		if len(man_args) == 2:
			arg = man_args[1]
			if '/tests/' in arg:
				arg = 'tests/' + man_args[1].rsplit('/tests/', 1)[1]
			self.assertEqual(expected, arg)
		else:
			self.assertEqual(expected, man_args)

	def testUpdateAlias(self):
		local_feed = os.path.join(mydir, 'Local.xml')
		launcher_script = os.path.join(apps.find_bin_dir(), 'my-test-alias')
		with open(launcher_script, 'w') as stream:
			alias.write_script(stream, local_feed, None)

		out, err = self.run_0install(['update', 'my-test-alias'])
		self.assertEqual("Bad interface name 'my-test-alias'.\n(hint: try 'alias:my-test-alias' instead)\n", err)
		self.assertEqual("", out)

	def testMan(self):
		out, err = self.run_ocaml(['man', '--help'])
		assert out.lower().startswith("usage:")

		# Wrong number of args: pass-through
		self.check_man(['git', 'config'], ('man', 'git', 'config'))
		self.check_man([], ('man',))

		local_feed = os.path.join(mydir, 'Local.xml')
		launcher_script = os.path.join(apps.find_bin_dir(), 'my-test-alias')
		with open(launcher_script, 'w') as stream:
			alias.write_script(stream, model.canonical_iface_uri(local_feed), None)
		self.check_man(['my-test-alias'], 'tests/test-echo.1')

		self.check_man(['__i_dont_exist'], '__i_dont_exist')
		self.check_man(['ls'], 'ls')

		# No man-page
		binary_feed = os.path.join(mydir, 'Command.xml')
		launcher_script = os.path.join(apps.find_bin_dir(), 'my-binary-alias')
		with open(launcher_script, 'w') as stream:
			alias.write_script(stream, model.canonical_iface_uri(binary_feed), None)

		out, err = self.run_ocaml(['man', 'my-binary-alias'])
		assert not err, err
		assert "No matching manpage was found for 'my-binary-alias'" in out, out

		with open(os.path.join(self.config_home, 'bad-unicode'), 'wb') as stream:
			stream.write(bytes([198, 65]))
		self.check_man(['bad-unicode'], 'bad-unicode')

	def testAlias(self):
		local_feed = model.canonical_iface_uri(os.path.join(mydir, 'Local.xml'))
		alias_path = os.path.join(mydir, '..', '0alias')
		child = subprocess.Popen([alias_path, 'local-app', local_feed], stdout = subprocess.PIPE, stderr = subprocess.STDOUT, universal_newlines = True)
		out, err = child.communicate()
		assert '("0alias" is deprecated; using "0install add" instead)' in out, out
		assert not err, err

		app = self.config.app_mgr.lookup_app('local-app')
		assert app.get_requirements().interface_uri == local_feed

	def testAdd(self):
		out, err = self.run_0install(['add', '--help'])
		assert out.lower().startswith("usage:")

		local_feed = os.path.join(mydir, 'Local.xml')
		local_copy = os.path.join(self.data_home, 'Local.xml')

		os.mkdir(self.data_home)
		shutil.copyfile(local_feed, local_copy)

		out, err = self.run_0install(['add', 'local-app', local_copy])
		assert not out, out
		assert not err, err

		app = self.config.app_mgr.lookup_app('local-app')

		# Because the unit-tests run very quickly, we have to back-date things
		# a bit...
		def set_mtime(name, t):
			os.utime(name, (t, t))
		set_mtime(local_copy, 100)				# Feed edited at t=100
		set_mtime(os.path.join(app.path, 'last-checked'), 200)	# Added at t=200

		# Can run without using the solver...
		sels = app.get_selections(may_update = True)
		blocker = app.download_selections(sels)
		self.assertEqual(None, blocker)
		self.assertEqual(0, app._get_mtime('last-solve', warn_if_missing = False))

		# But if the feed is modifier, we resolve...
		set_mtime(local_copy, 300)
		blocker = app.download_selections(app.get_selections(may_update = True))
		self.assertEqual(None, blocker)
		self.assertNotEqual(0, app._get_mtime('last-solve', warn_if_missing = False))

		set_mtime(os.path.join(app.path, 'last-solve'), 400)
		blocker = app.download_selections(app.get_selections(may_update = True))
		self.assertEqual(None, blocker)
		self.assertEqual(400, app._get_mtime('last-solve', warn_if_missing = False))

		import logging; logger.setLevel(logging.ERROR)	# Will display a warning
		os.unlink(local_copy)
		app._touch('last-check-attempt')	# Prevent background update
		blocker = app.download_selections(app.get_selections(may_update = True))
		self.assertEqual(None, blocker)
		self.assertNotEqual(400, app._get_mtime('last-solve', warn_if_missing = False))

		# Local feed is updated; now requires a download
		os.unlink(os.path.join(app.path, 'last-check-attempt'))
		hello_feed = os.path.join(mydir, 'Hello.xml')
		set_mtime(os.path.join(app.path, 'last-solve'), 400)
		self.config.iface_cache._interfaces = {}
		self.config.iface_cache._feeds = {}
		shutil.copyfile(hello_feed, local_copy)
		try:
			blocker = app.download_selections(app.get_selections(may_update = True))
			assert 0
		except BackgroundException:
			pass

		# Selections changed, but no download required
		with open(local_copy, 'rt') as stream:
			data = stream.read()
		data = data.replace(' version="1">',
				    ' version="1.1" main="missing">')
		with open(local_copy, 'wt') as stream:
			stream.write(data)
		set_mtime(os.path.join(app.path, 'last-solve'), 400)

		blocker = app.download_selections(app.get_selections(may_update = True))
		self.assertEqual(None, blocker)

		# If the selections.xml gets deleted, regenerate it
		os.unlink(os.path.join(app.path, 'selections.xml'))
		self.config.stores = TestStores()
		self.config.fetcher.allow_download('sha1=3ce644dc725f1d21cfcf02562c76f375944b266a')
		sels = app.get_selections(may_update = True)
		assert sels is not None

if __name__ == '__main__':
	unittest.main()
