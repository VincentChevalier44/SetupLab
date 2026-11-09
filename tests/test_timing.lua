-- Chrono d'AC publié en retard, stockage des identifiants de mods, grip du rapport J0 (relecture du 09/11/2026).
local T = require('t')
local Util = require('src/util')
local Config = require('src/config')
local Datasource = require('src/datasource')
local TrackModel = require('src/track_model')
local CarModel = require('src/car_model')
local Sim = require('src/laptime_sim')
local Recorder = require('src/recorder')
local Fake = require('fakehost')
local K = Config.K
local SYNC = Util.syncContext()
local tests = {}

local function setup()
  local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza') })
  local raw = Datasource.sampleTrack(h, 1, SYNC)
  local track = assert(TrackModel.build(raw, Datasource.readTrackFiles(h, SYNC), 2))
  local base = CarModel.build(Datasource.readCar(h, 0, SYNC), nil)
  local eff = assert(CarModel.configure(base, CarModel.defaultSetup(base), { airTemp = 25 }))
  local result, buf = Sim.run(track, eff, nil)
  local profile = { p = {}, v = {} }
  for k = 1, track.n do profile.p[k], profile.v[k] = track.p[k], buf.v[k] end
  profile.p[#profile.p + 1], profile.v[#profile.v + 1] = 1, buf.v[1]
  return h, track, profile
end

-- Conduit `laps` tours ; scale(lapCount) : facteur de vitesse du tour en cours (temps du tour différent d'un tour à l'autre).
-- Renvoie les tours enregistrés et les temps réels (previousLapTimeMs finaux) relevés par le faux hôte.
local function run(h, track, profile, laps, scale)
  local base = {}
  for i, v in ipairs(profile.v) do base[i] = v end
  local rec = Recorder.new()
  local ctx = { trackLength = track.length, conditions = { airTemp = 25, roadTemp = 32, roadGrip = 0.98 } }
  local now, dt, out, truth, extra, lastCount = 0, 1 / 60, {}, {}, 0, h.car.previousLapTimeMs
  local start = h.car.lapCount
  local applied = nil
  while h.car.lapCount < start + laps + 1 or (rec.pending and extra < 200) do
    if h.car.lapCount >= start + laps + 1 then extra = extra + 1 end
    local f = scale(h.car.lapCount - start)
    if f ~= applied then
      for i, v in ipairs(base) do profile.v[i] = v * f end
      applied = f
    end
    Fake.drive(h, profile, dt)
    now = now + dt
    if h.car.previousLapTimeMs ~= lastCount then
      lastCount = h.car.previousLapTimeMs
      truth[#truth + 1] = lastCount / 1000
    end
    local lap = Recorder.update(rec, h, now, function() return 'S1', 'F1' end, ctx)
    if lap then out[#out + 1] = lap end
  end
  -- quelques images de plus : le temps officiel en retard du dernier tour arrive
  for _ = 1, 10 do
    Fake.drive(h, profile, dt)
    if h.car.previousLapTimeMs ~= lastCount then
      lastCount = h.car.previousLapTimeMs
      truth[#truth + 1] = lastCount / 1000
    end
  end
  for i, v in ipairs(base) do profile.v[i] = v end
  return out, truth
end

tests['TM01 temps officiel en retard, deux tours à moins de 0,1 s : chacun son temps'] = function()
  local h, track, profile = setup()
  h.lateLapTimeFrames = 3
  -- tour 1 (lapCount 1 -> 2) au rythme nominal, tour 2 un peu plus lent (≈ +60 ms)
  local times = {}
  local laps, truth = run(h, track, profile, 2, function(i) return i == 2 and 0.99945 or 1 end)
  PY.note('TM1t', 'temps reels (previousLapTimeMs successifs) : ' .. table.concat(truth, ' / '))
  T.eq(#laps, 2)
  for i, lap in ipairs(laps) do times[i] = lap.time end
  -- durée réelle de chaque tour : le chrono de simulation de l'enregistreur (référence exacte du faux hôte)
  local d = times[2] - times[1]
  PY.note('TM1', 'tour 1 ' .. Util.fmt(times[1], 3) .. ' s, tour 2 ' .. Util.fmt(times[2], 3) .. ' s')
  T.ok(d > 0.03, 'le tour 2 (plus lent de ≈ 60 ms) doit avoir son propre temps ; écart retenu ' .. Util.fmt(d, 3) .. ' s')
end

tests['TM02 chrono remis à zéro 2 images après le compteur, temps officiel en retard : temps juste'] = function()
  local h, track, profile = setup()
  h.lateLapTimeFrames, h.lateTimerResetFrames = 3, 2
  local laps, truth = run(h, track, profile, 2, function(i) return i == 2 and 1.01 or 1 end)
  PY.note('TM2t', 'temps reels (previousLapTimeMs successifs) : ' .. table.concat(truth, ' / '))
  T.eq(#laps, 2)
  PY.note('TM2', 'tour 1 ' .. Util.fmt(laps[1].time, 3) .. ' s, tour 2 ' .. Util.fmt(laps[2].time, 3) .. ' s')
  T.ok(laps[1].time - laps[2].time > 0.5, 'tour 2 plus rapide d\'≈ 1 s : temps retenu ' .. Util.fmt(laps[2].time, 3))
end

tests['TM00 temps officiel à l\'heure : temps justes'] = function()
  local h, track, profile = setup()
  local laps, truth = run(h, track, profile, 2, function(i) return i == 2 and 0.99945 or 1 end)
  PY.note('TM0t', table.concat(truth, ' / ') .. ' ; retenus ' .. Util.fmt(laps[1].time, 3) .. ' / ' .. Util.fmt(laps[2].time, 3))
  T.ok(laps[2].time - laps[1].time > 0.03)
end

local Store = require('src/store')
tests['TM03 stockage : identifiant de mod (espace, parenthèses, accents) relu au relancement'] = function()
  for _, carId in ipairs({ 'rss formula hybrid', 'f2004 (v2)', 'porsche_911+', 'ks_nurburgring_é' }) do
    T.ok(Util.isSafeId(carId), 'isSafeId accepte ' .. carId)
    local key = Store.entryKey('cal', carId, 'monza', '-', 0)
    T.ok(key ~= nil, 'clé formée pour ' .. carId)
    local store = { entries = {}, dirty = false }
    T.ok(Store.put(store, key, { mu = 1.0, laps = 3 }, 1000))
    local text = Store.serialize(store.entries)
    local back, why = Store.parse(text)
    T.ok(back[key] ~= nil, 'entrée relue pour « ' .. carId .. ' » (' .. tostring(why) .. ')')
  end
end

-- Clés relues : seulement celles que Store.entryKey forme (octets hors UTF-8, séparateurs, genre absent : refusées).
tests['TM07 stockage : clé relue de la forme de Store.entryKey, UTF-8 bien formé'] = function()
  T.no(Util.isSafeId('voiture\215x'), 'octet isolé hors UTF-8')
  T.ok(Util.isSafeId('ks_nürburgring'), 'accent en UTF-8')
  T.eq(Store.entryKey('cal', 'voiture\215x', 'monza'), nil)
  local back = Store.parse('setuplab-store 1|cal:voiture\215x:monza#mu=1|cal:ok car:monza#mu=1|:monza#mu=1|cal::monza#mu=1')
  local keys = {}
  for key in pairs(back) do keys[#keys + 1] = key end
  T.eq(#keys, 1, 'une seule clé valide')
  T.ok(back['cal:ok car:monza'] ~= nil)
end

local Caps = require('src/caps')
tests['TM04 rapport J0 : grip lu en pour cent affiché tel quel'] = function()
  local caps = Caps.evaluate({}, { session = { ok = true, flags = {}, session = {},
    values = { roadGrip = 98, ambientTemperature = 24, roadTemperature = 32 } } })
  local detail = caps.byId.conditions.detail
  PY.note('TM4', detail)
  T.no(detail:find('9800', 1, true), 'grip affiché tel quel ×100 : ' .. detail)
end

tests['TM05 compteur en retard, temps officiel à l\'heure : aucune attente ajoutée'] = function()
  local h, track, profile = setup()
  h.lateLapCountFrames = 1
  local rec = Recorder.new()
  local ctx = { trackLength = track.length, conditions = { airTemp = 25 } }
  local now, waited, maxWait = 0, 0, 0
  local laps = 0
  local base = {}
  for i, v in ipairs(profile.v) do base[i] = v end
  for _ = 1, 60 * 400 do
    -- tours tous différents (temps officiels distincts)
    local f = 1 - 0.0005 * (h.car.lapCount % 3)
    for i, v in ipairs(base) do profile.v[i] = v * f end
    Fake.drive(h, profile, 1 / 60)
    now = now + 1 / 60
    local lap = Recorder.update(rec, h, now, function() return 'S1', 'F1' end, ctx)
    if rec.pending then waited = waited + 1 else waited = 0 end
    if waited > maxWait then maxWait = waited end
    if lap then laps = laps + 1 end
    if laps >= 2 then break end
  end
  for i, v in ipairs(base) do profile.v[i] = v end
  PY.note('TM5', 'images d attente au plus : ' .. maxWait)
  T.ok(maxWait <= 3, 'attente ' .. maxWait .. ' images')
end

-- Temps affichés : arrondis au millième avant le découpage en minutes (une moyenne, un temps simulé ne sont pas des
-- millièmes entiers).
tests['TM06 temps au tour affiché : arrondi au millième, jamais « 1:60.000 »'] = function()
  local U = require('src/ui')
  T.eq(U.lapTime(119.9996), '2:00.000')
  T.eq(U.lapTime(59.99951), '1:00.000')
  T.eq(U.lapTime(86.374), '1:26.374')
  T.eq(U.lapTime(87.3054), '1:27.305')
  T.eq(U.lapTime(0 / 0), '—')
end

return tests
