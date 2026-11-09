-- Bêta 1.5.9 (constats de Vincent du 09/11/2026, week-end à Imola) :
-- - « il me dit qu'il faut que je sois dans les stands » : sur la grille, avant le départ d'une course, le setup se charge
--   comme au stand (reprendre sa course, partir de sa qualif, essayer la v1 de course) ; départ donné, plus rien ;
-- - « il ne m'affiche pas les mêmes [temps] que ceux… de l'onglet information… la télémétrie doit être parfaite » :
--   votre meilleur tour est celui qu'AC compte avec ce setup (trafic et incidents compris), la mémoire du circuit montre vos
--   vrais temps (le tour simulé y était affiché comme « votre meilleur »), le nom du fichier suit le même temps ;
-- - « pour une qualification on met toujours soit du supersoft et s'il n'y a pas de supersoft on met du soft ».
local T = require('t')
local Store = require('src/store')
local Fake = require('fakehost')

local tests = {}

local function boot(opts)
  opts = opts or {}
  local h = Fake.new({ car = require('fixtures/cars/' .. (opts.car or 'lamborghini_huracan_gt3_evo2')),
    track = require('fixtures/tracks/monza'), skin = opts.skin })
  local session = opts.session or 3
  h.sim.raceSessionType = session
  h.session.type = session
  h.session.laps = 14
  rawset(h.car, 'isRaceFinished', false)
  rawset(h.sim, 'isSessionFinished', false)
  if session == 3 then
    -- sur la grille : hors des stands, arrêtée
    h.car.isInPit, h.car.isInPitlane, h.car.speedMs = false, false, 0
  end
  h.texts = {}
  local function capture(text) h.texts[#h.texts + 1] = text end
  local text, wrapped, colored = h.ui.text, h.ui.textWrapped, h.ui.textColored
  h.ui.text = function(s) capture(s); return text(s) end
  h.ui.textWrapped = function(s) capture(s); return wrapped(s) end
  h.ui.textColored = function(s, c) capture(s); return colored(s, c) end
  Fake.install(h)
  assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
  local app = rawget(_G, 'SETUPLAB').app
  app.utcOffset = function() return 7200 end
  app.settings.optBudgetEvalsQ, app.settings.optBudgetEvalsC = 80, 300
  return h, app
end

local function frames(h, n)
  for _ = 1, n do
    h.sim.time = h.sim.time + 1000 / 60
    h.texts = {}
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

local function ready(opts)
  local h, app = boot(opts)
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'découverte')
  return h, app
end

local function shown(h, fragment)
  for _, s in ipairs(h.texts) do
    if tostring(s):find(fragment, 1, true) then return s end
  end
  return nil
end

local function cspHas(h, fragment)
  for _, line in ipairs(h.cspLog or {}) do
    if tostring(line):find(fragment, 1, true) then return true end
  end
  return false
end

local function lastVersion(r)
  for i = #r.history, 1, -1 do
    if r.history[i].version then return r.history[i] end
  end
  return nil
end

