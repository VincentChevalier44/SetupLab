-- Bêta 1.5.11 (audit adversarial du 12/11/2026, « tu corriges absolument tout ») : chaque correction a son test.
local T = require('t')
local Fake = require('fakehost')
local Util = require('src/util')

local tests = {}

local function boot(opts)
  opts = opts or {}
  local h = Fake.new({ car = require('fixtures/cars/' .. (opts.car or 'lamborghini_huracan_gt3_evo2')),
    track = require('fixtures/tracks/' .. (opts.track or 'monza')) })
  if opts.setup then opts.setup(h) end
  Fake.install(h)
  assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
  local app = rawget(_G, 'SETUPLAB').app
  app.settings.optBudgetEvalsQ, app.settings.optBudgetEvalsC = 80, 300
  return h, app
end

local function frames(h, n)
  for _ = 1, n do
    h.sim.time = h.sim.time + 1000 / 60
    script.SETUPLAB__UPDATE(1 / 60)
    script.SETUPLAB__MAIN(1 / 60)
  end
end

local function waitFor(h, predicate, maxFrames)
  for i = 1, maxFrames or 60000 do
    frames(h, 1)
    if predicate() then return i end
  end
  return nil
end

-- Issue n° 2 (rapports 1.5.10 du 11/11/2026, CSP 0.2.11) : ac.getFolder réussissait au lancement de l'app et rendait nil
-- pendant la découverte ; ac.getCarDataFiles et ac.getSetupSpinners y rendaient un nombre, les INI de la voiture et du
-- circuit du vide. La découverte tourne dans une coroutine : ses appels de CSP passent maintenant par le fil principal.
tests['IS05 CSP 0.2.11 : lectures de CSP faites hors coroutine pendant la découverte'] = function()
  T.eq(coroutine.running(), nil, 'le banc tourne sur le fil principal')
  local inTask = 0
  local function mainOnly(fn, bad)
    return function(...)
      if coroutine.running() ~= nil then
        inTask = inTask + 1
        return bad
      end
      return fn(...)
    end
  end
  local h, app = boot({ setup = function(h)
    h.ac.getFolder = mainOnly(h.ac.getFolder, '')
    h.ac.getCarDataFiles = mainOnly(h.ac.getCarDataFiles, 3)
    h.ac.getSetupSpinners = mainOnly(h.ac.getSetupSpinners, 2)
    h.ac.readDataFile = mainOnly(h.ac.readDataFile, '')
    h.ac.INIConfig.carData = mainOnly(h.ac.INIConfig.carData, { sections = {} })
    h.ac.INIConfig.trackData = mainOnly(h.ac.INIConfig.trackData, { sections = {} })
    h.ac.DataLUT11.carData = mainOnly(h.ac.DataLUT11.carData, nil)
  end })
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'découverte')
  local d = app.discovery
  T.eq(inTask, 0, 'aucun appel de CSP depuis la coroutine')
  T.eq(d.car.iniStatus['car.ini'], 'ok')
  T.ok(d.car.dataFiles and #d.car.dataFiles > 0, 'liste des fichiers')
  T.ok(#d.setup.spinners > 0 and d.setup.spinnerSource == nil, 'crans lus par CSP')
  T.ok(next(d.car.luts) ~= nil, 'courbes lues')
  T.ok(d.car.rawProbe.absolu == nil or d.car.rawProbe.absolu == 'ok', 'chemin complet du dossier des voitures')
  T.ok(d.space and #d.space.vars > 0, 'réglages optimisables')
  -- rapport J0 : lectures au lancement, profil Windows masqué
  T.ok(waitFor(h, function() return app.report ~= nil end, 3000), 'rapport')
  T.ok(app.report:find('Lectures au lancement de l\'app (fil principal) :', 1, true), 'sondes au lancement')
  T.ok(app.report:find('ac.getCarDataFiles(0) : table[', 1, true), 'liste au lancement')
  T.eq(app.perf.errors, 0)
end

-- Util.callHost : dans une tâche, l'appel est fait par l'ordonnanceur sur le fil principal (mêmes retours que Util.call) ;
-- hors tâche, appel direct ; une erreur reste une erreur bornée.
tests['IS06 Util.callHost : fil principal dans une tâche, mêmes retours qu\'Util.call'] = function()
  local s = Util.schedulerNew()
  local seen = {}
  local function probe(a, b)
    seen[#seen + 1] = coroutine.running() == nil
    return a + b, 'x'
  end
  local result
  Util.schedulerAdd(s, 't', function(ctx)
    local ok, v, w = Util.callHost(probe, 2, 3)
    ctx.tick()
    local okE, why = Util.callHost(function() error('boum') end)
    local okA, whyA = Util.callHost(nil)
    return { ok = ok, v = v, w = w, okE = okE, why = why, okA = okA, whyA = whyA }
  end, function(ok, r) result = ok and r or { failed = r } end)
  for _ = 1, 10 do Util.schedulerStep(s, nil, 0.002, 4) end
  T.ok(result and not result.failed, tostring(result and result.failed))
  T.eq(result.ok, true)
  T.eq(result.v, 5)
  T.eq(result.w, 'x')
  T.eq(seen[1], true, 'appel sur le fil principal')
  T.eq(result.okE, false)
  T.ok(tostring(result.why):find('boum', 1, true), 'message d\'erreur')
  T.eq(result.okA, false)
  T.eq(result.whyA, 'absent')
  -- hors tâche
  local ok, v = Util.callHost(probe, 1, 1)
  T.eq(ok, true)
  T.eq(v, 2)
end

-- Vie privée (rapport J0 collé dans une issue publique) : le profil Windows est masqué.
tests['PR01 rapport J0 : nom d\'utilisateur Windows masqué'] = function()
  local Caps = require('src/caps')
  T.eq(Caps.maskProfile('Dossier UserSetups : C:\\Users\\Jean Dupont\\Documents\\Assetto Corsa\\setups'),
    'Dossier UserSetups : %USERPROFILE%\\Documents\\Assetto Corsa\\setups')
  T.eq(Caps.maskProfile('confirmée : C:\\Users\\gouhi\\Documents/Assetto Corsa/setups/x.ini'),
    'confirmée : %USERPROFILE%\\Documents/Assetto Corsa/setups/x.ini')
  T.eq(Caps.maskProfile('d:/users/x/OneDrive'), '%USERPROFILE%/OneDrive')
  T.eq(Caps.maskProfile('D:\\SteamLibrary\\steamapps'), 'D:\\SteamLibrary\\steamapps', 'autres chemins intacts')
end

-- Stockage (45 Ko sur 64 chez Vincent le 12/11/2026) : nombres courts, purge par priorité de genre, entrée sans date
-- purgeable, journal des entrées retirées, apostrophe d'un dossier de mod sans danger, relecture sans écriture.
tests['ST01 stockage : nombres courts, relus à l\'identique ou presque'] = function()
  local Store = require('src/store')
  local text = Store.serialize({ ['cal:car:trk:-:0'] = { airTemp = 22.800416946411133, brake = 0.89464999227648756,
    data = 2060105670, drag = 1, stamp = 1792368000 } })
  T.ok(text:find('airTemp=22.8004169|', 1, true), text)
  T.ok(text:find('brake=0.894649992|', 1, true), text)
  T.ok(text:find('data=2060105670|', 1, true), text)
  T.ok(text:find('#drag=1|', 1, true), text)
  T.ok(text:find('stamp=1792368000$'), text)
  local entries = Store.parse(text)
  local e = entries['cal:car:trk:-:0']
  T.near(e.airTemp, 22.800416946411133, 1e-6)
  T.near(e.brake, 0.89464999227648756, 1e-8)
  T.eq(e.data, 2060105670)
end

tests['ST02 stockage plein : rugosité et calibrations d\'abord, mémoire figée en dernier, retraits journalisés'] = function()
  local Store = require('src/store')
  local Config = require('src/config')
  local K = Config.K
  local saved = K.storeMaxBytes
  local store = { entries = {}, dirty = true }
  store.entries['mem:a:t:-:quali:sec'] = { file = 'old', hash = 1, version = 1, stamp = 10, locked = true }
  store.entries['mem:b:t:-:quali:sec'] = { file = 'old2', hash = 1, version = 1, stamp = 20 }
  store.entries['ver:a:t:-:qualif:1'] = { file = 'v', hash = 1, version = 1, stamp = 5 }
  store.entries['cal:a:t:-:0'] = { mu = 1, stamp = 900 }
  store.entries['rough:a:t:-'] = { G0 = 1, stamp = 1000 }
  store.entries['last:a:t:-:quali'] = { file = 'x', stamp = 1 }
  store.entries['rlaps:a:t:-'] = { laps = 10 }   -- sans date : la plus ancienne de son rang
  store.entries.settings = { language = 'fr' }
  local full = #Store.serialize(store.entries)
  local function purgeTo(bytes)
    K.storeMaxBytes = bytes
    store.purged = nil
    Store.purge(store)
    K.storeMaxBytes = saved
    return store.purged or {}
  end
  local p = purgeTo(full - 1)
  T.eq(p[1], 'rough:a:t:-', 'la rugosité d\'abord, même la plus récente')
  p = purgeTo(full - 60)
  T.eq(p[1], 'cal:a:t:-:0', 'puis la calibration')
  p = purgeTo(#Store.serialize(store.entries) - 1)
  T.eq(p[1], 'rlaps:a:t:-', 'puis, parmi derniers setups et tours saisis, l\'entrée sans date')
  p = purgeTo(#Store.serialize(store.entries) - 1)
  T.eq(p[1], 'last:a:t:-:quali')
  p = purgeTo(#Store.serialize(store.entries) - 1)
  T.eq(p[1], 'ver:a:t:-:qualif:1', 'versions validées avant la mémoire')
  p = purgeTo(#Store.serialize(store.entries) - 1)
  T.eq(p[1], 'mem:b:t:-:quali:sec', 'mémoire non figée avant la figée')
  p = purgeTo(1)
  T.eq(p[1], 'mem:a:t:-:quali:sec')
  T.ok(store.entries.settings ~= nil, 'les réglages ne partent jamais')
end

tests['ST03 stockage : apostrophe d\'un dossier de mod remplacée, relecture sans écriture'] = function()
  local Store = require('src/store')
  T.eq(Store.entryKey('last', "mod_car_'22", 'trk;x', '-'), 'last:mod_car__22:trk_x:-')
  local store = { entries = { ['last:a:t:-:quali'] = { file = 'x', stamp = 1 } }, dirty = false }
  local e = Store.get(store, 'last:a:t:-:quali', 1792368000.7)
  T.eq(e.file, 'x')
  T.eq(store.dirty, false, 'une relecture ne déclenche pas d\'écriture')
  T.eq(store.entries['last:a:t:-:quali'].stamp, 1792368000, 'date d\'usage à la seconde')
  Store.put(store, 'last:a:t:-:quali', { file = 'y' }, 1792368001.9)
  T.eq(store.dirty, true)
  T.eq(store.entries['last:a:t:-:quali'].stamp, 1792368001)
end

-- Enregistreur : quand toutes les clés plus anciennes sont protégées, le tour qui vient d'entrer reste dans la liste.
tests['EG01 meilleurs tours : jamais de tour hors de la liste quand les anciens sont protégés'] = function()
  local Recorder = require('src/recorder')
  local K = require('src/config').K
  local rec = Recorder.new(64)
  for i = 1, K.recorderMaxSignatures do rec.protected['s' .. i] = true end
  for i = 1, K.recorderMaxSignatures + 1 do
    Recorder.keepLap(rec, { valid = true, signature = 's' .. i, time = 90 + i, n = 1 })
  end
  for key in pairs(rec.laps.best) do
    local listed = false
    for _, k in ipairs(rec.laps.order) do listed = listed or k == key end
    T.ok(listed, key .. ' dans la liste')
  end
  T.ok(rec.laps.best['s' .. (K.recorderMaxSignatures + 1)] ~= nil, 'le nouveau tour gardé')
  -- un suivant, non protégé, évince le précédent non protégé : la liste reste bornée
  Recorder.keepLap(rec, { valid = true, signature = 'z', time = 80, n = 1 })
  T.eq(#rec.laps.order, K.recorderMaxSignatures + 1)
  T.eq(rec.laps.best['s' .. (K.recorderMaxSignatures + 1)], nil)
end

-- Horloge revenue en arrière (séance recommencée) : l'enregistreur repart tout de suite ; le journal n'est pas muet.
tests['EG02 horloge revenue en arrière : échantillons repris, journal pas muet'] = function()
  local Recorder = require('src/recorder')
  local rec = Recorder.new(64)
  rec.lastSampleAt, rec.nextSampleAt, rec.pending, rec.state = 1500, 1500.03, { deadline = 1501 }, 'enregistrement'
  local host = { ac = { getCar = function() return nil end } }
  Recorder.update(rec, host, 10, nil, {})
  T.eq(rec.nextSampleAt, nil)
  T.eq(rec.lastSampleAt, nil)
  T.eq(rec.pending, nil)
  T.eq(rec.state, 'attente')
  local log = Util.logNew(16, 2)
  T.ok(Util.logAdd(log, 1500, 'INFO', 'lap', 'Tour 1'))
  T.ok(Util.logAdd(log, 10, 'INFO', 'lap', 'Tour 1'), 'après le recul, la ligne passe')
  T.ok(Util.logAdd(log, 10, 'INFO', 'lap', 'Retouche FRONT_BIAS'), 'autre message du même code, même instant : passe')
  T.eq(Util.logAdd(log, 10.5, 'INFO', 'lap', 'Tour 1'), false, 'même code répété : limité')
  T.eq(Util.logAdd(log, 11, 'INFO', 'lap', 'Retouche ABS'), false, "plus tard dans l'intervalle : limitée")
end

-- Modèle (1.5.11, décision de Vincent du 12/11/2026 : « tout corriger, carrossage compris »).
local function realCar(carId, trackId)
  local Datasource = require('src/datasource')
  local TrackModel = require('src/track_model')
  local CarModel = require('src/car_model')
  local h = Fake.new({ car = require('fixtures/cars/' .. carId), track = require('fixtures/tracks/' .. trackId) })
  local sync = Util.syncContext()
  local raw = Datasource.sampleTrack(h, 1, sync)
  Datasource.probeBank(h, raw, sync)
  local track = assert(TrackModel.build(raw, Datasource.readTrackFiles(h, sync), 2))
  local base = CarModel.build(Datasource.readCar(h, 0, sync), nil)
  return base, track
end

tests["CM01 carrossage : gain jusqu'au sommet, perte au-delà et dans le mauvais sens"] = function()
  local CarModel = require('src/car_model')
  local tyre = { dcamber0 = 1.65, dcamber1 = -13 }
  local peak = 1.65 / 26
  T.eq(CarModel.camberFactor(tyre, 0), 1)
  T.ok(CarModel.camberFactor(tyre, peak / 2) > 1, 'gain avant le sommet')
  T.ok(CarModel.camberFactor(tyre, peak) > CarModel.camberFactor(tyre, peak / 2), 'maximum au sommet')
  T.ok(CarModel.camberFactor(tyre, 2 * peak) < CarModel.camberFactor(tyre, peak), 'perte au-delà du sommet')
  T.ok(CarModel.camberFactor(tyre, -peak) < 1, 'carrossage dans le mauvais sens : perte')
  T.ok(CarModel.camberFactor(tyre, 1) >= 0.5 and CarModel.camberFactor(tyre, -1) >= 0.5, 'borné')
  -- sur une vraie voiture : un peu de carrossage négatif à l'avant fait gagner du temps (avant : jamais)
  local Sim = require('src/laptime_sim')
  local base, track = realCar('lamborghini_huracan_gt3_evo2', 'monza')
  local function lap(camber)
    local s = CarModel.defaultSetup(base)
    s.camberF = camber
    return Sim.run(track, assert(CarModel.configure(base, s, { airTemp = 25 }))).time
  end
  T.ok(lap(-2.5) < lap(0), "carrossage négatif à l'avant : plus rapide qu'à 0°")
end

tests['CM02 freinage avec ABS : chaque essieu à sa limite, la répartition compte peu'] = function()
  local CarModel = require('src/car_model')
  local Sim = require('src/laptime_sim')
  local base, track = realCar('lamborghini_huracan_gt3_evo2', 'monza')
  local function lap(bias, abs)
    local s = CarModel.defaultSetup(base)
    s.brakeBias = bias
    return Sim.run(track, assert(CarModel.configure(base, s, { airTemp = 25, absActive = abs }))).time
  end
  local spreadAbs = math.abs(lap(0.62, true) - lap(0.55, true))
  local spreadNo = math.abs(lap(0.62, false) - lap(0.55, false))
  PY.note('CM02', string.format('écart de répartition 0,55 / 0,62 : avec ABS %.3f s, sans ABS %.3f s', spreadAbs, spreadNo))
  T.ok(spreadAbs < spreadNo, 'avec ABS, la répartition pèse moins')
  T.ok(lap(0.6, true) <= lap(0.6, false) + 1e-9, 'avec ABS, jamais plus lent')
end

tests['CM03 inertie, roulement : grandeurs physiques'] = function()
  local CarModel = require('src/car_model')
  local base = realCar('lamborghini_huracan_gt3_evo2', 'monza')
  local eff = assert(CarModel.configure(base, CarModel.defaultSetup(base), { airTemp = 25 }))
  -- inertie : plus forte en 1re qu'en 6e, de l'ordre de la centaine de kg en 1re (roues 1,75 et 1,95 kg·m²)
  T.ok(eff.inertiaMass[1] > eff.inertiaMass[eff.gearCount], 'masse équivalente plus forte en bas rapports')
  T.ok(eff.inertiaMass[eff.gearCount] > 50 and eff.inertiaMass[1] < 400, 'ordre de grandeur : ' .. eff.inertiaMass[1])
  -- roulement : environ 1 % du poids à l'arrêt (ROLLING_RESISTANCE_0 = 10), croissant avec l'appui
  local weight = eff.mass * Util.G
  T.ok(eff.rollRes[1] > 0.005 * weight and eff.rollRes[1] < 0.02 * weight, "roulement à l'arrêt : " .. eff.rollRes[1] .. ' N')
  T.ok(eff.rollRes[40] > eff.rollRes[1], "roulement croissant avec la vitesse et l'appui")
end

tests["CM04 hybride : le déploiement de l'ERS dépasse la pointe du moteur thermique"] = function()
  local CarModel = require('src/car_model')
  local Sim = require('src/laptime_sim')
  local base, track = realCar('urd_px1_aura', 'monza')
  local s = CarModel.defaultSetup(base)
  local eff = assert(CarModel.configure(base, s, { airTemp = 24, roadGrip = 0.98, ersSpec = base.ers }))
  T.ok(eff.ersOn and eff.ersTop and eff.ersTop > eff.topSpeed, 'plafond ERS au-delà de la pointe thermique')
  local one, zero = {}, {}
  for k = 1, track.n do one[k], zero[k] = 1, 0 end
  local full = Sim.run(track, eff, nil, { ersMask = one })
  local none = Sim.run(track, eff, nil, { ersMask = zero })
  PY.note('CM04', string.format('pointe thermique %.1f m/s ; vitesse maximale avec ERS %.1f m/s', eff.topSpeed, full.vMax))
  T.ok(full.vMax > eff.topSpeed + 0.5, 'vitesse maximale du tour au-delà de la pointe thermique : ' .. full.vMax)
  local plain = assert(CarModel.configure(base, s, { airTemp = 24, roadGrip = 0.98 }))
  T.near(none.time, Sim.run(track, plain).time, 1e-9, 'masque nul : la voiture sans ERS')
end

-- Colle : seuil des images/s relatif, cache des lectures, constat d'un chargement fenêtres fermées, overlay à jour.
tests['FP01 images/s : un plafond choisi ne réduit plus la tranche, une chute oui'] = function()
  local h, app = boot()
  h.sim.fps = 45
  frames(h, 3000)
  T.no(app.fpsSlow(45), 'VR à 45 i/s : pas de réduction')
  T.ok(app.fpsSlow(30), 'chute à 30 i/s : réduction')
  T.ok(app.fpsSlow(15), 'sous le plancher : réduction')
end

tests['CA01 découverte suivante : fichiers de la voiture et ligne IA gardés ; relance demandée : tout est relu'] = function()
  local h, app = boot()
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'découverte')
  local carData = 0
  local original = h.ac.INIConfig.carData
  h.ac.INIConfig.carData = function(...)
    carData = carData + 1
    return original(...)
  end
  -- découverte relancée par la colle (setup changé, chargement vérifié, nouvelle séance) : lectures gardées
  app.discoveryState = 'idle'
  T.ok(waitFor(h, function() return app.discoveryState == 'done' and app.discovery.carCached end), 'découverte suivante')
  T.eq(carData, 0, 'fichiers de la voiture non relus')
  T.ok(app.discovery.trackCached, 'ligne IA gardée')
  T.ok(app.discovery.space and #app.discovery.space.vars > 0, 'espace de setup refait sur le setup du moment')
  -- relance demandée par le pilote : tout est relu
  app.handleIntents({ rediscover = true })
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'découverte relancée')
  T.ok(carData > 0, 'relance demandée : fichiers relus')
  T.eq(app.discovery.trackCached, nil)
end

tests['LD01 constat du chargement suivi fenêtres fermées (boucle de calcul seule)'] = function()
  local h, app = boot()
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'découverte')
  app.loadCheck = { kind = 'quali', path = 'x', target = { JAMAIS_DANS_LA_VOITURE = 1 }, deadline = app.now + 0.5, backup = '' }
  for _ = 1, 60 do
    h.sim.time = h.sim.time + 1000 / 60
    script.SETUPLAB__UPDATE(1 / 60)
  end
  T.eq(app.loadCheck, nil, 'constat terminé sans fenêtre dessinée')
  T.ok(app.loadTest and app.loadTest.ok == false, 'écart constaté')
end

tests["OV09 overlay : réglages d'une version en préparation suivis à chaque calcul"] = function()
  local Ui = require('src/ui')
  local e = { changeList = { { key = 'a', contribution = 0.1 } } }
  T.eq(Ui.overlayChanges(e)[1].key, 'a')
  e.changeList = { { key = 'b', contribution = 0.2 }, { key = 'c', contribution = 0.3 } }
  local list = Ui.overlayChanges(e)
  T.eq(#list, 2, 'liste refaite')
  T.eq(list[1].key, 'c', 'triée par effet')
end

return tests
