"""
Check for updates in a background process. If we can start a program immediately, but some of our information
is rather old (longer that the L{config.Config.freshness} threshold) then we run it anyway, and check for updates using a new
process that runs quietly in the background.

This avoids the need to annoy people with a 'checking for updates' box when they're trying to run things.
"""

# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from zeroinstall import _, logger
import sys, os
from zeroinstall.support import tasks
from zeroinstall.injector import handler

def _escape_xml(s):
	return s.replace('&', '&amp;').replace('<', '&lt;')

class _NetworkState(object):
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

class BackgroundHandler:
	def __init__(self):
		self.notification_service = None
		self.network_manager = None
		self.notification_service_caps = []
		self.need_gui = False

		try:
			import dbus
			try:
				from dbus.mainloop.glib import DBusGMainLoop
				DBusGMainLoop(set_as_default=True)
			except ImportError:
				import dbus.glib		# Python 2
		except Exception as ex:
			logger.info(_("Failed to import D-BUS bindings: %s"), ex)
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
			logger.info(_("No D-BUS notification service available: %s"), ex)

		try:
			system_bus = dbus.SystemBus()
			remote_object = system_bus.get_object('org.freedesktop.NetworkManager',
								'/org/freedesktop/NetworkManager')

			self.network_manager = dbus.Interface(remote_object,
							'org.freedesktop.NetworkManager')
		except Exception as ex:
			logger.info(_("No D-BUS network manager service available: %s"), ex)

	def get_network_state(self):
		if self.network_manager:
			try:
				state = self.network_manager.state()
				if state < 10:
					state = _NetworkState.v0_8.get(state,
								_NetworkState.NM_STATE_UNKNOWN)
				return state

			except Exception as ex:
				logger.warning(_("Error getting network state: %s"), ex)
		return _NetworkState.NM_STATE_UNKNOWN

	def notify(self, title, message, timeout = 0, actions = []):
		"""Send a D-BUS notification message if possible. If there is no notification
		service available, log the message instead.
		@type title: str
		@type message: str
		@type timeout: int"""
		if not self.notification_service:
			logger.info('%s: %s', title, message)
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