tests['GR01 sur la grille avant le départ : la v1 de course se charge ; menu fermé : dit ; départ donné : plus rien'] = function()
  local h, app = ready({ skin = true })
  app.settings.compoundChoice = app.discovery.compoundIndex
  h.sim.isSessionStarted = false
  frames(h, 2)
  T.ok(app.raceGrid(), 'grille avant le départ')
  app.settings.refineMinLaps, app.settings.refineInstantFirst = 0, false
  app.handleIntents({ refineStart = 'race' })
  local r = app.refine
  T.ok(waitFor(h, function() return r.version >= 1 and r.phase == 'tours' end, 60000), 'v1 : ' .. tostring(r.waiting))
  local e = lastVersion(r)
  T.eq(h.car.isInPit, false, 'sur la grille, hors des stands')
  local loads = #h.loadCalls
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'essayer' } })
  T.eq(e.status, 'essai', tostring(app.ui.message))
  T.eq(#h.loadCalls, loads + 1, 'chargée sur la grille : ' .. tostring(app.loadNote and app.loadNote.text) .. ' ; grille '
    .. tostring(app.raceGrid()) .. ', course ' .. tostring(app.raceSession()) .. ', arrivée ' .. tostring(app.raceOver())
    .. ', commencée ' .. tostring(h.sim.isSessionStarted) .. ', type ' .. tostring(app.context and app.context.sessionType)
    .. ', au stand ' .. tostring(h.car.isInPit) .. ', images ' .. tostring(app.frameNo))
  T.ok(waitFor(h, function() return app.loadCheck == nil end), 'chargement constaté')
  -- menu de setup fermé : la raison dit la grille, et l'état est au journal
  h.setupEditable = false
  app.handleIntents({ refineJudge = { version = e.version, verdict = 'valider' } })
  T.eq(e.status, 'validée', tostring(app.ui.message))
  T.ok(tostring(app.loadBlocker('race')):find('sur la grille, avant le départ', 1, true), tostring(app.loadBlocker('race')))
  -- un clic sur « Charger » refusé : la raison sous le bouton, l'état lu au journal
  app.handleIntents({ load = 'race' })
  T.ok(app.loadNote and tostring(app.loadNote.text):find('sur la grille', 1, true), tostring(app.loadNote and app.loadNote.text))
  T.ok(cspHas(h, 'séance commencée false'), 'état du refus au journal')
  -- état du chargement montré : « sur la grille » au lieu de « au stand », menu fermé
  frames(h, 1)
  local r0 = app.loadReady
  T.ok(r0 and r0.grid and r0.pit and r0.menu == false, 'sur la grille, menu fermé : ' .. tostring(r0 and r0.grid))
  h.setupEditable = true
  -- départ donné : plus rien ne se charge, même sur la grille
  h.sim.isSessionStarted = true
  frames(h, 2)
  T.no(app.raceGrid())
  T.ok(tostring(app.loadBlocker('race')):find('course en cours', 1, true), tostring(app.loadBlocker('race')))
  -- départ illisible : pas de grille (prudence)
  h.sim.isSessionStarted = nil
  T.no(app.raceGrid(), 'départ illisible')
  T.eq(app.perf.errors, 0)
end

tests['GR02 hors séance de course : chargement au stand seulement, comme avant'] = function()
  local h, app = ready({ session = 1 })
  h.car.isInPit, h.car.isInPitlane, h.car.speedMs = false, false, 0
  h.sim.isSessionStarted = false
  frames(h, 2)
  T.no(app.raceGrid(), 'essai : jamais de grille')
  app.handleIntents({ qualiStart = true })
  T.ok(waitFor(h, function() return app.quali and app.quali.state == 'done' end, 60000), 'calcul')
  app.handleIntents({ qualiSave = true })
  T.eq(app.loadBlocker('quali'), 'voiture hors du stand')
  frames(h, 1)
  T.no(app.loadReady and app.loadReady.pit, 'hors du stand')
  h.car.isInPit = true
  T.eq(app.loadBlocker('quali'), nil, 'au stand')
  T.eq(app.perf.errors, 0)
end

