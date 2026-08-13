--- The manual, as data.
--
-- Shipped so that `guide` works in game, on the computer that is actually
-- bolted to the ship, at the moment something is wrong with it -- which is when
-- documentation is worth anything and is exactly when a README on a website is
-- not reachable. The mod itself does this with /rom/thrusters/docs.lua and it is
-- the right idea.
--
-- Pure: topics, wrapping and search, and nothing that draws. guide.lua is the
-- browser. Splitting them means the text can be checked -- that every topic has
-- a body, that no line is too wide for a pocket computer -- without a screen.
--
-- ## Written by hand to 26 columns, and checked
--
-- The wrapper below will fold anything too wide, and `spec.lua` asserts that it
-- never has to. Both, deliberately.
--
-- Machine reflow was tried and thrown away. Several topics are laid out as
-- tables -- a column of names against a column of meanings -- and a wrapper
-- turns those into hanging fragments that are harder to read than the thing they
-- were explaining. The wrapper is the backstop for a screen narrower than
-- expected, not the layout.

local guide = {}

guide.topics = {

{ title = "Start here", body = [[
A flight network for
Create Aeronautics ships.

Four programs, one
install. Each computer
picks its own from the
role you gave it:

 pilot  rides the ship
        and flies it
 tower  an advanced
        computer at base:
        roster, waypoints,
        log and a map
 remote an advanced
        pocket computer
 beacon stands still and
        is a waypoint

Every ship flies itself.
The tower and the pocket
only set goals. Switch
the tower off and the
ships carry on and land.

Every computer needs a
WIRELESS MODEM.

The ship needs a
NAVIGATION TABLE or it
can hover but not
navigate, and an
ALTITUDE SENSOR or it
will not fly at all.

Type: guide first
]] },

{ title = "First flight", body = [[
1 Build and assemble the
  ship, with a computer
  on it.

2 On that computer run:
    probe
  It writes /craft.cfg
  from what it can see,
  and /aero.survey.txt
  listing every
  peripheral it found.

3 Open /craft.cfg. Check
  the one thing probe
  had to guess: which
  bearing is lift and
  which is main. The
  wrong way round is a
  ship that flies into
  the ground.

4 TETHERED TEST.
  Run pilot with no
  plan. Check the pocket
  sees it. Press Ctrl-T.
  Every thruster must go
  to zero and back to
  redstone control.
  Do not fly until this
  works.

5 Stand where you want
  the pad. On the
  pocket: nav tab,
  + pad here, name it.
  Tap the name to make
  it home.

6 Put a second waypoint
  somewhere you can see.

7 fly tab: set an
  altitude, tap the
  waypoint, FLY IT.
]] },

{ title = "Configuring", body = [[
  configure

Panes, a review, and
nothing written until you
say so.

It OPENS by telling you
what is wrong with the
configuration you already
have, which saves the
whole business of finding
out.

  Network
    name, channel, role
  Bearings
    which is lift, which
    is main
  Instruments
    what this hull reads
  Limits
    speeds, heights,
    hover

BEARINGS is the one that
matters. Nothing can work
out which bearing holds
the ship up by looking --
probe guesses -- and
getting it backwards is a
ship that flies into the
ground. Here you see
every bearing attached
and point at the right
one. Swapping them is two
taps.

Review and apply writes
/aero.cfg and /craft.cfg.
Both are ordinary Lua and
still yours to edit.

Nothing is written until
APPLY.
]] },

{ title = "Checking the hardware", body = [[
If a computer will not do
what you expect, run:

  setup

It lists everything this
role needs, marks what is
attached RIGHT NOW, and
says what each thing is
for and what you lose
without it.

It re-checks every
second, so you can leave
it on screen, go and
place the missing block,
and watch the line turn
green.

  setup pilot

shows another role's list,
for planning a build
before you have made it.

On a flight computer it
also reads /craft.cfg and
reports anything that
disagrees with the
hardware -- which is
where the confusing
failures live. "It cannot
find the navigation
table" has four causes:

 the block is not on the
 contraption
 the contraption is not
 assembled
 /craft.cfg switched the
 role off
 nothing has run probe

setup tells the four
apart. Nothing else can.

The second one used to
be permanent. Assembling
a contraption attaches
every peripheral on it,
and the pilot resolved
its hardware once at
boot -- so turning the
computer on and THEN
assembling the ship left
it saying it could not
find a table that was
plainly there.

It now re-resolves
whenever a peripheral
attaches, and logs it.
Assembly order no longer
matters.
]] },

{ title = "The hull file", body = [[
/craft.cfg says what the
ship is made of. Update
never replaces it, so
edit it freely.

 controls
   what can be driven
 instruments
   what can be read
 limits
   speeds and heights
 gains
   how it flies
 mix
   which demand drives
   which control

The mix is the clever
part. The autopilot
makes four numbers:
lift, forward, yaw and
pitch. It knows nothing
about thrusters. The mix
maps them onto this
hull, which is why a
jet, a balloon and a
truck share one
autopilot.

  mix = {
   { demand = "lift",
     control = "lift",
     as = "throttle" },
  }

Terms ADD, so two
bearings can share the
lift with scale 0.5
each.

A bad craft file is a
warning on screen, never
a computer that will not
boot.
]] },

{ title = "Controls", body = [[
kind    drives
----    ------
bearing
  a thruster bearing:
  throttle and pivot
thruster
  one thruster
orientation
  a virtual orientation
  source: angleX, angleZ
wheels
  an Offroad wheel mount
input
  one channel of the
  analogue controller
grip
  a claw or rope winch
gearbox
  one face of a
  bidirectional gearbox,
  aimed in degrees
wire
  plain redstone

A wire is the only kind
that needs no
peripheral. With none it
drives this computer's
own six sides; with one
it drives a
redstone_relay, which
can sit anywhere on a
wired modem network.

  burner = {
    kind = "wire",
    side = "top",
    mode = "analog",
    hold = true },

mode is digital, analog
or bundled. A bundled
wire needs a colour.
]] },

{ title = "Instruments", body = [[
All of these are found by
themselves. Name one in
/craft.cfg only when you
have two, or set it to
false to say this hull
has none and stop the
warning.

nav
  navigation table.
  Position and heading.
  Without it a ship can
  hover but not navigate.
alt
  altitude sensor.
  Without it AND nav, the
  pilot hands the hull
  back rather than fly it
  down.
ground
  optical sensor pointing
  DOWN. The terrain
  guard's only eye.
forward
  optical sensor pointing
  AHEAD. The obstacle
  guard's.

  The two optical roles
  are the same block, so
  only you know which
  way each points. probe
  assumes the first is
  down and the second is
  forward. Check it in
  configure.

  Naming one sensor as
  both is refused: they
  want opposite ranges,
  so one guard would
  read a number that
  means something else.

  Run  probe --eyes  to
  watch what the sensors
  actually report, live,
  and which role each
  one has.

  Range is set on the
  SENSOR BLOCK. The ship
  asks for 128 down and
  takes what it is given
  -- it cannot raise the
  block's own maximum.
  Under 32 and the panel
  says so, because blank
  clearance looks just
  like flat ground far
  below.
gimbal
  gimbal sensor. Pitch
  and roll as real
  angles.
vel
  velocity sensor.
stick
  analogue joystick.
  Touching it takes
  control off the
  autopilot.
dock
  docking connector.
link
  advanced data link. The
  pilot publishes the
  current leg to it, so
  gyros and guided
  bearings on the hull
  aim where the autopilot
  is going.
homing
  directional link:
  bearing to the nearest
  matching link.
range
  modulating link: its
  distance.
plate
  nameplate. Renaming a
  ship writes it, so the
  name is readable from
  outside.
swivel
  swivel bearing's target
  angle.

CC: Sable, if installed,
beats all of them for
position, velocity and
attitude, and is the only
thing that can measure a
ship spinning.
]] },

{ title = "Balloons", body = [[
Hot air burners and
steam vents are
ANALOGUE. Signal
strength sets the target
volume of hot air, so
the signal IS the lift.

Always set hold = true
on anything that is
lift. Without it,
quitting the pilot turns
the burner off at
whatever altitude you
were at.

CC does not keep
redstone outputs across
a chunk unload. The
pilot saves every wire
signal and puts it back
at boot. That is the
only reason walking away
from a moored balloon is
survivable.

A balloon is a much
SLOWER thing to fly than
a thruster ship: the
envelope fills at a
fixed rate and there are
only sixteen signal
levels. Thruster gains
will make it bob.

Start with:

 gains = {
   hover = 0.5,
   altP = 0.2,
   vsP = 0.05,
   vsI = 0.04,
   vsD = 0.04 }

 limits = {
   cruise = 8,
   climb = 2,
   descend = 2 }
]] },

{ title = "Flying it", body = [[
On the pocket, four tabs
along the bottom.

FLEET
 Every ship and what it
 is doing. Tap one to
 pick it out; tap again
 for the whole fleet.

  HOLD stop and hover
  LAND come down here
  RTB  go home and land
  STOP descend now

 STOP is a CONTROLLED
 descent. There is no
 button here that cuts
 the engines in mid-air,
 on purpose.

FLY
 Set an altitude, tap
 waypoints to build a
 route, then FLY IT.
 SAVE as... keeps it.

NAV
 + waypoint here and
 + pad here put one
 where YOU stand.
 Tap a name to make it
 home. Tap the x to
 delete it.

LOG
 What happened, and why.

A pad is somewhere to
land and needs a height.
A point is somewhere to
fly over. A plan ending
on a point HOLDS there
rather than landing in
a field.
]] },

{ title = "Waypoint computers", body = [[
A BEACON is a computer you
put where you want a
waypoint. It tells the
tower it is there, for as
long as it is running, so
nobody has to walk over
with a pocket computer
and nobody has to add it
again after a restart.

That is the whole job. It
is a marker. No sensors,
nothing to wire up: a
wireless modem so it can
be heard, and a position
so it knows what to say.

SETTING IT UP

Install with the beacon
role, then run:

  beacon

It asks three things:

 name   what ships will
        call it
 pad?   y if ships land
        here, n if it is
        just somewhere to
        fly over
 where  type  x y z
        or  x,y,z

If GPS answers it offers
what it found, so Enter
takes it. If not, you
type the numbers. Either
way they are yours: GPS
is a suggestion and never
a requirement.

Q at the position prompt
leaves it unset.

CHANGING IT

  beacon set

or press S on the beacon
itself. Or edit
/beacon.cfg by hand --
update never touches it.

ALL AT ONCE

  beacon --at=40,70,300
         --name=quarry
         --kind=pad

OPTIONAL

Put a docking connector
on the same computer and
it reports whether the
pad is free.

A beacon with no position
says nothing at all. A
marker in the wrong place
is worse than no marker.
]] },

{ title = "Surveying", body = [[
Ships survey as they fly.
Every telemetry frame
carries where the ship is
and how far the ground is
below it, which is a
measurement, and the
tower remembers it.

So the second flight over
a route knows what the
first one found out.

Before taking off, the
ship checks the route
against that map and
RAISES its cruise
altitude if the ground
needs it. The log says
"terrain" when it does.

It only ever raises. A
map built from where
ships happened to fly can
say a hill IS there. It
can never honestly say a
hill is NOT.

On the fly tab you will
see one of:

  route needs 190
  route not surveyed

The second is not a
warning that something is
wrong. It means nobody
has been that way yet,
and the guards are all
you have. Fly it high.

The map is bounded and
kept on the tower across
restarts. Ships cache it,
so a ship already in the
air can still check its
own route with the tower
unloaded.
]] },

{ title = "Up and down", body = [[
Altitude has its own
control. You do not need
a flight plan to raise or
lower a ship.

On the pocket, fleet tab:

  ALT   raise / lower

Tap the right of the row
to go up, the left to go
down. Ten blocks a tap.
The same row is on a
ship's own panel, which
is where you nudge one
ship rather than the
whole fleet.

A PARKED ship takes off
for this and holds where
you put it. That is the
short way to say "take
off and hover at 140".

A FLYING ship just
changes what it holds.
If it was on a leg it
keeps the leg -- this is
a change of cruise
altitude, not a change of
mind.

Two taps move it twice.
The second is measured
from where the ship is
going, not from where it
has got to.

Silly numbers are
clamped. A hull can
narrow the range with
limits.ceiling and
limits.floor.
]] },

{ title = "Sharing a ship", body = [[
Anyone can WATCH a ship.
Telemetry is broadcast
and costs nothing.

One person at a time
FLIES it. Two pockets
sending "land" and "fly
to the quarry" a second
apart is the joystick
problem with more hands:
the ship obeys whichever
arrived last and nobody
can tell why.

So control is held. The
first order takes it.
Anyone else is refused
and told who to ask.

On a ship's panel:

  control   Anna
  TAKE control from Anna

Taking over always works.
A ship nobody can command
because its commander
logged off would be worse
than the muddle this
prevents. But it is a
deliberate tap and it
goes in the log.

RELEASE control hands it
back to nobody.

Control also lapses by
itself after about a
minute and a half of
silence, so wandering off
needs no ceremony.

In the fleet list, a ship
somebody else is flying
is marked with a star.
The tower shows the name
in a flown-by column.
]] },

{ title = "One ship", body = [[
Pick a ship on the fleet
tab, then tap SHIP.

Gauges
 Altitude against what
 it was told, fuel
 against the tank,
 vertical speed, tilt,
 the fix source, and the
 guard if one is firing.

Hull
 Every control and
 whether it answers.
 The quickest way to
 find the bearing you
 thought was attached.

Gains
 A minus and a plus on
 each. A tap moves it
 by a tenth of itself,
 so one control suits
 0.5 and 0.015 alike.
 Never below zero.

This is the tuning loop.
Reinstalling to try 0.4
instead of 0.35 is not
one anybody would use.
]] },

{ title = "Guards", body = [[
Seven rules outrank the
flight plan. Each writes
a line in the log saying
why.

1 HANDS
  You touched the
  joystick. The
  autopilot lets go and
  DROPS THE PLAN. It
  takes over again a few
  seconds after you let
  go.

2 TILT
  Leaning too far: stop,
  hold, level. Leaning
  past about 70: hand
  the hull back. Past 90
  the lift demand pushes
  the ship AT the
  ground.

3 NO HEIGHT
  No altitude source
  means no vertical
  loop, so hand the hull
  back rather than fly
  it down.

4 CLEARANCE
  Too close to the
  ground: climb,
  whatever the plan
  said.

5 OBSTACLE
  Something ahead: stop
  pushing and climb.
  Needs a forward
  optical sensor. A ship
  has NO BRAKES, so this
  buys height and time,
  not a stop.

6 NO FIX
  The navigation table
  has gone quiet too
  long: loiter. It
  resumes when the fix
  comes back.

7 BINGO FUEL
  Turn for home while
  there is still enough
  to get there. Latched.
]] },

{ title = "Tuning", body = [[
Symptoms, and what to
move on the SHIP panel.

Sinks, never climbs
  hover too low. Raise
  it. vsI finds the
  rest.

Climbs past and comes
back
  vsD up, or altP down.

Bobs up and down for
ever
  altP and vsP down. A
  balloon wants far
  softer gains than a
  thruster ship.

Wanders either side of
the heading
  hdgP down.

Rolls out of a turn
early, then overshoots
  hdgD down. Yaw drives
  a RATE of turn, so
  this loop needs much
  less damping than it
  looks like it should.

Never reaches cruise
speed
  spdP or spdI up, or
  the hull simply has
  not the thrust.
]] },

{ title = "When it goes wrong", body = [[
NOTHING ON THE POCKET
 No wireless modem, or
 the wrong channel.
 Every computer must be
 on the same one.
 Reinstall to change it.

A SHIP SAYS LOST
 Out of modem range, or
 its chunk is not
 loaded. An ender modem
 on the tower helps.

WILL NOT TAKE OFF
 Preflight refused and
 said why in the log:
 no plan, no cruise
 altitude, no fix, or
 not enough fuel for
 the trip.

HANDS BACK AT ONCE
 No altitude source.
 Check the altitude
 sensor is on the
 assembled ship and
 named in /craft.cfg.

CANNOT NAVIGATE
 Run `setup`. It tells
 apart: no block, an
 unassembled
 contraption, a
 /craft.cfg that
 switched nav off, and
 never having run probe.

FLIES THE WRONG WAY
 lift and main swapped
 in /craft.cfg, or a
 mix term with the
 wrong scale.

NO WAYPOINTS
 They live on the
 tower. With no tower
 the pocket shows only
 what ships have
 cached.

UPDATE REFUSED
 The ship is airborne.
 Land it first. This is
 deliberate.
]] },

{ title = "Files", body = [[
Update never replaces
these, so yours survive:

 /craft.cfg
   what this hull is
 /aero.cfg
   network, channel,
   role
 /aero.state
   a pilot's flight plan
 /fleet.state
   the tower's waypoints
   and its log
 /aero.survey.txt
   what probe last saw
 /beacon.cfg
   a beacon's name, kind
   and position

Programs:

 pilot   fly this ship
 server  the tower
 remote  the pocket
 beacon  be a waypoint
 setup   what this
         computer needs
 config- set it up without
 ure     editing Lua
 probe   survey the hull
 guide   this
 update  fetch the
         latest. Add
         --check to look
         without
         changing
         anything.
]] },

}

