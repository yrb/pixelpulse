# Real-time canvas plotting library
# Distributed under the terms of the BSD License
# (C) 2011 Kevin Mehall (Nonolith Labs) <km@kevinmehall.net>

livegraph = if exports? then exports else (this.livegraph = {})

PADDING = 10
AXIS_SPACING = 25
			
class livegraph.Axis
	constructor: (@min, @max) ->
		if @max == 'auto'
			@autoScroll = min
			@max = 0
		else
			@autoscroll = false
			
		@visibleMin = @min
		@visibleMax = @max
	
	span: -> @visibleMax - @visibleMin
		
	gridstep: ->
		grid=Math.pow(10, Math.round(Math.log(@max-@min)/Math.LN10)-1)
		if (@max-@min)/grid >= 10
			grid *= 2
		return grid
		
	grid: ->
		[min, max] = if @autoScroll then [@autoScroll, 0] else [@min, @max]
		livegraph.arange(min, max, @gridstep())
		
	xtransform: (x, geom) ->
		(x - @visibleMin) * geom.width / @span() + geom.xleft
		
	ytransform: (y, geom) ->
		geom.ybottom - (y - @visibleMin) * geom.height / @span()
		
	invYtransform: (ypx, geom) ->
		(geom.ybottom - ypx)/geom.height * @span() + @visibleMin
		
class DigitalAxis
	min = 0
	max = 1
	
	gridstep: -> 1
	grid: -> [0, 1]
	
	xtransform: (x, geom) -> if x then geom.xleft else geom.xright
	ytransform: (y, geom) -> if y then geom.ytop else geom.ybottom
	invYtransform: (ypx, geom) -> (geom.ybottom - ypx) > geom.height/2
		
livegraph.digitalAxis = new DigitalAxis()

class livegraph.Series
	constructor: (@xdata, @ydata, @color, @style) ->


window.requestAnimFrame = 
	window.requestAnimationFrame ||
	window.webkitRequestAnimationFrame ||
	window.mozRequestAnimationFrame ||
	window.oRequestAnimationFrame ||
	window.msRequestAnimationFrame ||
	(callback, element) -> window.setTimeout(callback, 1000/60)

class LiveGraph
	constructor: (@div, @xaxis, @yaxis, @series) ->		
		@div.setAttribute('class', 'livegraph')
		
#	autoscroll: ->
#		if @xaxis.autoScroll
#			@xaxis.max = @data[@data.length-1][@series[0].xvar]
#			@xaxis.min = @xaxis.max + @xaxis.autoScroll
	
	perfStat_enable: (div)->
		@psDiv = div
		@psCount = 0
		@psSum = 0
		@psRunningSum = 0
		@psRunningCount = 0

		setInterval((=> 
			@psRunningSum += @psSum
			@psRunningCount += @psCount
			@psDiv.innerHTML = "#{@renderer}: #{@psCount}fps; #{@psSum}ms draw time; Avg: #{@psRunningSum/@psRunningCount}"
			@psCount = 0
			@psSum = 0
		), 1000)

	perfStat: (time) ->
		@psCount += 1
		@psSum += time

# Creates a matrix A  =  sx  0   dx
#                        0   sy  dy
#						 0   0   1
# based off of the geometry (view) and axis settings such that
# A * vector(x, y, 1) in unit space = the point in pixel space
# or, alternatively, x'=x*sx+dx; y'=y*sy+dy
makeTransform = livegraph.makeTransform = (geom, xaxis, yaxis, w, h) ->
	sx = geom.width / xaxis.span()
	sy = -geom.height / yaxis.span()
	dx = geom.xleft - xaxis.visibleMin*sx
	dy = geom.ybottom - yaxis.visibleMin*sy
	return [sx, sy, dx, dy]

# Apply a transformation generated by makeTransform to a point
transform = livegraph.transform = (x, y, [sx, sy, dx, dy]) -> 
	return [dx + x*sx, dy+y*sy]

# Use a transformation from makeTransform to go from pixel to unit space
invTransform = livegraph.invTransform = (x, y, [sx, sy, dx, dy]) ->
	return [(x-dx)/sx, (y-dy)/sy]
	
relMousePos = (elem, event) ->
	o = $(elem).offset()
	return [event.pageX-o.left, event.pageY-o.top]
		
