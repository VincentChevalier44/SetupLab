-- Bêta 2.0.2 (réponses de Vincent du 16/11/2026) :
-- - A : « il doit enregistrer un setup modifié ainsi que son temps s'il est meilleur » : un setup de SetupLab retouché dans
--   le menu de setup, plus rapide en temps réels, devient une nouvelle version gardée en mémoire ;
-- - B : « oui pour la 6e vitesse » : la vitesse maxi du circuit est atteinte dans le dernier rapport.
local T = require('t')
local Fake = require('fakehost')
local R = require('src/recorder')

local tests = {}

local function boot(opts)
  opts = opts or {}
  local h = Fake.new({ car = require('fixtures/cars/' .. (opts.car or 'lamborghini_huracan_gt3_evo2')),
    track = require('fixtures/tracks/monza') })
  h.sim.raceSessionType = opts.session or 1
  h.session.type = opts.session or 1
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
    script.SETUPLAB__UPDATE(1 / 60)
    script.SETUPLAB__MAIN(1 / 60)
  end
end

local function ready(opts)
  local h, app = boot(opts)
  for _ = 1, 60000 do
    frames(h, 1)
    if app.discoveryState == 'done' then break end
  end
  T.eq(app.discoveryState, 'done', 'découverte')
  return h, app
end

-- Un cran réglable (hors carburant et répartition de freinage), retouché d'un pas.
local function retouch(h, skip)
  for _, sp in ipairs(h.spinners) do
    local step = sp.step or 1
    if sp.name ~= 'FUEL' and sp.name ~= 'FRONT_BIAS' and sp.name ~= skip and sp.max and sp.value + step <= sp.max then
      sp.value = sp.value + step
      return sp
    end
  end
  error('aucun cran retouchable')
end

-- Famille du setup de la voiture, relue voiture arrêtée.
local function liveFamily(app)
  app.inCar = nil
  return app.inCarFamily()
end

-- Case de la mémoire : le setup de la découverte, son texte (fichier de SetupLab), roulé dans ce lancement.
local function slot(h, app, group, fields)
  local d = app.discovery
  local text = h.ac.stringifyCurrentSetup(true, false)
  local m = { group = group, bucket = 'sec', file = 'SetupLab_' .. (group == 'course' and 'Course' or 'Qualif') .. '_v3.ini',
    hash = 7, version = 3, gain = 0.5, time = 80.0, family = d.family, signature = d.signature, text = text,
    locked = false }
  for k, v in pairs(fields or {}) do m[k] = v end
  app.memory[group .. '|sec'] = m
  R.keepFamily(app.recorder.laps, { family = d.family, bucket = 'sec', valid = true, acValid = true, time = 90.0 })
  return m
end

local function lapOf(family, time, extra)
  local lap = { family = family, bucket = 'sec', valid = true, acValid = true, time = time }
  for k, v in pairs(extra or {}) do lap[k] = v end
  return lap
end

-- Un tour roulé : compté par l'enregistreur (comme onLap), puis vérifié.
local function drive(app, lap)
  R.keepFamily(app.recorder.laps, lap)
  app.retouchCheck(lap)
end

tests['RT01 retouches plus rapides (tour rapide) : nouvelle version, temps, mémoire, setup à charger'] = function()
  local h, app = ready()
  local m = slot(h, app, 'essai', { best = 88.0 })
  local sp = retouch(h)
  local fam = liveFamily(app)
  T.ok(fam ~= m.family, 'famille retouchée')
  drive(app, lapOf(fam, 87.5))
  T.ok(app.retouchPending, 'en attente, voiture arrêtée')
  frames(h, 2)
  T.eq(app.retouchPending, nil)
  local e = app.memory['essai|sec']
  T.ok(e ~= m and e.retouched, 'référence remplacée : ' .. tostring(e.file))
  T.eq(e.version, 4, 'version suivante')
  T.ok(e.file:find('_v4', 1, true) and e.file:find('1.27.500', 1, true), 'nom : version et meilleur tour : ' .. e.file)
  T.near(e.best, 87.5, 1e-9, 'votre temps')
  T.eq(e.family, fam, 'famille du fichier = setup roulé')
  T.eq(e.replaced, m, 'référence d\'avant gardée')
  T.ok(h.written[e.path], 'fichier écrit')
  T.ok(h.written[e.path]:find('VALUE=' .. sp.value, 1, true), 'cran retouché dans le fichier')
  T.eq(app.saved.quali and app.saved.quali.name, e.file, 'setup à charger')
  T.eq(app.written[e.file], e.hash, 'fichier de SetupLab (chargeable)')
  T.ok(tostring(app.ui.message):find('v4', 1, true), app.ui.message)
  local L = require('src/i18n')
  L.set('en')
  local en = L.t(app.ui.message)
  L.set('fr')
  T.ok(en:find('Your changes to', 1, true) and en:find('kept in memory', 1, true) and not en:find('mémoire', 1, true), en)
  -- les tours suivants avec lui vont à sa case
  app.memoryLap(lapOf(fam, 87.2))
  T.near(app.memory['essai|sec'].best, 87.2, 1e-9)
  T.eq(app.perf.errors, 0)
