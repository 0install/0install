"""
Useful support routines (for internal use).
@since: 0.27
"""

# Copyright (C) 2007, Thomas Leonard
# See the README file for details, or visit http://0install.net.

import os, sys, logging

def find_in_path(prog):
	"""Search $PATH for prog.
	If prog is an absolute path, return it unmodified.
	@param prog: name of executable to find
	@return: the full path of prog, or None if not found
	@since: 0.27
	"""
	if os.path.isabs(prog): return prog
	for d in os.environ['PATH'].split(':'):
		path = os.path.join(d, prog)
		if os.path.isfile(path):
			return path
	return None

def read_bytes(fd, nbytes, null_ok = False):
	"""Read exactly nbytes from fd.
	@param fd: file descriptor to read from
	@param nbytes: number of bytes to read
	@param null_ok: if True, it's OK to receive EOF immediately (we then return None)
	@return: the bytes read
	@raise Exception: if we received less than nbytes of data
	"""
	data = ''
	while nbytes:
		got = os.read(fd, min(256, nbytes))
		if not got:
			if null_ok and not data:
				return None
			raise Exception("Unexpected end-of-stream. Data so far %s; expecting %d bytes more."
					% (repr(data), nbytes))
		data += got
		nbytes -= len(got)
	logging.debug("Message received: %s" % repr(data))
	return data

def pretty_size(size):
	"""Format a size for printing.
	@param size: the size in bytes
	@type size: int (or None)
	@return: the formatted size
	@rtype: str
	@since: 0.27"""
	if size is None:
		return '?'
	if size < 2048:
		return '%d bytes' % size
	size = float(size)
	for unit in ('Kb', 'Mb', 'Gb', 'Tb'):
		size /= 1024
		if size < 2048:
			break
	return '%.1f %s' % (size, unit)

def get_selections_gui(iface_uri, gui_args, test_callback = None):
	"""Run the GUI to choose and download a set of implementations.
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
		gui_sel = _fork_gui(namespaces.injector_gui_uri, [], [])
		if gui_sel is None:
			logging.info("Aborted at user request")
			return None		# Aborted by user
	else:
		logging.info("GUI is up-to-date.")
		# Try to start the GUI without using the network.
		gui_policy.freshness = 0
		gui_policy.network_use = model.network_offline
		gui_policy.recalculate_with_dl()
		assert gui_policy.ready		# Should always be some version available
		gui_policy.start_downloading_impls()
		gui_policy.handler.wait_for_downloads() # !?!
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

			reply = read_bytes(cli_from_gui, len('Length:') + 9, null_ok = True)
			if reply:
				if not reply.startswith('Length:'):
					raise Exception("Expected Length:, but got %s" % repr(reply))
				xml = read_bytes(cli_from_gui, int(reply.split(':', 1)[1], 16))

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