class livegraph.canvas extends LiveGraph
	constructor: (div, xaxis, yaxis, series) ->
		super(div, xaxis, yaxis, series)
		
		@axisCanvas = document.createElement('canvas')
		@graphCanvas = document.createElement('canvas')
		@div.appendChild(@axisCanvas)
		@div.appendChild(@graphCanvas)
		
		$(@div).mousedown(@mousedown)
		
		@showXbottom = false
		@showYleft = true
		@showYright = true
		@showYgrid = true
		
		@ctxa = @axisCanvas.getContext('2d')
		
		if not @init_webgl() then @init_canvas2d()
		
		@resized()
		
	init_canvas2d: ->
		@ctxg = @graphCanvas.getContext('2d')
		@redrawGraph = @redrawGraph_canvas2d
		@renderer = 'canvas2d'
		return true
		
	init_webgl: ->
	
		shader_vs = """
			attribute float x;
			attribute float y;

			uniform mat4 transform;

			void main(void) {
				gl_Position = transform * vec4(x, y, 1.0, 1.0);
				gl_Position.z = -1.0;
				gl_Position.w = 1.0;
			}
		"""
		
		shader_fs = """
			#ifdef GL_ES
			precision highp float;
			#endif

			void main(void) {
				gl_FragColor = vec4(0.0, 0.0, 1.0, 1.0);
			}
		"""
		
		@gl = gl = @graphCanvas.getContext("experimental-webgl")
		if not @gl then return false
		
		compile_shader = (type, source) ->
			s = gl.createShader(type)
			gl.shaderSource(s, source)
			gl.compileShader(s)
			if !gl.getShaderParameter(s, gl.COMPILE_STATUS)
				console.error(gl.getShaderInfoLog(s))
				return null
			return s
			
		fs = compile_shader(gl.FRAGMENT_SHADER, shader_fs)
		vs = compile_shader(gl.VERTEX_SHADER, shader_vs)
		
		if not fs and vs then return false
		
		gl.shaderProgram = gl.createProgram()
		gl.attachShader(gl.shaderProgram, fs)
		gl.attachShader(gl.shaderProgram, vs)
		gl.linkProgram(gl.shaderProgram)
		
		if (!gl.getProgramParameter(gl.shaderProgram, gl.LINK_STATUS))
			console.error "Could not initialize shaders"
			return false
			
		gl.useProgram(gl.shaderProgram)
		gl.shaderProgram.attrib =
			x: gl.getAttribLocation(gl.shaderProgram, "x")
			y: gl.getAttribLocation(gl.shaderProgram, "y")
		gl.shaderProgram.uniform =
			transform: gl.getUniformLocation(gl.shaderProgram, "transform")
			
		gl.enableVertexAttribArray(gl.shaderProgram.attrib.x)
		gl.enableVertexAttribArray(gl.shaderProgram.attrib.y)
		
		gl.enable(gl.GL_LINE_SMOOTH)
		gl.hint(gl.GL_LINE_SMOOTH_HINT, gl.GL_NICEST)
		gl.enable(gl.GL_BLEND)
		gl.blendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA)
			
		gl.xBuffer = gl.createBuffer()
		gl.yBuffer = gl.createBuffer()

		@renderer = 'webgl'
		@redrawGraph = @redrawGraph_webgl
		return true
		
	mousedown: (e) =>
		pos = origPos = relMousePos(@div, e)
		if @dragAction then @dragAction.cancel()
		@dragAction = @onClick(pos)
		
		mousemove = (e) =>
			pos = relMousePos(@div, e)
			if @dragAction then @dragAction.onDrag(pos, origPos)
			return
			
		mouseup = =>
			if @dragAction then @dragAction.onRelease(pos, origPos)
			$(window).unbind('mousemove', mousemove)
			         .unbind('mouseup', mouseup)
                     .css('cursor', 'auto')
			return
				
		$(window).mousemove(mousemove)
		         .mouseup(mouseup)
		
	onClick: (pos) ->
		return new livegraph.DragScrollAction(this, pos)
	
	resized: () ->
		if @div.offsetWidth == 0 or @div.offsetHeight == 0 then return
			
		@width = @div.offsetWidth
		@height = @div.offsetHeight
		@axisCanvas.width = @width
		@axisCanvas.height = @height
		@graphCanvas.width = @width
		@graphCanvas.height = @height
		
		@geom = 
			ytop: PADDING
			ybottom: @height - (PADDING + @showXbottom * AXIS_SPACING)
			xleft: PADDING + @showYleft * AXIS_SPACING
			xright: @width - (PADDING + @showYright * AXIS_SPACING)
			width: @width - 2*PADDING - (@showYleft+@showYright) * AXIS_SPACING
			height: @height - 2*PADDING - @showXbottom  * AXIS_SPACING

		if @onResized
			@onResized()
		
		@needsRedraw(true)
		
	addDot: (x, fill, stroke) ->
		dot = livegraph.makeDotCanvas(5, 'white', 'blue')
		dot.position = (y) =>
			[sx, sy, dx, dy] = makeTransform(@geom, @xaxis, @yaxis)
			
			dot.style.visibility = if !isNaN(y) and y? then 'visible' else 'hidden'
			
			if y > @yaxis.visibleMax
				y = @yaxis.visibleMax
				shape = 'up'
			else if y < @yaxis.visibleMin
				y = @yaxis.visibleMin
				shape = 'down'
			else
				shape = 'circle'
				
			if dot.shape != shape
				dot.shape = shape
				dot.render()
			
			y = Math.round(dy+y*sy)
			if dot.lastY != y
				dot.positionRight(PADDING+AXIS_SPACING, y)
				dot.lastY = y
			
		$(dot).appendTo(@div)
		return dot
			
	redrawAxis: ->
		@ctxa.clearRect(0,0,@width, @height)
		
		if @showXbottom then @drawXAxis(@geom.ybottom)	
		if @showYgrid   then @drawYgrid()	
		if @showYleft   then @drawYAxis(@geom.xleft,  'right', -5)
		if @showYright  then @drawYAxis(@geom.xright, 'left',   8)
		
	drawXAxis: (y) ->
		xgrid = @xaxis.grid()
		@ctxa.strokeStyle = 'black'
		@ctxa.lineWidth = 2
		@ctxa.beginPath()
		@ctxa.moveTo(@geom.xleft, y)
		@ctxa.lineTo(@geom.xright, y)
		@ctxa.stroke()
		
		textoffset = 5
		@ctxa.textAlign = 'center'
		@ctxa.textBaseline = 'top'
		
		if @xaxis.autoScroll
			[min, max] = [@xaxis.autoScroll, 0]
			offset = @xaxis.max
		else
			[min, max] = [@xaxis.min, @xaxis.max]
			offset = 0
		
		for x in xgrid
			@ctxa.beginPath()
			xp = @xaxis.xtransform(x+offset, @geom)
			@ctxa.moveTo(xp,y-4)
			@ctxa.lineTo(xp,y+4)
			@ctxa.stroke()
			@ctxa.fillText(Math.round(x*10)/10, xp ,y+textoffset)
		
	drawYAxis: (x, align, textoffset) =>
		grid = @yaxis.grid()
		@ctxa.strokeStyle = 'black'
		@ctxa.lineWidth = 1
		@ctxa.textAlign = align
		@ctxa.textBaseline = 'middle'
		
		@ctxa.beginPath()
		@ctxa.moveTo(x, @geom.ytop)
		@ctxa.lineTo(x, @geom.ybottom)
		@ctxa.stroke()
		
		for y in grid
			yp = Math.round(@yaxis.ytransform(y, @geom)) + 0.5
			
			#draw side axis ticks and labels
			@ctxa.beginPath()
			@ctxa.moveTo(x-4, yp)
			@ctxa.lineTo(x+4, yp)
			@ctxa.stroke()
			@ctxa.fillText(Math.round(y*10)/10, x+textoffset, yp)
			
	drawYgrid: ->
		grid = @yaxis.grid()
		@ctxa.strokeStyle = 'rgba(0,0,0,0.08)'
		@ctxa.lineWidth = 1
		for y in grid
			yp = Math.round(@yaxis.ytransform(y, @geom)) + 0.5
			@ctxa.beginPath()
			@ctxa.moveTo(@geom.xleft, yp)
			@ctxa.lineTo(@geom.xright, yp)
			@ctxa.stroke()
		
	needsRedraw: (fullRedraw=false) ->
		@axisRedrawRequested ||= fullRedraw
		if not @redrawRequested
			@redrawRequested = true
			requestAnimFrame(@redraw, @graphCanvas)

	redraw: =>
		startTime = new Date()
		keepAnimating = false
		
		if @height != @div.offsetHeight or @width != @div.offsetWidth
			@resized()
		
		if @dragAction
			keepAnimating ||= @dragAction.onAnim()
			
		if @axisRedrawRequested
			@redrawAxis()
			@axisRedrawRequested = false
			
		@redrawGraph()
		@redrawRequested = false
		
		if keepAnimating then @needsRedraw()
		@perfStat(new Date()-startTime)
		return
		
			
	redrawGraph_canvas2d: ->
		@ctxg.clearRect(0,0,@width, @height)
		@ctxg.lineWidth = 2
		
		[sx, sy, dx, dy] = makeTransform(@geom, @xaxis, @yaxis)
		
		for series in @series
			@ctxg.strokeStyle = series.color	
			 
			@ctxg.save()
			
			@ctxg.beginPath()
			@ctxg.rect(@geom.xleft, @geom.ytop, @geom.xright-@geom.xleft, @geom.ybottom-@geom.ytop)
			@ctxg.clip()
			
			@ctxg.beginPath()
			datalen = Math.min(series.xdata.length, series.ydata.length)
			
			cull = true
			
			for i in [0...datalen]
				if cull and series.xdata[i+1] < @xaxis.visibleMin
					continue
				
				x = series.xdata[i]
				y = series.ydata[i]
					
				@ctxg.lineTo(x*sx + dx, y*sy+dy)
				
				if cull and x > @xaxis.visibleMax
					break
					
			@ctxg.stroke()
			@ctxg.restore()
			
			if series.grabDot
				@ctxg.beginPath()
				
				xp = x*sx + dx
				yp = y*sy + dy
				
				if y<=@yaxis.min
					@ctxg.moveTo(xp-5,yp)
					@ctxg.lineTo(xp,yp+10)
					@ctxg.lineTo(xp+5,yp)
					@ctxg.lineTo(xp-5,yp)
				else if y>=@yaxis.max
					@ctxg.moveTo(xp-5,yp)
					@ctxg.lineTo(xp,yp-10)
					@ctxg.lineTo(xp+5,yp)
					@ctxg.lineTo(xp-5,yp)
				else
					@ctxg.arc(x, y, 5, 0, Math.PI*2, true);
				if series.grabDot == 'fill'
					@ctxg.fillStyle = series.color
				else
					@ctxg.fillStyle = 'white'
				@ctxg.fill()
				@ctxg.stroke()
				
		return
		
	redrawGraph_webgl: ->
		gl = @gl
		
		gl.clearColor(0.0, 0.0, 0.0, 0.0)
		gl.enable(gl.SCISSOR_TEST)
		gl.viewport(0, 0, @width, @height)
		gl.scissor(@geom.xleft, @height-@geom.ybottom, @geom.width, @geom.height)
		gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
		gl.lineWidth(2)
		
		[sx, sy, dx, dy] = makeTransform(@geom, @xaxis, @yaxis)
		w = 2.0/@width
		h = -2.0/@height

		# column-major order!
		tmatrix = [sx*w, 0, 0, 0,   0, sy*h, 0, 0,   dx*w, dy*h, 0, 0,   -1, 1, -1, 1]
		
		gl.uniformMatrix4fv(gl.shaderProgram.uniform.transform, false, new Float32Array(tmatrix))
		
		for series in @series
			gl.bindBuffer(gl.ARRAY_BUFFER, gl.xBuffer)
			gl.bufferData(gl.ARRAY_BUFFER, series.xdata, gl.STREAM_DRAW)
			gl.vertexAttribPointer(gl.shaderProgram.attrib.x, 1, gl.FLOAT, false, 0, 0)
			gl.bindBuffer(gl.ARRAY_BUFFER, gl.yBuffer)
			gl.bufferData(gl.ARRAY_BUFFER, series.ydata, gl.STREAM_DRAW)
			gl.vertexAttribPointer(gl.shaderProgram.attrib.y, 1, gl.FLOAT, false, 0, 0)
			gl.drawArrays(gl.LINE_STRIP, 0, series.xdata.length)
		
		
