--- Redstone remote. Runs on an advanced pocket computer.
--
-- The thing you carry: see what is on, switch it, edit the rules that switch it
-- for you. It holds no authoritative state of its own and never guesses -- a
-- node that has gone quiet says LOST rather than showing the last value it had
-- as though it were live. The whole job of this program is telling you what is
-- on right now.
--
-- Two routes, and the header always says which one is in use:
--
--   SERVER  the network server is answering. Scenes and the log come from it.
--   DIRECT  nothing at base is answering. The roster is assembled from node
--           heartbeats and commands go straight to the node. Scenes and the log
--           are unavailable, because they only ever lived on the server -- but
--           every switch still works, which is the part that matters when you
--           are standing in the dark.
--
-- Deliberately not read() anywhere: it blocks the event loop, heartbeats stop
-- arriving, and the link reads LOST while you type.

local config = require("lib.config")
local net    = require("lib.net")
local log    = require("lib.log")

local W, H = term.getSize()

--------------------------------------------------------------------------------
-- Link
--------------------------------------------------------------------------------

local link = {
  server = nil,            -- id of the network server, if one is answering
  net    = nil,            -- its last broadcast
  seenAt = -math.huge,
  nodes  = {},             -- [id] = state message, for direct mode
  heard  = {},             -- [id] = os.clock() of its last heartbeat
  rules  = {},             -- [id] = last `rules` reply, fetched on demand
  note   = nil,
}

link.note = ("network '%s': looking..."):format(config.protocol)

local function now() return os.clock() end

local function haveServer()
  return link.server ~= nil and (now() - link.seenAt) < config.heartbeatTimeout
end

--- One roster shape whichever route is live, so the panel is drawn from the
--- same rows either way.
local function roster()
  if haveServer() and link.net then return link.net.nodes or {} end

  local list = {}
  for id, s in pairs(link.nodes) do
    local gone = (now() - (link.heard[id] or -math.huge)) > config.heartbeatTimeout
    list[#list + 1] = {
      id = id, label = s.label, stale = gone, ports = s.ports,
      rules = s.rules, blocks = s.blocks, warn = s.warn,
    }
  end
  table.sort(list, function(a, b) return a.id < b.id end)
  return list
end

local function sceneList()
  if haveServer() and link.net then return link.net.scenes or {} end
  return {}
end

local function toNode(id, msg) net.send(id, msg) end

local function toServer(msg)
  if link.server then net.send(link.server, msg) end
end

--------------------------------------------------------------------------------
-- Screens
--------------------------------------------------------------------------------

local screen = "panel"                  -- panel | scenes | rules | log
local scroll = 0
local rows   = {}                       -- rebuilt every draw; carries the clicks
local flash  = nil                      -- { text, until_ }
local logs   = {}                       -- last `log` reply from the server

local editor = nil                      -- the new-rule form, when one is open
local typing = nil                      -- { field, text } while a name is typed

local function note(text)
  flash = { text = text, until_ = now() + 3 }
end

local function colour(c)
  if term.isColour() then term.setTextColour(c) end
end

local function at(x, y, text, c)
  colour(c or colours.white)
  term.setCursorPos(x, y)
  term.write(text)
end

local function fit(text, width)
  text = tostring(text or "")
  if #text <= width then return text end
  return text:sub(1, math.max(0, width - 1)) .. "."
end

local function isOn(v)
  if type(v) == "number" then return v > 0 end
  return v == true
end

local function shown(v)
  if type(v) == "number" then return tostring(v) end
  if v == nil then return "-" end
  return v and "ON" or "off"
end

--------------------------------------------------------------------------------
-- Row building
--------------------------------------------------------------------------------

