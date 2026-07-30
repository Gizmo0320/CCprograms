--- Shared configuration for miner.lua / remote.lua.
-- Edit this file rather than hardcoding values in the programs.

local config = {}

-- rednet protocol both ends speak.
config.protocol = "mining"

-- Where the resumable job state lives.
config.stateFile = "/miner.state"

-- Unsolicited status broadcast interval (seconds).
config.heartbeat = 2

-- Pocket side: no heartbeat for this long means CONNECTION LOST.
config.heartbeatTimeout = 6

--------------------------------------------------------------------------------
-- Fleet
--------------------------------------------------------------------------------

-- Where the server keeps its roster and job queue.
config.fleetFile = "/fleet.state"

-- No heartbeat for this long and the server presumes a turtle lost. Longer than
-- heartbeatTimeout: the pocket can afford to cry wolf, but the server uses this
-- to decide a job died, and requeueing a job whose turtle is merely lagging
-- would have two turtles mining the same lane.
config.staleAfter = 15

-- Seconds between dispatches. Turtles all leaving base in the same tick means
-- they all try to occupy the same block above the chest.
config.dispatchDelay = 2

-- How long after dispatching before a turtle is expected to be reporting the
-- job. A turtle that has just been sent a job still says "idle" for a moment --
-- its next heartbeat may already have been in flight when the order arrived --
-- and without this grace the server reads that as "never got it" and hands the
-- same lane to a second turtle. Comfortably more than one heartbeat.
config.dispatchGrace = 6

-- How many times a job is handed to a fresh turtle after the previous one went
-- idle without finishing. The cap is what stops a job that is impossible --
-- unreachable origin, bedrock start -- from cycling through the whole fleet
-- forever.
config.jobRetries = 2

-- Extra fuel kept in reserve on top of the cost of walking home.
config.fuelMargin = 64

-- How many times a single move/dig is retried before it is called a failure.
-- Gravel columns and mob spam both need a generous count; the cap only exists
-- so a genuinely stuck turtle surfaces an error instead of spinning forever.
config.maxRetries = 64

-- Junk that gets dumped when the inventory fills, and that may be used to seal
-- lava. Names are the Minecraft registry ids returned by turtle.getItemDetail.
config.junk = {
  ["minecraft:cobblestone"]      = true,
  ["minecraft:cobbled_deepslate"]= true,
  ["minecraft:stone"]            = true,
  ["minecraft:deepslate"]        = true,
  ["minecraft:dirt"]             = true,
  ["minecraft:coarse_dirt"]      = true,
  ["minecraft:rooted_dirt"]      = true,
  ["minecraft:grass_block"]      = true,
  ["minecraft:gravel"]           = true,
  ["minecraft:sand"]             = true,
  ["minecraft:sandstone"]        = true,
  ["minecraft:tuff"]             = true,
  ["minecraft:andesite"]         = true,
  ["minecraft:diorite"]          = true,
  ["minecraft:granite"]          = true,
  ["minecraft:netherrack"]       = true,
  ["minecraft:basalt"]           = true,
  ["minecraft:blackstone"]       = true,
  ["minecraft:end_stone"]        = true,
  ["minecraft:flint"]            = true,
}

-- Only these are ever burned. A whitelist, not turtle.refuel on everything --
-- otherwise the turtle eats the oak planks and bookshelves it just mined.
config.fuel = {
  ["minecraft:coal"]             = true,
  ["minecraft:charcoal"]         = true,
  ["minecraft:coal_block"]       = true,
  ["minecraft:blaze_rod"]        = true,
  ["minecraft:dried_kelp_block"] = true,
  ["minecraft:lava_bucket"]      = true,
}

-- If one of these is in the inventory it is used as a portable dump: placed,
-- filled, and broken again whenever the inventory fills up.
--
-- Two properties are required and neither is negotiable:
--   * items put in it go somewhere else, so breaking it does not spill them
--     back onto the floor for the turtle to pick straight back up;
--   * it drops itself when mined without silk touch, so the turtle can reclaim
--     it and carry it to the next unload.
-- That rules out ordinary chests and barrels (contents spill) and vanilla
-- minecraft:ender_chest (needs silk touch, shatters into 8 obsidian otherwise,
-- leaving the turtle with nowhere to dump for the rest of the job).
-- EnderStorage's ender chest satisfies both.
config.dumpChest = {
  ["enderstorage:ender_chest"]  = true,
  ["ender_storage:ender_chest"] = true,
}

