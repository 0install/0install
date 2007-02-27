# Copyright (C) 2007, Thomas Leonard
# See http://0install.net/0compile.html

import sys, os
import zeroinstall
import gtk, pango
import dialog

def report_bug(policy, iface):
	assert iface

	# TODO: Check the interface to decide where to send bug reports

	issue_file = '/etc/issue'
	if os.path.exists(issue_file):
		issue = file(issue_file).read().strip()
	else:
		issue = "(file '%s' not found)" % issue

	text = 'Problem with %s\n' % iface.uri
	if iface.uri != policy.root:
		text = '  (while attempting to run %s)\n' % policy.root
	text += '\n'

	text += 'Zero Install: Version %s, with Python %s\n' % (zeroinstall.version, sys.version)

	text += '\nChosen implementations:\n'

	if not policy.ready:
		text += '  Failed to select all required implementations\n'

	for chosen_iface in policy.implementation:
		text += '\n  Interface: %s\n' % chosen_iface.uri
		impl = policy.implementation[chosen_iface]
		if impl:
			text += '    Version: %s\n' % impl.get_version()
			if impl.interface != chosen_iface:
				text += '  From feed: %s\n' % impl.interface.uri
			text += '         ID: %s\n' % impl.id
		else:
			text += '    No implementation selected\n'

	text += '\nSystem:\n  %s\n\nIssue:\n  %s\n' % ('\n  '.join(os.uname()), issue)

	reporter = BugReporter(policy, iface, text)
	reporter.show()

class BugReporter(dialog.Dialog):
	def __init__(self, policy, iface, env):
		dialog.Dialog.__init__(self)
		self.set_title('Report a Bug')
		self.set_modal(True)
		self.set_has_separator(False)
		self.policy = policy
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
		frame("What doesn't work?", *actual)

		expected = text_area()
		frame('What did you expect to happen?', *expected)

		errors_box = gtk.VBox(False, 0)
		errors_swin, errors_buffer = text_area(mono = True)
		errors_box.pack_start(errors_swin, True, True, 0)
		buttons = gtk.HButtonBox()
		buttons.set_layout(gtk.BUTTONBOX_START)
		errors_box.pack_start(buttons, False, True, 4)
		get_errors = gtk.Button('Run it now and record the output')
		get_errors.connect('clicked', lambda button: self.collect_output(errors_buffer))
		buttons.add(get_errors)

		frame('Are any errors or warnings displayed?', errors_box, errors_buffer)

		environ = text_area(env, mono = True)
		frame('Information about your setup', *environ)

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
				title = 'Bug for %s' % iface.get_name()
				self.report_bug(title, text)
				self.destroy()
				dialog.alert(self, "Your bug report has been sent. Thank you.",
					     type = gtk.MESSAGE_INFO)
			else:
				self.destroy()
		self.connect('response', resp)

		self.show_all()

	def collect_output(self, buffer):
		import logging
		from zeroinstall.injector import run

		r, w = os.pipe()
		child = os.fork()
		if child == 0:
			# We are the child
			try:
				try:
					os.close(r)
					os.dup2(w, 1)
					os.dup2(w, 2)

					logger = logging.getLogger()
					logger.setLevel(logging.DEBUG)
					run.execute(self.policy, self.policy.prog_args)
				except:
					import traceback
					traceback.print_exc()
			finally:
				os._exit(1)
		else:
			os.close(w)
			reader = os.fdopen(r, 'r')

			self.hide()
			try:
				gtk.gdk.flush()
				iter = buffer.get_end_iter()
				buffer.place_cursor(iter)

				# Cope with invalid UTF-8
				import codecs
				decoder = codecs.getdecoder('utf-8')
				data = decoder(reader.read(), 'replace')[0]

				buffer.insert_at_cursor(data)
				reader.close()

				pid, status = os.waitpid(child, 0)
				assert pid == child
			finally:
				self.show()
	
	def report_bug(self, title, text):
		print >>sys.stderr, "Sending %s\n\n%s" % (title, text)

		import urllib
		from urllib2 import urlopen

		stream = urlopen('http://sourceforge.net/tracker/index.php',
			urllib.urlencode({
			'group_id': '76468',
			'atid': '929902',
			'func': 'postadd',
			'is_private': '0',
			'summary': title,
			'details': text}))
		stream.read()
		stream.close()