--------------------------------------------------------------------------------

--- Wrap a body to a width. Pure.
--
-- The backstop, not the layout: the topics above are already narrow enough for a
-- pocket computer and spec.lua enforces it. This exists for a screen narrower
-- than one, and for a search result drawn in a box.
--
-- Breaks on spaces and never mid-word, and keeps blank lines, because the topics
-- use them as paragraph breaks and a wrapper that ate them would run the whole
-- manual together. Leading spaces are kept too: several topics are laid out as
-- tables and lose their meaning without them.
function guide.wrap(text, width)
  local out = {}
  if width < 4 then width = 4 end

  for line in (tostring(text) .. "\n"):gmatch("(.-)\n") do
    if line == "" then
      out[#out + 1] = ""
    else
      local indent = line:match("^(%s*)") or ""
      local rest = line:sub(#indent + 1)

      while #indent + #rest > width do
        local room = math.max(1, width - #indent)
        local cut = rest:sub(1, room):match("^.*()%s")

        -- No space to break on means a single word longer than the line, and
        -- there is nothing to do but cut it. Rare, and better than looping.
        if not cut or cut < 2 then cut = room end

        out[#out + 1] = indent .. (rest:sub(1, cut):gsub("%s+$", ""))
        rest = rest:sub(cut + 1):gsub("^%s+", "")
      end

      out[#out + 1] = indent .. rest
    end
  end

  return out
end

--- Topics whose title or body contains `query`, case-insensitively. Pure.
--
-- Searched rather than indexed: there are a dozen topics and the answer has to
-- be right rather than fast. Returns the whole topic list for an empty query, so
-- clearing the search box puts the manual back.
function guide.search(query)
  query = tostring(query or ""):lower()
  if query == "" then return guide.topics end

  local found = {}
  for _, topic in ipairs(guide.topics) do
    if topic.title:lower():find(query, 1, true)
      or topic.body:lower():find(query, 1, true) then
      found[#found + 1] = topic
    end
  end
  return found
end

--- The widest line in every topic, and which topic it is in. Pure.
--
-- Exists for the test that keeps this readable on a pocket computer, which is
-- the device most likely to be reading it and the one least able to cope.
function guide.widest()
  local widest, where = 0, nil
  for _, topic in ipairs(guide.topics) do
    for line in (topic.body .. "\n"):gmatch("(.-)\n") do
      if #line > widest then widest, where = #line, topic.title end
    end
  end
  return widest, where
end

return guide
