"""
Check for updates in a background process. If we can start a program immediately, but some of our information
is rather old (longer that the L{policy.Policy.freshness} threshold) then we run it anyway, and check for updates using a new
process that runs quietly in the background.

This avoids the need to annoy people with a 'checking for updates' box when they're trying to run things.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _
import sys, os
from logging import info, warn
from zeroinstall.support import tasks
from zeroinstall.injector.iface_cache import iface_cache
from zeroinstall.injector import handler, namespaces

def _escape_xml(s):
	return s.replace('&', '&amp;').replace('<', '&lt;')

def _exec_gui(uri, *args):
	os.execvp('0launch', ['0launch', '--download-only', '--gui'] + list(args) + [uri])

class _NetworkState:
	NM_STATE_UNKNOWN = 0
	NM_STATE_ASLEEP = 1
	NM_STATE_CONNECTING = 2
	NM_STATE_CONNECTED = 3
	NM_STATE_DISCONNECTED = 4

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
		except Exception, ex:
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
		except Exception, ex:
			info(_("No D-BUS notification service available: %s"), ex)

		try:
			system_bus = dbus.SystemBus()
			remote_object = system_bus.get_object('org.freedesktop.NetworkManager',
								'/org/freedesktop/NetworkManager')

			self.network_manager = dbus.Interface(remote_object,
							'org.freedesktop.NetworkManager')
		except Exception, ex:
			info(_("No D-BUS network manager service available: %s"), ex)

	def get_network_state(self):
		if self.network_manager:
			try:
				return self.network_manager.state()
			except Exception, ex:
				warn(_("Error getting network state: %s"), ex)
		return _NetworkState.NM_STATE_UNKNOWN

	def confirm_trust_keys(self, interface, sigs, iface_xml):
		"""Run the GUI if we need to confirm any keys."""
		info(_("Can't update interface; signature not yet trusted. Running GUI..."))
		_exec_gui(self.root, '--refresh', '--download-only', '--systray')

	def report_error(self, exception, tb = None):
		from zeroinstall.injector import download
		if isinstance(exception, download.DownloadError):
			tb = None

		if tb:
			import traceback
			details = '\n' + '\n'.join(traceback.format_exception(type(exception), exception, tb))
		else:
			details = str(exception)
		self.notify("Zero Install", _("Error updating %(title)s: %(details)s") % {'title': self.title, 'details': details.replace('<', '&lt;')})

	def notify(self, title, message, timeout = 0, actions = []):
		"""Send a D-BUS notification message if possible. If there is no notification
		service available, log the message instead."""
		if not self.notification_service:
			info('%s: %s', title, message)
			return None

		LOW = 0
		NORMAL = 1
		CRITICAL = 2

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

	def have_actions_support(self):
		return 'actions' in self.notification_service_caps

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

def _check_for_updates(policy, verbose):
	root_iface = iface_cache.get_interface(policy.root).get_name()

	policy.handler = BackgroundHandler(root_iface, policy.root)

	info(_("Checking for updates to '%s' in a background process"), root_iface)
	if verbose:
		policy.handler.notify("Zero Install", _("Checking for updates to '%s'...") % root_iface, timeout = 1)

	network_state = policy.handler.get_network_state()
	if network_state != _NetworkState.NM_STATE_CONNECTED:
		info(_("Not yet connected to network (status = %d). Sleeping for a bit..."), network_state)
		import time
		time.sleep(120)
		if network_state in (_NetworkState.NM_STATE_DISCONNECTED, _NetworkState.NM_STATE_ASLEEP):
			info(_("Still not connected to network. Giving up."))
			sys.exit(1)
	else:
		info(_("NetworkManager says we're on-line. Good!"))

	policy.freshness = 0			# Don't bother trying to refresh when getting the interface
	refresh = policy.refresh_all()		# (causes confusing log messages)
	policy.handler.wait_for_blocker(refresh)

	# We could even download the archives here, but for now just
	# update the interfaces.

	if not policy.need_download():
		if verbose:
			policy.handler.notify("Zero Install", _("No updates to download."), timeout = 1)
		sys.exit(0)

	if not policy.handler.have_actions_support():
		# Can't ask the user to choose, so just notify them
		# In particular, Ubuntu/Jaunty doesn't support actions
		policy.handler.notify("Zero Install",
				      _("Updates ready to download for '%s'.") % root_iface,
				      timeout = 1)
		_exec_gui(policy.root, '--refresh', '--download-only', '--systray')
		sys.exit(1)

	notification_closed = tasks.Blocker("wait for notification response")

	def _NotificationClosed(nid, *unused):
		if nid != our_question: return
		notification_closed.trigger()

	def _ActionInvoked(nid, action):
		if nid != our_question: return
		if action == 'download':
			_exec_gui(policy.root)
		notification_closed.trigger()

	policy.handler.notification_service.connect_to_signal('NotificationClosed', _NotificationClosed)
	policy.handler.notification_service.connect_to_signal('ActionInvoked', _ActionInvoked)

	our_question = policy.handler.notify("Zero Install", _("Updates ready to download for '%s'.") % root_iface,
				actions = ['download', 'Download'])

	policy.handler.wait_for_blocker(notification_closed)

def spawn_background_update(policy, verbose):
	"""Spawn a detached child process to check for updates.
	@param policy: policy containing interfaces to update
	@type policy: L{policy.Policy}
	@param verbose: whether to notify the user about minor events
	@type verbose: bool"""
	# Mark all feeds as being updated. Do this before forking, so that if someone is
	# running lots of 0launch commands in series on the same program we don't start
	# huge numbers of processes.
	for x in policy.implementation:
		iface_cache.mark_as_checking(x.uri)			# Main feed
		for f in policy.usable_feeds(x):
			iface_cache.mark_as_checking(f.uri)		# Extra feeds

	if _detach():
		return

	try:
		try:
			_check_for_updates(policy, verbose)
		except SystemExit:
			raise
		except:
			import traceback
			traceback.print_exc()
			sys.stdout.flush()
	finally:
		os._exit(1)