-- Gammes de composés relevées sur les voitures de Vincent (09/11/2026) : DTM et KillerOne (« Sec - Hard » … « Sec -
-- Supersoft », « Pluie - … »), Huracan (« Slick Soft/Medium/Hard »), Macca (quatre gammes « Grip … - Dure/Medium/Tendre/Super
-- tendre »), LMP (« LMP Soft/Medium/Hard »).
tests['QT01 pneus de qualification : le plus tendre de la gamme du composé monté (HS, US, SS, S) ; rien de deviné'] = function()
  local h, app = boot({ session = 1 })
  local q = require('src/car_model').softestCompound
  local function set(list)
    local out = {}
    for i, c in ipairs(list) do
      out[i] = { index = i - 1, name = c[1], short = c[2], use = c[3] or 'sec' }
    end
    return { compounds = out }
  end
  local dtm = set({ { 'Sec - Hard', 'H' }, { 'Sec - Medium', 'M' }, { 'Sec - Soft', 'S' }, { 'Sec - Supersoft', 'SS' },
    { 'Pluie - Inter', 'I', 'intermédiaire' }, { 'Pluie - Full Wet', 'W', 'pluie' } })
  T.eq(q(dtm, 0), 3, 'DTM en Hard : Supersoft')
  T.eq(q(dtm, 3), 3, 'déjà en Supersoft : il le garde')
  local hur = set({ { 'Slick Soft', 'S' }, { 'Slick Medium', 'M' }, { 'Slick Hard', 'H' } })
  T.eq(q(hur, 2), 0, 'sans supersoft : Soft')
  local lmp = set({ { 'LMP Soft' }, { 'LMP Medium' }, { 'LMP Hard' } })
  T.eq(q(lmp, 1), 0, 'reconnu par le nom, sans nom court')
  local macca = set({ { 'Grip d\'origine - Dure' }, { 'Grip d\'origine - Medium' }, { 'Grip d\'origine - Tendre' },
    { 'Grip d\'origine - Super tendre' }, { 'Grip Formule 3 - Dure' }, { 'Grip Formule 3 - Medium' },
    { 'Grip Formule 3 - Tendre' }, { 'Grip Formule 3 - Super tendre' } })
  T.eq(q(macca, 5), 7, 'gamme du composé monté (Formule 3), noms français')
  T.eq(q(macca, 0), 3, 'gamme d\'origine')
  -- composé monté de pluie et plusieurs gammes sèches : rien de deviné ; une seule gamme : la sienne
  local maccaWet = set({ { 'Grip A - Tendre' }, { 'Grip B - Tendre' }, { 'Pluie', 'W', 'pluie' } })
  T.eq(q(maccaWet, 2), nil, 'deux gammes, composé de pluie monté : le calcul choisit')
  T.eq(q(dtm, 5), 3, 'une gamme sèche, composé de pluie monté : Supersoft')
  -- hypersoft et ultrasoft compris (réponse de Vincent du 09/11/2026) ; aucun pneu tendre : le calcul choisit
  local f1 = set({ { 'Hypersoft', 'HS' }, { 'Ultrasoft', 'US' }, { 'Supersoft', 'SS' }, { 'Soft', 'S' }, { 'Medium', 'M' } })
  T.eq(q(f1, 4), 0, 'Hypersoft, le plus tendre')
  T.eq(q(set({ { 'Ultra Soft' }, { 'Soft' }, { 'Medium' } }), 2), 0, 'Ultra Soft avant Soft')
  T.eq(q(set({ { 'Slick Medium', 'M' }, { 'Slick', 'US' }, { 'Slick', 'SS' } }), 0), 1, 'nom court US')
  T.eq(q(set({ { 'Slick Soft' }, { 'Slick Super Soft' } }), 0), 1, 'Super Soft avant Soft')
  T.eq(q(set({ { 'Slick' } }), 0), nil, 'un seul composé sans dureté')
  T.eq(q(set({ { 'Pilot Sport Cup 2 R' } }), 0), nil, 'pneu routier')
  T.eq(q(set({ { 'Semi-slick Medium' }, { 'Semi-slick Hard' } }), 1), nil, 'aucun soft')
  T.eq(app.perf.errors, 0)
  local _ = h
end