-- When the inventory fills and there is no carried dump chest, walk home, empty
-- into a container next to the start position, and walk back to carry on. This
-- is what lets a vanilla world run a job longer than 16 stacks.
config.dumpAtHome = true

-- Blocks that accept turtle.drop(). Wider than config.dumpChest, which is the
-- stricter "portable and reclaimable" list: these only have to sit at home and
-- hold things. The turtle checks against this before dropping, because dropping
-- at air litters the floor instead of storing anything.
config.container = {
  ["minecraft:chest"]           = true,
  ["minecraft:trapped_chest"]   = true,
  ["minecraft:barrel"]          = true,
  ["minecraft:hopper"]          = true,
  ["minecraft:dropper"]         = true,
  ["minecraft:dispenser"]       = true,
  ["minecraft:ender_chest"]     = true,
  ["enderstorage:ender_chest"]  = true,
  ["ender_storage:ender_chest"] = true,
  ["minecraft:shulker_box"]     = true,
}
for _, dye in ipairs({ "white", "orange", "magenta", "light_blue", "yellow",
                       "lime", "pink", "gray", "light_gray", "cyan", "purple",
                       "blue", "brown", "green", "red", "black" }) do
  config.container["minecraft:" .. dye .. "_shulker_box"] = true
end

-- Never dropped and never dumped into the chest.
config.keep = {}
for name in pairs(config.fuel) do config.keep[name] = true end
for name in pairs(config.dumpChest) do config.keep[name] = true end

-- Vein following: when a pattern is run with `veins` on, an ore next to the
-- turtle's path is chased to the end of its vein and then the turtle retraces
-- its way back to the row.
--
-- The caps are the whole safety story. Without them a turtle that clips the
-- edge of a ravine full of exposed ore walks off and never comes back.
config.veinMax    = 64   -- blocks per vein before it gives up and returns
config.veinRadius = 8    -- how far from the row a vein may lead it

-- Ore detection prefers the block tags CC:T returns from turtle.inspect, which
-- covers modded ores for free. This list is the fallback for older CC:T builds
-- that report no tags, and a place to add anything the tags miss.
config.oreTag = {
  ["c:ores"]                = true,
  ["forge:ores"]            = true,
  ["minecraft:coal_ores"]   = true,
  ["minecraft:iron_ores"]   = true,
  ["minecraft:gold_ores"]   = true,
  ["minecraft:diamond_ores"]= true,
  ["minecraft:redstone_ores"] = true,
  ["minecraft:lapis_ores"]  = true,
  ["minecraft:emerald_ores"]= true,
  ["minecraft:copper_ores"] = true,
}

config.ore = {
  ["minecraft:ancient_debris"] = true,
  ["minecraft:nether_quartz_ore"] = true,
  ["minecraft:nether_gold_ore"]   = true,
}
for _, kind in ipairs({ "coal", "iron", "gold", "diamond", "redstone",
                        "lapis", "emerald", "copper" }) do
  config.ore["minecraft:" .. kind .. "_ore"] = true
  config.ore["minecraft:deepslate_" .. kind .. "_ore"] = true
end

--------------------------------------------------------------------------------
-- Geo scanner (Advanced Peripherals)
--------------------------------------------------------------------------------

-- Default scan radius. Cost rises steeply with radius and it comes out of the
-- turtle's own fuel, so this is a working figure rather than the maximum.
config.scanRadius = 8

-- The scanner refuses while it is cooling down. That is a wait, not a failure,
-- so a scan is retried this many times with this long between attempts.
config.scanRetries  = 4
config.scanCooldown = 1

-- Ore blocks this far apart or closer are treated as one seam and become a
-- single harvest job. One job per ore block would swamp the queue and send a
-- turtle across the world for a single lump of coal.
config.clusterGap = 4

-- Clusters smaller than this are not worth a round trip; the vein following a
-- passing miner does will pick them up eventually.
config.clusterMin = 3

-- Two reported clusters within this distance of each other are taken to be the
-- same seam seen from two scan positions, so it is only queued once.
config.clusterSame = 6

-- Blocks that stop a dig outright.
config.unbreakable = {
  ["minecraft:bedrock"]            = true,
  ["minecraft:barrier"]            = true,
  ["minecraft:end_portal_frame"]   = true,
  ["minecraft:reinforced_deepslate"] = true,
  ["computercraft:turtle_normal"]  = true,
  ["computercraft:turtle_advanced"]= true,
}

-- Liquids the turtle refuses to dig into; it seals or routes around them.
config.hazard = {
  ["minecraft:lava"]         = true,
  ["minecraft:flowing_lava"] = true,
}

return config
