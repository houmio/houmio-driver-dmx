SerialPort = require('serialport').SerialPort
R = require('ramda')
zerofill = require('zerofill')
net = require('net')
Bacon = require('baconjs')
async = require('async')
carrier = require('carrier')

bridgeDmxSocket = new net.Socket()
houmioBridge = process.env.HOUMIO_BRIDGE || "localhost:3001"

dmxUniverseLength = 30

dmxUniverse = R.map () ->
		return 0x00
, R.range(0, dmxUniverseLength)



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
	serialPort.on 'data', (data)->
		console.log "Data", data

dataLenToTwoByte = (len)-> [(len&0xFF), (tempVal&0xFF00)>>8]

doWriteToDmx = (message) ->
  dmxUniverse[parseInt(message.data.protocolAddress)] = message.data.bri

  dmxPkt = R.concat([0x7e, 0x06], dataLenToTwoByte dmxUniverseLength).concat(dmxUniverse).concat([0xe7])
  console.log "Write to DMX", dmxPkt
  serialPort.write dmxPkt, (err, res) ->

isWriteMessage = (message) -> message.command is "write"

toLines = (socket) ->
  Bacon.fromBinder (sink) ->
    carrier.carry socket, sink
    socket.on "close", -> sink new Bacon.End()
    socket.on "error", (err) -> sink new Bacon.Error(err)
    ( -> )

openBridgeWriteMessageStream = (socket, protocolName) -> (cb) ->
  socket.connect houmioBridge.split(":")[1], houmioBridge.split(":")[0], ->
    lineStream = toLines socket
    messageStream = lineStream.map JSON.parse
    messageStream.onEnd -> exit "Bridge stream ended, protocol: #{protocolName}"
    messageStream.onError (err) -> exit "Error from bridge stream, protocol: #{protocolName}, error: #{err}"
    writeMessageStream = messageStream.filter isWriteMessage
    cb null, writeMessageStream

openStreams = [openBridgeWriteMessageStream(bridgeDmxSocket, "DMX")]

async.series openStreams, (err, [dmxWriteMessages]) ->
  if err then exit err

  dmxWriteMessages
    .onValue doWriteToDmx


  bridgeDmxSocket.write (JSON.stringify { command: "driverReady", protocol: "enttecdmx"}) + "\n"


