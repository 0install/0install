# Copyright (C) 2009, Thomas Leonard
# See http://0install.net/0compile.html

from __future__ import print_function

import sys, os
import gtk, pango
import dialog

import zeroinstall
from zeroinstall import _
from zeroinstall import support

def report_bug(driver, iface):
	assert iface

	# TODO: Check the interface to decide where to send bug reports

	issue_file = '/etc/issue'
	if os.path.exists(issue_file):
		issue = open(issue_file).read().strip()
	else:
		issue = "(file '%s' not found)" % issue_file

	requirements = driver.requirements

	text = 'Problem with %s\n' % iface.uri
	if iface.uri != requirements.interface_uri:
		text = '  (while attempting to run %s)\n' % requirements.interface_uri
	text += '\n'

	text += 'Zero Install: Version %s, with Python %s\n' % (zeroinstall.version, sys.version)

	text += '\nChosen implementations:\n'

	if not driver.solver.ready:
		text += '  Failed to select all required implementations\n'

	for chosen_iface_uri, impl in driver.solver.selections.selections.iteritems():
		text += '\n  Interface: %s\n' % chosen_iface_uri
		if impl:
			text += '    Version: %s\n' % impl.version
			feed_url = impl.attrs['from-feed']
			if feed_url != chosen_iface_uri:
				text += '  From feed: %s\n' % feed_url
			text += '         ID: %s\n' % impl.id
		else:
			chosen_iface = driver.config.iface_cache.get_interface(chosen_iface_uri)
			impls = driver.solver.details.get(chosen_iface, None)
			if impls:
				best, reason = impls[0]
				note = 'best was %s, but: %s' % (best, reason)
			else:
				note = 'not considered; %d available' % len(chosen_iface.implementations)

			text += '    No implementation selected (%s)\n' % note

	if hasattr(os, 'uname'):
		text += '\nSystem:\n  %s\n\nIssue:\n  %s\n' % ('\n  '.join(os.uname()), issue)
	else:
		text += '\nSystem without uname()\n'

	if driver.solver.ready:
		sels = driver.solver.selections
		text += "\n" + sels.toDOM().toprettyxml(encoding = 'utf-8')

	reporter = BugReporter(driver, iface, text)
	reporter.show()

class BugReporter(dialog.Dialog):
	def __init__(self, driver, iface, env):
		dialog.Dialog.__init__(self)

		self.sf_group_id = 76468
		self.sf_artifact_id = 929902

		self.set_title(_('Report a Bug'))
		self.set_modal(True)
		self.set_has_separator(False)
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

		browse_url = 'http://sourceforge.net/tracker/?group_id=%d&atid=%d' % (self.sf_group_id, self.sf_artifact_id)
		location_hbox = gtk.HBox(False, 4)
		location_hbox.pack_start(gtk.Label(_('Bugs reports will be sent to:')), False, True, 0)
		if hasattr(gtk, 'LinkButton'):
			import browser
			url_box = gtk.LinkButton(browse_url, label = browse_url)
			url_box.connect('clicked', lambda button: browser.open_in_browser(browse_url))
		else:
			url_box = gtk.Label(browse_url)
			url_box.set_selectable(True)
		location_hbox.pack_start(url_box, False, True, 0)
		vbox.pack_start(location_hbox, False, True, 0)

		self.add_button(gtk.STOCK_CANCEL, gtk.RESPONSE_CANCEL)
		self.add_button(gtk.STOCK_OK, gtk.RESPONSE_OK)
		self.set_default_response(gtk.RESPONSE_OK)

		def resp(box, r):
			if r == gtk.RESPONSE_OK:
				text = ''
				for title, buffer in self.frames:
					start = buffer.get_start_iter()
					end = buffer.get_end_iter()
					text += '%s\n\n%s\n\n' % (title, buffer.get_text(start, end).strip())
				title = _('Bug for %s') % iface.get_name()
				self.report_bug(title, text)
				dialog.alert(None, _("Your bug report has been sent. Thank you."),
					     type = gtk.MESSAGE_INFO)
				self.destroy()
			else:
				self.destroy()
		self.connect('response', resp)

		self.show_all()

	def collect_output(self, buffer):
		iter = buffer.get_end_iter()
		buffer.place_cursor(iter)

		if not self.driver.solver.ready:
			sels = self.driver.solver.selections
			buffer.insert_at_cursor("Can't run:\n{reason}".format(
					reason = self.driver.solver.get_failure_reason()))
			return
		uncached = self.driver.get_uncached_implementations()
		if uncached:
			buffer.insert_at_cursor("Can't run: the chosen versions have not been downloaded yet. I need:\n\n- " +
				"\n\n- " . join(['%s version %s\n  (%s)' %(x[0].uri, x[1].get_version(), x[1].id) for x in uncached]))
			return

		sels = self.driver.solver.selections
		doc = sels.toDOM()

		self.hide()
		try:
			gtk.gdk.flush()
			iter = buffer.get_end_iter()
			buffer.place_cursor(iter)
			
			# Tell 0launch to run the program
			doc.documentElement.setAttribute('run-test', 'true')
			payload = doc.toxml('utf-8')
			sys.stdout.write(('Length:%8x\n' % len(payload)) + payload)
			sys.stdout.flush()

			reply = support.read_bytes(0, len('Length:') + 9)
			assert reply.startswith('Length:')
			test_output = support.read_bytes(0, int(reply.split(':', 1)[1], 16))

			# Cope with invalid UTF-8
			import codecs
			decoder = codecs.getdecoder('utf-8')
			data = decoder(test_output, 'replace')[0]

			buffer.insert_at_cursor(data)
		finally:
			self.show()
	
	def report_bug(self, title, text):
		try:
			import urllib
			from urllib2 import urlopen

			stream = urlopen('http://sourceforge.net/tracker/index.php',
				urllib.urlencode({
				'group_id': str(self.sf_group_id),
				'atid': str(self.sf_artifact_id),
				'func': 'postadd',
				'is_private': '0',
				'summary': title,
				'details': text}))
			stream.read()
			stream.close()
		except:
			# Write to stderr in the hope that it doesn't get lost
			print("Error sending bug report: %s\n\n%s" % (title, text), file=sys.stderr)
			raise
