--- Messaging over a raw modem channel.
--
-- Not rednet. rednet always opens the same two channels -- the computer's own
-- id and 65535 -- and separates traffic by filtering on a protocol string once
-- a message has already been delivered. That works, but every fleet's traffic
-- wakes every computer on the map before being thrown away, and any other
-- program in the world using the same protocol name lands in our inbox.
--
-- A modem never raises an event for a channel it has not opened. So a channel
-- per fleet is real separation rather than a filter, and it is a number you can
-- set -- which is what cc-mek-scada does, and why it can run several networks
-- in one world without them touching.
--
-- What rednet was doing for us that we now do here:
--   * addressing -- every frame carries `from` and `to`, because a channel is
--     shared by everyone on the fleet and a modem_message has no sender
--   * an event shape -- receive() hands back (senderId, message) like
--     rednet.receive did, so the programs above barely changed

local config = require("lib.config")

local net = {}

net.modem   = nil     -- the wrapped peripheral
net.side    = nil     -- where it is attached
net.channel = nil     -- what we are listening on
net.id      = nil     -- this computer's id, cached

local BROADCAST = "*"

--------------------------------------------------------------------------------

--- Open a wireless modem on the fleet's channel. Returns side, or nil.
function net.open(channel)
  net.channel = channel or config.channel
  net.id      = os.getComputerID()

  for _, side in ipairs(peripheral.getNames()) do
    if peripheral.getType(side) == "modem" and peripheral.call(side, "isWireless") then
      net.modem = peripheral.wrap(side)
      net.side  = side
      net.modem.open(net.channel)
      return side
    end
  end
  return nil
end

function net.isOpen()
  return net.modem ~= nil and net.modem.isOpen(net.channel)
end

function net.close()
  if net.modem then net.modem.close(net.channel) end
  net.modem, net.side = nil, nil
end

--------------------------------------------------------------------------------

local function transmit(to, message)
  if not net.modem then return false end
  net.modem.transmit(net.channel, net.channel, {
    fleet = config.protocol,     -- see below
    from  = net.id,
    to    = to,
    body  = message,
  })
  return true
end

--- Send to one computer on the fleet.
function net.send(id, message) return transmit(id, message) end

--- Send to everyone on the fleet.
function net.broadcast(message) return transmit(BROADCAST, message) end

--------------------------------------------------------------------------------

--- Turn a raw modem_message event into (senderId, message), or nil if it is
--- not for us. Split out because remote.lua runs its own event loop -- it has a
--- UI to redraw and clicks to handle -- and cannot sit inside net.receive.
--
-- Frames carry the fleet name as well as riding a per-fleet channel. The
-- channel does the real separating; the name catches two fleets configured on
-- the same number by accident, which is otherwise a genuinely confusing failure
-- where turtles quietly take orders from the wrong base.
function net.decode(event, side, channel, reply, frame)
  if event ~= "modem_message" then return nil end
  if channel ~= net.channel then return nil end
  if type(frame) ~= "table" or type(frame.body) ~= "table" then return nil end
  if frame.fleet ~= config.protocol then return nil end
  if frame.to ~= BROADCAST and frame.to ~= net.id then return nil end

  -- Our own broadcasts come back to us on a shared channel. rednet never did
  -- that, and a server that folded its own heartbeats into the roster would be
  -- talking to itself.
  if frame.from == net.id then return nil end

  return frame.from, frame.body
end

--- Wait for a message addressed to us or broadcast. Returns senderId, message,
--- or nil on timeout -- the same shape rednet.receive had.
function net.receive(timeout)
  local timer = timeout and os.startTimer(timeout) or nil

  while true do
    local event, a, b, c, d = os.pullEvent()

    local from, message = net.decode(event, a, b, c, d)
    if from then
      if timer then os.cancelTimer(timer) end
      return from, message
    end

    if event == "timer" and timer and a == timer then return nil end
  end
end

return net
