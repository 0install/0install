# Copyright (C) 2009, Thomas Leonard
# See http://0install.net/0compile.html

from __future__ import print_function

import logging
import sys, os
import gtk, pango
from zeroinstall.gui import dialog

import zeroinstall
from zeroinstall import _
from zeroinstall.support import tasks
from zeroinstall.cmd import slave

@tasks.async
def report_bug(driver, iface):
	try:
		assert iface

		# TODO: Check the interface to decide where to send bug reports

		issue_file = '/etc/issue'
		if os.path.exists(issue_file):
			with open(issue_file, 'rt') as stream:
				issue = stream.read().strip()
		else:
			issue = "(file '%s' not found)" % issue_file

		root_iface = driver.tree['interface']

		text = 'Problem with %s\n' % iface.uri
		if iface.uri != root_iface:
			text = '  (while attempting to run %s)\n' % root_iface
		text += '\n'

		text += 'Zero Install: Version %s, with Python %s\n' % (zeroinstall.version, sys.version)

		blocker = slave.get_bug_report_details()
		yield blocker
		tasks.check(blocker)

		text += '\n' + blocker.result['details'] + '\n'

		if hasattr(os, 'uname'):
			text += '\nSystem:\n  %s\n\nIssue:\n  %s\n' % ('\n  '.join(os.uname()), issue)
		else:
			text += '\nSystem without uname()\n'

		if driver.ready:
			text += "\n" + blocker.result['xml']

		reporter = BugReporter(driver, iface, text)
		reporter.show()
	except Exception:
		logging.warning("Bug report failed", exc_info = True)

class BugReporter(dialog.Dialog):
	def __init__(self, driver, iface, env):
		dialog.Dialog.__init__(self)

		self.set_title(_('Report a Bug'))
		self.driver = driver
		self.frames = []

		vbox = gtk.VBox(False, 4)
		vbox.set_border_width(10)
		self.vbox.pack_start(vbox, True, True, 0)

		self.set_default_size(gtk.gdk.screen_width() / 2, -1)

		def frame(title, contents, buffer):
			fr = gtk.Frame()
			label = gtk.Label('')
			label.set_markup('<b>%s</b>' % title)
			fr.set_label_widget(label)
			fr.set_shadow_type(gtk.SHADOW_NONE)
			vbox.pack_start(fr, True, True, 0)

			align = gtk.Alignment(0, 0, 1, 1)
			align.set_padding(0, 0, 16, 0)
			fr.add(align)
			align.add(contents)

			self.frames.append((title, buffer))

		def text_area(text = None, mono = False):
			swin = gtk.ScrolledWindow()
			swin.set_policy(gtk.POLICY_AUTOMATIC, gtk.POLICY_ALWAYS)
			swin.set_shadow_type(gtk.SHADOW_IN)

			tv = gtk.TextView()
			tv.set_wrap_mode(gtk.WRAP_WORD)
			swin.add(tv)
			if text:
				tv.get_buffer().insert_at_cursor(text)

			if mono:
				tv.modify_font(pango.FontDescription('mono'))

			tv.set_accepts_tab(False)

			return swin, tv.get_buffer()

		actual = text_area()
		frame(_("What doesn't work?"), *actual)

		expected = text_area()
		frame(_('What did you expect to happen?'), *expected)

		errors_box = gtk.VBox(False, 0)
		errors_swin, errors_buffer = text_area(mono = True)
		errors_box.pack_start(errors_swin, True, True, 0)
		buttons = gtk.HButtonBox()
		buttons.set_layout(gtk.BUTTONBOX_START)
		errors_box.pack_start(buttons, False, True, 4)
		get_errors = gtk.Button(_('Run it now and record the output'))
		get_errors.connect('clicked', lambda button: self.collect_output(errors_buffer))
		buttons.add(get_errors)

		frame(_('Are any errors or warnings displayed?'), errors_box, errors_buffer)

		if dialog.last_error:
			errors_buffer.insert_at_cursor(str(dialog.last_error))

		environ = text_area(env, mono = True)
		frame(_('Information about your setup'), *environ)

		# (not working since sf.net update)
		#
		# browse_url = 'http://sourceforge.net/tracker/?group_id=%d&atid=%d' % (self.sf_group_id, self.sf_artifact_id)
		# location_hbox = gtk.HBox(False, 4)
		# location_hbox.pack_start(gtk.Label(_('Bugs reports will be sent to:')), False, True, 0)
		# if hasattr(gtk, 'LinkButton'):
		# 	import browser
		# 	url_box = gtk.LinkButton(browse_url, label = browse_url)
		# 	url_box.connect('clicked', lambda button: browser.open_in_browser(browse_url))
		# else:
		# 	url_box = gtk.Label(browse_url)
		# 	url_box.set_selectable(True)
		# location_hbox.pack_start(url_box, False, True, 0)
		# vbox.pack_start(location_hbox, False, True, 0)

		self.add_button(gtk.STOCK_CANCEL, gtk.RESPONSE_CANCEL)
		self.add_button(gtk.STOCK_OK, gtk.RESPONSE_OK)
		self.set_default_response(gtk.RESPONSE_OK)

		def resp(box, r):
			if r == gtk.RESPONSE_OK:
				text = ''
				for title, buffer in self.frames:
					start = buffer.get_start_iter()
					end = buffer.get_end_iter()
					text += '%s\n\n%s\n\n' % (title, buffer.get_text(start, end, include_hidden_chars = False).strip())
				try:
					message = self.report_bug(iface, text)
				except Exception as ex:
					dialog.alert(None, _("Error sending bug report: {ex}".format(ex = ex)),
						     type = gtk.MESSAGE_ERROR)
				else:
					dialog.alert(None, _("Success: {msg}").format(msg = message),
						     type = gtk.MESSAGE_INFO)
					self.destroy()
			else:
				self.destroy()
		self.connect('response', resp)

		self.show_all()

	@tasks.async
	def collect_output(self, buffer):
		try:
			iter = buffer.get_end_iter()
			buffer.place_cursor(iter)

			if not self.driver.ready:
				buffer.insert_at_cursor("Can't run, because we failed to select a set of versions.\n")
				return

			self.hide()
			try:
				gtk.gdk.flush()
				iter = buffer.get_end_iter()
				buffer.place_cursor(iter)

				# Tell 0launch to run the program
				blocker = slave.run_test()
				yield blocker
				tasks.check(blocker)

				buffer.insert_at_cursor(blocker.result)
			finally:
				self.show()
		except Exception as ex:
			buffer.insert_at_cursor(str(ex))
			raise
	
	def report_bug(self, iface, text):
		try:
			if sys.version_info[0] > 2:
				from urllib.request import urlopen
				from urllib.parse import urlencode
			else:
				from urllib2 import urlopen
				from urllib import urlencode

			data = urlencode({
				'uri': iface.uri,
				'body': text}).encode('utf-8')
			stream = urlopen('http://0install.net/api/report-bug/', data = data)
			reply = stream.read().decode('utf-8')
			stream.close()
			return reply
		except:
			# Write to stderr in the hope that it doesn't get lost
			print("Error sending bug report: %s\n\n%s" % (iface, text), file=sys.stderr)
			raise