-- Every screen builds a flat list of rows and hands each one a click handler.
-- Working out what was clicked from coordinates and the current screen was the
-- thing that went wrong most often in mining/remote.lua; a row that carries its
-- own action cannot drift out of step with where it was drawn.
local function row(entry)
  rows[#rows + 1] = entry
  return entry
end

local function buildPanel()
  for _, node in ipairs(roster()) do
    row({ kind = "head", label = node.label or ("node " .. node.id),
          stale = node.stale, warn = node.warn })

    if not node.stale then
      for _, p in ipairs(node.ports or {}) do
        row({
          kind = "port", node = node.id, port = p,
          click = function()
            if p.dir ~= "out" then
              note(p.name .. " is an input")
              return
            end
            local want = not isOn(p.value)
            if p.kind == "analog" then want = isOn(p.value) and 0 or 15 end
            toNode(node.id, { type = "set", port = p.name,
                              value = want, why = "manual" })
            -- Optimistic, and corrected within two seconds by the next
            -- heartbeat. Waiting for the round trip to redraw makes a button
            -- feel broken on a link that is merely slow.
            p.value = want
          end,
        })
      end
    end
  end
end

local function buildScenes()
  if not haveServer() then
    row({ kind = "note", text = "Scenes need the server." })
    row({ kind = "note", text = "Nothing is answering at base." })
    return
  end

  for _, scene in ipairs(sceneList()) do
    row({
      kind = "scene", name = scene.name, active = scene.active,
      click = function()
        toServer({ type = "scene", name = scene.name })
        note("applying " .. scene.name)
      end,
    })
  end

  row({
    kind = "action", text = "+ capture current as...",
    click = function()
      typing = { field = "scene", text = "" }
    end,
  })
end

local function buildRules()
  for _, node in ipairs(roster()) do
    if not node.stale then
      row({ kind = "head", label = node.label or ("node " .. node.id) })

      local known = link.rules[node.id]
      if not known then
        toNode(node.id, { type = "rules?" })
        row({ kind = "note", text = "  asking..." })
      else
        for _, rule in ipairs(known.rules or {}) do
          row({
            kind = "rule", node = node.id, rule = rule,
            click = function()
              toNode(node.id, {
                type = "rule",
                action = (rule.enabled == false) and "enable" or "disable",
                rule = { id = rule.id },
              })
              rule.enabled = (rule.enabled == false)
            end,
          })
        end
        for _, block in ipairs(known.blocks or {}) do
          row({ kind = "block", node = node.id, block = block })
        end
        for _, why in ipairs(known.problems or {}) do
          row({ kind = "warn", text = why })
        end

        row({
          kind = "action", text = "  + new rule",
          click = function()
            local ins, outs = {}, {}
            for _, p in ipairs(node.ports or {}) do
              if p.dir == "out" then outs[#outs + 1] = p.name
              else ins[#ins + 1] = p.name end
            end
            if #ins == 0 or #outs == 0 then
              note("needs an input and an output")
              return
            end
            editor = {
              node = node.id, ins = ins, outs = outs,
              id = "", whenPort = 1, op = 1, value = 1,
              actPort = 1, set = true, hold = 0, field = 1,
            }
          end,
        })
      end
    end
  end
end

local function buildLog()
  if not haveServer() then
    row({ kind = "note", text = "The log lives on the server." })
    return
  end
  for _, entry in ipairs(logs) do
    row({ kind = "log", entry = entry })
  end
  if #logs == 0 then row({ kind = "note", text = "Nothing yet." }) end
end

--------------------------------------------------------------------------------
-- The rule editor
--------------------------------------------------------------------------------

local EDIT_OPS = { "on", "off", "rising", "falling", "<", ">", "==" }

local function needsValue(op)
  return op == "<" or op == ">" or op == "=="
end

local FIELDS = { "id", "when", "op", "value", "act", "set", "hold" }

local function editorRule()
  local when = { port = editor.ins[editor.whenPort], op = EDIT_OPS[editor.op] }
  if needsValue(when.op) then when.value = editor.value end

  return {
    id      = (editor.id ~= "" and editor.id) or ("rule-" .. os.epoch("utc") % 10000),
    enabled = true,
    when    = when,
    act     = { port = editor.outs[editor.actPort], set = editor.set },
    hold    = editor.hold > 0 and editor.hold or nil,
  }
end

local function cycle(delta)
  local field = FIELDS[editor.field]

  if field == "when" then
    editor.whenPort = ((editor.whenPort - 1 + delta) % #editor.ins) + 1
  elseif field == "op" then
    editor.op = ((editor.op - 1 + delta) % #EDIT_OPS) + 1
  elseif field == "value" then
    editor.value = math.max(0, math.min(15, editor.value + delta))
  elseif field == "act" then
    editor.actPort = ((editor.actPort - 1 + delta) % #editor.outs) + 1
  elseif field == "set" then
    editor.set = not editor.set
  elseif field == "hold" then
    editor.hold = math.max(0, math.min(60, editor.hold + delta))
  elseif field == "id" then
    typing = { field = "id", text = editor.id }
  end
end

local function drawEditor()
  term.clear()
  at(1, 1, "NEW RULE", colours.cyan)
  at(1, 2, ("on node %d"):format(editor.node), colours.grey)

  local op = EDIT_OPS[editor.op]
  local lines = {
    { "id",    (editor.id ~= "" and editor.id) or "(auto)" },
    { "when",  editor.ins[editor.whenPort] },
    { "is",    op },
    { "value", needsValue(op) and tostring(editor.value) or "-" },
    { "set",   editor.outs[editor.actPort] },
    { "to",    editor.set and "ON" or "off" },
    { "hold",  editor.hold > 0 and (editor.hold .. "s") or "none" },
  }

  for i, line in ipairs(lines) do
    local y = 3 + i
    local here = (i == editor.field)
    at(1, y, here and ">" or " ", colours.yellow)
    at(2, y, fit(line[1], 6), colours.lightGrey)
    at(9, y, fit(line[2], W - 10), here and colours.yellow or colours.white)
  end

  at(1, H - 2, "arrows change, enter", colours.grey)
  at(1, H - 1, "saves, q cancels", colours.grey)
end

local function saveRule()
  local rule = editorRule()
  toNode(editor.node, { type = "rule", action = "add", rule = rule })
  link.rules[editor.node] = nil     -- refetch, so the list shows what stuck
  note("sent " .. rule.id)
  editor = nil
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

local TABS = { "panel", "scenes", "rules", "log" }

local function drawRow(entry, y)
  if entry.kind == "head" then
    at(1, y, fit(entry.label, W - 6), entry.stale and colours.red or colours.cyan)
    if entry.stale then at(W - 4, y, "LOST", colours.red) end

  elseif entry.kind == "port" then
    local p = entry.port
    at(2, y, fit(p.label or p.name, W - 8),
      p.dir == "out" and colours.white or colours.lightGrey)
    at(W - 4, y, ("%4s"):format(shown(p.value)),
      isOn(p.value) and colours.lime or colours.grey)

  elseif entry.kind == "scene" then
    at(1, y, fit(entry.name, W - 8), colours.white)
    if entry.active then at(W - 6, y, "ACTIVE", colours.lime) end

  elseif entry.kind == "rule" then
    local off = entry.rule.enabled == false
    at(2, y, fit(entry.rule.id, W - 6), off and colours.grey or colours.white)
    at(W - 3, y, off and "off" or "on", off and colours.grey or colours.lime)

  elseif entry.kind == "block" then
    at(2, y, fit(entry.block.id, W - 9), colours.lightBlue)
    at(W - 7, y, fit(entry.block.kind, 7), colours.grey)

  elseif entry.kind == "log" then
    at(1, y, log.time(entry.entry.at), colours.grey)
    at(7, y, fit(entry.entry.port, 10), colours.white)
    at(18, y, fit(shown(entry.entry.to), 3),
      isOn(entry.entry.to) and colours.lime or colours.grey)
    at(22, y, fit(entry.entry.why, 5), colours.lightBlue)

  elseif entry.kind == "warn" then
    at(1, y, fit(entry.text, W), colours.orange)

  elseif entry.kind == "action" then
    at(1, y, fit(entry.text, W), colours.yellow)

  else
    at(1, y, fit(entry.text, W), colours.grey)
  end
end

local function draw()
  if editor then return drawEditor() end

  rows = {}
  if screen == "panel" then buildPanel()
  elseif screen == "scenes" then buildScenes()
  elseif screen == "rules" then buildRules()
  else buildLog() end

  term.setBackgroundColour(colours.black)
  term.clear()

  at(1, 1, "REDSTONE", colours.cyan)
  if haveServer() then
    at(W - 5, 1, "SERVER", colours.lime)
  elseif #roster() > 0 then
    at(W - 5, 1, "DIRECT", colours.yellow)
  else
    at(W - 5, 1, " LOST ", colours.red)
  end

  local top, bottom = 3, H - 2
  local visible = bottom - top + 1

  if scroll > math.max(0, #rows - visible) then
    scroll = math.max(0, #rows - visible)
  end

  if #rows == 0 then
    at(1, 4, fit(link.note, W), colours.grey)
  end

  for i = 1, visible do
    local entry = rows[i + scroll]
    if entry then
      entry.y = top + i - 1
      drawRow(entry, entry.y)
    end
  end

  if #rows > visible then
    at(W, 2, "^", colours.grey)
    at(W, H - 1, "v", colours.grey)
  end

  -- Tabs on the bottom row, which is where a thumb is on a pocket computer.
  local x = 1
  for _, name in ipairs(TABS) do
    at(x, H, name:sub(1, 5), screen == name and colours.yellow or colours.grey)
    x = x + 6
  end

  if typing then
    at(1, H - 1, fit(typing.field .. ": " .. typing.text .. "_", W), colours.yellow)
  elseif flash and now() < flash.until_ then
    at(1, H - 1, fit(flash.text, W), colours.lime)
  end
end

--------------------------------------------------------------------------------
-- Input
--------------------------------------------------------------------------------

local function clickTab(x)
  local index = math.floor((x - 1) / 6) + 1
  local name = TABS[index]
  if not name then return end

  screen, scroll = name, 0
  if name == "log" then toServer({ type = "log?", n = 30 }) end
  if name == "rules" then link.rules = {} end     -- refetch on each visit
end

local function onClick(x, y)
  if editor then return end

  if y == H then return clickTab(x) end

  for _, entry in ipairs(rows) do
    if entry.y == y and entry.click then
      entry.click()
      return
    end
  end
end

local function onChar(ch)
  if not typing then return end
  if #typing.text < 16 and ch:match("[%w%-_]") then
    typing.text = typing.text .. ch
  end
end

local function onKey(key)
  if typing then
    if key == keys.enter then
      if typing.field == "scene" and typing.text ~= "" then
        toServer({ type = "scene!", name = typing.text, capture = true })
        note("captured " .. typing.text)
      elseif typing.field == "id" and editor then
        editor.id = typing.text
      end
      typing = nil
    elseif key == keys.backspace then
      typing.text = typing.text:sub(1, -2)
    elseif key == keys.q then
      typing = nil
    end
    return
  end

  if editor then
    if key == keys.up then
      editor.field = ((editor.field - 2) % #FIELDS) + 1
    elseif key == keys.down then
      editor.field = (editor.field % #FIELDS) + 1
    elseif key == keys.left then
      cycle(-1)
    elseif key == keys.right then
      cycle(1)
    elseif key == keys.enter then
      saveRule()
    elseif key == keys.q then
      editor = nil
    end
    return
  end

  if key == keys.up then
    scroll = math.max(0, scroll - 1)
  elseif key == keys.down then
    scroll = scroll + 1
  elseif key == keys.tab then
    local index = 1
    for i, name in ipairs(TABS) do if name == screen then index = i end end
    clickTab((index % #TABS) * 6 + 1)
  elseif key == keys.q then
    return "quit"
  end
end

--------------------------------------------------------------------------------
-- Start
--------------------------------------------------------------------------------

term.clear()
term.setCursorPos(1, 1)

if not net.open() then
  colour(colours.red)
  print("No wireless modem.")
  print("This pocket computer needs one to see anything.")
  colour(colours.white)
  return
end

net.broadcast({ type = "net?" })
net.broadcast({ type = "ports?" })     -- direct mode roster, in case nothing is home
draw()

local tick = os.startTimer(0.5)
local ask  = os.startTimer(config.heartbeat)

while true do
  local event, a, b, c, d = os.pullEvent()

  local from, msg = net.decode(event, a, b, c, d)
  if from then
    if type(msg) == "table" then
      if msg.type == "net" then
        link.server, link.net, link.seenAt = from, msg, now()
      elseif msg.type == "state" then
        link.nodes[from], link.heard[from] = msg, now()
      elseif msg.type == "rules" then
        link.rules[from] = msg
      elseif msg.type == "log" then
        logs = msg.entries or {}
      elseif msg.type == "error" then
        note(tostring(msg.reason))
      elseif msg.type == "ack" and msg.of == "scene" then
        note(("scene: %d sent, %d missed"):format(msg.sent or 0, msg.missed or 0))
      end
    end
    draw()

  elseif event == "timer" and a == tick then
    tick = os.startTimer(0.5)
    draw()

  elseif event == "timer" and a == ask then
    ask = os.startTimer(config.heartbeat)
    -- Nodes and the server broadcast unprompted, so this is only for the first
    -- few seconds after the pocket is picked up -- and for a node that booted
    -- while it was in a drawer.
    if not haveServer() then
      link.note = ("network '%s': no server"):format(config.protocol)
      net.broadcast({ type = "net?" })
    end

  elseif event == "mouse_click" then
    onClick(b, c)
    draw()

  elseif event == "char" then
    onChar(a)
    draw()

  elseif event == "key" then
    if onKey(a) == "quit" then break end
    draw()
  end
end

term.clear()
term.setCursorPos(1, 1)
colour(colours.white)
print("Remote closed. Nodes carry on.")