end

tests['RT02 retouches pas plus rapides, sans temps réel de référence, ou référence figée : rien d\'enregistré'] = function()
  local h, app = ready()
  local m = slot(h, app, 'essai', { best = 88.0 })
  retouch(h)
  local fam = liveFamily(app)
  drive(app, lapOf(fam, 88.2))
  T.eq(app.retouchPending, nil, 'plus lent')
  drive(app, lapOf(fam, 87.0, { acValid = false, valid = false }))
  T.eq(app.retouchPending, nil, 'tour non compté par AC')
  m.best = nil
  drive(app, lapOf(fam, 87.0))
  T.eq(app.retouchPending, nil, 'temps simulé seulement : jamais comparé')
  m.best, m.locked = 88.0, true
  drive(app, lapOf(fam, 87.0))
  frames(h, 2)
  T.eq(app.retouchPending, nil)
  T.ok(tostring(app.ui.message):find('figé', 1, true), tostring(app.ui.message))
  T.eq(app.memory['essai|sec'], m, 'référence inchangée')
end

tests['RT03 setup ni roulé ni chargé par SetupLab, ou changé avant l\'arrêt : rien d\'enregistré'] = function()
  local h, app = ready()
  local m = slot(h, app, 'essai', { best = 88.0 })
  app.recorder.laps.family = {}
  local sp = retouch(h)
  local fam = liveFamily(app)
  drive(app, lapOf(fam, 87.0))
  T.eq(app.retouchPending, nil, 'pas un setup de SetupLab roulé')
  app.loaded.quali = { name = m.file, values = {} }
  drive(app, lapOf(fam, 87.0))
  T.ok(app.retouchPending, 'chargé par SetupLab')
  -- encore retouché avant l'arrêt : le setup de la voiture n'est plus celui du tour
  retouch(h, sp.name)
  frames(h, 2)
  T.eq(app.memory['essai|sec'], m, 'rien d\'enregistré')
end

tests['RT04 course : moyenne d\'au moins 3 tours de course, carburant de la référence gardé'] = function()
  local h, app = ready()
  local m = slot(h, app, 'course', { mean = 90.0, laps = 5 })
  retouch(h)
  local fam = liveFamily(app)
  for i = 1, 2 do
    local lap = lapOf(fam, 89.0 + i * 0.1)
    R.keepFamily(app.recorder.laps, lap)
    app.retouchCheck(lap)
  end
  T.eq(app.retouchPending, nil, 'deux tours : trop tôt')
  -- carburant de la voiture changé en roulant : jamais repris
  for _, sp in ipairs(h.spinners) do
    if sp.name == 'FUEL' then sp.value = math.max(sp.min or 0, sp.value - 1) end
  end
  local lap = lapOf(fam, 89.3)
  R.keepFamily(app.recorder.laps, lap)
  app.retouchCheck(lap)
  T.ok(app.retouchPending, 'trois tours de course plus rapides en moyenne')
  frames(h, 2)
  local e = app.memory['course|sec']
  T.ok(e ~= m and e.retouched, 'nouvelle version de course')
  T.near(e.mean, (89.1 + 89.2 + 89.3) / 3, 1e-9)
  T.eq(e.laps, 3)
  T.ok(not e.file:find('%d%.%d%d%.%d%d%d'), 'course : pas de temps dans le nom : ' .. e.file)
  local fuel = m.text:match('%[FUEL%]\nVALUE=([^\n]*)')
  if fuel then T.ok(h.written[e.path]:find('[FUEL]\nVALUE=' .. fuel, 1, true), 'carburant de la référence') end
  T.eq(app.saved.race and app.saved.race.name, e.file)
  T.eq(app.perf.errors, 0)
end

tests['RT05 setup de course retouché, setup de qualif aussi roulé : version de course (la référence la plus proche)'] = function()
  local h, app = ready()
  local race = slot(h, app, 'course', { mean = 90.0, laps = 5 })
  -- qualif : un autre setup (un cran plus loin ailleurs), roulé aussi, plus lent que vos retouches
  local other = retouch(h)
  local qtext = h.ac.stringifyCurrentSetup(true, false)
  other.value = other.value - (other.step or 1)
  app.memory['essai|sec'] = { group = 'essai', bucket = 'sec', file = 'SetupLab_Qualif_v2.ini', hash = 8, version = 2,
    family = 'qfam', text = qtext, best = 95.0, locked = false }
  R.keepFamily(app.recorder.laps, lapOf('qfam', 95.0))
  retouch(h, other.name)
  local fam = liveFamily(app)
  for i = 1, 3 do
    local lap = lapOf(fam, 89.0 + i * 0.1)
    R.keepFamily(app.recorder.laps, lap)
    app.retouchCheck(lap)
  end
  T.ok(app.retouchPending, 'plus rapide')
  frames(h, 2)
  local e = app.memory['course|sec']
  T.ok(e ~= race and e.retouched, 'version de course : ' .. tostring(e and e.file))
  T.eq(app.memory['essai|sec'].file, 'SetupLab_Qualif_v2.ini', 'qualif inchangée')
  T.eq(app.perf.errors, 0)