tests['QT02 calcul du tour rapide : Soft imposé sur le sec ; refus, réglage et pluie passent avant'] = function()
  local h, app = ready({ session = 1 })
  -- banc : Slick Medium monté (index 1)
  T.eq(app.discovery.compoundIndex, 1)
  app.settings.compoundChoice = -1
  app.handleIntents({ qualiStart = true })
  T.ok(waitFor(h, function() return app.quali and app.quali.state == 'done' end, 60000), 'calcul')
  local c = app.quali.result.compound
  T.eq(c.index, 0, 'Slick Soft')
  T.eq(c.rule, 'quali')
  T.ok(cspHas(h, 'Pneus de qualification : '), 'dit au journal')
  -- réglage imposé : il passe avant
  app.settings.compoundChoice = 2
  app.handleIntents({ qualiStart = true })
  T.ok(waitFor(h, function() return app.quali and app.quali.state == 'done' end, 60000), 'calcul 2')
  T.eq(app.quali.result.compound.index, 2, 'composé du réglage')
  T.eq(app.quali.result.compound.rule, nil)
  -- composé refusé (« Modifier… ») : le composé monté reste
  app.settings.compoundChoice = -1
  app.pins.quali = { TYRES = { value = 1, from = 1 } }
  app.handleIntents({ qualiStart = true })
  T.ok(waitFor(h, function() return app.quali and app.quali.state == 'done' end, 60000), 'calcul 3')
  T.eq(app.quali.result.compound.index, 1, 'refus gardé')
  app.pins.quali = {}
  -- aucun supersoft ni soft reconnu : le calcul choisit, et les noms des composés sont au journal (une fois)
  local saved = {}
  for i, cc in ipairs(app.discovery.carBase.compounds) do
    saved[i] = { cc.name, cc.short }
    cc.name, cc.short = 'Gomme ' .. i, nil
  end
  app.handleIntents({ qualiStart = true })
  T.ok(waitFor(h, function() return app.quali and app.quali.state == 'done' end, 60000), 'calcul 4')
  T.eq(app.quali.result.compound.rule, nil)
  T.ok(cspHas(h, 'non appliquée (aucun pneu tendre reconnu) : Gomme 1'), 'composés dits au journal')
  for i, cc in ipairs(app.discovery.carBase.compounds) do cc.name, cc.short = saved[i][1], saved[i][2] end
  T.eq(app.perf.errors, 0)
end

