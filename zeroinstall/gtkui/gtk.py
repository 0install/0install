"""Compatibility wrapper to make Python 3's GTK look more like Python 2's version.
@since: 1.10
"""

# Copyright (C) 2012, Thomas Leonard
# See the README file for details, or visit http://0install.net.

from __future__ import absolute_import
import sys

if sys.version_info[0] > 2:
	# Python 3

	from gi.repository import Gdk as gdk
	from gi.repository.Gdk import Screen

	from gi.repository.Gtk import MessageType, ResponseType, WindowPosition, PolicyType, ShadowType, WrapMode
	from gi.repository.Gtk import Dialog, ScrolledWindow, TextView, TreePath
	from gi.repository.Gtk import Builder, Menu
	from gi.repository.Gtk import TreeStore, TreeViewColumn, CellRendererText
	from gi.repository.Gtk import STOCK_CLOSE
	from gi.repository.Gtk import MenuItem as GtkMenuItem

	MESSAGE_ERROR = MessageType.ERROR

	RESPONSE_CANCEL = ResponseType.CANCEL
	RESPONSE_CLOSE = ResponseType.CLOSE
	RESPONSE_HELP = ResponseType.HELP
	RESPONSE_DELETE_EVENT = ResponseType.DELETE_EVENT

	WIN_POS_CENTER = WindowPosition.CENTER
	POLICY_AUTOMATIC = PolicyType.AUTOMATIC
	POLICY_ALWAYS = PolicyType.ALWAYS
	SHADOW_IN = ShadowType.IN
	WRAP_WORD = WrapMode.WORD

	gdk.screen_width = Screen.get_default().get_width
	gdk.screen_height = Screen.get_default().get_height

	gdk.BUTTON_PRESS = gdk.EventType.BUTTON_PRESS

	def MenuItem(label):
		item = GtkMenuItem()
		item.set_label(label)
		return item

	def path_depth(path):
		return path.get_depth()

	def path_parent(path):
		parent = path.copy()
		parent.up()
		return parent
else:
	from gtk import *				# Python 2

	def path_depth(path):
		return len(path)

	def path_parent(path):
		return path[:-1]
