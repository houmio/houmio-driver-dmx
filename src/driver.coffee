SerialPort = require('serialport').SerialPort
R = require('ramda')
zerofill = require('zerofill')
net = require('net')
Bacon = require('baconjs')
async = require('async')
carrier = require('carrier')
cc = require('./colourConversion')
_ = require('lodash')
fs = require('fs')

bridgeDmxAcSocket = new net.Socket()
bridgeDmxWinchSocket = new net.Socket()
houmioBridge = process.env.HOUMIO_BRIDGE || "localhost:3001"
houmioDmxSerialStart = process.env.DMX_SERIAL_START || "ttyUSB"

dmxUniverseLength = 30

dmxDataStream = new Bacon.Bus()

exit = (msg) ->
  console.log msg
  process.exit 1

toHex = (val) ->
	R.concat '0x', zerofill parseInt(val).toString(16), 2

findDmxSerialPort = () ->
  deviceFiles = fs.readdirSync('/dev')
  startsWithDmxSerial = (s) -> new RegExp(houmioDmxSerialStart).test(s)
  usbSerials = R.filter(startsWithDmxSerial, deviceFiles)
  prependWithDev = (s) -> '/dev/' + s
  return R.head(R.map(prependWithDev, usbSerials))

dmxPort = findDmxSerialPort()

serialPort = new SerialPort dmxPort, {
  'baudrate': 115200,
  'databits': 8,
  'stopbits': 1,
  'parity'  : 'none',
}

serialPort.on 'open', ()->
	console.log "Serial Port Opened:", dmxPort
	serialPort.on 'data', (data)->
		console.log "Data", data

dataLenToTwoByte = (len)-> [(len&0xFF), (len&0xFF00)>>8]

doWriteToDmx = (dmxUniverse) ->
  dmxPkt = R.concat([0x7e, 0x06], dataLenToTwoByte dmxUniverseLength).concat(dmxUniverse).concat([0xe7])
  serialPort.write dmxPkt, (err, res) ->
    if err then exit err

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

calculateWinchPosition = (winch) ->
  top = 255 - winch.data.maxPos
  bottom = winch.data.minPos
  length = top - bottom
  Math.floor(length/255*(255-winch.data.bri)) + bottom

winchParamsToDmxVals = (winch) ->
  _.map [winch.data.position,
    winch.data.finePosition,
    winch.data.speed,
    winch.data.maxPos,
    winch.data.minPos,
    winch.data.findUp,
    winch.data.findDown], (val, i) ->
      {'addr': winch.data.startAddress + i, 'val': val}

parseWinchParams = (winch) ->
  winch.data.universeAddress = winch.data.protocolAddress.split('/')[0]
  winch.data.speed = parseInt winch.data.protocolAddress.split('/')[2]
  winch.data.maxPos = parseInt winch.data.protocolAddress.split('/')[3]
  winch.data.minPos = parseInt winch.data.protocolAddress.split('/')[4]
  winch.data.position = calculateWinchPosition winch
  winch.data.startAddress = parseInt winch.data.protocolAddress.split('/')[1]
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


createLightSlideMessages = (message) ->
  time = 5



async.series openStreams, (err, [acWriteMessages, winchWriteMessages]) ->
  if err then exit err

  acMessageStream = new Bacon.Bus()

  Bacon.update(
    []
    acMessageStream, (driverState, x) ->
      if !x.time
        x.time = 5


      idEquals = R.pathEq ['data', '_id']
      index = R.findIndex idEquals(x.data._id), driverState
      if x.time > 0
        x.time -= 1
        console.log x
        #Bacon.later(5000, x).onValue (val) -> acMessageStream.push(val)
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
    console.log deviceStateRegisterArray
    f = (x) ->universe[x.addr] = x.val
    R.forEach f, deviceStateRegisterArray
    universe
  .onValue (dmxUniverse) -> doWriteToDmx dmxUniverse

  acWriteMessages
    .onValue (m) -> acMessageStream.push(m)

  bridgeDmxWinchSocket.write (JSON.stringify { command: "driverReady", protocol: "dmx/winch"}) + "\n"
  bridgeDmxAcSocket.write (JSON.stringify { command: "driverReady", protocol: "dmx/ac"}) + "\n"


