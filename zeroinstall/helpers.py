"""
Convenience routines for performing common operations.
@since: 0.28
"""

# Copyright (C) 2007, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os, sys, logging
from zeroinstall import support

def get_selections_gui(iface_uri, gui_args, test_callback = None):
	"""Run the GUI to choose and download a set of implementations.
	If the GUI itself is due for a check, refresh it first.
	The user may ask the GUI to submit a bug report about the program. In that case,
	the GUI may ask us to test it. test_callback is called in that case with the implementations
	to be tested; the callback will typically call L{run.test_selections} and return the result of that.
	@param iface_uri: the required program
	@type iface_uri: str
	@param gui_args: any additional arguments for the GUI itself
	@type gui_args: [str]
	@param test_callback: function to use to try running the program
	@type test_callback: L{selections.Selections} -> str
	@since: 0.28
	"""
	from zeroinstall.injector import selections, autopolicy, namespaces, model, run, qdom
	from StringIO import StringIO

	gui_policy = autopolicy.AutoPolicy(namespaces.injector_gui_uri)
	if iface_uri != namespaces.injector_gui_uri and (gui_policy.need_download() or gui_policy.stale_feeds):
		# The GUI itself needs updating. Do that first.
		logging.info("The GUI could do with updating first.")
		gui_sel = get_selections_gui(namespaces.injector_gui_uri, ['--refresh'])
		if gui_sel is None:
			logging.info("Aborted at user request")
			return None		# Aborted by user
	else:
		# Try to start the GUI without using the network.
		gui_policy.freshness = 0
		gui_policy.network_use = model.network_offline
		gui_policy.recalculate()
		assert gui_policy.ready		# Should always be some version available
		gui_sel = selections.Selections(gui_policy)

	cli_from_gui, gui_to_cli = os.pipe()		# socket.socketpair() not in Python 2.3 :-(
	gui_from_cli, cli_to_gui = os.pipe()
	try:
		child = os.fork()
		if child == 0:
			# We are the child
			try:
				try:
					os.close(cli_from_gui)
					os.close(cli_to_gui)
					os.dup2(gui_to_cli, 1)
					os.dup2(gui_from_cli, 0)
					run.execute_selections(gui_sel, gui_args + ['--', iface_uri])
				except:
					import traceback
					traceback.print_exc(file = sys.stderr)
			finally:
				sys.stderr.flush()
				os._exit(1)
		os.close(gui_from_cli)
		gui_from_cli = None
		os.close(gui_to_cli)
		gui_to_cli = None

		while True:
			logging.info("Waiting for selections from GUI...")

			reply = support.read_bytes(cli_from_gui, len('Length:') + 9, null_ok = True)
			if reply:
				if not reply.startswith('Length:'):
					raise Exception("Expected Length:, but got %s" % repr(reply))
				xml = support.read_bytes(cli_from_gui, int(reply.split(':', 1)[1], 16))

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
					logging.debug("Sending: %s" % `output`)
					while output:
						sent = os.write(cli_to_gui, output)
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
		for fd in [cli_to_gui, cli_from_gui, gui_to_cli, gui_from_cli]:
			if fd is not None: os.close(fd)
	
	return sels
