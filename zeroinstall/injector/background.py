"""
Check for updates in a background process. If we can start a program immediately, but some of our information
is rather old (longer that the L{config.Config.freshness} threshold) then we run it anyway, and check for updates using a new
process that runs quietly in the background.

This avoids the need to annoy people with a 'checking for updates' box when they're trying to run things.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
import sys, os
from logging import info, warn
from zeroinstall.support import tasks
from zeroinstall.injector import handler

def _escape_xml(s):
	return s.replace('&', '&amp;').replace('<', '&lt;')

def _exec_gui(uri, *args):
	parent_dir = os.path.dirname(os.path.dirname(__file__))
	child_args = [sys.executable, '-u', os.path.join(parent_dir, '0launch-gui/0launch-gui')] + list(args) + [uri]
	os.execvp(sys.executable, child_args)

class _NetworkState:
	NM_STATE_UNKNOWN = 0
	NM_STATE_ASLEEP = 10
	NM_STATE_DISCONNECTED = 20
	NM_STATE_DISCONNECTING = 30
	NM_STATE_CONNECTING = 40
	NM_STATE_CONNECTED_LOCAL = 50
	NM_STATE_CONNECTED_SITE = 60
	NM_STATE_CONNECTED_GLOBAL = 70

	# Maps enum values from version <= 0.8 to current (0.9) values
	v0_8 = {
		0: NM_STATE_UNKNOWN,
		1: NM_STATE_ASLEEP,
		2: NM_STATE_CONNECTING,
		3: NM_STATE_CONNECTED_GLOBAL,
		4: NM_STATE_DISCONNECTED,
	}


class BackgroundHandler(handler.Handler):
	"""A Handler for non-interactive background updates. Runs the GUI if interaction is required."""
	def __init__(self, title, root):
		handler.Handler.__init__(self)
		self.title = title
		self.notification_service = None
		self.network_manager = None
		self.notification_service_caps = []
		self.root = root	# If we need to confirm any keys, run the GUI on this

		try:
			import dbus
			import dbus.glib
		except Exception as ex:
			info(_("Failed to import D-BUS bindings: %s"), ex)
			return

		try:
			session_bus = dbus.SessionBus()
			remote_object = session_bus.get_object('org.freedesktop.Notifications',
								'/org/freedesktop/Notifications')

			self.notification_service = dbus.Interface(remote_object,
							'org.freedesktop.Notifications')

			# The Python bindings insist on printing a pointless introspection
			# warning to stderr if the service is missing. Force it to be done
			# now so we can skip it
			old_stderr = sys.stderr
			sys.stderr = None
			try:
				self.notification_service_caps = [str(s) for s in
						self.notification_service.GetCapabilities()]
			finally:
				sys.stderr = old_stderr
		except Exception as ex:
			info(_("No D-BUS notification service available: %s"), ex)

		try:
			system_bus = dbus.SystemBus()
			remote_object = system_bus.get_object('org.freedesktop.NetworkManager',
								'/org/freedesktop/NetworkManager')

			self.network_manager = dbus.Interface(remote_object,
							'org.freedesktop.NetworkManager')
		except Exception as ex:
			info(_("No D-BUS network manager service available: %s"), ex)

	def get_network_state(self):
		if self.network_manager:
			try:
				state = self.network_manager.state()
				if state < 10:
					state = _NetworkState.v0_8.get(state,
								_NetworkState.NM_STATE_UNKNOWN)
				return state

			except Exception as ex:
				warn(_("Error getting network state: %s"), ex)
		return _NetworkState.NM_STATE_UNKNOWN

	def confirm_import_feed(self, pending, valid_sigs):
		"""Run the GUI if we need to confirm any keys."""
		info(_("Can't update feed; signature not yet trusted. Running GUI..."))
		_exec_gui(self.root, '--download', '--refresh', '--systray')

	def report_error(self, exception, tb = None):
		from zeroinstall.injector import download
		if isinstance(exception, download.DownloadError):
			tb = None

		if tb:
			import traceback
			details = '\n' + '\n'.join(traceback.format_exception(type(exception), exception, tb))
		else:
			try:
				details = unicode(exception)
			except:
				details = repr(exception)
		self.notify("Zero Install", _("Error updating %(title)s: %(details)s") % {'title': self.title, 'details': details.replace('<', '&lt;')})

	def notify(self, title, message, timeout = 0, actions = []):
		"""Send a D-BUS notification message if possible. If there is no notification
		service available, log the message instead."""
		if not self.notification_service:
			info('%s: %s', title, message)
			return None

		LOW = 0
		NORMAL = 1
		#CRITICAL = 2

		import dbus.types

		hints = {}
		if actions:
			hints['urgency'] = dbus.types.Byte(NORMAL)
		else:
			hints['urgency'] = dbus.types.Byte(LOW)

		return self.notification_service.Notify('Zero Install',
			0,		# replaces_id,
			'',		# icon
			_escape_xml(title),
			_escape_xml(message),
			actions,
			hints,
			timeout * 1000)

def _detach():
	"""Fork a detached grandchild.
	@return: True if we are the original."""
	child = os.fork()
	if child:
		pid, status = os.waitpid(child, 0)
		assert pid == child
		return True

	# The calling process might be waiting for EOF from its child.
	# Close our stdout so we don't keep it waiting.
	# Note: this only fixes the most common case; it could be waiting
	# on any other FD as well. We should really use gobject.spawn_async
	# to close *all* FDs.
	null = os.open('/dev/null', os.O_RDWR)
	os.dup2(null, 1)
	os.close(null)

	grandchild = os.fork()
	if grandchild:
		os._exit(0)	# Parent's waitpid returns and grandchild continues

	return False

def _check_for_updates(requirements, verbose):
	from zeroinstall.injector.driver import Driver
	from zeroinstall.injector.config import load_config

	background_handler = BackgroundHandler(requirements.interface_uri, requirements.interface_uri)
	background_config = load_config(background_handler)
	root_iface = background_config.iface_cache.get_interface(requirements.interface_uri).get_name()
	background_handler.title = root_iface

	driver = Driver(config = background_config, requirements = requirements)

	info(_("Checking for updates to '%s' in a background process"), root_iface)
	if verbose:
		background_handler.notify("Zero Install", _("Checking for updates to '%s'...") % root_iface, timeout = 1)

	network_state = background_handler.get_network_state()
	if network_state not in (_NetworkState.NM_STATE_CONNECTED_SITE, _NetworkState.NM_STATE_CONNECTED_GLOBAL):
		info(_("Not yet connected to network (status = %d). Sleeping for a bit..."), network_state)
		import time
		time.sleep(120)
		if network_state in (_NetworkState.NM_STATE_DISCONNECTED, _NetworkState.NM_STATE_ASLEEP):
			info(_("Still not connected to network. Giving up."))
			sys.exit(1)
	else:
		info(_("NetworkManager says we're on-line. Good!"))

	background_config.freshness = 0			# Don't bother trying to refresh when getting the interface
	refresh = driver.solve_with_downloads(force = True)	# (causes confusing log messages)
	tasks.wait_for_blocker(refresh)

	# We could even download the archives here, but for now just
	# update the interfaces.

	if not driver.need_download():
		if verbose:
			background_handler.notify("Zero Install", _("No updates to download."), timeout = 1)
		sys.exit(0)

	background_handler.notify("Zero Install",
			      _("Updates ready to download for '%s'.") % root_iface,
			      timeout = 1)
	_exec_gui(requirements.interface_uri, '--refresh', '--systray')
	sys.exit(1)

def spawn_background_update(driver, verbose):
	"""Spawn a detached child process to check for updates.
	@param driver: driver containing interfaces to update
	@type driver: L{driver.Driver}
	@param verbose: whether to notify the user about minor events
	@type verbose: bool
	@since: 1.5 (used to take a Policy)"""
	iface_cache = driver.config.iface_cache
	# Mark all feeds as being updated. Do this before forking, so that if someone is
	# running lots of 0launch commands in series on the same program we don't start
	# huge numbers of processes.
	for uri in driver.solver.feeds_used:
		iface_cache.mark_as_checking(uri)

	if _detach():
		return

	try:
		try:
			_check_for_updates(driver.requirements, verbose)
		except SystemExit:
			raise
		except:
			import traceback
			traceback.print_exc()
			sys.stdout.flush()
	finally:
		os._exit(1)
