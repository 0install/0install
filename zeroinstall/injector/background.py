"""
Check for updates in a background process. If we can start a program immediately, but some of our information
is rather old (longer that the L{policy.Policy.freshness} threshold) then we run it anyway, and check for updates using a new
process that runs quietly in the background.

This avoids the need to annoy people with a 'checking for updates' box when they're trying to run things.
"""

import sys, os
from logging import info
from zeroinstall.support import tasks
from zeroinstall.injector.iface_cache import iface_cache
from zeroinstall.injector import handler

# Copyright (C) 2007, Thomas Leonard
# See the README file for details, or visit http://0install.net.

def _escape_xml(s):
	return s.replace('&', '&amp;').replace('<', '&lt;')

def _exec_gui(uri, *args):
	os.execvp('0launch', ['0launch', '--download-only', '--gui'] + list(args) + [uri])

class BackgroundHandler(handler.Handler):
	"""A Handler for non-interactive background updates. Runs the GUI if interaction is required."""
	def __init__(self, title):
		handler.Handler.__init__(self)
		self.title = title

		try:
			import dbus
			import dbus.glib

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
				self.notification_service.GetCapabilities()
			finally:
				sys.stderr = old_stderr

			self.have_notifications = True
		except Exception, ex:
			info("Failed to import D-BUS bindings: %s", ex)
			self.have_notifications = False
		
	def confirm_trust_keys(self, interface, sigs, iface_xml):
		"""Run the GUI if we need to confirm any keys."""
		self.notify("Zero Install", "Can't update interface; signature not yet trusted. Running GUI...", timeout = 2)
		_exec_gui(interface.uri, '--refresh')

	def report_error(self, exception, tb = None):
		self.notify("Zero Install", "Error updating %s: %s" % (self.title, str(exception)))

	def notify(self, title, message, timeout = 0, actions = []):
		"""Send a D-BUS notification message if possible. If there is no notification
		service available, log the message instead."""
		if not self.have_notifications:
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
	info("Checking for updates to '%s' in a background process", root_iface)
	if verbose:
		handler.notify("Zero Install", "Checking for updates to '%s'..." % root_iface, timeout = 1)

	policy.handler = BackgroundHandler(root_iface)
	policy.freshness = 0			# Don't bother trying to refresh when getting the interface
	refresh = policy.refresh_all()		# (causes confusing log messages)
	policy.handler.wait_for_blocker(refresh)

	# We could even download the archives here, but for now just
	# update the interfaces.

	if not policy.need_download():
		if verbose:
			policy.handler.notify("Zero Install", "No updates to download.", timeout = 1)
		sys.exit(0)

	if not policy.handler.have_notifications:
		policy.handler.notify("Zero Install", "Updates ready to download for '%s'." % root_iface)
		sys.exit(0)

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

	our_question = policy.handler.notify("Zero Install", "Updates ready to download for '%s'." % root_iface,
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
