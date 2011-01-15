# Copyright (C) 2009, Thomas Leonard
# See the README file for details, or visit http://0install.net.

class Freshness(object):
	__slots__ = ['time', 'text']

	def __init__(self, time, text):
		self.time = time
		self.text = text
	
	def __str__(self):
		return self.text

freshness_levels = [
	Freshness(0, _('No automatic updates')),
	#Freshness(60, _('Up to one minute old')),
	#Freshness(60 * 60, _('Up to one hour old')),
	Freshness(24 * 60 * 60, _('Up to one day old')),
	Freshness(7 * 24 * 60 * 60, _('Up to one week old')),
	Freshness(30 * 24 * 60 * 60, _('Up to one month old')),
	Freshness(365 * 24 * 60 * 60, _('Up to one year old')),
	]
