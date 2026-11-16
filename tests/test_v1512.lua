-- Bêta 1.5.12 (demande de Vincent du 12/11/2026) : SetupLab reste indépendante, lit AdvancedIA quand il est installé et en
-- marche (pont v1, clé AdvancedIA.session), publie SetupLab.state pour SpotterEnginer. Sans eux, rien ne change.
local T = require('t')
local Fake = require('fakehost')
local Util = require('src/util')
local Config = require('src/config')
local Companion = require('src/companion')
local Layout = require('src/bridge_layout')
local Optimizer = require('src/optimizer')
local Datasource = require('src/datasource')
local TrackModel = require('src/track_model')
local CarModel = require('src/car_model')
local Sim = require('src/laptime_sim')
local Recorder = require('src/recorder')

local K = Config.K
local SYNC = Util.syncContext()
local tests = {}

-- AdvancedIA simulé : manifeste, pont (ac.connect avec des tables à la place de la mémoire partagée), clé de séance, et
-- ac.store relevé. aia.installed = false : rien de tout cela.
local function fakeAia(h, aia)
  local root = 'C:/AC/apps/lua'
  h.ac.FolderID.ScriptOrigin = 990
  local getFolder = h.ac.getFolder
  h.ac.getFolder = function(id)
    if id == 990 then return root .. '/SetupLab' end
    return getFolder(id)
  end
  local exists, load = h.io.fileExists, h.io.load
  h.io.fileExists = function(path)
    if aia.installed and path == root .. '/AdvancedIA/manifest.ini' then return true end
    return exists(path)
  end
  h.io.load = function(path, default)
    if aia.installed and path == root .. '/AdvancedIA/manifest.ini' then return '[ABOUT]\nVERSION=Beta 1.63\n' end
    return load(path, default)
  end
  h.stores = {}
  h.ac.store = function(key, value)
    h.stores[#h.stores + 1] = { key = key, value = value }
    h.storeValues = h.storeValues or {}
    h.storeValues[key] = value
  end
  h.ac.load = function(key) return h.storeValues and h.storeValues[key] or nil end
  if aia.bridge ~= false then
    aia.hello = { bridgeVersion = 2, release = 'Beta 2.0.0', heartbeat = 0, closed = false }
    aia.data = { enabled = true, ready = true, online = false, replay = false, paused = false, panic = false, guard = '',
      wet = false, neutral = false, red = false, mandatoryStops = 0, maxStintMin = 0, cars = {} }
    h.connects = 0
    local S = {}
    for _, name in ipairs({ 'boolean', 'int32', 'uint32', 'float', 'double' }) do S[name] = function() return name end end
    S.string = function(n) return 'string' .. n end
    S.key = function(k) return { key = k } end
    S.array = function(item, n) return { array = item, n = n } end
    S.struct = function(t) return t end
    h.ac.StructItem = S
    h.ac.connect = function(t)
      h.connects = h.connects + 1
      if t.key.key == Layout.helloKey then return aia.hello end
      if t.key.key == Layout.dataKey then return aia.data end
      error('clé inconnue')
    end
  end
  -- battement : avancé à chaque appel (une image d'AdvancedIA)
  function aia.beat() aia.hello.heartbeat = aia.hello.heartbeat + 1 end
  function aia.session(text) h.storeValues = h.storeValues or {}; h.storeValues[Companion.SESSION_KEY] = text end
  return aia
end

local function boot(aia)
  local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza') })
  if aia then fakeAia(h, aia) end
  Fake.install(h)
  assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
  local app = rawget(_G, 'SETUPLAB').app
  app.settings.optBudgetEvalsQ, app.settings.optBudgetEvalsC = 80, 300
  -- horloge réelle du banc : le temps de simulation (le battement se juge en temps réel)
  app.clock = function() return h.sim.time / 1000 end
  return h, app
end

local function frames(h, n, aia)
  for _ = 1, n do
    h.sim.time = h.sim.time + 1000 / 60
    if aia and aia.beat and aia.hello and aia.alive ~= false then aia.beat() end
    script.SETUPLAB__UPDATE(1 / 60)
    script.SETUPLAB__MAIN(1 / 60)
  end
end

tests['CP01 sans AdvancedIA : rien d\'ouvert, rien d\'affiché, enregistreur inchangé'] = function()
  local h, app = boot(nil)
  frames(h, 30)
  T.eq(app.companion.installed, false)
  T.eq(app.companion.state, 'absent')
  T.no(app.companion.detected, 'non détecté')
  T.no(app.companionUsing)
  T.eq(app.recordContext.lapVerdict, nil, 'aucune attente de verdict')
  T.eq(app.recordContext.carIdle, nil, 'filtre de trafic inchangé')
  T.no(require('src/ui').companionShown(app), 'réglage AdvancedIA caché')
  T.eq(app.perf.errors, 0)
  -- installé, mais CSP sans ac.connect (0.2.11) : détecté (réglage affiché), pont non ouvert, aucune erreur
  local aia = { installed = true, bridge = false }
  h, app = boot(aia)
  frames(h, 30)
  T.ok(app.companion.installed)
  T.eq(app.companion.state, 'nobridge')
  T.ok(require('src/ui').companionShown(app), 'réglage AdvancedIA affiché (installé)')
  T.no(app.companionUsing)
  T.eq(app.perf.errors, 0)
end

tests['CP02 clé AdvancedIA.session : lecture tolérante, autre version ignorée'] = function()
  local s = Companion.parseSession('v=1;playerLapId=4;playerLapClean=1;reason=sc;lastLapId=3;lastLapClean=0;drsAllowed=0;'
    .. 'compoundChange=1;compoundsAllowed=1,2;wetWaived=0;costMs=1.8;aiLapMean=101.25;aiLapCount=40;rules=F1;session=C;futur=x')
  T.ok(s ~= nil)
  T.eq(s.lastLapId, 3)
  T.eq(s.lastLapClean, false)
  T.eq(s.playerLapClean, true)
  T.eq(s.reason, 'sc')
  T.eq(s.drsAllowed, false)
  T.eq(s.compoundChange, true)
  T.ok(s.compoundsAllowed[1] and s.compoundsAllowed[2] and not s.compoundsAllowed[0], 'composés permis')
  T.near(s.costMs, 1.8, 1e-9)
  T.eq(s.session, 'C')
  T.eq(Companion.parseSession('v=2;lastLapId=3'), nil, 'autre version')
  T.eq(Companion.parseSession(nil), nil)
  T.eq(Companion.parseSession(string.rep('x', 2000)), nil)
  -- format définitif d'AdvancedIA 1.63 (12/11/2026) : ordre, booléens 0/1, règles avec espaces, liste vide, fermeture
  local real = Companion.parseSession('v=1;session=Q;rules=F1 2026;playerLapId=5;playerLapClean=0;reason=yellow;'
    .. 'lastLapId=4;lastLapClean=1;drsAllowed=1;compoundChange=0;compoundsAllowed=;wetWaived=0;costMs=1.234;'
    .. 'aiLapMean=0.000;aiLapCount=0')
  T.eq(real.session, 'Q')
  T.eq(real.rules, 'F1 2026')
  T.eq(real.playerLapClean, false)
  T.eq(real.lastLapId, 4)
  T.eq(real.lastLapClean, true)
  T.eq(real.drsAllowed, true)
  T.eq(real.compoundsAllowed, nil, 'liste vide : pas de restriction')
  T.near(real.costMs, 1.234, 1e-9)
  local closed = Companion.parseSession('v=1;closed=1')
  T.eq(closed.lastLapClean, nil, 'fermeture : aucun verdict')
  local partial = Companion.parseSession('v=1;lastLapId=abc;compoundsAllowed=-')
  T.eq(partial.lastLapId, nil, 'champ illisible : absent')
  T.eq(partial.compoundsAllowed, nil, 'pas de restriction')
end

tests['CP03 liaison : battement, arrêt, fermeture, autre version, moteur suspendu'] = function()
  local aia = { installed = true }
  local h, app = boot(aia)
  frames(h, 10, aia)
  T.eq(app.companion.state, 'connected')
  T.ok(app.companionUsing, 'données utilisées')
  T.eq(h.connects, 2, 'pont ouvert une fois (deux structures)')
  T.ok(app.recordContext.lapVerdict ~= nil, 'verdict attendu au passage de ligne')
  T.ok(require('src/ui').companionShown(app))
  -- réglage décoché : SetupLab l'ignore
  app.settings.companionUse = false
  frames(h, 2, aia)
  T.no(app.companionUsing)
  T.eq(app.recordContext.lapVerdict, nil)
  app.settings.companionUse = true
  -- battement arrêté plus de 2,5 s (temps réel) : en attente
  aia.alive = false
  frames(h, 200, aia)
  T.eq(app.companion.state, 'waiting')
  T.no(app.companionUsing)
  aia.alive = true
  frames(h, 2, aia)
  T.eq(app.companion.state, 'connected')
  aia.data.paused = true
  frames(h, 1, aia)
  T.eq(app.companion.state, 'suspended')
  T.no(app.companionUsing, 'moteur suspendu : rien d\'utilisé')
  aia.data.paused = false
  aia.hello.bridgeVersion = 1
  frames(h, 1, aia)
  T.eq(app.companion.state, 'version', 'pont v1 (AdvancedIA 1.63) : refusé')
  aia.hello.bridgeVersion = 2
  aia.hello.closed = true
  frames(h, 1, aia)
  T.eq(app.companion.state, 'closed')
  T.eq(app.perf.errors, 0)
end

-- Enregistreur : environnement de conduite (comme tests/test_recorder.lua).
local envCache
local function env()
  if envCache == nil then
    local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza') })
    local raw = Datasource.sampleTrack(h, 1, SYNC)
    Datasource.probeBank(h, raw, SYNC)
    local files = Datasource.readTrackFiles(h, SYNC)
    local track = assert(TrackModel.build(raw, files, 2))
    local base = CarModel.build(Datasource.readCar(h, 0, SYNC), nil)
    local eff = assert(CarModel.configure(base, CarModel.defaultSetup(base), { airTemp = 25 }))
    local _, buf = Sim.run(track, eff, nil)
    local profile = { p = {}, v = {} }
    for k = 1, track.n do profile.p[k], profile.v[k] = track.p[k], buf.v[k] end
    profile.p[#profile.p + 1], profile.v[#profile.v + 1] = 1, buf.v[1]
    envCache = { h = h, track = track, profile = profile }
  end
  local h = envCache.h
  h.car.lapCount = 0
  h.car.isLapValid, h.car.isInPitlane, h.car.brakeBias = true, false, 0.62
  rawset(h, 'others', nil)
  return envCache
end

local function drive(e, laps, extra, hook)
  local h, dt, now = e.h, 1 / 60, 0
  local rec = Recorder.new()
  local finished = {}
  local context = { trackLength = e.track.length, conditions = { airTemp = 25, roadTemp = 32, roadGrip = 0.98 } }
  for k, v in pairs(extra or {}) do context[k] = v end
  local start, frame, after = h.car.lapCount, 0, 0
  while h.car.lapCount < start + laps + 1 or (rec.pending and after < 240) do
    if h.car.lapCount >= start + laps + 1 then after = after + 1 end
    frame = frame + 1
    if hook then hook(frame, h, now) end
    Fake.drive(h, e.profile, dt)
    now = now + dt
    local lap = Recorder.update(rec, h, now, function() return 'S1' end, context)
    if lap then finished[#finished + 1] = lap end
    assert(frame < 200000, 'conduite bloquée')
  end
  return finished
end

tests['CP04 tour neutralisé selon AdvancedIA : compté au chrono d\'AC seulement ; verdict absent : tour gardé'] = function()
  -- verdict publié 0,3 s après la ligne : tour 1 neutralisé, tour 2 propre
  local due, published = {}, {}
  local laps = drive(env(), 2, { lapVerdict = function(id) return published[id] end }, function(_, h, now)
    local id = h.car.lapCount - 1
    if id >= 1 and due[id] == nil then due[id] = now + 0.3 end
    for lapId, at in pairs(due) do
      if now >= at and published[lapId] == nil then
        if lapId == 1 then published[lapId] = false else published[lapId] = true end
      end
    end
  end)
  T.eq(#laps, 2)
  T.eq(laps[1].reason, Recorder.NEUTRAL_REASON, 'tour 1 neutralisé')
  T.no(laps[1].valid, 'hors analyse (calibration, rythme, consommation)')
  T.ok(laps[1].acValid, 'compté au chrono d\'AC')
  T.ok(laps[2].valid, 'tour 2 propre : ' .. tostring(laps[2].reason))
  -- verdict jamais publié : jugé sans lui après l'attente
  laps = drive(env(), 1, { lapVerdict = function() return nil end })
  T.eq(#laps, 1)
  T.ok(laps[1].valid, tostring(laps[1].reason))
  -- sans AdvancedIA : aucun changement
  laps = drive(env(), 1, nil)
  T.ok(laps[1].valid)
end

tests['CP05 trafic : voiture arrêtée selon AdvancedIA ignorée'] = function()
  local e = env()
  local function follow(_, h)
    local q = (h.car.splinePosition + 20 / e.track.length) % 1
    if rawget(h, 'others') == nil then h.others = { Fake.otherCar(q) } else h.others[1].splinePosition = q end
  end
  local laps = drive(e, 1, { carsCount = 2 }, follow)
  T.eq(laps[1].reason, Recorder.TRAFFIC_REASON, 'voiture proche : trafic')
  e = env()
  laps = drive(e, 1, { carsCount = 2, carIdle = function(i) return i == 1 end }, follow)
  T.ok(laps[1].valid, 'voiture arrêtée selon AdvancedIA : pas de trafic (' .. tostring(laps[1].reason) .. ')')
end

tests['CP06 règles de course : arrêts obligatoires et relais maximal plafonnent le relais'] = function()
  local cap, rules = Optimizer.ruleStintCap(30, {}, 100)
  T.eq(cap, 30)
  T.eq(rules, nil, 'sans règle')
  cap, rules = Optimizer.ruleStintCap(30, { ruleStops = 1 }, 100)
  T.eq(cap, 15)
  T.eq(rules.stops, 1)
  cap = Optimizer.ruleStintCap(31, { ruleStops = 2 }, 100)
  T.eq(cap, 11, 'trois relais de 11 tours au plus')
  cap = Optimizer.ruleStintCap(30, { ruleStops = 1, ruleMaxStintMin = 20 }, 100)
  T.eq(cap, 12, '20 min à 100 s le tour')
end

tests['CP07 changement de gomme obligatoire : meilleur composé permis différent du monté'] = function()
  local comparison = { { index = 0, J = 100.5 }, { index = 1, J = 100.0 }, { index = 2, J = 100.2 },
    { index = 3, J = 99.0, wet = true } }
  T.eq(Companion.pitCompound(1, nil, comparison, {}), 2, 'meilleur autre que le monté, jamais un composé pluie sur le sec')
  T.eq(Companion.pitCompound(1, { [0] = true, [1] = true }, comparison, {}), 0, 'composés permis par la règle')
  T.eq(Companion.pitCompound(1, nil, nil, { 0, 1, 2 }), 0, 'sans comparaison : premier autre composé')
  T.eq(Companion.pitCompound(1, { [1] = true }, comparison, { 0, 1 }), nil, 'aucun autre permis')
end

tests['CP08 SetupLab.state : contrat v1, 240 octets, réécrit seulement si une valeur change'] = function()
  local text = Companion.stateText({ kind = 'race', ver = 'e3', fuel = 104.26, fpl = 2.853, stint = 35, compound = 'M',
    hotF = 27.46, hotR = 27.9, tune = 'running', readyN = 3, stamp = 1234.6, pitc = 'H', stops = 1, tlap = 2, tdl = -0.317,
    tv = 'better', tch = 'aero', tid = 5, sess = 2 })
  T.eq(text, 'v=1;kind=race;ver=e3;fuel=104.3;fpl=2.85;stint=35;compound=M;phot=27.5,27.5,27.9,27.9;tune=running;readyN=3;'
    .. 'stamp=1235;pitc=H;stops=1;tlap=2;tdl=-0.32;tv=better;tch=aero;tid=5;sess=2')
  T.ok(#text <= K.companionStateMax)
  local empty = Companion.stateText({ kind = 'none', stamp = 10 })
  T.eq(empty, 'v=1;kind=none;ver=-;fuel=-1;fpl=-1;stint=-1;compound=-;phot=-1;tune=idle;readyN=0;stamp=10;pitc=-;stops=-1;'
    .. 'tlap=-1;tdl=-;tv=-;tch=-;tid=0;sess=-1')
  T.eq(Companion.stateText({ compound = 'a;b=c' }):match('compound=([^;]*)'), 'a_b_c', 'séparateurs retirés des noms')
  -- longueur maximale : noms longs coupés, total borné
  local long = Companion.stateText({ kind = 'quali', ver = string.rep('9', 30), compound = string.rep('X', 30),
    pitc = string.rep('Y', 30), fuel = 999.9, fpl = 99.99, stint = 999, hotF = 99.9, hotR = 99.9, readyN = 99999,
    stamp = 9999999, stops = 99, tlap = 999, tdl = -99.99, tv = 'better', tch = 'alignment', tid = 99999, tune = 'running',
    sess = 99 })
  T.ok(#long <= K.companionStateMax, 'au plus 240 octets : ' .. #long)
  -- publication : le stamp seul ne réécrit pas
  local c, writes = Companion.new(), {}
  local host = { ac = { store = function(k, v) writes[#writes + 1] = { k, v } end } }
  T.ok(Companion.publish(c, host, Companion.stateText({ kind = 'race', stamp = 1 })))
  T.no(Companion.publish(c, host, Companion.stateText({ kind = 'race', stamp = 2 })), 'stamp seul : pas réécrit')
  T.ok(Companion.publish(c, host, Companion.stateText({ kind = 'quali', stamp = 3 })))
  T.eq(#writes, 2)
  T.eq(writes[1][1], 'SetupLab.state')
  -- sans ac.store (CSP sans cette fonction) : rien
  T.no(Companion.publish(Companion.new(), { ac = {} }, 'v=1'))
end

tests['CP09 AdvancedIA en marche : règles lues, coût, pluie, composé du preset, SetupLab.state publié'] = function()
  local aia = { installed = true }
  local h, app = boot(aia)
  for _ = 1, 20000 do
    frames(h, 1, aia)
    if app.discoveryState == 'done' then break end
  end
  T.eq(app.discoveryState, 'done')
  aia.data.mandatoryStops, aia.data.maxStintMin = 1, 30
  aia.session('v=1;lastLapId=0;lastLapClean=1;drsAllowed=0;compoundChange=1;compoundsAllowed=;costMs=2.5;rules=Endurance;'
    .. 'session=C')
  frames(h, 60, aia)
  T.ok(app.companionUsing)
  local rules = Companion.rules(app.companion)
  T.eq(rules.stops, 1)
  T.eq(rules.maxStintMin, 30)
  T.ok(rules.compoundChange)
  T.eq(Companion.drsAllowed(app.companion), false)
  T.near(Companion.costMs(app.companion), 2.5, 1e-9)
  -- composé du preset : un autre que le monté
  local target = app.companionPitTarget({ TYRES = 1, PRESSURE_LF = 26 })
  T.ok(target.TYRES ~= 1 and type(target.TYRES) == 'number', 'autre composé : ' .. tostring(target.TYRES))
  T.eq(target.PRESSURE_LF, 26, 'pressions gardées')
  -- sans obligation : valeurs inchangées (même table)
  aia.session('v=1;compoundChange=0')
  frames(h, 40, aia)
  local same = { TYRES = 1 }
  T.ok(app.companionPitTarget(same) == same)
  -- SetupLab.state publié, texte au contrat
  local text = h.storeValues and h.storeValues['SetupLab.state']
  T.ok(type(text) == 'string' and text:find('^v=1;kind=') ~= nil, tostring(text))
  T.ok(#text <= K.companionStateMax)
  T.eq(app.perf.errors, 0)
end

tests['CP10 mode inerte (replay) : SetupLab.state jamais écrit'] = function()
  local aia = { installed = true }
  local h, app = boot(aia)
  frames(h, 30, aia)
  h.sim.isReplayActive = true
  local n = nil
  for _ = 1, 400 do
    frames(h, 1, aia)
    if app.inert and n == nil then n = #h.stores end
  end
  T.ok(app.inert ~= nil, 'inerte en replay')
  -- une valeur change pendant le replay : rien n'est écrit
  app.lastLoadKind = 'race'
  frames(h, 120, aia)
  T.eq(#h.stores, n, 'aucune écriture en mode inerte')
end

-- Avis de wattu (Overtake, 10/11/2026, « Setup not saved: current setup unreadable »), reproduit au banc le 12/11/2026 :
-- seul un CSP qui rend une copie vide du setup en cours partout le produit (pas seulement dans la coroutine de la
-- découverte : la relecture au clic suffisait déjà). Message : cause et action ; réponse de CSP au journal.
tests["WA01 copie vide du setup en cours : enregistrement refusé avec la cause et l'action ; vide en tâche seulement : enregistré"] =
    function()
  local function run(everywhere)
    local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza') })
    local real = h.ac.stringifyCurrentSetup
    h.ac.stringifyCurrentSetup = function(...)
      if everywhere or coroutine.running() ~= nil then return '' end
      return real(...)
    end
    Fake.install(h)
    assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
    local app = rawget(_G, 'SETUPLAB').app
    app.settings.optBudgetEvalsQ = 80
    for _ = 1, 60000 do
      frames(h, 1)
      if app.discoveryState == 'done' then break end
    end
    app.handleIntents({ qualiStart = true })
    for _ = 1, 60000 do
      frames(h, 1)
      if app.quali and app.quali.state == 'done' then break end
    end
    T.eq(app.quali and app.quali.state, 'done', 'calcul')
    app.handleIntents({ qualiSave = true })
    return h, app
  end
  local h, app = run(true)
  T.ok(app.ui.message:find('copie vide du setup en cours', 1, true), app.ui.message)
  T.ok(app.ui.message:find('rapport J0', 1, true), 'action dite')
  local L = require('src/i18n')
  L.set('en')
  T.ok(L.t(app.ui.message):find('CSP returned an empty copy', 1, true), 'traduit : ' .. L.t(app.ui.message))
  L.set('fr')
  local logged = false
  for _, line in ipairs(h.cspLog) do
    if line:find('stringifyCurrentSetup : découverte vide, relecture vide', 1, true) then logged = true end
  end
  T.ok(logged, 'réponse de CSP au journal')
  h, app = run(false)
  T.ok(app.saved.quali ~= nil, 'vide dans la tâche seulement : enregistré (' .. tostring(app.ui.message) .. ')')
end

tests['CP12 pont v2 (AdvancedIA 2.0.0) : voiture abandonnée ignorée dans le trafic'] = function()
  local c = Companion.new()
  c.installed, c.opened = true, true
  c.hello = { bridgeVersion = 2, heartbeat = 1, closed = false }
  local cars = {}
  cars[1] = { valid = true, halt = false, onTrack = true, retired = false, lastReason = 5 }
  cars[2] = { valid = true, halt = false, onTrack = true, retired = true, lastReason = 0 }
  cars[3] = { valid = false, retired = true }
  c.data = { enabled = true, ready = true, wet = false, mandatoryStops = 0, maxStintMin = 0, trackWarnings = 3,
    serveLaps = 3, cars = cars }
  Companion.step(c, { ac = { load = function() return 'v=1;lastLapId=3;lastLapClean=1' end } }, 0)
  T.eq(c.state, 'connected')
  T.no(Companion.carIdle(c, 1), 'en course, même sanctionnée : trafic')
  T.ok(Companion.carIdle(c, 2), 'abandonnée : ignorée')
  T.no(Companion.carIdle(c, 3), 'entrée non valide : rien supposé')
end

tests['CP11 liaison connectée : aucune table créée par image (lecture du pont, voitures du trafic)'] = function()
  local c = Companion.new()
  c.installed, c.opened = true, true
  c.hello = { bridgeVersion = 2, heartbeat = 1, closed = false }
  local cars = {}
  for i = 0, 3 do cars[i] = { valid = true, halt = i == 2, onTrack = true } end
  c.data = { enabled = true, ready = true, wet = false, mandatoryStops = 1, maxStintMin = 0, cars = cars }
  local host = { ac = { load = function() return 'v=1;lastLapId=3;lastLapClean=1' end } }
  Companion.step(c, host, 0)
  T.eq(c.state, 'connected')
  local frame = 0
  local function run(n)
    for _ = 1, n do
      frame = frame + 1
      c.hello.heartbeat = frame + 1
      -- clé relue toutes les 0,5 s : texte inchangé, rien de relu
      Companion.step(c, host, frame / 60)
      for i = 1, 3 do Companion.carIdle(c, i) end
    end
  end
  -- traces de LuaJIT : objets du ramasse-miettes créés à leur compilation (une fois, selon l'ordre des tests) ; mesure
  -- des tables et chaînes du code seulement, compilateur arrêté
  local jit = rawget(_G, 'jit')
  if jit then jit.off() end
  run(600)
  collectgarbage('collect')
  collectgarbage('stop')
  local before = collectgarbage('count')
  run(6000)
  local kb = collectgarbage('count') - before
  collectgarbage('restart')
  if jit then jit.on() end
  T.ok(kb < 1, string.format('%.2f Ko alloués en 6000 images', kb))
  T.ok(Companion.carIdle(c, 2), 'voiture arrêtée')
  T.no(Companion.carIdle(c, 1))
end

tests['HC01 appel de CSP depuis une tâche : nombre exact d\'arguments (ac.hasTrackSpline, journal du 13/11)'] = function()
  local seen = {}
  local function strict(n)
    return function(...)
      seen[#seen + 1] = select('#', ...)
      if select('#', ...) ~= n then error('wrong number of arguments for function call') end
      return 'ok' .. n
    end
  end
  local s = Util.schedulerNew()
  local got = {}
  Util.schedulerAdd(s, 'hc', function()
    got[1] = { Util.callHost(strict(0)) }
    got[2] = { Util.callHost(strict(1), 7) }
    got[3] = { Util.callHost(strict(2), nil, nil) }
    got[4] = { Util.callHost(strict(5), 1, 2, 3, 4, 5) }
    return true
  end)
  for _ = 1, 10 do Util.schedulerStep(s, nil, 0, 100) end
  T.eq(#seen, 4, 'quatre appels faits sur le fil principal')
  T.eq(seen[1], 0)
  T.eq(seen[2], 1)
  T.eq(seen[3], 2, 'nil explicites comptés')
  T.eq(seen[4], 5)
  for i, n in ipairs({ 0, 1, 2, 5 }) do
    T.ok(got[i][1] == true and got[i][2] == 'ok' .. n, 'appel ' .. i .. ' : ' .. tostring(got[i][2]))
  end
  -- géométrie du circuit lue en tâche avec une ligne IA stricte (fakehost)
  local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza') })
  local t = nil
  Util.schedulerAdd(s, 'track', function(c) t = Datasource.sampleTrack(h, 10, c); return true end)
  for _ = 1, 2000 do
    Util.schedulerStep(s, nil, 0, 1000)
    if t then break end
  end
  T.ok(t ~= nil and t.ok, 'ligne IA lue en tâche : ' .. tostring(t and t.reason))
end

tests['NM01 noms de réglages du scan des voitures : reconnus, jamais optimisés ni ouverts par une mesure'] = function()
  local Space = require('src/setup_space')
  local expect = {
    ARB_F = 'carNamed', ARB_R = 'carNamed', SPRING_LF = 'carNamed', BUMPSTOP_RR = 'carNamed',
    DAMPER_BUMP_LF = 'carNamed', DAMPER_FAST_REBOUND_RR = 'carNamed', PACKER_RANGE_HF = 'heaveStop',
    BUMPSTOP_HR = 'heaveStop', MGUK_DELIVERY = 'ers', MGUK_RECOVERY = 'ers', MGUH_MODE = 'ers', TURBO = 'turbo',
    BRAKE_ENGINE = 'engineBrake', STEER_ASSIST = 'steerAssist', GEARSET = 'gearset', ABOUT = 'info',
    INTERNAL_GEAR_3 = 'gear', FINAL_RATIO = 'final',
  }
  for name, kind in pairs(expect) do
    local r = Space.classify(name)
    T.eq(r.kind, kind, name)
    if kind ~= 'gear' and kind ~= 'final' then
      T.eq(r.class, Space.EXCLUDED, name .. ' conservé')
      T.ok(type(r.reason) == 'string' and r.reason ~= Space.KEPT.unknown, name .. ' : raison propre')
    end
  end
  -- noms d'AC inchangés
  T.eq(Space.classify('ARB_FRONT').kind, 'arb')
  T.eq(Space.classify('SPRING_RATE_LF').kind, 'spring')
  T.eq(Space.classify('PACKER_RANGE_LF').kind, 'packer')
  T.eq(Space.classify('ENGINE_MAPS').kind, 'engineMap')
  T.eq(Space.classify('CUSTOM_SCRIPT_ITEM_7').kind, 'script')
  -- une mesure de rugosité ouvre les ressorts d'AC, jamais un nom propre à la voiture
  local spinners = {
    { name = 'SPRING_RATE_LF', label = 'Ressort', min = 0, max = 10, step = 1, value = 5 },
    { name = 'SPRING_LF', label = 'Spring LF', min = 0, max = 10, step = 1, value = 5 },
  }
  local space = Space.build({ spinners = spinners })
  Space.release(space, 'spring', Space.REDUCED, 'test')
  for _, var in ipairs(space.vars) do
    if var.kind == 'carNamed' then
      T.eq(var.class, Space.EXCLUDED, 'nom propre resté conservé')
      T.eq(var.label, 'Spring LF', 'libellé de CSP affiché')
    end
  end
  -- chaque raison nouvelle est traduite
  local L = require('src/i18n')
  for _, key in ipairs({ 'carNamed', 'heaveStop', 'ers', 'turbo', 'engineBrake', 'gearset', 'info' }) do
    T.ok(require('src/lang_en')[Space.KEPT[key]] ~= nil, 'traduction : ' .. key)
  end
  T.ok(L ~= nil)
end

tests['EM01 carte ERS : zones en couleurs (part déployée, profil, franchissement de la ligne), proportions, autre tracé refusé'] = function()
  local ErsMap = require('src/ers_map')
  -- tracé en ellipse de 1000 m, 400 points, deux fois plus large que haut
  local t = { n = 400, x = {}, z = {}, s = {}, length = 1000, closed = true }
  for k = 1, t.n do
    local a = (k - 1) / t.n * 2 * math.pi
    t.x[k], t.z[k], t.s[k] = 200 * math.cos(a), 100 * math.sin(a), (k - 1) / t.n * 1000
  end
  local zones = { { s0 = 100, s1 = 300, fraction = 0.5 }, { s0 = 500, s1 = 600, profile = true }, { s0 = 900, s1 = 50 } }
  T.eq(ErsMap.stateAt(zones, 150, 1000), ErsMap.DEPLOY, 'début de zone déployé')
  T.eq(ErsMap.stateAt(zones, 250, 1000), ErsMap.NONE, 'fin de zone (½) sans déploiement')
  T.eq(ErsMap.stateAt(zones, 550, 1000), ErsMap.PROFILE)
  T.eq(ErsMap.stateAt(zones, 980, 1000), ErsMap.DEPLOY, 'zone qui franchit la ligne, avant')
  T.eq(ErsMap.stateAt(zones, 20, 1000), ErsMap.DEPLOY, 'zone qui franchit la ligne, après')
  T.eq(ErsMap.stateAt(zones, 700, 1000), ErsMap.NONE)
  local map = assert(ErsMap.build(t, zones, true))
  T.ok(map.n <= ErsMap.MAX_POINTS and map.n >= 100, 'sous-échantillonné : ' .. map.n)
  T.near(map.aspect, 0.5, 0.02, 'proportions gardées')
  for j = 1, map.n do T.ok(map.x[j] >= 0 and map.x[j] <= 1 and map.y[j] >= 0 and map.y[j] <= 1) end
  T.ok(map.deployed > 0)
  T.ok(map.dirY > 0, 'sens de marche (z croissant au départ)')
  -- zones d'un autre tracé (plus long) : refus
  local m2, why = ErsMap.build(t, { { s0 = 100, s1 = 5000 } }, true)
  T.eq(m2, nil)
  T.contains(why, 'autre tracé')
  T.eq((ErsMap.build(t, {}, true)), nil, 'sans zone')
  T.eq((ErsMap.build({ n = 3, x = {}, z = {}, s = {}, length = 10 }, zones, true)), nil, 'tracé trop court')
end

tests['EM02 carte ERS dessinée dans l\'onglet QUALIF (voiture hybride), absente sans ERS ; construite une fois'] = function()
  local function bootSkin(carId)
    local h = Fake.new({ car = require('fixtures/cars/' .. carId), track = require('fixtures/tracks/monza'), skin = true,
      kers = true })
    h.sim.raceSessionType = 1
    h.texts = {}
    local text = h.ui.text
    h.ui.text = function(s) h.texts[#h.texts + 1] = s; return text(s) end
    Fake.install(h)
    assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
    local app = rawget(_G, 'SETUPLAB').app
    app.settings.optBudgetEvalsQ = 60
    return h, app
  end
  local function run(h, n)
    for _ = 1, n do
      h.sim.time = h.sim.time + 1000 / 60
      h.texts = {}
      script.SETUPLAB__UPDATE(1 / 60)
      script.SETUPLAB__MAIN(1 / 60)
    end
  end
  local function shown(h, needle)
    for _, s in ipairs(h.texts) do if type(s) == 'string' and s:find(needle, 1, true) then return true end end
    return false
  end
  local h, app = bootSkin('urd_px1_aura')
  for _ = 1, 40000 do
    run(h, 1)
    if app.discoveryState == 'done' then break end
  end
  T.ok(app.discovery.ers and app.discovery.ers.enabled, 'ERS simulé')
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = true, true, 0
  app.handleIntents({ qualiStart = true })
  for _ = 1, 200000 do
    run(h, 1)
    if app.quali and app.quali.state ~= 'running' then break end
  end
  T.eq(app.quali.state, 'done', tostring(app.quali.error))
  T.ok(app.quali.result.ers and #app.quali.result.ers.proposed.zones > 0, 'zones de déploiement')
  h.width, h.tab = 764, 'Tour rapide'
  run(h, 2)
  T.ok(shown(h, 'à confirmer en jeu'), 'panneau ERS affiché')
  T.ok(shown(h, 'Programme de déploiement conseillé'), 'programme conseillé')
  -- carte construite une fois par résultat, pas à chaque image
  local ErsMap = require('src/ers_map')
  local build, calls = ErsMap.build, 0
  ErsMap.build = function(...) calls = calls + 1; return build(...) end
  run(h, 30)
  ErsMap.build = build
  T.eq(calls, 0, 'carte en cache')
  -- voiture sans ERS : pas de panneau
  local h2, app2 = bootSkin('lamborghini_huracan_gt3_evo2')
  for _ = 1, 40000 do
    run(h2, 1)
    if app2.discoveryState == 'done' then break end
  end
  h2.width, h2.tab = 764, 'Tour rapide'
  run(h2, 2)
  T.no(shown(h2, 'à confirmer en jeu'), 'pas de carte sans ERS')
end

tests['GA01 fichier aux noms INTERNAL_GEAR_n / FINAL_RATIO : valeurs relues sous les noms des crans (retouches, signatures)'] = function()
  local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza'),
    gearNames = 'internal' })
  Fake.install(h)
  assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
  local app = rawget(_G, 'SETUPLAB').app
  local text = h.ac.stringifyCurrentSetup(true, false)
  T.contains(text, '[INTERNAL_GEAR_2]', 'fichier aux noms de CSP')
  local v = app.setupValues(text)
  local spinners = h.ac.getSetupSpinners()
  local seen = 0
  for _, sp in ipairs(spinners) do
    if sp.name:match('^GEAR_%d+$') or sp.name == 'FINAL_GEAR_RATIO' then
      T.eq(v[sp.name], sp.value, sp.name .. ' relu sous le nom du cran')
      seen = seen + 1
    end
  end
  T.ok(seen >= 2, 'rapports vus : ' .. seen)
  T.eq(v.INTERNAL_GEAR_2, nil, 'alias rangé sous le nom du cran')
  -- décalage d'un cran (audit du 14/11/2026) : aucune vitesse en trop
  local top = 0
  for _, sp in ipairs(spinners) do local n = tonumber(sp.name:match('^GEAR_(%d+)$')); if n and n > top then top = n end end
  T.eq(v['GEAR_' .. (top + 1)], nil, 'pas de GEAR_' .. (top + 1))
  T.eq(v.FINAL_RATIO, nil)
end

tests['IM01 calcul impossible pour de bon : la carte d\'étape le dit (raison, une action), plus d\'étape « Départ »'] = function()
  local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza') })
  h.sim.raceSessionType = 1
  Fake.install(h)
  assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
  local app = rawget(_G, 'SETUPLAB').app
  for _ = 1, 40000 do
    h.sim.time = h.sim.time + 1000 / 60
    script.SETUPLAB__UPDATE(1 / 60)
    if app.discoveryState == 'done' then break end
  end
  local Ui = require('src/ui')
  T.eq(app.qualiImpossible(), nil, 'voiture lisible : possible')
  local m = Ui.stepModel(app, 'Tour rapide')
  T.eq(m.step, 1, 'étape Départ')
  local saved = app.discovery.optimizable
  app.discovery.optimizable = {}
  m = Ui.stepModel(app, 'Tour rapide')
  T.eq(m.title, 'Calcul impossible avec cette voiture')
  T.contains(m.text, 'aucun réglage optimisable')
  T.eq(#m.actions, 1)
  T.ok(m.actions[1].intent.rediscover, 'relancer la découverte')
  T.eq(m.step, nil, 'pas d\'étape à suivre')
  -- circuit pas encore appris (un tour le donne) : pas « impossible »
  app.discovery.optimizable = saved
  local track = app.discovery.trackModel
  app.discovery.trackModel = nil
  T.eq(app.qualiImpossible(), nil, 'circuit à apprendre d\'un tour : pas impossible')
  app.discovery.trackModel = track
end

tests["RJ01 course lancée : la version en piste n'est pas écartée (rien ne se recharge en course, analyse gardée)"] = function()
  local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza') })
  Fake.install(h)
  assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
  local app = rawget(_G, 'SETUPLAB').app
  for _ = 1, 40000 do
    h.sim.time = h.sim.time + 1000 / 60
    script.SETUPLAB__UPDATE(1 / 60)
    if app.discoveryState == 'done' then break end
  end
  h.sim.isSessionStarted = true
  app.context.sessionType = K.sessionTypeRace
  T.ok(app.raceRunning(), 'course lancée')
  local e = { version = 1, signature = 'x', text = "[FUEL]\nVALUE=10\n" }
  app.refine = { kind = 'race', active = true, driven = 1, version = 1, history = { e } }
  app.handleIntents({ refineJudge = { version = 1, verdict = 'écarter' } })
  T.eq(e.status, nil, 'version gardée à juger')
  T.contains(app.ui.message, "jugez-la à l'arrivée")
end

tests['FN01 nom choisi qui finit par le genre (autre casse) ou réduit au genre : versions reconnues dans le nom'] = function()
  local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza') })
  Fake.install(h)
  assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
  local app = rawget(_G, 'SETUPLAB').app
  -- l'écriture du joueur est gardée (test RG01) ; ses versions sont reconnues quelle que soit la casse
  for _, name in ipairs({ 'spa_quali', 'Monza_QUALIF', 'Quali', 'spa_Qualif' }) do
    app.names.quali = name
    local base = app.fileBase('quali', 'sec')
    T.eq(base, name, 'nom gardé')
    local genre = name:lower():find('qualif$') and 'Qualif' or 'Quali'
    T.eq(Util.versionInName(base .. '_v3.ini', genre), 3, name .. ' : version reconnue')
    T.eq(Util.versionInName(base .. '_Pluie_v4.ini', genre), 4, name .. ' : version de pluie reconnue')
  end
  T.eq(Util.versionInName('spa_Qualif_v2.ini', 'Quali'), nil, 'Qualif n\'est pas Quali')
end

return tests