tests['TA01 vos temps : meilleur tour d\'AC affiché, tour propre à côté ; mémoire en temps réels ; journal'] = function()
  local h, app = ready({ session = 1, skin = true })
  local d = app.discovery
  local U = require('src/ui')
  -- un tour propre en 1:27.305, un tour en trafic (compté par AC) en 1:26.374
  local fam = d.family
  local clean = { family = fam, bucket = 'sec', valid = true, acValid = true, time = 87.305, signature = d.signature }
  app.recorder.laps.family = {}
  local busy = { family = fam, bucket = 'sec', valid = false, acValid = true, time = 86.374, signature = d.signature,
    reason = require('src/recorder').TRAFFIC_REASON }
  local R = require('src/recorder')
  R.keepFamily(app.recorder.laps, clean)
  R.keepFamily(app.recorder.laps, busy)
  local stats = U.realLaps(app, fam, 'sec')
  T.near(U.realTime(stats, 'quali'), 86.374, 1e-9, 'votre meilleur : celui d\'AC')
  T.near(U.cleanBestApart(stats, 'quali'), 87.305, 1e-9, 'tour propre à côté')
  T.near(U.realTime(stats, 'race'), 87.305, 1e-9, 'course : moyenne des tours analysés seulement')
  T.ok(U.realText(stats, 'quali'):find('propre', 1, true), U.realText(stats, 'quali'))
  -- nouvelle séance : votre meilleur repart de zéro, comme le chrono d'AC ; l'analyse garde ses tours
  R.newSession(app.recorder)
  T.eq(U.realTime(stats, 'quali'), nil, 'nouvelle séance : aucun meilleur tour')
  T.near(stats.best, 87.305, 1e-9, 'analyse : meilleur tour propre gardé')
  T.eq(stats.count, 1)
  R.keepFamily(app.recorder.laps, { family = fam, bucket = 'sec', valid = true, acValid = true, time = 88.0 })
  T.near(U.realTime(stats, 'quali'), 88.0, 1e-9, 'meilleur de la séance')
  T.eq(U.cleanBestApart(stats, 'quali'), nil, 'propre de la séance : le même')
  R.newSession(app.recorder)
  R.keepFamily(app.recorder.laps, clean)
  R.keepFamily(app.recorder.laps, busy)
  -- mémoire : le tour simulé n'est plus « votre meilleur »
  app.memory['essai|sec'] = { group = 'essai', bucket = 'sec', file = 'SetupLab_Qualif_v3.ini', hash = 1, version = 3,
    gain = 0.74, time = 83.999, family = fam, locked = false }
  h.tab = 'Mémoire'
  frames(h, 1)
  T.ok(shown(h, 'TEMPS SIMULÉ · AUCUN TOUR MESURÉ') or shown(h, 'temps simulé · aucun tour mesuré'), 'temps simulé dit comme tel')
  app.memoryLap(busy)
  T.near(app.memory['essai|sec'].best, 86.374, 1e-9, 'meilleur tour d\'AC gardé')
  app.memoryLap(clean)
  T.near(app.memory['essai|sec'].best, 86.374, 1e-9, 'un tour plus lent ne le remplace pas')
  frames(h, 1)
  T.ok(shown(h, '1:26.374'), 'votre vrai meilleur tour à l\'écran')
  -- course : moyenne des tours analysés, jamais un tour rejeté
  app.memory['course|sec'] = { group = 'course', bucket = 'sec', file = 'SetupLab_Course_v1.ini', hash = 2, version = 1,
    gain = 1.3, time = 85.19, family = fam, locked = false }
  app.memoryLap(clean)
  app.memoryLap(busy)
  app.memoryLap({ family = fam, bucket = 'sec', valid = true, acValid = true, time = 88.305 })
  T.near(app.memory['course|sec'].mean, 87.805, 1e-9)
  T.eq(app.memory['course|sec'].laps, 2)
  -- gardé dans le stockage, relu au lancement suivant
  local key = app.storeKey('mem', d, 'essai', 'sec')
  if key then
    local e = Store.get(app.store, key, 0)
    T.ok(e and math.abs(e.best - 86.374) < 1e-9, 'stocké')
  end
  -- un tour terminé met la mémoire à jour (par le traitement de chaque tour)
  app.handleLap({ family = fam, bucket = 'sec', valid = true, acValid = true, time = 86.1, signature = d.signature })
  T.near(app.memory['essai|sec'].best, 86.1, 1e-9, 'tour terminé : mémoire à jour')
  -- validé avant la 1.5.9, sans « best » : le temps du nom du fichier (écrit par SetupLab depuis un de vos tours)
  if key then
    Store.put(app.store, key, { file = 'SetupLab_Qualif_v3_1.26.646.ini', hash = 5, version = 3, gain = 0.74, time = 83.999 }, 0)
    app.refreshMemory()
    T.near(app.memory['essai|sec'].best, 86.646, 1e-9, 'temps du nom du fichier')
    T.near(app.memory['essai|sec'].time, 83.999, 1e-9, 'temps simulé gardé à part')
  end
  -- contrôle croisé avec le chrono d'AC : son meilleur tour non compté est dit au journal
  h.car.bestLapTimeMs = 86000
  app.acBestSeen = nil
  local lap = { family = fam, bucket = 'sec', valid = false, time = 86.0, reason = 'setup modifié pendant le tour' }
  app.handleLap(lap)
  T.ok(cspHas(h, 'Meilleur tour d\'AC 86.000 s non compté'), 'avertissement au journal')
  T.eq(app.perf.errors, 0)
end

