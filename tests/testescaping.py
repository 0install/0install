#!/usr/bin/env python
# -*- coding: utf-8 -*-
from __future__ import unicode_literals
import basetest
from basetest import BaseTest
import sys, os, re
import unittest

sys.path.insert(0, '..')
from zeroinstall.injector import model
from zeroinstall.support import escaping

safe = re.compile('^[-.a-zA-Z0-9_]*$')

class TestEscaping(BaseTest):
	def testEscape(self):
		self.assertEqual("", model.escape(""))
		self.assertEqual("hello", model.escape("hello"))
		self.assertEqual("%20", model.escape(" "))

		self.assertEqual("file%3a%2f%2ffoo%7ebar",
				model.escape("file://foo~bar"))
		self.assertEqual("file%3a%2f%2ffoo%25bar",
				model.escape("file://foo%bar"))

		self.assertEqual("file:##foo%7ebar",
				model._pretty_escape("file://foo~bar"))
		self.assertEqual("file:##foo%25bar",
				model._pretty_escape("file://foo%bar"))

	def testUnescape(self):
		self.assertEqual("", model.unescape(""))
		self.assertEqual("hello", model.unescape("hello"))
		self.assertEqual(" ", model.unescape("%20"))

		self.assertEqual("file://foo~bar",
				model.unescape("file%3a%2f%2ffoo%7ebar"))
		self.assertEqual("file://foo%bar",
				model.unescape("file%3a%2f%2ffoo%25bar"))

		self.assertEqual("file://foo",
				model.unescape("file:##foo"))
		self.assertEqual("file://foo~bar",
				model.unescape("file:##foo%7ebar"))
		self.assertEqual("file://foo%bar",
				model.unescape("file:##foo%25bar"))
	
	def testEscaping(self):
		def check(str):
			self.assertEqual(str, model.unescape(model.escape(str)))
			self.assertEqual(str, model.unescape(model._pretty_escape(str)))
			self.assertEqual(str,
				escaping.ununderscore_escape(escaping.underscore_escape(str)))

		check('')
		check('http://example.com')
		check('http://example%46com')
		check('http:##example#com')
		check('http://example.com/foo/bar.xml')
		check('%20%21~&!"£ :@;,./{}$%^&()')
		check('http://example.com/foo_bar-50%á.xml')
		check('_one__two___three____four_____')
		check('_1_and_2_')
	
	def testUnderEscape(self):
		for x in range(0, 128):
			unescaped = chr(x)
			escaped = escaping.underscore_escape(unescaped)
			assert safe.match(escaped), escaped
			self.assertEqual(unescaped, escaping.ununderscore_escape(escaped))


if __name__ == '__main__':
	unittest.main()