class livegraph.DragScrollAction
	constructor: (@lg, @origPos) ->
		@origMin = @lg.xaxis.visibleMin
		@origMax = @lg.xaxis.visibleMax
		@scale = makeTransform(@lg.geom, @lg.xaxis, @lg.yaxis)[0]
		@velocity = 0
		@pressed = true
		
		@x = @lastX = @origPos[0]
		@t = +new Date()
	
	onDrag: ([x, y]) ->
		time = +new Date()
		@scrollTo(x)
		@x = x
		
	scrollTo: (x) ->
		scrollby = (x-@origPos[0])/@scale
		@lg.xaxis.visibleMin = @origMin - scrollby
		@lg.xaxis.visibleMax = @origMax - scrollby
		@lg.needsRedraw(true)
		
	onRelease: ->
		@pressed = false
		@lg.needsRedraw()
		@t = +new Date()-1
		
	onAnim: ->
		if @stop then return
		
		t = +new Date()
		dt = Math.min(t - @t, 100)
		@t = t
		
		if dt == 0 then return
		
		minOvershoot = Math.max(@lg.xaxis.min - @lg.xaxis.visibleMin, 0)
		maxOvershoot = Math.max(@lg.xaxis.visibleMax - @lg.xaxis.max, 0)
		
		if @pressed
			dx = @x - @lastX
			@lastX = @x
			
			@velocity = dx/dt
			overshoot = Math.max(minOvershoot, maxOvershoot)
			if overshoot > 0
				@velocity *= (1-overshoot)/200
		else
			if minOvershoot > 0.0001
				if @velocity <= 0
					@velocity = -1*minOvershoot
				else
					@velocity -= 0.1*dt
			else if maxOvershoot > 0.0001
				if @velocity >= 0
					@velocity = 1*maxOvershoot
				else
					@velocity += 0.1*dt
			else
				vstep = (if @velocity > 0 then 1 else -1) * 0.05
				@velocity -= vstep
				
				if (Math.abs(@velocity)) < Math.abs(vstep)
					@stop = true
					return false
			
			@x = @x + @velocity*dt
			@scrollTo(@x)
			
			return true # keep animating
		
	cancel: ->
		@stop = true
		
