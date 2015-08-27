SerialPort = require('serialport').SerialPort
R = require('ramda')
zerofill = require('zerofill')
net = require('net')
Bacon = require('baconjs')
async = require('async')
carrier = require('carrier')
cc = require('./colourConversion')
_ = require('lodash')
bridgeDmxAcSocket = new net.Socket()
bridgeDmxWinchSocket = new net.Socket()
houmioBridge = process.env.HOUMIO_BRIDGE || "localhost:3001"

dmxUniverseLength = 30

dmxDataStream = new Bacon.Bus()


doWriteToDmx = (writeMessageArray) ->
  console.log "KULLIII", writeMessageArray



toHex = (val) ->
	R.concat '0x', zerofill parseInt(val).toString(16), 2

serialPort = new SerialPort "/dev/cu.usbmodem1411", {
  'baudrate': 115200,
  'databits': 8,
  'stopbits': 1,
  'parity'  : 'none',
}




serialPort.on 'open', ()->
	console.log "OPEN", toHex 12
	serialPort.on 'data', (data)->
		console.log "Data", data


dataLenToTwoByte = (len)-> [(len&0xFF), (len&0xFF00)>>8]

doWriteToDmx = (dmxUniverse) ->
  dmxPkt = R.concat([0x7e, 0x06], dataLenToTwoByte dmxUniverseLength).concat(dmxUniverse).concat([0xe7])
  serialPort.write dmxPkt, (err, res) ->

parseLightParams = (light) ->
  if light.data.type is 'color'
    return _.map cc.hsvToRgbw(light.data.hue, light.data.saturation, light.data.bri), (val, index) ->
      {'addr': parseInt(light.data.protocolAddress)+index, 'val': val}
  else
    return [{'addr': parseInt(light.data.protocolAddress), 'val': light.data.bri}]


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

openStreams = [openBridgeWriteMessageStream(bridgeDmxAcSocket, "DMX"),
              openBridgeWriteMessageStream(bridgeDmxWinchSocket, "WINCH")]

calculateWinchPosition = (writeMessage) ->
  top = 255 - writeMessage.data.maxPos
  bottom = writeMessage.data.minPos
  length = top - bottom
  Math.floor(length/255*(255-writeMessage.data.bri)) + bottom

winchParamsToDmxVals = (winch) ->
  positionAddress = parseInt(winch.data.protocolAddress)
  _.map [winch.data.position,
    winch.data.finePosition,
    winch.data.speed,
    winch.data.maxPos,
    winch.data.minPos,
    winch.data.findUp,
    winch.data.findDown], (val, i) ->
      {'addr': positionAddress + i, 'val': val}

parseWinchParams = (winch) ->
  winch.data.universeAddress = winch.data.protocolAddress.split('/')[0]
  winch.data.speed = parseInt winch.data.protocolAddress.split('/')[2]
  winch.data.maxPos = parseInt winch.data.protocolAddress.split('/')[3]
  winch.data.minPos = parseInt winch.data.protocolAddress.split('/')[4]
  winch.data.position = calculateWinchPosition winch
  winch.data.protocolAddress = winch.data.protocolAddress.split('/')[1]
  winch.data.findDown = 0
  winch.data.finePosition = 0
  winch.data.findUp = 0
  if winch.data.type is 'binary'
    winch.data.position = 0
    winch.data.speed = 30
    winch.data.maxPos = 0
    winch.data.minPos = 0
    if winch.data.on then winch.data.findUp = 100 else winch.data.findUp = 0
  winchParamsToDmxVals winch


createLightArrayFromState = (driverState) ->
  f = (device) ->
    switch device.protocol
      when 'enttecdmx/winch' then return parseWinchParams(device)
      else return parseLightParams(device)
  R.flatten R.map(f, driverState)

async.series openStreams, (err, [acWriteMessages, winchWriteMessages]) ->
  if err then exit err

  Bacon.update(
    [],
    acWriteMessages, (driverState, x) ->
      idEquals = R.pathEq ['data', '_id']
      index = R.findIndex idEquals(x.data._id), driverState
      if index is -1
        R.append x, driverState
      else
        lens = R.lensIndex index
        R.set lens, x, driverState
    ,
    winchWriteMessages, (driverState, x) ->
      idEquals = R.pathEq ['data', '_id']
      index = R.findIndex idEquals(x.data._id), driverState
      if index is -1
        R.append x, driverState
      else
        lens = R.lensIndex index
        R.set lens, x, driverState
  ).map (driverState) ->
    universe = R.repeat 0x00, dmxUniverseLength
    deviceStateRegisterArray = createLightArrayFromState driverState
    f = (x) ->universe[x.addr] = x.val
    R.forEach f, deviceStateRegisterArray
    universe
  .onValue (dmxUniverse) -> doWriteToDmx dmxUniverse

  winchWriteMessages
    .flatMap (m) ->

  bridgeDmxWinchSocket.write (JSON.stringify { command: "driverReady", protocol: "enttecdmx/winch"}) + "\n"
  bridgeDmxAcSocket.write (JSON.stringify { command: "driverReady", protocol: "enttecdmx/ac"}) + "\n"