end

tests['RT06 tour rapide : un tour plus lent après le meilleur ne compte pas contre lui ; enregistré une seule fois'] = function()
  local h, app = ready()
  slot(h, app, 'essai', { best = 88.0 })
  retouch(h)
  local fam = liveFamily(app)
  for _, t in ipairs({ 87.4, 88.6 }) do
    local lap = lapOf(fam, t)
    R.keepFamily(app.recorder.laps, lap)
    app.retouchCheck(lap)
  end
  T.ok(app.retouchPending, 'meilleur tour 87.4 gardé')
  frames(h, 2)
  local e = app.memory['essai|sec']
  T.ok(e.retouched, 'enregistré')
  T.near(e.best, 87.4, 1e-9)
  drive(app, lapOf(fam, 87.0))
  T.eq(app.retouchPending, nil, 'déjà enregistré : sa case suit vos tours')
end

tests['RT07 affinage : ses versions attendent « Valider » ; numéro après la version en attente'] = function()
  local h, app = ready()
  local m = slot(h, app, 'essai', { best = 88.0 })
  retouch(h)
  local fam = liveFamily(app)
  -- version de l'affinage en essai (ce setup) : pas une retouche
  app.refines.quali = { kind = 'quali', active = false, version = 5, history = { { version = 5, family = fam } } }
  drive(app, lapOf(fam, 87.0))
  T.eq(app.retouchPending, nil, 'version calculée par affinage')
  -- affinage actif de qualif : rien sans « Valider »
  app.refines.quali = { kind = 'quali', active = true, version = 5, history = {} }
  drive(app, lapOf(fam, 86.9))
  T.eq(app.retouchPending, nil, 'affinage actif')
  -- affinage arrêté, v5 calculée en attente (sans fichier) : vos retouches prennent le numéro suivant
  app.refines.quali = { kind = 'quali', active = false, version = 5, history = { { version = 5, family = 'autre' } } }
  drive(app, lapOf(fam, 86.8))
  T.ok(app.retouchPending, 'en attente')
  frames(h, 2)
  local e = app.memory['essai|sec']
  T.ok(e ~= m and e.retouched)
  T.eq(e.version, 6, 'après la v5 en attente')
  T.eq(app.refines.quali.version, 5, 'affinage inchangé')
  T.eq(app.nextVersion('quali'), 7)
  T.eq(app.loaded.quali and app.loaded.quali.name, e.file, 'référence des retouches suivantes')
end

tests['RT08 composé retouché revenu à celui du setup chargé : libéré ; changé encore : suivi'] = function()
  local _, app = ready()
  local d = app.discovery
  app.lastLoadKind = 'quali'
  app.loaded.quali = { values = { TYRES = 2 }, name = 'SetupLab_Qualif_v3.ini' }
  app.pins.quali = { TYRES = { value = 1, from = 2 } }
  d.compoundIndex = 0
  app.detectPins(d)
  T.eq(app.pins.quali.TYRES and app.pins.quali.TYRES.value, 0, 'suivi')
  d.compoundIndex = 2
  app.detectPins(d)
  T.eq(app.pins.quali.TYRES, nil, 'libéré')
  -- version chargée qui garde votre composé : la retouche reste
  app.loaded.quali = { values = { TYRES = 0 }, name = 'SetupLab_Qualif_v4.ini' }
  app.pins.quali = { TYRES = { value = 0, from = 2 } }
  d.compoundIndex = 0
  app.detectPins(d)
  T.eq(app.pins.quali.TYRES and app.pins.quali.TYRES.value, 0, 'gardé dans la version')
end

tests['RT09 pont : dernier tour jugé de la séance précédente ignoré, texte réécrit ou pont coupé au changement'] = function()
  local C = require('src/companion')
  local c = { state = 'connected', session = { lastLapId = 3, lastLapClean = false }, sessionText = 'A' }
  T.eq(C.lapVerdict(c, 3), false, 'même séance')
  C.newSession(c)
  T.eq(C.lapVerdict(c, 3), nil, 'séance suivante')
  -- texte réécrit pour les IA (autre aiLapCount), même dernier tour jugé : toujours ignoré
  c.sessionText, c.session = 'A2', { lastLapId = 3, lastLapClean = false, aiLapCount = 9 }
  T.eq(C.lapVerdict(c, 3), nil, 'texte réécrit, même tour')
  c.sessionText, c.session = 'B', { lastLapId = 3, lastLapClean = true }
  T.eq(C.lapVerdict(c, 3), true, 'tour jugé dans cette séance')
  -- pont coupé au changement : le dernier texte lu compte
  local d = { state = 'connected', session = nil, sessionText = nil, lastReadText = 'v=1;lastLapId=3;lastLapClean=0' }
  C.newSession(d)
  d.sessionText, d.session = 'A', { lastLapId = 3, lastLapClean = false }
  T.eq(C.lapVerdict(d, 3), nil, 'ancien texte relu après reconnexion')
end

return tests
