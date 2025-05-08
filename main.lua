--============================================================--
--  SCRAP BOTS – “Boss Minion-Storm” Build (Love2D 11.x)      --
--  Waves 1-5 = fixed part drops; Wave 6 = boss with minions   --
--  Extra mechanics: on-kill heal, shotgun blaster,            --
--                       full-set fan, 200 HP chassis          --
--============================================================--

--  ╭──────────────────────╮
--  │  GLOBAL INITIALISER  │
--  ╰──────────────────────╯
local lg, lk = love.graphics, love.keyboard
math.randomseed(os.time())

-------------------------------------------------------------- WINDOW
local W, H = 960, 540            -- game resolution
local lineH = 14                 -- line height for UI text (set in love.load)

--- love.load --------------------------------------------------
--  Runs once at startup.  Creates the window and measures the
--  current font so UI lists don’t overlap.
function love.load()
  love.window.setMode(W, H)
  lineH = lg.getFont():getHeight() + 2
end

-------------------------------------------------------------- CONSTANTS
local BASE       = {speed = 140, dmg = 4, fireDelay = 0.30, bulletSpd = 400}
local BUILD_TIME = 5             -- seconds between waves
local SLOTS      = {"head", "chassis", "leftArm", "rightArm", "legs"}

-------------------------------------------------------------- PART LIBRARY
--  All equippable parts, grouped by slot name. Each table can
--  carry stat deltas (hp, speed, dmg, etc.) plus cosmetic data.
local PARTS = {
  head    = {{name = "Radar",  colour = {0.45, 0.8, 1},  fireDelay = -0.05}},
  chassis = {{name = "Light",  colour = {1,    0.6, 0.35}, speed = 30, hp = 100}},
  leftArm = {
    {name = "Blaster",  colour = {0.6, 0.3, 1}, shot = 5, spread = 0.25, bulletSpd = -50},
    {name = "Shotgun",  colour = {0.6, 0.3, 1}, shot = 5, spread = 0.35, dmg = -1,
                        bulletSpd = -70, fireDelay = 0.12},
    {name = "Laser",    colour = {0.2, 1, 1},  hitscan = true, pierce = true,
                        dmg = 2, fireDelay = 0.12},
  },
  legs    = {{name = "Boosters", colour = {0.25, 1, 0.6}, speed = 45}}
}
PARTS.rightArm = PARTS.leftArm   -- mirror the left-arm table

-------------------------------------------------------------- GAME STATE
--  A single table holds every dynamic thing in the game so it’s
--  easy to reset on restart.
local G = {
  phase   = "build",            -- "build" or "fight"
  timer   = BUILD_TIME,
  wave    = 0,
  dead    = false,
  win     = false,

  scrap   = {},                 -- loose parts on floor
  bullets = {},
  enemies = {},
  boss    = nil,

  player  = {
    x = W/2, y = H/2, w = 22, h = 22,
    hp = 100, maxHp = 100,
    fireCd = 0,
    contactCd = 0,             -- touch-damage invulnerability timer
    bag = {}, slots = {}       -- inventory + equipped parts
  }
}

-------------------------------------------------------------- HELPERS
local function aabb(a, b)
  return a.x < b.x + b.w and b.x < a.x + a.w and
         a.y < b.y + b.h and b.y < a.y + a.h
end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function deepcopy(t)
  local n = {}
  for k, v in pairs(t) do n[k] = v end
  return n
end

local colors = {bg = {0.08, 0.09, 0.10}, ui = {0.92, 0.92, 0.92}}

--- stat(key) --------------------------------------------------
--  Returns the player’s current stat (base + all equipped mods).
local function stat(key)
  local v = BASE[key] or 0
  for _, p in pairs(G.player.slots) do v = v + (p[key] or 0) end
  return v
end

--- allEquipped() ---------------------------------------------
--  True iff every slot has a part installed (unlocks full-set bonus).
local function allEquipped()
  for _, slot in ipairs(SLOTS) do
    if not G.player.slots[slot] then return false end
  end
  return true
end

