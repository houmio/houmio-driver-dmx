SerialPort = require('serialport').SerialPort
R = require('ramda')
zerofill = require('zerofill')





toHex = (val) ->
	R.concat '0x', zerofill parseInt(val).toString(16), 2

serialPort = new SerialPort "/dev/cu.usbmodem1451", {
  'baudrate': 115200,
  'databits': 8,
  'stopbits': 1,
  'parity'  : 'none',
}
tempVal =0
serialPort.on 'open', ()->
	console.log "OPEN", toHex 12
	setInterval writeToDmx, 1000

	serialPort.on 'data', (data)->
		console.log "Data", data


writeToDmx = () ->
	dmxUniverse = R.map () ->
		return 0x00

	, R.range(0, 32)
	#dmxUniverse[0] =
	#dmxUniverse[1] = 0
	dmxUniverse[1] = 215
	dmxUniverse[2] = 128

	dmxUniverse = R.concat([0x7e, 0x06, 32, 0x00], dmxUniverse).concat [0xe7]

	#tempValHi = (tempVal&0xff00)>>8
	#tempValLo = (tempVal&0xff)

	#dmxUniverse = [0x01, 0x18, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3B, 0x10, 0x10, 0x9C, 0x8E, 0xFE, 0x05, 0x01, 0x00, 0x00, 0x00, 0x10, 0x00, 0x03, 0x00, 0x09, 0x7B]
		#dmxUniverse[3]=0
	console.log "dmxUniverse", R.map toHex, dmxUniverse
	serialPort.write dmxUniverse, (err, res)->
		console.log("KULLI", res, tempVal++)
###