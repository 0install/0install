"""
Convenience routines for performing common operations.
@since: 0.28
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import print_function

import os, sys
from zeroinstall import support, SafeException, logger
from zeroinstall.support import tasks
from zeroinstall import logger

DontUseGUI = object()

def get_selections_gui(iface_uri, gui_args, test_callback = None, use_gui = True):
	"""Run the GUI to choose and download a set of implementations.
	The user may ask the GUI to submit a bug report about the program. In that case,
	the GUI may ask us to test it. test_callback is called in that case with the implementations
	to be tested; the callback will typically call L{zeroinstall.injector.run.test_selections} and return the result of that.
	@param iface_uri: the required program, or None to show just the preferences dialog
	@type iface_uri: str
	@param gui_args: any additional arguments for the GUI itself
	@type gui_args: [str]
	@param test_callback: function to use to try running the program
	@type test_callback: L{zeroinstall.injector.selections.Selections} -> str
	@param use_gui: if True, raise a SafeException if the GUI is not available. If None, returns DontUseGUI if the GUI cannot be started. If False, returns DontUseGUI always. (since 1.11)
	@param use_gui: bool | None
	@return: the selected implementations
	@rtype: L{zeroinstall.injector.selections.Selections}
	@since: 0.28
	"""
	if use_gui is False:
		return DontUseGUI

	if 'DISPLAY' not in os.environ:
		if use_gui is None:
			return DontUseGUI
		else:
			raise SafeException("Can't use GUI because $DISPLAY is not set")

	from zeroinstall.injector import selections, qdom
	from io import BytesIO

	from os.path import join, dirname
	gui_exe = join(dirname(__file__), '0launch-gui', '0launch-gui')

	import socket
	cli, gui = socket.socketpair()

	try:
		child = os.fork()
		if child == 0:
			# We are the child (GUI)
			try:
				try:
					cli.close()
					# We used to use pipes to support Python2.3...
					os.dup2(gui.fileno(), 1)
					os.dup2(gui.fileno(), 0)
					if use_gui is True:
						gui_args = ['-g'] + gui_args
					if iface_uri is not None:
						gui_args = gui_args + ['--', iface_uri]
					os.execvp(sys.executable, [sys.executable, gui_exe] + gui_args)
				except:
					import traceback
					traceback.print_exc(file = sys.stderr)
			finally:
				sys.stderr.flush()
				os._exit(1)
		# We are the parent (CLI)
		gui.close()
		gui = None

		while True:
			logger.info("Waiting for selections from GUI...")

			reply = support.read_bytes(cli.fileno(), len('Length:') + 9, null_ok = True)
			if reply:
				if not reply.startswith(b'Length:'):
					raise Exception("Expected Length:, but got %s" % repr(reply))
				reply = reply.decode('ascii')
				xml = support.read_bytes(cli.fileno(), int(reply.split(':', 1)[1], 16))

				dom = qdom.parse(BytesIO(xml))
				sels = selections.Selections(dom)

				if dom.getAttribute('run-test'):
					logger.info("Testing program, as requested by GUI...")
					if test_callback is None:
						output = b"Can't test: no test_callback was passed to get_selections_gui()\n"
					else:
						output = test_callback(sels)
					logger.info("Sending results to GUI...")
					output = ('Length:%8x\n' % len(output)).encode('utf-8') + output
					logger.debug("Sending: %s", repr(output))
					while output:
						sent = cli.send(output)
						output = output[sent:]
					continue
			else:
				sels = None

			pid, status = os.waitpid(child, 0)
			assert pid == child
			if status == 1 << 8:
				logger.info("User cancelled the GUI; aborting")
				return None		# Aborted
			elif status == 100 << 8:
				if use_gui is None:
					return DontUseGUI
				else:
					raise SafeException("No GUI available")
			if status != 0:
				raise Exception("Error from GUI: code = %d" % status)
			break
	finally:
		for sock in [cli, gui]:
			if sock is not None: sock.close()
	
	return sels

def ensure_cached(uri, command = 'run', config = None):
	"""Ensure that an implementation of uri is cached.
	If not, it downloads one. It uses the GUI if a display is
	available, or the console otherwise.
	@param uri: the required interface
	@type uri: str
	@return: the selected implementations, or None if the user cancelled
	@rtype: L{zeroinstall.injector.selections.Selections}
	"""
	from zeroinstall.injector.driver import Driver

	if config is None:
		from zeroinstall.injector.config import load_config
		config = load_config()

	from zeroinstall.injector.requirements import Requirements
	requirements = Requirements(uri)
	requirements.command = command

	d = Driver(config, requirements)

	if d.need_download() or not d.solver.ready:
		sels = get_selections_gui(uri, ['--command', command], use_gui = None)
		if sels != DontUseGUI:
			return sels
		done = d.solve_and_download_impls()
		tasks.wait_for_blocker(done)

	return d.solver.selections

def exec_man(stores, sels, main = None, fallback_name = None):
	"""Exec the man command to show the man-page for this interface.
	Never returns.
	@since: 1.12"""
	interface_uri = sels.interface
	selected_impl = sels.selections[interface_uri]

	if selected_impl.id.startswith('package'):
		impl_path = None
	else:
		impl_path = selected_impl.get_path(stores)

	if main is None:
		if sels.commands:
			selected_command = sels.commands[0]
		else:
			print("No <command> in selections!", file=sys.stderr)
			sys.exit(1)
		main = selected_command.path
		if main is None:
			print("No main program for interface '%s'" % interface_uri, file=sys.stderr)
			sys.exit(1)

	prog_name = os.path.basename(main)

	if impl_path is None:
		# Package implementation
		logger.debug("Searching for man-page native command %s (from %s)" % (prog_name, fallback_name))
		os.execlp('man', 'man', prog_name)

	assert impl_path

	logger.debug("Searching for man-page for %s or %s in %s" % (prog_name, fallback_name, impl_path))

	# TODO: the feed should say where the man-pages are, but for now we'll accept
	# a directory called man in some common locations...
	for mandir in ['man', 'share/man', 'usr/man', 'usr/share/man']:
		manpath = os.path.join(impl_path, mandir)
		if os.path.isdir(manpath):
			# Note: unlike "man -M", this also copes with LANG settings...
			os.environ['MANPATH'] = manpath
			os.execlp('man', 'man', prog_name)
			sys.exit(1)

	# No man directory given or found, so try searching for man files

	manpages = []
	for root, dirs, files in os.walk(impl_path):
		for f in files:
			if f.endswith('.gz'):
				manpage_file = f[:-3]
			else:
				manpage_file = f
			if manpage_file.endswith('.1') or \
			   manpage_file.endswith('.6') or \
			   manpage_file.endswith('.8'):
				manpage_prog = manpage_file[:-2]
				if manpage_prog == prog_name or manpage_prog == fallback_name:
					os.execlp('man', 'man', os.path.join(root, f))
					sys.exit(1)
				else:
					manpages.append((root, f))
		for d in list(dirs):
			if d.startswith('.'):
				dirs.remove(d)

	print("No matching manpage was found for '%s' (%s)" % (fallback_name, interface_uri))
	if manpages:
		print("These non-matching man-pages were found, however:")
		for root, file in manpages:
			print(os.path.join(root, file))
	sys.exit(1)