-------------------------------------------------------------- BULLETS & BEAMS
--- spawnBeam(angle, dmg) -------------------------------------
--  Creates a hitscan beam (stored briefly for drawing) and deals
--  instant damage to anything on that angle.
local function spawnBeam(a, dmg)
  table.insert(G.bullets, {beam = true, angle = a, life = 0.08,
                           x = G.player.x, y = G.player.y, dmg = dmg})

  -- helper to test a single target
  local function hit(t, dx, dy, d)
    if (dx * math.cos(a) + dy * math.sin(a)) / d > 0.97 then
      t.hp = t.hp - dmg
    end
  end

  -- check every enemy
  for _, e in ipairs(G.enemies) do
    local dx, dy = e.x + e.w/2 - G.player.x, e.y + e.h/2 - G.player.y
    hit(e, dx, dy, math.sqrt(dx*dx + dy*dy))
  end

  -- check boss (if present)
  if G.boss then
    local dx = G.boss.x + G.boss.w/2 - G.player.x
    local dy = G.boss.y + G.boss.h/2 - G.player.y
    hit(G.boss, dx, dy, math.sqrt(dx*dx + dy*dy))
  end
end

--- spawnProj(angle, stats) -----------------------------------
--  Spawns a normal projectile that travels each frame.
local function spawnProj(a, s)
  table.insert(G.bullets, {
    x = G.player.x, y = G.player.y, w = 4, h = 4,
    dmg = s.dmg, pierce = s.pierce,
    vx = math.cos(a) * s.bulletSpd,
    vy = math.sin(a) * s.bulletSpd
  })
end

-------------------------------------------------------------- SHOOT
--- tryShoot() ------------------------------------------------
--  Fires current weapons (and full-set bonus if active).
local function tryShoot()
  if G.player.fireCd > 0 or G.phase ~= "fight" then return end

  -- angle toward mouse cursor
  local mx, my = love.mouse.getPosition()
  local ang = math.atan2(my - G.player.y, mx - G.player.x)

  local base = {
    dmg       = stat("dmg"),
    bulletSpd = stat("bulletSpd"),
    pierce    = false
  }

  -- fire equipped arms
  local arms = {G.player.slots.leftArm, G.player.slots.rightArm}
  if arms[1] or arms[2] then
    for _, arm in ipairs(arms) do
      if arm then
        base.pierce = base.pierce or arm.pierce
        local shot, spread = arm.shot or 1, arm.spread or 0
        for i = 1, shot do
          local off = (i - (shot + 1)/2) / ((shot > 1) and (shot - 1) or 1) * spread
          if arm.hitscan then
            spawnBeam(ang + off, base.dmg)
          else
            spawnProj(ang + off, base)
          end
        end
      end
    end
  else
    spawnProj(ang, base)          -- bare-bones default gun
  end

  -- full-set fan + scatter
  if allEquipped() then
    for _, d in ipairs { -0.12, 0, 0.12 } do spawnBeam(ang + d, base.dmg) end
    for i = -3, 3 do spawnProj(ang + i * 0.1, base) end
  end

  G.player.fireCd = stat("fireDelay")
end

-------------------------------------------------------------- ENEMIES & BOSS
--- spawnEnemy() ---------------------------------------------
--  Creates a basic minion at a random edge, moving toward player.
local function spawnEnemy()
  local size = 20
  local side = math.random(4)
  local ex = (side == 1) and -size or (side == 2 and W + size or math.random(W))
  local ey = (side == 3) and -size or (side == 4 and H + size or math.random(H))
  table.insert(G.enemies, {x = ex, y = ey, w = size, h = size,
                           hp = 40, maxHp = 40, speed = 80})
end

--- spawnWave() ----------------------------------------------
--  Advances the wave counter and fills the arena:
--    – Waves 1-5 = regular minions
--    – Wave 6    = stationary boss that spawns minions
local function spawnWave()
  G.wave = G.wave + 1
  if G.wave == 6 then
    G.boss = {x = W/2 - 40, y = 60, w = 80, h = 80,
              hp = 40000, maxHp = 40000, spawnCd = 3}
  else
    local n = (G.wave == 1) and 3 or (G.wave == 2 and 5 or 5 + G.wave * 2)
    for i = 1, n do spawnEnemy() end
  end
end

-------------------------------------------------------------- FIXED DROPS
--- dropForWave(w) -------------------------------------------
--  Returns the guaranteed part (and its slot) for a given wave.
local function dropForWave(w)
  if     w == 1 then return deepcopy(PARTS.leftArm[3]),  "leftArm"   -- Laser
  elseif w == 2 then return deepcopy(PARTS.chassis[1]),  "chassis"
  elseif w == 3 then return deepcopy(PARTS.legs[1]),     "legs"
  elseif w == 4 then return deepcopy(PARTS.rightArm[1]), "rightArm"  -- Blaster
  elseif w == 5 then return deepcopy(PARTS.head[1]),     "head"
  end