livegraph.makeDotCanvas = (radius = 5, fill='white', stroke='blue') ->
	c = document.createElement('canvas')
	c.width = 2*radius + 4
	c.height = 2*radius + 4
	center = radius+2
	c.fill = fill
	c.stroke = stroke
	
	$(c).css
		position: 'absolute'
		'margin-top':-center
		'margin-right':-center
	ctx = c.getContext('2d')

	c.positionLeft = (x, y)->
		c.style.top = "#{y}px"
		c.style.left = "#{x}px"
		c.style.right = "auto"
	c.positionRight = (x, y)->
		c.style.top = "#{y}px"
		c.style.right = "#{x}px"
		c.style.left = "auto"
	
	c.render = ->
		c.width = c.width
		ctx.fillStyle = c.fill
		ctx.strokeStyle = c.stroke
		ctx.lineWidth = 2
		
		switch c.shape
			when 'circle'
				ctx.arc(center, center, radius, 0, Math.PI*2, true);
			when 'down'
				ctx.moveTo(center,             center+radius)
				ctx.lineTo(center+radius*0.86, center-radius*0.5)
				ctx.lineTo(center-radius*0.86, center-radius*0.5)
				ctx.lineTo(center,             center+radius)
			when 'up'
				ctx.moveTo(center,             center-radius)
				ctx.lineTo(center+radius*0.86, center+radius*0.5)
				ctx.lineTo(center-radius*0.86, center+radius*0.5)
				ctx.lineTo(center,             center-radius)
				
		ctx.fill()
		ctx.stroke()
		
	c.render()

	return c
	
	
			
