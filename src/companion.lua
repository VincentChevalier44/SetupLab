-- SetupLab — apps compagnes (1.5.12, demande de Vincent du 12/11/2026). Module d'E/S : l'hôte est injecté par la colle.
--
-- SetupLab reste indépendante : sans AdvancedIA (ou sans ac.connect, CSP 0.2.11), rien ne change, rien n'est affiché.
-- Avec AdvancedIA en marche, lecture seule (jamais d'écriture dans ses structures) :
--   pont v2 (AdvancedIA 2.0.0 ; ac.connect, src/bridge_layout.lua copié à l'identique d'AdvancedIA) : battement,
--     fermeture, état du moteur, pluie, coût, voitures (filtre de trafic) ;
--   clé ac.store « AdvancedIA.session » (AdvancedIA 1.63) : verdict du tour du joueur (neutralisation, drapeau, pénalité),
--     règles de la séance (gommes, arrêts, DRS), coût par image, rythme des IA. Texte « v=1;clé=valeur;… ».
-- Publication (SpotterEnginer, contrat v1 convenu le 12/11/2026) : clé ac.store « SetupLab.state », 240 octets au plus,
-- réécrite seulement quand une valeur change.
-- Toutes les fonctions de ce module tournent sur le fil principal (update), jamais dans une tâche de l'ordonnanceur
-- (leçon de l'issue n° 2 : CSP 0.2.11 refuse certains appels depuis une coroutine).

local Util = require('src/util')
local Config = require('src/config')
local Layout = require('src/bridge_layout')
local K = Config.K

local M = {}

local get, call = Util.get, Util.call
local floor = math.floor

M.SESSION_KEY = 'AdvancedIA.session'
M.STATE_KEY = 'SetupLab.state'
M.FOLDERS = { 'AdvancedIA', 'ACAdvancedIA' }

function M.new()
  return { installed = false, detected = false, opened = false, state = 'absent', reason = '', release = '',
    lastBeat = 0, beatAt = -1, hello = nil, data = nil, session = nil, sessionText = nil, nextRead = -1,
    published = nil, live = nil }
end

-- Installation d'AdvancedIA : manifeste dans apps/lua/AdvancedIA (ou l'ancien dossier ACAdvancedIA). Une fois.
function M.detect(c, host)
  local folderID = get(get(host.ac, 'FolderID'), 'ScriptOrigin')
  local okF, own = call(get(host.ac, 'getFolder'), folderID)
  if not (okF and type(own) == 'string' and own ~= '') then return false end
  local root = own:gsub('[\\/]+$', ''):match('^(.*)[\\/][^\\/]+$')
  if root == nil then return false end
  local exists, load = get(host.io, 'fileExists'), get(host.io, 'load')
  for _, name in ipairs(M.FOLDERS) do
    local okE, present = call(exists, root .. '/' .. name .. '/manifest.ini')
    if okE and present == true then
      c.installed = true
      local okL, text = call(load, root .. '/' .. name .. '/manifest.ini', '')
      if okL and type(text) == 'string' then
        c.release = Util.truncate(text:match('\nVERSION%s*=%s*([^\r\n]+)') or text:match('^VERSION%s*=%s*([^\r\n]+)') or '', 24)
      end
      break
    end
  end
  return c.installed
end

-- Structures du pont : même constructeur qu'AdvancedIA et SpotterEnginer (mêmes types, mêmes clés).
local function item(S, f)
  local kind = f[2]
  if kind == 'bool' then return S.boolean() elseif kind == 'int' then return S.int32() elseif kind == 'uint' then return S.uint32()
  elseif kind == 'float' then return S.float() elseif kind == 'double' then return S.double() elseif kind == 'string' then
    return S.string(f[3]) end
  error('pont : type inconnu ' .. tostring(kind), 0)
end

local function struct(S, key, list)
  local t = {}
  if key then t.key = S.key(key) end
  for i = 1, #list do t[list[i][1]] = item(S, list[i]) end
  return t
end

-- Ouverture du pont, une fois, seulement si AdvancedIA est installé (sinon rien n'est créé).
function M.open(c, host)
  if c.opened then return c.hello ~= nil end
  c.opened = true
  if not c.installed then return false end
  local connect, S = get(host.ac, 'connect'), get(host.ac, 'StructItem')
  if type(connect) ~= 'function' or type(S) ~= 'table' then
    c.reason = 'ac.connect absent'
    return false
  end
  local ok, hello, data = pcall(function()
    local h = connect(struct(S, Layout.helloKey, Layout.hello))
    local d = struct(S, Layout.dataKey, Layout.fields)
    d.cars = S.array(S.struct(struct(S, nil, Layout.car)), Layout.maxCars)
    return h, connect(d)
  end)
  if ok then
    c.hello, c.data = hello, data
    return true
  end
  c.reason = Util.truncate(tostring(hello), K.textMax.error)
  return false
end

-- Champ d'une structure partagée (accès protégé, sans fermeture créée : appelé à chaque image).
local function index(t, key) return t[key] end
local function field(t, key)
  local ok, v = pcall(index, t, key)
  if ok then return v end
  return nil
end

local function flag(v)
  if v == '1' or v == 'true' then return true end
  if v == '0' or v == 'false' then return false end
  return nil
end

local function number(v)
  local n = tonumber(v)
  if n and Util.isFinite(n) then return n end
  return nil
end

-- Texte de la clé AdvancedIA.session -> table, ou nil (autre version, texte illisible). Tolérant : champ inconnu ignoré,
-- champ illisible absent (nil). Format exact à revérifier avec la session AdvancedIA (séparateurs, lettres de séance).
function M.parseSession(text)
  if type(text) ~= 'string' or #text > 1024 then return nil end
  local raw = {}
  for k, v in text:gmatch('([%w_]+)=([^;]*)') do raw[k] = v end
  if raw.v ~= '1' then return nil end
  local out = {
    playerLapId = number(raw.playerLapId), playerLapClean = flag(raw.playerLapClean),
    lastLapId = number(raw.lastLapId), lastLapClean = flag(raw.lastLapClean),
    reason = raw.reason and Util.truncate(raw.reason, 16) or nil,
    drsAllowed = flag(raw.drsAllowed), compoundChange = flag(raw.compoundChange), wetWaived = flag(raw.wetWaived),
    costMs = number(raw.costMs), aiLapMean = number(raw.aiLapMean), aiLapCount = number(raw.aiLapCount),
    rules = raw.rules and Util.truncate(raw.rules, 24) or nil, session = raw.session and raw.session:sub(1, 1) or nil,
  }
  if raw.compoundsAllowed and raw.compoundsAllowed ~= '' and raw.compoundsAllowed ~= '-' then
    local allowed, any = {}, false
    for n in raw.compoundsAllowed:gmatch('[^,]+') do
      local i = number(n)
      if i and i >= 0 then
        allowed[floor(i)] = true
        any = true
      end
    end
    out.compoundsAllowed = any and allowed or nil
  end
  return out
end

-- Instantané des champs utiles du pont, recopiés dans la même table à chaque image (rien n'est gardé de la structure
-- partagée ; aucune table créée par image).
local SNAPSHOT_BOOL = { 'enabled', 'ready', 'online', 'replay', 'paused', 'panic', 'wet', 'neutral', 'red', 'raceKnown' }
local SNAPSHOT_RAW = { 'guard', 'sessionType', 'raceLapsLeft', 'mandatoryStops', 'maxStintMin', 'minPitTime' }
local function snapshot(d, s)
  for i = 1, #SNAPSHOT_BOOL do s[SNAPSHOT_BOOL[i]] = field(d, SNAPSHOT_BOOL[i]) == true end
  for i = 1, #SNAPSHOT_RAW do s[SNAPSHOT_RAW[i]] = field(d, SNAPSHOT_RAW[i]) end
  return s
end

-- Une image : état de la liaison (battement en temps réel : l'horloge d'AdvancedIA s'arrête en pause), clé de séance
-- relue toutes les K.companionReadPeriod s. wall : horloge réelle (s). Renvoie vrai si l'état a changé.
function M.step(c, host, wall)
  local before = c.state
  local state, reason = 'absent', ''
  local hello = c.hello
  if not c.installed then
    state = 'absent'
  elseif hello == nil then
    state, reason = 'nobridge', c.reason or ''
  else
    local beat = tonumber(field(hello, 'heartbeat')) or 0
    if beat ~= c.lastBeat then c.lastBeat, c.beatAt = beat, wall end
    local alive = beat ~= 0 and c.beatAt >= 0 and wall - c.beatAt <= K.companionStale and wall >= c.beatAt
    if field(hello, 'closed') == true then
      state = 'closed'
    elseif not alive then
      state = 'waiting'
    elseif (tonumber(field(hello, 'bridgeVersion')) or 0) ~= Layout.version or c.data == nil then
      state = 'version'
    else
      c.snap = c.snap or {}
      local s = snapshot(c.data, c.snap)
      c.live = s
      if not s.enabled then state, reason = 'suspended', 'disabled'
      elseif s.panic then state, reason = 'suspended', 'panic'
      elseif s.replay then state, reason = 'suspended', 'replay'
      elseif s.paused then state, reason = 'suspended', 'paused'
      elseif not s.ready then state, reason = 'suspended', tostring(s.guard or '')
      else state = 'connected' end
    end
  end
  if state ~= 'connected' and state ~= 'suspended' then c.live = nil end
  c.state, c.reason = state, reason
  c.detected = c.installed or state == 'connected' or state == 'suspended'
  -- clé de séance : relue seulement connecté ; oubliée sinon (la valeur reste dans ac.store, jamais utilisée)
  if state == 'connected' then
    if wall >= c.nextRead or wall < c.nextRead - K.companionReadPeriod * 2 then
      c.nextRead = wall + K.companionReadPeriod
      local okL, text = call(get(host.ac, 'load'), M.SESSION_KEY)
      if okL and type(text) == 'string' and text ~= c.sessionText then
        c.sessionText = text
        c.session = M.parseSession(text)
      elseif not (okL and type(text) == 'string') then
        c.sessionText, c.session = nil, nil
      end
    end
  else
    c.session, c.sessionText = nil, nil
  end
  return state ~= before
end

function M.connected(c) return c ~= nil and c.state == 'connected' end

-- Verdict d'AdvancedIA sur un tour du joueur (numérotation de car.lapCount pendant ce tour) : true (propre), false
-- (neutralisation, drapeau, pénalité), nil (inconnu : pas encore publié, ou AdvancedIA absent).
function M.lapVerdict(c, lapId)
  if not M.connected(c) or c.session == nil or lapId == nil then return nil end
  local s = c.session
  if s.lastLapId == lapId and s.lastLapClean ~= nil then return s.lastLapClean, s.reason end
  return nil
end

-- Coût d'AdvancedIA par image (ms), ou nil.
function M.costMs(c)
  if not M.connected(c) or c.session == nil then return nil end
  local v = c.session.costMs
  if v and v >= 0 and v < K.companionCostMaxMs then return v end
  return nil
end

-- Piste mouillée selon AdvancedIA : true, false, ou nil (inconnu).
function M.wet(c)
  if not M.connected(c) or c.live == nil then return nil end
  return c.live.wet
end

-- DRS permis par la règle de la séance : false seulement si AdvancedIA le coupe.
function M.drsAllowed(c)
  if not M.connected(c) or c.session == nil then return nil end
  return c.session.drsAllowed
end

-- Règles de course du profil d'AdvancedIA : { stops = arrêts obligatoires, maxStintMin = relais maximal (min),
-- compoundChange, allowed = ensemble des index de composé permis (nil : pas de restriction) }, ou nil.
function M.rules(c)
  if not M.connected(c) then return nil end
  local live, s = c.live or {}, c.session or {}
  local stops = tonumber(live.mandatoryStops)
  local stint = tonumber(live.maxStintMin)
  local r = {
    stops = stops and stops > 0 and stops <= K.companionMaxStops and floor(stops) or nil,
    maxStintMin = stint and Util.isFinite(stint) and stint > 0 and stint or nil,
    compoundChange = s.compoundChange == true, allowed = s.compoundsAllowed, name = s.rules,
  }
  if r.stops == nil and r.maxStintMin == nil and not r.compoundChange and r.allowed == nil then return nil end
  return r
end

-- Voiture d'AC (indice ≥ 1) à ignorer dans le filtre de trafic : arrêtée, hors de la piste ou abandonnée (pont v2)
-- selon AdvancedIA.
function M.carIdle(c, index)
  if not M.connected(c) or c.data == nil or index == nil or index < 0 or index >= Layout.maxCars then return false end
  local cars = field(c.data, 'cars')
  local car = cars and field(cars, index)
  if car == nil or field(car, 'valid') ~= true then return false end
  return field(car, 'halt') == true or field(car, 'onTrack') == false or field(car, 'retired') == true
end

-- Composé du preset d'arrêt quand un changement est obligatoire : le meilleur composé permis (J le plus bas de la
-- comparaison de l'optimiseur, jamais un composé pluie sur le sec) différent du composé monté. comparison : entrées
-- { index, J, wet } ; indices : repli sans comparaison (ordre des composés de la voiture). Renvoie l'index, ou nil.
function M.pitCompound(mounted, allowed, comparison, indices)
  local best, bestJ = nil, math.huge
  for _, e in ipairs(comparison or {}) do
    if e.index ~= mounted and not e.wet and (allowed == nil or allowed[e.index]) and Util.isFinite(e.J) and e.J < bestJ then
      best, bestJ = e.index, e.J
    end
  end
  if best ~= nil then return best end
  for _, i in ipairs(indices or {}) do
    if i ~= mounted and (allowed == nil or allowed[i]) then return i end
  end
  return nil
end

-- Texte de SetupLab.state (contrat v1 avec SpotterEnginer) : champs dans l'ordre convenu, -1 pour un nombre inconnu,
-- « - » pour un nom inconnu. s : table des valeurs (voir la colle). sess (demande de SpotterEnginer du 12/11/2026) :
-- sim.currentSessionIndex, la clé est donc réécrite à chaque nouvelle séance ; stamp : sim.time / 1000 arrondi.
local function num(v, digits)
  if not Util.isFinite(v) then return '-1' end
  if digits == 0 then return string.format('%d', floor(v + 0.5)) end
  return string.format('%.' .. digits .. 'f', v)
end

local function name(v)
  if type(v) ~= 'string' or v == '' then return '-' end
  return (v:gsub('[;=,%c]', '_'):sub(1, 8))
end

function M.stateText(s)
  local phot = '-1'
  if Util.isFinite(s.hotF) and Util.isFinite(s.hotR) then
    phot = num(s.hotF, 1) .. ',' .. num(s.hotF, 1) .. ',' .. num(s.hotR, 1) .. ',' .. num(s.hotR, 1)
  end
  local tdl = Util.isFinite(s.tdl) and string.format('%.2f', s.tdl) or '-'
  local text = 'v=1;kind=' .. (s.kind or 'none') .. ';ver=' .. name(s.ver) .. ';fuel=' .. num(s.fuel, 1) .. ';fpl='
    .. num(s.fpl, 2) .. ';stint=' .. num(s.stint, 0) .. ';compound=' .. name(s.compound) .. ';phot=' .. phot .. ';tune='
    .. (s.tune or 'idle') .. ';readyN=' .. num(s.readyN or 0, 0) .. ';stamp=' .. num(s.stamp, 0) .. ';pitc=' .. name(s.pitc)
    .. ';stops=' .. num(s.stops, 0) .. ';tlap=' .. num(s.tlap, 0) .. ';tdl=' .. tdl .. ';tv=' .. (s.tv or '-') .. ';tch='
    .. (s.tch or '-') .. ';tid=' .. num(s.tid or 0, 0) .. ';sess=' .. num(s.sess, 0)
  return text:sub(1, K.companionStateMax)
end

-- Écrit SetupLab.state si une valeur a changé (le stamp seul ne compte pas : il dit l'instant de l'écriture) ; jamais si
-- ac.store manque. Renvoie vrai si écrit.
function M.publish(c, host, text)
  local key = text:gsub(';stamp=[^;]*', '')
  if key == c.published then return false end
  local store = get(host.ac, 'store')
  if type(store) ~= 'function' then return false end
  local ok = pcall(store, M.STATE_KEY, text)
  if ok then c.published, c.publishedText = key, text end
  return ok
end

return M