end

--  colour lookup for drawing floor parts
local partColours = {}
for _, list in pairs(PARTS) do
  for _, p in ipairs(list) do partColours[p.name] = p.colour end
end

--- dropWavePart() -------------------------------------------
--  Spawns the wave-specific part in the centre of the arena.
local function dropWavePart()
  local part, slot = dropForWave(G.wave)
  if part then
    table.insert(G.scrap,
      {x = W/2, y = H/2, w = 14, h = 14, part = part, slot = slot})
  end
end

--- pickupScrap() --------------------------------------------
--  Transfers any floor scrap touching the player into their bag.
local function pickupScrap()
  for i = #G.scrap, 1, -1 do
    if aabb(G.player, G.scrap[i]) then
      table.insert(G.player.bag, G.scrap[i])
      table.remove(G.scrap, i)
    end
  end
end

-------------------------------------------------------------- INPUT / EQUIP
--- love.keypressed(key) -------------------------------------
--  Handles number-key equipping and restart on victory/death.
function love.keypressed(k)
  -- restart after win/death
  if (G.dead or G.win) and k == "r" then love.event.quit("restart") end

  -- 1-5 equip keys
  local idx = tonumber(k)
  if idx and G.player.bag[idx] then
    local it = G.player.bag[idx]
    G.player.slots[it.slot] = it.part
    table.remove(G.player.bag, idx)

    -- recalc HP in case chassis changed
    G.player.maxHp = 100 + stat("hp")
    G.player.hp    = clamp(G.player.hp, 0, G.player.maxHp)
  end
end

-------------------------------------------------------------- UPDATE
--- love.update(dt) ------------------------------------------
--  Master game loop: handles timers, movement, collisions.
function love.update(dt)
  if G.dead or G.win then return end

  -- cooldown timers
  G.player.fireCd   = math.max(0, G.player.fireCd   - dt)
  G.player.contactCd= math.max(0, G.player.contactCd- dt)

  -- build-phase countdown & pickup handling
  if G.phase == "build" then
    G.timer = G.timer - dt
    pickupScrap()
    if G.timer <= 0 then G.phase = "fight"; spawnWave() end
  end

  -- player movement
  local vx, vy = 0, 0
  if lk.isDown("w") then vy = -1 end
  if lk.isDown("s") then vy =  1 end
  if lk.isDown("a") then vx = -1 end
  if lk.isDown("d") then vx =  1 end
  local spd = stat("speed")
  G.player.x = clamp(G.player.x + vx * spd * dt, 0, W - G.player.w)
  G.player.y = clamp(G.player.y + vy * spd * dt, 0, H - G.player.h)

  -- shooting
  if love.mouse.isDown(1) then tryShoot() end

  -- bullets update
  for i = #G.bullets, 1, -1 do
    local b = G.bullets[i]
    if b.beam then
      b.life = b.life - dt
      if b.life <= 0 then table.remove(G.bullets, i) end
    else
      b.x, b.y = b.x + b.vx * dt, b.y + b.vy * dt
      if b.x < -10 or b.x > W + 10 or b.y < -10 or b.y > H + 10 then
        table.remove(G.bullets, i)
      end
    end
  end

  -- enemy AI & collisions
  for ei = #G.enemies, 1, -1 do
    local e = G.enemies[ei]
    local dx, dy = G.player.x - e.x, G.player.y - e.y
    local dist = math.sqrt(dx*dx + dy*dy) + 1e-6
    e.x, e.y = e.x + dx/dist * e.speed * dt,
               e.y + dy/dist * e.speed * dt

    -- projectile damage
    for bi = #G.bullets, 1, -1 do
      local b = G.bullets[bi]
      if not b.beam and aabb(e, b) then
        e.hp = e.hp - b.dmg
        if not b.pierce then table.remove(G.bullets, bi) end
      end
    end

    -- touch damage
    if aabb(e, G.player) and G.player.contactCd == 0 then
      G.player.hp = G.player.hp - 15
      G.player.contactCd = 0.6
    end

    -- enemy death → heal player
    if e.hp <= 0 then
      G.player.hp = clamp(G.player.hp + 5, 0, G.player.maxHp)
      table.remove(G.enemies, ei)
    end
  end

  --:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: BOSS LOGIC
  if G.boss then
    -- volley of 20 minions every 2 seconds
    G.boss.spawnCd = G.boss.spawnCd - dt
    if G.boss.spawnCd <= 0 then
      G.boss.spawnCd = 2
      for i = 1, 20 do spawnEnemy() end
    end

    -- projectile hits on boss
    for bi = #G.bullets, 1, -1 do
      local b = G.bullets[bi]
      if not b.beam and aabb(G.boss, b) then
        G.boss.hp = G.boss.hp - b.dmg
        if not b.pierce then table.remove(G.bullets, bi) end
      end
    end

    -- boss touch damage
    if aabb(G.boss, G.player) and G.player.contactCd == 0 then
      G.player.hp = G.player.hp - 25
      G.player.contactCd = 0.6
    end

    -- boss death = win
    if G.boss.hp <= 0 then
      G.boss = nil
      G.win  = true
    end
  end

  -- wave completed
  if G.phase == "fight" and #G.enemies == 0 and not G.boss then
    G.phase = "build"
    G.timer = BUILD_TIME
    dropWavePart()
  end

  -- player death
  if G.player.hp <= 0 then G.dead = true end
