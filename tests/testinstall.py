#!/usr/bin/env python
from basetest import BaseTest, StringIO, BytesIO
import sys, os, tempfile, subprocess, shlex
import unittest

sys.path.insert(0, '..')
from zeroinstall import cmd, alias
from zeroinstall.injector import model, qdom, handler, gpg, config, reader
import selections

mydir = os.path.dirname(__file__)

class Reply:
	def __init__(self, reply):
		self.reply = reply

	def readline(self):
		return self.reply

class TestInstall(BaseTest):
	maxDiff = None

	def testHelp(self):
		out, err = self.run_ocaml([])
		assert out.lower().startswith("usage:")
		assert 'add-feed' in out
		assert '--version' in out
		assert err == "Exit status: 1\n", err

		out2, err = self.run_ocaml(['--help'])
		assert err == "Exit status: 1\n", err
		assert out2 == out

		out, err = self.run_ocaml(['--version'])
		assert 'Thomas Leonard' in out
		assert not err, err

		out, err = self.run_ocaml(['foobar'])
		assert 'Unknown 0install sub-command' in err, err

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

	def testImport(self):
		child_config = config.Config()
		child_config.auto_approve_keys = False
		child_config.key_info_server = None
		child_config.save_globals()

		out, err = self.run_ocaml(['import'])
		assert out.lower().startswith("usage:")
		assert 'FEED' in out

		stream = open('6FCF121BE2390E0B.gpg')
		gpg.import_key(stream)
		stream.close()
		out, err = self.run_ocaml(['import', 'Hello.xml'], stdin = 'Y\n')
		assert not out, out
		assert 'Trusting DE937DD411906ACF7C263B396FCF121BE2390E0B for example.com:8000' in err, err

	def testList(self):
		out, err = self.run_ocaml(['list', 'foo', 'bar'])
		assert out.lower().startswith("usage:")
		assert 'PATTERN' in out

		out, err = self.run_ocaml(['list'])
		assert not err, err
		assert '' == out, repr(out)

		self.testImport()

		out, err = self.run_ocaml(['list'])
		assert not err, err
		assert 'http://example.com:8000/Hello.xml\n' == out, repr(out)

		out, err = self.run_ocaml(['list', 'foo'])
		assert not err, err
		assert '' == out, repr(out)

		out, err = self.run_ocaml(['list', 'hello'])
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
		launcher_script = os.path.join(self.config_home, 'my-test-alias')
		with open(launcher_script, 'w') as stream:
			alias.write_script(stream, local_feed, None)

		out, err = self.run_ocaml(['update', 'my-test-alias'])
		assert err.startswith("Bad interface name 'my-test-alias'.\n(hint: try 'alias:my-test-alias' instead)\n"), err
		self.assertEqual("", out)

	def testMan(self):
		out, err = self.run_ocaml(['man', '--help'])
		assert out.lower().startswith("usage:")

		# Wrong number of args: pass-through
		self.check_man(['git', 'config'], ('man', 'git', 'config'))
		self.check_man([], ('man',))

		local_feed = os.path.join(mydir, 'Local.xml')
		launcher_script = os.path.join(self.config_home, 'my-test-alias')
		with open(launcher_script, 'w') as stream:
			alias.write_script(stream, model.canonical_iface_uri(local_feed), None)
		self.check_man(['my-test-alias'], 'tests/test-echo.1')

		self.check_man(['__i_dont_exist'], '__i_dont_exist')
		self.check_man(['ls'], 'ls')

		# No man-page
		binary_feed = os.path.join(mydir, 'Command.xml')
		launcher_script = os.path.join(self.config_home, 'my-binary-alias')
		with open(launcher_script, 'w') as stream:
			alias.write_script(stream, model.canonical_iface_uri(binary_feed), None)

		out, err = self.run_ocaml(['man', 'my-binary-alias'])
		assert "Exit status: 1" in err, err
		assert "No matching manpage was found for 'my-binary-alias'" in out, out

		with open(os.path.join(self.config_home, 'bad-unicode'), 'wb') as stream:
			stream.write(bytes([198, 65]))
		self.check_man(['bad-unicode'], 'bad-unicode')

	def testAlias(self):
		local_feed = model.canonical_iface_uri(os.path.join(mydir, 'Local.xml'))
		alias_path = os.path.join(mydir, '..', '0alias')
		child = subprocess.Popen([alias_path, 'local-app', local_feed], stdout = subprocess.PIPE, stderr = subprocess.PIPE, universal_newlines = True)
		out, err = child.communicate()
		assert 'ERROR: "0alias" has been removed; use "0install add" instead' in err, err
		assert not out, out

if __name__ == '__main__':
	unittest.main()
