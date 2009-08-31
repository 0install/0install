"""
Convenience routines for performing common operations.
@since: 0.28
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os, sys, logging
from zeroinstall import support
from zeroinstall import _

def get_selections_gui(iface_uri, gui_args, test_callback = None):
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
	@return: the selected implementations
	@rtype: L{zeroinstall.injector.selections.Selections}
	@since: 0.28
	"""
	from zeroinstall.injector import selections, qdom
	from StringIO import StringIO

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
					if iface_uri is not None:
						gui_args = gui_args + ['--', iface_uri]
					os.execvp(gui_exe, [gui_exe] + gui_args)
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
			logging.info("Waiting for selections from GUI...")

			reply = support.read_bytes(cli.fileno(), len('Length:') + 9, null_ok = True)
			if reply:
				if not reply.startswith('Length:'):
					raise Exception("Expected Length:, but got %s" % repr(reply))
				xml = support.read_bytes(cli.fileno(), int(reply.split(':', 1)[1], 16))

				dom = qdom.parse(StringIO(xml))
				sels = selections.Selections(dom)

				if dom.getAttribute('run-test'):
					logging.info("Testing program, as requested by GUI...")
					if test_callback is None:
						output = "Can't test: no test_callback was passed to get_selections_gui()\n"
					else:
						output = test_callback(sels)
					logging.info("Sending results to GUI...")
					output = ('Length:%8x\n' % len(output)) + output
					logging.debug("Sending: %s", repr(output))
					while output:
						sent = cli.send(output)
						output = output[sent:]
					continue
			else:
				sels = None

			pid, status = os.waitpid(child, 0)
			assert pid == child
			if status == 1 << 8:
				logging.info("User cancelled the GUI; aborting")
				return None		# Aborted
			if status != 0:
				raise Exception("Error from GUI: code = %d" % status)
			break
	finally:
		for sock in [cli, gui]:
			if sock is not None: sock.close()
	
	return sels

def ensure_cached(uri):
	"""Ensure that an implementation of uri is cached.
	If not, it downloads one. It uses the GUI if a display is
	available, or the console otherwise.
	@param uri: the required interface
	@type uri: str
	@return: a new policy for this program, or None if the user cancelled
	@rtype: L{zeroinstall.injector.selections.Selections}
	"""
	from zeroinstall.injector import autopolicy, selections

	p = autopolicy.AutoPolicy(uri, download_only = True)
	p.freshness = 0		# Don't check for updates

	if p.need_download() or not p.ready:
		if os.environ.get('DISPLAY', None):
			return get_selections_gui(uri, [])
		else:
			p.recalculate_with_dl()
			p.start_downloading_impls()
			p.handler.wait_for_downloads()

	return selections.Selections(p)