end

-------------------------------------------------------------- DRAW
--- love.draw() ----------------------------------------------
--  Renders everything: beams, bullets, entities, UI.
function love.draw()
  lg.clear(colors.bg)

  -- beams (draw first, beneath bullets)
  for _, b in ipairs(G.bullets) do
    if b.beam then
      lg.setColor(0, 1, 1)
      lg.setLineWidth(2)
      lg.line(b.x, b.y,
              b.x + math.cos(b.angle) * W,
              b.y + math.sin(b.angle) * H)
    end
  end

  -- bullets
  lg.setColor(1, 1, 0)
  for _, b in ipairs(G.bullets) do
    if not b.beam then lg.rectangle("fill", b.x, b.y, 4, 4) end
  end

  -- enemies
  for _, e in ipairs(G.enemies) do
    lg.setColor(1, 0.25, 0.25)
    lg.rectangle("fill", e.x, e.y, e.w, e.h)

    -- HP bar
    lg.setColor(0, 0, 0)
    lg.rectangle("fill", e.x, e.y - 6, e.w, 4)
    lg.setColor(0, 1, 0)
    lg.rectangle("fill", e.x, e.y - 6, e.w * (e.hp / e.maxHp), 4)
  end

  -- boss
  if G.boss then
    lg.setColor(0.8, 0.2, 1)
    lg.rectangle("fill", G.boss.x, G.boss.y, G.boss.w, G.boss.h)
    lg.setColor(0, 0, 0)
    lg.rectangle("fill", G.boss.x, G.boss.y - 8, G.boss.w, 6)
    lg.setColor(0, 1, 1)
    lg.rectangle("fill", G.boss.x, G.boss.y - 8,
                 G.boss.w * (G.boss.hp / G.boss.maxHp), 6)
  end

  -- player (flashes white while invulnerable)
  lg.setColor(G.player.contactCd > 0 and {1, 1, 1} or {0.25, 1, 0.35})
  lg.rectangle("fill", G.player.x, G.player.y, G.player.w, G.player.h)

  -- floor parts
  for _, s in ipairs(G.scrap) do
    lg.setColor(partColours[s.part.name])
    lg.rectangle("fill", s.x, s.y, s.w, s.h)
  end

  --:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::: UI
  lg.setColor(colors.ui)
  lg.print(("HP: %d/%d  Wave: %d  Phase: %s")
           :format(G.player.hp, G.player.maxHp, G.wave, G.phase), 10, 10)

  -- backpack list
  local baseY, equipX = H - 100, 300
  lg.print("Backpack (1-5):", 10, baseY)
  for i, it in ipairs(G.player.bag) do
    lg.print(("%d) %s %s"):format(i, it.slot, it.part.name),
             10, baseY + i * lineH)
  end

  -- equipped list
  lg.print("Equipped:", equipX, baseY)
  for idx, slot in ipairs(SLOTS) do
    local part = G.player.slots[slot]
    lg.print(("%s: %s")
             :format(slot, part and part.name or "—"),
             equipX, baseY + idx * lineH)
  end

  -- centre banners
  if G.phase == "build" and not (G.dead or G.win) then
    lg.printf(("BUILD PHASE – equip part (%d)")
              :format(math.ceil(G.timer)),
              0, H/2 - 16, W, "center")
  elseif G.dead then
    lg.printf("YOU DIED – press R to restart",
              0, H/2 - 16, W, "center")
  elseif G.win then
    lg.printf("BOSS DOWN! GAME OVER – press R to restart",
              0, H/2 - 16, W, "center")
  end
end