livegraph.arange = (lo, hi, step) ->
	ret = new Float32Array((hi-lo)/step+1)
	for i in [0...ret.length]
		ret[i] = lo + i*step
	return ret
		
livegraph.demo = ->
	xaxis = new livegraph.Axis(-20, 20)
	xaxis.visibleMin = -5
	xaxis.visibleMax = 5
	yaxis = new livegraph.Axis(-1, 3)

	xdata = livegraph.arange(-20, 20, 0.005)
	ydata = new Float32Array(xdata.length)

	updateData = ->
		n = (Math.sin(+new Date()/1000)+2)*0.5

		for i in [0...ydata.length]
			x = xdata[i]
			if x != 0
				ydata[i] = Math.sin(x*Math.PI/n)/x
			else
				ydata[i] = Math.PI/n

	updateData()

	series = new livegraph.Series(xdata, ydata, 'blue')
	lg = new livegraph.canvas(document.getElementById('demoDiv'), xaxis, yaxis, [series])
	lg.needsRedraw()
	
	lg.start = ->
		@iv = setInterval((->
			updateData()
			lg.needsRedraw()
		), 10)
		
	lg.pause = -> 
		clearInterval(@iv)
		

	lg.perfStat_enable(document.getElementById('statDiv'))
	
	lg.start()

	window.lg = lg


