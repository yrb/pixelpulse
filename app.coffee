# Pixelpulse controller
# (C) 2011 Nonolith Labs
# Author: Kevin Mehall <km@kevinmehall.net>
# Distributed under the terms of the GNU GPLv3

pixelpulse = (window.pixelpulse ?= {})

pixelpulse.overlay = (message) ->
	if not message
		$("#error-overlay").hide()
	else
		$("#error-overlay").fadeIn(300)
		$("#error-status").text(message)

pixelpulse.init = (server, params) ->
	ts = $("#timeseries").get(0)
	meters = $("#meters").get(0)

	if !window.WebSocket
		pixelpulse.overlay "Pixelpulse requires WebSockets and currently only works in Chrome and Safari"
		return

	server.connect()
	
	hasConnected = no
	
	server.connected.listen ->
		document.title = "Pixelpulse (Connected)"
		document.body.className = "connected"
		pixelpulse.overlay()
		hasConnected = yes

	server.disconnected.listen ->
		document.title = "Pixelpulse (Disconnected)"
		document.body.className = "disconnected"
		if not hasConnected
			pixelpulse.overlay "Dataserver not detected"
		else
			pixelpulse.overlay "Connection lost"

	server.devicesChanged.listen (l) ->
		console.info "Device list changed", l
		if not server.device
			# select the "first" device if we don't have a device chosen
			server.selectDevice(l[Object.keys(l)])

	server.deviceSelected.listen (dev) ->
		console.info "Selected device", dev
		dev.changed.listen ->
			console.info "device updated", dev
			for chId, channel of dev.channels
				console.info "Channel", chId
				for stId, stream of channel.streams
					console.info "Stream", stId
					s = new pixelpulse.TileView(stream)
					$('#streams').append(s.showTimeseries())
					
	server.captureStateChanged.listen (s) ->
		if s
			$('#startpause').removeClass('startbtn').addClass('stopbtn').attr('title', 'Pause')
		else
			$('#startpause').removeClass('stopbtn').addClass('startbtn').attr('title', 'Start')
			
	$('#startpause').click ->
		if server.captureState
			server.pauseCapture()
		else
			server.startCapture()
				
			
		
#URL params
params = {}
for pair in document.location.search.slice(1).split('&')
	[key,params[key]] = pair.split('=')

$(document).ready ->	
	if not params.timebar
		$('#timesection').hide()
		
	if not params.layouts
		$('#layout-sel').hide()
		
	if params.perfstat
		$('#perfstat').show()
		
	if params.demohint
		$('#info').show()
	
	pixelpulse.init(server, params)