-- Issue n° 2 (08/11/2026, CSP 0.2.11 build 3465, voiture RSS) : « Calcul indisponible, modèle de voiture incomplet ». Le
-- rapport montrait tous les INI vides, la liste des fichiers et les crans en « format inattendu ». Les INI se relisent en
-- texte brut (ac.readDataFile, data.acd compris), les crans se déduisent de setup.ini et du setup en cours : le calcul a lieu.
tests['IS02 CSP 0.2.11 : INI vides, liste et crans illisibles : texte brut et setup.ini, le calcul a lieu'] = function()
  local Datasource = require('src/datasource')
  -- référence : les crans que donne CSP sur la même voiture
  local hRef = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza') })
  local reference = {}
  for _, sp in ipairs(hRef.spinners) do reference[sp.name] = sp end
  local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza') })
  h.sim.raceSessionType, h.session.type = 1, 1
  h.ac.INIConfig.carData = function() return { sections = {} } end
  h.ac.DataLUT11.carData = function() return nil end
  h.ac.getCarDataFiles = function() return 42 end
  h.ac.getSetupSpinners = function() return nil end
  h.texts = {}
  Fake.install(h)
  assert(loadfile(PY.appDir .. '/SetupLab.lua'))()
  local app = rawget(_G, 'SETUPLAB').app
  app.settings.optBudgetEvalsQ = 80
  T.ok(waitFor(h, function() return app.discoveryState == 'done' end), 'découverte')
  local d = app.discovery
  T.eq(d.car.iniStatus['car.ini'], 'ok (texte brut)')
  T.eq(d.car.dataFilesReason, 'format inattendu (number)')
  T.eq(d.setup.spinnerSource, 'setup.ini')
  T.eq(#d.setup.spinners, #hRef.spinners, 'tous les crans déduits, rapports de boîte compris')
  -- même encodage que les crans de CSP (bornes et valeur)
  for _, sp in ipairs(d.setup.spinners) do
    local ref = reference[sp.name]
    if ref then
      T.near(sp.min, ref.min, 1e-6, sp.name .. ' min')
      T.near(sp.max, ref.max, 1e-6, sp.name .. ' max')
      T.near(sp.value, ref.value, 1e-6, sp.name .. ' valeur')
    end
  end
  T.ok(d.space and #d.space.vars > 0, 'réglages optimisables')
  T.ok(d.carModel == nil or d.carModel.ok ~= false, 'modèle de voiture')
  -- signature en roulant : la même lecture
  T.ok(app.liveSignatureOf == nil or app.liveSignatureOf() ~= nil)
  app.handleIntents({ qualiStart = true })
  T.ok(waitFor(h, function() return app.quali and app.quali.state ~= 'running' end, 60000), 'calcul')
  T.eq(app.quali.state, 'done', tostring(app.quali.reason or app.ui.message))
  T.eq(app.perf.errors, 0)
end

-- Issue n° 2 : une liste de CSP sous forme d'objet indexable (userdata, cdata), depuis l'indice 0 : copiée entière.
tests['IS03 CSP : crans renvoyés en objet indexable (base 0) : tous lus'] = function()
  local Datasource = require('src/datasource')
  local h = Fake.new({ car = require('fixtures/cars/lamborghini_huracan_gt3_evo2'), track = require('fixtures/tracks/monza') })
  local real = h.spinners
  local proxy = newproxy(true)
  local mt = getmetatable(proxy)
  mt.__index = function(_, i) return type(i) == 'number' and real[i + 1] or nil end
  mt.__len = function() return #real end
  h.ac.getSetupSpinners = function() return proxy end
  local spinners = Datasource.readSpinners(h)
  T.eq(type(proxy), 'userdata')
  T.eq(#spinners, #real, 'tous les crans')
  T.eq(spinners[1].name, real[1].name, 'le premier (indice 0) compris')
  T.eq(spinners[#spinners].name, real[#real].name, 'le dernier compris')
end

return tests
