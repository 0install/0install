"""
Check for updates in a background process. If we can start a program immediately, but some of our information
is rather old (longer that the freshness threshold) then we run it anyway, and check for updates using a new
process that runs quietly in the background.

This avoids the need to annoy people with a 'checking for updates' box when they're trying to run things.
"""

import sys, os
from logging import info
from zeroinstall.injector.iface_cache import iface_cache
from zeroinstall.injector import handler

# Copyright (C) 2007, Thomas Leonard
# See the README file for details, or visit http://0install.net.

try:
	import dbus
	import dbus.glib

	session_bus = dbus.SessionBus()

	remote_object = session_bus.get_object('org.freedesktop.Notifications',
						'/org/freedesktop/Notifications')
				      
	notification_service = dbus.Interface(remote_object, 
					'org.freedesktop.Notifications')

	# The Python bindings insist on printing a pointless introspection
	# warning to stderr if the service is missing. Force it to be done
	# now so we can skip it
	old_stderr = sys.stderr
	sys.stderr = None
	try:
		notification_service.GetCapabilities()
	finally:
		sys.stderr = old_stderr

	#notification_service.connect_to_signal('NotificationClosed', _NotificationClosed)
	#notification_service.connect_to_signal('ActionInvoked', _ActionInvoked)

	have_notifications = True
except Exception, ex:
	info("Failed to import D-BUS bindings: %s", ex)
	have_notifications = False

LOW = 0
NORMAL = 1
CRITICAL = 2

def notify(title, message, timeout = 0):
	if not have_notifications:
		info('%s: %s', title, message)
		return

	import time
	import dbus.types

	hints = {}
	hints['urgency'] = dbus.types.Byte(LOW)

	notification_service.Notify('Zero Install',
		0,		# replaces_id,
		'',		# icon
		title,
		message,
		[],
		hints,
		timeout * 1000)

class BackgroundHandler(handler.Handler):
	def __init__(self, title):
		handler.Handler.__init__(self)
		self.title = title
		
	def confirm_trust_keys(self, interface, sigs, iface_xml):
		notify("Zero Install", "Can't update interface; signature not yet trusted.")

	def report_error(self, exception):
		notify("Zero Install", "Error updating %s: %s" % (title, str(exception)))

def spawn_background_update(policy):
	child = os.fork()
	if child:
		pid, status = os.waitpid(child, 0)
		assert pid == child
		return

	grandchild = os.fork()
	if grandchild:
		os._exit(0)	# Parent's waitpid returns and grandchild continues

	try:
		# Child
		root_iface = iface_cache.get_interface(policy.root).get_name()
		info("Checking for updates to '%s' in a background process", root_iface)
		notify("Zero Install", "Checking for updates to '%s'..." % root_iface, timeout = 1)

		#ctx = gobject.main_context_default()
		#loop = gobject.MainLoop(ctx)
		#loop.run()

		policy.handler = BackgroundHandler(root_iface)
		policy.refresh_all()
		policy.handler.wait_for_downloads()

		if policy.need_download():
			notify("Zero Install", "Updates ready to download for '%s'." % root_iface)
		else:
			notify("Zero Install", "No updates to download.", timeout = 1)

		# We could even download the archives here, but for now just
		# update the interfaces.

		sys.exit(0)
	finally:
		os._exit(1)
